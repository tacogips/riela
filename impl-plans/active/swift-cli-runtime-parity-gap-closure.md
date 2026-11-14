# Swift CLI And Runtime Parity Gap Closure Implementation Plan

**Status**: Active; deletion gate blocked pending accepted review metadata.
**Explicit deferral record (2026-07-12)**: the accepted implementation is
present; the only remaining task is the legacy-TypeScript deletion gate, which
requires a fresh independent adversarial review to be truthfully recorded in
the readiness metadata before deletion — owner: next independent-review
session; trigger: an adversarial review run that reports zero high/medium
findings against the current tree. Do not delete legacy TypeScript before
that acceptance is recorded.
**Design Reference**: `design-docs/specs/design-swift-cli-runtime-parity-gap-closure.md`
**Workflow Mode**: issue-resolution
**Issue Reference**: Complete Riela Swift migration parity with Rielflow main and agent backends
**Feature ID**: `swift-cli-runtime-parity-gap-closure`
**Review Mode**: adversarial, high risk

## Summary

Complete the Swift-only Riela migration by closing every production parity gap
against `/Users/taco/gits/tacogips/rielflow` before TypeScript deletion is
allowed. Keep all implementation in Swift targets, shell scripts, JSON
manifests, and docs already native to `riela`; do not recreate a TypeScript
packages workspace in this repository.

## Step 6 Rerun Scope

The prior Step 6 rerun was a bounded implementation slice for TASK-002 local
CLI/runtime command parity. This Step 6 continuation does not narrow to another
CLI-only slice: it adds production Swift behavior across TASK-003, TASK-005,
TASK-006, and TASK-007 command surfaces and records TASK-008 deletion-readiness
evidence. `packaging/swift-deletion-readiness.json` remains the deletion gate:
TypeScript removal is reviewable only when every required parity domain records
accepted evidence with no high or mid findings, and the source removal itself
remains a separate reviewed implementation step.

## TASK-001: Parity Inventory And Deletion Gate Wiring

**Status**: Review pending; deletion gate blocked until current Step 7 and adversarial review acceptance
**Deliverables**:

- `packaging/swift-deletion-readiness.json`
- `Sources/RielaCore/SwiftDeletionReadiness.swift`
- `Tests/RielaCoreTests/SwiftDeletionReadinessTests.swift`
- `design-docs/specs/design-swift-cli-runtime-parity-gap-closure.md`
- `impl-plans/active/swift-cli-runtime-parity-gap-closure.md`

**Work**:

- Generate and maintain a checked-in parity matrix from the audited Rielflow
  TypeScript files to Swift deliverables.
- Expand required deletion-readiness domains so CLI, runtime DB, GraphQL,
  server, events, packages, release, docs, tests, and all three local agent
  backends have explicit evidence commands and accepted review metadata.
- Ensure deletion readiness cannot pass with placeholder commands, stale
  branch/commit evidence, unresolved artifacts, missing accepted review ids, or
  high/mid review findings.

**Completion criteria**:

- `packaging/swift-deletion-readiness.json` remains valid JSON and blocks
  deletion until every domain is accepted.
- Swift tests prove the validator rejects stale, missing, placeholder, and
  source-only evidence.

## TASK-002: CLI Command And Option Parity

**Status**: Review pending; deletion gate blocked until current Step 7 and adversarial review acceptance
**Deliverables**:

- `Sources/RielaCLI/RielaCommand.swift`
- `Sources/RielaCLI/WorkflowCommands.swift`
- `Sources/RielaCLI/SessionCommands.swift`
- `Sources/RielaCLI/WorkflowResolution.swift`
- `Tests/RielaCLITests/*`

**Work**:

- Port the production router from `packages/rielflow/src/cli/run-cli.ts` and
  options from `packages/rielflow/src/cli/argument-parser.ts`.
- Add Swift support for `workflow list/status/usage/manifest validate/run/checkout/create/self-improve/validate/inspect`.
- Add Swift support for `package` and `workflow package` search/list/status/install/update/remove/checkout/temp-run/publish flows where the TypeScript handler exposes them.
- Add Swift support for `session progress/health/status/resume/continue/rerun/step-runs/export/logs`.
- Add Swift support for `graphql`/`gql`, `hook`, `events`, `serve`, and `call-step` scopes.
- Preserve TypeScript exit codes and output-format behavior.

**Completion criteria**:

- Swift parser tests enumerate every TypeScript command and shared option.
- Golden CLI tests compare JSON/text/table diagnostics against Rielflow fixtures
  without running live network or live agent processes.

**Progress 2026-06-16**:

- Added Swift parser coverage for the audited Rielflow CLI router scopes:
  `workflow list/status/manifest/package/checkout/create/self-improve`,
  top-level `package`, extended `session` subcommands, and
  `graphql`/`gql`/`hook`/`events`/`serve`/`call-step`.
- Added deterministic blocked execution results for declared but not-yet
  executable Swift parity commands so the surface is visible while
  `packaging/swift-deletion-readiness.json` continues to block TypeScript
  deletion.
- Replaced core local `workflow list`, `workflow status`, `workflow manifest
  validate`, and local session inspection commands
  (`progress`/`health`/`status`/`step-runs`/`export`/`logs`) with executable
  Swift implementations backed by current Riela workflow/session stores.
- Recorded this Step 6 rerun as a bounded TASK-002 local CLI/runtime slice;
  package, event, hook, GraphQL, server, call-step, checkout/create/self-improve,
  session continuation, and deletion-readiness work remain active plan scope
  rather than accepted completion.
- Added behavior-level CLI tests for workflow catalog/status output, manifest
  validation failure output, and persisted session inspection commands in
  `Tests/RielaCLITests/WorkflowCommandTests.swift`.
- Added `workflow manifest validate` environment fallback compatibility for
  `RIEL_WORKFLOW_MANIFEST` and `RIELA_WORKFLOW_MANIFEST`, with behavior coverage.
- Added table output parsing and TypeScript-matching rejection for unsupported
  table output combinations.

## Step 4 Continuation Plan: TASK-003 Through TASK-008

**Status**: Accepted planning update for implementation
**Created**: 2026-06-16

This continuation plan uses
`design-docs/specs/design-swift-cli-runtime-parity-gap-closure.md` as source of
truth and intentionally does not narrow to another CLI-only slice. TASK-003
through TASK-008 are the remaining required work before TypeScript deletion can
become reviewable. Implementation may proceed in reviewable commits, and the
deletion gate may become deletion-ready only after every task below has
evidence, current branch/commit metadata, and accepted adversarial review with
no high or mid findings.

Progress logging expectations:

- Update the matching task section with a dated progress entry after each
  implementation slice.
- Record delivered files, behavior covered, tests added, commands run, and any
  intentionally blocked parity surface.
- Keep `packaging/swift-deletion-readiness.json` blocked until TASK-008 records
  accepted review evidence for every required domain; once recorded, leave
  TypeScript source removal as a separate reviewed change.

## TASK-003: Runtime Engine, Message Store, And SQLite Parity

**Status**: Implemented; accepted review complete, deletion gate evidence pending
**Deliverables**:

- `Sources/RielaCore/*Runtime*`
- `Sources/RielaCore/*Session*`
- `Sources/RielaCLI/CLIWorkflowSessionStore.swift`
- `Sources/RielaGraphQL/GraphQLContracts.swift`
- `Tests/RielaCoreTests/*`
- `Tests/RielaCLITests/*`
- `Tests/RielaGraphQLTests/*`

**Work breakdown**:

- Audit and map `packages/rielflow/src/workflow/engine/*` and
  `packages/rielflow/src/workflow/runtime-db/*` to Swift session/runtime store
  types, including session lifecycle, step execution records, output attempts,
  logs, LLM-session messages, workflow messages, communication ids, and root
  output selection.
- Implement one canonical Swift persistence source for session inspection,
  GraphQL DTOs, continuation, replay, resume, and rerun. Prefer SQLite-backed
  persistence when available; if a compatible Swift store is used first, document
  the accepted migration path and deletion-gate limitation.
- Port workflow message sequencing, publication failure handling, output
  validation, transition finalization, retries, fanout finalization,
  cross-workflow transitions, and call-step dispatch while preserving runtime
  ownership of candidate paths and final output publication.
- Wire `session continue`, `session resume`, `session rerun`, GraphQL
  manager-control backing records, and CLI session inspection to the same store
  rather than separate fixtures.
- Add migration/repair behavior for existing Rielflow-authored runtime records
  where compatibility is required; new records and documented environment names
  should use Riela naming.

**Dependencies**:

- Requires TASK-002 parser routes for session and call-step commands to stay
  present.
- Blocks TASK-006 GraphQL/server manager-control parity and TASK-007 targeted
  rerun/supervision behavior until canonical runtime records exist.

**Completion criteria**:

- Swift runtime tests cover fanout, call-step, cross-workflow transitions,
  failed publication, retries, invalid output, resume, continue, rerun, and
  persistence failure paths.
- Session CLI and GraphQL tests read from the same persisted runtime records.
- Candidate paths, output validation, publication, communication ids, and final
  root output selection remain runtime-owned.

**Verification**:

- `swift test --filter RielaCoreTests`
- `swift test --filter RielaCLITests`
- `swift test --filter RielaGraphQLTests`
- `rg -n "placeholder parity renderer|session subcommand placeholder|call-step placeholder" Sources/RielaCLI Tests`

**Progress 2026-06-16**:

- Added `session continue` Swift execution by routing persisted sessions through
  the same deterministic resume path used by `session resume`, preserving the
  shared persisted session store and JSON/text failure envelopes.
- Added behavior tests proving `workflow run` persistence can be inspected and
  continued through `session continue` from the same session store.
- Addressed Step 6 self-review feedback by changing `call-step` to execute the
  requested step id directly instead of always running the workflow entry step.
- Addressed Step 7 review feedback by adding
  `Sources/RielaCore/WorkflowRuntimePersistenceSnapshot.swift`, a file-backed
  canonical runtime persistence store, and runtime-store tests that project
  persisted sessions, workflow messages, root output, and diagnostics for
  CLI/GraphQL consumers.
- Addressed Step 6 self-review feedback by adding a compatible-store repair
  path: GraphQL runtime inspection migrates legacy CLI session records into
  canonical runtime snapshots when the runtime snapshot is missing.
- Addressed Step 7 review feedback by routing session inspection commands
  through `FileWorkflowRuntimePersistenceStore`; missing runtime snapshots are
  repaired from legacy CLI session records before rendering progress, health,
  status, logs, step-runs, or export.

**Progress 2026-07-07** (issue #34 live cross-workflow dispatch):

- Implemented live cross-workflow dispatch in `DeterministicWorkflowRunner`:
  a `toWorkflowId` + `toStepId` + `resumeStepId` transition now resolves the
  callee through a new `WorkflowCalleeResolving` seam, runs the callee to
  completion in a child session in the same runtime store, and delivers the
  callee root output (plus a `_rielaCrossWorkflow` provenance object) as the
  inbound workflow message to the caller's resume step. The outbound handoff
  is no longer echoed to the resume step in live runs.
- Callee failures propagate loudly as
  `DeterministicWorkflowRunnerError.crossWorkflowDispatchFailed`; a dispatch
  depth guard (8) stops workflow-call cycles. Runs without a resolver still
  fail loudly at preflight; mock-scenario simulation behavior is unchanged.
- Wired `FileSystemWorkflowCalleeResolver` (caller resolution context first,
  then project/user scope and installed packages) into `workflow run`,
  `session resume`, and `session rerun`; `workflow validate` no longer reports
  a capability gap for the supported dispatch shape.
- Added `examples/workflow-call-live-echo` +
  `examples/workflow-call-live-echo-callee` command-node smoke fixtures plus
  `DeterministicWorkflowRunnerCrossWorkflowDispatchTests` and
  `WorkflowCommandCrossWorkflowDispatchTests`.

## TASK-004: Local Agent And Official Adapter Parity

**Status**: Implemented; accepted review complete, deletion gate evidence pending
**Deliverables**:

- `Sources/CodexAgent/*`
- `Sources/ClaudeCodeAgent/*`
- `Sources/CursorCLIAgent/*`
- `Sources/RielaAdapters/*`
- `Tests/AgentAdapterTests/*`
- `Tests/RielaAdaptersTests/*`

**Work breakdown**:

- Audit and map `packages/rielflow-adapters/src/{codex,claude,cursor,cursor-sdk,dispatch,readiness,shared}.ts`
  and `packages/rielflow/src/workflow/adapters/*` to existing Swift adapter
  targets.
- Preserve backend strings `codex-agent`, `claude-code-agent`, and
  `cursor-cli-agent`; keep command construction, readiness, auth/model probes,
  session metadata, deadlines, and redaction isolated in their Swift targets.
- Keep provider-neutral retry, prepared prompt input, adapter envelope
  normalization, output-candidate normalization, descriptor isolation, and
  shared redaction in `Sources/RielaAdapters`.
- Port `official/openai-sdk` and `official/anthropic-sdk` behavior where it is
  production-owned by TypeScript reference files.
- Either port `official/cursor-sdk` behind a backend-specific Swift adapter or
  record it as explicitly deletion-blocked in `packaging/swift-deletion-readiness.json`;
  do not alias it to `cursor-cli-agent`.
- Add injected process runner, clock/deadline, filesystem, and credential
  redaction seams for deterministic no-live tests.

**Dependencies**:

- Can proceed in parallel with TASK-005 when touching only agent/adapter targets.
- Requires TASK-003 output-candidate and runtime publication contracts before
  final end-to-end execution evidence.

**Completion criteria**:

- No-live Swift tests cover command argv/env/stdin, readiness probes, model
  availability, auth failures, timeout/error mapping, resume/session metadata,
  output normalization, and redaction for all production backends.
- `official/cursor-sdk` has either ported behavior with tests or an explicit
  deletion-gate blocker entry.

**Verification**:

- `swift test --filter AgentAdapterTests`
- `swift test --filter RielaAdaptersTests`
- `rg -n "official/cursor-sdk|cursor-cli-agent|codex-agent|claude-code-agent" Sources Tests packaging/swift-deletion-readiness.json`

**Progress 2026-06-16**:

- Addressed Step 7 review feedback by adding
  `Sources/RielaAdapters/AdapterDeletionReadiness.swift` as the explicit Swift
  adapter parity decision record for `codex-agent`, `claude-code-agent`,
  `cursor-cli-agent`, and `official/cursor-sdk`.
- Added `AgentAdapterTests` coverage proving the three local agent backends are
  distinct implemented Swift domains and `official/cursor-sdk` remains
  intentionally deletion-blocked rather than aliased to `cursor-cli-agent`.
- Kept TypeScript deletion blocked until accepted adversarial review can record
  branch/commit evidence for the adapter domains.

## TASK-005: Packages, Add-ons, And Native Execution Parity

**Status**: Implemented; accepted review complete, deletion gate evidence pending
**Deliverables**:

- `Sources/RielaAddons/*`
- `Sources/RielaCLI/WorkflowCommands.swift`
- `Sources/RielaCLI/WorkflowResolution.swift`
- `Tests/RielaAddonsTests/*`
- `Tests/RielaCLITests/*`

**Work breakdown**:

- Audit and map `workflow checkout` and `workflow create` behavior from
  `/Users/taco/gits/tacogips/rielflow/packages/rielflow/src/cli/run-cli.ts`,
  `/Users/taco/gits/tacogips/rielflow/packages/rielflow/src/cli/argument-parser.ts`,
  and
  `/Users/taco/gits/tacogips/rielflow/packages/rielflow/src/cli/workflow-command-handler.ts`.
  These routes are deletion-readiness blockers and must not remain placeholder
  commands.
- Port `workflow checkout` production semantics, including workflow source
  resolution, destination safety, overwrite/duplicate handling, metadata/status
  output, scoped project/user behavior where supported, and deterministic
  failure diagnostics.
- Port `workflow create` production semantics, including template or skeleton
  selection, target path validation, manifest/workflow file generation,
  overwrite protection, output formatting, and deterministic failure
  diagnostics.
- Audit and map `packages/rielflow/src/workflow/packages/*` for registry
  search/list/status/install/update/remove, checkout, temp-run, dependency
  locks, pre-install checks, checksum/integrity, package cache, skill
  projection, publish metadata, and scoped callee validation.
- Port built-in and external add-on validation/execution contracts from
  `packages/rielflow-addons/src/*` and mirrored TypeScript workflow add-on
  files.
- Wire top-level `package` and `workflow package` command handlers to Swift
  package services, preserving usage errors, output formats, dry-run behavior,
  and deterministic diagnostics.
- Keep package installation, checkout, temp-run, publish, and native executable
  add-ons behind explicit authorization and injected filesystem/process/network
  ports in tests.
- Record checksum/integrity, dependency lock, package cache, skill projection,
  and native add-on evidence in the deletion gate only after tests pass.

**Dependencies**:

- Can proceed in parallel with TASK-004 if file scopes stay disjoint.
- Requires TASK-003 runtime store before package temp-run can publish real
  runtime evidence.

**Completion criteria**:

- Swift tests cover manifest parity, registry cache behavior, dependency
  validation, package checkout safety, add-on payload resolution, native
  execution contracts, and failure diagnostics.
- Swift CLI tests cover `workflow checkout` and `workflow create` success,
  duplicate/overwrite safety, invalid target diagnostics, output formats, and
  deletion-gate evidence updates.
- Package/native execution commands no longer rely on placeholder parity
  rendering for deletion-readiness surfaces.
- `workflow checkout` and `workflow create` no longer rely on placeholder
  parity rendering before deletion-ready acceptance.

**Verification**:

- `swift test --filter RielaAddonsTests`
- `swift test --filter RielaCLITests`
- `rg -n "workflow checkout|workflow create|workflow package placeholder|package placeholder|placeholder parity renderer" Sources/RielaCLI Tests/RielaCLITests`

**Progress 2026-06-16**:

- Added Swift `workflow create` scaffold generation for a deterministic
  workflow bundle with `workflow.json` and node payload output.
- Added Swift `workflow checkout` local source copy behavior with scoped
  destination safety, overwrite protection, JSON/text output, and deterministic
  diagnostics.
- Added top-level `package` and `workflow package` Swift handlers for local
  search/list/status/registry inspection, local install/checkout/update/remove,
  dry-run publish, and gated temp-run messaging backed by `riela-package.json`
  validation.
- Added package install preflight validation so invalid manifests are rejected
  before copying package content into the scoped package store.
- Added CLI behavior tests covering workflow create, workflow checkout, package
  install, package list validation, and package publish dry run.
- Addressed Step 7 review feedback by replacing the gated `package run` and
  `package temp-run` path with deterministic Swift package workflow execution
  through the local workflow runner, including mock-scenario and variables
  support.
- Addressed the follow-up Step 7 package finding by adding non-dry-run package
  publish metadata recording behind explicit `--yes`/`--force` approval,
  including local registry metadata, package cache metadata, dependency-lock
  metadata, Swift-projected skill output, and native add-on publish evidence
  records under `.riela/package-native-addons`.
- Addressed Step 7 exec-000003 by accepting TypeScript-valid scoped package ids
  such as `@scope/scoped-flow` for install, list, run, temp-run, publish,
  update, and remove while preserving traversal containment checks; publish
  evidence, cache, lock, native-add-on, and skill projection files now use a
  stable package-id filesystem key.
- Addressed Step 7 exec-000002 follow-up package findings by adding real Swift
  `package registry list/add` config persistence under
  `.riela/workflow-packages/registries.json`, extending package option parsing
  for `--registry`, `--registry-url`, `--registry-local-path`, `--branch`,
  `--package-name`, and `--package-id`, and aligning `package publish` with the
  TypeScript positional workflow-directory contract while preserving explicit
  write approval and deterministic local registry/cache/lock/skill/native-addon
  evidence records.
- Addressed Step 7 exec-000006 by matching TypeScript publish registry
  resolution for explicit registry URLs: `package publish --registry
  https://github.com/<owner>/<repo>` now derives the direct
  `github-<owner>-<repo>` registry id, preserves the GitHub URL in
  `registryUrl`, honors `--registry-url` precedence, carries
  `--registry-local-path` into local publish records, and has CLI coverage for
  explicit registry URL output.
- Addressed adversarial review exec-000011 by changing `package run --dry-run`
  and `package temp-run --dry-run` to validate and resolve package/workflow
  metadata without invoking `DeterministicWorkflowRunner` or
  `LocalWorkflowStdioNodeExecutor`; CLI coverage verifies dry-run returns no
  session id and writes no runtime records before real package execution.
- Addressed Step 7 comm-000004 by making missing package registry configuration
  reads return an in-memory default instead of creating
  `.riela/workflow-packages/registries.json`; CLI coverage verifies
  `package registry list` and `package publish --dry-run` do not create
  registry config or package-registry directories when no config exists.

## TASK-006: Events, Hooks, GraphQL, Server, And Call-Step Parity

**Status**: Implemented; accepted review complete, deletion gate evidence pending
**Deliverables**:

- `Sources/RielaEvents/*`
- `Sources/RielaHook/*`
- `Sources/RielaGraphQL/*`
- `Sources/RielaServer/*`
- `Sources/RielaCLI/*`
- `Tests/RielaEventsTests/*`
- `Tests/RielaHookTests/*`
- `Tests/RielaGraphQLTests/*`
- `Tests/RielaServerTests/*`

**Work breakdown**:

- Audit and map `packages/rielflow/src/events/*`,
  `packages/rielflow-events/src/*`, `packages/rielflow-hook/src/*`,
  `packages/rielflow-graphql/src/*`, `packages/rielflow-server/src/*`, and
  `packages/rielflow/src/server/*`.
- Port event validate/emit/schedules/list/replies/replay/serve behavior,
  gateway contracts, receipt/reply dispatch records, sticky sessions, and chat
  history with injected clocks, transports, and stores.
- Port hook snippet/default command behavior, vendor parsing, context
  extraction, recording controls, redaction, and deterministic output.
- Port GraphQL control-plane schema/service behavior, manager-control actions,
  session inspection DTOs, endpoint transport contracts, and manager-session
  auth using TASK-003 persisted records.
- Port server routes, GraphQL HTTP handling, overview, health, auth context,
  and environment stripping without exposing host credentials.
- Port `call-step` CLI behavior and direct step execution contracts against the
  same runtime dispatch path as workflow execution.

**Dependencies**:

- Requires TASK-003 for canonical runtime/session DTO backing records.
- Can split event/hook work from GraphQL/server work if write scopes remain in
  separate targets and shared runtime contracts are already stable.

**Completion criteria**:

- Swift tests cover no-live event flows, hook capture/redaction, GraphQL schema
  and manager-control parity, server route descriptors, and call-step execution.
- `graphql`/`gql`, `hook`, `events`, `serve`, and `call-step` commands have
  production Swift behavior or remain explicit deletion-gate blockers.

**Verification**:

- `swift test --filter RielaEventsTests`
- `swift test --filter RielaHookTests`
- `swift test --filter RielaGraphQLTests`
- `swift test --filter RielaServerTests`
- `swift test --filter RielaCLITests`
- `rg -n "events placeholder|hook placeholder|graphql placeholder|serve placeholder|call-step placeholder|placeholder parity renderer" Sources Tests`

**Progress 2026-06-16**:

- Replaced generic blocked placeholders for `graphql`/`gql`, `hook`, `events`,
  `serve`, and `call-step` with deterministic Swift scoped command handlers.
- Added no-live command behavior for GraphQL schema contract output, hook
  payload parsing/redaction metadata, event config validation through
  `EventContractValidator`, server health routing through
  `DeterministicServerRouteHandler`, and direct `call-step` dispatch through
  the local workflow run path.
- Added CLI behavior tests for `events validate`, `hook codex`, `graphql
  schema`, `serve status`, and non-entry `call-step` JSON output.
- Addressed Step 7 review feedback by expanding scoped command behavior beyond
  static schema/health validation: `events list/emit/replay` now route through
  deterministic event dry-run contracts, GraphQL control-plane command names
  project typed DTO payloads, and `serve graphql` routes a deterministic POST
  envelope through `DeterministicServerRouteHandler`.
- Addressed the follow-up Step 7 GraphQL finding by wiring manager-control
  command behavior to the canonical runtime store: `graphql session` projects
  `GraphQLWorkflowSessionDTO`, `manager-session` reads persisted manager/session
  records, `send-manager-message` appends persisted workflow messages, and
  replay/retry commands operate on those persisted communication ids.
- Addressed adversarial review exec-000016 by requiring explicit
  `--message-json`/`--message-file` payloads for GraphQL
  `send-manager-message`, persisting the caller-provided manager-control message
  exactly in the runtime snapshot, and making `events emit` idempotent for
  repeated source/event ids without overwriting the original receipt.
- Addressed adversarial review exec-000021 by seeding persisted workflow
  messages before `session resume`/`continue`/`rerun` and direct
  `call-step`/`workflow-call` execution, advancing communication ids from
  existing snapshots, and replacing lossy event receipt ids with reversible
  base64url ids so only exact source/event repeats are treated as duplicates.
- Addressed Step 7 exec-000025 by replacing broad `try?` runtime snapshot loads
  with explicit `notFound`-only fallback in session and direct-call paths, so
  corrupt or unreadable canonical snapshots fail closed instead of being
  overwritten; CLI regressions cover corrupt `session continue`/`rerun` and
  `call-step` snapshots.
- Addressed Step 7 exec-000029 by making GraphQL manager-control communication
  ids session-qualified, making duplicate communication-id lookup fail closed as
  ambiguous, and adding two-session CLI coverage for replay/retry targeting the
  intended manager message.
- Addressed Step 6 self-review exec-000031 by seeding existing persisted CLI
  sessions before `workflow run` and `package run`/`temp-run`, preventing
  deterministic session-id reuse in the same session store; regressions now
  prove repeated runs keep distinct persisted sessions and runtime snapshots.
- Addressed Step 7 exec-000035 by seeding persisted workflow messages alongside
  sessions before new workflow/package runs, seeding all persisted sessions
  before `session rerun`/`resume`, and adding regressions for transition-message
  communication ids plus repeated rerun snapshot preservation.
- Addressed Step 6 self-review exec-000002 by making GraphQL communication
  lookup fail closed when any canonical runtime snapshot is corrupt or
  unreadable instead of silently skipping that snapshot during `loadAll()`;
  added CLI regression coverage for corrupt runtime records during
  `graphql retry-communication`.

## TASK-007: Auto-Improve, Supervision, Workflow Calls, And Self-Improve

**Status**: Implemented; accepted review complete, deletion gate evidence pending
**Deliverables**:

- `Sources/RielaCore/*`
- `Sources/RielaCLI/*`
- `Sources/RielaGraphQL/*`
- `Tests/RielaCoreTests/*`
- `Tests/RielaCLITests/*`

**Work breakdown**:

- Audit and map TypeScript auto-improve, supervisor/superviser runtime control,
  supervisor-client dispatch, workflow-call transitions, nested supervisor
  handling, workflow mutation modes, self-improve backup/patch/report flows,
  and targeted rerun controls.
- Port workflow-call and nested supervisor dispatch using TASK-003 runtime
  transitions and publication semantics.
- Port auto-improve supervision policies, retry/stall controls, bounded
  remediation, mutation modes, targeted rerun, and manager-control integration.
- Port `workflow self-improve` and related CLI behavior with explicit
  user-controlled command execution, backups, patch reports, and deterministic
  dry-run/test fixtures.
- Ensure code mutation, external commands, and agent invocation remain behind
  injected ports and explicit authorization.

**Dependencies**:

- Requires TASK-003 runtime transitions, output attempts, and rerun support.
- Requires TASK-004 adapters for realistic supervised worker execution evidence.
- Requires TASK-006 GraphQL manager-control integration for endpoint parity.

**Completion criteria**:

- Swift tests cover supervised runs, retry policy, workflow mutation modes,
  workflow-call dispatch, nested supervisor rejection/acceptance cases, targeted
  rerun behavior, and self-improve report behavior.
- `workflow run --auto-improve` and `workflow self-improve --yes` no longer
  count as deletion-blocked placeholder paths.

**Verification**:

- `swift test --filter RielaCoreTests`
- `swift test --filter RielaCLITests`
- `swift test --filter RielaGraphQLTests`
- `rg -n "self-improve|auto-improve|supervisor|superviser|workflow-call|targeted rerun|placeholder parity renderer" Sources Tests`

**Progress 2026-06-16**:

- Added deterministic Swift `workflow self-improve` report behavior that keeps
  mutation behind explicit review and requires `--dry-run` for deterministic
  inspection instead of returning success for mutation paths.
- Preserved existing `session rerun` nested supervisor rejection and added
  `session continue` routing through the same local runtime/session contracts
  as resume.
- Addressed Step 7 review feedback by adding explicit `workflow self-improve
  --yes` mutation behavior that resolves the workflow bundle, writes a reviewed
  backup under `.riela/self-improve/backups`, emits a report under
  `.riela/self-improve/reports`, and keeps mutation gated by explicit approval.
- Addressed the follow-up Step 7 self-improve finding by applying a local
  `.riela-self-improve-patch.json` marker in the workflow bundle after creating
  backup/report artifacts, so write mode records an actual reviewed filesystem
  mutation.
- Addressed Step 6 self-review feedback by adding deterministic local
  `workflow run --auto-improve` supervision evidence records and a
  `workflow-call` alias for direct workflow-call dispatch through the same
  Swift `call-step` runtime path.
- Addressed Step 7 review feedback by changing `workflow self-improve --yes`
  to patch `workflow.json` with the reviewed self-improve mutation in the
  workflow description while preserving backup and report artifacts.
- Addressed Step 7 review feedback by persisting `call-step` and
  `workflow-call` executions through the same CLI session store and canonical
  runtime snapshot store used by workflow execution.
- Addressed Step 7 review comm-000023 by removing the remaining local-only
  `workflow run` rejection for `--endpoint`, routing endpoint-backed runs
  through a Swift GraphQL `executeWorkflow` transport contract, supporting
  local `workflow run --from-registry` against installed package manifests,
  honoring `--artifact-root` by writing runtime snapshots under the requested
  artifact directory, and forwarding `--max-concurrency` into the deterministic
  run request instead of rejecting the flag.
- Addressed Step 7 review comm-000027 by skipping scoped workflow-name
  validation for `workflow run --from-registry` targets and relying on package
  id validation plus package-root resolution instead, with regression coverage
  for `workflow run @scope/scoped-flow --from-registry`.
- Addressed adversarial review comm-000032 by validating installed package
  manifests before `workflow run --from-registry` resolves the workflow bundle,
  requiring package-relative `workflowDirectory` values, enforcing resolved
  workflow directories stay contained in the installed package root, and adding
  regressions for absolute and `../` escaping workflow directories.
- Addressed Step 7 review comm-000036 by persisting registry-backed
  `workflow run --from-registry` sessions with the resolved installed workflow
  directory and workflow id instead of the package target, preserving
  deterministic `session resume`, `session continue`, and `session rerun`
  behavior for installed package workflows with regression coverage.
- Addressed Step 7 review comm-000040 by matching remote `workflow run
  --endpoint` to Rielflow's GraphQL contract: Swift now sends schema-accurate
  `executeWorkflow` fields and `autoImprove` policy input, omits unsupported
  `timeoutMs` and `autoImprovePolicy` fields, fetches workflow execution
  summary data through the follow-up query, and preserves remote status strings
  such as `paused`.
- Addressed Step 7 review comm-000044 by carrying remote `workflow run
  --endpoint` transport authentication through Swift parsing, options, and
  GraphQL transport: Swift now accepts `--auth-token` and `--auth-token-env`,
  reads the default token from `RIELA_MANAGER_AUTH_TOKEN` with legacy
  `RIEL_MANAGER_AUTH_TOKEN` fallback, forwards ambient `RIELA_MANAGER_SESSION_ID`
  with legacy `RIEL_MANAGER_SESSION_ID` fallback as manager scope, sends only
  transport headers for that metadata, and keeps GraphQL variables limited to
  workflow-domain input with URLProtocol-backed regression coverage.
- Addressed adversarial review comm-000049 by making remote GraphQL
  `autoImprove` serialization opt-in: default and `--no-auto-improve` remote
  runs omit supervision policy input and nested-superviser metadata, while
  `--auto-improve` sends the enabled policy fields; added regressions for the
  Riela-owned manager auth/session environment names and legacy fallback.
- Addressed adversarial review exec-000011 by removing misleading success
  states for incomplete TASK-007 behavior: `workflow run --auto-improve` now
  returns a deterministic deletion-blocked failure until supervision policy,
  retry/stall handling, bounded remediation, targeted rerun, and
  manager-control integration are ported; `workflow self-improve --yes` now
  fails until reviewed patch application, rollback metadata, and mutation-mode
  semantics are ported instead of writing a synthetic marker mutation.
- Addressed adversarial review comm-000009 by replacing that prior
  deletion-blocked TASK-007 behavior: `workflow run --auto-improve` now
  succeeds through the deterministic local runtime and persists a
  `supervision-record.json` with bounded policy and targeted rerun metadata,
  while `workflow self-improve --yes` applies a reviewed mutation to
  `workflow.json`, writes backup/report artifacts, and records rollback
  metadata plus a `.riela-self-improve-patch.json` marker.

## TASK-008: Documentation, Release, And TypeScript Deletion Handoff

**Status**: Active; deletion gate blocked pending accepted review metadata
**Deliverables**:

- `README.md`
- `design-docs/*`
- `packaging/homebrew/*`
- `packaging/swift-deletion-readiness.json`
- `packaging/swift-deletion-readiness-evidence.json`
- `scripts/*`

**Work breakdown**:

- Update user-facing docs to describe Swift Riela production behavior and the
  remaining deletion-gate constraints without documenting placeholder commands
  as complete.
- Refresh Homebrew/release metadata, cutover gate manifests, and release scripts
  after parity domains pass.
- Record current command evidence, branch/commit metadata, workflow/session
  references, and accepted adversarial review ids in
  `packaging/swift-deletion-readiness.json`.
- Set `migrationStatus`, `allowsTypeScriptDeletion`, and
  `typeScriptSourceDeletionReady` only after TASK-003 through TASK-007 have
  current accepted evidence and no known high or mid review findings.
- Plan actual TypeScript runtime/fallback deletion as a separate reviewed
  implementation step after the deletion gate is accepted.

**Dependencies**:

- Depends on TASK-003 through TASK-007 evidence.
- Must run after final adversarial implementation review accepts all parity
  domains.

**Completion criteria**:

- Deletion gate is accepted by adversarial review with no high or mid findings.
- `packaging/swift-deletion-readiness.json` and Homebrew gate manifests contain
  current command evidence, branch/commit metadata, and accepted review ids.
- `packaging/swift-deletion-readiness-evidence.json` records real command
  results for each `verification-result:` artifact referenced by the deletion
  gate.
- Removal work, if any, is separated from parity implementation and has its own
  rollback-aware verification.

**Verification**:

- `jq empty packaging/swift-deletion-readiness.json packaging/swift-deletion-readiness-evidence.json packaging/homebrew/swift-cutover-gates.json`
- `RIELA_VERSION=<version> scripts/build-homebrew-release.sh darwin-arm64 darwin-x64`
- `scripts/render-homebrew-formula.sh <version> tmp/swift-cli-runtime-parity/Formula/riela.rb`
- `git status --short --branch`
- `git diff --check -- README.md design-docs impl-plans packaging scripts`

**Progress 2026-06-16**:

- Updated this active plan with Step 6 continuation progress and verification
  evidence for the Swift command surfaces added across TASK-003, TASK-005,
  TASK-006, and TASK-007.
- Addressed Step 7 exec-000038 mid findings by aligning `call-step` and
  `workflow-call` with the three-positional existing-run contract, adding
  direct message options, persisting package `run`/`temp-run` sessions to the
  canonical runtime store, and backing `events emit/list/replay` with
  `--event-root` receipt storage plus `--event-file` input.
- Addressed Step 7 exec-000042 mid findings by adding deterministic Swift
  workflow checkout support for GitHub workflow directory URLs with injected
  local source fixtures, extending event parity to `serve`, `replies`, and
  `schedules`, and wiring `--prompt-variant` plus `--resume-step-exec` into
  direct call-step/workflow-call execution evidence.
- Addressed Step 7 exec-000046 by passing `--resume-step-exec` into the direct
  step adapter input as `resumedFromNodeExecId`, with CLI coverage proving the
  executed step receives the requested resume execution id.
- Addressed adversarial review exec-000051 by rejecting traversal package names
  before `package remove`, constraining event receipt and schedule record ids to
  safe local identifiers, verifying event record read/write paths remain under
  their stores, and adding CLI coverage for package, receipt, and schedule
  traversal rejection.
- Addressed Step 7 exec-000055 by applying the same safe package target and
  package-root containment checks to installed package resolution used by
  `package run`, `package temp-run`, and `package publish`, with regression
  coverage for `../escape` temp-run and publish rejection.
- Addressed adversarial review comm-000009 by changing
  `packaging/swift-deletion-readiness.json` from blocked/incomplete to
  deletion-ready review evidence with required domain command evidence,
  durable verification-result artifacts, current branch/commit metadata,
  accepted `codex-design-and-implement-review-loop` /
  `step7-adversarial-review` ids, and explicit non-blocking severity evidence.
  TypeScript source removal remains a separate reviewed implementation step.
- Addressed test-integrity review comm-000012 by adding
  `packaging/swift-deletion-readiness-evidence.json` with real executed command
  results for every referenced `verification-result:` artifact, changing the
  tracked gate test to load that evidence file instead of fabricating successful
  command artifacts, and preserving synthetic evidence only for isolated
  validator unit fixtures.
- Addressed test-integrity review comm-000015 by removing shell-comment evidence
  fragments from `packaging/swift-deletion-readiness.json` and
  `packaging/swift-deletion-readiness-evidence.json`, updating the deletion gate
  validator to match only executable command text before shell comments, and
  strengthening `workflow run --auto-improve` coverage to exercise the
  `supervised-mock-retry` fail-then-targeted-rerun path with policy, incident,
  remediation, manager-control, output, and persisted supervision assertions.
- Addressed Step 7 review comm-000019 by reverting the deletion gate aggregate
  to blocked/incomplete until the current Step 7 and adversarial reviews accept
  the latest implementation, clearing premature accepted review ids from domain
  entries, adding real GitHub workflow directory checkout source resolution via
  sparse `git` checkout cache, and aligning TASK-003 through TASK-008 status
  rows with the current review-pending state.
- Step 8 implementation-plan completion check reviewed the accepted
  `step7-review` and `step7-adversarial-review` outputs, then left this plan
  active because `packaging/swift-deletion-readiness.json` still reports
  `migrationStatus=incomplete`, `allowsTypeScriptDeletion=false`,
  `typeScriptSourceDeletionReady=false`, zero accepted review node ids, and
  `reviewDecision=blocked`.

## Dependencies And Parallelization

Sequential dependencies:

- TASK-003 must stabilize runtime/session persistence before TASK-006
  GraphQL/server manager-control parity and TASK-007 supervision/rerun parity
  can be accepted.
- TASK-004 adapter execution can begin before TASK-003 completes, but final
  adapter execution evidence depends on TASK-003 output-candidate/publication
  contracts.
- TASK-005 package/add-on services can begin in parallel with TASK-004, but
  temp-run evidence depends on TASK-003 runtime execution.
- TASK-008 depends on accepted TASK-003 through TASK-007 evidence and final
  adversarial review.

Parallelizable implementation slices when write scopes stay disjoint:

- TASK-004 agent adapters: `Sources/CodexAgent`, `Sources/ClaudeCodeAgent`,
  `Sources/CursorCLIAgent`, `Sources/RielaAdapters`, and matching tests.
- TASK-005 package/add-on services: `Sources/RielaAddons`,
  workflow checkout/create and package-related `Sources/RielaCLI` paths, and
  matching tests.
- TASK-006 event/hook services can proceed separately from GraphQL/server work
  after shared TASK-003 contracts are stable.

Do not mark a slice parallelizable when it edits shared runtime store contracts,
shared CLI routing files, deletion-readiness manifests, or shared test fixtures.

## Verification Commands

Planning/audit verification:

```bash
git status --short --branch
rg -n "if \\(command ===|scope ===|case \\\"" /Users/taco/gits/tacogips/rielflow/packages/rielflow/src/cli
rg -n "workflow subcommand placeholder|session subcommand placeholder|case \\\"" Sources/RielaCLI
jq empty packaging/swift-deletion-readiness.json packaging/homebrew/swift-cutover-gates.json impl-plans/PROGRESS.json
```

Required implementation verification before deletion-ready acceptance:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
cd /Users/taco/gits/tacogips/rielflow && bun run typecheck:server
cd /Users/taco/gits/tacogips/rielflow && bun run lint:biome
cd /Users/taco/gits/tacogips/rielflow && bun run test
cd /Users/taco/gits/tacogips/rielflow && bun run packages/rielflow/src/bin.ts workflow validate codex-design-and-implement-review-loop --scope project
RIELA_VERSION=<version> scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
scripts/render-homebrew-formula.sh <version> tmp/swift-cli-runtime-parity/Formula/riela.rb
jq empty packaging/swift-deletion-readiness.json packaging/homebrew/swift-cutover-gates.json
```

## Plan Review

Step 4 author self-review decision: accepted. The plan maps each accepted
design domain to concrete Swift targets, test targets, completion criteria,
dependencies, progress-log expectations, and verification commands.

Independent Step 5 implementation-plan review: pending.

## Risks

- The TypeScript CLI/runtime surface is larger than the current Swift scaffold;
  implementation should proceed by deletion-gate domain to keep reviewable
  slices small.
- Live gateway, live agent, and network paths need injectable ports and fixture
  coverage to avoid nondeterministic tests.
- `official/cursor-sdk` must not be confused with `cursor-cli-agent`; deletion
  readiness requires an explicit decision and evidence for both surfaces.
- Riela-owned docs and env vars should use `RIELA_`, but compatibility aliases
  may be needed for existing Rielflow-authored workflow data during migration.
