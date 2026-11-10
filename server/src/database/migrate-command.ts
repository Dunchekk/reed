import { Pool } from "pg";
import { migrate } from "./migrate.ts";

if (!process.env.DATABASE_URL) throw new Error("DATABASE_URL is required");
const pool = new Pool({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 5_000 });
try {
  await migrate(pool, new URL("../../migrations/", import.meta.url));
  console.info("Database migrations are current");
} finally {
  await pool.end();
}
