# Swift CLI And Runtime Parity Gap Closure Design

## Status

Accepted feature-local planning design for the high-risk Swift-only Riela
migration parity pass.

## Feature Contract

- Workflow mode: issue-resolution
- Issue reference: Complete Riela Swift migration parity with Rielflow main and
  agent backends
- Feature id: `swift-cli-runtime-parity-gap-closure`
- Feature title: Riela Swift CLI/runtime migration parity with Rielflow main and
  agent backends
- Reference repository root: `/Users/taco/gits/tacogips/rielflow`
- Target repository root: `/Users/taco/gits/tacogips/riela`
- Review mode: adversarial

## Goal

Port every remaining production feature needed before the TypeScript runtime can
be deleted from Riela, using the current Rielflow TypeScript main CLI/runtime as
the behavioral reference. The migration remains Swift-only in this repository:
do not add a TypeScript packages workspace back to `riela`.

Product-owned Swift code, documentation, scripts, and environment names should
use `riela`, `Riela`, and `RIELA_`. Existing authored workflows, package
manifests, backend strings, and compatibility inputs may still accept legacy
Rielflow spelling where required to run existing data, but newly documented
Riela-owned surfaces should be Riela-branded.

## Continuation Scope After TASK-002 Slice

The prior workflow session
`riel-codex-design-and-implement-review-loop-1781564951-7693c0fd` completed
only a bounded TASK-002 CLI/runtime slice. The current accepted scope is not
allowed to narrow again: TASK-003 through TASK-008 remain required before
TypeScript deletion can become reviewable.

The remaining blockers are design-owned as follows:

- TASK-003 owns runtime/session persistence, SQLite-compatible message store
  behavior, workflow message sequencing, output attempts, publication failure
  paths, resume, continue, rerun, call-step dispatch, and GraphQL/session DTO
  backing records.
- TASK-004 owns local agent and official adapter parity for `codex-agent`,
  `claude-code-agent`, `cursor-cli-agent`, `official/openai-sdk`,
  `official/anthropic-sdk`, and `official/cursor-sdk`.
- TASK-005 owns package registry, checkout, temp-run, publish metadata,
  checksum/integrity, skill projection, add-on manifests, and native executable
  or bundle add-on contracts.
- TASK-006 owns `events`, `hook`, `graphql`/`gql`, `serve`, and `call-step`
  production semantics, including redaction and manager-control coverage.
- TASK-007 owns auto-improve, supervision, workflow-call, nested supervisor,
  self-improve, and targeted rerun behavior.
- TASK-008 owns user-facing documentation, Homebrew release metadata, current
  verification evidence, branch/commit evidence, accepted review ids, and the
  final `packaging/swift-deletion-readiness.json` decision.

`renderUnimplementedParityCommand` may remain only for commands still blocked
by the deletion gate. It is not acceptable deletion-readiness evidence for
`workflow checkout`, `workflow create`, `workflow self-improve`,
`workflow package`, top-level `package`, `session continue`, `graphql`/`gql`,
`hook`, `events`, `serve`, or `call-step`.

## Audited Reference Surface

The planning audit compared the current Swift targets and tests in `riela`
against the current Rielflow branch under `/Users/taco/gits/tacogips/rielflow`.
The authoritative TypeScript reference files are:

- `packages/rielflow/src/cli/run-cli.ts`
- `packages/rielflow/src/cli/argument-parser.ts`
- `packages/rielflow/src/cli/workflow-command-handler.ts`
- `packages/rielflow/src/cli/workflow-run-command.ts`
- `packages/rielflow/src/cli/session-command-handler.ts`
- `packages/rielflow/src/cli/workflow-package-command-handler.ts`
- `packages/rielflow/src/cli/scoped-command-handlers.ts`
- `packages/rielflow/src/workflow/engine/*`
- `packages/rielflow/src/workflow/runtime-db/*`
- `packages/rielflow/src/workflow/packages/*`
- `packages/rielflow/src/workflow/adapters/{codex,claude,cursor,cursor-sdk,dispatch,readiness,shared}.ts`
- `packages/rielflow-adapters/src/{codex,claude,cursor,cursor-sdk,dispatch,readiness,shared}.ts`
- `packages/rielflow-events/src/*`
- `packages/rielflow-graphql/src/*`
- `packages/rielflow-server/src/*`
- `packages/rielflow-hook/src/*`

Current Swift coverage exists in `Package.swift`, `Sources/RielaCore`,
`Sources/RielaCLI`, `Sources/RielaAdapters`, `Sources/CodexAgent`,
`Sources/ClaudeCodeAgent`, `Sources/CursorCLIAgent`, `Sources/RielaAddons`,
`Sources/RielaEvents`, `Sources/RielaGraphQL`, `Sources/RielaServer`,
`Sources/RielaHook`, and their matching `Tests/*` targets. The current deletion
gate in `packaging/swift-deletion-readiness.json` is intentionally blocked and
is the machine-readable source of truth until this plan records accepted parity
evidence.

## Required Parity Domains

### CLI Command Surface

Swift `RielaCLI` must cover the production command router from
`packages/rielflow/src/cli/run-cli.ts` without narrowing behavior to the current
Swift subset. Required scopes and commands are:

- root help/version and shared option parsing from `argument-parser.ts`
- `workflow list`, `workflow status`, `workflow usage`, `workflow manifest validate`
- `workflow run`, including direct workflow JSON/file input, mock scenarios,
  variables, node patches, bounded execution limits, local and GraphQL paths
- `workflow checkout`, `workflow create`, `workflow self-improve`, `workflow validate`, and `workflow inspect`
- top-level `package` and `workflow package` commands for search, list, status,
  install, update, remove, checkout/run temp flows, registry options, and publish
  metadata where present in the TypeScript handler
- `session progress`, `session health`, `session status`, `session resume`,
  `session continue`, `session rerun`, `session step-runs`, `session export`,
  and `session logs`
- `graphql`/`gql`, `hook`, `events`, `serve`, and `call-step` scopes

Swift should preserve TypeScript exit-code behavior: usage errors return `2`,
runtime failures return `1`, and successful terminal operations return `0`.
Text, JSON, JSONL, and table output support must match the TypeScript command
where the TypeScript command supports it; unsupported format combinations must
fail with deterministic usage diagnostics.

### Runtime Engine And Persistence

Swift runtime parity must cover the current TypeScript engine, not only the
deterministic mock runner. Required behavior includes session lifecycle,
step-addressed execution, bounded fanout, direct and cross-workflow calls,
superviser/supervisor control, output-attempt retry/finalization,
transition selection, workflow message publication, root output selection,
manager-control actions, runtime logs, LLM session messages, session health,
continuation, rerun/resume, and SQLite-backed runtime DB behavior.

Runtime-owned boundaries remain unchanged: workers and adapters may return
candidate output only. Session ids, step execution ids, communication ids,
workflow message rows, accepted output artifacts, final root outputs, and
runtime DB records are owned by the runtime.

Swift persistence must expose one canonical source of truth for session
inspection, GraphQL manager-control/session DTOs, continuation, replay, and
rerun. Legacy or compatibility aliases may read existing Rielflow-authored data
only through tested migration/normalization paths; new Riela-owned data and
documentation should use `RIELA_` environment names.

### Agent And Adapter Backends

The three repository-owned local agent backends must remain first-class Swift
targets:

- `CodexAgent` owns `codex-agent` command construction, readiness, auth/model
  probes, session handling, JSONL output normalization, deadlines, and redaction.
- `ClaudeCodeAgent` owns `claude-code-agent` command construction, readiness,
  auth/model probes, resume/session handling, permissions/plan mode, deadlines,
  and redaction.
- `CursorCLIAgent` owns `cursor-cli-agent` command construction, Cursor model
  effort resolution, readiness, auth/model probe classification, mode/stream
  configuration, deadlines, and redaction.

Provider-neutral behavior remains in `RielaAdapters`: dispatch, retry,
prepared prompt input, official SDK adapters, adapter envelopes, output-candidate
normalization, and shared error categories. `official/openai-sdk`,
`official/anthropic-sdk`, and any production `official/cursor-sdk` behavior in
the TypeScript runtime must either be ported or explicitly blocked in the
deletion gate; it must not be silently lost during TypeScript deletion.

Cursor behavior stays isolated by backend. `cursor-cli-agent` command,
readiness, model-effort, stream, auth, timeout, and session behavior belongs in
`Sources/CursorCLIAgent`; `official/cursor-sdk` belongs behind an adapter module
selected only by the `official/cursor-sdk` backend. Neither path may reuse
Codex-specific execution behavior except through provider-neutral
`RielaAdapters` envelopes, retry/deadline handling, prompt preparation, output
candidate normalization, and redaction.

### Packages, Add-ons, Events, Hooks, GraphQL, And Server

Swift parity must include workflow package registry/search/install/update/remove,
checkout, temp run, dependency validation, skill projection, node add-on
execution contracts, native executable and bundle add-ons, event source
validation, event emit/serve/replay/schedules/replies, chat gateway behavior,
hook parsing/recording/redaction, GraphQL control-plane operations, and server
routes. Live network behavior should stay behind injected ports in tests, but
the production Swift runtime must expose equivalent CLI and library entrypoints.

### Deletion Gate

`packaging/swift-deletion-readiness.json` may move to
`migrationStatus=deletion_ready`, `allowsTypeScriptDeletion=true`, and
`typeScriptSourceDeletionReady=true` only after every required domain is
`passed`, has current command evidence, records branch/commit/review metadata,
and has an accepted adversarial review with no high or mid findings. Until then,
TypeScript source, tests, fallback scripts, and reference package metadata remain
in the repository.

## Design Review

Self-review decision: accepted after adding explicit CLI scope coverage,
runtime-owned publication boundaries, agent target ownership, and the no
TypeScript-workspace constraint.

Independent review decision: accepted after separating production Swift
packaging from TypeScript deletion readiness and requiring `official/cursor-sdk`
to be either ported or explicitly blocked by the deletion gate instead of being
lost implicitly.

No high or mid design findings remain open.
