import type { FastifyInstance, FastifyRequest } from "fastify";
import rateLimit from "@fastify/rate-limit";
import type { AccountRepository } from "../accounts/account-repository.ts";
import { AuthError } from "./provider.ts";
import type { AuthenticationProvider, ProviderSession } from "./provider.ts";

export interface AuthDependencies { auth: AuthenticationProvider; accounts: AccountRepository }
const phone = { type: "string", pattern: "^\\+7[0-9]{10}$" };
const token = { type: "string", minLength: 1, maxLength: 8192 };
const body = (properties: Record<string, object>) => ({
  type: "object", required: Object.keys(properties), additionalProperties: false, properties,
});

function bearer(request: FastifyRequest): string {
  const value = request.headers.authorization;
  if (!value || !/^Bearer \S{1,8192}$/.test(value)) throw new AuthError("unauthorized");
  return value.slice(7);
}

export async function registerAuthRoutes(app: FastifyInstance, dependencies: AuthDependencies): Promise<void> {
  const { auth, accounts } = dependencies;
  await app.register(rateLimit, {
    max: 60, timeWindow: 60_000, cache: 10_000,
    errorResponseBuilder: (_request, context) => new AuthError("rate_limited", new Date(Date.now() + context.ttl).toISOString()),
  });
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
