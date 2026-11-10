import assert from "node:assert/strict";
import { test } from "node:test";
import { DevelopmentAuthProvider } from "../src/auth/development-provider.ts";

const phone = "+70000000001";

test("development OTP requires a challenge, expires, and enforces resend/attempt limits", async () => {
  let now = 0;
  const provider = new DevelopmentAuthProvider("test", () => now);
  assert.throws(() => new DevelopmentAuthProvider("production"));
  await assert.rejects(provider.requestCode("+79999999999"), { code: "invalid_request" });
  await assert.rejects(provider.verifyCode(phone, "123456"), { code: "invalid_code" });
  await provider.requestCode(phone);
  await assert.rejects(provider.requestCode(phone), { code: "rate_limited" });
  for (let attempt = 0; attempt < 5; attempt += 1) {
    await assert.rejects(provider.verifyCode(phone, "000000"), { code: "invalid_code" });
  }
  await assert.rejects(provider.verifyCode(phone, "123456"), { code: "rate_limited" });
  now += 60_000;
  await provider.requestCode(phone);
  now += 300_000;
  await assert.rejects(provider.verifyCode(phone, "123456"), { code: "invalid_code" });
});

test("verification consumes the code; refresh rotates tokens; logout revokes both", async () => {
  let now = 0;
  const provider = new DevelopmentAuthProvider("test", () => now);
  await provider.requestCode(phone);
  const first = await provider.verifyCode(phone, "123456");
  await assert.rejects(provider.verifyCode(phone, "123456"), { code: "invalid_code" });
  assert.equal((await provider.authenticate(first.accessToken)).phone, phone);
  now += 3_600_000;
  await assert.rejects(provider.authenticate(first.accessToken), { code: "unauthorized" });
  const second = await provider.refresh(first.refreshToken);
  assert.notEqual(first.accessToken, second.accessToken);
  await assert.rejects(provider.refresh(first.refreshToken), { code: "unauthorized" });
  await provider.revoke(second.accessToken);
  await assert.rejects(provider.refresh(second.refreshToken), { code: "unauthorized" });
  await assert.rejects(provider.authenticate(second.accessToken), { code: "unauthorized" });
});
