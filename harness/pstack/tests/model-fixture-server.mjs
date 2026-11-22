import { createServer } from "node:http";

/** Minimal local HTTP server; the handler receives a recordFailure callback. */
export const createModelFixtureServer = async (handler) => {
  let failure;
  const recordFailure = (cause) => {
    failure ??= cause instanceof Error ? cause.message : String(cause);
    return failure;
  };
  const server = createServer((request, response) => {
    Promise.resolve(handler(request, response, recordFailure)).catch(
      (cause) => {
        recordFailure(cause);
        response.statusCode = 500;
        response.end();
      },
    );
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return {
    origin: `http://127.0.0.1:${port}`,
    get failure() {
      return failure;
    },
    close: () =>
      new Promise((resolve) => {
        server.close(() => resolve());
        server.closeAllConnections();
      }),
  };
};
