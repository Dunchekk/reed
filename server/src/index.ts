import { buildApp } from "./app.ts";
import { loadConfig } from "./config.ts";

const config = loadConfig(process.env);
const app = buildApp();

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
