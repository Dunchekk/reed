import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import { Pool } from "pg";
import { migrate } from "../src/database/migrate.ts";
import { PostgresAccountRepository } from "../src/accounts/postgres-account-repository.ts";

test("PostgreSQL migrations are repeatable and verified subjects retain their account", {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const pool = new Pool({ connectionString: process.env.TEST_DATABASE_URL, max: 2 });
  try {
    const directory = new URL("../migrations/", import.meta.url);
    await migrate(pool, directory);
    await migrate(pool, directory);
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      const repository = new PostgresAccountRepository(client);
      const identity = { provider: "test", subject: randomUUID(), phone: "+70000000001" };
      const first = await repository.findOrCreate(identity);
      const again = await repository.findOrCreate({ ...identity, phone: "+70000000002" });
      assert.equal(first.id, again.id);
      assert.equal(again.phone, "+70000000002");
      const other = await repository.findOrCreate({ ...identity, subject: randomUUID() });
      assert.notEqual(first.id, other.id);
    } finally {
      await client.query("ROLLBACK");
      client.release();
    }
  } finally {
    await pool.end();
  }
});
