import { randomUUID } from "node:crypto";
import type { Pool, PoolClient } from "pg";
import type { Account, AccountRepository, VerifiedIdentity } from "./account-repository.ts";

export class PostgresAccountRepository implements AccountRepository {
  private readonly database: Pick<Pool | PoolClient, "query">;

  constructor(database: Pick<Pool | PoolClient, "query">) {
    this.database = database;
  }

  async findOrCreate(identity: VerifiedIdentity): Promise<Account> {
    const result = await this.database.query<Account>(
      `INSERT INTO accounts (id, provider, provider_subject, phone)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (provider, provider_subject) DO UPDATE
       SET phone = EXCLUDED.phone, updated_at = now()
       RETURNING id, phone`,
      [randomUUID(), identity.provider, identity.subject, identity.phone],
    );
    const account = result.rows[0];
    if (!account) throw new Error("Account persistence returned no row");
    return account;
  }
}
