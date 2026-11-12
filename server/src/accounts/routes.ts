import type { FastifyInstance } from "fastify";
import { bearer, body, phone } from "../auth/http-contract.ts";
import type { AuthDependencies } from "../auth/routes.ts";
import { AuthError } from "../auth/provider.ts";
import { ensureSameIdentity } from "./lifecycle.ts";
import type { ContactKind } from "./lifecycle.ts";

const email = {type: "string", maxLength: 254, pattern: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$"};
const code = {type: "string", pattern: "^[0-9]{6}$"};
export function registerAccountRoutes(app: FastifyInstance, dependencies: AuthDependencies, lifecycle: NonNullable<AuthDependencies["lifecycle"]>) {
  const {auth, accounts} = dependencies, {provider, repository} = lifecycle;
  const identified = async (token: string) => {
    const identity = await auth.authenticate(token);
    const account = await accounts.findOrCreate(identity);
    return {identity, account};
  };
  app.get("/v1/account/profile", async (request) => ({account:(await identified(bearer(request))).account, deletionAvailable: provider.deletionAvailable}));
  for (const kind of ["phone", "email"] as ContactKind[]) {
    app.post<{Body: {value: string}}>(`/v1/account/${kind}/request`, {
      schema: {body: body({value: kind === "phone" ? phone : email})},
      config: {rateLimit: {max: 5, timeWindow: 60_000}},
    }, async (request, reply) => {
      const token = bearer(request), {identity} = await identified(token);
      const value = kind === "email" ? request.body.value.toLowerCase() : request.body.value;
      const result = await provider.requestContact(token,kind,value);
      await repository.rememberContact(identity,kind,value);
      return reply.code(202).send(result);
    });
    app.post<{Body: {code: string}}>(`/v1/account/${kind}/verify`, {schema: {body: body({code})}}, async (request) => {
      const token = bearer(request), {identity} = await identified(token);
      const value = await repository.pendingContact(identity,kind);
      if (!value) throw new AuthError("invalid_code");
      const updated = await provider.verifyContact(token,kind,value,request.body.code);
      ensureSameIdentity(identity,updated);
      return {account: await accounts.findOrCreate(updated), confirmed: (kind === "phone" ? updated.phone : updated.recoveryEmail) === value};
    });
  }
  app.post<{Body: {email: string}}>("/v1/auth/recovery/request", {
    schema: {body: body({email})}, config: {rateLimit: {max: 5, timeWindow: 60_000}},
  }, async (request, reply) => reply.code(202).send(await provider.requestRecovery(request.body.email.toLowerCase())));
  app.post<{Body: {email: string; code: string}}>("/v1/auth/recovery/verify", {schema: {body: body({email,code})}}, async (request) => {
    const result = await provider.verifyRecovery(request.body.email.toLowerCase(),request.body.code);
    return {account: await accounts.findOrCreate(result.identity), accessToken: result.accessToken, refreshToken: result.refreshToken, expiresAt: result.expiresAt};
  });
  app.delete("/v1/account", async (request, reply) => {
    if (!provider.deletionAvailable) throw new AuthError("provider_unavailable");
    const identity = await auth.authenticate(bearer(request));
    await repository.beginDeletion(identity);
    return reply.code(202).send({status: "deletion_pending"});
  });
}
