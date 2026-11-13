import {createHash} from "node:crypto";
import {createReadStream} from "node:fs";
import {mkdir, open, rename, rm, readdir, lstat} from "node:fs/promises";
import {join, resolve} from "node:path";
import {CloudError} from "../contracts.ts";
import type {MediaPart, MediaVariant} from "../contracts.ts";
import {uuid} from "../validation.ts";
import type {ObjectScope, ObjectStore} from "./object-store.ts";

function missing(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "ENOENT";
}

export class FileObjectStore implements ObjectStore {
  readonly root: string;
  constructor(root: string) { this.root = resolve(root); }

  private directory(scope: ObjectScope, area: "upload" | "media", id: string): string {
    return join(this.root, uuid(scope.accountID), uuid(scope.epoch), area, uuid(id));
  }

  private path(scope: ObjectScope, area: "upload" | "media", id: string, variant: MediaVariant): string {
    if (variant !== "original" && variant !== "thumbnail") throw new CloudError("invalid_record");
    return join(this.directory(scope,area,id),variant);
  }

  async inspect(scope: ObjectScope, area: "upload" | "media", id: string, variant: MediaVariant): Promise<MediaPart | undefined> {
    const hash = createHash("sha256");
    let size = 0;
    try {
      for await (const bytes of createReadStream(this.path(scope,area,id,variant))) {
        hash.update(bytes); size += bytes.length;
      }
    } catch (error) { if (missing(error)) return undefined; throw error; }
    return {size,sha256:hash.digest("hex")};
  }

  async append(scope: ObjectScope, uploadID: string, variant: MediaVariant, offset: number, bytes: Buffer): Promise<void> {
    if (!Number.isSafeInteger(offset) || offset < 0 || bytes.length === 0) throw new CloudError("invalid_record");
    const directory = this.directory(scope,"upload",uploadID), path = this.path(scope,"upload",uploadID,variant);
    await mkdir(directory,{recursive:true,mode:0o700});
    let file;
    try { file = await open(path,"r+"); }
    catch (error) { if (!missing(error)) throw error; file = await open(path,"wx+",0o600); }
    try {
      const length = (await file.stat()).size;
      if (offset > length) throw new CloudError("invalid_record");
      const overlap = Math.min(bytes.length,length-offset);
      if (overlap > 0) {
        const previous = Buffer.alloc(overlap);
        const read = await file.read(previous,0,overlap,offset);
        if (read.bytesRead !== overlap || !previous.equals(bytes.subarray(0,overlap))) throw new CloudError("corrupted_media");
      }
      // A previous process may have written bytes before its SQL transaction committed.
      let written = overlap;
      while (written < bytes.length) {
        const result = await file.write(bytes,written,bytes.length-written,offset+written);
        if (!result.bytesWritten) throw new Error("Object store write made no progress");
        written += result.bytesWritten;
      }
      await file.sync();
    } finally { await file.close(); }
  }

  async publish(scope: ObjectScope, uploadID: string, mediaID: string, variant: MediaVariant, expected: MediaPart): Promise<void> {
    const existing = await this.inspect(scope,"media",mediaID,variant);
    if (existing) {
      if (existing.size !== expected.size || existing.sha256 !== expected.sha256) throw new CloudError("corrupted_media");
      return;
    }
    const staged = await this.inspect(scope,"upload",uploadID,variant);
    if (!staged || staged.size !== expected.size || staged.sha256 !== expected.sha256) throw new CloudError("corrupted_media");
    await mkdir(this.directory(scope,"media",mediaID),{recursive:true,mode:0o700});
    await rename(this.path(scope,"upload",uploadID,variant),this.path(scope,"media",mediaID,variant));
  }

  async read(scope: ObjectScope, mediaID: string, variant: MediaVariant, offset: number, count: number): Promise<Buffer> {
    const file = await open(this.path(scope,"media",mediaID,variant),"r");
    try {
      const bytes = Buffer.alloc(count), result = await file.read(bytes,0,count,offset);
      return bytes.subarray(0,result.bytesRead);
    } finally { await file.close(); }
  }

  async removeMedia(scope: ObjectScope, id: string): Promise<void> { await rm(this.directory(scope,"media",id),{recursive:true,force:true}); }
  async removeOrphans(scope: ObjectScope, uploads: Set<string>, media: Set<string>, olderThan: Date): Promise<void> {
    for(const [area,keep] of [["upload",uploads],["media",media]] as const){
      const parent=join(this.root,uuid(scope.accountID),uuid(scope.epoch),area);
      let names:string[];try{names=await readdir(parent);}catch(error){if(missing(error))continue;throw error;}
      for(const name of names){
        // Only store-owned UUID directories; never traverse symlinks or unrelated files.
        if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(name) || keep.has(name))continue;
        const path=this.directory(scope,area,name),entry=await lstat(path);
        if(!entry.isSymbolicLink() && entry.isDirectory() && entry.mtime<olderThan)await rm(path,{recursive:true,force:true});
      }
    }
  }
  async removeUpload(scope: ObjectScope, id: string): Promise<void> {
    await rm(this.directory(scope,"upload",id),{recursive:true,force:true});
  }
  async removeEpoch(scope: ObjectScope): Promise<void> {
    await rm(join(this.root,uuid(scope.accountID),uuid(scope.epoch)),{recursive:true,force:true});
  }
  async removeAccount(accountID: string): Promise<void> {
    await rm(join(this.root,uuid(accountID)),{recursive:true,force:true});
  }
}
