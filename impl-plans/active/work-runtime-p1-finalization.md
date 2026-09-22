# Work Runtime P1: Serial reconciliation, documentation and verification

**Status**: Step 4 reconciled for user-scope package 0.3.12; Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete the Work Runtime P1 dependency DAG (number/url: null)
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.6 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review-attempt-1-exec-4`, `accepted`; findings/feedback empty; no Step 5 feedback supplied.
**Codex-agent references**: `workflowExecutionId:codex-design-and-implement-review-loop-session-1`, `issueCommunicationId:comm-000002`, `intakeExecutionId:step1-issue-intake-attempt-1-exec-2`, `communicationId:comm-000004`, `designStepId:step2-design-doc-update`, `stepId:step3-design-review`, `stepId:step4-impl-plan-create`, `designAuthorModel:gpt-6-astra`, `planAuthorModel:gpt-6-astra`, `gateModel:gpt-5.6-sol`, `implementationModel:gpt-5.6-terra`; downstream executions record actual IDs.
**Resumption authority**: Current runtimeVariables deliver `comm-000004` from `step3-design-review-attempt-1-exec-4`, accepting design execution `step2-design-doc-update-attempt-1-exec-3` (`comm-000003`). This accepts the resumed design for package 0.3.12; identical historical communication labels alone are not current acceptance. Intake is `comm-000002`; role assignment originates at `comm-000001` / `riela-manager-attempt-1-exec-1`. No implementation predecessor is accepted by this planning turn.
**Planning evidence**: `tmp/work-runtime-p1/step4-plan-v0312/verification-evidence.json`; author self-check: `tmp/work-runtime-p1/step4-plan-v0312/author-self-check.json`.
**Updated**: 2026-09-22

```json
{
  "planId": "p1-finalize",
  "planPath": "impl-plans/active/work-runtime-p1-finalization.md",
  "dependsOn": [
    "p1-sandbox",
    "p1-reservation",
    "p1-lifecycle",
    "p1-capabilities",
    "p1-dispatch"
  ],
  "writePaths": [
    "README.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Sources/RielaCore/SurfaceCatalog+RowSupport.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/WorkflowRunHelpTests.swift",
    "Tests/RielaCLITests/WorkflowCommandInspectionTests.swift",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "design-docs/specs/design-control-surface-parity.md",
    ".codex/skills/riela-impl-workflow/SKILL.md",
    "examples/task-repair-loop/**",
    "examples/task-agent-director/**",
    "impl-plans/README.md",
    "impl-plans/PROGRESS.json",
    "impl-plans/progress/plans-index.json",
    "impl-plans/progress/meta.json",
    "impl-plans/progress/phases.json",
    "impl-plans/progress/plans/work-runtime-p1-capabilities.json",
    "impl-plans/progress/plans/work-runtime-p1-dispatcher-guard-director.json",
    "impl-plans/progress/plans/work-runtime-p1-finalization.json",
    "impl-plans/progress/plans/work-runtime-p1-guard-director.json",
    "impl-plans/progress/plans/work-runtime-p1-reservation.json",
    "impl-plans/progress/plans/work-runtime-p1-sandbox.json",
    "impl-plans/active/work-runtime-p1-capabilities.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/active/work-runtime-p1-finalization.md",
    "impl-plans/active/work-runtime-p1-guard-director.md",
    "impl-plans/active/work-runtime-p1-reservation.md",
    "impl-plans/active/work-runtime-p1-sandbox.md",
    "Package.swift",
    "Package.resolved",
    "impl-plans/progress/p1-finalize.md"
  ],
  "sharedPaths": [
    ".codex/skills/riela-impl-workflow/SKILL.md",
    "Package.resolved",
    "Package.swift",
    "README.md",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCore/SurfaceCatalog+RowSupport.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Tests/RielaCLITests/WorkflowCommandInspectionTests.swift",
    "Tests/RielaCLITests/WorkflowRunHelpTests.swift",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "examples/task-agent-director/**",
    "examples/task-repair-loop/**",
    "impl-plans/PROGRESS.json",
    "impl-plans/README.md",
    "impl-plans/active/work-runtime-p1-capabilities.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/active/work-runtime-p1-finalization.md",
    "impl-plans/active/work-runtime-p1-guard-director.md",
    "impl-plans/active/work-runtime-p1-reservation.md",
    "impl-plans/active/work-runtime-p1-sandbox.md",
    "impl-plans/progress/meta.json",
    "impl-plans/progress/phases.json",
    "impl-plans/progress/plans-index.json",
    "impl-plans/progress/plans/work-runtime-p1-capabilities.json",
    "impl-plans/progress/plans/work-runtime-p1-dispatcher-guard-director.json",
    "impl-plans/progress/plans/work-runtime-p1-finalization.json",
    "impl-plans/progress/plans/work-runtime-p1-guard-director.json",
    "impl-plans/progress/plans/work-runtime-p1-reservation.json",
    "impl-plans/progress/plans/work-runtime-p1-sandbox.json"
  ],
  "progressLog": "impl-plans/progress/p1-finalize.md",
  "taskIds": [
    "P1-8"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-finalize",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter 'WorkflowRunHelp|WorkflowCommandInspection|DistributedWorkerConfiguration|SurfaceCatalog'",
    "git diff --check",
    "xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-finalize/changed-swift-files.nul",
    "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter RielaWorkTests",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter 'WorkStoreReservationTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|ImplementationWorkflowSandboxTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter TaskCommandMutationTests/testDryRunLeavesRuntimeDatabaseByteAndRowEquivalent",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize",
    "tmp/work-runtime-p1/build/p1-finalize/debug/riela doctor --output json",
    "tmp/work-runtime-p1/build/p1-finalize/debug/riela doctor --output text",
    "tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow validate codex-design-and-implement-review-loop --workflow-definition-dir .riela/workflows --output json",
    "tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow validate task-repair-loop --workflow-definition-dir examples --output json",
    "tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1/p1-finalize/examples/task-repair-loop --output json",
    "tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json",
    "tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1/p1-finalize/examples/task-agent-director --output json",
    "git diff --name-only"
  ],
  "dependencyMode": "native-accepted-predecessor-DAG",
  "evidenceDirectory": "tmp/work-runtime-p1/p1-finalize/"
}
```

The execution, overwrite protection, evidence, and completion contract in
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` applies to this plan.
No worker edits another worker’s progress log or marks a shared plan complete.


## Intent, context, non-goals and invariants

User intent is closure of every P1 task on the actual joined tree, with honest
verification and publication evidence. All five implementation predecessors
must already have accepted source/behavior/interface handoffs; finalization
cannot fill missing readiness with a progress claim. Non-goals: implementing
P2–P7, unrelated cleanup/formatting, editing another worker's log, changing the
immutable installed workflow, or base-branch integration.

| File responsibility | Smallest intended change / acceptance |
| --- | --- |
| `README.md`, `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`, `SurfaceCatalog+Rows.swift`, `SurfaceCatalog+RowSupport.swift`; `Sources/RielaCLI/CLISurfaceEnumeration.swift`, `RielaCommand.swift`, `RielaArgumentParser+WorkflowAndMemory.swift` | Reconcile actual task/host/doctor/help surfaces and removed options; no new behavior beyond accepted P1. |
| `Tests/RielaCoreTests/SurfaceCatalogTests.swift`, `Tests/RielaCLITests/WorkflowRunHelpTests.swift`, `WorkflowCommandInspectionTests.swift` | Assert help/catalog/parity against the joined accepted surface. |
| `design-docs/specs/design-work-runtime-consolidation.md`, `design-control-surface-parity.md`; `.codex/skills/riela-impl-workflow/SKILL.md` | Refresh only P1 behavior/status/guidance; mark GraphQL/GUI deferred; inspect exact owner before any additional directly affected guidance edit. |
| `examples/task-repair-loop/`, `examples/task-agent-director/` | Repair only accepted joined intent and EXPECTED_RESULTS alignment; preserve dispatch-owned semantics and rerun its tests on repair. |
| Six canonical active plans, `impl-plans/README.md`, `impl-plans/PROGRESS.json`, `impl-plans/progress/plans-index.json`, `meta.json`, `phases.json`, P1 records under `impl-plans/progress/plans/` | Reconcile P1-only status from independent acceptance. Materialize exact P1 record paths before edits; preserve all other plan/session entries. |
| `Package.swift`, `Package.resolved` | Serial reconciliation only if required by accepted implementation; no gratuitous lockfile regeneration. |
| `impl-plans/progress/p1-finalize.md` | Joined hash inventory, repair assignments, full gates, reviewers and publication readiness; never alter predecessor logs. |

Invariants: every accepted intent survives join or is explicitly repaired and
retested; no checkbox/archive from planning acceptance; all changed Swift files
in strict lint union; no removed workflow flag advertised; unrelated specialist/
event options remain; final allowlist contains only accepted P1 and narrow docs.
Runtime-owned joining and serial repair precede Astra's independent combined
review; later workflow gates grant acceptance before closure/commit/push.

## Intended changes and acceptance (§10, §13, §17.1, §17.5)

- [ ] **P1-8a** Join every accepted predecessor using runtime change evidence,
  pre/post hashes and immutable intents. Audit retained WIP and serially repair
  lost/overwritten intent, explicitly assigning exact repair files from the
  predecessor write sets before editing. No parallel repair. Re-run affected
  regressions and request independent combined-tree review.
- [ ] **P1-8b** Reconcile help, README, SurfaceCatalog and parity design rows for
  task run/decide, workflow usage/host validation and doctor. Explicitly mark
  GraphQL task/host and GUI counterparts deferred to P5. Update design P1 status
  only from accepted implementation/review evidence; broader design is unchanged.
  Refresh directly affected workflow-authoring guidance with intended host
  snapshot/pin/policy rules, and remove obsolete auto-improve instructions.
  Audit repository skill ownership; changes under user-scope installed package
  or external skills are not authorized repository edits. Report any external
  obsolete guidance as a handoff, do not invoke or rewrite it.
- [ ] **P1-8c** Audit all tracked/untracked owning riela-package.json manifests
  for workflow/prompt/script/skill edits. Refresh only applicable digests using
  that package's established tool and validate it. Capture exact expanded tool
  command and manifest path in the log. If none exists (Step 2 observed none),
  record the fresh audit and mark digest refresh non-applicable. Do not invent
  a package or edit the installed user-scope package. Lockfile generation,
  indexes and any necessary touched-file formatting are serial here only.
- [ ] **P1-8d** Run the gates below on the joined tree, require no unresolved
  high/mid test-integrity/adversarial/combined review findings through the
  existing installed workflow, and record review execution IDs and decisions.
  This worker prepares closure evidence; later independent review steps own
  acceptance. Until they accept, keep checklist/progress pending. Afterwards
  the workflow's serial documentation/finalization owner updates shared
  progress/indexes. Preserve canonical plan paths while this DAG executes;
  any later archive must preserve planId and original planPath mappings. Never edit another
  worker's append-only progress log; summarize its evidence in the index.

Deliverables: reconciled tree, documentation/examples/help/surface catalog,
manifest audit or refreshed digests, complete verification records and pending
or accepted review handoff. Commit and push of accepted P1 implementation and narrowly required docs/index
updates are authorized; base integration is not requested. Final commit
preparation uses an exact in-scope allowlist and preserves unrelated WIP.

## Final aggregate gates

The following are required after serial repair. Use the exact Xcode binary and
plan-local scratch build; no reliance on a stale globally installed riela.
Record separate complete logs and final exits for each command. Doctor probes
may report unavailable backends normally; do not mislabel those as a failed
mock semantic test or hide a real command failure.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-finalize
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter RielaWorkTests
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter 'WorkStoreReservationTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|ImplementationWorkflowSandboxTests'
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter TaskCommandMutationTests/testDryRunLeavesRuntimeDatabaseByteAndRowEquivalent
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter 'WorkflowRunHelp|WorkflowCommandInspection|DistributedWorkerConfiguration|SurfaceCatalog'
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize
tmp/work-runtime-p1/build/p1-finalize/debug/riela doctor --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela doctor --output text
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow validate codex-design-and-implement-review-loop --workflow-definition-dir .riela/workflows --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow validate task-repair-loop --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1/p1-finalize/examples/task-repair-loop --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1/p1-finalize/examples/task-agent-director --output json
git diff --check
git diff --name-only
```

Run common strict changed/new-file SwiftLint against the UNION of all accepted
intent write sets, not just this worker's docs. Record repository-wide baseline
comparison. Swift full tests include P0 projection/store/show/list and unrelated
loop/routine/specialist regressions: a failing required gate remains blocked,
not accepted based on narrower filters. TaskRuntimeExampleTests must compare
both fixtures' EXPECTED_RESULTS.md outcomes through task dispatch; record positive case
counts. Validate host/usage warning, strict failure and unreachable/called-node
behavior via WorkflowHostCapabilityTests; commands under test must be captured
in test evidence. No live agent credentials required for deterministic gates.

Use a foreground removed-surface audit that distinguishes rg exit 1 (no match)
from exit 2 (tool failure). The removed strings include --auto-improve,
--max-supervised-attempts, --max-workflow-patches, --monitor-interval-ms,
--stall-timeout-ms, --workflow-mutation-mode, --nested-supervisor,
input.autoImprove and input.nestedSuperviser. Audit Sources, README.md, examples,
.riela/workflows, .agents/skills and .codex/skills. Capture every match; classify
by actual workflow-auto-improve context so legitimate specialist/event monitor
options are preserved. Fail any shipped help/request/example/guidance still
advertising removed workflow options. Historical design/completed-plan records
are outside this search. Record explicit matched-path/line justification for
any retained unrelated supervisor option, never a blanket name exclusion.

```bash
python3 - <<'AUDIT'
from pathlib import Path
import subprocess
pattern = r'--auto-improve|--max-supervised-attempts|--max-workflow-patches|--monitor-interval-ms|--stall-timeout-ms|--workflow-mutation-mode|--nested-supervisor|input\.autoImprove|input\.nestedSuperviser'
paths = [p for p in ['Sources','README.md','examples','.riela/workflows','.agents/skills','.codex/skills'] if Path(p).exists()]
r = subprocess.run(['rg','-n','--',pattern,*paths], capture_output=True, text=True)
print(r.stdout, end=''); print(r.stderr, end='')
assert r.returncode in (0, 1), 'removed-surface audit tool failed'
print('MATCHES_REQUIRE_REVIEW' if r.returncode == 0 else 'NO_MATCHES')
AUDIT
```

A MATCHES_REQUIRE_REVIEW outcome is not a passing removal gate until each
match is resolved or explicitly shown unrelated in independent review. This
avoids accidentally deleting accepted P2/P3 behavior to satisfy a string grep.

## Closure criteria and risk record

All P1-0…P1-8 criteria and commands must have complete logs, final exit status,
and required positive test counts. Store/runner cancellation uncertainty stays
fail-closed; declared enable may be usable/unverified by accepted design, with
failed probes visible. Same-directory writes remain vulnerable between hash
checks; independent join review and serial repair are required controls.
Step 3 accepted the current design with no findings; Step 4 inspection and
plan validation do not certify implementation. No hidden user decision is required. Record any actual
blocked runtime/environment checks at implementation time instead of claiming
P1 complete. Archive only after independent acceptance, never to signal that
planning alone finished the feature.

## Verification and completion

Run these commands in the foreground and record final exit status and complete
log paths in the plan-owned progress log. Named new suites below are required
deliverables, not claims that they already exist. Zero selected tests is a
failed gate; record the discovered test names and positive executed counts.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-finalize
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter 'WorkflowRunHelp|WorkflowCommandInspection|DistributedWorkerConfiguration|SurfaceCatalog'
git diff --check
```

Also run the changed-file strict SwiftLint gate defined in the root plan for
this plan's actual Swift write set, including new untracked files. Retain P0
assertions affected by these changes. Each unchecked task below requires its
specified acceptance assertions, passing build/typecheck, focused tests and
lint, complete evidence, and independent review with no unresolved high/mid
finding. Passing this plan alone does not close P1. Report blocked commands
explicitly; never substitute source-text assertions for behavioral tests.

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

## Publication readiness and authorized handoff

The installed workflow owns final Git mutations after acceptance. Before the
plan checkpoint, and again before publication, inspect branch/HEAD/status and
the exact allowlist. Before final push, inspect live origin and upstream:

```bash
git branch --show-current
git rev-parse HEAD
git status --short
git config --get branch.feat/remaining-impl-plans.remote
git config --get branch.feat/remaining-impl-plans.merge
git ls-remote --heads origin refs/heads/feat/remaining-impl-plans
git diff --cached --check
```

Record logs/exits separately. Config exit 1 means missing upstream; a successful
ls-remote with empty output means absent remote branch, not a network failure.
The design found no upstream/local tracking ref; that is not live absence.
Only the authorized finalization path may establish origin's same-name branch
and upstream, without force-push, then verify the accepted commit hash using
the same ls-remote command. If the immutable installed finalizer requires a
pre-existing upstream and cannot perform first publication, return that concrete
blocker and required operator/runtime repair. Never fabricate refs, edit the
package or claim push success. Record committed/pushed hashes and exact ordered
file allowlist. No base-branch integration or unrelated Git mutation is planned.

P1 per-plan JSON records do not currently exist under `impl-plans/progress/plans/`.
Use the six exact paths in writePaths if required by the existing index schema;
do not generate or rewrite unrelated records. Global archiving remains a later
serial action after acceptance with an explicit destination-path assignment.

Use §17.6 and comm-000004 as current planning authority. Reconcile the seven retained source/test files and two retained progress
logs explicitly against accepted owner intents; prior progress is
not acceptance. Review decisions must identify the current source hashes.
Historical Step 2 pending-review text in the design is reconciled during
accepted documentation refresh, without reopening accepted design scope.

## Current acceptance boundary

The current Step 3 runtime delivery accepts the resumed design with no
findings; the design document's historical pending-review prose is not a
new blocker and is preserved until serial documentation refresh. Step 5
plan review remains pending. This plan certifies no predecessor or behavior.
Read the current source and this plan's exact file map before editing; use
current hashes and complete foreground evidence, never historical progress
as implementation acceptance. The Step 4 author check is
`python3 tmp/work-runtime-p1/step4-plan-v0312/self-check.py`; its complete log
and final exit are recorded in the planning evidence above.
