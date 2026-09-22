# Work Runtime P1: Dispatcher integration and plan contract

**Status**: Step 4 revised; Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete the Work Runtime P1 dependency DAG (number/url: null)
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.6 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review-attempt-1-exec-4`, `accepted_for_step4_implementation_planning`; findings/feedback empty; no Step 5 feedback supplied.
**Codex-agent references**: `workflowExecutionId:codex-design-and-implement-review-loop-session-1`, `communicationId:comm-000003`, `communicationId:comm-000004`, `sourceStepExecutionId:step2-design-doc-update-attempt-1-exec-3`, `stepId:step3-design-review`, `stepId:step4-impl-plan-create`, `designAuthorModel:gpt-6-astra`, `planAuthorModel:gpt-6-astra`, `gateModel:gpt-5.6-sol`, `implementationModel:gpt-5.6-terra`; downstream executions record actual IDs.
**Updated**: 2026-09-22

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [
    "p1-sandbox",
    "p1-reservation",
    "p1-lifecycle",
    "p1-capabilities"
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
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Tests/RielaCLITests/WorkflowCommandInspectionTests.swift",
    "Tests/RielaCLITests/WorkflowRunHelpTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaWorkTests/WorkGuardDispatcherTests.swift",
    "examples/task-agent-director/**",
    "examples/task-repair-loop/**"
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
  "dependencyMode": "native-accepted-predecessor-DAG",
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
  },
  "evidenceDirectory": "tmp/work-runtime-p1/p1-dispatch/"
}
```


## Authority, intent and context

Complete the full P1-0 through P1-8 dependency DAG from checkpoint
`bf39f3749894f4a01bf456c6d5178e377d5dd140` on `feat/remaining-impl-plans` in
`/Users/taco/gits/tacogips/riela-worktrees/remaining-impl-plans`.
This plan owns P1-6/7 and supplies the common execution contract for all six
plans. The accepted design §17.1–17.6 overrides older broad phase descriptions.
Step 3 accepted it in `comm-000004`, `step3-design-review-attempt-1-exec-4`,
`codex-design-and-implement-review-loop-session-1`, with no findings.
No Step 5 feedback was supplied; Step 5 acceptance remains pending.

Current inspection confirms HEAD equals the checkpoint. Task CLI only exposes
show/list; dispatcher/director orchestration, capability placement, mutation
suites and replacement examples remain absent. Retained sandbox/reservation
code needs current behavioral certification. Decision storage trusts caller
completion, lacks scoped causality/original replay, and only defers cancel;
director ordering and gate-recovery budget checks need repair by p1-lifecycle.
See `tmp/work-runtime-p1/step4-plan/inspection-evidence.json`; inspection is
not passing implementation evidence. Preserve correct retained work and all
unrelated state, other sessions and Monja tenant-sharding-d48 work.

Continue the Riela-owned immutable user-scope package at
`/Users/taco/.riela/packages/codex-design-and-implement-review-loop/`, version
0.3.6, manifest-declared integrity digest
`45efc8840875e19b5e69151a3c9b99e5cbc0c8352b5b90c813de8d372227be14`.
Manifest inspection is not a recomputed integrity check. Do not modify the
installation or start another workflow. Project canonical payload validation
is artifact validation only. No worktrees, private branches or concurrent Git
mutations. Astra authors all plans and performs final combined-tree review;
Terra implements/reconciles; Sol gates readiness and owns the single material
adversarial review. Implementation/test nodes maximize independent delegated
investigation and verification with one writer per overlapping file; this
planning node has one author and no authoring fanout.

Non-goals: P2–P7; loop-engineering, agent-node-output-contract, workflow-defect
detection, Tauri and note plans; task serve, new remote authentication, new
planner, duplicate capability registry, auto-improve state migration or
compatibility, recursive director repair, proposals, specialist classification,
broad cleanup/formatting, speculative flexibility and optional hardening.
Plain workflow run stays task-free; loop/routine/specialist/event behavior and
stores remain. No external Codex-reference source was supplied; the accepted
design records ../../codex-agent absent. Agent references are provenance, not
parity claims. Cursor invocation/auth/probes/heartbeat remain adapter-owned;
no prompt translation or cross-backend equivalence promise is introduced.

## Dependency readiness and serial waves

All six plans are native implementation inputs; no predecessor is external.
Use each JSON planId/planPath/dependsOn unchanged. Historical dispatch JSON
files are evidence of earlier runs, not this run's scheduler input; preserve
those files and let the installed runtime materialize this accepted DAG.

| Wave | Plan ID | Accepted predecessors | Ownership / handoff |
| --- | --- | --- | --- |
| 1 | p1-sandbox | none | P1-0 canonical node payloads and real-payload regression |
| 1 | p1-reservation | none | P1-1 models/schema/SQLite atomic primitives; initial Package.swift ownership |
| 2 | p1-lifecycle | p1-reservation | P1-2/3 guard, policy and store-authoritative decisions; no schema/model writes |
| 2 | p1-capabilities | p1-reservation | P1-4/5 neutral values, adapter probes, schema/host placement and host authoring |
| 3 | p1-dispatch | p1-sandbox, p1-reservation, p1-lifecycle, p1-capabilities | P1-6/7 runner/CLI integration and replacement before removal |
| 4 | p1-finalize | all five implementation plans | P1-8 serial join/repair, aggregate evidence, docs/digest/index reconciliation |

After Step 5 accepts, the workflow's serial checkpoint gate commits the
accepted design and all six plans with an exact allowlist before native fanout.
Step 4 does not commit pending plans. Initially accepted implementation IDs
are empty: only sandbox and reservation are eligible after that checkpoint.
Every dependency admission requires accepted source revision/content hashes,
exact interface signatures/owner, behavioral command logs with final exit 0
and positive per-suite counts, and integration review with no unresolved
high/mid finding. Sol readiness gates are not extra adversarial reviews.
Missing evidence blocks affected descendants while independent roots continue.
Do not substitute source inspection or invented accepted IDs for readiness.

Lifecycle and capabilities fresh-read the reservation handoff. Lifecycle must
not edit WorkModels, WorkStore.swift, WorkStore+Schema.swift or Package.swift
while capabilities owns its wave. Missing primitives return to reservation's
designated owner for serial repair, invalidate affected acceptance, and require
new tests/review before admission resumes. Dispatcher consumes accepted
causality/completion/replay/cancellation and capability contracts; it must not
duplicate those repairs or bypass them in CLI code. Narrow coordinator/decision
integration changes require explicit ownership transfer and regression evidence.

Within dispatch serialize P1-6a, then P1-6b/c, then P1-6d, then P1-7b.
P1-7a deletion follows passing replacement tests for inactivity, bounded retry,
gate/failure recovery, cancellation and replay. Re-run those tests after removal.
CLI addition and legacy removal ship in the same publication cut. p1-finalize
then owns serial shared-file repair and final aggregate verification.

An unchanged or materially unverified implementation returns actionable
blockers once (missing contract, owner, needed command/access repair, final
exit/log), and cannot enter integrity/adversarial/reconciliation repetition.
Retained correct code can be certified only with fresh behavioral evidence and
independent acceptance; never invent a code edit to satisfy a change-count gate.
If the immutable runtime cannot admit that evidence, report its concrete gate
blocker without editing the workflow or mislabeling unchanged code as passing.

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
`tmp/work-runtime-p1/step4-plan/before-hashes.json` records this planning turn's
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
| P1-6a/c/d shared serial handoff: `Sources/RielaWork/WorkStore+Decisions.swift`, `TaskGuardCoordinator.swift`; `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`, `WorkGuardDispatcherTests.swift` | Consume and regression-test the accepted lifecycle implementation of scoped causality, reconstructed completion, original replay, atomic pending requests and live cancellation fencing. Only add narrowly necessary real-runner coordination after ownership transfer; do not defer lifecycle acceptance repairs to this plan. Coordinator must preserve complete guard-batch persistence before decisions. If durable outcome storage needs schema/model changes, block and route to owner; do not invent parallel storage. Add negative/rollback/crash/replay tests, not CLI-only checks. |
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
literal PLAN_ID below with the current planId and record the expanded command.
Every plan metadata block also contains its exact expanded lint commands.

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

Each worker appends only to its plan-owned progressLog. Preserve historical
entries and distinguish this session's pending/blocked/implemented/verified/
accepted states. Record dependencies, execution/review IDs, interface signatures,
immutable intent paths, exact pre/post hashes, commands/start/end/final exits,
complete logs and positive per-suite counts, findings and residual risks.
No Step 4 progress log asserts implementation completion.

All P1-0…P1-8 checkboxes remain unchecked until current behavioral evidence,
self-review, Sol test-integrity and its single material adversarial review,
and Astra combined-tree review leave no high/mid finding. p1-finalize and the
later serial documentation owner reconcile all six plans, README, PROGRESS.json
and P1 progress indexes from that accepted tree. Preserve non-P1 entries and
other workers' append-only logs. Keep canonical plan IDs/paths through execution;
archive only after acceptance with identity/source-path mappings preserved.

The finalization plan owns help/SurfaceCatalog/authoring guidance and package
ownership audit. Refresh only applicable manifest digests, never invent a
manifest or mutate the immutable installation. Lockfiles, shared indexes and
archiving stay serial. The authorized final workflow commit/push includes only
accepted P1 implementation and narrowly required documentation/index updates;
no scratch, unrelated changes or base integration. Follow the first-push
readiness and remote-hash checks in p1-finalize. Planning is not publication.

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
are owned by the accepted p1-capabilities predecessor, not duplicate deliverables here. Require
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

### Step 4 author check and remaining gates

Planning evidence and the author self-check are under
`tmp/work-runtime-p1/step4-plan/`. They verify six-plan coverage, DAG/ownership,
accepted-design mapping, explicit invariants/acceptance/commands, proportion,
progress and edit-integrity requirements. Step 5 acceptance and all actual
implementation gates remain downstream. V0–V9 have not run in Step 4.
Reservation/lifecycle/capability behavioral acceptance is required before
p1-dispatch admission. No unresolved user product decision or design defect
is known; any actual implementation/access/publication blocker must be reported.

## Evidence-producing command contract

Run each metadata verificationCommands entry in the foreground from repository
root, one command per immutable log under the evidenceDirectory above; retain
handles and poll through exit. Build establishes compile/typecheck. Focused
filters must exercise every named suite with positive executed counts and the
acceptance cases in this plan; missing/zero-test suites, timeout or incomplete
logs block acceptance. Diff checks establish patch hygiene, not behavior.
Strict lint uses the NUL manifest of surviving touched AND new Swift files from
intent/change evidence. Capture repository lint before edits and after the final
plan tree; compare diagnostics and fail new attributable issues while recording
unrelated baseline findings. Do not run xargs on an empty manifest; record why
no Swift file changed. Finalization lints the union of all accepted write sets.

Record exact command, start/end, finalExitStatus, completeLogPath, per-suite
testCount (null for non-tests), source hashes and review decision in
`verification-evidence.json` in this plan's evidenceDirectory and its progressLog.
Use numbered attempt subdirectories for reruns; retain logs through handoff.
All common per-edit fresh-read/pre/post SHA-256, immutable intent, drift-stop,
join/changeTracking and serial repair rules in the dispatcher contract apply.
Only this plan's implementation owner appends to its progressLog; it may not
mark another plan or shared index complete. Documentation refresh and final
checkbox/index reconciliation belong to p1-finalize after independent acceptance.

## Stable verification input and shared-file handoffs

Before either root edits source, the serial preflight owner captures the shared
repository lint baseline. Workers may reference that complete log/hash rather
than racing baseline capture against another writer. Plan-local post-edit lint
is compared to that baseline; finalization compares the entire joined tree.
Separate scratch builds isolate build outputs, not source. Record source hashes
before/after each verification command; if another writer changes relevant
inputs during a run, that run cannot certify the resulting tree. Serialize
verification on stable wave boundaries and re-run affected gates after join.

The planned root and wave-2 write sets are disjoint. Later sharedPaths must
include every transferred file, including tests/help/parser files. Before a
new helper, remote decoder, digest manifest or repair path is edited, record its
exact path/accepted requirement and serial owner. Revalidate overlapping
predecessor behavior; do not silently widen parallel ownership.
