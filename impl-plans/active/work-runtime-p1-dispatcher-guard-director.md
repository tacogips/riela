# Work Runtime P1: Dispatcher integration and plan contract

**Status**: Resumed Step 4 authored; Step 5 review pending; implementation BLOCKED on external dependency readiness.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Resume and complete Work Runtime P1 dispatcher, guard, and director
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.6 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review`, `accepted`; no findings or revision request.
**Codex-agent references**: `comm-000001`, `comm-000002`, `comm-000003`, `comm-000004`, `riela-manager`, `step1-issue-intake`, `step2-design-doc-update`, `step3-design-review`, `step4-impl-plan-create`; downstream installed-package implementation/review executions must record their actual IDs.
**Updated**: 2026-09-22

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [
    "p1-reservation",
    "p1-lifecycle",
    "p1-capabilities",
    "p1-sandbox"
  ],
  "writePaths": [
    "Sources/RielaWork/TaskDispatcher.swift",
    "Sources/RielaWork/AgentDirector.swift",
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift",
    "Sources/RielaCLI/ParsedWorkflowOptions.swift",
    "Sources/RielaCLI/WorkflowCommands.swift",
    "Sources/RielaCLI/ProductionNodeAdapter.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/RielaCommand+SessionParsing.swift",
    "Sources/RielaCLI/SessionCommands.swift",
    "Sources/RielaCLI/SessionCommandModels.swift",
    "Sources/RielaCLI/LoopCommands.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Tests/RielaWorkTests/TaskDispatcherTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaWorkTests/WorkGuardDispatcherTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskRuntimeExampleTests.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/CommandParsingTests.swift",
    "Tests/RielaCLITests/WorkflowCommandAutoImproveTests.swift",
    "Tests/RielaCLITests/WorkflowCommandInspectionTests.swift",
    "Tests/RielaCLITests/WorkflowCommandPackageLifecycleTests.swift",
    "Tests/RielaCLITests/RielaExampleParityTests.swift",
    "Tests/RielaCLITests/WorkflowRunHelpTests.swift",
    "examples/auto-improve/**",
    "examples/default-superviser/**",
    "examples/supervised-mock-retry/**",
    "examples/task-repair-loop/**",
    "examples/task-agent-director/**",
    "impl-plans/progress/p1-dispatch.md"
  ],
  "sharedPaths": [
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaWorkTests/WorkGuardDispatcherTests.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift"
  ],
  "progressLog": "impl-plans/progress/p1-dispatch.md",
  "taskIds": [
    "P1-6a",
    "P1-6b",
    "P1-6c",
    "P1-6d",
    "P1-7a",
    "P1-7b"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter WorkStoreReservationTests",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|CompletionEvaluatorTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests'",
    "xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-dispatch/changed-swift-files.nul",
    "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache",
    "tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-repair-loop --workflow-definition-dir examples --output json",
    "tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/examples/task-repair-loop --output json",
    "tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json",
    "tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/examples/task-agent-director --output json",
    "rg -n 'autoImprove|nestedSuperviser|WorkflowAutoImprovePolicy|WorkflowMutationMode|SupervisedScenarioNodeAdapter|--auto-improve|--nested-superviser' Sources Tests README.md examples",
    "git diff --check",
    "git diff --cached --check"
  ],
  "dependencyMode": "external-readiness-gates; not implementation fanout in this run",
  "serialFinalizationPaths": [
    "README.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Sources/RielaCore/SurfaceCatalog+RowSupport.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "impl-plans/README.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md"
  ],
  "taskDependencies": {
    "P1-6a": [
      "p1-reservation",
      "p1-lifecycle",
      "p1-capabilities",
      "p1-sandbox"
    ],
    "P1-6b": [
      "P1-6a"
    ],
    "P1-6c": [
      "P1-6a"
    ],
    "P1-6d": [
      "P1-6a",
      "P1-6c"
    ],
    "P1-7b": [
      "P1-6a",
      "P1-6b",
      "P1-6c",
      "P1-6d"
    ],
    "P1-7a": [
      "P1-7b"
    ]
  }
}
```


## Authority, intent and context

Implement only the six unchecked tasks P1-6a–d and P1-7a–b, retaining correct
checkpoint code from ancestors 368a3032 and c6a35e6. The accepted source is
`design-docs/specs/design-work-runtime-consolidation.md` §17.1–17.6, with §5a
and §5–7 supplying domain context. Step 3 accepted the resumed design in
`comm-000004`, `step3-design-review-attempt-1-exec-4`, session
`codex-design-and-implement-review-loop-session-1`: `accepted: true`,
`needs_revision: false`, findings/feedback empty. No current Step 5 feedback
was supplied. Earlier acceptance and progress records do not certify this run.

Current HEAD inspected on 2026-09-22 is
`f085c1f9410e8ff2f3d4a8cdc8fb9452156fbdec`. Task CLI supports show/list;
TaskDispatcher, AgentDirector, the four mutation/integration/example suites
and both replacement bundles are absent. Reservation APIs exist but have not
passed this run's behavioral readiness gates. WorkStore+Decisions currently
trusts caller completion, lacks scoped causal validation, returns current rows
on replay and defers only cancel; TaskGuardCoordinator forwards that verdict.
DeterministicDirector still needs stable ordering and gate-recovery budget
checks from its owner. Capabilities are unproven. Inspection evidence:
`tmp/work-runtime-p1/step4-resume/inspection-evidence.json` (all six commands
exit 0); source inspection is not passing implementation verification.

Continue only the Riela-owned immutable user-scope package at
`/Users/taco/.riela/packages/codex-design-and-implement-review-loop/`, inspected
version 0.3.5, minimum 0.3.5. Do not edit that installation, launch another
workflow or replace native scheduling. Stay in the supplied
`feat/remaining-impl-plans` directory; no worktrees, private branches or
concurrent Git mutations. Commit and push of accepted P1 work and narrow docs
are authorized by current workflowInput; base integration is not requested.
Preserve unrelated changes, accepted workflow-defect documents and all Monja
tenant-sharding-d48 work. Implementation uses native Codex gpt-5.6-terra low
effort; plan and adversarial reviews remain independent workflow nodes.

Non-goals: implementation or closure of the other five P1 plans; P2–P7;
loop-engineering, agent-node-output-contract, workflow-defect detection,
Tauri, note plans; task serve; new remote authentication; new planner or
capability registry; compatibility/migration for removed auto-improve state;
recursive director repair, proposals and specialist classification; broad
cleanup, formatting, speculative abstractions and optional hardening.
Plain workflow run remains task-free. Existing loop, routine, specialist and
event behavior remains intact.

No external Codex-reference input exists; ../../codex-agent is absent per
accepted design §17.5. Codex-agent references above are workflow provenance,
not a parity source. Cursor invocation/auth/probes/heartbeat stay in
`Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` or its adapter helpers,
owned by the capability dependency. No prompt translation or cross-backend
behavioral-equivalence promise is introduced.

## Dependency readiness and serial waves

This turn authors ALL plans for this intake: one plan, `p1-dispatch`. The work
shares CLI/runner/applier files, so splitting into implementation workers adds
avoidable overlap. Read-only investigation or independent verification may be
delegated when native scheduling permits; serialize builds sharing a cache.
No independent implementation fanout is planned.

The following external records form a DAG: reservation and sandbox have no
predecessors; lifecycle and capabilities depend on reservation; dispatch
requires reservation, lifecycle, capabilities and execution access. Whole-P1
finalization follows other P1 plans but is NOT a prerequisite of dispatch.
Do not include external records in this run's implementation plan list or
fabricate accepted IDs to make the native scheduler admit this plan.

| External planId / path | Exact interface owner / required evidence | Current readiness |
| --- | --- | --- |
| p1-reservation / `impl-plans/active/work-runtime-p1-reservation.md` | Owner: reservation; `Sources/RielaWork/WorkStore+Reservation.swift`, `WorkStore+Schema.swift`, `WorkModels.swift`. Atomic version/dependency recheck, unique session/lease, token authorization, pending-request and cancellation transaction primitives. Run V2 below. | Unverified checkpoint; accepted predecessor revision **null**; no current behavioral evidence. |
| p1-lifecycle / `impl-plans/active/work-runtime-p1-guard-director.md` | Owner: lifecycle; `WorkGuard.swift`, `DeterministicDirector.swift`, `DecisionApplier.swift`, `CompletionEvaluator.swift`, `WorkDecision.swift`, `WorkEvidence.swift` in Sources/RielaWork. Stable ordering, durable guard batch, replay/completion/causality and last-attempt rules. Shared coordinator/store handoff below; run V3. | Known material gaps (§17.6); accepted predecessor revision **null**. |
| p1-capabilities / `impl-plans/active/work-runtime-p1-capabilities.md` | Owner: capabilities; planned `Sources/RielaCore/WorkflowRequirement*.swift`, `BackendCapability*.swift`, `Sources/RielaWork/BackendCapabilityPlacement*.swift`, `WorkStore+Hosts.swift`, `Sources/RielaCLI/HostCapability*.swift`, adapter probes. Selected-entry resolver, one merged snapshot, read-only mode, deterministic per-node placement and host input contract; run V4. | Interface absent/unproven; accepted predecessor revision **null**. No dispatcher-local substitute. |
| p1-sandbox / `impl-plans/active/work-runtime-p1-sandbox.md` | Owner: sandbox/current runtime; installed package node access and current workflow-owned workspace-write evidence. Record immutable version/digest, actual execution ID and granted write scope. | Installed 0.3.5 manifest inspected; downstream execution access unverified, accepted revision **null**. Canonical node edits excluded. |
| p1-finalize / `impl-plans/active/work-runtime-p1-finalization.md` | Owner: external whole-P1 finalization; archives/indexes other P1 plans only after its own acceptance. | Deferred outside this run; not a dispatch dependency or deliverable. |

Before dependent work, record in the p1-dispatch progress log each accepted
predecessor revision, exact public symbol/signature and file hash, owning
execution/review ID, complete behavioral logs and write ownership transfer.
Absent/failing interfaces block the affected work and remain blocked in handoff;
readiness inspection does not authorize implementation of the dependency.
`TaskGuardCoordinator.swift` and `WorkStore+Decisions.swift` may receive the
narrow §17.2 integration fixes specified below only after the lifecycle and
reservation contracts and single-writer handoff are explicit. Schema/model,
reservation-store or DeterministicDirector changes go back to their dependency
owner; never silently widen this plan. Null revisions must become evidenced
accepted revisions before native implementation admission.

| Wave | Tasks / prerequisites | Deliverable |
| --- | --- | --- |
| 0 | External readiness, Step 5 acceptance, serial plan checkpoint | Accepted design and this plan committed with exact allowlist/hash before implementation; no Step 4 commit. |
| 1 | P1-6a after all external gates; P1-6b and P1-6c after P1-6a, serial | Dispatcher and real-run bridge, read-only dry-run, shared decisions/cancellation and tests. |
| 2 | P1-6d after P1-6a/c; P1-7b after P1-6a/b/c/d | Bounded child and planner inputs; task-backed deterministic examples. |
| 3 | P1-7a after replacement V1 tests pass on waves 1–2 | Remove legacy implementation/flags and obsolete examples; reject removed inputs. |
| 4 | Serial package reconciliation after P1-7a/b | Broader verification, narrow docs/plan/index refresh, single adversarial review and workflow commit/push. |

P1-7b creates replacement bundles before P1-7a deletes old bundles. Deliver CLI
and removal in one publication cut. Historical
`impl-plans/active/work-runtime-p1-20260921-dispatch.json` and the old six-plan
fanout/progress are NOT this run's dispatch input. Leave external plans and
historical manifest intact; runtime dispatch must use only this reviewed plan.
Step 5 must reject an execution manifest that reintroduces their scope.

## Shared directory and edit integrity contract

The JSON lists are ownership scopes. Example directory globs cover only the named
P1 responsibility, not unrelated files matched by a broad suffix. Materialize
exact paths before editing. New helper/test files must stay within the listed
responsibility patterns. Shared paths have one writer per wave; any additional
intersection or missing shared contract is queued for serial integration,
recorded in the owner's log, and assigned before dependent editing resumes.
Do not opportunistically change Package.swift from a parallel branch: the
reservation owner audits retained module/test dependencies; dependency-owned
changes require that owner and explicit handoff, not dispatch-worker edits. Lockfile generation, shared indexes,
global plan archiving, digest refresh and broad formatting are serial-only.
Avoid broad formatting entirely unless required for touched code.

For EVERY edit, including deletion and each retry:

1. Fresh-read the current file and relevant predecessor contract. Record a
   pre-edit SHA-256 (or explicit absent sentinel) and immutable intent snapshot
   under `tmp/work-runtime-p1/<planId>/intents/<sequence>/`. The snapshot records
   accepted requirement, exact paths, expected semantic delta, original bytes
   or content reference, and expected preserved behaviors. Never replace an
   earlier snapshot; store corrections in a new sequence.
2. Recheck the hash immediately before writing. On drift, stop that write,
   reread/rebase the intended patch and capture a new intent; do not overwrite
   from stale buffers. After writing, record post-edit SHA-256, exact diff and
   tests. Hashing cannot prevent a race after the check; native runtime-owned
   change evidence and the post-join semantic review remain mandatory.
3. Each worker updates ONLY its `progressLog`: task status, intent paths,
   changed-file paths/pre/post hashes, predecessor versions, behavior,
   verification command/start/end/final exit/complete log path/test count,
   findings and residual risks. Workers do not edit shared checkboxes, indexes
   or another worker's log. Create the named progress log when work starts.
4. At every join, aggregate native changeTracking evidence plus intent/hash
   records. Compare current hashes and behavior with EVERY accepted branch,
   detecting missing, overwritten and unexplained changes even if compilation
   passes. A later intentional shared-path edit must explicitly preserve the
   predecessor contract and rerun its relevant tests.
5. One serial repair owner restores accepted intent with fresh reads; an
   independent combined-tree reviewer then verifies the repaired tree and its
   evidence. Repeat focused gates for affected code and the final aggregate
   gate. No implementation branch declares the combined tree accepted alone.

Inventory and classify existing dirty/untracked changes before implementation.
`tmp/work-runtime-p1/step4-resume/before-hashes.json` records this planning turn's
baseline; implementation must take a fresh one. Retain correct in-scope work,
repair incorrect work with evidence, and preserve unrelated changes. Never
reset/clean the tree or stage all files. Plans remain unchecked until serial
finalization can cite current behavioral evidence and accepted review.

All scratch scripts, Swift build caches, logs and fixtures live under
`tmp/work-runtime-p1/`. Parallel builds use the plan-specific scratch paths in
commands; any command writing a shared build/cache is serialized. Run shell
commands in the foreground, retain yielded handles and poll through terminal
exit. An incomplete log, timeout, missing suite or unpolled process cannot pass.
Retain referenced evidence through review/handoff; remove only unreferenced
scratch once the task is done.

## Intended changes and acceptance (§17.2–17.5)

- [ ] **P1-6a** Compose TaskDispatcher with canonical stored plan/definition and
  runtime store resolution. Resolve selected entry, dependencies and placement
  before reservation. Missing plan/entry/dependency or invalid policy errors;
  unmet dependencies/capacity records its wait without attempt/session/lease.
  Atomically reserve and authorize, then run EXACT reserved session ID through
  the existing runner. Project terminal evidence before guard/completion and
  apply decisions through the shared applier. Refresh real dispatch placement
  once before reservation and use the chosen per-node backend/host in execution.
- [ ] **P1-6b** Ship task run <task-id> [--dry-run] with attempt/session IDs or
  wait reason. Dry-run follows identical resolution but opens state read-only:
  no create, migration, generation reset, checkpoint, host-cache, task, attempt,
  session, decision, lease or evidence writes. Missing/incompatible stores are
  diagnostics; fresh probes remain in memory. Prove byte AND row equivalence
  including work_hosts, SQLite sidecars and host profile configuration; an
  absent store stays absent and corrupt profile config is not quarantined.
- [ ] **P1-6c** task decide requires exactly one --accept, --reject <reason>,
  --rerun [step], --cancel plus --principal, --expected-version, --decision-id.
  Human principal is audit identity under existing local access, not new remote
  authentication. Validate action combinations and stable replay; call the
  applier, never direct row mutation. Ctrl-C uses this same durable cancellation
  path; terminal acknowledgment precedes fence release. Cover interruption
  during authorization, running, acknowledgment and pending rerun consumption.
  Existing authenticated remote manager paths keep their protections.
- [ ] **P1-6d** Wire one bounded optional agent-director child through ordinary
  workflow execution. Reconcile work attempt before entry: .director reservation;
  retain judged work TaskView, record child session/cost/attempt exactly once.
  Validate allowed P1 decision kinds and apply through the same causal/version/
  completion/budget checks. Invalid/forbidden/failed/budget-blocked output records
  evidence and needs human decision. No recursive director repair, replan,
  proposals or specialist classifier. Finish planner-variable host snapshot
  wiring through dispatcher workflow input variables using capability contracts.
- [ ] **P1-7a** FIRST establish replacement dispatcher behavioral tests for
  auto-improve inactivity, bounded retry, gate/failure recovery, cancellation
  and replay. Record passing exit/log before deleting the old implementation.
  THEN remove WorkflowRunCommand+AutoImprove.swift, WorkflowAutoImprovePolicy,
  WorkflowMutationMode, SupervisedScenarioNodeAdapter, supervision state/result,
  remote input.autoImprove/input.nestedSuperviser and removed flags. Discover
  exact references with rg; changes outside scoped files are serialized and
  assigned to this integration owner before edit. Preserve specialist/event
  supervisor dispatch, existing loop/routine behavior and plain workflow runs.
- [ ] **P1-7b** Replace examples/auto-improve, examples/default-superviser and
  examples/supervised-mock-retry with examples/task-repair-loop and
  examples/task-agent-director, each with mock-scenario.json and
  EXPECTED_RESULTS.md. TaskRuntimeExampleTests must drive real task lifecycle
  using deterministic fixtures: acceptance, gate recovery, guard stop, capacity
  wait; allowed director output, child accounting and invalid-output escalation.
  Workflow-only mock runs supplement these tests; they do not prove dispatch.

Deliverables: dispatcher/CLI composition, bounded director child, both example
bundles, removal of obsolete implementation and equivalent regressions. Keep
CLI addition and auto-improve removal in the same delivery cut; no publication
between them. Test real reserved-session execution, dependency/version races,
guard persistence failure, cancellation acknowledgment loss, replay crashes,
last-attempt completion, dry-run effects, and task-free plain workflow run.

## File-level implementation map and preserved invariants

Every row is limited to the accepted requirement named. New file names below
are intended destinations, not assertions of existing APIs. Fresh-read existing
neighbors and accepted predecessor signatures before implementation; reuse
existing functions and avoid a generic framework. Extra helpers are allowed
only for necessary responsibility splits, with an exact-path serial assignment
and intent record first. The JSON writePaths list never authorizes unrelated
changes to a matched file. Dependency-owned files are read-only here.

| Task / files | Intended change / required evidence |
| --- | --- |
| P1-6a: new `Sources/RielaWork/TaskDispatcher.swift`; new `Sources/RielaCLI/TaskDispatch.swift`; existing `WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift` in Sources/RielaCLI | Work coordinates accepted requirement/placement/reservation/decision contracts; CLI resolves canonical definition/store and bridges to existing runner using the reserved session ID and per-node host/backend. Project terminal evidence before completion/guard evaluation. Reuse runner execution; no RielaCore import of RielaWork. TaskDispatcherTests and TaskDispatcherIntegrationTests prove exact reserved ID, version/dependency races, wait without attempt/session/lease, stale launch rejection and projection-before-decision. |
| P1-6b/c: `Sources/RielaCLI/TaskCommands.swift`, `TaskCommandModels.swift`, `RielaCommand.swift`, `RielaArgumentParser+WorkflowAndMemory.swift`, new `TaskDispatch.swift` | Add run/dry-run/decide parsing, typed result DTOs and text/JSON output. Preserve show/list and store-root precedence. Dry-run must select read-only dependency APIs before any loader that initializes/migrates/quarantines. Decide validates exactly one action, principal, expected version and stable ID. Route Ctrl-C through durable applier/runner cancellation, including pending-launch and acknowledgment windows. No second direct-mutation path. TaskCommandMutationTests and TaskCommandParsingTests assert parsing, replay and filesystem/row invariance. |
| P1-6a/c/d shared serial handoff: `Sources/RielaWork/WorkStore+Decisions.swift`, `TaskGuardCoordinator.swift`; `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`, `WorkGuardDispatcherTests.swift` | After predecessor ownership transfer, validate causal ledger scope/relevance and reconstruct completion in the store transaction. Return original persisted application on identical replay (retain first timestamps); reject changed intent. Atomically enqueue one rerun/recover using dependency transaction primitives. All live stop/reject/cancel/replacement actions retain fence until durable runner acknowledgment. Coordinator persists the full guard batch before any decision and cannot make caller verdict authoritative. If durable outcome storage needs schema/model changes, block and route to owner; do not invent parallel storage. Add negative/rollback/crash/replay tests, not CLI-only checks. |
| P1-6d: new `Sources/RielaWork/AgentDirector.swift`; `TaskDispatcher.swift`, `Sources/RielaCLI/TaskDispatch.swift` | One ordinary child workflow only when configured escalation needs it. Reconcile judged work before .director reservation; retain its TaskView; charge child attempt/session/cost once and use the same applier. Forward the accepted capability snapshot through planner workflow variables; no new planner. TaskDispatcherTests/TaskDispatcherIntegrationTests prove host input and selected backend delivery, last-admitted-attempt completion, invalid/forbidden/failed/budget-blocked child escalation and no recursion. Deterministic ordering itself belongs to p1-lifecycle. |
| P1-7a: `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift` (delete after barrier), `RielaCommand.swift`, `ParsedWorkflowOptions.swift`, `RielaArgumentParser+WorkflowAndMemory.swift`, `WorkflowCommands.swift`, `WorkflowRunCommand.swift`, `ProductionNodeAdapter.swift`, `RielaCLIApplication.swift` | Remove actual policy/mutation types in RielaCommand, flags, option plumbing, execution branch, remote serialization and scenario wrapper. SupervisedScenarioNodeAdapter actually lives in RielaCLIApplication.swift (not an Adapters file). Reject removed autoImprove/nestedSuperviser remote fields rather than ignoring or forwarding them. Keep normal run, mock scenario and authenticated remote paths intact. Rewrite legacy tests as rejection/preservation regressions only after replacement coverage passes. |
| P1-7a conditional retained call sites: `Sources/RielaCLI/SessionCommands.swift`, `SessionCommandModels.swift`, `RielaCommand+SessionParsing.swift`, `LoopCommands.swift`; `Sources/RielaCore/DeterministicWorkflowRunner.swift` | Remove only obsolete supervision plumbing/result fields tied to the deleted workflow path. Preserve loop/routine and specialist/event behavior and their stores; do not delete symbols merely for containing supervisor. Inspect callers/consumers before removal; contradictory retained behavior is a dependency blocker, not permission to redesign another plan. A newly discovered remote decoder outside listed paths requires exact serial ownership assignment before its narrow removed-input rejection edit and tests. |
| P1-7a regressions: `Tests/RielaCLITests/CommandParsingTests.swift`, `WorkflowCommandAutoImproveTests.swift`, `WorkflowCommandInspectionTests.swift`, `WorkflowCommandPackageLifecycleTests.swift`, `RielaExampleParityTests.swift`, `WorkflowRunHelpTests.swift` | Preserve equivalent scenarios in the four new dispatcher suites before deleting old tests. Assert removed flags/remote fields fail, plain runs create no task, help and package examples match; keep specialist supervisor, events, routines and loops green in V5. |
| P1-7b: `examples/task-repair-loop/` and `examples/task-agent-director/` each with `workflow.json`, required referenced `nodes/` and `prompts/`, `mock-scenario.json`, `EXPECTED_RESULTS.md`, `README.md`; `Tests/RielaCLITests/TaskRuntimeExampleTests.swift` | Minimal deterministic bundles; tests create task fixtures through existing store APIs then drive actual task run/decision lifecycle with mock node execution, not merely workflow run or string assertions. Document acceptance, gate recovery, guard stop, capacity wait, bounded child output/accounting/escalation. Remove only the three legacy directories after V1 before-removal passes. No new task-create CLI. |

The four required new suites are exactly
`Tests/RielaWorkTests/TaskDispatcherTests.swift`,
`Tests/RielaCLITests/TaskCommandMutationTests.swift`,
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` and
`Tests/RielaCLITests/TaskRuntimeExampleTests.swift`. Integration tests use
real reservation/store/runner paths and deterministic injected node/probe/clock
boundaries; test doubles must not bypass the contract under test.

Invariant checklist for tests and independent review:

- Reservation atomically binds task version/dependencies, attempt, unique
  session, lease, placement and decision. Token is single-use and digest-only;
  no relaunch on uncertain authorization, lease expiry or heartbeat loss.
- Dry-run changes neither bytes nor rows across main DB, WAL/SHM, work_hosts,
  runtime/host cache and host-profile files; absent stores stay absent; corrupt
  profile input is neither rewritten nor quarantined. Compare inventories and
  content before/after with connections closed; include missing/incompatible state.
- Store causality cannot reference missing, foreign or stale attempt evidence.
  Latest-attempt verification/gates and applicable blocking findings govern
  acceptance; human accept waives only requiresHumanAccept. Identical replay
  returns original outcome even after later task changes; conflicting payload
  or fresh stale-version decisions fail without side effects.
- Guard batch persistence failure prevents all dependent action. Replay does
  not duplicate evidence or cumulative tokens. Gate visits use > limit; other
  used limits use >=; attempt budget limits the next admission and allows the
  last admitted attempt to finish. SDK heartbeat exemptions are preserved.
- Cancellation is durable before runner cancellation; fence release follows
  durable terminal acknowledgment. Test interruption before authorization,
  while running, during acknowledgment and during pending-request consumption.
- Placement consumes the dependency's one fresh merged snapshot. No pin
  fallback, implicit authentication, invented capacity, unreachable-node
  requirement or stale success after failed refresh. Chosen per-node backend/
  host and planner snapshot reach execution; capability validation is not a token.

## Common lint and validation contract

swift build is the Swift compile/typecheck gate. Swift edits follow the local
Swift skill: keep touched code responsibility-based, avoid speculative
abstraction, and split touched non-generated files over 1000 lines by actual
responsibility without unrelated cleanup. Include necessary extracted paths in
serial ownership records. Do not weaken tests or lint to accept retained WIP.

Before edits, each worker captures repository lint baseline. After edits,
materialize exact existing changed/new Swift paths from its intent records in
`tmp/work-runtime-p1/<planId>/changed-swift-files.nul`; do not rely on git diff
alone because it omits untracked files and predecessor commits. Replace the
literal PLAN_ID below with p1-dispatch and record the expanded command.
The expanded mandatory commands are V6/V7 below.

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/PLAN_ID/changed-swift-files.nul
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
```

Skip xargs only for an explicitly empty Swift write set; strict touched-file
lint gates acceptance. Repository-wide output is a recorded baseline check:
fail new diagnostics attributable to this work, report existing unrelated ones,
and do not broaden edits to clear them. If a tool is unavailable, record a
blocked gate and environment error, not success. Run required focused tests,
then the broader V5 gate once on the joined tree; repeat only after
new changes/failures. No web code is planned, so browser E2E is not a P1 gate.

## Completion, documentation and progress

Only P1-6a–d and P1-7a–b may be checked complete by serial reconciliation after
current behavioral evidence, author self-check, test-integrity review, the
workflow's single adversarial implementation review and combined-tree review
leave no unresolved high/mid finding. P0 remains green. Do not archive this
plan on partial delivery or archive/certify the other P1 plans. Whole-P1
completion remains external even when these six tasks pass.

Implementation owner creates `impl-plans/progress/p1-dispatch.md`; each task
entry records status (pending/blocked/implemented/verified/accepted), dependency
revisions, immutable intent paths, exact files/pre/post hashes, commands,
complete log paths, exit statuses, positive test counts, findings and remaining
risks. Only that worker edits its progress log. Do not create a progress log
with fictional implementation in Step 4. Current planning evidence lives in
`tmp/work-runtime-p1/step4-resume/` and is retained through review/handoff.

After joining, one serial owner reconciles README task/removed-flag guidance,
actual CLI help, `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift` and existing
supervision exclusions in `SurfaceCatalog+Rows.swift` / `SurfaceCatalog+RowSupport.swift`
only where changed behavior requires it. Keep GraphQL/UI counterparts explicitly
deferred. Verify with WorkflowRunHelpTests and SurfaceCatalogTests. Update only
this plan and its existing `impl-plans/README.md` row from verified evidence;
list deferred dependency status and do not absorb external finalization work.
Review the repository workflow skill and user-facing guidance for direct
impact; any necessary skill edit requires a fresh exact-path assignment and
owning manifest audit before writing. No blanket skill rewrite is authorized.

Run `rg --files --hidden -g riela-package.json -g '!tmp/**' -g '!.git/**'`
before workflow/prompt/script/skill edits. No repository manifest was found by
the design audit; refresh a discovered owning manifest's digests using its
existing tooling in serial reconciliation, or record no applicable manifest.
Do not invent a manifest or mutate the installed immutable package. Lockfile
generation, indexes, digest updates and any archiving are serial-only; no
lockfile or broad formatting change is planned.

The current workflow handles authorized commit/push after acceptance with an
exact P1 allowlist, excluding scratch and unrelated changes. Record commit
hash, pushed hash and upstream verification. Preserve pre-existing accepted
design edits. Step 4 supplies a plan, not implementation or publication proof.

## Verification contract

All commands run in the foreground from repository root. Create
`tmp/work-runtime-p1/p1-dispatch/` first. Capture full stdout/stderr, command,
start/end, final exit status, and positive executed test count in
`verification-evidence.json` there and in the progress log. Poll yielded handles
through terminal exit. Timeouts, incomplete logs, absent suites and zero tests
are failures/blocked checks, never passes. Log basenames below are mandatory;
use immutable numbered attempt subdirectories on retries and distinct
`before-removal/` and `after-removal/` directories for V1. Build caches remain
`tmp/work-runtime-p1/build/p1-dispatch`. Never use shell orphaning or detached
processes. No implementation commands below have run during Step 4.

### Commands and evidence

**V0 compile/typecheck**, log `build.log`:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
```

**V1 required focused behavior**, log `focused-tests.log`. Run once before any
legacy deletion and again on the final removal tree. All four named suites
must exist and execute positive counts; an aggregate count alone cannot hide
an absent suite. It establishes every P1-6/7 acceptance row above, including
real task-backed examples and dry-run file/row comparisons.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
```

**V2 reservation readiness/regression**, log `reservation-tests.log`. Require
atomic rollback, duplicate IDs, concurrent independent connections, stale
version/dependency, token replay, uncertainty fence, pending request consumption
and durable cancellation tests from the accepted owner revision.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter WorkStoreReservationTests
```

**V3 lifecycle readiness and shared-applier regression**, log
`lifecycle-tests.log`. Require positive counts for each suite and behavioral
proof of the shared file map and invariant checklist, stable simultaneous
violation ordering, gate recovery budget and latest-attempt completion.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|CompletionEvaluatorTests'
```

**V4 capability readiness**, log `capability-tests.log`. These suites/interfaces
are owned by the external capability plan, not new deliverables here. Require
selected-entry/called-workflow resolution, deterministic placement, finite
freshness and failed-refresh handling, host declarations, read-only profile
loading, probe redaction and planner snapshot contract; every suite must run.
Absent suites make readiness blocked even if the test command exits 0.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
```

**V5 joined-tree regression**, logs `work-cli-core-tests.log` and
`adapter-server-graphql-tests.log`. Work/CLI/Core are mandatory for the planned
shared changes, retaining P0 read/projection/store, plain runner, parser/help,
loop/routine/specialist/events, surface catalog and remote forwarding behavior.
Run the second command when adapter/Core execution or remote handling is
changed (expected for P1-7a); record exact applicability if skipped. Do not
weaken unrelated failing tests: classify baseline versus caused failures and
report blocked verification explicitly.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests'
```

**V6 strict touched-file lint**, log `swiftlint-changed.log`. The NUL manifest
contains all surviving new/modified Swift paths from intent/change evidence,
including untracked files, with no deleted paths. Require no strict diagnostics.

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-dispatch/changed-swift-files.nul
```

**V7 repository lint baseline/comparison**, logs `swiftlint-baseline.log` before
edits and `swiftlint-repository.log` after. Record each exit and compare full
diagnostics; do not fix unrelated baseline issues or call unavailable lint a pass.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
```

**V8 bundle validation/supplemental workflow mocks**, logs respectively
`repair-validate.log`, `repair-mock.log`, `director-validate.log`,
`director-mock.log`. All four exit 0; compare results with each bundle's
EXPECTED_RESULTS.md. These checks do not replace V1's actual task lifecycle.
Only run on the newly built executable after V0. No real credentials required.

```bash
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-repair-loop --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/examples/task-repair-loop --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/examples/task-agent-director --output json
```

**V9 removal inventory and diff**, logs `legacy-reference-audit.log`,
`git-diff-check.log`, `git-diff-cached-check.log`. For rg, exit 1 means no
matches, 0 requires classification of every retained match (rejection tests,
historical docs or unrelated specialist/event behavior), and >1 is an error.
Never delete all supervisor-name matches. Diff checks require exit 0; cached
check runs at the serial plan/final commit gate after the exact allowlist is staged.

```bash
rg -n 'autoImprove|nestedSuperviser|WorkflowAutoImprovePolicy|WorkflowMutationMode|SupervisedScenarioNodeAdapter|--auto-improve|--nested-superviser' Sources Tests README.md examples
git diff --check
git diff --cached --check
```

### Step 4 author check and remaining blockers

Author validation checks the six-task mapping to accepted §17.1–17.6, DAG,
explicit ownership/files/invariants/acceptance/commands, scope and proportion,
progress and edit-integrity requirements, and preservation of external plans
and accepted design. Its script/output and command evidence are under
`tmp/work-runtime-p1/step4-resume/`. Source inspection does not certify the
implementation. Step 5 plan acceptance is still pending. V0–V9 are future
implementation gates; reservation/lifecycle/capability behavioral readiness
and downstream execution-access evidence remain unresolved blockers. Report
these even if author plan-structure checks pass. There is no unresolved user
product decision and no hidden waiver or fallback for a missing dependency.
