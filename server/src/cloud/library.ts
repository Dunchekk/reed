import {randomUUID} from "node:crypto";
import {CloudDatabase} from "./database.ts";
import {CloudError} from "./contracts.ts";
import type {CloudPage, CloudScope, CloudSummary} from "./contracts.ts";
import {record} from "./records.ts";

/** Replication cursor and epoch live in the same transaction as every mutation. */
export class CloudLibrary {
  readonly database: CloudDatabase;
  readonly notificationsAvailable: boolean;

  constructor(database: CloudDatabase, notificationsAvailable = false) {
    this.database = database;
    this.notificationsAvailable = notificationsAvailable;
  }

  async summary(accountID: string): Promise<CloudSummary> {
    return this.database.account(accountID, async (client, state) => {
      const cards = await client.query("SELECT COUNT(*)::int AS count FROM cloud_records WHERE account_id=$1 AND kind='card' AND payload IS NOT NULL", [accountID]);
      const media = await client.query("SELECT COALESCE(SUM(bytes),0)::text AS bytes FROM cloud_media WHERE account_id=$1", [accountID]);
      return {epoch: state.epoch, sequence: state.sequence, cards: cards.rows[0].count,
        mediaBytes: Number(media.rows[0].bytes), notificationsAvailable: this.notificationsAvailable};
    });
  }

  async pull(scope: CloudScope, epoch: string, after: number, limit: number): Promise<CloudPage> {
    if (!Number.isSafeInteger(after) || after < 0 || !Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new CloudError("invalid_record");
    }
    return this.database.device(scope, epoch, async (client, state) => {
      if (after > state.sequence) throw new CloudError("invalid_record");
      const rows = await client.query(`SELECT kind,id,version,sequence,payload FROM cloud_changes
        WHERE account_id=$1 AND sequence>$2 ORDER BY sequence LIMIT $3`, [scope.accountID, after, Math.min(limit, 20)]);
      const records = [];
      let bytes = 0;
      for (const row of rows.rows) {
        const next = record(row);
        bytes += Buffer.byteLength(JSON.stringify(next));
        if (records.length && bytes > 8 * 1024 * 1024) break;
        records.push(next);
      }
      const cursor = records.at(-1)?.sequence ?? after;
      return {epoch: state.epoch, records, cursor, hasMore: cursor < state.sequence};
    });
  }

  async reset(scope: CloudScope, epoch: string): Promise<CloudSummary> {
    return this.database.device(scope, epoch, async (client) => {
      // Device identities remain, but no request with the old epoch can mutate the new library.
      for (const table of ["cloud_return_plans", "cloud_return_days", "cloud_return_slots", "cloud_operations", "cloud_changes", "cloud_records", "cloud_uploads", "cloud_media"]) {
        await client.query(`DELETE FROM ${table} WHERE account_id=$1`, [scope.accountID]);
      }
      await client.query("UPDATE cloud_devices SET is_primary=false WHERE account_id=$1", [scope.accountID]);
      const next = randomUUID();
      await client.query("UPDATE cloud_libraries SET epoch=$2,sequence=0 WHERE account_id=$1", [scope.accountID, next]);
      return {epoch: next, sequence: 0, cards: 0, mediaBytes: 0, notificationsAvailable: this.notificationsAvailable};
    });
  }
}
