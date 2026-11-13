import type {FastifyInstance, FastifyRequest} from "fastify";
import rateLimit from "@fastify/rate-limit";
import {bearer} from "../auth/http-contract.ts";
import {AuthError} from "../auth/provider.ts";
import type {AuthDependencies} from "../auth/routes.ts";
import type {CloudReturns} from "../returns/service.ts";
import type {CloudLibrary} from "./library.ts";
import type {CloudRecords} from "./records.ts";
import type {CloudDevices} from "./devices.ts";
import type {CloudMedia} from "./media/service.ts";
import {chunkLimit, variant} from "./media/service.ts";
import {integer, object, string, uuid, validateManifest, validateMutation} from "./validation.ts";

export interface CloudDependencies {library: CloudLibrary; records: CloudRecords; devices: CloudDevices; media: CloudMedia; returns?: CloudReturns}

export async function registerCloudRoutes(app: FastifyInstance, auth: AuthDependencies, cloud: CloudDependencies): Promise<void> {
  const accounts = new WeakMap<FastifyRequest,string>();
  app.addHook("onRequest", async request => {
    const identity = await auth.auth.authenticate(bearer(request));
    accounts.set(request,(await auth.accounts.findOrCreate(identity)).id);
  });
  await app.register(rateLimit, {max:3000,timeWindow:60_000,cache:10_000,hook:"preHandler",
    keyGenerator: request => accounts.get(request) ?? request.ip,
    errorResponseBuilder: (_request,context) => new AuthError("rate_limited",new Date(Date.now()+context.ttl).toISOString())});
  app.addContentTypeParser("application/octet-stream",{parseAs:"buffer",bodyLimit:chunkLimit},(_request,body,done) => done(null,body));
  const account = (request: FastifyRequest) => accounts.get(request)!;
  const scope = (request: FastifyRequest) => ({accountID:account(request),deviceID:uuid(request.headers["x-reed-device"])});
  const epoch = (request: FastifyRequest) => uuid(request.headers["x-reed-epoch"]);

  if (cloud.returns) app.get("/v1/cloud/returns", request => cloud.returns!.plan(scope(request),epoch(request)));
  app.get("/v1/cloud", request => cloud.library.summary(account(request)));
  app.get<{Querystring:{after?:string;limit?:string}}>("/v1/cloud/changes", request =>
    cloud.library.pull(scope(request),epoch(request),integer(Number(request.query.after ?? 0)),integer(Number(request.query.limit ?? 20),1,100)));
  app.post("/v1/cloud/mutations",{bodyLimit:3*1024*1024}, request => cloud.records.push(scope(request),epoch(request),validateMutation(request.body)));
  app.post("/v1/cloud/reset", request => cloud.library.reset(scope(request),epoch(request)));

  app.post("/v1/cloud/devices", request => {
    const body = object(request.body);
    return cloud.devices.register(account(request),{id:uuid(body.id),name:string(body.name,480),timeZone:string(body.timeZone,100),
      ...(body.pushToken !== undefined ? {pushToken:string(body.pushToken,512)} : {})});
  });
  app.get("/v1/cloud/devices", request => cloud.devices.list(scope(request)));
  app.put<{Params:{id:string}}>("/v1/cloud/devices/:id/primary", async (request,reply) => {
    await cloud.devices.selectPrimary(scope(request),uuid(request.params.id)); return reply.code(204).send();
  });
  app.delete<{Params:{id:string}}>("/v1/cloud/devices/:id", async (request,reply) => {
    await cloud.devices.revoke(scope(request),uuid(request.params.id)); return reply.code(204).send();
  });

  app.post("/v1/cloud/uploads", request => cloud.media.begin(scope(request),epoch(request),validateManifest(request.body)));
  app.put<{Params:{id:string;variant:string};Querystring:{offset?:string};Body:Buffer}>("/v1/cloud/uploads/:id/:variant",{bodyLimit:chunkLimit}, request =>
    cloud.media.append(scope(request),epoch(request),uuid(request.params.id),variant(request.params.variant),integer(Number(request.query.offset)),request.body));
  app.post<{Params:{id:string}}>("/v1/cloud/uploads/:id/complete", async (request,reply) => {
    await cloud.media.finish(scope(request),epoch(request),uuid(request.params.id)); return reply.code(204).send();
  });
  app.get<{Params:{id:string}}>("/v1/cloud/media/:id", request => cloud.media.manifest(scope(request),epoch(request),uuid(request.params.id)));
  app.get<{Params:{id:string;variant:string};Querystring:{offset?:string;count?:string}}>("/v1/cloud/media/:id/:variant", async (request,reply) => {
    const bytes = await cloud.media.read(scope(request),epoch(request),uuid(request.params.id),variant(request.params.variant),integer(Number(request.query.offset ?? 0)),integer(Number(request.query.count ?? chunkLimit),1,chunkLimit));
    return reply.type("application/octet-stream").header("Cache-Control","private, no-store").send(bytes);
  });
}
