import assert from "node:assert/strict";
import { test } from "node:test";
import { SupabaseAuthProvider } from "../src/auth/supabase-provider.ts";

const user = { id: "11111111-1111-4111-8111-111111111111", phone: "70000000001", phone_confirmed_at: "2026-01-01T00:00:00Z" };

test("Supabase verification translates the wire format without shared session state", async () => {
  const requests: Array<{ url: URL; init: RequestInit }> = [];
  const provider = new SupabaseAuthProvider("https://example.supabase.co", "test-publishable", async (url, init) => {
    requests.push({ url, init });
    return Response.json({ user, access_token: "a", refresh_token: "r", expires_in: 3600 });
  }, () => 0);
  const session = await provider.verifyCode("+70000000001", "123456");
  assert.equal(session.identity.phone, "+70000000001");
  assert.equal(session.expiresAt, "1970-01-01T01:00:00.000Z");
  assert.equal(requests[0]?.url.pathname, "/auth/v1/verify");
  assert.deepEqual(JSON.parse(String(requests[0]?.init.body)), { phone: "+70000000001", token: "123456", type: "sms" });
});

test("Supabase failures are sanitized and unconfirmed identities are rejected", async () => {
  const limited = new SupabaseAuthProvider("https://example.supabase.co", "key", async () => new Response("private upstream body", { status: 429 }));
  await assert.rejects(limited.requestCode("+70000000001"), { code: "rate_limited" });
  const unavailable = new SupabaseAuthProvider("https://example.supabase.co", "key", async () => { throw new Error("secret network detail"); });
  await assert.rejects(unavailable.refresh("secret"), { code: "provider_unavailable" });
  const unconfirmed = new SupabaseAuthProvider("https://example.supabase.co", "key", async () => Response.json({ ...user, phone_confirmed_at: null }));
  await assert.rejects(unconfirmed.authenticate("token"), { code: "unauthorized" });
});

test("contact changes reject another subject and recovery never creates a user", async () => {
  const calls: Array<{url: URL; init: RequestInit}> = [];
  const provider = new SupabaseAuthProvider("https://example.supabase.co","key",async (url,init) => {
    calls.push({url,init});
    if (url.pathname.endsWith("/verify")) return Response.json({user:{...user,id:"22222222-2222-4222-8222-222222222222"}});
    return Response.json(user);
  });
  await assert.rejects(provider.verifyContact("access","phone","+70000000002","123456"),{code:"unauthorized"});
  await provider.requestRecovery("reader@example.test");
  assert.deepEqual(JSON.parse(String(calls.at(-1)?.init.body)),{email:"reader@example.test",create_user:false});
  assert.equal(provider.deletionAvailable,false);
  await assert.rejects(provider.deleteIdentity(user.id),{code:"provider_unavailable"});
});

test("admin deletion uses server credentials and repeated missing identity is success",async () => {
  const provider = new SupabaseAuthProvider("https://example.supabase.co","public",async (url,init) => {
    assert.equal(url.pathname,`/auth/v1/admin/users/${user.id}`);
    assert.equal(init.method,"DELETE");
    assert.equal((init.headers as Record<string,string>).Authorization,"Bearer service-only");
    return new Response(null,{status:404});
  },Date.now,"service-only");
  await provider.deleteIdentity(user.id);
});

test("recovery request hides unknown emails without hiding provider outages", async () => {
  const missing = new SupabaseAuthProvider("https://example.supabase.co","key",async () => new Response(null,{status:400}));
  assert.ok((await missing.requestRecovery("missing@example.test")).retryAt);
  const down = new SupabaseAuthProvider("https://example.supabase.co","key",async () => new Response(null,{status:503}));
  await assert.rejects(down.requestRecovery("reader@example.test"),{code:"provider_unavailable"});
});
