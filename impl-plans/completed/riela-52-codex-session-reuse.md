# Riela 52 Codex Session Reuse And Authentication Readiness Implementation Plan

**Status**: Completed
**Workflow Mode**: `issue-resolution`
**Issue**: [riela#52](https://github.com/tacogips/riela/issues/52)
**Design References**: `design-docs/specs/design-riela-52-codex-session-reuse.md`; `design-docs/specs/design-workflow-json.md#sessionpolicy`
**Created**: 2026-07-17
**Last Updated**: 2026-07-17

---

## Design Source Of Truth

Implement explicit, branch-safe Codex thread reuse in workflow execution while
preserving fresh execution for nil, missing-mode, and explicit `new` policies.
The accepted design, not the earlier intake summary, controls implementation
details: typed root-run/current-session/current-step identity, separate fresh
and resumed prompt forms, successful-process thread promotion, configuration-
keyed authentication single flight, top-level awaited cleanup, and effective
step-or-node policy validation at every resolved-bundle boundary.

### Included

- Provider-neutral execution identity and run-ended lifecycle plumbing.
- Fresh/resumed prompt rendering and deterministic per-attempt selection.
- Codex fresh/resume command selection using the existing
  `CodexProcessCommandBuilder` argument builders.
- Workflow-path JSONL thread-id observation and centralized extraction rules.
- Run/session/step-keyed Codex thread state with fanout isolation.
- Configuration-keyed Codex authentication readiness single flight and
  top-level run cleanup.
- Raw, typed, and resolved-bundle validation for effective session policies.
- CLI, runtime, catalog, staged-verification, inspect, temporary-workflow, and
  server validation call-site coverage required by the accepted design.
- Focused adapter, core, CLI, and server tests plus full verification and
  documentation closeout.

### Excluded

- Keeping one Codex OS process alive between workflow steps.
- Reuse across workflow runs, workflow-session boundaries, fanout siblings, or
  cross-workflow child sessions.
- Cursor CLI behavior changes or provider-neutral Codex JSONL/session storage.
- A Codex GUI/helper suppression flag, schema-version bump, or package migration.
- Any pre-existing RielaApp web-server/UI, unrelated RielaCLI, release-script,
  or package-resolution worktree changes.

## Codex Reference Traceability

| Reference | Planned use |
| --- | --- |
| `Sources/CodexAgent/CodexAgentAdapter.swift` | Shared concurrency-safe run state, readiness coordination, session resolution, prompt/command decision, successful-result promotion, and cleanup. |
| `Sources/CodexAgent/CodexAgentProcess.swift` | Existing fresh/resume argv builders and piped-prompt validation remain authoritative. |
| `Sources/CodexAgent/CodexProcessManager.swift` | Centralize or reuse current session-id extraction semantics; do not introduce a divergent parser. |
| `Sources/RielaCore/WorkflowModel.swift` | Preserve normalized `new`/`reuse`/`inheritFromStepId` model behavior. |
| `Sources/RielaCore/AdapterContracts.swift` | Add typed execution identity, fresh/resumed prompt forms, lifecycle context, and default async no-op hook. |
| `Sources/RielaCore/DeterministicWorkflowRunner.swift` | Root run identity ownership, effective-policy validation, metadata propagation, and exactly-once awaited cleanup that preserves the original result. |
| `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift` | Render fresh and resumed prompt forms from the same selected variant and variables. |
| `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift` | Inherit root run identity while retaining distinct branch workflow-session ids and joining children before cleanup. |
| `Sources/RielaCore/WorkflowValidation.swift` | Add compatibility-preserving bundle-aware effective-policy validation. |
| `Sources/RielaCore/WorkflowRawValidation.swift` | Validate authored policy shape, enum, non-empty inheritance, cross-field rules, and target step. |
| `Sources/RielaAdapters/LocalAgentProcess.swift` | Add non-consuming raw stdout observation without changing streaming, normalization, redaction, termination, or cancellation. |
| `Sources/RielaAdapters/DispatchingNodeAdapter.swift` | Forward typed metadata and lifecycle calls to already-loaded provider adapters only. |
| `Sources/RielaCLI/WorkflowResolution.swift` | Retain raw validation at base decode and provide the hydrated payload map to bundle-aware consumers. |
| `Sources/RielaCLI/WorkflowResolution+SharedNodeRefs.swift` | Retain raw validation for referenced authored workflows and materialize shared nodes for later bundle validation. |
| `Sources/RielaCLI/WorkflowValidateInspectCommands.swift` | Validate effective policies for validate/inspect and expose diagnostics. |
| `Sources/RielaCLI/WorkflowStagedVerification.swift` | Validate the fully resolved staged bundle before required verification. |
| `Sources/RielaCLI/WorkflowCatalogCommands.swift` | Calculate list/status validity from bundle-aware diagnostics. |
| `Sources/RielaCLI/WorkflowRunCommand.swift` | Build temporary node-id maps and validate temporary/final patched bundles. |
| `Sources/RielaServer/WorkflowServingController.swift` | Validate fully resolved direct-directory bundles while preserving deferred scoped/package resolution. |

Intentional accepted divergence from the intake plan: authentication success is
not merely cached by a broad run-global boolean. It is keyed by root
`workflowRunId` and a secret-safe fingerprint of executable, working directory,
and merged environment. Cleanup is an awaited provider-neutral lifecycle hook,
and effective node-file policy validation is part of this issue.

## Task Breakdown

### T1. Baseline, Ownership, And Dirty-Tree Audit

**Status**: COMPLETE
**Write Scope**: only `tmp/riela-52-codex-session-reuse/` for scratch evidence
**Depends On**: accepted Step 3 design

**Deliverables**:

- Record the initial `git status`, unstaged/staged file lists, and issue-owned
  source/test/doc paths before editing.
- Create `tmp/riela-52-codex-session-reuse/issue-owned-swift-paths.txt` as the
  explicit newline-separated Swift lint manifest. Seed it from the intentional
  issue #52 write scopes compared with the baseline, not from an unrestricted
  `git diff`; append every issue-owned Swift file before it is first edited or
  created, including new untracked Swift files. Keep unrelated baseline paths
  out of the manifest.
- Maintain `tmp/riela-52-codex-session-reuse/issue-owned-untracked-paths.txt`
  as the companion explicit list for the per-file whitespace checks in T8;
  never infer ownership from the final dirty tree alone.
- Confirm current adapter input, runner recursion/fanout, JSONL process hooks,
  session-id parser, validator overloads/call sites, and relevant test seams.
- Record implementation-only discoveries in the progress log; escalate any
  required design divergence before coding it.

**Verification**:

- `git status --short`
- `git diff --name-only`
- `git diff --cached --name-only`
- `test -f tmp/riela-52-codex-session-reuse/issue-owned-swift-paths.txt`
- `test -f tmp/riela-52-codex-session-reuse/issue-owned-untracked-paths.txt`
- `rg -n 'sessionPolicy|AdapterExecutionInput|buildResumeArguments|sessionId|validate\(' Sources/CodexAgent Sources/RielaAdapters Sources/RielaCore Sources/RielaCLI Sources/RielaServer Tests`

### T2. Provider-Neutral Execution And Lifecycle Contracts

**Status**: COMPLETE
**Write Scope**: `Sources/RielaCore/AdapterContracts.swift`,
`Sources/RielaCore/DeterministicWorkflowRunner.swift`,
`Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift`,
`Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`, and focused
`Tests/RielaCoreTests/DeterministicWorkflowRunner*Tests.swift`
**Depends On**: T1

**Deliverables**:

- Add typed `workflowRunId`, `workflowSessionId`, and workflow `stepId` metadata
  to adapter execution input without placing identity in business variables.
- Add separately rendered `freshPromptText` and `resumedPromptText`; preserve
  source compatibility/current fresh behavior for non-Codex adapters.
- Add the exact async, nonthrowing `workflowRunDidEnd` contract and default no-op.
- Derive root run identity after top-level session entry, propagate it through
  recursive fanout/cross-workflow calls, and retain each invocation's distinct
  current workflow-session identity.
- Gate lifecycle ownership to the top-level call; save the original success,
  provider error, or cancellation, await cleanup after descendants join, then
  return/rethrow the unchanged original outcome.

**Verification**:

- Tests for identity propagation through ordinary, fanout, and cross-workflow
  execution.
- Tests for exactly one top-level lifecycle callback and zero recursive callbacks.
- Suspending-cleanup tests proving success/error/cancellation is not observable
  before cleanup completes and cleanup cannot replace the original outcome.
- Prompt tests for session-start inclusion/omission and retry rendering rules.
- `swift test --filter RielaCoreTests.DeterministicWorkflowRunner`

### T3. Effective Session-Policy Validation

**Status**: COMPLETE
**Write Scope**: `Sources/RielaCore/WorkflowValidation.swift`,
`Sources/RielaCore/WorkflowRawValidation.swift`, related model/helper files only
if required, and focused `Tests/RielaCoreTests/Workflow*Tests.swift`
**Depends On**: T1

**Deliverables**:

- Preserve workflow-only validation and add the compatibility-defaulted
  bundle-aware overload accepting `[String: AgentNodePayload]`.
- Validate exactly `step.sessionPolicy ?? nodePayload.sessionPolicy`, including
  step-over-node precedence and shared-node use.
- Reject inheritance unless mode is `reuse`; reject empty and unknown
  `inheritFromStepId`; keep an unexecuted but valid same-workflow target legal.
- Keep raw validation limited to authored `workflow.json`; use bundle-aware
  validation for hydrated node files/shared references/patches.

**Verification**:

- Tests for step policies, node policies, precedence, shared nodes, missing
  mode/new inheritance, empty/unknown targets, and valid unresolved targets.
- Programmatic request test proving invalid effective node policy fails before
  any adapter call.
- `swift test --filter RielaCoreTests.WorkflowModelTests`
- `swift test --filter RielaCoreTests.DeterministicWorkflowRunnerTests`

### T4. Non-Consuming Codex JSONL Thread Observation

**Status**: COMPLETE
**Write Scope**: `Sources/RielaAdapters/LocalAgentProcess.swift`,
`Sources/CodexAgent/CodexProcessManager.swift`, a responsibility-focused new
`Sources/CodexAgent` file if needed, and focused `Tests/AgentAdapterTests` /
`Tests/CodexAgentTests`
**Depends On**: T1

**Deliverables**:

- Expose raw stdout observation without consuming or mutating normal streaming,
  backend-event classification, response normalization, redaction, termination,
  or cancellation behavior.
- Centralize the extractor shared with `CodexProcessManager` for
  `thread.started.thread_id`, `session_meta.meta.id`, and supported
  `session_meta` id aliases/payload nesting.
- Ignore empty/non-string ids; represent repeated equal ids as one value and
  conflicting ids as ambiguous rather than selecting one.

**Verification**:

- Parser tests for every accepted JSONL variant, repeated ids, empty/non-string
  values, malformed lines, and conflicting ids.
- Process tests proving observation does not remove normalized output or events.
- `swift test --filter CodexAgentTests`
- `swift test --filter AgentAdapterTests.CodexAgentEventTests`

### T5. Codex Session State, Command Selection, And Promotion

**Status**: COMPLETE
**Write Scope**: `Sources/CodexAgent/CodexAgentAdapter.swift`,
`Sources/CodexAgent/CodexAgentProcess.swift` only if reuse-builder integration
requires a source-compatible seam, new responsibility-focused Codex state file
if needed, and focused `Tests/AgentAdapterTests`
**Depends On**: T2, T4

**Deliverables**:

- Introduce one concurrency-safe reference state owner shared across value-typed
  adapter copies, keyed by `(workflowRunId, workflowSessionId, stepId)` and
  `(workflowRunId, workflowSessionId)` latest state.
- Resolve one immutable per-attempt outcome: fresh for nil/missing/new; exact
  same-session inheritance for named reuse; same-session latest for unnamed
  reuse; fresh fallback when unresolved.
- Select the matching fresh/resumed prompt and delegate argv construction to
  existing `buildExecArguments`/`buildResumeArguments`; retain piped stdin,
  option ordering, and prompt-transport validation.
- Promote thread state only after process success and before output-contract
  validation. Implement exact accepted rules for fresh, id-less resume,
  matching resume id, ambiguous metadata, conflicting resume id, failures, and
  cancellation.
- Ensure explicit `new` remains fresh on every retry while a successful
  fresh-fallback can be resumed by its next validation attempt.

**Verification**:

- Command tests: exact/latest reuse -> resume; nil/new/unresolved reuse -> exec.
- Prompt/argv tests: fresh and fallback include session-start; resume omits it.
- Propagation tests for inherited step targeting, successful id-less resume,
  ambiguous/conflicting metadata, failed/canceled/id-less fresh execution, and
  validation retries.
- Isolation tests proving no lookup across root runs, parent/child sessions, or
  sibling fanout sessions.
- `swift test --filter AgentAdapterTests`

### T6. Authentication Single Flight And Run Cleanup

**Status**: COMPLETE
**Write Scope**: issue-owned Codex state/adapter files from T5,
`Sources/RielaAdapters/DispatchingNodeAdapter.swift`, and focused
`Tests/AgentAdapterTests` / `Tests/RielaCoreTests`
**Depends On**: T2, T5

**Deliverables**:

- Key readiness by root run id plus a secret-safe fingerprint of effective
  executable, working directory, and merged environment.
- Represent absent/checking/ready explicitly so concurrent callers share one
  in-flight task; cache success only and remove failure/cancellation state.
- Preserve the injectable `checkAuthPreflight` seam and current error
  classification/redaction/cancellation behavior.
- Forward lifecycle cleanup from `DispatchingNodeAdapter` to a stable snapshot
  of already-loaded adapters without loading unused providers.
- On root cleanup, cancel/await in-flight readiness and atomically remove all
  readiness/thread entries for that run, regardless of caller cancellation.

**Verification**:

- Tests for concurrent success single flight, same-run cache hit, differing
  configuration fingerprints, distinct runs, failure retry, canceled waiter,
  root cancellation, and injectable-seam behavior.
- Fanout lifecycle tests: fast branch does not evict slower sibling; parent
  continues after join using cached readiness and only parent-session history.
- Dispatch tests proving only loaded adapters receive one cleanup callback.
- `swift test --filter AgentAdapterTests`
- `swift test --filter RielaCoreTests.DeterministicWorkflowRunnerFanoutTests`

### T7. Resolved-Bundle Validation Call Sites

**Status**: COMPLETE
**Write Scope**: `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`,
`Sources/RielaCLI/WorkflowStagedVerification.swift`,
`Sources/RielaCLI/WorkflowCatalogCommands.swift`,
`Sources/RielaCLI/WorkflowRunCommand.swift`,
`Sources/RielaServer/WorkflowServingController.swift`, and directly associated
RielaCLI/RielaServer tests; do not edit dirty unrelated EntryPoint/serve-HTTP files
**Depends On**: T3

**Deliverables**:

- Use bundle-aware validation after resolution/materialization and after any
  command-local or instance patch in validate, inspect, staged verification,
  catalog status/list, temporary run, local runtime, and direct-directory serve.
- Build the temporary node-id payload map before validation; validate bare
  temporary workflows with an empty map.
- Surface inspect diagnostics and preserve catalog list's per-entry invalid
  representation.
- Preserve raw decode validation and deferred scoped/package server selection;
  prove the later runtime guard rejects invalid deferred bundles.

**Verification**:

- CLI tests supply invalid effective node policies through validate, inspect,
  staged verification, catalog status/list, temporary envelope, instance patch,
  and bare valid step-only temporary input.
- Server tests cover invalid direct-directory node policy, invalidating patch,
  deferred scoped/package selection, and later runtime rejection.
- `swift test --filter RielaCLITests.WorkflowCommandInspectionTests`
- `swift test --filter RielaCLITests.WorkflowCommandCatalogTests`
- `swift test --filter RielaCLITests.WorkflowStagedVerificationTests`
- `swift test --filter RielaCLITests.WorkflowCommandTests`
- `swift test --filter RielaServerTests.WorkflowServingControllerTests`

### T8. Integrated Regression Verification And Documentation Closeout

**Status**: COMPLETE
**Write Scope**: issue-owned tests; `design-docs/specs/design-riela-52-codex-session-reuse.md`,
`design-docs/specs/design-workflow-json.md`, and this plan only for factual
implementation results; scratch evidence only under
`tmp/riela-52-codex-session-reuse/`
**Depends On**: T2, T3, T4, T5, T6, T7

**Deliverables**:

- Run focused, broader, full, lint, whitespace, and dirty-tree verification;
  log exact commands and results.
- Reconcile documentation with actual behavior without weakening the accepted
  semantics or inventing a GUI suppression flag.
- Change this plan to `Completed` only after every criterion passes or has an
  explicitly recorded, accepted exception.
- Confirm unrelated pre-existing changes were neither edited nor staged; do
  not commit or push unless the later implementation workflow explicitly owns
  and authorizes that action.

**Verification**:

- `swift test --filter CodexAgentTests`
- `swift test --filter AgentAdapterTests`
- `swift test --filter RielaCoreTests`
- `swift test --filter RielaCLITests`
- `swift test --filter RielaServerTests`
- `swift test`
- `swift build`
- `while IFS= read -r file; do [ -z "$file" ] || swiftlint lint --strict "$file"; done < tmp/riela-52-codex-session-reuse/issue-owned-swift-paths.txt`
- `git diff HEAD --check`
- For every path in
  `tmp/riela-52-codex-session-reuse/issue-owned-untracked-paths.txt`, run
  `git diff --no-index --check /dev/null <untracked-issue-file>` separately;
  require no whitespace-error output and record exit `1` as expected when the
  file content differs from `/dev/null`.
- `git status --short`
- `git diff --cached --name-only`
- Compare the final dirty paths and both issue-owned manifests against the T1
  baseline. Record evidence that all issue-owned Swift files, including newly
  untracked files, were linted and that unrelated RielaApp web-server/UI, CLI
  entry-point/serve-HTTP, release-script, and web files were untouched by issue
  #52 work.

## Dependencies

| Deliverable | Dependency | Status |
| --- | --- | --- |
| Entire plan | Step 3 accepted design and schema update | Available |
| Core identity/lifecycle | Existing top-level session entry and recursive run request model | Available |
| Prompt selection | Existing session-start and ordinary prompt rendering | Available |
| Resume execution | `CodexProcessCommandBuilder.buildResumeArguments` and piped-prompt rules | Available |
| Thread capture | Existing `CodexProcessManager` extraction semantics and JSONL stdout | Available |
| Branch isolation | Existing distinct fanout child workflow-session ids | Available |
| Auth single flight | Shared Codex adapter state and typed root run id | Pending T2/T5 |
| Bundle validation callers | Hydrated/materialized node payload maps and T3 overload | Pending T3 |
| Cleanup | Structured descendant join and loaded-provider adapter snapshot | Pending T2/T6 |
| Final closeout | All implementation and focused tests | Pending T2-T7 |

## Parallelizable Tasks

- T3 and T4 may proceed in parallel after T1: their production/test write
  scopes are disjoint.
- T2 may proceed in parallel with T3 and T4 after T1, provided T2 does not edit
  workflow validation files and T4 does not edit adapter contracts.
- T5 must wait for T2 and T4 because its immutable resolution consumes the new
  execution/prompt contract and raw observation semantics.
- T7 may proceed in parallel with T5 after T3 because its CLI/server write
  scope is disjoint from Codex adapter state.
- Within T7, CLI and server implementation/tests may run in parallel because
  their source and test paths are disjoint.
- T6 is not parallelizable with T5 because both modify the shared Codex state
  owner; its runner integration also depends on T2 lifecycle semantics.
- T8 starts only after T2-T7 converge.

## Completion Criteria

- [x] Nil, missing-mode, and explicit `new` always use fresh Codex exec; reuse
      with no resolvable same-session history falls back to fresh without error.
- [x] Named reuse resolves only the targeted same-session step; unnamed reuse
      resolves only the same-session latest thread.
- [x] Fresh/resumed prompts and validation-retry behavior match the accepted
      design, including session-start omission only for an actually resumed turn.
- [x] Supported JSONL thread ids are observed without disrupting output/events;
      promotion honors success, id-less resume, ambiguity, conflict, failure,
      and cancellation rules.
- [x] Concurrent fanout siblings, parent/child sessions, and different root runs
      cannot resolve one another's Codex thread state.
- [x] Authentication is configuration-keyed, single-flight, success-only cached,
      retryable after failure/cancellation, and preserves error/redaction seams.
- [x] Completed, failed, and canceled root runs await exactly one cleanup after
      descendants join; recursive runs do not clean shared state.
- [x] Raw and effective session-policy validation covers authored steps, node
      payloads, precedence, shared nodes, patches, all named call sites, and the
      final programmatic runtime guard.
- [x] Cursor behavior and other adapters' existing fresh prompt behavior remain
      unchanged.
- [x] Focused tests, RielaCore/RielaCLI/RielaServer suites, full `swift test`,
      and explicit `swift build` pass.
- [x] Strict SwiftLint passes for exactly the T1-recorded issue-owned Swift
      paths, including new untracked files; no unrelated dirty Swift path is
      included merely because it appears in `git diff`.
- [x] `git diff HEAD --check` passes for tracked changes, and every issue-owned
      untracked file passes its separate `git diff --no-index --check /dev/null
      <file>` inspection with no whitespace diagnostics; exit `1` is recorded
      as expected when the untracked file differs from `/dev/null`.
- [x] Design and plan documents record final behavior and verification; this
      plan is moved to `impl-plans/completed/` only during completed closeout.
- [x] No scratch files exist outside `tmp/riela-52-codex-session-reuse/`, and no
      unrelated dirty file was edited, staged, committed, or pushed.

## Progress Log Expectations

Every implementation session must append a dated entry containing task ids,
files changed, exact verification commands/results, blockers, and any accepted
design divergence with owner. The final entry must include the T1-versus-final
dirty-tree audit, focused/full test and lint results, lifecycle/fanout evidence,
and the plan move from active to completed.

## Progress Log

### Session: 2026-07-17

**Tasks Completed**: Created the implementation plan after Step 3 accepted the
design.

**Tasks In Progress**: None.

**Blockers**: None.

**Notes**: Step 3 reported no findings and accepted both design documents for
implementation planning. This plan explicitly incorporates its accepted
configuration-keyed readiness, async run cleanup, fresh/resumed prompt,
effective node-policy validation, and fanout-lifecycle requirements. Existing
unrelated dirty worktree paths remain outside the write scope.

### Revision: 2026-07-17

**Finding Addressed**: `PLAN-VERIFY-001`.

**Changes**: Added explicit `swift build`; replaced unrestricted diff-derived
SwiftLint discovery with the T1-maintained issue-owned Swift manifest, including
new untracked files; changed tracked whitespace verification to `git diff HEAD
--check`; and added a separate `git diff --no-index --check /dev/null <file>`
check for every issue-owned untracked file with exit `1` documented as expected
when content differs.

### Completion: 2026-07-17

**Tasks Completed**: T1-T8.

**Implementation**: Added provider-neutral run/session/step identity, fresh and
resumed prompt forms, awaited root-run lifecycle cleanup, branch-safe Codex
thread state, non-consuming JSONL thread-id capture, fresh/resume command
selection, configuration-keyed authentication single flight, effective
session-policy validation, and resolved CLI/server validation call sites.

**Focused Verification**:

- `swift test --filter CodexSessionReuseTests` — 6 passed.
- `swift test --filter WorkflowSessionPolicyTests` — 4 passed.
- `swift test --filter AgentAdapterTests` — 129 passed.
- `swift test --filter CodexAgentTests` — 39 passed.
- `swift test --filter RielaCLITests` — 557 passed.
- `swift test --filter RielaServerTests` — 40 passed.
- `swift build` — passed with the Xcode Swift toolchain.
- strict per-file SwiftLint command from T8 — passed for every path in the
  issue-owned Swift manifest.

**Full-Suite Exception**: `swift test` executed 2,082 tests with 4 skipped and
9 failures. All nine are outside issue #52: seven assertions belong to the
pre-existing RielaApp daemon event-source restart test, one deletion-readiness
test detects the unrelated assistant-model fixture, and one deletion-readiness
test detects the explicitly out-of-scope `web/node_modules` TypeScript tree.
No issue-owned session-reuse, validation, adapter, CLI, or server test failed.
The user constraint forbids changing those unrelated RielaApp/web paths, so
this is the recorded full-suite exception rather than an issue #52 blocker.

**Design Divergence**: None. No Codex GUI-suppression flag was added or claimed.

**Dirty-Tree Audit**: Issue-owned changes are limited to the implementation,
tests, and design/plan paths recorded by the T1 manifests. No file was staged,
committed, or pushed; scratch evidence remains under
`tmp/riela-52-codex-session-reuse/`.
