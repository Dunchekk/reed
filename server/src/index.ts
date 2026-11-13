import {configuredAPNs} from "./notifications/apns.ts";
import {CloudPushWorker} from "./notifications/worker.ts";
import {CloudReturns} from "./returns/service.ts";
import {CloudMaintenance} from "./cloud/maintenance.ts";
import {isAbsolute} from "node:path";
import {CloudDatabase} from "./cloud/database.ts";
import {CloudLibrary} from "./cloud/library.ts";
import {CloudRecords} from "./cloud/records.ts";
import {CloudDevices} from "./cloud/devices.ts";
import {CloudMedia} from "./cloud/media/service.ts";
import {FileObjectStore} from "./cloud/media/file-object-store.ts";
import { PostgresDevelopmentIdentities } from "./auth/development-identities.ts";
import { AccountDeletionWorker } from "./accounts/lifecycle.ts";
import { buildApp } from "./app.ts";
import { loadConfig } from "./config.ts";
import { Pool } from "pg";
import { PostgresAccountRepository } from "./accounts/postgres-account-repository.ts";
import { DevelopmentAuthProvider } from "./auth/development-provider.ts";
import { SupabaseAuthProvider } from "./auth/supabase-provider.ts";

const config = loadConfig(process.env);
if (!process.env.DATABASE_URL) throw new Error("DATABASE_URL is required");
const database = new Pool({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 5_000, max: 10 });
const auth = config.authProvider === "development"
  ? new DevelopmentAuthProvider(config.environment, Date.now, new PostgresDevelopmentIdentities(database))
  : new SupabaseAuthProvider(process.env.SUPABASE_URL ?? "", process.env.SUPABASE_PUBLISHABLE_KEY ?? "", fetch, Date.now, process.env.SUPABASE_SERVICE_ROLE_KEY);
const accounts = new PostgresAccountRepository(database);
const cloudDatabase = new CloudDatabase(database);
if(config.environment === "production" && (!process.env.CLOUD_STORAGE_PATH || !isAbsolute(process.env.CLOUD_STORAGE_PATH))) throw new Error("Production requires an absolute CLOUD_STORAGE_PATH");
const objects = new FileObjectStore(process.env.CLOUD_STORAGE_PATH ?? ".local/cloud-objects");
const pushProvider = await configuredAPNs(process.env);
const cloud = {library:new CloudLibrary(cloudDatabase,!!pushProvider),records:new CloudRecords(cloudDatabase),
  returns:new CloudReturns(cloudDatabase),devices:new CloudDevices(cloudDatabase),media:new CloudMedia(cloudDatabase,objects)};
const app = buildApp({auth, accounts, lifecycle: {provider: auth, repository: accounts}},cloud);
const pushWorker = new CloudPushWorker(cloudDatabase,cloud.returns,pushProvider);
const refreshReturns = () => pushWorker.run().catch(() => app.log.error("Cloud returns will retry"));
const returnsTimer = setInterval(() => { void refreshReturns(); }, 30_000).unref();
app.addHook("onReady", async () => { await refreshReturns(); });
const maintenance = new CloudMaintenance(cloudDatabase,objects);
const maintainCloud = () => maintenance.run().catch(() => app.log.error("Cloud cleanup will retry"));
const maintenanceTimer = setInterval(() => { void maintainCloud(); }, 3600_000).unref();
app.addHook("onReady", async () => { await maintainCloud(); });
const deletion = new AccountDeletionWorker(accounts,auth,config.authProvider,id => maintenance.deleteAccount(id));
const retryDeletion = () => deletion.run().catch(() => app.log.error("Account deletion will retry"));
const deletionTimer = setInterval(() => { void retryDeletion(); }, 30_000).unref();
app.addHook("onReady", async () => { await retryDeletion(); });
app.addHook("onClose", async () => { clearInterval(deletionTimer); clearInterval(returnsTimer); clearInterval(maintenanceTimer); await maintenance.run().catch(() => {}); await pushWorker.run().catch(() => {}); await deletion.run().catch(() => {}); await database.end(); });
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
