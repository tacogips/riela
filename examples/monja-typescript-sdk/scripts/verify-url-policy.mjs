import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const runtimeDirectory = process.env.MONJA_EXAMPLE_RUNTIME_DIR;
if (!runtimeDirectory) throw new Error("MONJA_EXAMPLE_RUNTIME_DIR is required");
const canonicalRuntime = fs.realpathSync(runtimeDirectory);
const policyModulePath = path.join(canonicalRuntime, "consumer/dist/monja-url-policy.js");

let fetchCalls = 0;
const originalFetch = globalThis.fetch;
globalThis.fetch = async () => {
  fetchCalls += 1;
  throw new Error("URL policy attempted network access");
};

const permitted = [
  ["https://api.example", false, "https://api.example/"],
  ["https://api.example/deployment", false, "https://api.example/deployment"],
  ["http://localhost:8080", true, "http://localhost:8080/"],
  ["http://127.0.0.1:8080", true, "http://127.0.0.1:8080/"],
  ["http://[::1]:8080", true, "http://[::1]:8080/"],
];
const rejected = [
  "",
  "not a URL",
  "ftp://api.example",
  "http://api.example",
  "http://localhost.",
  "http://sub.localhost",
  "http://127.0.0.2",
  "http://[::2]",
  "https://user@api.example",
  "https://api.example?query=1",
  "https://api.example#fragment",
];

try {
  const { evaluateMonjaBaseUrlPolicy } = await import(pathToFileURL(policyModulePath).href);
  if (typeof evaluateMonjaBaseUrlPolicy !== "function") throw new Error("compiled URL policy export is missing");
  for (const [input, allowInsecureLocalhost, normalizedBaseUrl] of permitted) {
    const result = evaluateMonjaBaseUrlPolicy(input);
    if (!result?.ok || result.value.allowInsecureLocalhost !== allowInsecureLocalhost || result.value.normalizedBaseUrl !== normalizedBaseUrl) {
      throw new Error("URL policy permitted-case mismatch");
    }
  }
  for (const input of rejected) {
    const result = evaluateMonjaBaseUrlPolicy(input);
    if (result?.ok || typeof result?.error?.kind !== "string" || result.error.kind.length === 0 || result.error.kind.length > 64) {
      throw new Error("URL policy rejected-case mismatch");
    }
  }
  if (fetchCalls !== 0) throw new Error("URL policy performed network access");
} finally {
  globalThis.fetch = originalFetch;
}

process.stdout.write(`${JSON.stringify({ status: "ok", permitted: permitted.length, rejected: rejected.length, fetchCalls })}\n`);
