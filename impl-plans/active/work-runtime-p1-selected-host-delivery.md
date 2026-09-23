# Work Runtime P1-6a: selected-host and called-workflow delivery

Status: authored for independent plan review; implementation not started.
Workflow mode: planning-only for this run; later implementation requires a separate issue-resolution run.
Issue: local-request: Work Runtime P1-6a selected-host and called-workflow delivery; no GitHub issue supplied.
Codex-agent references: none supplied; no Cursor adapter mapping or divergence applies.

## Intent and authority

Complete one missing execution slice: task admission selects a host/backend/model and the actual root/callee node executes that choice through the retained worker path. A placement DTO or successful compile does not prove delivery. Source baseline is `fbd4412199068a63ad3977e600696dc725dd6f18`, an incomplete WIP checkpoint. Intake reports 26/26 focused and 156/156 prerequisite tests; those counts are historical, not this plan's verification.

Authority is [accepted design](../../design-docs/specs/design-work-runtime-consolidation.md) §17.2, §17.4 and §17.7, accepted for this planning handoff by Step 3 communication `comm-000004`, and [parent P1 plan](work-runtime-p1-dispatcher-guard-director.md), especially its P1-6a delivery section and V0–V7/V11 gates. Preserve both documents and all unchecked parent criteria. This plan neither supersedes nor narrows their final acceptance.

Only this new document is authorized for the current planning commit. No Swift, fixtures, package source, dispatch records or accepted design edits occur in this run. Runner-supplied provenance is authoritative; do not rediscover the executing workflow's package or registry. Commit accepted planning bytes before any subsequent native implementation/review dispatch; do not dispatch implementation here.

## Contract and ownership manifest

```json
{
  "planId": "work-runtime-p1-selected-host-delivery",
  "planPath": "impl-plans/active/work-runtime-p1-selected-host-delivery.md",
  "dependsOn": [],
  "execution": "single serial implementation owner; independent review after verification",
  "planningCommitAllowlist": ["impl-plans/active/work-runtime-p1-selected-host-delivery.md"],
  "writePaths": [
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/HostCapabilityResolver.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift",
    "Sources/RielaCLI/WorkflowCalleeResolution.swift",
    "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
    "Sources/RielaCLI/DistributedWorkerCommand.swift",
    "Sources/RielaCore/WorkflowRequirements.swift",
    "Sources/RielaServer/DistributedControllerHost.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/WorkflowHostCapabilityTests.swift",
    "Tests/RielaCLITests/DistributedWorkerConfigurationTests.swift",
    "Tests/RielaCLITests/DistributedNodeExecutionTests.swift",
    "Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift",
    "Tests/RielaCoreTests/DistributedJobControllerTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Tests/RielaWorkTests/TaskDispatcherTests.swift",
    "impl-plans/active/work-runtime-p1-selected-host-delivery.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift",
    "Sources/RielaCLI/WorkflowCalleeResolution.swift",
    "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
    "Sources/RielaCore/WorkflowRequirements.swift",
    "Sources/RielaServer/DistributedControllerHost.swift"
  ],
  "tasks": [
    {"id":"SHD-1","dependsOn":[],"deliverable":"baseline and immutable edit intents"},
    {"id":"SHD-2","dependsOn":["SHD-1"],"deliverable":"one topology evaluation and complete admission evidence"},
    {"id":"SHD-3","dependsOn":["SHD-2"],"deliverable":"root and callee selected placement execution"},
    {"id":"SHD-4","dependsOn":["SHD-3"],"deliverable":"deterministic task-to-worker handoff and failure tests"},
    {"id":"SHD-5","dependsOn":["SHD-4"],"deliverable":"joined verification, independent review and exact commit evidence"}
  ]
}
```

The empty plan-level dependency list means there is no new separately scheduled plan prerequisite; SHD-1 must validate retained prerequisite behavior. All tasks are serial because composition, admission and test fixtures overlap. No parallel implementation tasks, private branches, worktrees or concurrent Git operations. One owner controls all listed source/test edits. The author/reviewer roles remain independent.

## Non-goals and stopping rules

Do not implement P1-6c live decision/cancellation integration, P1-6d director execution, P1-7b examples, P1-7a legacy removal, or final P1 certification. Their order remains 6c → 6d → 7b → 7a → final acceptance. Preserve existing cancellation behavior and test its worker loss boundary; do not claim new task cancellation acknowledgment coverage. Do not remove auto-improve or repair unrelated broad-test failures.

No second dispatcher, capability registry, runner, transport, store, scheduler, package resolver or planner. No schema migration, new CLI command, broad formatting, generic abstraction, speculative hardening or performance cleanup. Do not modify other worktrees or Monja. Use the existing capability context for existing planner variables; do not create a planner or run a director child here.

If a required repair exceeds the explicit file map, record the failing test, exact additional path and smallest necessary change for serial review before editing it. Do not silently expand scope. Source drift is a reconciliation event, not permission to overwrite another owner's changes. Material design contradictions must be returned for review; cosmetic preferences are not blockers.

## Current source and precise intended changes

| File / retained seam | Required change or preservation |
| --- | --- |
| `Sources/RielaCLI/TaskDispatch.swift` | Replace `host: "local"` plus `workers: []` with one local/registered-worker evaluation tied to the located task's store and configured controller. Build assignments from reachable steps' existing `placement.target`, keyed by full workflow/step/node provenance. Resolve actual pending entry and reuse information before requirements. Persist full placement choices and snapshot provenance in existing admission evidence, not only the current host-ID array. Pass the same choices to execution; keep reservation and terminal reconciliation ordering. |
| `Sources/RielaCLI/HostCapabilityResolver.swift` | Add a task-facing topology operation to the existing resolver/protocol, with the located WorkStore root explicit. Read existing snapshots, intersect workers with configured controller IDs/groups, preserve registration liveness/capacity and capability freshness, and merge one fresh local probe. Do not invoke repeated per-worker probes, create stores during dry-run, or trust arbitrary snapshots from a different profile/store. Existing local/exact/group callers retain their semantics. Inject clock/snapshots through this seam for deterministic tests. |
| `Sources/RielaCLI/WorkflowValidateInspectCommands.swift` | Retain `reachableWorkflowMaps`, its package/add-on/environment projection and callee resolver. Extend only selected-entry/reused-prefix plumbing and expose the reachable bundles/steps needed by task composition. Do not duplicate traversal in TaskDispatch. Unknown executable targets must be errors before reservation. |
| `Sources/RielaCore/WorkflowRequirements.swift` | Keep requirement/provenance types and traversal of calls, return/resume edges and joins. Preserve cycle visitation and qualified reused-prefix keys. Ensure executable steps with explicit placement but no backend requirement still participate in host selection; do not let command/add-on nodes bypass assignments. Repair only demonstrated gaps, with tests. |
| `Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift` | Replace blanket remote/callee rejection with placement application scoped to a resolved workflow and exact step. Validate every selected choice is consumed exactly once at its provenance. Pin remote targets to selected worker IDs; preserve authored workspace/exports/group constraints. Apply backend/model to execution payloads without losing different choices for steps reusing a node ID. If needed, create deterministic execution-only payload aliases and rewrite those step node references in the in-memory bundle; never mutate registered bundles. Keep the root session guard and `makeTaskAdmission` ordinary process admission for every session, task token only for the exact reserved root. |
| `Sources/RielaCLI/WorkflowCalleeResolution.swift` | Extend the existing resolver with optional task execution context/pre-resolved bundles. Apply callee-specific choices during actual callee resolution; preserve normal resolution when no task context exists. Reuse admitted definitions so a later resolution cannot silently execute different bytes. Missing/mismatched choices fail closed. Child sessions retain ordinary admission and linkage; they do not create new task attempts or consume the root launch token. |
| `Sources/RielaCLI/WorkflowRunCommand.swift` | Thread admitted bundle/placement/context through existing preparation and runner construction. Preserve exact reserved root session and existing persistence callbacks. Apply selected overrides after effective-instance patches so patches cannot silently replace the admitted backend/model. Use existing configured distributed executor. No second top-level remote workflow session. |
| `Sources/RielaCLI/WorkflowRunCommand+KaibaPreflight.swift` | Its prepared result currently fixes the callee resolver and applies effective-instance patches. Thread the optional task context through this existing preparation boundary, preserving ordinary Kaiba/instance preflight and non-task behavior. Use the same placed callee resolver for preflight and execution. |
| `Sources/RielaCLI/DistributedWorkerCommand.swift` | Retain `configuredDistributedExecutor` and worker configuration/environment logic. Expose already loaded controller topology/default workspace to task composition without starting a second controller. Keep authentication and workspace allowlists unchanged. |
| `Sources/RielaServer/DistributedControllerHost.swift` | The existing controller config has no workspace default. Add optional `defaultWorkspace` to this configuration, validate a nonempty bounded alias when supplied, and preserve decoding old configs. Authored step placement workspace wins. For automatically selected remote execution without an authored workspace, require this explicit default before reserve; missing mapping is a configuration error, never a guessed filesystem path or local fallback. Existing worker workspace dictionaries remain authoritative and reject unmapped aliases. No new mapping registry. |
| `Sources/RielaWork/TaskDispatcher.swift`, `Sources/RielaWork/BackendCapabilityPlacement.swift` | Retain as read-only production seams unless a demonstrated regression requires separately reviewed ownership extension. Existing preview/reservation and placement APIs already support the required choices, assignment and evidence inputs. Do not replace them. |
| `Sources/RielaCore/DistributedNodeExecution.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Distributed.swift`, `Sources/RielaCore/DistributedJobController.swift` | Reuse queued handoff, exact worker target, existing attach/lease/result/lost behavior and runner result projection. Existing loss is non-retryable; no fallback/requeue is authorized. Read and test these paths; no production edits expected. |
| `Sources/RielaServer/DistributedWorkerProtocol.swift`, `Sources/RielaServer/DistributedWorkerHTTPClient.swift`, `Sources/RielaServer/DistributedWorkerHTTPRouter.swift`, `Sources/RielaServer/DistributedWorkerLoop.swift`, `Sources/RielaCore/DistributedWorkerNodeExecutor.swift` | Reuse registration, authenticated claim/renew/complete, workspace execution and owned shutdown. No transport rewrite or capability protocol redesign. Changes here require a concrete failing handoff test and serial ownership extension. |

Workspace configuration is the one bounded addition necessary because a capability choice contains a host but the retained executor requires a workspace alias. Tests must cover old config decoding, explicit placement precedence, configured default delivery, and missing-default failure before admission. This does not advertise per-workspace capabilities or weaken worker validation.

## Invariants

1. Resolve canonical task plan and actual start/resume/rerun/recovery entry. Requirements exclude reused executable prefixes/unreachable nodes but retain reachable return/join successors and callee-only requirements. Missing target is an error, not capacity wait.
2. One merged evaluation supplies preview, reservation evidence and execution. Preserve capability source/time/fresh/verified fields and full provenance. Pins do not fall back; explicit worker/group restrictions are mandatory. Deterministic ordering remains local first only when unassigned, then eligible workers by ID.
3. Dependency/capacity waits and dry-run create no attempt, runtime session, lease, controller job, evidence row or persistent host refresh. Version/dependency changes between preview and reservation are rechecked atomically by the retained store.
4. Validate execution configuration and placement applicability before reserve. Successful reserve binds one root session and single-use launch token. Callee session IDs remain separate ordinary runner identities linked to the root, not replacement roots or independent task attempts.
5. Exact selected backend/model reaches the worker adapter input for each workflow/step/node. Neither instance patches nor shared node IDs can erase it. Preserve sandbox, authentication, environment allowlists, export policy and process admission.
6. A remote selection stays remote and pinned to the chosen worker, even when originally selected by group. Worker loss after admission, authorization uncertainty or lease expiry never authorizes another local/remote copy. Preserve durable uncertainty and existing terminal certainty rules; do not release a task fence on heartbeat loss alone.
7. Durable runtime terminal evidence is projected and stored before attempt reconciliation, completion verdict and guard decisions. Root/callee outputs must be visible through the existing session persistence path, not a new store.
8. Plain workflow runs without task context retain existing placement, preflight and admission behavior. All worker fixtures stop and are awaited on success and failure.

## Tasks, deliverables and progress

- **SHD-1 / baseline:** Fresh-read this plan, authority docs and all owned files. Record HEAD, clean/dirty inventory, source hashes and V0/V2/V3/V4 baseline outcomes. Inspect existing controller/workspace configuration and retained worker tests. Capture an immutable intent JSON per task under `tmp/work-runtime-p1-selected-host-delivery/intents/` listing exact paths, pre-hashes, intended changes and acceptance rows. Do not edit until that snapshot is saved.
- **SHD-2 / admission composition:** Implement reachable requirement/assignment composition, one topology evaluation, explicit workspace selection and full admission evidence through the listed seams. Add requirement/topology/config tests alongside changes. Deliver preview/wait behavior with zero durable allocations and no credential values in evidence.
- **SHD-3 / execution delivery:** Thread frozen execution context through root and callees, preparation, placement application and existing distributed executor. Verify effective-instance override ordering, exact root identity and ordinary callee admission. Keep retained terminal reconciliation. No human decision/director expansion.
- **SHD-4 / evidence:** Extend the test owners below with actual task-dispatch-to-worker execution. The fixture adapter may be deterministic, but the task dispatcher, admission/store, queued controller, authenticated transport, worker executor and completion projection under test must be real. Add failure/race cases and ensure owned shutdown.
- **SHD-5 / serial acceptance:** Fresh-read all changed files, compare post-hashes and joined diff against intents, repair integration conflicts serially, run required gates, obtain independent review, resolve all high/mid findings, and record reviewed commit bytes. Update only this plan's progress/acceptance evidence. No parent checkbox changes. Commit only accepted exact files; no main merge.

Before each edit, reread the current file and compare its SHA-256 with the latest recorded post-hash (or baseline pre-hash). On mismatch, stop that edit, inspect the intervening diff and rewrite the intent from current bytes; never restore a stale buffer. Save post-hash and actual diff after each edit. Shared indexes, lockfile generation, global formatting and plan archiving belong only to serial finalization and are not needed by this slice. Each owner writes only its own progress log; for this single implementation owner use `tmp/work-runtime-p1-selected-host-delivery/progress.md`. Record task ID, changed paths, pre/post hashes, commands, exit status, full log paths, positive test counts, blockers and review decision. Final accepted evidence is summarized in this plan before scratch cleanup.

## Deterministic test ownership and required assertions

All new workflow/payload/controller fixtures are built by the listed test files beneath repository-root `tmp/work-runtime-p1-selected-host-delivery/tests/<case>/`; use isolated per-test directories and teardown. No checked-in package or example fixtures are edited. Reuse the owned HTTP worker pattern in `Tests/RielaCLITests/DistributedNodeExecutionTests.swift`; no detached shell process, external service, production credentials or real model API is needed. Use barriers/actor continuations and injected clocks for races; no arbitrary sleeps as correctness assertions.

| ID | Test owner | Required observation |
| --- | --- | --- |
| T1 | `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` | Start via TaskDispatch with a local backend mismatch and a capable registered worker. Real controller claim → worker executor with deterministic recording adapter → authenticated completion → durable root snapshot. Assert worker ID, backend, model, root reserved session ID, one task attempt, placement evidence provenance and zero local adapter invocations. Use configured default workspace for an unassigned remote choice. |
| T2 | Same file | Root invokes a callee with a capability only available remotely, returns and joins. Assert callee-selected backend/model/worker reached the executor, child linked to root, root token consumed once, ordinary process admission applied to both, and terminal outputs projected before guard/completion. Do not substitute a direct runner-only call for this test. |
| T3 | `Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift`, `Tests/RielaCLITests/WorkflowHostCapabilityTests.swift` | Callee-only environment/add-on requirements, cycles, return/join traversal, unreachable node exclusion, qualified reused prefixes, missing callee/step/node before reservation, and explicit placement on a command without a backend policy. |
| T4 | `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` | Two workers with distinct recording adapters: explicit worker, explicit group and incompatible local capability. Selection stays within assignment, group resolves deterministically and execution is pinned to that chosen ID. Same node ID used by two steps with different placements does not overwrite either choice; repeat IDs across root/callee stay isolated. Instance patch cannot restore a different backend/model. |
| T5 | Same file and `Tests/RielaWorkTests/TaskDispatcherTests.swift` | Dependency wait, no live worker, capacity zero, stale worker capability, dry-run and missing default-workspace error. Compare store/session/controller rows and relevant file bytes before/after; no new attempt/session/lease/job/evidence. Barrier-controlled dependency/version change before reserve denies launch. |
| T6 | Same file and `Tests/RielaCoreTests/DistributedJobControllerTests.swift` | Lose chosen worker after claim/authorization with deterministic lease clock. Observe no second job/attempt or local/other-worker invocation; retry cannot bypass uncertain-launch fence. Preserve existing durable lost/terminal semantics, rather than manufacture success or release on heartbeat loss. |
| T7 | `Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`, `Tests/RielaCLITests/DistributedNodeExecutionTests.swift` | Preserve authenticated identity, workspace mapping, claim/complete/replay rules, worker loss and existing cancellation behavior. Tests prove worker execution, not just manual result DTO submission. Do not claim task-level live cancellation acknowledgment (P1-6c). |
| T8 | `Tests/RielaCLITests/DistributedWorkerConfigurationTests.swift` | Old controller JSON decodes unchanged; optional default validates; authored workspace wins; missing default fails before reservation; configured alias reaches worker workspace. |

Each named case must have an explicit test name and positive execution count in final evidence. Additional tests are justified only by a concrete invariant above. If a shared test file exceeds repository Swift size limits, extract only these new fixture helpers into a narrowly named sibling test file after recording its exact path in the serial ownership intent; do not refactor unrelated tests.

## Verification commands and evidence

Run from repository root, foreground only. Save complete stdout/stderr and final exit codes under `tmp/work-runtime-p1-selected-host-delivery/logs/`; poll every yielded process to terminal exit. A timeout, missing suite, zero selected tests or incomplete log is not a pass. Use the following toolchain and scratch path consistently (shell variables are task-specific):

```bash
mkdir -p tmp/work-runtime-p1-selected-host-delivery/logs
SHD_SWIFT=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
SHD_BUILD=tmp/work-runtime-p1-selected-host-delivery/build
# V0: compilation/typecheck
"$SHD_SWIFT" build --scratch-path "$SHD_BUILD"
# V1: retained dispatcher behavior plus T1/T2/T4/T5/T6
/usr/bin/arch -arm64 "$SHD_SWIFT" test --scratch-path "$SHD_BUILD" --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
# V2: reservation, uncertainty and budget regression
/usr/bin/arch -arm64 "$SHD_SWIFT" test --scratch-path "$SHD_BUILD" --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests'
# V3: retained lifecycle only; bounded child acceptance remains P1-6d
/usr/bin/arch -arm64 "$SHD_SWIFT" test --scratch-path "$SHD_BUILD" --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|AgentDirectorTests|CompletionEvaluatorTests'
# V4: capability/requirement/configuration regression, including T3/T8
/usr/bin/arch -arm64 "$SHD_SWIFT" test --scratch-path "$SHD_BUILD" --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
# V11: actual handoff and retained distributed behavior, including T7
/usr/bin/arch -arm64 "$SHD_SWIFT" test --scratch-path "$SHD_BUILD" --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|DistributedNodeExecutionTests'
# V5: joined regressions; baseline failures are recorded, never repaired here or hidden
/usr/bin/arch -arm64 "$SHD_SWIFT" test --scratch-path "$SHD_BUILD" --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'
/usr/bin/arch -arm64 "$SHD_SWIFT" test --scratch-path "$SHD_BUILD" --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests|RielaAppSupportTests'
# V6: produce a NUL manifest of all surviving changed/new Swift files first
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1-selected-host-delivery/changed-swift-files.nul
# V7: run at baseline and final; compare complete diagnostics
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
# Document/diff gates; cached check follows exact allowlist staging at finalization
 git diff --check
 git diff --cached --check
 git status --short --branch
 shasum -a 256 impl-plans/active/work-runtime-p1-selected-host-delivery.md
```

Log names: `V0-build.log`, `V1-focused.log`, `V2-reservation.log`, `V3-lifecycle.log`, `V4-capability.log`, `V11-handoff.log`, `V5-work-cli-core.log`, `V5-adapter-server-graphql-app.log`, `V6-touched-lint.log`, `V7-baseline-lint.log`, `V7-final-lint.log`, `document-checks.log`. Record the final exit code separately for each invocation; when using a logging pipeline, capture the producer's exit status, not tee's. Record exact T1–T8 test names/counts and hash the source tree/diff used for each accepted gate.

V1 and V11 are slice evidence only: they do not certify missing parent examples or P1-6c task cancellation. Parent full V1/V11 and final P1 remain open. V5 failures must be classified baseline versus introduced with concrete logs; never label a failing gate passing. Required gate failure blocks full implementation acceptance unless the independent reviewer explicitly records a bounded baseline exception; such an exception cannot close a parent gate. No browser/UI gate is needed for this CLI/worker slice. No runtime workflow/package readiness command is part of these checks.

## Acceptance and finalization

Planning acceptance: independently review this document's exact SHA-256, ownership manifest, DAG, T1–T8 matrix and commands; resolve every high/mid finding. The current planning commit allowlist is exactly this file, on `feat/remaining-impl-plans`, followed by non-force push of the accepted commit to the same branch. No main merge. Parent/design hashes must remain unchanged. The current node authors the document; downstream review/finalization records acceptance and commit/push evidence.

Later implementation acceptance requires all of the following, without changing parent checkboxes:

- [ ] SHD-1–SHD-5 complete, intents/post-hashes reconciled, exact changed-file allowlist reviewed.
- [ ] Real task-to-worker root and callee execution proves host/backend/model, exact root identity, ordinary callee admission and terminal projection ordering (T1/T2/T4).
- [ ] Entry/assignment/configuration rules, waits with no allocations and version/dependency races proven (T3/T5/T8).
- [ ] Worker loss has no fallback, duplicate launch or premature fence release (T6/T7).
- [ ] Required gates have complete terminal logs, positive suite/case counts, no introduced regression, and independent review has no unresolved high/mid findings.
- [ ] This plan records reviewed revision/hash, gate results, residual limitations and exact committed files. No unrelated code, package, example or legacy removal change is included.
- [ ] P1-6a slice accepted separately; P1-6c/6d/7b/7a and final P1 remain explicitly pending. Parent P1-6a closure requires its own full parent acceptance evidence; this plan does not mark it complete automatically.

Progress at authoring: SHD-1–SHD-5 not started. Planning document authored; independent plan review pending. No implementation test run or product completion is claimed.
