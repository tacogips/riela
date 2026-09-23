import { createMonjaClient } from "@monja/client";
import type { ClientError, GraphQLRequest } from "@monja/client";
import {
  evaluateMonjaBaseUrlPolicy,
  type MonjaUrlPolicyResult,
} from "./monja-url-policy.js";

const MAX_INPUT_BYTES = 1_048_576;
const MAX_QUERY_BYTES = 65_536;
const MAX_VARIABLE_BYTES = 262_144;
const MAX_OUTPUT_BYTES = 1_048_576;
const DEFAULT_REQUEST_TIMEOUT_MS = 15_000;
const MAX_REQUEST_TIMEOUT_MS = 60_000;

enum FailureStage {
  Input = "input",
  Configuration = "configuration",
  Client = "client",
  Rest = "rest",
  Graphql = "graphql",
  Output = "output",
  Runtime = "runtime",
}

enum LocalFailureKind {
  InvalidInvocation = "invalid_invocation",
  InputTooLarge = "input_too_large",
  MissingConfiguration = "missing_configuration",
  InvalidTimeout = "invalid_timeout",
  QueryTooLarge = "query_too_large",
  VariablesTooLarge = "variables_too_large",
  OutputTooLarge = "output_too_large",
  Serialization = "serialization",
  Unexpected = "unexpected",
}

type SafeFailure = Readonly<{
  stage: FailureStage;
  kind: LocalFailureKind | ClientError["kind"] | MonjaUrlPolicyFailureKind;
  status?: number;
}>;

type Result<T> =
  | Readonly<{ ok: true; value: T }>
  | Readonly<{ ok: false; error: SafeFailure }>;

type GraphQLInput = Readonly<{
  query: string;
  variables?: Record<string, unknown>;
  operationName?: string;
}>;

type CommandConfiguration = Readonly<{
  baseUrl: string;
  apiKey: string;
  requestTimeoutMs: number;
  allowInsecureLocalhost: boolean;
}>;

type MonjaUrlPolicyFailureKind = Extract<
  MonjaUrlPolicyResult,
  Readonly<{ ok: false }>
>["error"]["kind"];

function succeed<T>(value: T): Result<T> {
  return { ok: true, value };
}

function fail<T>(
  stage: FailureStage,
  kind: SafeFailure["kind"],
  status?: number,
): Result<T> {
  return status === undefined
    ? { ok: false, error: { stage, kind } }
    : { ok: false, error: { stage, kind, status } };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function readStandardInput(): Promise<Result<string>> {
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;

  try {
    for await (const chunk of process.stdin as AsyncIterable<unknown>) {
      if (!(typeof chunk === "string" || chunk instanceof Uint8Array)) {
        return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
      }
      const bytes =
        typeof chunk === "string" ? Buffer.from(chunk, "utf8") : chunk;
      totalBytes += bytes.byteLength;
      if (totalBytes > MAX_INPUT_BYTES) {
        return fail(FailureStage.Input, LocalFailureKind.InputTooLarge);
      }
      chunks.push(bytes);
    }
  } catch {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }

  try {
    const combined = Buffer.concat(
      chunks.map((chunk) => Buffer.from(chunk)),
      totalBytes,
    );
    return succeed(new TextDecoder("utf-8", { fatal: true }).decode(combined));
  } catch {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }
}

function parseSingleRecord(input: string): Result<Record<string, unknown>> {
  const records = input
    .split(/\r?\n/u)
    .filter((line) => line.trim().length > 0);
  if (records.length !== 1) {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }

  const record = records[0];
  if (record === undefined) {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(record);
  } catch {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }
  return isRecord(parsed)
    ? succeed(parsed)
    : fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
}

function parseGraphQLInput(
  envelope: Readonly<Record<string, unknown>>,
): Result<GraphQLInput> {
  const variables = envelope["variables"];
  if (!isRecord(variables)) {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }
  const workflowInput = variables["workflowInput"];
  if (!isRecord(workflowInput)) {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }
  const graphql = workflowInput["graphql"];
  if (!isRecord(graphql)) {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }

  const query = graphql["query"];
  if (typeof query !== "string" || query.trim().length === 0) {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }
  if (Buffer.byteLength(query, "utf8") > MAX_QUERY_BYTES) {
    return fail(FailureStage.Input, LocalFailureKind.QueryTooLarge);
  }

  const operationName = graphql["operationName"];
  if (operationName !== undefined && typeof operationName !== "string") {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }

  const graphQLVariables = graphql["variables"];
  if (graphQLVariables !== undefined && !isRecord(graphQLVariables)) {
    return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
  }
  if (graphQLVariables !== undefined) {
    let serializedVariables: string;
    try {
      serializedVariables = JSON.stringify(graphQLVariables);
    } catch {
      return fail(FailureStage.Input, LocalFailureKind.InvalidInvocation);
    }
    if (Buffer.byteLength(serializedVariables, "utf8") > MAX_VARIABLE_BYTES) {
      return fail(FailureStage.Input, LocalFailureKind.VariablesTooLarge);
    }
  }

  return succeed({
    query,
    ...(operationName === undefined ? {} : { operationName }),
    ...(graphQLVariables === undefined ? {} : { variables: graphQLVariables }),
  });
}

function parseRequestTimeout(rawValue: string | undefined): Result<number> {
  if (rawValue === undefined) return succeed(DEFAULT_REQUEST_TIMEOUT_MS);
  if (!/^[0-9]+$/u.test(rawValue)) {
    return fail(FailureStage.Configuration, LocalFailureKind.InvalidTimeout);
  }
  const timeout = Number(rawValue);
  return Number.isSafeInteger(timeout) &&
    timeout >= 1 &&
    timeout <= MAX_REQUEST_TIMEOUT_MS
    ? succeed(timeout)
    : fail(FailureStage.Configuration, LocalFailureKind.InvalidTimeout);
}

function readConfiguration(): Result<CommandConfiguration> {
  const baseUrl = process.env["MONJA_BASE_URL"];
  const apiKey = process.env["MONJA_API_KEY"];
  if (baseUrl === undefined || baseUrl.length === 0) {
    return fail(
      FailureStage.Configuration,
      LocalFailureKind.MissingConfiguration,
    );
  }
  if (apiKey === undefined || apiKey.length === 0) {
    return fail(
      FailureStage.Configuration,
      LocalFailureKind.MissingConfiguration,
    );
  }

  const timeout = parseRequestTimeout(process.env["MONJA_REQUEST_TIMEOUT_MS"]);
  if (!timeout.ok) return timeout;

  const policy = evaluateMonjaBaseUrlPolicy(baseUrl);
  if (!policy.ok) {
    return fail(FailureStage.Configuration, policy.error.kind);
  }

  return succeed({
    baseUrl,
    apiKey,
    requestTimeoutMs: timeout.value,
    allowInsecureLocalhost: policy.value.allowInsecureLocalhost,
  });
}

function fromClientError<T>(
  stage: FailureStage,
  error: ClientError,
): Result<T> {
  if (error.kind === "authentication" || error.kind === "http") {
    return fail(stage, error.kind, error.status);
  }
  return fail(stage, error.kind);
}

function createGraphQLRequest(
  input: GraphQLInput,
): GraphQLRequest<Record<string, unknown>> {
  return {
    query: input.query,
    ...(input.operationName === undefined
      ? {}
      : { operationName: input.operationName }),
    ...(input.variables === undefined ? {} : { variables: input.variables }),
  };
}

async function runCommand(): Promise<Result<string>> {
  const input = await readStandardInput();
  if (!input.ok) return input;

  const envelope = parseSingleRecord(input.value);
  if (!envelope.ok) return envelope;
  const graphqlInput = parseGraphQLInput(envelope.value);
  if (!graphqlInput.ok) return graphqlInput;

  const configuration = readConfiguration();
  if (!configuration.ok) return configuration;

  const created = createMonjaClient({
    baseUrl: configuration.value.baseUrl,
    auth: { kind: "apiKey", token: configuration.value.apiKey },
    allowInsecureLocalhost: configuration.value.allowInsecureLocalhost,
    jsonResponseMaxBytes: MAX_OUTPUT_BYTES,
  });
  if (!created.ok) {
    return fromClientError(FailureStage.Client, created.error);
  }

  const abortController = new AbortController();
  const timeout = setTimeout(
    () => abortController.abort(),
    configuration.value.requestTimeoutMs,
  );
  try {
    const rest = await created.value.core.me({
      signal: abortController.signal,
    });
    if (!rest.ok) return fromClientError(FailureStage.Rest, rest.error);

    const graphql = await created.value.graphql.executeStrict<
      unknown,
      Record<string, unknown>
    >(createGraphQLRequest(graphqlInput.value), {
      signal: abortController.signal,
    });
    if (!graphql.ok) {
      return fromClientError(FailureStage.Graphql, graphql.error);
    }

    let serialized: string;
    try {
      serialized = JSON.stringify({
        status: "ok",
        rest: {
          kind: rest.value.kind,
          user: {
            id: rest.value.user.id,
            username: rest.value.user.username,
            displayName: rest.value.user.displayName,
          },
        },
        graphql: graphql.value,
      });
    } catch {
      return fail(FailureStage.Output, LocalFailureKind.Serialization);
    }
    if (Buffer.byteLength(serialized, "utf8") > MAX_OUTPUT_BYTES) {
      return fail(FailureStage.Output, LocalFailureKind.OutputTooLarge);
    }
    return succeed(`${serialized}\n`);
  } finally {
    clearTimeout(timeout);
  }
}

function writeFailure(failure: SafeFailure): void {
  process.exitCode = 1;
  process.stderr.write(`${JSON.stringify(failure)}\n`);
}

try {
  const result = await runCommand();
  if (result.ok) {
    process.stdout.write(result.value);
  } else {
    writeFailure(result.error);
  }
} catch {
  writeFailure({
    stage: FailureStage.Runtime,
    kind: LocalFailureKind.Unexpected,
  });
}
