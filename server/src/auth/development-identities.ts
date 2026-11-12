import { randomUUID } from "node:crypto";
import type { Pool, PoolClient } from "pg";
import type { VerifiedIdentity } from "../accounts/account-repository.ts";
import type { ContactKind } from "../accounts/lifecycle.ts";
import { AuthError } from "./provider.ts";

export interface DevelopmentIdentityStore {
  forPhone(phone: string): Promise<VerifiedIdentity>;
  get(subject: string): Promise<VerifiedIdentity | undefined>;
  forEmail(email: string): Promise<VerifiedIdentity | undefined>;
  update(subject: string, kind: ContactKind, value: string): Promise<VerifiedIdentity>;
  remove(subject: string): Promise<void>;
}
export class MemoryDevelopmentIdentities implements DevelopmentIdentityStore {
  private readonly identities = new Map<string, VerifiedIdentity>();
  async forPhone(phone: string) {
    const existing = [...this.identities.values()].find((value) => value.phone === phone);
    if (existing) return existing;
    const identity = { provider: "development", subject: randomUUID(), phone };
    this.identities.set(identity.subject, identity); return identity;
  }
  async get(subject: string) { return this.identities.get(subject); }
  async forEmail(email: string) { return [...this.identities.values()].find((value) => value.recoveryEmail === email); }
  async update(subject: string, kind: ContactKind, value: string) {
    const original = await this.get(subject);
    if (!original) throw new AuthError("unauthorized");
    if ([...this.identities.values()].some((identity) => identity.subject !== subject && (kind === "phone" ? identity.phone : identity.recoveryEmail) === value)) throw new AuthError("invalid_request");
    const updated = { ...original, ...(kind === "phone" ? {phone: value} : {recoveryEmail: value}) };
    this.identities.set(subject, updated); return updated;
  }
  async remove(subject: string) { this.identities.delete(subject); }
}
export class PostgresDevelopmentIdentities implements DevelopmentIdentityStore {
  private readonly database: Pick<Pool | PoolClient, "query">;
  constructor(database: Pick<Pool | PoolClient, "query">) { this.database = database; }
  private async find(column: "subject" | "email", value: string) {
    return (await this.database.query<VerifiedIdentity>(`SELECT 'development' AS provider,subject,phone,email AS "recoveryEmail" FROM development_identities WHERE ${column}=$1`, [value])).rows[0];
  }
  async get(subject: string) { return this.find("subject", subject); }
  async forEmail(email: string) { return this.find("email", email); }
  async forPhone(phone: string) {
    const result = await this.database.query<VerifiedIdentity>(`INSERT INTO development_identities(subject,phone) VALUES ($1,$2)
      ON CONFLICT(phone) DO UPDATE SET phone=EXCLUDED.phone RETURNING 'development' AS provider,subject,phone,email AS "recoveryEmail"`, [randomUUID(),phone]);
    return result.rows[0]!;
  }
  async update(subject: string, kind: ContactKind, value: string) {
    try {
      const result = await this.database.query<VerifiedIdentity>(`UPDATE development_identities SET ${kind === "phone" ? "phone" : "email"}=$2
        WHERE subject=$1 RETURNING 'development' AS provider,subject,phone,email AS "recoveryEmail"`, [subject,value]);
      if (!result.rows[0]) throw new AuthError("unauthorized");
      return result.rows[0];
    } catch (error) {
      if (error && typeof error === "object" && "code" in error && error.code === "23505") throw new AuthError("invalid_request");
      throw error;
    }
  }
  async remove(subject: string) { await this.database.query("DELETE FROM development_identities WHERE subject=$1", [subject]); }
}
