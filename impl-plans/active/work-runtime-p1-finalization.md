# Work Runtime P1: Serial reconciliation, documentation and verification

**Status**: Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete Work Runtime P1 using the accepted dispatcher, guard, and director design
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.5 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review`, `accepted_for_step4_implementation_planning`; no findings or revision request.
**Codex-agent references**: `riela-manager`, `step1-issue-intake`, `step2-design-doc-update`, `step3-design-review`, `step4-impl-plan-create`; downstream installed-package implementation/review executions must record their actual IDs.
**Updated**: 2026-09-21

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
    "Sources/RielaCore/SurfaceCatalog*.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaArgumentParser*.swift",
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
    "impl-plans/progress/plans/**",
    "impl-plans/active/work-runtime-p1-*.md",
    "impl-plans/completed/work-runtime-p1-*.md",
    "Package.swift",
    "Package.resolved",
    "impl-plans/progress/p1-finalize.md"
  ],
  "sharedPaths": [
    "README.md",
    "Sources/RielaCore/SurfaceCatalog*.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaArgumentParser*.swift",
    "design-docs/specs/design-work-runtime-consolidation.md",
    ".codex/skills/riela-impl-workflow/SKILL.md",
    "examples/task-repair-loop/**",
    "examples/task-agent-director/**",
    "impl-plans/README.md",
    "impl-plans/PROGRESS.json",
    "impl-plans/progress/plans-index.json",
    "impl-plans/progress/meta.json",
    "impl-plans/progress/phases.json",
    "impl-plans/progress/plans/**",
    "impl-plans/active/work-runtime-p1-*.md",
    "Package.swift",
    "Package.resolved"
  ],
  "progressLog": "impl-plans/progress/p1-finalize.md",
  "taskIds": [
    "P1-8"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-finalize",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-finalize --filter 'WorkflowRunHelp|WorkflowCommandInspection|DistributedWorkerConfiguration|SurfaceCatalog'",
    "git diff --check"
  ]
}
```

The execution, overwrite protection, evidence, and completion contract in
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` applies to this plan.
No worker edits another worker’s progress log or marks a shared plan complete.


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
  progress/indexes and archives all six plans together. Never edit another
  worker's append-only progress log; summarize its evidence in the index.

Deliverables: reconciled tree, documentation/examples/help/surface catalog,
manifest audit or refreshed digests, complete verification records and pending
or accepted review handoff. No push/base integration is authorized. Final commit
preparation must use an exact in-scope allowlist and preserve unrelated WIP.

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
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1/examples/task-repair-loop --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-finalize/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1/examples/task-agent-director --output json
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
The Step 3 missing independent log is historical disclosure, not an unresolved
accepted-design finding; fresh Step 4 checks do not reconstruct that log or
certify implementation. No hidden user decision is required. Record any actual
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
