import type { AccountLifecycleProvider, ContactKind } from "../accounts/lifecycle.ts";
import { MemoryDevelopmentIdentities } from "./development-identities.ts";
import type { DevelopmentIdentityStore } from "./development-identities.ts";
import { randomBytes } from "node:crypto";
import type { VerifiedIdentity } from "../accounts/account-repository.ts";
import { AuthError } from "./provider.ts";
import type { AuthenticationProvider, ProviderSession } from "./provider.ts";

interface Challenge { expiresAt: number; retryAt: number; attempts: number }
interface StoredSession { value: ProviderSession; refreshExpiresAt: number }

/** Isolated synthetic auth. Never a fallback for a failed real provider. */
export class DevelopmentAuthProvider implements AuthenticationProvider, AccountLifecycleProvider {
  readonly deletionAvailable = true;
  private readonly challenges = new Map<string, Challenge>();
  private readonly access = new Map<string, StoredSession>();
  private readonly refreshTokens = new Map<string, StoredSession>();
  private readonly identities: DevelopmentIdentityStore;
  private readonly now: () => number;

  constructor(environment: string, now: () => number = Date.now, identities: DevelopmentIdentityStore = new MemoryDevelopmentIdentities()) {
    if (environment !== "development" && environment !== "test") {
      throw new Error("Development authentication is forbidden outside development/test");
    }
    this.now = now;
    this.identities = identities;
  }

  async requestCode(phone: string): Promise<{ retryAt: string }> {
    if (!/^\+700000000\d{2}$/.test(phone)) throw new AuthError("invalid_request");
    return this.challenge(phone);
  }

  private async challenge(phone: string): Promise<{retryAt: string}> {
    this.prune();
    const previous = this.challenges.get(phone);
    if (previous && previous.retryAt > this.now()) {
      throw new AuthError("rate_limited", new Date(previous.retryAt).toISOString());
    }
    const retryAt = this.now() + 60_000;
    this.challenges.set(phone, { expiresAt: this.now() + 300_000, retryAt, attempts: 0 });
    return { retryAt: new Date(retryAt).toISOString() };
  }

  async verifyCode(phone: string, code: string): Promise<ProviderSession> {
    this.consume(phone, code);
    return this.issue(await this.identities.forPhone(phone));
  }
  private consume(key: string, code: string): void {
    this.prune();
    const challenge = this.challenges.get(key);
    if (!challenge) throw new AuthError("invalid_code");
    if (challenge.attempts >= 5) throw new AuthError("rate_limited", new Date(challenge.retryAt).toISOString());
    challenge.attempts += 1;
    if (code !== "123456") throw new AuthError("invalid_code");
    this.challenges.delete(key);
  }
  async requestContact(token: string, kind: ContactKind, value: string) {
    const identity = await this.authenticate(token);
    if (kind === "phone" ? !/^\+700000000\d{2}$/.test(value) : !/^[a-z0-9._+-]+@example\.test$/.test(value)) throw new AuthError("invalid_request");
    return this.challenge(`${identity.subject}:${kind}:${value}`);
  }
  async verifyContact(token: string, kind: ContactKind, value: string, code: string) {
    const identity = await this.authenticate(token);
    this.consume(`${identity.subject}:${kind}:${value}`, code);
    return this.identities.update(identity.subject, kind, value);
  }
  async requestRecovery(email: string) {
    if (!/^[a-z0-9._+-]+@example\.test$/.test(email)) throw new AuthError("invalid_request");
    return this.challenge(`recovery:${email}`);
  }
  async verifyRecovery(email: string, code: string) {
    this.consume(`recovery:${email}`, code);
    const identity = await this.identities.forEmail(email);
    if (!identity) throw new AuthError("invalid_code");
    return this.issue(identity);
  }
  async deleteIdentity(subject: string) {
    await this.identities.remove(subject);
    for (const session of this.access.values()) if (session.value.identity.subject === subject) this.remove(session);
  }

  async refresh(refreshToken: string): Promise<ProviderSession> {
    this.prune();
    const session = this.refreshTokens.get(refreshToken);
    if (!session) throw new AuthError("unauthorized");
    this.remove(session);
    const identity = await this.identities.get(session.value.identity.subject);
    if (!identity) throw new AuthError("unauthorized");
    return this.issue(identity);
  }

  async authenticate(accessToken: string): Promise<VerifiedIdentity> {
    this.prune();
    const session = this.access.get(accessToken);
    if (!session || Date.parse(session.value.expiresAt) <= this.now()) throw new AuthError("unauthorized");
    const identity = await this.identities.get(session.value.identity.subject);
    if (!identity) throw new AuthError("unauthorized");
    return identity;
  }

  async revoke(accessToken: string): Promise<void> {
    const session = this.access.get(accessToken);
    if (session) this.remove(session);
  }

  private issue(identity: VerifiedIdentity): ProviderSession {
    this.prune();
    if (this.access.size >= 1_000) throw new AuthError("rate_limited");
    const value: ProviderSession = {
      identity,
      accessToken: randomBytes(32).toString("base64url"),
      refreshToken: randomBytes(32).toString("base64url"),
      expiresAt: new Date(this.now() + 3_600_000).toISOString(),
    };
    const stored = { value, refreshExpiresAt: this.now() + 30 * 86_400_000 };
    this.access.set(value.accessToken, stored);
    this.refreshTokens.set(value.refreshToken, stored);
    return value;
  }

  private remove(session: StoredSession): void {
    this.access.delete(session.value.accessToken);
    this.refreshTokens.delete(session.value.refreshToken);
  }

  private prune(): void {
    for (const [phone, challenge] of this.challenges) {
      if (challenge.expiresAt <= this.now()) this.challenges.delete(phone);
    }
    for (const session of this.access.values()) {
      if (session.refreshExpiresAt <= this.now()) this.remove(session);
    }
  }
}
