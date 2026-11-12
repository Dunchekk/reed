import {bearer, body, phone, token} from "./http-contract.ts";
import type { FastifyInstance } from "fastify";
import { registerAccountRoutes } from "../accounts/routes.ts";
import rateLimit from "@fastify/rate-limit";
import type { AccountRepository } from "../accounts/account-repository.ts";
import { AuthError } from "./provider.ts";
import type { AuthenticationProvider, ProviderSession } from "./provider.ts";

export interface AuthDependencies { auth: AuthenticationProvider; accounts: AccountRepository; lifecycle?: {
  provider: import("../accounts/lifecycle.ts").AccountLifecycleProvider;
  repository: import("../accounts/lifecycle.ts").AccountLifecycleRepository;
} }

export async function registerAuthRoutes(app: FastifyInstance, dependencies: AuthDependencies): Promise<void> {
  const { auth, accounts } = dependencies;
  await app.register(rateLimit, {
    max: 60, timeWindow: 60_000, cache: 10_000,
    errorResponseBuilder: (_request, context) => new AuthError("rate_limited", new Date(Date.now() + context.ttl).toISOString()),
  });
  if (dependencies.lifecycle) registerAccountRoutes(app, dependencies, dependencies.lifecycle);
  const session = async (value: ProviderSession) => ({
    account: await accounts.findOrCreate(value.identity),
    accessToken: value.accessToken, refreshToken: value.refreshToken, expiresAt: value.expiresAt,
  });

  app.post<{ Body: { phone: string } }>("/v1/auth/otp", {
    schema: { body: body({ phone }) },
    config: { rateLimit: { max: 5, timeWindow: 60_000 } },
  }, async (request, reply) => reply.code(202).send(await auth.requestCode(request.body.phone)));

  app.post<{ Body: { phone: string; code: string } }>("/v1/auth/verify", {
    schema: { body: body({ phone, code: { type: "string", pattern: "^[0-9]{6}$" } }) },
  }, async (request) => session(await auth.verifyCode(request.body.phone, request.body.code)));

  app.post<{ Body: { refreshToken: string } }>("/v1/auth/refresh", {
    schema: { body: body({ refreshToken: token }) },
  }, async (request) => session(await auth.refresh(request.body.refreshToken)));

  app.get("/v1/account", async (request) => accounts.findOrCreate(await auth.authenticate(bearer(request))));
  app.post("/v1/auth/logout", async (request, reply) => {
    await auth.revoke(bearer(request));
    return reply.code(204).send();
  });
}
