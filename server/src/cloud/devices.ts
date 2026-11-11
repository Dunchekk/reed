import {CloudDatabase} from "./database.ts";
import {CloudError} from "./contracts.ts";
import type {CloudScope, Device} from "./contracts.ts";
import {uuid} from "./validation.ts";
import type {PoolClient} from "pg";

function device(row: Record<string, unknown>): Device {
  return {id: String(row.id), name: String(row.name), timeZone: String(row.time_zone),
    isPrimary: Boolean(row.is_primary), lastSeenAt: (row.last_seen_at as Date).toISOString()};
}

export class CloudDevices {
  readonly database: CloudDatabase;
  constructor(database: CloudDatabase) { this.database = database; }

  async register(accountID: string, input: {id: string; name: string; timeZone: string; pushToken?: string}): Promise<Device> {
    const id = uuid(input.id);
    if (typeof input.name !== "string" || !input.name.trim() || input.name.length > 120 ||
        typeof input.timeZone !== "string" || input.timeZone.length > 100) throw new CloudError("invalid_record");
    try { new Intl.DateTimeFormat("en", {timeZone: input.timeZone}).format(); }
    catch { throw new CloudError("invalid_record"); }
    if (input.pushToken !== undefined && !/^[a-fA-F0-9]{64,512}$/.test(input.pushToken)) throw new CloudError("invalid_record");
    return this.database.account(accountID, async client => {
      const existing = (await client.query("SELECT * FROM cloud_devices WHERE account_id=$1 AND id=$2", [accountID,id])).rows[0];
      // Rejoining after revocation requires a new device identity, chosen explicitly on the client.
      if (existing?.revoked_at) throw new CloudError("device_revoked");
      const counts = (await client.query(`SELECT COUNT(*)::int AS total,
        COUNT(*) FILTER (WHERE revoked_at IS NULL)::int AS active FROM cloud_devices WHERE account_id=$1`, [accountID])).rows[0];
      if (!existing && counts.active >= 20) throw new CloudError("quota_exceeded");
      const result = await client.query(`INSERT INTO cloud_devices(account_id,id,name,time_zone,is_primary,push_token)
        VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(account_id,id) DO UPDATE SET
        name=EXCLUDED.name,time_zone=EXCLUDED.time_zone,push_token=COALESCE(EXCLUDED.push_token,cloud_devices.push_token),last_seen_at=now() RETURNING *`,
        [accountID,id,input.name.trim(),input.timeZone,counts.total === 0,input.pushToken?.toLowerCase() ?? null]);
      return device(result.rows[0]);
    });
  }

  async list(scope: CloudScope): Promise<Device[]> {
    return this.database.account(scope.accountID, async client => {
      await this.requireActive(client,scope);
      return (await client.query("SELECT * FROM cloud_devices WHERE account_id=$1 AND revoked_at IS NULL ORDER BY last_seen_at DESC,id", [scope.accountID])).rows.map(device);
    });
  }

  async selectPrimary(scope: CloudScope, targetID: string): Promise<void> {
    const target = uuid(targetID);
    await this.database.account(scope.accountID, async client => {
      await this.requireActive(client,scope);
      if (!(await client.query("SELECT id FROM cloud_devices WHERE account_id=$1 AND id=$2 AND revoked_at IS NULL", [scope.accountID,target])).rowCount) throw new CloudError("not_found");
      await client.query("UPDATE cloud_devices SET is_primary=false WHERE account_id=$1 AND is_primary=true", [scope.accountID]);
      await client.query("UPDATE cloud_devices SET is_primary=true WHERE account_id=$1 AND id=$2", [scope.accountID,target]);
    });
  }

  async revoke(scope: CloudScope, targetID: string): Promise<void> {
    const target = uuid(targetID);
    await this.database.account(scope.accountID, async client => {
      // Retrying a self-revocation is safe even if its first response was lost.
      if (target !== scope.deviceID.toLowerCase()) await this.requireActive(client,scope);
      await client.query("UPDATE cloud_devices SET revoked_at=COALESCE(revoked_at,now()),is_primary=false,push_token=NULL WHERE account_id=$1 AND id=$2", [scope.accountID,target]);
    });
  }

  private async requireActive(client: PoolClient, scope: CloudScope): Promise<void> {
    if (!(await client.query("SELECT id FROM cloud_devices WHERE account_id=$1 AND id=$2 AND revoked_at IS NULL", [scope.accountID,scope.deviceID])).rowCount) throw new CloudError("device_revoked");
  }
}
