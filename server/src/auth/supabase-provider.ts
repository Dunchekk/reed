import type { VerifiedIdentity } from "../accounts/account-repository.ts";
import { AuthError } from "./provider.ts";
import type { AuthenticationProvider, AuthErrorCode, ProviderSession } from "./provider.ts";

type Fetch = (url: URL, init: RequestInit) => Promise<Response>;
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new AuthError("provider_unavailable");
  return value as Record<string, unknown>;
}

/** Stateless adapter: credentials are explicit and never shared between users. */
export class SupabaseAuthProvider implements AuthenticationProvider {
  private readonly base: URL;
  private readonly key: string;
  private readonly fetcher: Fetch;
  private readonly now: () => number;

  constructor(url: string, key: string, fetcher: Fetch = fetch, now: () => number = Date.now) {
    const project = new URL(url);
    if (project.protocol !== "https:" || project.username || project.password || !key) {
      throw new Error("Supabase requires an HTTPS project URL and a publishable key");
    }
    this.base = new URL("/auth/v1/", project);
    this.key = key;
    this.fetcher = fetcher;
    this.now = now;
  }

  async requestCode(phone: string): Promise<{ retryAt: string }> {
    await this.request("otp", "POST", { phone, create_user: true, channel: "sms" }, undefined, "provider_unavailable");
    return { retryAt: new Date(this.now() + 60_000).toISOString() };
  }

  async verifyCode(phone: string, code: string): Promise<ProviderSession> {
    return this.session(await this.request("verify", "POST", { phone, token: code, type: "sms" }, undefined, "invalid_code"));
  }

  async refresh(refreshToken: string): Promise<ProviderSession> {
    return this.session(await this.request("token?grant_type=refresh_token", "POST", { refresh_token: refreshToken }, undefined, "unauthorized"));
  }

  async authenticate(accessToken: string): Promise<VerifiedIdentity> {
    return this.identity(await this.request("user", "GET", undefined, accessToken, "unauthorized"));
  }

  async revoke(accessToken: string): Promise<void> {
    await this.request("logout?scope=local", "POST", undefined, accessToken, "unauthorized");
  }

  private identity(value: unknown): VerifiedIdentity {
    const user = object(value);
    const phone = typeof user.phone === "string" ? "+" + user.phone.replace(/^\+/, "") : "";
    if (typeof user.id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(user.id)
      || !/^\+7\d{10}$/.test(phone) || typeof user.phone_confirmed_at !== "string" || !user.phone_confirmed_at) {
      throw new AuthError("unauthorized");
    }
    return { provider: "supabase", subject: user.id, phone };
  }

  private session(value: unknown): ProviderSession {
    const data = object(value);
    const expiresAt = typeof data.expires_at === "number" ? data.expires_at * 1000
      : typeof data.expires_in === "number" ? this.now() + data.expires_in * 1000 : NaN;
    if (typeof data.access_token !== "string" || !data.access_token
      || typeof data.refresh_token !== "string" || !data.refresh_token
      || !Number.isFinite(expiresAt) || expiresAt <= this.now() || expiresAt > this.now() + 31 * 86_400_000) {
      throw new AuthError("provider_unavailable");
    }
    return {
      identity: this.identity(data.user), accessToken: data.access_token,
      refreshToken: data.refresh_token, expiresAt: new Date(expiresAt).toISOString(),
    };
  }

  private async request(path: string, method: string, body: unknown, token: string | undefined, invalid: AuthErrorCode): Promise<unknown> {
    try {
      const headers: Record<string, string> = { apikey: this.key, "Content-Type": "application/json" };
      if (token) headers.Authorization = `Bearer ${token}`;
      const response = await this.fetcher(new URL(path, this.base), {
        method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(10_000), redirect: "error",
      });
      if (response.status === 429) {
        const seconds = Number(response.headers.get("retry-after") ?? "60");
        const delay = Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds, 3600) : 60;
        throw new AuthError("rate_limited", new Date(this.now() + delay * 1000).toISOString());
      }
      if (!response.ok) throw new AuthError(response.status >= 500 ? "provider_unavailable" : invalid);
      if (response.status === 204) return undefined;
      return await response.json();
    } catch (error) {
      if (error instanceof AuthError) throw error;
      throw new AuthError("provider_unavailable");
    }
  }
}
