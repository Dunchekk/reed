import { randomBytes } from "node:crypto";
import type { VerifiedIdentity } from "../accounts/account-repository.ts";
import { AuthError } from "./provider.ts";
import type { AuthenticationProvider, ProviderSession } from "./provider.ts";

interface Challenge { expiresAt: number; retryAt: number; attempts: number }
interface StoredSession { value: ProviderSession; refreshExpiresAt: number }

/** Isolated synthetic auth. Never a fallback for a failed real provider. */
export class DevelopmentAuthProvider implements AuthenticationProvider {
  private readonly challenges = new Map<string, Challenge>();
  private readonly access = new Map<string, StoredSession>();
  private readonly refreshTokens = new Map<string, StoredSession>();
  private readonly now: () => number;

  constructor(environment: string, now: () => number = Date.now) {
    if (environment !== "development" && environment !== "test") {
      throw new Error("Development authentication is forbidden outside development/test");
    }
    this.now = now;
  }

  async requestCode(phone: string): Promise<{ retryAt: string }> {
    if (!/^\+700000000\d{2}$/.test(phone)) throw new AuthError("invalid_request");
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
    this.prune();
    const challenge = this.challenges.get(phone);
    if (!challenge) throw new AuthError("invalid_code");
    if (challenge.attempts >= 5) {
      throw new AuthError("rate_limited", new Date(challenge.retryAt).toISOString());
    }
    challenge.attempts += 1;
    if (code !== "123456") throw new AuthError("invalid_code");
    this.challenges.delete(phone);
    return this.issue({ provider: "development", subject: phone, phone });
  }

  async refresh(refreshToken: string): Promise<ProviderSession> {
    this.prune();
    const session = this.refreshTokens.get(refreshToken);
    if (!session) throw new AuthError("unauthorized");
    this.remove(session);
    return this.issue(session.value.identity);
  }

  async authenticate(accessToken: string): Promise<VerifiedIdentity> {
    this.prune();
    const session = this.access.get(accessToken);
    if (!session || Date.parse(session.value.expiresAt) <= this.now()) throw new AuthError("unauthorized");
    return session.value.identity;
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
