# Work Runtime P1-6a: selected-host and called-workflow delivery

Status: source-matched host verification recorded; independent implementation acceptance and bounded V5 exception pending.
Workflow mode: issue-resolution.
Issue: local-request: Work Runtime P1-6a SHD-5; no GitHub issue supplied.
Codex-agent reference-code inputs: none (`codexAgentReferences: []`). Current workflow references: intake `comm-000002`, accepted design review `comm-000004` / `step3-design-review-attempt-1-exec-4`, execution `codex-design-and-implement-review-loop-session-1`.

## Current finalization contract (2026-09-24, checkpoint 2264315)

User intent: independently review the retained P1-6a implementation and final
operator-host evidence, decide the bounded baseline exception, and finalize only
this slice if accepted. The accepted design is
`design-docs/specs/design-work-runtime-consolidation.md` §17.7, SHA-256
`2e33a88188b8659496248e4454d3514e7b29657672cfe41531234b05ff781e61`.
Step 3 accepted that design, not the implementation or V5 exception. The sole
plan is this file. Preserve checkpoint
`22643151891ad47e999343d05da1a20044176193`, its history and all current WIP.
The parent plan is read-only reference; parent P1 and later slices remain open.

This section and the current manifest govern execution. Historical progress
below is retained as evidence, not a request to recreate tests, restart SHD-1–4,
rerun completed host gates or repair unrelated baseline failures. The original
source-contract table and T1–T8 matrix remain behavioral review requirements;
their prospective wording does not authorize new implementation. No new runtime
component, Cursor behavior or reference-code comparison is needed.

### Tasks, dependencies and deliverables

Retain the original SHD-1 → SHD-2 → SHD-3 → SHD-4 → SHD-5 dependency history.
SHD-1–4 implementation is retained for review; only the following SHD-5 subtasks
remain. They execute serially on the existing branch and shared directory.

| Task | Depends on | Deliverable and acceptance |
| --- | --- | --- |
| SHD-5a evidence audit | retained SHD-4 | Fresh-read current source, design, plan and complete host logs. Record HEAD/dirty inventory and hashes; map T1–T8 to actual named tests/assertions and passing suites. Reconcile the 22-case/24-assertion failure set and signatures with both baselines. No host rerun when source/evidence remains sufficient. |
| SHD-5b adversarial review | SHD-5a | Independent read-only reviewer assesses material correctness, data loss, security and verification; records reviewed hashes, exact findings and explicit accept/reject plus rationale for the bounded V5 exception. |
| SHD-5c integration review | SHD-5b | A distinct independent read-only reviewer checks retained plus current P1-6a source/test changes, test integrity and source-matched evidence on the combined tree. Explicitly accept/reject the same V5 exception and report all high/mid defects. |
| SHD-5d serial reconciliation | SHD-5c | If either review rejects or reports high/mid defects, record precise repair scope and do not finalize. One owner repairs only demonstrated P1-6a defects, refreshes affected gates/hashes and returns revised bytes to both reviewers. If both accept, update only this plan's progress/acceptance evidence, reconcile exact six-path publication allowlist and hand off commit/non-force push. |

No parallel implementation tasks or new native fanout are scheduled. Use the
existing sequential review stages with independent reviewers. Accepted design
and plans must be committed before any native implementation/review fanout;
this continuation additionally prohibits any commit before independent slice
acceptance. Thus do not launch native fanout or make an early planning commit.
Step 4 only authors this plan; Step 5 reviews its exact bytes. Publication is a
later serial action after both implementation reviews accept. Do not create
worktrees/private branches or run concurrent Git mutations.

### File-level intent and boundaries

The two current production changes are in
`Sources/RielaCLI/HostCapabilityResolver.swift` and
`Sources/RielaCLI/TaskDispatch.swift`: review dry-run/topology behavior and
selected-host task dispatch against the invariant list below. Preserve them
unless a concrete defect requires repair. Review the current assertions in
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` and helpers in
`Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift`;
do not recreate the authenticated T4/T6 cases or reinstate the unsupported
pre-reserved-session `instanceConfiguration.nodePatches` expectation. Preserve
separate patch-before-placement and actual worker backend/model assertions.
Keep all other source/test paths read-only unless a precise material finding
requires a separately reviewed ownership extension.

Step 4 writes only this plan. The accepted design stays byte-identical. After
implementation acceptance, this plan records reviewers, reviewed hashes,
T1–T8 mapping, commands/logs/exits, V5 exception rationale, residual limitations
and exact committed files. The final candidate allowlist is exactly the four
Swift paths above, the accepted design and this plan, in manifest order.
Verify the complete retained P1-6a diff as well as the unpublished delta;
checkpointed files need review but are not silently added to publication.
Read README and affected documentation; no user-facing behavior change means
no additional documentation edit. Parent plans, indexes, lockfiles, package
files, Monja and unrelated work remain unchanged. No archiving, broad formatting
or unrelated baseline repair is part of this work.

Before each edit, fresh-read and compare the file hash to the latest recorded
post-hash, initially the pre-hash. Save an immutable intent revision under
`tmp/p1-6a-finalization/<execution>/intents/` with task, exact paths, pre-hashes,
finding and intended change. After editing save post-hashes and the actual diff.
On drift stop the edit, inspect intervening changes and create a superseding
intent from current bytes; never restore stale buffers. One serial owner joins
and repairs all changes. Each reviewer writes only its own progress/evidence
under `tmp/p1-6a-finalization/<execution>/reviews/<role>/`; the owner writes
`tmp/p1-6a-finalization/<execution>/progress.md`. Record task/status, commands,
terminal exits, complete log paths, source hashes, findings and decisions.
Preserve earlier logs and checkpoint history; never stage scratch artifacts.

### Source-matched evidence and verification

Use `tmp/p1-6a-finalization/host-verify/evidence.json` and every referenced
complete log. Recorded V0/V6/V7 exit 0; V1 41/41, V2 23/23, V3 80/80,
V4 55/55, V11 53/53. V5 adapters/server/GraphQL/app exits 0 with 440 XCTest
cases (two skipped) and 19 Swift Testing cases. V7 has 30 warnings in unchanged
files. V5 CLI/Core exits **1**, 1,965 tests, 24 assertions in 22 cases. Compare
21 cases/23 assertions against
`tmp/p1-6a-host-verify/preimplementation-baseline/all-current-failures.log`;
compare the additional
`WorkflowCommandTests.testCallStepCompletesChangeTrackedFanoutBeforeStopping`
against `tmp/p1-6a-finalization/host-verify/baseline-cbe1dd1-call-step.log`
(exit 1, same missing `agentSandbox` validation error). Both reviewers must
inspect signatures and slice relevance, not infer acceptance from counts.
The exception may cover only this identified set; V5 remains failing and no
parent gate closes even if both accept it.

Run the following read-only audit commands from repository root and save full
stdout/stderr plus each terminal exit under the execution evidence directory:

```bash
git status --short --branch
git rev-parse HEAD
cat tmp/p1-6a-finalization/host-verify/evidence.json
shasum -a 256 design-docs/specs/design-work-runtime-consolidation.md impl-plans/active/work-runtime-p1-selected-host-delivery.md
shasum -a 256 Sources/RielaCLI/HostCapabilityResolver.swift Sources/RielaCLI/TaskDispatch.swift Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift
git diff -- Sources/RielaCLI/HostCapabilityResolver.swift Sources/RielaCLI/TaskDispatch.swift Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift | shasum -a 256
rg -n 'func test|XCTAssert|XCTUnwrap' Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift
rg -n 'error: -\[|Test Case.*failed|Executed .*tests' tmp/p1-6a-finalization/host-verify/V5-work-cli-core-final.log tmp/p1-6a-host-verify/preimplementation-baseline/all-current-failures.log tmp/p1-6a-finalization/host-verify/baseline-cbe1dd1-call-step.log
git diff --check
```

Hashes must match the host manifest; inspect full logs (not only rg excerpts)
for T1–T8 assertions, positive selected counts and terminal summaries. The
source-diff pipeline must record both producer statuses, not just shasum's exit.
Record the exact 22 case names, per-case assertion counts, signature comparison
and each reviewer's exception decision. Evidence audit is not a fresh test run.

Do not repeat completed host gates unless bytes change or evidence is materially
insufficient. The V0–V7/V11 command catalog below is conditional repair guidance.
For required reruns use the host's resolved scratch path
`tmp/p1-6a-host-verify/build`, `--skip-update`, and `--disable-sandbox` for tests,
with the catalog's exact toolchain and filters; record actual commands and why
each gate is affected. V0 provides Swift compilation/typechecking; V6 covers
all changed Swift paths including the helper; V7 compares repository warnings.
No browser/UI gate applies. An inability to run listeners here requires owned
host verification of changed bytes, not replacing existing host evidence with
sandbox environment failures. No incomplete log or zero-selected suite passes.
Run foreground commands and retain/poll yielded handles to terminal exit.

Before publication review `git diff --no-ext-diff --unified=3 85ab45a --` and
`git show --format= --no-ext-diff 6b86992 --` with the exact retained slice paths
from the original ownership table appended. Record unexpected-file and redacted
secret-review findings; never include credentials in logs. Then independently
review the current six-path publication diff, including the untracked helper.
Finalization checks `git diff --check`, exact allowlist staging,
`git diff --cached --check` and `git diff --cached --name-only`; commit only
accepted bytes and non-force push to `origin` / `feat/remaining-impl-plans`.
Record committed files, commit hash, push exit and remote hash equality. No
publication is claimed by this plan; do not close acceptance boxes early.

## Intent and authority

The current finalization contract above supersedes prior execution scheduling,
source inventories and planning commit wording. Accepted design §17.2, §17.4
and §17.7 and the T1–T8 matrix below define behavior. Runner-supplied provenance
and effective input are authoritative; no package/registry rediscovery task is
part of this plan. There is no new user product decision or reference divergence.

## Contract and ownership manifest

```json
{
  "planId": "work-runtime-p1-selected-host-delivery",
  "planPath": "impl-plans/active/work-runtime-p1-selected-host-delivery.md",
  "dependsOn": [],
  "execution": "serial SHD-5 finalization; independent sequential reviews",
  "writePaths": [
    "Sources/RielaCLI/HostCapabilityResolver.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "impl-plans/active/work-runtime-p1-selected-host-delivery.md"
  ],
  "sharedPaths": [
    "impl-plans/active/work-runtime-p1-selected-host-delivery.md"
  ],
  "publicationAllowlist": [
    "Sources/RielaCLI/HostCapabilityResolver.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-selected-host-delivery.md"
  ],
  "tasks": [
    {
      "id": "SHD-5a",
      "dependsOn": [],
      "deliverable": "retained SHD-4 and source-matched evidence audit"
    },
    {
      "id": "SHD-5b",
      "dependsOn": [
        "SHD-5a"
      ],
      "deliverable": "independent adversarial and V5 exception decision"
    },
    {
      "id": "SHD-5c",
      "dependsOn": [
        "SHD-5b"
      ],
      "deliverable": "independent combined-tree integration and V5 exception decision"
    },
    {
      "id": "SHD-5d",
      "dependsOn": [
        "SHD-5c"
      ],
      "deliverable": "serial repair/review if required; accepted documentation and exact-file publication handoff"
    }
  ]
}
```

The empty plan-level dependency list means there is no new separately scheduled plan prerequisite; SHD-5a audits retained SHD-1–4 evidence. All tasks are serial because composition, admission and test fixtures overlap. No parallel implementation tasks, private branches, worktrees or concurrent Git operations. One owner controls all listed source/test edits. The author/reviewer roles remain independent.

## Non-goals and stopping rules

Do not implement P1-6c live decision/cancellation integration, P1-6d director execution, P1-7b examples, P1-7a legacy removal, or final P1 certification. Their order remains 6c → 6d → 7b → 7a → final acceptance. Preserve existing cancellation behavior and test its worker loss boundary; do not claim new task cancellation acknowledgment coverage. Do not remove auto-improve or repair unrelated broad-test failures.

No second dispatcher, capability registry, runner, transport, store, scheduler, package resolver or planner. No schema migration, new CLI command, broad formatting, generic abstraction, speculative hardening or performance cleanup. Do not modify other worktrees or Monja. Use the existing capability context for existing planner variables; do not create a planner or run a director child here.

If a required repair exceeds the explicit file map, record the failing test, exact additional path and smallest necessary change for serial review before editing it. Do not silently expand scope. Source drift is a reconciliation event, not permission to overwrite another owner's changes. Material design contradictions must be returned for review; cosmetic preferences are not blockers.

## Retained source contracts and bounded repair ownership

The table records original implementation intent, retained through checkpoint `2264315` plus current WIP.
SHD-2/SHD-3 verify these contracts; change production code only for a failure
demonstrated by the required tests. The current continuation has no planned test additions; repairs require a concrete finding.

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
| `Sources/RielaCore/DistributedNodeExecution.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Distributed.swift`, `Sources/RielaCore/DistributedJobController.swift` | Reuse queued handoff, exact worker target, existing attach/lease/result/lost behavior and runner result projection. Existing loss is non-retryable; no fallback/requeue is authorized. The red `testTaskTopologyRejectsCachedWorkerWithoutLiveControllerRegistration` proves a cached snapshot can select an unregistered worker. Serially extend only `DistributedJobController.swift` with a read-only worker-status query because retained `workers(now:)` may persist lease expiration during dry-run. Independent review of this exact extension remains required. |
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

Execute only the current SHD-5a–d finalization table above. The original task descriptions
below define retained deliverables, not instructions to reimplement them.

- **SHD-1 / baseline:** Fresh-read this plan, authority docs and all owned files. Record HEAD, clean/dirty inventory, source hashes and V0/V2/V3/V4 baseline outcomes. Inspect existing controller/workspace configuration and retained worker tests. Capture an immutable intent JSON per task under `tmp/work-runtime-p1-selected-host-delivery/intents/` listing exact paths, pre-hashes, intended changes and acceptance rows. Do not edit until that snapshot is saved.
- **SHD-2 / admission composition:** Implement reachable requirement/assignment composition, one topology evaluation, explicit workspace selection and full admission evidence through the listed seams. Add requirement/topology/config tests alongside changes. Deliver preview/wait behavior with zero durable allocations and no credential values in evidence.
- **SHD-3 / execution delivery:** Thread frozen execution context through root and callees, preparation, placement application and existing distributed executor. Verify effective-instance override ordering, exact root identity and ordinary callee admission. Keep retained terminal reconciliation. No human decision/director expansion.
- **SHD-4 / evidence:** Extend the test owners below with actual task-dispatch-to-worker execution. The fixture adapter may be deterministic, but the task dispatcher, admission/store, queued controller, authenticated transport, worker executor and completion projection under test must be real. Add failure/race cases and ensure owned shutdown.
- **SHD-5 / serial acceptance:** Fresh-read all changed files, compare post-hashes and joined diff against intents, repair integration conflicts serially, run required gates, obtain independent review, resolve all high/mid findings, and record reviewed commit bytes. Update only this plan's progress/acceptance evidence. No parent checkbox changes. Commit only accepted exact files; no main merge.

Before each edit, reread the current file and compare its SHA-256 with the latest recorded post-hash (or baseline pre-hash). On mismatch, stop that edit, inspect the intervening diff and rewrite the intent from current bytes; never restore a stale buffer. Save post-hash and actual diff after each edit. Shared indexes, lockfile generation, global formatting and plan archiving belong only to serial finalization and are not needed by this slice. Each owner writes only its own progress log; for this single implementation owner use `tmp/work-runtime-p1-selected-host-delivery/progress.md`. Record task ID, changed paths, pre/post hashes, commands, exit status, full log paths, positive test counts, blockers and review decision. Final accepted evidence is summarized in this plan. Preserve prior and current verification evidence; do not delete it during cleanup.

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

Conditional repair catalog only: the current contract above controls whether any gate must rerun. Run from repository root, foreground only. Save complete stdout/stderr and final exit codes under `tmp/work-runtime-p1-selected-host-delivery/logs/`; poll every yielded process to terminal exit. A timeout, missing suite, zero selected tests or incomplete log is not a pass. Use the following toolchain and scratch path consistently (shell variables are task-specific):

For this continuation, place the log names below in a fresh execution-specific
subdirectory of `logs/` and record its exact path in progress. Never truncate
older gate logs. Record the invoked command, HEAD, exact reviewed source/test
file SHA-256 manifest and dirty-diff hash with each gate. If toolchain cache or
listener restrictions prevent completion, preserve the failure and obtain a
source-matched host run; a changed scratch path or host command must be recorded
explicitly with the same test filter and source identity.

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

Planning acceptance: Step 5 independently reviews this document's exact hash,
manifest, DAG, T1–T8 mapping and conditional commands; resolve every high/mid
finding. Preserve accepted design and parent bytes. No commit/push occurs before
independent implementation acceptance. Native fanout is not scheduled; the
commit-before-fanout rule does not authorize an early commit. Final publication
uses the current six-path allowlist after acceptance and serial reconciliation.

Later implementation acceptance requires all of the following, without changing parent checkboxes:

- [ ] SHD-1–SHD-5 complete, intents/post-hashes reconciled, exact changed-file allowlist reviewed.
- [ ] Real task-to-worker root and callee execution proves host/backend/model, exact root identity, ordinary callee admission and terminal projection ordering (T1/T2/T4).
- [ ] Entry/assignment/configuration rules, waits with no allocations and version/dependency races proven (T3/T5/T8).
- [ ] Worker loss has no fallback, duplicate launch or premature fence release (T6/T7).
- [ ] Required gates have complete terminal logs, positive suite/case counts, no introduced regression, and independent review has no unresolved high/mid findings.
- [ ] This plan records reviewed revision/hash, gate results, residual limitations and exact committed files. No unrelated code, package, example or legacy removal change is included.
- [ ] P1-6a slice accepted separately; P1-6c/6d/7b/7a and final P1 remain explicitly pending. Parent P1-6a closure requires its own full parent acceptance evidence; this plan does not mark it complete automatically.

Progress on 2026-09-23 (issue-resolution Step 6, incomplete): SHD-1 baseline captured; SHD-2–SHD-5 source and selected tests implemented through retained dispatcher, reservation, callee resolver, distributed executor and authenticated worker paths. The controller status inspection seam was added to `Sources/RielaCore/DistributedJobController.swift` after the cached-worker test failed red, then passed green. Per-edit intentions and post-hashes are under `tmp/work-runtime-p1-selected-host-delivery/intents/`. No parent criterion is changed.

Selected checks on the current implementation: V0 fallback build passed after the exact fresh scratch build failed before compilation on an unwritable module cache; V2 passed 23/23, V3 passed 80/80, V4 passed 55/55, and the focused frozen-callee resolver test passed 1/1. V1 failed 4/32 assertions and V11 failed 13/45 assertions, including T1/T2 local HTTP listener denial (`Network.NWError error 1 - Operation not permitted`). V5 CLI/Core failed 503 assertions across 1,944 tests, including unrelated Git addon and workflow command failures; V5 adapters/server/GraphQL/app exited zero with positive selected tests. Complete command logs and exit files are under `tmp/work-runtime-p1-selected-host-delivery/logs/`. V7 unscoped SwiftLint is superseded by the runtime's exact changed-file lint requirement and is not an acceptance gate for this run.

Independent read-only source review by `/root/source_analysis` found no remaining high/mid production-code defect but marked verification incomplete: T1/T2 lack positive authenticated execution, and T2 does not directly assert ordinary child process admission or terminal output projection before completion. `/root/test_analysis` also identified remaining task-level T4–T6 and T8 coverage gaps. These findings and failing gates keep every implementation acceptance box above unchecked. At that workflow terminal, no implementation acceptance, commit, push or parent P1 closure was claimed.

Operator host-side follow-up (2026-09-23): after the implementation session ended, the T1/T2 fixture was corrected for repeated capability publications and the CLI's ISO-8601 date encoding. Both authenticated root/callee tests now pass with assertions for the reserved root, linked ordinary child, accepted outputs, reconciled attempt, terminal evidence and final decision. On the exact pre-merge branch content, V1 passed 32/32 and V11 passed 45/45 using `swift test --disable-sandbox --skip-update` with an isolated scratch build; both remained 32/32 and 45/45 after merge commit `0e9ceb9`. Complete logs and exit codes are in `tmp/p1-6a-host-verify/`. The host-side V5 CLI/Core run failed 23 assertions across 1,944 tests (versus 503 in the implementation sandbox). An independent checkout of the pre-implementation checkpoint `39d08a4` reproduced the **same 21 failing cases and 23 assertions**; exact-case baseline logs, exit code and SHA-256-verified copies are in `tmp/p1-6a-host-verify/preimplementation-baseline/`. This proves the observed host-side V5 failures predate the P1-6a implementation, but V5 is still failing and requires an explicit bounded baseline exception from the independent reviewer. The WIP implementation checkpoint `6b86992` and main merge `0e9ceb9` were pushed to `feat/remaining-impl-plans`; neither is acceptance. T4–T6/T8 coverage and final independent review remain open.

Step 6 continuation (2026-09-23, still incomplete): one serial owner added
`testTaskExplicitWorkerAndGroupExecutePinnedChoices` and authenticated-worker
workspace cases `testTaskAuthoredWorkspaceOverridesControllerDefaultAtWorker`
and `testTaskDefaultWorkspaceAliasReachesWorker` to
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`. The retained T1/T2
fixture now optionally starts two distinct recording workers and checks the
chosen adapter, leased worker ID, backend/model and workspace alias. The new
`testTaskAdmissionWaitsAndDryRunLeaveNoAllocations` covers dependency wait,
zero capacity and dry-run with exact row and file-byte comparisons. In
`Tests/RielaWorkTests/TaskDispatcherTests.swift`,
`testDependencyChangeBetweenPreviewAndReservationDeniesLaunch` proves the
reservation recheck creates no attempt, decision or evidence. The latter two
tests passed 2/2 with zero failures on the current source; full output and exit
status are in `tmp/work-runtime-p1-selected-host-delivery/logs/step6-local-focused-final.*`.
Strict selected-file SwiftLint passed on the retained P1-6a Swift set plus the
new Work test, using `step6-changed-swift-files.nul`; see `logs/step6-V6-lint-4.*`.

The exact plan scratch test stopped before compilation because its module cache
was unwritable; the plan-local-cache retry stopped before compilation while
fetching `agent-gateway` because DNS was unavailable. The current-tree `.build`
retry compiled the new HTTP tests, but `testTaskExplicitWorkerAndGroupExecutePinnedChoices`
and the two T8 workspace cases failed at listener creation with
`Network.NWError error 1 - Operation not permitted`; see
`logs/step6-T4-pins-2.*` and `logs/step6-T8-current-tree.*`. These are missing
host execution evidence, not passing tests. T4 repeated-node/instance-patch
execution, T5 absent/stale-worker and task-level version race, and T6 claimed
worker loss/uncertain fence remain unimplemented. Final source-matched V0–V7/V11,
V5 signature reclassification and explicit independent bounded-exception
decision, adversarial/integration reviews, and exact-file acceptance remain
open. Historical post-merge V1/V11 and V5 logs do not certify these new bytes.
No completion box or parent P1 criterion is closed; no commit or push occurred
in this Step 6 continuation.

Operator host follow-up after Step 6 terminal (2026-09-23): the current two-test-file
diff SHA-256 is `d5fc7541fb97ebd8474ae12b3a03857792327b9df0a99d4d448170309072c8d4`.
Using the existing resolved scratch build on the listener-capable host,
`swift test --disable-sandbox --skip-update --filter TaskDispatcherIntegrationTests`
passed 19/19 with zero failures (exit 0). This includes the authenticated T4
worker/group pin and both T8 workspace cases that could not run inside the
implementation sandbox. The complete rerun log is
`tmp/work-runtime-p1-selected-host-delivery/logs/T4-T8-host-integration.log`.
This is focused evidence only: the listed T4 repeated-node/instance-patch,
T5 and T6 gaps and final source-matched V0–V7/V11 gates remain open.

Step 6 continuation at `22643151891ad47e999343d05da1a20044176193`
(2026-09-23, still incomplete): the single implementation owner changed
`Sources/RielaCLI/TaskDispatch.swift`,
`Sources/RielaCLI/HostCapabilityResolver.swift`,
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`, and new
`Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift`.
Per-edit intents and post-hashes are in
`tmp/work-runtime-p1-selected-host-delivery/intents/continue-20260923/`;
the final code source identity and exact hashes are in
`logs/continue-20260923/source-identity.txt` beneath that evidence root.
The new task-level cases cover absent/stale/unregistered worker waits and a
missing controller lock sidecar without allocation, version/dependency changes
between preview and reserve, repeated node IDs across root/callee with distinct
worker/backend/model choices, an actual conflicting instance patch routed through
task dispatch to the selected worker, and a claimed-worker-loss retry before and
after durable lease loss. The dry-run lock sidecar regression was found by
`/root/source_review` and fixed in the existing topology seam. Fixture helpers
were extracted into the allowed sibling test file to keep each Swift file below
1,000 lines. These new authenticated cases are **compiled but have not passed**
on the current source: this sandbox denies localhost listeners.

Terminal logs and exit files under `logs/continue-20260923/` record the exact
V0 scratch build exiting 1 before compilation on the protected module cache
(`V0-build-exact-scratch-final.*`), followed by the current-tree cache fallback
exiting 0 (`V0-build-fallback-final.*`); V2 23/23, V3 80/80, V4 55/55; and
local T4 patch/T5 cases 3/3.
V1 ran 41 tests and exited 1 with 16 assertions in eight HTTP fixture cases;
V11 ran 53 tests and exited 1 with 25 assertions in HTTP fixture cases. All
observed V1/V11 failures occurred at listener creation with
`Network.NWError error 1 - Operation not permitted`; neither gate is a pass.
V5 CLI/Core ran 1,965 tests and exited 1 with 519 failed assertions across 249
cases in this sandbox. V5 adapter/server/GraphQL/app exited 0 with 85 XCTest
and 19 Swift Testing cases. V6 strict selected-file lint exited 0. V7 explicit
repository-file lint exited 0 with 30 warnings in 19 files; none of those files
changed since `cbe1dd1`. `git diff --check` passed. The exact plan scratch test
failed before compilation on the protected module cache; its plan-local-cache
retry failed fetching `agent-gateway` because DNS was unavailable. The
current-tree dependency checkout supplied the completed runs. No incomplete log
is counted as a passing check.

Independent `/root/source_review` found no unresolved high/mid source finding
after the dry-run, task-level patch and post-loss retry corrections, but its
decision is source-review acceptance **pending positive host verification**.
Independent `/root/evidence_audit` explicitly **rejected** the bounded V5
exception for this run: the final sandbox V5 includes 228 failing cases beyond
the historical host's 21-case/23-assertion preimplementation baseline, and the
historical host log is not source-matched. A listener-capable operator host must
run final V1/V11, the new authenticated T4/T6 tests, and V5 on these exact
source bytes; then an independent reviewer must compare exact V5 case names and
signatures and decide the exception again. V5 remains failing, every
implementation acceptance checkbox above remains open, and later P1 slices and
final P1 remain open. No commit or push occurred in this Step 6 continuation.

Operator host verification after Step 6 terminal (2026-09-24; independent
acceptance still pending): the new instance-patch worker test initially failed
because it demanded `instanceConfiguration.nodePatches` on the pre-reserved
session, where that metadata is not persisted. The test now retains the
separate `prepareRunExecution` assertion that the conflicting patch applies
before placement and the authenticated worker assertion that the admitted
backend/model wins, without asserting unrelated reserved-session metadata.
The failing case passed 1/1 after this correction. The four reviewed Swift
file SHA-256 values, tracked code diff hash, exact host commands, terminal exit
codes and full logs are recorded in
`tmp/p1-6a-finalization/host-verify/evidence.json`; the source identity stayed
unchanged throughout the final host gates.

On that source, host V0 build exited 0; V1 passed 41/41, V2 23/23, V3 80/80,
V4 55/55 and V11 53/53. The final authenticated T4/T6 cases are included in
the passing V1/V11 runs. V5 adapter/server/GraphQL/app passed 440 XCTest cases
(two skipped, zero failures) plus 19 Swift Testing cases. Strict touched-file
SwiftLint and repository-wide SwiftLint exited 0; the latter reported 30
warnings only in unchanged files. `git diff --check` passed. The host commands
used the already resolved scratch build and `--skip-update`, because the exact
fresh scratch path in the implementation sandbox could not reach compilation.

Host V5 CLI/Core **still failed**: 1,965 tests, 24 failed assertions in 22
distinct cases (seven unexpected), exit 1. Twenty-one cases and 23 assertions
match the independent preimplementation baseline exactly by case name and
per-case assertion count. The one additional case,
`WorkflowCommandTests.testCallStepCompletesChangeTrackedFanoutBeforeStopping`,
was run in a clean detached checkout of checkpoint `cbe1dd1` and failed with
the same missing `agentSandbox` validation error before this continuation's
source edits. Its complete terminal log is
`tmp/p1-6a-finalization/host-verify/baseline-cbe1dd1-call-step.log`; the
disposable checkout was removed after verifying it was clean. This is
source-matched evidence for an expanded 22-case/24-assertion pre-existing
failure set, **not** a passing V5 gate or an accepted exception. An independent
reviewer must explicitly accept or reject the bounded exception against these
logs before any P1-6a acceptance, commit or push. Parent P1 and later slices
remain open.

Step 4 finalization-plan revision (2026-09-24): Step 3 `comm-000004` accepted
the design with no findings. This revision limits remaining work to SHD-5a–d,
retains source-matched host evidence and requires both independent V5 decisions.
All implementation acceptance boxes remain open. No source edits, gate reruns,
commit, push or parent closure occurred in Step 4. Author evidence is under
`tmp/p1-6a-finalization/step4-plan/`.
