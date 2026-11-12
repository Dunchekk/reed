import { randomUUID } from "node:crypto";
import type { Pool, PoolClient } from "pg";
import type { Account, AccountRepository, VerifiedIdentity } from "./account-repository.ts";

import { AuthError } from "../auth/provider.ts";
import type { AccountLifecycleRepository, ContactKind } from "./lifecycle.ts";

export class PostgresAccountRepository implements AccountRepository, AccountLifecycleRepository {
  private readonly database: Pick<Pool | PoolClient, "query">;

  constructor(database: Pick<Pool | PoolClient, "query">) {
    this.database = database;
  }

  async findOrCreate(identity: VerifiedIdentity): Promise<Account> {
    const result = await this.database.query<Account>(
      `INSERT INTO accounts (id, provider, provider_subject, phone, recovery_email)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (provider, provider_subject) DO UPDATE
       SET phone = EXCLUDED.phone, recovery_email = EXCLUDED.recovery_email, updated_at = now()
       WHERE accounts.deletion_status='active'
       RETURNING id, phone, recovery_email AS "recoveryEmail"`,
      [randomUUID(), identity.provider, identity.subject, identity.phone, identity.recoveryEmail ?? null],
    );
    const account = result.rows[0];
    if (!account) throw new AuthError("unauthorized");
    return account;
  }

  async rememberContact(identity: VerifiedIdentity, kind: ContactKind, value: string): Promise<void> {
    const result = await this.database.query(`INSERT INTO account_contact_changes (account_id,kind,value)
      SELECT id,$3,$4 FROM accounts WHERE provider=$1 AND provider_subject=$2 AND deletion_status='active'
      ON CONFLICT (account_id,kind) DO UPDATE SET value=EXCLUDED.value, expires_at=now()+interval '1 hour'`,
      [identity.provider, identity.subject, kind, value]);
    if (!result.rowCount) throw new AuthError("unauthorized");
  }
  async pendingContact(identity: VerifiedIdentity, kind: ContactKind): Promise<string | undefined> {
    const result = await this.database.query<{value: string}>(`SELECT c.value FROM account_contact_changes c JOIN accounts a ON a.id=c.account_id
      WHERE a.provider=$1 AND a.provider_subject=$2 AND a.deletion_status='active' AND c.kind=$3 AND c.expires_at>now()`,
      [identity.provider,identity.subject,kind]);
    return result.rows[0]?.value;
  }
  async beginDeletion(identity: VerifiedIdentity): Promise<void> {
    const result = await this.database.query(`WITH removed AS (
      UPDATE accounts SET deletion_status=CASE WHEN deletion_status='deleted' THEN 'deleted' ELSE 'pending' END,
      phone=NULL, recovery_email=NULL, updated_at=now() WHERE provider=$1 AND provider_subject=$2 RETURNING id)
      DELETE FROM account_contact_changes WHERE account_id IN (SELECT id FROM removed)`, [identity.provider, identity.subject]);
    // UPDATE is idempotent; an account must already exist before requesting deletion.
    void result;
  }
  async pendingDeletions(): Promise<{id: string; provider: string; subject: string}[]> {
    return (await this.database.query<{id: string; provider: string; subject: string}>(
      `SELECT id,provider,provider_subject AS subject FROM accounts WHERE deletion_status='pending' ORDER BY updated_at LIMIT 100`)).rows;
  }
  async finishDeletion(id: string): Promise<void> {
    await this.database.query("UPDATE accounts SET deletion_status='deleted',updated_at=now() WHERE id=$1 AND deletion_status='pending'", [id]);
  }
}
