import { buildApp } from "./app.ts";
import { loadConfig } from "./config.ts";
import { Pool } from "pg";
import { PostgresAccountRepository } from "./accounts/postgres-account-repository.ts";
import { DevelopmentAuthProvider } from "./auth/development-provider.ts";
import { SupabaseAuthProvider } from "./auth/supabase-provider.ts";

const config = loadConfig(process.env);
if (!process.env.DATABASE_URL) throw new Error("DATABASE_URL is required");
const auth = config.authProvider === "development"
  ? new DevelopmentAuthProvider(config.environment)
  : new SupabaseAuthProvider(process.env.SUPABASE_URL ?? "", process.env.SUPABASE_PUBLISHABLE_KEY ?? "");
const database = new Pool({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 5_000, max: 10 });
const app = buildApp({ auth, accounts: new PostgresAccountRepository(database) });
app.addHook("onClose", () => database.end());
database.on("error", () => app.log.error("Database connection failed"));

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => {
    void app.close().catch(() => { process.exitCode = 1; });
  });
}

try {
  await app.listen({ host: config.host, port: config.port });
} catch {
  app.log.error("Server failed to start");
  process.exitCode = 1;
  await app.close();
}
