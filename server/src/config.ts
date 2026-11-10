export interface Config {
  environment: "development" | "test" | "production";
  host: string;
  port: number;
  authProvider: "development" | "supabase";
}

export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const environment = env.NODE_ENV ?? "development";
  if (!["development", "test", "production"].includes(environment)) {
    throw new Error("NODE_ENV must be development, test, or production");
  }
  const authProvider = env.AUTH_PROVIDER ?? "development";
  if (authProvider !== "development" && authProvider !== "supabase") {
    throw new Error("AUTH_PROVIDER must be development or supabase");
  }
  if (environment === "production" && authProvider === "development") {
    throw new Error("Development authentication is forbidden in production");
  }
  const port = Number(env.PORT ?? "3000");
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("PORT must be an integer between 1 and 65535");
  }
  return {
    environment: environment as Config["environment"],
    authProvider,
    host: env.HOST ?? "127.0.0.1",
    port,
  };
}
