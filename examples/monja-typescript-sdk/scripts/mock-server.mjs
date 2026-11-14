import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const runtimeDirectory = process.env.MONJA_EXAMPLE_RUNTIME_DIR;
const token = process.env.MONJA_API_KEY;
const mode = process.env.MONJA_MOCK_MODE ?? "success";
const supportedModes = new Set([
  "success",
  "rest-failure",
  "capability-disabled",
  "graphql-failure",
  "timeout",
  "oversized-rest",
  "oversized-graphql",
  "oversized-response",
  "oversized-output",
]);

if (!runtimeDirectory || !token || !supportedModes.has(mode)) {
  process.stderr.write("monja-mock: invalid startup configuration\n");
  process.exit(64);
}

const canonicalRuntime = fs.realpathSync(runtimeDirectory);
const handoffPath = path.join(canonicalRuntime, "mock-server.json");
const requestsPath = path.join(canonicalRuntime, "mock-requests.json");
const expectedRequests = [
  ["GET", "/api/v1/auth/me"],
  ["GET", "/api/v1/server-capabilities"],
  ["POST", "/api/v1/graphql"],
];
const requests = [];
let rejected = false;

function writePrivateJson(filePath, value) {
  const temporaryPath = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporaryPath, filePath);
}

function recordRequest(method, requestPath, authenticated, valid) {
  requests.push({ sequence: requests.length + 1, method, path: requestPath, authenticated, valid });
  writePrivateJson(requestsPath, { mode, complete: requests.length === 3 && !rejected, rejected, requests });
}

function sendJson(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
  });
  response.end(body);
}

function principalPayload(extra = {}) {
  return {
    kind: "apiKey",
    user: {
      id: "user-riela-sdk",
      username: "riela-sdk",
      displayName: "Riela SDK Probe",
      isBot: false,
      isAdmin: false,
      deactivatedAt: null,
      ...extra,
    },
    scopes: [],
  };
}

function capabilities(graphqlEnabled) {
  return {
    apiVersion: "v1",
    graphqlEnabled,
    documentRestSurfaceEnabled: true,
    billingEnabled: true,
    calendarRestSurfaceEnabled: true,
    attachmentRestSurfaceEnabled: true,
    capabilityGrammar: { revision: 1, entries: [] },
    eventProtocol: { supported: [2] },
  };
}

async function readJsonBody(request) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > 262_144) throw new Error("body-too-large");
    chunks.push(chunk);
  }
  const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("invalid-body");
  return parsed;
}

const server = http.createServer(async (request, response) => {
  const requestIndex = requests.length;
  const [expectedMethod, expectedPath] = expectedRequests[requestIndex] ?? [undefined, undefined];
  const method = request.method ?? "";
  const requestPath = request.url ?? "/";
  const authenticated = request.headers.authorization === `Bearer ${token}`;
  const ordered = method === expectedMethod && requestPath === expectedPath;

  if (!authenticated || !ordered) {
    rejected = true;
    recordRequest(method, requestPath, authenticated, false);
    sendJson(response, 409, { error: "unexpected_request" });
    return;
  }

  if (requestIndex === 0) {
    recordRequest(method, requestPath, true, true);
    if (mode === "timeout") return;
    if (mode === "rest-failure") {
      sendJson(response, 503, { error: "controlled_rest_failure" });
      return;
    }
    if (mode === "oversized-rest") {
      sendJson(response, 200, principalPayload({ displayName: "x".repeat(1_100_000) }));
      return;
    }
    sendJson(response, 200, principalPayload());
    return;
  }

  if (requestIndex === 1) {
    recordRequest(method, requestPath, true, true);
    sendJson(response, 200, capabilities(mode !== "capability-disabled"));
    return;
  }

  try {
    if (request.headers["content-type"]?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
      throw new Error("invalid-content-type");
    }
    const body = await readJsonBody(request);
    const validVariables = body.variables === undefined || (typeof body.variables === "object" && body.variables !== null && !Array.isArray(body.variables));
    const validOperation = body.operationName === undefined || body.operationName === "RielaSdkProbe";
    const validDocument = typeof body.query === "string" && body.query.includes("RielaSdkProbe") && body.query.includes("me");
    if (!validVariables || !validOperation || !validDocument) throw new Error("invalid-graphql-request");
    recordRequest(method, requestPath, true, true);
    if (mode === "graphql-failure") {
      sendJson(response, 200, { errors: [{ message: "controlled GraphQL failure" }] });
      return;
    }
    if (mode === "oversized-output") {
      sendJson(response, 200, { data: { me: { kind: "apiKey", padding: "x".repeat(1_048_450) } } });
      return;
    }
    if (mode === "oversized-graphql" || mode === "oversized-response") {
      sendJson(response, 200, { data: { me: { kind: "apiKey", padding: "x".repeat(1_100_000) } } });
      return;
    }
    sendJson(response, 200, {
      data: {
        me: {
          kind: "apiKey",
          user: { id: "user-riela-sdk", username: "riela-sdk", displayName: "Riela SDK Probe" },
        },
      },
    });
  } catch {
    rejected = true;
    recordRequest(method, requestPath, true, false);
    sendJson(response, 400, { error: "malformed_graphql_request" });
  }
});

server.on("clientError", (_error, socket) => {
  socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  if (!address || typeof address === "string") {
    process.stderr.write("monja-mock: listener did not expose an IPv4 port\n");
    process.exitCode = 1;
    server.close();
    return;
  }
  writePrivateJson(requestsPath, { mode, complete: false, rejected: false, requests: [] });
  writePrivateJson(handoffPath, { baseUrl: `http://127.0.0.1:${address.port}`, pid: process.pid, mode });
});

function stop() {
  server.close(() => process.exit(0));
}

process.on("SIGINT", stop);
process.on("SIGTERM", stop);
