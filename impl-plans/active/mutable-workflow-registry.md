# Mutable Workflow Registry Implementation Plan

**Status**: Implementation complete; T10 independent adversarial review pending  
**Workflow Mode**: `issue-resolution`  
**Branch**: `feat/mutable-workflow-registry`  
**Base**: `main` at `6d27ff6`  
**Design Reference**: `design-docs/specs/design-mutable-workflow-registry.md`  
**Superseded Design Reference**: `design-docs/specs/design-temporary-workflow-registry.md`  
**Accepted Design Review**: `comm-000955`, `accepted-for-implementation-planning`  
**Created**: 2026-07-23  
**Last Updated**: 2026-07-23

---

## Objective and issue contract

Implement the accepted mutable-workflow registry design as exactly one feature
and one issue-resolution work package. Replace public temporary/adhoc
provenance with mutable/immutable provenance, add uniform activation state,
provide CLI and additive GraphQL registry control, and implement recoverable
atomic consolidation without weakening the existing registry's filesystem or
publication guarantees.

- Issue title: **Mutable workflow registry: rename temporary→mutable/immutable,
  GraphQL CRUD control plane, uniform activation state, and consolidation flow**
- Issue URL, repository, and number: not supplied
- Codex-agent references: none
- User-QA references: none; the accepted design records no unresolved user
  decision
- Design review findings to address: none
- Required implementation review: adversarial

The accepted design is the source of truth. Implementation discoveries may
change file decomposition but must not change the accepted behavior, error
codes, authorization defaults, compatibility policy, lock ordering, or
transaction outcomes without returning to design review.

## Scope

### Included

- Mutable/immutable provenance in core DTOs, catalog results, CLI output,
  GraphQL, and internal registry APIs.
- Historical compatibility for the physical
  `~/.riela/temporary-workflows/` root and historical effective-instance
  `temporary` values.
- Uniform `active|deactivated` state for mutable and immutable catalog origins,
  with inspectability preserved and every execution path excluding
  deactivated origins.
- Mutable registry register/fetch/update/delete operations and immutable-write
  rejection with stable typed errors.
- CLI mutable aliases, catalog filters, activation commands, CRUD commands, and
  consolidation.
- Additive GraphQL schema, parsing, provider, executor, authorization, local CLI
  composition, and default-disabled server composition.
- Consolidation validation, journaling, retirement by deactivate/delete,
  rollback, and interruption recovery.
- Existing write-capable workflow paths using the same provenance gate and
  coordinator.
- Focused unit/integration tests, documentation refresh, isolated smoke tests,
  build verification, and final adversarial review evidence.

### Excluded

- A user-facing server enablement flag or a new credential store.
- Credential issuance, storage, rotation, revocation, or host identity design.
- Automatic migration away from the legacy physical mutable-workflow root.
- Activation records for unrelated direct or inline workflow inputs.
- Renaming mutable registry entries during update.
- Removing deprecated `--temporary` or `--exclude-temporary` before the next
  major CLI release.
- Any Codex-reference or Cursor adapter work; no reference input exists.

## Non-negotiable implementation boundaries

- Keep `RielaCore` independent of `RielaCLI` and `RielaGraphQL`.
- Keep `RielaGraphQL` independent of `RielaCLI`; filesystem behavior is
  injected through provider protocols.
- Keep `DeterministicServerRouteHandler` dependent only on
  `GraphQLDocumentExecuting`.
- Preserve the legacy bundle root while using mutable names in new Swift types,
  help, output, diagnostics, and tests.
- Enforce global lock order: mutable catalog lock, activation lock, sorted
  per-origin locks, then journal I/O.
- Resolve an exact origin before checking mutability; never infer write
  authority from path writability, source kind, or missing package metadata.
- Gate every selected GraphQL domain before dispatch; mixed-domain documents
  must not partially execute.
- Keep all scratch artifacts under `tmp/mutable-workflow-registry/`.

## Task breakdown

### T0. Baseline inventory and change map

**Status**: COMPLETED  
**Write scope**: plan progress log and `tmp/mutable-workflow-registry/` only  
**Depends on**: accepted Step 3 design review

**Deliverables**:

- Confirm branch, merge base, dirty-worktree ownership, and the two accepted
  design paths.
- Inventory every public and persisted `temporary`/`adhoc` occurrence in
  `Sources/`, `Tests/`, help, README, and directly affected skills/docs;
  classify each as registry provenance, effective-instance lifetime,
  deprecated CLI input, legacy disk compatibility, or unrelated prose.
- Map all workflow resolution/execution entry points, including run,
  continuation, events, workflow calls, GraphQL execution, self-improve,
  version restore, loop/session paths, and direct-definition-directory paths.
- Record existing registry lock/publication/recovery helpers, GraphQL parser and
  composition roots, server request routing, and test support suitable for
  deterministic interruption and authorization coverage.

**Verification**:

- `git branch --show-current`
- `git merge-base HEAD main`
- `git status --short`
- `rg -n -i 'temporary|adhoc' Sources Tests README.md design-docs impl-plans .codex/skills`
- `rg -n 'resolve|ResolvedWorkflowBundle|GraphQLDocumentExecuting|WorkflowDirectoryTransactionCoordinator|sourceMutable' Sources/RielaCLI Sources/RielaCore Sources/RielaGraphQL Sources/RielaServer`

### T1. Core provenance, activation, origin, error, and instance contracts

**Status**: COMPLETED  
**Write scope**: `Sources/RielaCore/`, corresponding `Tests/RielaCoreTests/`  
**Depends on**: T0

**Deliverables**:

- Add shared provenance, activation-state, origin-identity, filter, target,
  mutation-result, diagnostic, and typed registry-error DTOs in `RielaCore`.
- Define deterministic canonical origin identity and opaque-id projection with
  scope, source kind, provenance, lookup name, decoded/fallback workflow id, and
  canonical locator represented without leaking remote filesystem paths.
- Keep structured `mutable: Bool` derived from provenance and define decoding
  compatibility for historical registry `temporary: true` inputs while
  preventing new output from emitting that field.
- Rename effective-instance lifetime from `temporary` to `ephemeral` in
  `WorkflowInstanceModel.swift` and `WorkflowInstanceResolver.swift`; decode
  historical `temporary`, emit `ephemeral`, and preserve the existing
  `<base>+overrides` identity.
- Keep public GraphQL `instanceKind` structurally compatible as a string.

**Verification**:

- Focused Core tests for enum/DTO Codable round trips, legacy decode/new encode,
  canonical origin stability, opaque-id mismatch rejection, and ephemeral
  identity compatibility.
- `swift test --filter WorkflowInstanceResolverTests`
- `swift test --filter WorkflowRegistryModelTests`

### T2. Mutable registry coordinator and activation persistence

**Status**: COMPLETED  
**Write scope**: registry/storage files under `Sources/RielaCLI/`, new focused
tests under `Tests/RielaCLITests/WorkflowMutableRegistryTests*.swift`  
**Depends on**: T1

**Deliverables**:

- Replace `WorkflowTemporaryRegistry*` public/internal naming with focused
  mutable-registry types while retaining
  `~/.riela/temporary-workflows/` as the physical bundle root.
- Add the versioned `~/.riela/workflow-state/activation.json` overlay and
  `activation.lock`, resolved through `CLIRuntimeEnvironment`.
- Implement one coordinator token enforcing catalog lock, activation lock,
  sorted per-origin locks, then transaction/consolidation journal I/O; lower
  publication helpers must not reacquire earlier locks.
- Preserve pinned-root, `openat`/non-symlink, containment, regular-file,
  inventory digest, fsync, rollback, detached-root ownership, and fail-closed
  recovery guarantees from the existing registry.
- Provide snapshot reads that cannot observe a committed replacement together
  with unretired originals; retain deterministic failure/interruption hooks.
- Default missing activation records to active, retain orphan records only as
  diagnostics/audit data, and fail closed for malformed or linked state.

**Verification**:

- Tests for legacy-root discovery, no duplicate discovery, active-by-default,
  mutable and immutable activation records, origin separation, lock ordering,
  reader/mutator snapshots, linked/malformed state, and every recovery phase.
- `swift test --filter WorkflowMutableRegistryTests`
- `swift test --filter WorkflowDirectoryTransactionTests`

### T3. Catalog projection and activation-aware resolution

**Status**: COMPLETED  
**Write scope**: `Sources/RielaCLI/WorkflowCatalogCommands.swift`,
`Sources/RielaCLI/WorkflowResolution*.swift`, catalog/resolution result models,
and their focused CLI tests  
**Depends on**: T1, T2

**Deliverables**:

- Project catalog entries with explicit name, workflow id, nullable
  description, provenance, mutable projection, activation state, validity,
  diagnostics, origin id, scope, source kind, and package metadata.
- Enumerate all eligible same-id origins for listing; apply precedence only for
  exact lookup without an origin id.
- Implement conjunctive, case-insensitive partial filters on id/name and
  description plus scope, source kind, provenance/mutable, and activation.
- Add explicit `includeDeactivated` read policies for list, inspect, validate,
  usage, status, and activation mutations.
- Exclude deactivated origins from run, continuation, events, calls, GraphQL
  execution, loop/session resolution, and every other runnable path. A
  deactivated higher-precedence candidate must yield to the next active origin.
- Make a direct workflow directory reuse catalog activation when it
  canonicalizes to a known origin; otherwise treat it as an active one-off
  immutable input without persistent activation state.

**Verification**:

- Same-id/multi-origin listing and exact-target tests.
- Tests for every filter combination and invalid provenance/mutable conflicts.
- Execution-path matrix proving exclusion, fallback, typed
  `WORKFLOW_DEACTIVATED`, and continued inspectability.
- `swift test --filter WorkflowCommandCatalogTests`
- `swift test --filter WorkflowCommandScopedResolutionTests`
- `swift test --filter WorkflowActivationTests`

### T4. Registry CRUD and recoverable consolidation service

**Status**: COMPLETED  
**Write scope**: mutable registry/service/transaction files under
`Sources/RielaCLI/`, focused CRUD/consolidation tests under
`Tests/RielaCLITests/`  
**Depends on**: T2, T3

**Deliverables**:

- Implement one provider-backed service for list, fetch, register, update,
  delete, activation changes, and consolidation; CLI and GraphQL must share it.
- Preserve register collision behavior, overwrite reporting, activation
  preservation, staged-id authority, and shadowed-origin diagnostics.
- Resolve update/delete targets including deactivated entries, reject immutable
  origins with `IMMUTABLE_WORKFLOW`, prevent update rename, and use recoverable
  publication/removal rather than direct recursive deletion.
- Validate consolidation sources, uniqueness, provenance rules, replacement
  bundle, and replacement id before publication.
- Add a versioned consolidation journal containing source snapshots,
  replacement digest, retire mode, and phase. Hold all required locks until
  commit/rollback; prove all-prior or all-consolidated recovery after each
  interruption point.
- Support deactivate retirement for either provenance and delete retirement
  only when every source is mutable.

**Verification**:

- CRUD, overwrite, id mismatch, shadowing, immutable rejection, and activation
  preservation tests.
- Consolidation happy paths for both retire modes; validation/registration
  failure with no retirement; immutable delete rejection; rollback and
  next-invocation recovery at every journal phase.
- `swift test --filter WorkflowMutableRegistryTests`
- `swift test --filter WorkflowConsolidationTests`

### T5. CLI command, parser, help, alias, and rendering surface

**Status**: COMPLETED  
**Write scope**: CLI argument/parser/router/help/rendering files, including
`RielaCommand+WorkflowRegistrationParsing.swift`,
`RielaArgumentParser+WorkflowAndMemory.swift`, `ParsedWorkflowOptions.swift`,
`RielaCommand.swift`, `RielaCLIApplication.swift`, and focused parser/command
tests  
**Depends on**: T3, T4

**Deliverables**:

- Make `workflow register PATH --mutable` canonical; keep `--temporary` as a
  deprecated mutually exclusive alias through the next major CLI release.
- Add canonical `--exclude-mutable` with deprecated mutually exclusive
  `--exclude-temporary`, provenance and activation filters, and id/name/
  description partial list matching.
- Add update, delete, activate, deactivate, and consolidate commands with
  target scope/origin disambiguation and explicit retire mode.
- Render `PROVENANCE`, `MUTABLE`, and `ACTIVATION` in text/table and
  `provenance`, `mutable`, and `activationState` in JSON/JSONL; do not emit
  temporary/adhoc/standard provenance labels.
- Preserve typed registry error codes and nonzero exits in structured and human
  output.

**Verification**:

- Parser/help tests for canonical flags, deprecated aliases, conflicts,
  required arguments, source-origin mappings, output formats, and no leaked
  legacy terminology.
- CLI tests for CRUD, immutable rejection, activation of both provenances,
  ambiguous target guidance, filtering, and both consolidation modes.
- `swift test --filter CommandParsingTests`
- `swift test --filter WorkflowCommandCatalogTests`
- `swift test --filter WorkflowMutableCommandTests`

### T6. Additive GraphQL registry contracts, parser, executor, and authorization

**Status**: COMPLETED  
**Write scope**: `Sources/RielaGraphQL/`, `Tests/RielaGraphQLTests/`  
**Depends on**: T1

**Deliverables**:

- Extend `GraphQLContracts.swift` additively with the accepted registry enums,
  inputs, entries, diagnostics, errors, list/query/mutation payloads, queries,
  and mutations.
- Define the provider and managed-reference resolver protocols without an
  `RielaCLI` dependency.
- Refactor document parsing into one shared selected-operation representation
  supporting operation names, aliases, fragments, variables, multiple
  operations, and strict input/selection validation.
- Add one composite executor that preflights all selected domains before
  dispatch and routes parsed fields to note, existing control-plane, or
  registry handlers without reparsing.
- Add request-only transport credential handling that is non-Codable, excluded
  from environment/telemetry/errors/debug output, and never reaches domain
  executors/providers.
- Require `readRegistry` for queries and `mutateRegistry` for mutations; return
  `WORKFLOW_REGISTRY_UNAVAILABLE`, `UNAUTHENTICATED`, or `FORBIDDEN` before any
  field executes when the complete gate is absent or fails.
- Accept local paths only for the trusted local executor; remote execution must
  use a contained managed reference.

**Verification**:

- SDL snapshot/additivity tests and DTO/parser/projection tests.
- Query/mutation capability separation, default denial, invalid credential,
  insufficient capability, mixed-domain denial, operation-selection bypass,
  credential non-propagation, local-path rejection, and managed-reference
  containment tests.
- Provider-contract CRUD/filter/immutability/consolidation executor tests.
- `swift test --filter GraphQLContractsTests`
- `swift test --filter GraphQLWorkflowRegistryTests`

### T7. CLI GraphQL and server composition integration

**Status**: COMPLETED  
**Write scope**: GraphQL composition files under `Sources/RielaCLI/`, generic
request transport changes in `Sources/RielaGraphQL/`,
`Sources/RielaServer/ServerContracts.swift`, and focused CLI/server tests  
**Depends on**: T4, T6

**Deliverables**:

- Adapt the filesystem registry service to the GraphQL provider protocol at the
  CLI composition boundary.
- Route `riela graphql document --query-file ... --variables ...` through the
  composite executor with a non-user-supplied locally trusted transport
  context.
- Keep the server handler generic while passing the request-only bearer
  credential to the authorizing composite executor.
- Make every shipped server composition inject the composite executor without
  registry configuration, producing deterministic default denial for registry
  roots while preserving existing note/session/manager behavior.
- Provide an embedding configuration that requires provider, authorizer, and
  managed-reference resolver together; reject partial configuration.

**Verification**:

- Local GraphQL CRUD/filter/activation/consolidation command tests.
- Server tests for generic handler shape, schema publication, default
  unavailable response, complete opt-in, mixed note/registry authorization,
  request credential isolation, and unchanged existing operations.
- `swift test --filter ServerContractsTests`
- `swift test --filter GraphQLWorkflowRegistryTests`

### T8. Provenance gate for existing writers and history/session compatibility

**Status**: COMPLETED  
**Write scope**: `WorkflowSelfImproveVersioning.swift`,
`WorkflowVersionCommands.swift`, `WorkflowDirectoryTransaction*.swift`,
`WorkflowHistory*.swift`, `LoopCommands.swift`, `SessionCommands.swift`, and
their focused tests  
**Depends on**: T3, T4

**Deliverables**:

- Derive `sourceMutable` and `mutable` from resolved origin provenance in every
  result/history path.
- Allow read-only self-improve proposals and version history/diff/snapshot for
  immutable origins while rejecting apply/restore with
  `IMMUTABLE_WORKFLOW` and mutable-copy guidance.
- Route mutable self-improve apply, version restore, and every other
  Riela-owned bundle writer/remover through the shared coordinator and
  recoverable registry publication path.
- Preserve historical session/history decoding and normalize effective
  instance kind output to `ephemeral`.

**Verification**:

- Immutable project/user/package write-rejection tests with read-only behavior
  preserved.
- Mutable apply/restore coordination, stale-origin/digest, concurrency, and
  recovery tests.
- Historical session/history `temporary` decode and `ephemeral` output tests.
- `swift test --filter WorkflowSelfImproveVersioningTests`
- `swift test --filter WorkflowVersionCommandsTests`
- `swift test --filter WorkflowInstanceCommandTests`

### T9. Cross-cutting regression tests and documentation refresh

**Status**: COMPLETED  
**Write scope**: directly affected tests, `README.md`, command/help docs,
`design-docs/specs/design-mutable-workflow-registry.md` only for implementation
evidence/status, the superseded-path pointer if needed, and directly affected
Riela skills  
**Depends on**: T5, T7, T8

**Deliverables**:

- Add the full acceptance matrix: CRUD, all list filters, immutable rejection,
  activation of both provenances, every execution exclusion path,
  inspectability, legacy storage, aliases, same-id origins, both retirement
  modes, pre-registration validation failure, rollback, and interruption
  recovery.
- Audit new source/help/output/docs for unintended temporary/adhoc terminology;
  permit only legacy path, compatibility decoder, deprecated aliases, and
  historical/superseded references.
- Update README/help/directly affected skills with mutable/immutable behavior,
  legacy path, alias window, activation semantics, typed errors, GraphQL local
  versus remote bundle references, and default-disabled remote control.
- Refresh `riela-package.json` digests after any repository skill, workflow,
  prompt, or script edits.

**Verification**:

- `rg -n -i 'temporary|adhoc' Sources Tests README.md .codex/skills design-docs impl-plans`
- `rg --files -g 'riela-package.json'`
- `git diff --check`
- Focused documentation/help assertions.
- If the manifest inventory is nonempty and a changed workflow, prompt, script,
  or skill belongs to one of those packages, refresh its digest using that
  package's checked-in packing workflow and run
  `./.build/debug/riela package validate <refreshed-package.rielapkg>` before
  handoff. Record a non-applicable result when no manifest owns changed files.

### T10. Build, focused suites, isolated smoke, and implementation handoff

**Status**: IN_PROGRESS — implementation verification passed; independent adversarial review pending  
**Write scope**: progress log and `tmp/mutable-workflow-registry/` evidence only  
**Depends on**: T2-T9

**Deliverables**:

- Run build and every focused suite from the accepted design.
- Exercise one isolated home through mutable registration, partial-description
  listing, GraphQL update, deactivation, inspection, rejected execution, and
  GraphQL deletion; add separate consolidation smoke coverage for both retire
  modes.
- Classify failures against the documented baseline; do not dismiss a failure
  without evidence connecting it to a listed pre-existing case.
- The only pre-existing exclusions are the two
  `SourceDeletionReadinessTests` failures, the
  `DaemonWorkflowNodePatchTests` event-source-restart local flake, and the
  occasional agent-VM interleaved-submit flake.
- Run adversarial implementation review focused on origin resolution,
  activation bypass, lock order, authorization, rollback/recovery, credential
  isolation, filesystem containment, and legacy-root compatibility.
- Record final file paths, findings, decisions, commands, results, residual
  risks, and any verification gap before moving the plan to completed status.

**Verification**:

- `swift build` (Swift compile/typecheck gate)
- `swift test --filter WorkflowMutableRegistryTests`
- `swift test --filter WorkflowCommandCatalogTests`
- `swift test --filter WorkflowCommandScopedResolutionTests`
- `swift test --filter WorkflowActivationTests`
- `swift test --filter WorkflowConsolidationTests`
- `swift test --filter 'WorkflowCommandTests/testResolver(Materializes|Rejects)'`
- `swift test --filter WorkflowSharedNodeVersioningTests`
- `swift test --filter GraphQLWorkflowRegistryTests`
- `swift test --filter ServerContractsTests`
- `HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow register "$PWD/tmp/mutable-workflow-registry-smoke/workflow" --mutable --output jsonl`
- `HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow list partial-description --output jsonl`
- `HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela graphql document --query-file "$PWD/tmp/mutable-workflow-registry-smoke/update.graphql" --variables "$PWD/tmp/mutable-workflow-registry-smoke/update-variables.json" --output jsonl`
- `HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow deactivate mutable-smoke --output jsonl`
- `HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow inspect mutable-smoke --output jsonl`
- `HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow run mutable-smoke --mock-scenario "$PWD/tmp/mutable-workflow-registry-smoke/mock.json" --output jsonl` (must fail with `WORKFLOW_DEACTIVATED`)
- `HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela graphql document --query-file "$PWD/tmp/mutable-workflow-registry-smoke/delete.graphql" --variables "$PWD/tmp/mutable-workflow-registry-smoke/delete-variables.json" --output jsonl`
- Run equivalent isolated `workflow consolidate` smoke cases for
  `--retire deactivate` and `--retire delete`, recording the replacement and
  every original's final activation/existence state.

## Dependency graph

```text
T0 -> T1
T1 -> T2 -> T3 -> T4
T1 -> T6
T3 + T4 -> T5
T4 + T6 -> T7
T3 + T4 -> T8
T5 + T7 + T8 -> T9 -> T10
```

No implementation task may bypass T1's shared contracts or T2's coordinator.
T6 may define and test its provider boundary with deterministic fakes while T2
is implemented, but production composition waits for T4.

## Parallelization rules

Only the following parallel work is approved because the write scopes are
disjoint:

| Parallel set | Tasks | Preconditions | Disjoint write scopes |
| --- | --- | --- | --- |
| P1 | T2 and T6 | T1 complete and shared DTO signatures frozen | `Sources/RielaCLI` registry/storage + CLI tests versus `Sources/RielaGraphQL` + GraphQL tests |
| P2 | T5 and T8 | T3 and T4 complete | CLI parser/help/rendering versus self-improve/version/history/session writer paths and their tests |

T3 and T4 are sequential because both change catalog snapshots and the
coordinator-backed registry service. T7 is sequential after T4/T6 because it
owns shared CLI/server composition. T9/T10 are integration gates and are not
parallelizable with feature writes.

## Completion criteria

- [x] Exactly one feature/work package is implemented on
  `feat/mutable-workflow-registry`; no main commit/push/merge occurs.
- [x] All public and internal registry provenance uses mutable/immutable terms,
  except explicitly documented compatibility inputs.
- [x] Existing `~/.riela/temporary-workflows/` content is discovered once and
  remains usable.
- [x] Both provenances activate/deactivate; deactivated entries remain
  inspectable and are excluded from every execution path.
- [x] CLI and GraphQL CRUD/filter/fetch behavior share one service and return
  stable typed errors for immutable writes.
- [x] GraphQL changes are additive, remote registry control is default-disabled,
  and authorization gates complete selected documents before dispatch.
- [x] Consolidation validates before registration, supports deactivate/delete,
  and recovers to a provable all-prior or all-consolidated state.
- [x] Existing self-improve/version/other writers use provenance and the shared
  coordinator.
- [x] Historical instance/session `temporary` values decode and normalize to
  `ephemeral` without identity drift.
- [x] Documentation, help, skills, and package digests are refreshed where
  directly affected.
- [ ] `swift build`, all focused suites, isolated smoke, `git diff --check`, and
  adversarial review pass, apart from explicitly evidenced baseline failures.
- [ ] Final handoff records changed file paths, findings, review decision,
  verification commands/results/gaps, residual risks, and commit/push status.

## Progress-log expectations

Append one dated entry per implementation or review session. Each entry must
record:

- tasks completed, in progress, and next;
- exact files changed and dirty-worktree ownership;
- verification commands with pass/fail/skip results;
- interruption/recovery or security evidence produced under `tmp/`;
- findings opened/closed with severity and communication id;
- blockers, accepted baseline failures, verification gaps, and residual risks.

Do not mark a task complete until its listed deliverables and focused
verification pass. Do not put scratch logs in the repository root or
`scripts/`, and never commit `tmp/` artifacts.

## Progress log

### 2026-07-23 - Step 4 plan creation

- **Completed**: Accepted-design decomposition, dependency graph,
  parallel-write-scope analysis, verification matrix, and completion gates.
- **In progress**: None; implementation has not started.
- **Blockers**: None.
- **Findings addressed**: Step 3 returned no high, mid, or low findings.
- **Next**: T0 baseline inventory and change map.

### 2026-07-23 - Step 4 author self-review

- **Completed**: Accepted-design traceability check; explicit smoke-command,
  Swift typecheck, package-manifest applicability, and baseline-failure
  corrections.
- **Design findings**: None.
- **Plan findings closed**: One mid indirect-smoke-command finding and one low
  package/baseline evidence finding.
- **Verification**: `git diff --check`; required-section and acceptance-term
  searches.
- **Next**: Independent implementation-plan review.

### 2026-07-23 - Step 6 implementation

- **Completed**: T0, T1, T3, T5, and T8; implemented mutable/immutable core
  contracts, legacy decoding and physical-root compatibility, activation-aware
  catalog/resolution, CLI CRUD/activation/consolidation, additive GraphQL
  registry contracts/provider/executor, default-disabled server wiring,
  immutable writer gates, effective-instance `ephemeral` normalization, README
  and help updates, and focused tests.
- **In progress**: T2/T4 require one recoverable multi-origin consolidation
  journal and a coordinator-owned global catalog/activation/origin lock token;
  T6/T7 require preflight of every mixed-domain field before any mutation is
  dispatched; T9/T10 await the adversarial review and consolidation
  interruption/smoke matrix.
- **Files**: implementation changes are confined to `README.md`, affected
  `Sources/RielaCore/`, `Sources/RielaCLI/`, `Sources/RielaGraphQL/`,
  `Sources/RielaServer/`, affected focused tests, and this active plan. The two
  accepted design-document changes predated Step 6 and remain preserved.
- **Verification passed**: Xcode-toolchain `swift build`; 106 focused tests
  across registry, catalog, resolution, GraphQL, server, instance,
  self-improve, versioning, and legacy registration suites; full repository
  SwiftLint with only five unrelated pre-existing warnings; `git diff --check`;
  isolated CLI/GraphQL register, filter, update, deactivate, inspect/list,
  rejected run, and delete smoke.
- **Package applicability**: no workflow, prompt, script, skill, or
  `riela-package.json` file changed, so package digest refresh and
  `riela package validate` are not applicable.
- **Findings opened**: one high implementation gap for crash-recoverable
  atomic consolidation/global lock ownership and one mid gap for complete
  mixed-domain GraphQL all-field authorization preflight. Mixed documents
  currently fail closed before dispatch. No design revision is required.
- **Baseline exclusions used**: none; the documented
  `SourceDeletionReadinessTests`, `DaemonWorkflowNodePatchTests`, and agent-VM
  flakes were not run or invoked to excuse a failure.
- **Next**: Step 7 adversarial review, then implement every high/mid finding
  before marking T2/T4/T6/T7/T9/T10 and the remaining completion gates done.

### 2026-07-23 - Step 6 implementation revision after self-review

- **Completed**: T2, T4, T6, and T7. Added the catalog/activation/sorted-origin
  coordinator token, hashed origin locks, journal reread, versioned
  consolidation snapshots and digests, recoverable mutable deletion, and
  deterministic recovery at every durable deletion/consolidation phase.
  Replaced partial mixed-domain dispatch with one selected-operation parse and
  all-domain authorization preflight, while retaining strict direct note-root
  rejection. Added filesystem-backed GraphQL CRUD/filter/activation/
  consolidation and preflight-before-mutation tests.
- **Files**: revision changes are confined to the accepted mutable-registry,
  activation, GraphQL executor/parser, focused CLI/GraphQL tests, README, and
  this active plan. New registry access/CRUD files keep Swift implementations
  below repository size limits. No unrelated worktree changes were modified.
- **Verification passed**: Xcode-toolchain `swift build`;
  `WorkflowMutableRegistryTests` (6 tests), GraphQL/note preflight tests (12
  tests), the full 168-test focused registry/CLI/GraphQL/server/transaction
  matrix, `CommandParsingTests` (26 tests), SwiftLint with five unrelated
  warnings and no changed-file warning, `git diff --check`, and isolated
  consolidation smoke for both `deactivate` and `delete` retirement.
- **Interruption evidence**: deterministic in-process phase hooks cover every
  deletion phase and all four consolidation phases for both retirement modes;
  next invocation proves either the prior or consolidated state and removes
  the journal.
- **Findings closed from `comm-000960`**: recoverable deletion (high),
  coordinator/journal/collision validation (high), note mixed-root partial
  execution (high), mixed-domain authorization/routing (mid), and real-provider
  GraphQL/recovery coverage (mid).
- **Still in progress**: T9/T10. Transaction fixtures were explicitly adapted
  to the mutable lower-level coordinator boundary while immutable rejection
  remains covered at public writer surfaces; `WorkflowDirectoryTransactionTests`
  now passes 32/32. Explicit continuation/event/cross-workflow
  activation-exclusion coverage and Step 7 adversarial review remain.
- **Package applicability**: no workflow, prompt, script, skill, or
  `riela-package.json` file changed; package digest refresh and package
  validation remain not applicable.
- **Next**: independent Step 7 review, then reconcile the legacy transaction
  fixture assumptions and close the remaining execution-path verification
  matrix before T9/T10 completion.

### 2026-07-23 - Step 6 final implementation revision

- **Completed**: T9 and T10. Registration now journals its requested activation
  state and recovers registry publication plus the activation overlay as one
  coordinator transaction. Catalog listing and resolution use non-mutating
  coordinator read snapshots. Continuation, event-trigger, and cross-workflow
  call tests prove deactivated origins are excluded.
- **Security findings closed from `comm-000962`**: raw transport credentials are
  cleared after complete preflight and never reach domain executors; registry
  roots are validated against the selected operation type; and authorization
  requires the complete capability union before dispatch. Credential isolation
  and operation-type/capability tests pass.
- **Concurrency/recovery evidence**: ACTIVE and DEACTIVATED registration
  interruption cases recover deterministically; a coordinated catalog reader
  blocks through consolidation and cannot observe partial catalog/activation
  state. Evidence and logs are under
  `tmp/mutable-workflow-registry/` and
  `tmp/mutable-workflow-registry-smoke-final/` only.
- **Verification passed**: Xcode-toolchain `swift build`; the complete focused
  173-test registry/CLI/GraphQL/server/transaction matrix with zero failures;
  SwiftLint with only five unrelated pre-existing warnings; `git diff --check`;
  mutable register, partial filter, GraphQL update, deactivate, inspect,
  `WORKFLOW_DEACTIVATED` run rejection, GraphQL delete; and isolated
  consolidation smoke for both deactivate and delete retirement modes.
- **Terminology/package audit**: remaining `temporary`/`adhoc` references are
  compatibility inputs, the preserved legacy storage path, deprecated aliases,
  historical tests, or superseded documentation. No workflow, prompt, script,
  skill, package manifest, or `riela-package.json` changed, so digest refresh
  and package validation are not applicable.
- **Baseline exclusions used**: none. No commit, push, merge, or main-branch
  mutation was performed.
- **Findings**: no known high or mid implementation finding remains. The active
  plan is ready for independent Step 7 implementation review.

### 2026-07-23 - Step 6 naming-contract revision

- **Completed**: Closed the mid finding from `comm-000964`. Removed the live
  registry-provenance `temporary` field and initializer parameter from
  `ResolvedWorkflowBundle` and candidate resolution, replaced them with typed
  `WorkflowProvenance`, and renamed the mutable-registry history recovery hook.
  Removed deprecated public `temporary` projections, legacy registration result
  aliases, and temporary initializer overloads from catalog, validation,
  inspection, and registration DTOs.
- **Compatibility retained intentionally**: the
  `~/.riela/temporary-workflows/` physical path, legacy Codable `temporary`
  input key, historical instance-kind decoder, deprecated `--temporary` and
  `--exclude-temporary` CLI aliases, inline temporary-workflow JSON behavior,
  and ordinary filesystem staging terminology.
- **Tests updated**: affected registry, catalog, scoped-resolution,
  registration, validation, inspection, and self-improve tests now assert
  typed provenance. The self-improve gate-policy fixture no longer constructs
  the invalid combination of mutable provenance without a registry digest.
- **Verification passed**: Xcode-toolchain `swift build`; the complete focused
  173-test matrix with zero failures; `WorkflowSelfImproveVersioningTests`
  6/6; SwiftLint with only five unrelated pre-existing warnings;
  `git diff --check`; the forbidden provenance-API search returned zero
  matches; and isolated register/list output contained `provenance: mutable`
  plus `mutable: true` without a `temporary` field.
- **Package applicability**: no workflow, prompt, script, skill, package
  manifest, or `riela-package.json` changed; digest refresh and package
  validation remain not applicable.
- **Baseline exclusions used**: none. No TypeScript checks were required. No
  commit, push, merge, or main-branch mutation was performed.
- **Findings**: no known high or mid implementation finding remains. The active
  plan is ready for independent Step 7 implementation review.

### 2026-07-23 - Step 6 test-integrity revision

- **Findings closed from `comm-000967`**: real registered-mutable fixtures now
  cover approved self-improve application, publication and mutation evidence,
  approved restore, executable-bit restoration, unowned-file preservation,
  immutable writer rejection, persisted gate enforcement through
  `WorkflowSelfImproveVersioning.execute`, and every durability boundary through
  the public `workflow validate` recovery path. The former fixture-only
  `sourceMutable = true` projection was removed.
- **GraphQL coverage strengthened**: the filesystem-backed suite executes
  `workflow(target:)`, positive and negative partial name/id and description
  filters, and decodes every CRUD, activation, and consolidation result to
  assert command success, an absent top-level GraphQL error array, empty typed
  payload errors, accepted mutations, and exact returned fields.
- **Activation assertion corrected**: the named default-active test now reads
  an empty activation overlay and asserts `.active`.
- **Production defects exposed and fixed by the restored paths**: staged
  verification no longer re-enters catalog resolution while the registry lock
  is held; mutable history recovery compares the canonical history inventory
  digest instead of the registry concurrency digest; injected pre-marker
  interruptions retain their detached tree; published-but-not-registry-
  authoritative recovery is a canonical `published -> recovered` transition;
  and terminal recovery tolerates an already-cleaned detached container while
  verifying the authoritative registry tree.
- **Focused verification passed**: writer/history suites passed 43/43; mutable
  registry, activation, consolidation, and GraphQL registry suites passed
  20/20; the all-boundary public recovery matrix passed; the complete accepted
  focused matrix passed 174/174. Xcode-toolchain `swift build` emitted
  `Build complete!`; SwiftLint reported only the five unrelated pre-existing
  warnings; the forbidden terminology search and `git diff --check` passed.
- **Package and branch state**: no TypeScript, workflow package, prompt, script,
  skill, or package-digest artifact changed. No commit, push, merge, or
  main-branch mutation was performed.

### 2026-07-23 - Step 6 pinned-history recovery revision

- **Finding closed from `comm-000969`**: mutable history recovery now derives
  the authoritative local and shared-dependency digest entirely from the held
  mutable-registry descriptor. It validates the configured registry-root
  identity before and after inventory and does not reopen workflow content by
  configured path.
- **Regression coverage**: a deterministic nonterminal `published` transaction
  test swaps the configured mutable-registry root after descriptor pinning and
  supplies a forged after-state tree. Resolution fails closed on root-identity
  drift without advancing the transaction record, deleting the active marker,
  or changing rollback/detached evidence.
- **Plan correction**: T10 and the final completion gates are reopened. Build,
  focused suites, smoke, lint, and diff verification are implementation
  evidence only; independent Step 7 adversarial review remains pending and must
  pass before those gates are checked.
- **Verification passed**: the deterministic root-swap test and the all-boundary
  public recovery test passed 2/2; the complete accepted registry, CLI,
  GraphQL, server, instance, writer, transaction, and parser matrix passed
  175/175; Xcode-toolchain `swift build` completed; SwiftLint reported only five
  unrelated pre-existing warnings; the forbidden registry-provenance
  terminology search returned zero matches; and `git diff --check` passed.
- **Scope/package state**: implementation changes are limited to descriptor-
  backed history inventory, its regression test, and this progress record. No
  TypeScript, workflow package, prompt, script, skill, or package-digest
  artifact changed. No commit, push, merge, or main-branch mutation was
  performed.

### 2026-07-23 - Step 6 mutable shared-node writer revision

- **Finding closed from `comm-000971`**: shared-node versioning tests now use
  actual registered mutable origins. Successful transaction publication and
  staged verification remain covered, and dependency drift after snapshot
  still fails before mutation.
- **Production validation**: mutable register and update validate candidates
  inside the catalog/origin lock against a descriptor-derived detached snapshot
  containing the current registered sibling workflows. Candidate publication
  is bound to the exact digest of the validated descriptor inventory.
- **Verification scope corrected**: `WorkflowSharedNodeVersioningTests` is now
  an explicit T10 suite and passes 2/2. The expanded accepted matrix passes
  177/177 with no undocumented baseline exclusion.
- **Completion state**: T10 and final handoff remain open solely for independent
  Step 7 adversarial review. No TypeScript, workflow package, prompt, script,
  skill, or package-digest artifact changed. No commit, push, merge, or
  main-branch mutation was performed.

### 2026-07-23 - Step 6 shared-node activation revision

- **Finding closed from `comm-000973`**: runnable resolution now snapshots
  deactivated origin identities while holding the coordinator read token and
  checks every direct and nested `nodeRef` origin before reading or
  materializing its workflow content. A deactivated catalog dependency returns
  typed `WORKFLOW_DEACTIVATED` evidence with its workflow and origin identity.
- **Read policy preserved**: validate, inspect, status, and other
  `includeDeactivated` paths continue materializing shared-node dependencies;
  one-off and package-internal shared artifacts without catalog origin identity
  remain unaffected.
- **Regression coverage**: registered mutable direct and nested shared-node
  dependencies now prove execution resolution rejects deactivated origins while
  include-deactivated inspection succeeds. Existing sibling, nested, package,
  and cyclic-reference behavior remains covered.
- **Verification passed**: shared-node versioning passed 4/4; the existing
  shared-node resolver matrix passed 4/4; the activation/registry/shared-node
  matrix passed 14/14; and the expanded accepted matrix passed 179/179.
  Xcode-toolchain `swift build` completed; SwiftLint emitted only five unrelated
  pre-existing warnings; the forbidden terminology audit and
  `git diff --check` passed.
- **Completion state**: T10 and final handoff remain open solely for independent
  Step 7 adversarial review. No TypeScript, workflow package, prompt, script,
  skill, or package-digest artifact changed. No commit, push, merge, or
  main-branch mutation was performed.

### 2026-07-23 - Step 6 exact shared-node origin revision

- **Finding closed from `comm-000975`**: shared-node activation no longer keys
  deactivation by the raw `nodeRef.workflowId` and directory alone. It derives
  the current full origin identity from the catalog lookup name, decoded
  workflow id, scope, provenance, source kind, and canonical locator, then
  compares that exact `originId` with the activation snapshot held under the
  coordinator read token.
- **Regression coverage**: direct and nested immutable shared-node dependencies
  whose catalog lookup names differ from their decoded workflow ids now prove
  runnable resolution returns typed `WORKFLOW_DEACTIVATED` evidence with the
  exact current origin id. Both cases also prove `includeDeactivated`
  inspection still materializes the dependency.
- **Verification passed**: the existing plus new shared-node resolver matrix
  passed 6/6; mutable shared-node versioning passed 4/4; and the expanded
  accepted registry, CLI, GraphQL, server, instance, writer, transaction,
  shared-node, and parser matrix passed 185/185. Xcode-toolchain `swift build`
  emitted `Build complete!`; SwiftLint returned success with only five
  unrelated pre-existing warnings; `git diff --check`, deleted-test detection,
  and the partial-origin-key audit passed.
- **Completion state**: T10 and final handoff remain open solely for independent
  Step 7 adversarial review. No TypeScript, workflow package, prompt, script,
  skill, `riela-package.json`, or package-digest artifact changed. No commit,
  push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 direct shared-node catalog-origin revision

- **Finding closed from `comm-000977`**: runnable resolution now builds a
  reentrancy-safe catalog-origin snapshot under the coordinator read token
  whenever deactivation records exist. Shared dependencies select their current
  catalog identity by canonical locator and decoded workflow id rather than
  inheriting a direct parent's scope, provenance, or source kind.
- **Catalog identity corrected**: package catalog entries now decode the
  package workflow definition so origin identity uses the actual workflow id
  and description while retaining the package name as its lookup name. Catalog
  projection uses an include-deactivated resolver that suppresses recursive
  snapshot capture.
- **Regression coverage**: direct project, nested direct user, and direct
  package shared dependencies now prove exact typed `WORKFLOW_DEACTIVATED`
  rejection and successful `includeDeactivated` inspection. Lookup-name and
  decoded-id mismatch, mutable direct/nested activation, package source kind,
  and one-off direct behavior remain distinct.
- **Verification passed**: the shared-node resolver matrix passed 9/9; mutable
  shared-node versioning passed 4/4; and the expanded accepted registry, CLI,
  GraphQL, server, instance, writer, transaction, shared-node, and parser
  matrix passed 188/188. Xcode-toolchain `swift build` completed; SwiftLint
  emitted only five unrelated pre-existing warnings; `git diff --check`,
  deleted-test detection, and package-applicability checks passed.
- **Completion state**: T10 and final handoff remain open solely for independent
  Step 7 adversarial review. No TypeScript, workflow package, prompt, script,
  skill, `riela-package.json`, or package-digest artifact changed. No commit,
  push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 metadata-only catalog-origin revision

- **Finding closed from `comm-000979`**: runnable activation policy construction
  no longer obtains origin identity through full catalog bundle resolution.
  Project, user, package, and mutable origins are inventoried from workflow
  declarations, package manifests, and the descriptor-pinned mutable registry
  without reading node payloads, hydrating prompts, materializing shared
  references, or invoking workflow history recovery.
- **Pre-materialization regression added**: a deactivated project dependency
  with deliberately invalid node payload JSON returns the exact typed
  `WORKFLOW_DEACTIVATED` error before payload decoding. Existing direct/nested
  project, user, package, immutable, mutable, and include-deactivated inspection
  coverage remains passing.
- **Verification passed**: the shared-node resolver matrix passed 10/10; mutable
  shared-node versioning passed 4/4; and the expanded accepted registry, CLI,
  GraphQL, server, instance, writer, transaction, shared-node, and parser
  matrix passed 189/189. Xcode-toolchain `swift build` completed; SwiftLint
  emitted only five unrelated pre-existing warnings; `git diff --check`,
  deleted-test detection, TypeScript-change detection, and package-applicability
  checks passed.
- **Completion state**: T10 and final handoff remain open solely for independent
  Step 7 adversarial review. No TypeScript, workflow package, prompt, script,
  skill, `riela-package.json`, or package-digest artifact changed. No commit,
  push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 Step 7 implementation-review revision

- **Review gates reopened and closed**: T6 and T9 were reopened for
  `comm-000983` and are complete again after all six high/mid findings and
  regression tests passed. T10 remains in progress for independent Step 7
  re-review; no adversarial gate is claimed before that decision.
- **GraphQL dispatch and validation**: every selected registry root now
  preflights operation type, argument/input shape, closed enums, nested
  selections, and duplicate response keys before provider dispatch.
  Expected errors are isolated to their root field, so later failures cannot
  rewrite earlier successful mutation results. Destructive invalid-document,
  invalid-enum, duplicate-key, and field-local error regressions pass.
- **Credential and working-directory boundaries**: fallback preflight and both
  domain executors receive credential-free requests after composite
  authorization. Trusted `LOCAL_PATH` references resolve against the request's
  CLI working directory. Credential visibility and relative-path regressions
  pass.
- **Activation and filesystem boundaries**: top-level and shared candidates
  are checked against the coordinated metadata/activation snapshot before node
  payload materialization. Activation documents, consolidation journals, and
  consolidation backups use pinned descriptor-relative operations; deterministic
  activation-root and journal-root swap tests pass.
- **Follow-up regressions closed during verification**: descriptor-relative
  backup creation now creates each file's parent without relying on directory
  enumeration order. Read-only homes without registry state preserve
  non-mutating catalog/resolution behavior instead of attempting state-root
  creation.
- **Verification passed**: Xcode-toolchain `swift build` completed; the
  expanded accepted matrix passed 197/197; SwiftLint reported only five
  unrelated pre-existing warnings; `git diff --check`, deleted-test detection,
  branch verification, typed-enum audit, and package-manifest applicability
  checks passed. The local Swift test/build wrappers retained their output
  pipes until command timeout after terminal success summaries; the recorded
  suite and build results themselves completed successfully.
- **Scope and state**: no TypeScript, workflow package, prompt, script, skill,
  or `riela-package.json` changed. No package digest refresh was applicable.
  No commit, push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 GraphQL parser and dispatch self-review revision

- **Review gates reopened and closed**: T6 and T9 were reopened for
  `comm-000985` and are complete again after all four high/mid findings and
  regression tests passed. T10 remains in progress pending independent Step 7
  re-review.
- **Strict selected-operation parsing**: nested selection arguments are retained
  and rejected where the selected field accepts none. Duplicate root arguments
  and duplicate inline input-object fields fail parsing before any provider
  call. Named fragment definitions and spreads expand recursively with
  duplicate-definition, unknown-fragment, type-condition, and cycle checks.
- **Ordered and fail-closed dispatch**: after complete all-domain preflight, the
  composite dispatches root fields one at a time in original document order.
  Only typed `WorkflowRegistryError` values become field-local payload errors;
  cancellation and unexpected provider failures return a top-level failure and
  stop later mutation dispatch.
- **Regression coverage**: destructive invalid-document tests prove nested
  arguments, duplicate `input` arguments, and duplicate target fields cause
  zero provider calls. Named root/nested fragments, mixed note/registry mutation
  ordering, cancellation, and unexpected-provider failure behavior are covered.
  An isolated filesystem-backed CLI smoke proves the formerly destructive
  `accepted(unexpected: true)` document now returns `INVALID_WORKFLOW` and
  preserves the registered workflow.
- **Verification passed**: `GraphQLWorkflowRegistryTests` passed 18/18; the
  shared Note/GraphQL/server parser matrix passed 107/107; the expanded accepted
  registry, CLI, GraphQL, server, writer, transaction, shared-node, and parser
  matrix passed 201/201. Xcode-toolchain build, SwiftLint, `git diff --check`,
  deleted-test detection, TypeScript applicability, and package-manifest
  applicability also passed.
- **Scope and state**: no TypeScript, workflow package, prompt, script, skill,
  or `riela-package.json` changed. No package digest refresh was applicable.
  No commit, push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 fragment validation and partial-data revision

- **Review gates reopened and closed**: T6 and T9 were reopened for
  `comm-000987` and are complete again after all high/mid findings and
  regressions passed. T10 remains in progress pending independent Step 7
  re-review.
- **Fragment preflight**: fragment definitions now reject directives and
  malformed tokens before their selection sets. Expanded nested selections
  retain their fragment type conditions, and the note and registry schema
  validators compare those conditions with the exact parent output type before
  provider dispatch.
- **Failure result preservation**: cancellation and unexpected registry
  provider failures stop subsequent mutation roots while returning already
  completed root data with the top-level error.
- **Regression coverage**: the destructive fragment-definition directive
  document causes zero provider calls; incompatible nested fragment types fail
  before list dispatch; success-to-unexpected-failure and
  success-to-cancellation sequences preserve the successful payload and leave
  the final mutation undispatched. An isolated filesystem-backed CLI smoke
  returns `INVALID_WORKFLOW` for the formerly destructive fragment document and
  proves the registered workflow remains listed.
- **Verification passed**: `GraphQLWorkflowRegistryTests` passed 19/19; the
  shared Note/GraphQL/server parser matrix passed 108/108; the expanded accepted
  registry, CLI, GraphQL, server, writer, transaction, shared-node, and parser
  matrix passed 202/202. Xcode-toolchain build, SwiftLint, `git diff --check`,
  deleted-test detection, TypeScript applicability, and package-manifest
  applicability also passed.
- **Scope and state**: no TypeScript, workflow package, prompt, script, skill,
  or `riela-package.json` changed. No package digest refresh was applicable.
  No commit, push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 operation uniqueness and fragment-budget revision

- **Review gates reopened and closed**: T6 and T9 were reopened for
  `comm-000989` and are complete again after all high/mid findings and
  regressions passed. T10 remains in progress pending independent Step 7
  re-review.
- **Selected-operation validation**: operation names are validated for
  document-wide uniqueness before `operationName` selection. Variable
  definitions are parsed for every operation, track names independently from
  defaults, and reject duplicates before any selected root can dispatch.
- **Bounded fragment expansion**: fragment expansion now enforces both a
  20-spread chain-depth limit and a 1,024-expansion document budget in addition
  to cycle and selection-depth checks.
- **Regression coverage**: destructive duplicate-variable and duplicate-
  operation documents perform zero provider calls. Deep acyclic and branching
  fragment graphs fail preflight before registry listing. The directive,
  type-condition, partial-data, and failure dispatch-stop regressions from
  `comm-000988` remain passing.
- **Verification passed**: `GraphQLWorkflowRegistryTests` passed 21/21; the
  shared Note/GraphQL/server parser matrix passed 110/110; the expanded accepted
  registry, CLI, GraphQL, server, writer, transaction, shared-node, and parser
  matrix passed 204/204. Xcode-toolchain build completed; SwiftLint emitted only
  five unrelated pre-existing warnings; isolated destructive CLI smokes,
  `git diff --check`, deleted-test detection, TypeScript applicability, branch
  verification, file-size checks, and package-manifest applicability passed.
- **Scope and state**: no TypeScript, workflow package, prompt, script, skill,
  or `riela-package.json` changed. No package digest refresh was applicable.
  No commit, push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 strict GraphQL grammar revision

- **Review gates reopened and closed**: T6 and T9 were reopened for
  `comm-000991` and are complete again after all three high findings and their
  destructive zero-provider-call regressions passed. T10 remains in progress
  pending independent Step 7 re-review.
- **Document-definition validation**: the shared parser now rejects unknown or
  trailing top-level definitions and enforces that an anonymous operation is
  the document's only operation before `operationName` selection or dispatch.
- **Strict input grammar**: variable definitions parse exactly one recursive
  named/list/non-null type reference with bounded nesting. Inline input-object
  keys must be GraphQL Name tokens; quoted JSON-style keys fail preflight.
  Operation-definition and type parsing moved to
  `Sources/RielaGraphQL/NoteGraphQLOperationParsing.swift`, keeping every
  changed Swift implementation file below 1,000 lines.
- **Regression coverage**: anonymous-plus-named, duplicate-name, trailing
  definition, malformed variable type, quoted input key, duplicate variable,
  directive, fragment type/budget, partial-data, and dispatch-stop regressions
  all pass. An isolated filesystem-backed smoke returns `INVALID_WORKFLOW` for
  all four formerly destructive documents and preserves the registered active
  workflow.
- **Verification passed**: `GraphQLWorkflowRegistryTests` passed 21/21; the
  shared Note/GraphQL/server matrix passed 110/110; the expanded accepted
  registry, CLI, GraphQL, server, writer, transaction, shared-node, and parser
  matrix passed 204/204. Xcode-toolchain build completed.
- **Scope and state**: no TypeScript, workflow package, prompt, script, skill,
  or `riela-package.json` changed. No package digest refresh was applicable.
  No commit, push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 document-wide GraphQL preflight revision

- **Review gates reopened and closed**: T6 and T9 were reopened for
  `comm-000993` and are complete again after the document-wide parser and
  destructive zero-provider-call regressions passed. T10 remains in progress
  pending independent Step 7 re-review.
- **Whole-document validation**: every operation definition is now parsed before
  operation selection. Direct registry execution validates every registry
  operation, and composite execution preflights every unselected domain without
  authorizing or dispatching it.
- **Variable isolation**: unselected operations retain static argument and enum
  validation without requiring runtime variable values belonging only to those
  operations. The selected operation continues to require all referenced
  runtime variables.
- **Regression coverage**: direct and composite tests prove an invalid
  unselected registry enum prevents a selected delete mutation from reaching
  the provider. A valid unselected operation with an unresolved runtime
  variable does not block the selected mutation.
- **Verification passed**: `GraphQLWorkflowRegistryTests` passed 23/23; the
  shared Note/GraphQL/server matrix passed 112/112; the expanded accepted
  registry, CLI, GraphQL, server, writer, transaction, shared-node, and parser
  matrix passed 206/206. The filesystem-backed smoke returned
  `INVALID_WORKFLOW` and preserved the registered active workflow.
- **Scope and state**: no TypeScript, workflow package, prompt, script, skill,
  or `riela-package.json` changed. No package digest refresh was applicable.
  No commit, push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 variable schema and fragment completeness revision

- **Review gates reopened and closed**: T6 and T9 were reopened for
  `comm-000995` and are complete again after `self-review-008` and
  `self-review-009` plus their destructive zero-provider-call regressions
  passed. T10 remains in progress pending independent Step 7 re-review.
- **Typed operation variables**: every operation now retains its complete
  variable declaration set, recursive named/list/non-null type references,
  defaults, and input-position usages. The document parser rejects undeclared
  variables, unknown or output-only input types, and incompatible variable
  positions in registry roots before any selected-operation dispatch.
  Unselected operations remain isolated from selected-operation runtime values.
- **Complete fragment definitions**: fragment expansion tracks every definition
  used anywhere in the document. Referenced definitions continue through full
  selection, argument, enum, type-condition, cycle, depth, and expansion-budget
  validation; GraphQL's no-unused-fragments rule rejects every remaining
  definition before operation selection or dispatch.
- **Regression coverage**: selected and unselected incompatible registry
  variable types, undeclared variables, unknown input types, and an unused
  fragment containing an invalid registry enum all fail with
  `INVALID_WORKFLOW` and zero destructive provider calls.
- **Verification passed**: `GraphQLWorkflowRegistryTests` passed 25/25; the
  shared Note/GraphQL/server matrix passed 114/114; the expanded accepted
  registry, CLI, GraphQL, server, writer, transaction, shared-node, and parser
  matrix passed 208/208. Xcode-toolchain build emitted `Build complete!`; the
  local wrapper retained its output pipe after terminal completion. Isolated
  filesystem-backed variable and unused-fragment smokes both returned
  `INVALID_WORKFLOW`, and the registered workflow remained active and listed.
- **Scope and state**: no TypeScript, workflow package, prompt, script, skill,
  or `riela-package.json` changed. No package digest refresh was applicable.
  No commit, push, merge, or main-branch mutation was performed.

### 2026-07-23 - Step 6 complete variable validation revision

- **Review gates reopened and closed**: T6 and T9 were reopened for
  `comm-000997` and are complete again after `self-review-010`,
  `self-review-011`, and `self-review-012` plus their destructive
  zero-provider-call regressions passed. T10 remains in progress pending
  independent Step 7 re-review.
- **All-domain variable positions**: the shared schema index now validates
  declared variable types at every known note and registry input position in
  every operation before selection or dispatch. Existing note sort documents
  now declare the published `NoteListSort` type while preserving their runtime
  invalid-value diagnostics.
- **Complete declaration usage**: execution preflight aggregates variable uses
  across each operation's roots and expanded fragments and rejects every unused
  declaration. Lightweight route and telemetry scans remain non-executing and
  do not apply execution-only usage validation.
- **Typed defaults**: variable defaults retain scalar, enum, list, and input-
  object literal kinds. Defaults are recursively validated against declared
  nullability, built-in scalars, schema enums, input objects, lists, and custom
  scalars before they enter operation variables.
- **Regression coverage**: an incompatible unselected note variable, an unused
  selected mutation variable, and a quoted enum default all return
  `INVALID_WORKFLOW` and perform zero activation or deletion provider calls.
- **Verification passed**: `GraphQLWorkflowRegistryTests` passed 26/26; the
  shared Note/GraphQL/server matrix passed 115/115; the expanded accepted
  registry, CLI, GraphQL, server, writer, transaction, shared-node, and parser
  matrix passed 209/209. Xcode-toolchain build completed. Isolated
  filesystem-backed smokes rejected all three formerly destructive documents
  and preserved the registered workflow's active state.
- **Scope and state**: no TypeScript, workflow package, prompt, script, skill,
  or `riela-package.json` changed. No package digest refresh was applicable.
  No commit, push, merge, or main-branch mutation was performed.

## Known risks carried into implementation

- Missing an execution/resolution path could allow activation bypass.
- Incorrect global lock acquisition or holding periods could deadlock or expose
  partial consolidation state.
- Parser, schema, executor, and authorization-gate drift could permit partial or
  unauthorized GraphQL execution.
- Consolidation interruption recovery may encounter ambiguous artifact state;
  it must fail closed and preserve evidence.
- Origin identity can drift when externally owned bundles move; orphan overlay
  records must not activate or deactivate the wrong origin.
- Renaming public CLI/JSON/Swift terminology can regress scripted callers;
  deprecated flag aliases and compatibility decoders require explicit tests.
- New paths must preserve the existing registry's containment, pinned-root,
  symlink rejection, digest, durability, and publication recovery guarantees.
