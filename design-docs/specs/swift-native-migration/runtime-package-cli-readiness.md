# Riela Swift Native Migration Design: Runtime, Package, CLI, and Readiness Tasks

## TASK-005 Runtime Session, Message Store, And Publication Boundary

TASK-005 ports the first Swift runtime-owned session and message boundary needed for deterministic workflow execution. The scope is intentionally narrower than the full SQLite runtime: Swift should expose the core value types, store protocols, publication APIs, and deterministic in-memory behavior that later SQLite, CLI, GraphQL, server, package, and event slices can reuse.

Ownership rules:

- `RielaCore` owns session and message value types, runtime store protocols, publication request/result types, candidate output normalization, and output validation helpers that are independent of a concrete persistence backend.
- `RielaCLI` may host a minimal deterministic runner or command surface only when it exercises those core runtime APIs without replacing the TypeScript/Bun production fallback.
- `RielaAdapters`, `CodexAgent`, `ClaudeCodeAgent`, `CursorCLIAgent`, and official SDK adapters remain provider-output boundaries. They may return inline candidate payloads or write to a runtime-provided candidate path, but they must not publish final workflow messages.
- Candidate-path staging is an execution-attempt detail. The runtime provisions and clears the candidate path before an attempt, reads or copies the submitted candidate after the adapter returns, validates the normalized business payload, records the attempt result, then finalizes the staging location as non-authoritative plumbing. Runtime publication must reject ambiguous candidate sources so adapter output or inline candidates cannot bypass a reserved candidate path. Runtime staging must reject unsafe path components before filesystem use and must verify prepared/finalized staging directories stay under the configured staging root.
- Runtime staging must also validate existing path components before creation and the resolved staging directory after creation so safe-looking symlink components under the staging root cannot redirect candidate paths outside the root.
- Legacy worker mailbox compatibility is out of scope and must not be reintroduced. TASK-005 must not add `RIELA_MAILBOX_DIR`, `inbox/input.json`, `outbox/output.json`, or execution-local inbox/outbox message APIs.

Core API shape:

- `WorkflowSession` records the workflow id, session id, status, entry step, current step, created/updated timestamps, and accepted step execution summaries needed by deterministic inspection tests.
- `WorkflowStepExecution` records step id, node id, attempt ordinal, backend, status, accepted output metadata, and provider-owned adapter output metadata without treating adapter output as a published workflow message.
- `WorkflowMessageRecord` mirrors the TypeScript `workflow_messages` boundary: runtime-generated communication id, workflow execution id, from/to step ids, routing scope, delivery kind, source step execution id, transition condition, payload JSON, optional artifact references, lifecycle state, and created order.
- Runtime-owned message input resolution converts prior `WorkflowMessageRecord` rows for the target step into one deterministic structured execution input with ordered message records, merged payload, communication ids, and source step ids before any adapter call, then applies the merged payload to the `AdapterExecutionInput` boundary.
- Runtime-owned direct message publication creates deliverable messages, and input resolution consumes only delivered or already-consumed workflow message rows while excluding created, failed, and superseded rows.
- `WorkflowRuntimeStore` or equivalent protocols must split session mutation from message publication closely enough that later SQLite-backed persistence can fail message writes deterministically. A failed message append must prevent downstream delivery from being reported as published.
- Deterministic in-memory implementations should use injectable clocks and monotonic id generation so tests can assert exact session ids, execution ids, communication ids, created order, status transitions, and publication failure behavior without real SQLite or filesystem state.

Publication flow:

1. Runtime creates or resumes a `WorkflowSession` and records a step execution attempt.
2. Runtime resolves prior `WorkflowMessageRecord` rows into one structured adapter/executor input object.
3. Adapter or executor returns a provider-owned `AdapterExecutionOutput`, inline business candidate, or candidate-file submission.
4. Runtime normalizes the candidate using the same output-envelope rules already shared by Swift adapters.
5. If the node declares an output contract, runtime validates the schema definition and normalized business payload before publication. Malformed JSON, invalid envelopes, malformed schema definitions, schema failure, and `completionPassed: false` failure paths must be deterministic and must not publish downstream workflow messages. Swift validation must preserve the TypeScript JSON Schema subset for unsupported keyword rejection, nested properties/items, additionalProperties, enum, const, string and numeric bounds, strict integer checks, valid patterns, and anyOf/oneOf/allOf combinators.
6. After validation succeeds, runtime writes the accepted output artifact or in-memory equivalent, updates the session step execution state, and publishes downstream `WorkflowMessageRecord` rows generated from the accepted output only.
7. TASK-005 must fail closed for transition shapes it does not yet implement. Cross-workflow `toWorkflowId`, `resumeStepId`, and fanout transitions must not be silently converted into direct in-workflow messages.
8. External root output selection remains runtime-owned: published workflow output comes from the latest accepted root-scope output node metadata, not from an arbitrary adapter response or merely because a step has no downstream transitions.

Validation requirements:

- Inline adapter payloads and candidate-path file payloads must pass through one normalization and validation path.
- Candidate-path files must be rejected when they are missing, stale from a previous attempt, malformed, non-object when an output contract requires an object, or outside the runtime-provided staging location.
- Output-contract retries may be modeled minimally in TASK-005, but final-attempt failure must leave the step failed and must not create downstream messages.
- Provider errors, policy-blocked adapter failures, timeout failures, and invalid output failures must update session state deterministically without fabricating successful messages.
- Unsupported transition semantics must fail before accepted output or workflow message publication.
- Published messages must use runtime-generated ids and created order; workers never provide communication ids.

Rollout constraints:

- TypeScript/Bun remains the production runtime and fallback while Swift runtime parity is incomplete.
- TASK-005 should prefer in-memory deterministic behavior over partial SQLite writes. The SQLite-backed implementation can follow once the Swift API shape matches the existing `workflow_messages` contract.
- CLI exposure should remain minimal until TASK-007; any Swift CLI smoke command added in TASK-005 must be clearly scaffold/parity-only.
- Cursor-specific behavior remains isolated in `CursorCLIAgent`; TASK-005 adds no Cursor CLI mode, stream, auth, or `official/cursor-sdk` behavior.
- Tests must use injected adapters/stores/clocks and synthetic candidates. They must not require live LLM credentials, local agent binaries, network access, or the TypeScript runtime.

## TASK-006 Package, Add-on, Event, Hook, GraphQL, And Server Contract Boundary

TASK-006 extends the additive Swift migration beyond the core runtime session
shape into the compatibility contracts needed by package discovery, add-on
resolution, event dry-runs, hook recording, GraphQL inspection, and server
request routing. This slice is contract-first: it should expose deterministic
Swift value types, parsers, validators, projections, and injected ports without
making the Swift runtime the production server or package installer.

Scope:

- `RielaAddons` owns workflow package manifest loading and validation
  contracts, node add-on descriptors, declarative add-on execution requests,
  add-on resolve results, and add-on failure diagnostics.
- `RielaEvents` owns event source and binding DTOs, external event envelopes,
  event validation diagnostics, dry-run trigger requests/results, receipt
  projection contracts, and injected trigger/reply/receipt ports.
- `RielaHook` owns hook vendor/event parsing, hook recording controls, hook
  context extraction from environment and payload, redaction-safe payload
  capture, and hook-event store records.
- `RielaGraphQL` owns Swift DTO projections over the TASK-005 runtime session,
  step execution, workflow message, hook event, event receipt/reply dispatch,
  and control-plane result shapes. It should expose schema-compatible contract
  text or field descriptors without requiring a live GraphQL HTTP stack.
- `RielaServer` owns request and route contracts for `/`, `/overview`,
  `/graphql`, and `/healthz`, including request envelope parsing, method
  handling, status/content-type response descriptors, and server context
  projection. It must not start long-running HTTP loops in this slice.

Package manifest compatibility:

- The Swift package manifest contract maps the TypeScript surfaces in
  `packages/riela/src/workflow/packages/manifest.ts`,
  `packages/riela/src/workflow/packages/types.ts`, and
  `packages/riela/src/workflow/packages/install-validation.ts`.
- Manifest names must use the same safe package-name rule, including optional
  scope prefixes and lower-case package identifiers.
- Package-relative paths must normalize using POSIX separators and reject empty
  paths, absolute paths, `..`, and traversal above the package root.
- Supported package kinds remain `workflow` and `node-addon`; omitted kind
  defaults to `workflow`.
- Skills, workflow metadata, dependency declarations, dependency add-on locks,
  integrity metadata, and add-on entries should be modeled as value contracts
  with deterministic validation issues. Unknown or unsupported keys should fail
  closed where the TypeScript validator currently rejects them.
- Validation workflow roots should be represented as an injected filesystem
  planning contract. TASK-006 must not copy directories, install packages, run
  package scripts, or mutate project/user scopes.

Add-on execution compatibility:

- The Swift add-on boundary maps
  `packages/riela/src/workflow/addon-types.ts`,
  `packages/riela/src/workflow/addon-package-boundary.ts`, and
  `packages/riela-addons/src/node-addons/*`.
- Add-on definitions remain declarative. Resolvers receive node payload,
  variables, source metadata, and explicit options, not workflow engine
  internals, session stores, communication ids, candidate paths, or mutable
  runtime state.
- Sync and async add-on boundaries must be distinguishable so an async-only
  add-on cannot accidentally run through a sync validation path.
- Built-in add-on names and versions should remain stable in authored workflow
  JSON. Swift may expose typed config DTOs for known built-ins, but unknown
  third-party add-ons stay data-driven and fail with deterministic diagnostics
  when no resolver is injected.
- Add-ons may construct candidate business payloads or dispatch intent records
  through injected ports. They must not publish workflow messages, allocate
  communication ids, execute agent backends directly, or reach into runtime
  internals.

Event dry-run compatibility:

- The Swift event contract maps `packages/riela-events/src/types.ts`,
  `packages/riela-events/src/runtime-ports.ts`,
  `packages/riela/src/events/validate.ts`,
  `packages/riela/src/events/manual-emit.ts`, and related input-mapping
  helpers.
- Event source validation should cover supported source kinds, unique ids,
  route path conflicts, HTTP path syntax, secret/env var names, template
  reference validation, and binding output-destination checks.
- Dry-run trigger execution should normalize an external event envelope, apply
  matching bindings and input mappings, and return deterministic trigger
  summaries through injected ports. It must not open live gateways, poll remote
  APIs, write receipts, send chat replies, or run workflows unless a test
  supplies an explicit mock port.
- Event envelopes preserve `sourceId`, `eventId`, `provider`, `eventType`,
  `receivedAt`, `dedupeKey`, actor, conversation, input, and optional artifact
  references. Raw payload persistence must use redacted or metadata-only
  contracts where the TypeScript path redacts provider payloads.

Hook compatibility:

- The Swift hook contract maps `packages/riela-hook/src/types.ts`,
  `packages/riela-hook/src/parse.ts`,
  `packages/riela-hook/src/context.ts`,
  `packages/riela-hook/src/redaction.ts`, and
  `packages/riela-hook/src/recorder-contracts.ts`.
- Supported hook vendors remain `claude-code`, `codex`, and `gemini`. Known
  event names should normalize case and punctuation like the TypeScript parser,
  with unknown events represented explicitly instead of rejected solely for
  being new.
- Hook payload parsing must require non-empty `session_id`,
  `hook_event_name`, and `cwd`; optional `transcript_path` may be string, null,
  or omitted; optional `model` must be a string when present.
- Recording controls preserve `RIELA_HOOK_RECORDING=auto|off|required`,
  `RIELA_HOOK_STRICT`, and `RIELA_HOOK_CAPTURE_RAW=redacted|metadata-only|full`.
  Required mode fails when workflow/node execution environment is incomplete;
  auto mode returns no Riela context instead of failing.
- Redaction must replace sensitive key values, including auth, API key, secret,
  token, password, credential, private key, stdout, stderr, output, and command
  output fields. Hook records store payload hashes and optional payload refs;
  they must not persist full raw payloads by default.

GraphQL and server compatibility:

- `RielaGraphQL` maps `packages/riela-graphql/src/dto.ts`,
  `packages/riela-graphql/src/control-plane-service.ts`, and
  `packages/riela-graphql/src/schema-contract.ts`.
- DTO projection should be lossy only where the TypeScript control plane is
  already projection-based: runtime-internal stores remain private, while
  sessions, step executions, communications, hook events, event receipts, reply
  dispatches, logs, and LLM session messages expose stable inspection fields.
- Control-plane service protocols should be injected and deterministic. Running,
  continuing, or mutating workflows through GraphQL may be represented as result
  contracts, but TASK-006 should not add final CLI parity or a live control
  server.
- `RielaServer` maps `packages/riela/src/server/api.ts`,
  `packages/riela/src/server/graphql.ts`, and
  `packages/riela-server/src/contracts.ts`.
- Server request contracts should parse GraphQL JSON envelopes, reject missing
  or non-object bodies deterministically, normalize variables to an object,
  preserve optional operation names, propagate bearer tokens and manager session
  ids through context, and strip ambient manager execution context from
  inherited environment before request execution.
- Route contracts should keep `/` and `/overview` read-only, `/graphql`
  delegated to the GraphQL contract, and `/healthz` returning a deterministic
  service/status body. Unsupported methods and unknown paths should produce
  deterministic response descriptors.

Rollout constraints:

- TypeScript/Bun remains the production fallback. TASK-006 may add Swift tests
  and library surfaces only.
- No live network chat gateways, live HTTP server loops, package installation
  side effects, package checkout mutation, or final CLI cutover belongs in this
  slice.
- Tests must use fixture manifests, fixture event configs, fixture hook payloads,
  in-memory stores, injected clocks, injected filesystems, and injected
  GraphQL/server service ports. They must not require network access, live
  chat credentials, local agent binaries, or package installation side effects.
- Cursor CLI behavior remains isolated in `CursorCLIAgent`; TASK-006 introduces
  no Cursor-specific add-on, event, GraphQL, hook, or server behavior.

## TASK-007 Swift CLI Validate, Inspect, And Deterministic Run Parity

TASK-007 introduces additive Swift `RielaCLI` command parsing and deterministic
execution behavior for parity tests. The Swift CLI should prove that the native
targets can load, validate, inspect, and run deterministic mock workflows without
changing the production TypeScript/Bun command path or release fallback.

Command scope:

- `workflow validate <name>` loads workflows through the same direct/project/user
  resolution concepts as the TypeScript CLI. It must support `--scope
  auto|project|user`, `--workflow-definition-dir`, `--output text|json`, and
  `--node-patch <json|@file|file>` for non-persistent node setting overrides.
  Structural validation is passive by default. `--executable` may report
  deterministic readiness/preflight results through injected Swift contracts,
  but tests must not require live agent CLIs, credentials, network access, or
  package installation side effects.
- `workflow inspect <name>` loads the same resolved workflow and reports
  step-addressed structure, source scope/path, entry and manager step ids,
  reusable node ids, cross-workflow dispatch ids, counts, defaults, callable
  input/output contracts, add-on source summaries, and runtime readiness
  descriptors. `--structure` remains a text-only compact step/description view;
  `--output json` must preserve the full inspection summary rather than the
  compact structure projection.
- `workflow run <name-or-workflow-json>` is limited to deterministic local
  execution in this slice. It must accept `--variables <json|@file|file>`,
  `--node-patch <json|@file|file>`, `--mock-scenario <path>`, `--output
  text|json`, `--max-steps`, `--max-concurrency`, `--max-loop-iterations`,
  `--default-timeout-ms`, `--timeout-ms`, `--artifact-root`, `--session-store`,
  and `--working-dir` / `--working-directory` where the corresponding Swift
  runtime contracts already exist. Temporary workflow JSON may be supported for
  deterministic fixture runs, but registry-backed runs, remote `--endpoint`,
  package checkout mutation, live gateways, live HTTP server loops, and final
  release cutover remain outside TASK-007.

Deterministic run behavior:

1. CLI parsing normalizes options before workflow loading and fails malformed
   input with deterministic exit codes: usage errors return `2`; load,
   validation, and execution failures return `1`; successful validation,
   inspection, or terminal mock execution returns `0`.
2. Workflow loading must apply node patches in memory only and must not write
   `workflow.json`, `nodes/node-*.json`, package manifests, event configs, hook
   records, registry records, or scoped checkout metadata.
3. Runtime execution uses TASK-005 session, step execution, candidate
   normalization, output-contract validation, and workflow message publication
   APIs. Adapters and add-ons still return candidate payloads only; the CLI must
   not allocate communication ids or publish messages directly.
4. Mock scenario responses map by step/node execution id consistently with the
   TypeScript `ScenarioNodeAdapter`: an entry may be a single response or a
   sequence, output-contract retry attempts advance deterministically, and
   missing entries fall back to the deterministic local adapter.
5. Scenario failure, provider failure, `completionPassed: false`, invalid
   output contracts, unsupported transition semantics, and message append
   failures must leave session state deterministic and must not fabricate
   downstream workflow messages.
6. JSON stdout must remain machine parseable. Human progress, verbose/debug
   diagnostics, and validation issue text belong on stderr or text output only.

TypeScript/Bun parity references:

- `packages/riela/src/cli/argument-parser.ts` defines option spelling,
  value requirements, and enum validation.
- `packages/riela/src/cli/workflow-command-handler.ts` defines current
  `workflow validate` and `workflow inspect` text/JSON output shape.
- `packages/riela/src/cli/workflow-run-command.ts` defines local run,
  temporary workflow, variables, node patch, registry-run, and endpoint
  boundaries. TASK-007 implements only the deterministic local subset needed for
  Swift parity.
- `packages/riela/src/workflow/scenario-adapter.ts` defines mock-scenario
  response sequencing and deterministic fallback behavior.
- `packages/riela/src/workflow/engine/workflow-runner.ts` and
  `packages/riela/src/workflow/engine/step-result-finalization.ts` define
  the runtime-owned finalization behavior that Swift must preserve through
  TASK-005 APIs.

Codex-reference mapping:

- The preferred `../../codex-agent` root remains unavailable for this checkout.
  The observed adjacent `../codex-agent` repository is a reference only, not an
  implementation source.
- `../codex-agent/dist/sdk/mock-session-runner.d.ts` shows the reference
  project's deterministic mock-runner pattern: synthetic sessions, recorded
  calls, injected options, explicit completion, and no live Codex process.
  Swift TASK-007 should use the same testing principle while keeping Riela's
  workflow session/message semantics under `RielaCore`.
- Cursor-specific behavior stays isolated in `CursorCLIAgent`. `RielaCLI`
  may parse workflow options and dispatch through provider-neutral contracts,
  but it must not expose Cursor mode, stream format, or auth-probe details as
  core workflow or CLI concepts.

Rollout constraints:

- TypeScript/Bun remains the documented production fallback until Swift
  validation, inspect, deterministic run, package, event, GraphQL, hook,
  adapter, and macOS archive gates pass.
- TASK-007 must not remove, rename, or shadow existing TypeScript CLI command
  behavior in release packaging.
- Tests must exercise Swift through injected stores, clocks, scenario adapters,
  filesystems, and process/readiness probes. They must not require live local
  agent binaries, LLM credentials, network access, repository-owned npm
  installs, package checkout mutation, or long-running server loops.

## TASK-008 Packaging And Homebrew Cutover Readiness Gates

TASK-008 defines the additive Swift release artifact contract and the gates that
must remain closed before Homebrew or published release assets switch away from
the TypeScript/Bun executable. This slice prepares deterministic build and
documentation surfaces only. It must not tag a release, upload GitHub release
assets, update `tacogips/homebrew-tap`, remove the Bun archive path, or make the
Swift executable production by default.

Artifact contract:

- The Swift executable product remains named `riela`, matching
  `Package.swift`'s `.executable(name: "riela", targets: ["RielaCLI"])`
  product and the installed command name.
- The local release executable path is the `riela` binary under the explicit
  Xcode SwiftPM release bin path returned by:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
      build -c release --product riela --show-bin-path
  ```

- Swift Homebrew-readiness staging must copy that product to
  `dist/swift-homebrew/work/riela-<version>-darwin-<arch>/bin/riela`
  before creating an archive. The archive payload shape remains
  `bin/riela` plus repository README or release notes, so install behavior
  can be smoke-tested without formula logic changes.
- Pre-cutover Swift archive names must be distinct from current Bun production
  archives:

  ```text
  dist/swift-homebrew/riela-swift-<version>-darwin-arm64.tar.gz
  dist/swift-homebrew/riela-swift-<version>-darwin-x64.tar.gz
  ```

- Each Swift archive must have a sibling `.sha256` file generated by the same
  deterministic checksum policy as `scripts/build-homebrew-release.sh`.
- Current production Bun/Homebrew archives remain
  `dist/homebrew/riela-<version>-darwin-arm64.tar.gz`,
  `dist/homebrew/riela-<version>-darwin-x64.tar.gz`, and Linux variants
  until the final cutover gate is accepted.

Homebrew cutover gates:

- The TypeScript/Bun runtime remains the documented production fallback and the
  Homebrew formula source until TASK-009 accepts final parity, security, and
  adversarial implementation review.
- A Swift formula preview may be rendered or tested only against local
  `file://` archives or unpublished CI artifacts. It must not be committed to
  the tap, uploaded to GitHub releases, or described as the default install
  path.
- The cutover is blocked until Swift validation, inspect, deterministic run,
  package validation, event trigger dry-run, GraphQL manager-control, hook
  context parsing, adapter output normalization, SQLite-backed session/message
  persistence, and macOS archive smoke gates all pass in deterministic
  verification.
- Smoke verification must prove `riela --help`, `riela workflow validate
  <fixture> --output json`, `riela workflow inspect <fixture> --output json`,
  and deterministic `riela workflow run <fixture> --mock-scenario <path>
  --output json` through the archived Swift executable without live agent
  binaries, credentials, network access, package checkout mutation, release
  upload, or tap mutation.
- Any script or manifest added for Swift packaging must be dry-run friendly,
  deterministic, explicit about the artifact directory, and safe to execute on
  macOS without publishing side effects.

Codex-reference mapping:

- The preferred `../../codex-agent` reference root remains unavailable in this
  checkout; the adjacent `../codex-agent` repository is reference-only.
- `../codex-agent/package.json` shows a stable package executable contract via
  `bin`, a restricted package file list, and a prepack build step. TASK-008 uses
  that as a structural reminder to keep release artifact contents explicit, but
  does not copy codex-agent packaging code or introduce npm package publishing
  behavior.
- Cursor CLI behavior remains isolated in `CursorCLIAgent`; packaging gates do
  not add Cursor mode, stream, auth, or `official/cursor-sdk` behavior to
  provider-neutral modules or Homebrew scripts.
