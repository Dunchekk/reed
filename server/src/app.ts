import Fastify from "fastify";

export function buildApp() {
  const app = Fastify({
    bodyLimit: 64 * 1024,
    logger: {
      level: "info",
      redact: ["req.headers.authorization", "req.headers.cookie", "res.headers.set-cookie"],
      // Request URLs and bodies can contain personal data; log safe lifecycle events only.
      serializers: { req: (request) => ({ method: request.method, id: request.id }) },
    },
    disableRequestLogging: true,
  });

  app.get("/health", async () => ({ status: "ok" }));

  app.setErrorHandler((error, request, reply) => {
    if (typeof error === "object" && error !== null && "validation" in error) {
      return reply.code(400).send({ error: { code: "invalid_request", message: "Некорректный запрос" } });
    }
    const status = typeof error === "object" && error !== null && "statusCode" in error
      ? error.statusCode : undefined;
    if (typeof status === "number" && status >= 400 && status < 500) {
      return reply.code(status).send({ error: { code: "invalid_request", message: "Запрос отклонён" } });
    }
    request.log.error({ requestId: request.id }, "Request failed");
    return reply.code(500).send({ error: { code: "internal_error", message: "Внутренняя ошибка сервера" } });
  });
  return app;
}
