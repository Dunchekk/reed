import type {FastifyRequest} from "fastify";
import {AuthError} from "./provider.ts";

export const phone = { type: "string", pattern: "^\\+7[0-9]{10}$" };
export const token = { type: "string", minLength: 1, maxLength: 8192 };
export const body = (properties: Record<string, object>) => ({
  type: "object", required: Object.keys(properties), additionalProperties: false, properties,
});

export function bearer(request: FastifyRequest): string {
  const value = request.headers.authorization;
  if (!value || !/^Bearer \S{1,8192}$/.test(value)) throw new AuthError("unauthorized");
  return value.slice(7);
}

