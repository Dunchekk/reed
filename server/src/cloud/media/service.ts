import {randomUUID} from "node:crypto";
import {CloudDatabase} from "../database.ts";
import {CloudError} from "../contracts.ts";
import type {CloudScope, MediaManifest, MediaVariant, Upload} from "../contracts.ts";
import {integer, uuid, validateManifest} from "../validation.ts";
import {canonical} from "../records.ts";
import type {ObjectStore} from "./object-store.ts";

export const chunkLimit = 512 * 1024;
interface UploadRow {id: string; attachment_id: string; manifest: MediaManifest; original_offset: string; thumbnail_offset: string; complete: boolean}
function upload(row: UploadRow): Upload {
  return {id:row.id,originalOffset:Number(row.original_offset),thumbnailOffset:Number(row.thumbnail_offset),complete:row.complete};
}
export function variant(value: unknown): MediaVariant {
  if (value !== "original" && value !== "thumbnail") throw new CloudError("invalid_record");
  return value;
}

export class CloudMedia {
  readonly database: CloudDatabase;
  readonly objects: ObjectStore;
  readonly quotaBytes: number;
  constructor(database: CloudDatabase, objects: ObjectStore, quotaBytes = 2 * 1024 ** 3) {
    this.database = database; this.objects = objects; this.quotaBytes = quotaBytes;
  }

  async begin(scope: CloudScope, epoch: string, raw: MediaManifest): Promise<Upload> {
    const manifest = validateManifest(raw), bytes = manifest.original.size + manifest.thumbnail.size;
    return this.database.device(scope,epoch,async client => {
      const existing = (await client.query<UploadRow>("SELECT * FROM cloud_uploads WHERE account_id=$1 AND epoch=$2 AND attachment_id=$3",[scope.accountID,epoch,manifest.id])).rows[0];
      if (existing) {
        if (canonical(existing.manifest) !== canonical(manifest)) throw new CloudError("corrupted_media");
        await client.query("UPDATE cloud_uploads SET expires_at=now()+interval '7 days' WHERE account_id=$1 AND id=$2",[scope.accountID,existing.id]);
        return upload(existing);
      }
      const ready = (await client.query("SELECT manifest FROM cloud_media WHERE account_id=$1 AND id=$2",[scope.accountID,manifest.id])).rows[0];
      if (ready && canonical(ready.manifest) !== canonical(manifest)) throw new CloudError("corrupted_media");
      const reserved = (await client.query(`SELECT
        (SELECT COALESCE(SUM(bytes),0) FROM cloud_media WHERE account_id=$1) +
        (SELECT COALESCE(SUM((manifest->'original'->>'size')::bigint + (manifest->'thumbnail'->>'size')::bigint),0)
         FROM cloud_uploads WHERE account_id=$1 AND NOT complete) AS bytes,
        (SELECT COUNT(*) FROM cloud_uploads WHERE account_id=$1 AND NOT complete) AS count`,[scope.accountID])).rows[0];
      if (!ready && (Number(reserved.bytes)+bytes > this.quotaBytes || Number(reserved.count) >= 1000)) throw new CloudError("quota_exceeded");
      const result = await client.query<UploadRow>(`INSERT INTO cloud_uploads(account_id,epoch,id,attachment_id,manifest,original_offset,thumbnail_offset,complete)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`,[scope.accountID,epoch,randomUUID(),manifest.id,JSON.stringify(manifest),ready?manifest.original.size:0,ready?manifest.thumbnail.size:0,!!ready]);
      return upload(result.rows[0]!);
    });
  }

  async append(scope: CloudScope, epoch: string, uploadID: string, rawVariant: MediaVariant, offset: number, bytes: Buffer): Promise<Upload> {
    const id = uuid(uploadID), part = variant(rawVariant);
    integer(offset); integer(bytes.length,1,chunkLimit);
    return this.database.device(scope,epoch,async client => {
      const row = (await client.query<UploadRow>("SELECT * FROM cloud_uploads WHERE account_id=$1 AND epoch=$2 AND id=$3",[scope.accountID,epoch,id])).rows[0];
      if (!row) throw new CloudError("not_found");
      const knownOffset = Number(part === "original" ? row.original_offset : row.thumbnail_offset);
      if (offset > knownOffset || offset + bytes.length > row.manifest[part].size) throw new CloudError("invalid_record");
      const objectScope = {accountID:scope.accountID,epoch};
      if (row.complete) {
        const previous = await this.objects.read(objectScope,row.attachment_id,part,offset,bytes.length);
        if (!previous.equals(bytes)) throw new CloudError("corrupted_media");
        return upload(row);
      }
      await this.objects.append(objectScope,id,part,offset,bytes);
      const column = part === "original" ? "original_offset" : "thumbnail_offset";
      const result = await client.query<UploadRow>(`UPDATE cloud_uploads SET ${column}=$3,expires_at=now()+interval '7 days' WHERE account_id=$1 AND id=$2 RETURNING *`,[scope.accountID,id,Math.max(knownOffset,offset+bytes.length)]);
      return upload(result.rows[0]!);
    });
  }

  async finish(scope: CloudScope, epoch: string, uploadID: string): Promise<void> {
    const id = uuid(uploadID);
    await this.database.device(scope,epoch,async client => {
      const row = (await client.query<UploadRow>("SELECT * FROM cloud_uploads WHERE account_id=$1 AND epoch=$2 AND id=$3",[scope.accountID,epoch,id])).rows[0];
      if (!row) throw new CloudError("not_found");
      if (row.complete) return;
      const objectScope = {accountID:scope.accountID,epoch};
      for (const part of ["original","thumbnail"] as const) {
        const offset = Number(part === "original" ? row.original_offset : row.thumbnail_offset);
        const actual = await this.objects.inspect(objectScope,"media",row.attachment_id,part) ?? await this.objects.inspect(objectScope,"upload",id,part);
        if (offset !== row.manifest[part].size || !actual || canonical(actual) !== canonical(row.manifest[part])) throw new CloudError("corrupted_media");
      }
      for (const part of ["original","thumbnail"] as const) await this.objects.publish(objectScope,id,row.attachment_id,part,row.manifest[part]);
      await client.query("INSERT INTO cloud_media(account_id,id,manifest,bytes) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING",[scope.accountID,row.attachment_id,JSON.stringify(row.manifest),row.manifest.original.size+row.manifest.thumbnail.size]);
      await client.query("UPDATE cloud_uploads SET complete=true WHERE account_id=$1 AND id=$2",[scope.accountID,id]);
    });
  }

  async manifest(scope: CloudScope, epoch: string, id: string): Promise<MediaManifest> {
    const mediaID = uuid(id);
    return this.database.device(scope,epoch,async client => {
      const row = (await client.query<{manifest:MediaManifest}>("SELECT manifest FROM cloud_media WHERE account_id=$1 AND id=$2",[scope.accountID,mediaID])).rows[0];
      if (!row) throw new CloudError("not_found");
      return row.manifest;
    });
  }

  async read(scope: CloudScope, epoch: string, id: string, rawVariant: MediaVariant, offset: number, count: number): Promise<Buffer> {
    const mediaID = uuid(id), part = variant(rawVariant);
    integer(offset); integer(count,1,chunkLimit);
    return this.database.device(scope,epoch,async client => {
      const row = (await client.query<{manifest:MediaManifest}>("SELECT manifest FROM cloud_media WHERE account_id=$1 AND id=$2",[scope.accountID,mediaID])).rows[0];
      if (!row) throw new CloudError("not_found");
      if (offset > row.manifest[part].size) throw new CloudError("invalid_record");
      return this.objects.read({accountID:scope.accountID,epoch},mediaID,part,offset,Math.min(count,row.manifest[part].size-offset));
    });
  }
}
