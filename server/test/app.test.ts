import assert from "node:assert/strict";
import { test } from "node:test";
import { buildApp } from "../src/app.ts";
import { loadConfig } from "../src/config.ts";

test("health responds without opening a network port", async (t) => {
  const app = buildApp();
  t.after(() => app.close());
  const response = await app.inject({ method: "GET", url: "/health" });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json(), { status: "ok" });
});

test("development authentication cannot be enabled in production", () => {
  assert.throws(() => loadConfig({ NODE_ENV: "production" }), /forbidden/);
  assert.throws(() => loadConfig({ PORT: "NaN" }), /PORT/);
});
