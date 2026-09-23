# Monja TypeScript SDK Command Node Interoperability

Status: proposed; ready for adversarial design review

Workflow mode: `design-plan-only`

Issue reference:
`local-request:/Users/taco/gits/tacogips/riela:Use the Monja TypeScript SDK from Riela command nodes`

Reference repository: `/Users/taco/gits/tacogips/monja`

Latest review decision:
`revision_required_for_mid_consumer_esm_configuration_finding` from
`comm-000020`. This revision defines the generated consumer manifest, pinned
compiler and Node typings, strict NodeNext configuration, and isolated ESM
resolution proof. The earlier `comm-000014` node-file/secure-transport and
`comm-000017` loopback-verification corrections remain part of the design.

## Goal

Prove one dependency-ordered interoperability path in which a Riela command
node runs under Node.js, imports `@monja/client` by package name from a locally
npm-packed artifact, calls the typed `client.core.me()` REST operation, and
executes a caller-supplied GraphQL query or mutation through
`client.graphql.executeStrict`.

The proof must exercise the actual Riela JSONL stdin/stdout boundary and an
installed package. Importing Monja workspace source or running only an SDK unit
test is insufficient.

## Source Findings

- `/Users/taco/gits/tacogips/monja/packages/client-typescript/package.json`
  names the package `@monja/client`, exposes ESM and declarations from
  `dist/index.js` and `dist/index.d.ts`, and includes only `dist` in `files`.
  A successful build must therefore precede every pack.
- Existing Monja SDK tests import `../src/...`; they establish SDK behavior but
  do not establish npm-package consumption.
- `createMonjaClient` exposes `core.me()` and `graphql.execute` /
  `graphql.executeStrict`. The client uses `globalThis.fetch` unless a fetch
  implementation is injected and bounds decoded JSON responses to 1,048,576
  bytes by default.
- `client.graphql.execute` and `executeStrict` perform a fresh
  `GET /api/v1/server-capabilities` check before
  `POST /api/v1/graphql`. A faithful mock requires both exchanges.
- `LocalWorkflowStdioNodeExecutor` already writes one invocation envelope plus
  a newline to child stdin and accepts empty stdout or exactly one JSON object
  record. It rejects multiple records, invalid JSON, and non-object output.
- Riela command evidence retains an argv summary, and a nonzero command result
  includes trimmed stderr in the adapter error. Credentials must therefore
  never enter argv, and the node must keep stderr credential-free by
  construction.
- `FoundationLocalProcessRunner` inherits the host environment before applying
  the command environment overlay. Live authentication can remain host-env
  only; it need not be templated into workflow JSON.
- The Monja worktree has unrelated tracked and untracked changes. No cleanup,
  reset, bulk formatting, or broad staging is permitted.
- The package declares no Node `engines` range. The example must check required
  runtime capabilities and record the verified Node version rather than
  silently inventing a package-wide compatibility promise.

## Scope

### In scope

- `examples/monja-typescript-sdk/` with one workflow, one TypeScript command
  source, setup/run helpers, deterministic mock verification, README, and
  expected-results documentation.
- A clean consumer directory under the Riela repository's `tmp/` directory.
- Local Monja SDK build, npm pack, artifact inspection, installation with
  lifecycle scripts disabled, typecheck/compile, and execution through Riela.
- A deterministic loopback mock and an explicitly operator-owned live boundary.
- Focused Riela executor tests only if packed execution reveals a Riela defect.
- Focused Monja package or SDK fixes only if build, pack inspection, clean
  install, typecheck, or execution provides reproducible evidence.

### Out of scope

- Publishing `@monja/client` to a registry.
- Vendoring Monja source, tarballs, generated `dist`, `node_modules`, lockfiles,
  credentials, or verification logs into Riela.
- Starting, seeding, migrating, or mutating a live Monja deployment.
- Adding a second Riela SDK abstraction or a Cursor/Codex agent adapter.
- Broad cleanup of either repository or unrelated Monja worktree repair.
- Session-cookie authentication in the portable example. The proof uses an API
  key supplied through the environment.

## Package-Consumer Boundary

The package proof is ordered and fail-closed:

1. Build `packages/client-typescript` so `dist` cannot be stale or absent.
2. Run its typecheck and test suite.
3. Run `npm pack --json --pack-destination <riela-root>/tmp/...` against the
   package directory.
4. Inspect the reported tarball rather than guessing its file name. Require the
   package name, version, `package/dist/index.js`,
   `package/dist/index.d.ts`, and `package/package.json`. Reject a missing entry
   point, any `package/src/` member, repository escape, or workspace-only
   dependency.
5. Create a new consumer below `<riela-root>/tmp/monja-typescript-sdk/`. Generate
   a `package.json` with
   `name: "riela-monja-typescript-sdk-consumer"`, `private: true`,
   `type: "module"`, and the exact dependency
   `"@monja/client": "file:<canonical-reported-tarball-path>"`, and exact
   development dependencies `"typescript": "5.7.2"` and
   `"@types/node": "20.12.14"`. The `file:` value is generated only in this
   ignored consumer; no machine path or tarball dependency is committed.
6. Generate `tsconfig.json` with this complete interoperability configuration:
   `target: "ES2022"`, `module: "NodeNext"`,
   `moduleResolution: "NodeNext"`,
   `lib: ["ES2022", "DOM", "DOM.Iterable"]`, `types: ["node"]`,
   `rootDir: "src"`, `outDir: "dist"`, `strict: true`,
   `exactOptionalPropertyTypes: true`, `noUncheckedIndexedAccess: true`,
   `useUnknownInCatchVariables: true`, `verbatimModuleSyntax: true`,
   `forceConsistentCasingInFileNames: true`, `noEmitOnError: true`, and
   `skipLibCheck: false`, with emit enabled. Include only `src/**/*.ts`; do not
   use `extends` or inherit any Riela or Monja compiler configuration.
7. Run
   `npm install --ignore-scripts --no-audit --no-fund --package-lock=true`
   from the consumer so its generated lockfile records the exact tarball and
   pinned tool versions.
   Reject any installed top-level version other than `@monja/client` at the
   packed version, TypeScript 5.7.2, and `@types/node` 20.12.14. The consumer's
   own `node_modules/@types/node` is the only Node typing source, and the
   consumer's own `node_modules/.bin/tsc` is the only compiler.
8. Copy the committed example command sources into `src/`, typecheck and compile
   them from the consumer, and run only `dist/*.js`. Node treats the emitted
   `.js` as ESM through the generated `type: "module"` manifest and NodeNext
   emit. TypeScript sources use `.js` specifiers for internal relative imports
   as required by NodeNext. Module resolution must select the consumer's
   installed package, never Monja `src` or a Monja workspace `node_modules`
   directory.
9. Before transport tests, run an ESM-mode resolution probe from the consumer
   and require `import.meta.resolve("@monja/client")` to resolve to the real
   path `<consumer>/node_modules/@monja/client/dist/index.js`. Require emitted
   JavaScript to retain the bare `@monja/client` import, contain no CommonJS
   `require`/`module.exports`, and execute successfully under `node` from that
   consumer.
10. Record the tarball checksum, file list, generated metadata, resolved package
   path, exact compiler/type versions, Node version,
   and command results only in evidence below `tmp/`; do not commit them.

The committed command source must contain the bare package import:
`import { createMonjaClient } from "@monja/client"`. It must not contain a
Monja-relative path, a `file:` dependency, a development-machine path, or an
import-map alias.

## Example Layout

The implementation plan should preserve this responsibility split:

- `examples/monja-typescript-sdk/workflow.json`: a manager-less workflow with
  `entryStepId: "monja-command"`, one `nodes[]` entry whose
  `nodeFile` is `nodes/node-monja-command.json`, and one terminal worker step
  whose `nodeId` is `monja-command`. Set `defaults.nodeTimeoutMs` to 90,000,
  leaving 30 seconds beyond the command's maximum 60-second request deadline
  for process startup and output validation while retaining a finite bound.
- `examples/monja-typescript-sdk/nodes/node-monja-command.json`: the required
  `AgentNodePayload`. Its id is `monja-command`, its `nodeType` is `command`,
  and its command uses `scriptPath: "scripts/run-installed-command.sh"`, empty
  arguments and environment maps, and `workingDirectory: "scripts"`. The
  loader therefore resolves the script within the workflow bundle while the
  wrapper remains independent of the caller's current directory. Its authored
  input contract documents `workflowInput.graphql.query`, optional
  `operationName`, and optional object `variables`; its output contract
  documents the single `status`/`rest`/`graphql` object.
- `examples/monja-typescript-sdk/nodes/monja-command.ts`: JSONL validation, SDK
  client construction, sequential REST and GraphQL calls, safe result shaping,
  and bounded diagnostics.
- `examples/monja-typescript-sdk/nodes/monja-url-policy.ts`: a pure,
  side-effect-free URL-policy seam used by the command before client
  construction. It returns either a permitted normalized base URL plus the
  derived `allowInsecureLocalhost` value, or a bounded rejection category; it
  cannot perform DNS or network IO.
- `examples/monja-typescript-sdk/scripts/prepare.sh`: build, pack, inspect,
  generate the exact private ESM consumer manifest and strict NodeNext config,
  install the tarball plus pinned compiler/Node typings, typecheck, compile,
  and verify isolated ESM package resolution under `tmp/`.
- `examples/monja-typescript-sdk/scripts/run-installed-command.sh`: execute the
  prepared JavaScript without accepting credentials in arguments. It resolves
  the Riela root from its own path, then executes only from
  `MONJA_EXAMPLE_RUNTIME_DIR` after verifying that directory is contained by
  the Riela `tmp/` root.
- `examples/monja-typescript-sdk/scripts/mock-server.mjs`: loopback-only mock for
  REST, capabilities, and GraphQL transport.
- `examples/monja-typescript-sdk/scripts/verify-url-policy.mjs`: imports the
  compiled pure policy seam and asserts the complete permitted/rejected matrix
  without starting a listener or calling `fetch`.
- `examples/monja-typescript-sdk/scripts/verify.sh`: isolated orchestration,
  positive and negative contract checks, leakage checks, and cleanup.
- `examples/monja-typescript-sdk/README.md`: local package setup, runtime and
  environment prerequisites, the workflow-to-node-to-script chain, HTTPS as
  the live default, the exact loopback-only HTTP exception, the distinction
  between policy classification and IPv4 end-to-end transport, the generated
  private ESM consumer metadata and pinned tooling, and deterministic and live
  instructions.
- `examples/monja-typescript-sdk/EXPECTED_RESULTS.md`: stable output shapes,
  request sequence, node resolution facts, the explicit URL-policy matrix, the
  single `127.0.0.1` transport success case, isolated NodeNext emit and
  `@monja/client` resolution evidence, failure boundaries, and commands that
  remain operator-only.

Generated package, compiler, server, process, and evidence files belong only in
`<riela-root>/tmp/monja-typescript-sdk/`. Helpers must resolve repository roots
from their own locations or explicit non-secret environment variables; they
must not commit absolute development-machine paths.

`MONJA_EXAMPLE_RUNTIME_DIR` is a non-secret harness setting, never a command
argument. `prepare.sh` and `run-installed-command.sh` use the same canonical
value. Deterministic verification assigns a unique per-run directory below
`tmp/monja-typescript-sdk/`; a direct operator run may use the documented
single-run default. Missing, non-directory, symlink-escaping, or out-of-`tmp/`
values fail before Node starts.

## Invocation Contract

The command receives exactly one Riela
`WorkflowStdioNodeInvocationEnvelope` JSON object followed by a newline.

Because `monja-command` is the entry step and has no predecessor messages, user
request data comes from `envelope.variables.workflowInput`, not from the
predecessor-oriented `envelope.input` payload. `workflow.json` exposes no query
or credential as argv or authored environment. CLI callers provide only the
non-secret GraphQL request under:

- `workflowInput.graphql.query`: required string;
- `workflowInput.graphql.operationName`: optional string; and
- `workflowInput.graphql.variables`: optional top-level object.

The command ignores `_rielaInput` metadata when choosing the GraphQL operation.

The node must:

- read stdin once to EOF with a 1,048,576-byte limit;
- accept exactly one nonblank JSONL record and reject any second nonblank
  record;
- require a top-level object and validate only the fields it consumes;
- obtain the GraphQL document only from `variables.workflowInput.graphql`, with
  its optional operation name and variables object;
- reject a GraphQL document over 65,536 UTF-8 bytes, serialized variables over
  262,144 UTF-8 bytes, or a non-object variables value before network activity;
- never treat invocation data as command arguments or environment-variable
  names; and
- never echo the invocation, query, variables, environment, request headers,
  or raw SDK error object in diagnostics.

The portable documented query is read-only and schema-backed:
`query RielaSdkProbe { me { kind user { id username displayName } } }`.
The input contract remains capable of carrying another query or mutation, so
the example proves arbitrary-document execution rather than a hidden typed
GraphQL wrapper.

## Authentication And Configuration

The example reads:

- `MONJA_BASE_URL`: non-secret HTTPS server base URL, except for the exact
  loopback HTTP rule below;
- `MONJA_API_KEY`: required secret used as `{ kind: "apiKey", token }`; and
- optional `MONJA_REQUEST_TIMEOUT_MS`: a non-secret integer in `1...60000`,
  defaulting to 15,000 milliseconds for the whole REST-plus-GraphQL sequence.

None of these values is authored into `workflow.json`. The host exports them
before the workflow starts; the command inherits them through Riela's process
boundary. The executable and arguments are fixed and contain no environment
expansion, token, base URL, query, or variables.

No real or fixture token is committed. Deterministic verification generates an
ephemeral token at runtime, supplies it to both mock and command through their
environments, captures output under `tmp/`, and rejects any occurrence of that
token in stdout, stderr, Riela JSON output, error evidence, or argv evidence.
The verification script must not enable shell tracing.

The command must not serialize the complete client options or SDK error. On
failure it writes no stdout record, writes one bounded diagnostic to stderr
containing only the stage and a safe classification such as error kind/status,
and exits nonzero. It omits error messages, details, URLs, headers, bodies,
queries, variables, and credential lengths. This is stricter than relying only
on SDK redaction because Riela includes command stderr in provider errors.

The command parses `MONJA_BASE_URL` with the platform URL parser before client
construction and derives `allowInsecureLocalhost` without an independent
configuration switch:

- HTTPS always uses `allowInsecureLocalhost: false` or omits the option.
- HTTP sets `allowInsecureLocalhost: true` only when the normalized hostname is
  exactly `localhost`, `127.0.0.1`, or `[::1]`.
- Any other HTTP hostname, any other scheme, or a URL containing username,
  password, query, or fragment is rejected before a request is sent.
- Lookalikes such as `localhost.`, subdomains, and non-loopback IPs do not
  receive the exception.

This decision is implemented behind the pure `monja-url-policy.ts` seam. Its
observable success result contains the normalized base URL and the derived
boolean; its observable failure result contains only a stable non-secret
category. `monja-command.ts` must call this seam before `createMonjaClient` and
before any fetch-capable operation. Production diagnostics map failure
categories to bounded stage/kind output and do not print the URL.

The SDK remains the final authority for deployment-prefix normalization and
route-safety validation. The command never sets `allowInsecureLocalhost` from
workflow input or an environment boolean. Thus the deterministic
`http://127.0.0.1:<port>` mock is enabled automatically, while HTTPS remains the
live default and remote plaintext HTTP fails closed.

The node passes one abort signal with the configured timeout to both SDK
operations, so the complete sequence has one bounded deadline. It sets the SDK
JSON response limit explicitly to 1,048,576 bytes, checks that the final
serialized success object is no more than 1,048,576 UTF-8 bytes, and fails
without stdout if the limit would be exceeded.

## Network Data Flow

After local input/configuration validation, calls are sequential:

1. `client.core.me()` sends `GET /api/v1/auth/me`.
2. `client.graphql.executeStrict(...)` sends
   `GET /api/v1/server-capabilities` with no-store semantics.
3. When `graphqlEnabled` is true, the SDK sends
   `POST /api/v1/graphql` with the supplied document, variables, and operation
   name.
4. The node maps the successful REST principal and GraphQL data into one output
   object and performs one stdout write ending in a newline.

The proposed success output is one top-level object with `status`, `rest`, and
`graphql` members. `rest` contains only principal kind and non-credential user
identity fields. `graphql` contains the GraphQL data requested by the caller.
The output never includes client configuration, authorization data, transport
headers, or the original invocation.

## Deterministic Mock Contract

The mock binds only to `127.0.0.1` on an operating-system-selected port and
publishes the chosen base URL to its parent through a private file or pipe under
`tmp/`. It must not print the token.

This listener proves the complete installed-package/Riela transport path only
for `http://127.0.0.1:<port>`. The harness does not claim network success for
`localhost` or `[::1]`, because name resolution and IPv6 availability vary by
host. Those accepted hostnames, HTTPS, lookalikes, and non-loopback HTTP are
verified deterministically through the pre-network policy seam instead.

It accepts exactly the three expected authenticated requests in order:

- `GET /api/v1/auth/me` returns a valid API-key principal;
- `GET /api/v1/server-capabilities` returns `apiVersion: "v1"`,
  `graphqlEnabled: true`, valid capability grammar, and supported event
  protocol; and
- `POST /api/v1/graphql` asserts the operation name/document shape and returns
  deterministic `me` data.

Unexpected methods, paths, extra requests, missing/wrong authorization, or
malformed bodies fail verification. The mock records only method/path and safe
assertion outcomes.

`verify.sh` must prove:

- clean npm-pack installation and bare package-name resolution;
- the generated consumer is private and ESM, its `@monja/client` dependency is
  the canonical tarball reported by `npm pack`, its installed TypeScript is
  exactly 5.7.2, and its installed `@types/node` is exactly 20.12.14;
- the generated strict config has the exact ES2022/NodeNext/module-resolution,
  DOM library, Node types, `src`/`dist`, and strictness settings specified in
  Package-Consumer Boundary, and TypeScript declarations are consumable under
  that config without falling back to a workspace compiler or type root;
  resolution evidence must place the compiler and `@types/node` package below
  the consumer's own `node_modules` directory;
- the emitted `.js` runs as ESM, retains the bare package import, contains no
  CommonJS wrapper, and `import.meta.resolve("@monja/client")` resolves to the
  installed consumer path `<consumer>/node_modules/@monja/client/dist/index.js`;
- `workflow.json` resolves `nodes/node-monja-command.json`, whose fixed empty
  argv and environment execute `scripts/run-installed-command.sh` from the
  declared `scripts` working directory;
- the actual Riela workflow executes the prepared command successfully;
- the command emits one object record and Riela accepts it;
- empty input, multiple records, non-object JSON, missing environment, REST
  failure, capability-disabled GraphQL, GraphQL failure, timeout, and oversized
  input/output emit no stdout object and bounded stderr only;
- the pure policy seam permits HTTPS with `allowInsecureLocalhost: false`,
  permits exact HTTP `localhost`, `127.0.0.1`, and `[::1]` with
  `allowInsecureLocalhost: true`, and rejects loopback lookalikes,
  non-loopback HTTP, other schemes, userinfo, query, and fragment without
  invoking `fetch`;
- end-to-end REST, capability, and GraphQL transport succeeds only against the
  deterministic `127.0.0.1` listener; no IPv6 or localhost resolver assumption
  is part of the gate;
- the generated token is absent from all captured outputs and evidence; and
- all scratch state stays below the Riela `tmp/` root.

## Live Verification Boundary

Live verification is optional and operator-owned. It requires:

- a separately started Monja server reachable over HTTPS at `MONJA_BASE_URL`,
  with plaintext HTTP allowed only for an exact loopback hostname;
- an API key exported only as `MONJA_API_KEY` and authorized to call
  `/api/v1/auth/me` and the selected GraphQL fields;
- `GET /api/v1/server-capabilities` reporting `graphqlEnabled: true`;
- a supported Node runtime with ESM and `globalThis.fetch`; and
- a non-mutating query by default. Mutations require explicit operator choice
  and are never part of the deterministic gate.

Server startup, database migration, seed data, API-key issuance, secret-store
integration, and remote TLS policy are Monja deployment concerns. The README
must name these prerequisites without inventing environment-specific commands
or values. Live output may contain server data and therefore must not be stored
as committed expected-result evidence.

## Evidence-Gated Change Policy

Implementation starts with the example and consumer harness. It may widen only
after a reproducible failing gate:

- Change Monja `package.json`, exports, build output, or SDK code only when the
  built tarball cannot be installed, imported, typed, or executed as specified.
- Change `WorkflowStdioNodeExecutor.swift` only when a correctly behaving
  installed command is incompatible with the documented Riela JSONL contract.
- Every production change requires a focused regression test in the owning
  repository and an evidence note linking the failure to the changed file.
- Preserve the pre-existing Monja status exactly outside the explicit file
  allowlist. Do not reformat, stage, revert, or include unrelated changes.
- If later implementation changes a packaged workflow, prompt, script, or
  skill with digest metadata, refresh the owning `riela-package.json` digests.
  This design-only update changes no package digest.

## TypeScript Reference Application

The following references resolve under `/Users/taco/gits/tacogips/monja` and
govern any later TypeScript change:

- `.agents/agents/ts-coding.md`
- `.agents/agents/check-and-test-after-modify.md`
- `.agents/skills/ts-coding-standards/SKILL.md`
- `.agents/skills/ts-review/SKILL.md`

The implementation task supplied to the TypeScript coding agent must state its
purpose, this design document, its exact target, and completion criteria. New
code uses strict types, `unknown` plus narrowing, readonly data, explicit Result
handling, bounded async behavior, and credential/path hygiene. After every
TypeScript modification, invoke the prescribed post-modification verification
with modified packages and files, run Biome before or alongside typecheck, run
formatting for touched paths, run tests, and perform the TypeScript review
checklist. Do not weaken lint or type rules to make the example pass.

## Cursor CLI Behavior Mapping

No Cursor CLI behavior is referenced or required. This is a backend-neutral
Riela command-node process boundary. No authentication, stdio, packaging, or
error rule belongs in a Cursor adapter, and no divergence from Cursor behavior
is claimed.

## Rollout And Verification Gates

Implementation is not accepted until the following commands and their exact
results are recorded:

```bash
cd /Users/taco/gits/tacogips/monja && bun run --cwd packages/client-typescript build && bun run --cwd packages/client-typescript typecheck && bun run --cwd packages/client-typescript test
bash examples/monja-typescript-sdk/scripts/verify.sh
swift run riela workflow validate monja-typescript-sdk --workflow-definition-dir ./examples --output json
swift test --filter WorkflowStdioNodeExecutorTests
git -C /Users/taco/gits/tacogips/riela diff --check
git -C /Users/taco/gits/tacogips/monja diff --check
```

If TypeScript changes, the Monja reference checks additionally require Biome
with warning diagnostics visible, formatting of touched paths, the relevant
typecheck and tests, the `check-and-test-after-modify` pass, and a `ts-review`
pass. The implementation handoff must distinguish failures caused by this work
from failures in pre-existing dirty files.

## Acceptance Mapping

| Intake signal | Design contract |
|---|---|
| Bare `@monja/client` import from npm-packed artifact | Package-Consumer Boundary; Example Layout |
| Deterministic ESM consumer, compiler, and Node typings | Package-Consumer Boundary; Deterministic Mock Contract |
| Valid workflow node-file resolution | Example Layout; Deterministic Mock Contract |
| Exactly one stdin invocation and at most one stdout object | Invocation Contract; Deterministic Mock Contract |
| Typed REST plus arbitrary GraphQL | Goal; Network Data Flow |
| Environment-only, non-leaking authentication | Authentication And Configuration |
| Setup, mock, live, and expected-result documentation | Example Layout; Live Verification Boundary |
| Monja build/typecheck/test | Rollout And Verification Gates |
| Example deterministic verification | Deterministic Mock Contract; Rollout And Verification Gates |
| Workflow validation | Rollout And Verification Gates |
| Riela executor regression tests | Evidence-Gated Change Policy; Rollout And Verification Gates |
| Both repositories pass `diff --check` | Rollout And Verification Gates |

## Risks And Mitigations

- **Stale or missing `dist`:** always build before pack and inspect the reported
  tarball entries.
- **False workspace success:** compile and execute from a new consumer whose
  only Monja dependency is the installed tarball; reject source-relative
  imports.
- **Ambiguous module emit or Node typings:** generate a private `type: module`
  consumer, pin TypeScript 5.7.2 and `@types/node` 20.12.14, compile with the
  exact strict NodeNext config, and assert the ESM resolver lands inside the
  consumer's installed package.
- **Credential leakage through evidence:** env-only auth, fixed argv, generated
  mock token, bounded safe diagnostics, captured-output scanning, and no shell
  tracing.
- **Remote plaintext credential exposure:** derive the SDK's insecure-localhost
  option only for exact loopback HTTP, keep HTTPS as the live default, and test
  all accepted/rejected classifications through a pure pre-network seam.
- **Nondeterministic localhost/IPv6 networking:** reserve end-to-end mock
  transport for `127.0.0.1`; test `localhost` and `[::1]` as policy outcomes
  without depending on DNS order or IPv6 listener availability.
- **Incomplete GraphQL mock:** require the capability request and GraphQL POST,
  in addition to REST `me`, with exact ordering and no unexpected requests.
- **Stdout contamination:** one success serialization call, no logging to
  stdout, negative tests, and Riela's existing fail-closed parser tests.
- **Unsafe or misleading live gate:** default to a read-only query and keep
  server lifecycle, mutation, seed, and credentials outside deterministic CI.
- **Unnecessary cross-repository fixes:** widen scope only from reproducible
  packed-consumer or runtime evidence and add focused ownership tests.
- **Dirty Monja worktree collision:** snapshot status, use an explicit file
  allowlist, inspect final diffs, and never clean, reset, stage, commit, or push.
- **Unproven Node compatibility:** capability-check ESM and global fetch, record
  the tested version, and avoid changing package `engines` without a dedicated
  compatibility decision and evidence.

## Open Questions

The deterministic design is complete without live-environment answers. The
remaining operator decisions are tracked in
`design-docs/user-qa/qa-monja-typescript-sdk-command-node.md` and must be
resolved before claiming live verification.

## Addressed Review Feedback

- `comm-000014`, mid finding at the former line 113: added
  `nodes/node-monja-command.json`, the exact `workflow.json` `nodeFile` and step
  linkage, fixed command metadata, working-directory behavior, and
  `variables.workflowInput.graphql` routing.
- `comm-000014`, mid finding at the former line 174: defined deterministic
  `allowInsecureLocalhost` derivation for exact loopback HTTP only, remote HTTP
  rejection, HTTPS live defaults, README/EXPECTED_RESULTS obligations, and
  positive and negative verification cases.
- `comm-000017`, mid finding at the former line 277: added a pure observable
  pre-network URL-policy seam and full policy matrix, retained end-to-end mock
  success only on `127.0.0.1`, and removed any requirement for deterministic
  `localhost` resolution or IPv6 listener availability.
- `comm-000020`, mid finding at the former line 100: defined the generated
  private `type: module` consumer manifest with its exact tarball dependency,
  pinned TypeScript and Node typings, the complete strict NodeNext config, and
  verification that emitted ESM resolves `@monja/client` only from the
  isolated consumer.
