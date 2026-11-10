import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import { buildApp } from "../src/app.ts";
import { DevelopmentAuthProvider } from "../src/auth/development-provider.ts";
import type { Account, AccountRepository } from "../src/accounts/account-repository.ts";

function repository(): AccountRepository {
  const accounts = new Map<string, Account>();
  return { async findOrCreate(identity) {
    const key = `${identity.provider}:${identity.subject}`;
    const account = accounts.get(key) ?? { id: randomUUID(), phone: identity.phone };
    accounts.set(key, account);
    return account;
  } };
}

test("HTTP sign-in keeps accounts isolated, validates input, and revokes the session", async (t) => {
  const app = buildApp({ auth: new DevelopmentAuthProvider("test"), accounts: repository() });
  t.after(() => app.close());
  const phone = "+70000000001";
  assert.equal((await app.inject({ method: "POST", url: "/v1/auth/otp", payload: { phone: "invalid" } })).statusCode, 400);
  assert.equal((await app.inject({ method: "GET", url: "/v1/account" })).statusCode, 401);
  assert.equal((await app.inject({ method: "POST", url: "/v1/auth/otp", payload: { phone } })).statusCode, 202);
  const verified = await app.inject({ method: "POST", url: "/v1/auth/verify", payload: { phone, code: "123456" } });
  assert.equal(verified.statusCode, 200);
  const session = verified.json();
  const headers = { authorization: `Bearer ${session.accessToken}` };
  assert.deepEqual((await app.inject({ method: "GET", url: "/v1/account", headers })).json(), session.account);
  const refreshed = await app.inject({ method: "POST", url: "/v1/auth/refresh", payload: { refreshToken: session.refreshToken } });
  assert.equal(refreshed.statusCode, 200);
  assert.equal(refreshed.json().account.id, session.account.id);
  assert.equal((await app.inject({ method: "GET", url: "/v1/account", headers })).statusCode, 401);
  const nextHeaders = { authorization: `Bearer ${refreshed.json().accessToken}` };
  assert.equal((await app.inject({ method: "POST", url: "/v1/auth/logout", headers: nextHeaders })).statusCode, 204);
  assert.equal((await app.inject({ method: "GET", url: "/v1/account", headers: nextHeaders })).statusCode, 401);
});

test("IP rate limiting uses the same safe error contract", async (t) => {
  const app = buildApp({ auth: new DevelopmentAuthProvider("test"), accounts: repository() });
  t.after(() => app.close());
  for (let i = 0; i < 5; i += 1) {
    await app.inject({ method: "POST", url: "/v1/auth/otp", payload: { phone: `+7000000000${i}` } });
  }
  const response = await app.inject({ method: "POST", url: "/v1/auth/otp", payload: { phone: "+70000000009" } });
  assert.equal(response.statusCode, 429);
  assert.equal(response.json().error.code, "rate_limited");
});
