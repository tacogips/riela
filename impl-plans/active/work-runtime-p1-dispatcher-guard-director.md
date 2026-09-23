# Work Runtime P1: P1-6b task run and read-only dry-run

**Status**: Current Step 3 design accepted at `comm-000004`; revised Step 4 plan awaiting Step 5. Existing P1-6b implementation has source-matched host verification (194/194); independent implementation/amendment acceptance and publication remain pending.
**Workflow mode**: issue-resolution
**Issue reference**: Work Runtime P1-6b; no GitHub issue number supplied.
**Accepted design**: `design-docs/specs/design-work-runtime-consolidation.md` §17.5, “P1-6b bounded continuation (2026-09-24)”; SHA256 `f83f86ceac6862d926419c791c58f52cd5010afd34f0ad973501a0cf87fc0fc2`.
**Review decision**: Step 3 accepted, no findings or feedback, `comm-000004`, `step3-design-review-attempt-1-exec-4`.
**Codex-agent references**: `codex-design-and-implement-review-loop-session-1`, `step1-issue-intake`, `comm-000002`, `step2-design-doc-update`, `comm-000003`, `step3-design-review`, `comm-000004`.
**Updated**: 2026-09-24

This metadata and the current contract below are the only executable plan for
this invocation. The historical parent material at the end is reference-only:
its broad task list, old baseline, verification and completion requirements do
not authorize work beyond P1-6b. Stable plan ID and progress-log ownership are
preserved. One implementation owner runs the coupled tasks serially; no second
plan or implementation fanout is needed.

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/HostCapabilityResolver.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaSQLite/SQLiteDatabase.swift",
    "Sources/RielaWork/TaskDispatcher.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDryRunReadOnlyTests.swift",
    "Tests/RielaCLITests/TaskRunResultTests.swift",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/HostCapabilityResolver.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaSQLite/SQLiteDatabase.swift",
    "Sources/RielaWork/TaskDispatcher.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDryRunReadOnlyTests.swift",
    "Tests/RielaCLITests/TaskRunResultTests.swift",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md"
  ],
  "progressLog": "impl-plans/progress/p1-dispatch.md",
  "taskIds": [
    "P1-6b-audit",
    "P1-6b-results",
    "P1-6b-readonly",
    "P1-6b-verification",
    "P1-6b-finalization"
  ],
  "taskDependencies": {
    "P1-6b-audit": [],
    "P1-6b-results": [
      "P1-6b-audit"
    ],
    "P1-6b-readonly": [
      "P1-6b-audit"
    ],
    "P1-6b-verification": [
      "P1-6b-results",
      "P1-6b-readonly"
    ],
    "P1-6b-finalization": [
      "P1-6b-verification"
    ]
  },
  "dependencyMode": "single-plan-ordered-internal-gates",
  "acceptedPrerequisite": {
    "taskId": "P1-6a",
    "commit": "2f10916a14501af68fd7e7f63cb91f244a343f8c"
  },
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandParsingTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'",
    "xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6b/changed-swift-files.nul",
    "git diff --check",
    "git diff --cached --check"
  ],
  "evidenceDirectory": "tmp/work-runtime-p1/p1-6b/",
  "verificationPolicy": "Reuse source-matched completed gates. Run affected build/test/lint commands only after code changes or a material evidence gap; always recheck hashes and diffs.",
  "hostAggregateCommand": "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --disable-sandbox --skip-update --scratch-path tmp/p1-6a-host-verify/build --filter 'TaskCommandParsingTests|TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests|BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|TaskRunResultTests|TaskDryRunReadOnlyTests|WorkStoreTests|TaskCommandTests|SQLiteDatabaseTests'"
}
```

## Current P1-6b executable contract

### Intent, context, and non-goals

Independently review and conditionally finalize the existing task-run result and
allocation-free dry-run WIP on `feat/remaining-impl-plans`, planning checkpoint
`f8c91887d4021ccd3ebfec5dda39cbc555b6b040`, retaining accepted P1-6a dispatch.
The nine Swift changes and plan/progress/design edits already exist; preserve
them. Recheck actual status before review; never reset changes. Coding may be
re-dispatched only for an independently proven material defect.
The supplied effective workflow input and runtime provenance are authoritative.
Do not inspect the executing package or scoped registries.

No director, human-decision/cancellation redesign, legacy removal, new examples,
new schema, general persistence framework, new dependency, broad formatting,
main merge, worktree creation or unrelated baseline repair is authorized.
P1-6c/d, P1-7a/b and parent P1 remain open. Existing examples are regression
fixtures only. Preserve other sessions/worktrees, including Monja tenant-sharding-d48.
Codex references are workflow identities; no Cursor adapter or source-parity task applies.

### Ownership, dependencies, and safe edits

`dependsOn: []` means no newly scheduled external plan; P1-6a is an accepted
prerequisite at the commit above, not work to rerun or reopen. The metadata DAG
orders evidence audit → result/read-only reviews → combined verification →
conditional finalization. Native Riela owns dependency-ready review waves;
this node creates no implementation fanout.
All listed paths are exclusively owned by this single implementation owner;
reviewers inspect without edits. The write set is a ceiling, not a demand to
change every file. All code/test edits are conditional on an independently proven material defect.
The two focused test files already exist and are included in host evidence. No other path is implicitly writable: a needed
path expansion requires a concrete finding, exact path and bounded plan/review
amendment before editing, not a blanket new abstraction or unrelated repair.

Bounded Step 6 scope amendment: `TaskDryRunReadOnlyTests` observed a changed
SQLite `-shm` byte snapshot on every seeded preview. Review the existing change to
`Sources/RielaSQLite/SQLiteDatabase.swift` only to recognize a zero-byte WAL
as idle for immutable reads. A nonempty WAL is diagnosed by task preview before
opening the store, so committed WAL data is never silently ignored. Independent
review must accept this path expansion and the final byte/row evidence.

Before each edit, fresh-read the file and capture SHA256 plus an immutable
intent snapshot under `tmp/work-runtime-p1/p1-6b/attempt-N/` recording intended
hunks and accepted requirement. Record post-edit hashes. Compare predecessor
hashes at every handoff; preserve unexpected changes, invalidate affected
verification, and reconcile serially instead of restoring whole files. No
concurrent Git operations or private implementation branches. For this existing-WIP
continuation, the design and this revised plan must be accepted before any
conditional repair. No new pre-implementation commit is required. Commit the
exact reviewed P1-6b file set only through downstream finalization after
independent implementation acceptance; this author node neither commits nor
preempts Step 5. This continuation-specific order supersedes the historical
checkpoint procedure in the non-executable parent reference below.

Workers append only to `impl-plans/progress/p1-dispatch.md`. Shared indexes,
lockfile generation, formatting and global archiving are reserved for serial
finalization and are unnecessary for this slice. Never archive this parent plan.
If native join supplies change evidence, the serial integration owner compares
all intended hunks and hashes and repairs overwritten accepted behavior before
independent combined-tree review.

### Tasks and exact deliverables

All boxes below are current review/finalization gates, not instructions to redo
prior coding. Historical completed implementation remains recorded in progress.

- [ ] **P1-6b-audit** (wave 1, single owner): Fresh-read accepted §17.5, the nine
  Swift files in `writePaths`, both exact manifests and complete host log.
  Recompute nine hashes, inventory current diff/untracked files and record
  source identity plus the host command/exit 0/194 tests. Preserve the earlier
  sandbox aggregate as failed, exit 1, including intermediate assertion failures.
  Deliver an evidence inventory and review inputs in repository-root `tmp/`.
- [ ] **P1-6b-results** (wave 2, independent test-integrity review, read-only):
  Inspect `Sources/RielaCLI/TaskDispatch.swift`,
  `Tests/RielaCLITests/TaskCommandParsingTests.swift`,
  `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`, and
  `Tests/RielaCLITests/TaskRunResultTests.swift`. Trace text/JSON placement,
  ready/wait without allocation, typed reasons, nonzero failure exits,
  pre-admission failure envelopes and exact durable reserved attempt/session
  IDs after admitted errors. Inspect read-only fixtures and snapshots in
  `Tests/RielaCLITests/TaskDryRunReadOnlyTests.swift` for real APIs, complete
  row values and nonmutating observation. Deliver findings with severity,
  paths, concrete evidence and an explicit SQLite amendment accept/reject
  decision; no edits or inferred pass from row counts alone.
- [ ] **P1-6b-readonly** (wave 2, independent adversarial review, read-only):
  Trace `Sources/RielaCLI/TaskDispatch.swift`,
  `Sources/RielaCLI/HostCapabilityResolver.swift`,
  `Sources/RielaWork/TaskDispatcher.swift`, `Sources/RielaWork/WorkStore.swift`
  and `Sources/RielaSQLite/SQLiteDatabase.swift`. Verify no writable fallback,
  initialization, migration, checkpoint, quarantine, profile persistence,
  reservation, pending-request consumption or launch on preview. Assess
  absent/corrupt/incompatible stores, profiles and sidecars; byte/inventory and
  row-value invariance includes `work_hosts`. Corrupt undecodable data requires
  diagnostic and byte invariance, with row comparison explicitly inapplicable.
  Assess zero-byte/absent WAL handling, rejection of nonempty WAL before either
  store opens, shared-reader compatibility and concurrent-writer races. Deliver
  a separate explicit SQLite amendment accept/reject decision and material
  findings supported by evidence, not hypothetical hardening requests.
- [ ] **P1-6b-verification** (wave 3, serial join and independent Astra
  combined-tree integration review): Join both reports and recheck all hashes.
  Astra explicitly decides the SQLite amendment and combined result/placement/
  reservation contract against accepted §17.5 and P1-6a regression evidence.
  All three reviews must have no unresolved material correctness, data-loss,
  security or verification defect. Only an independently demonstrated defect
  authorizes a serial repair: record finding, exact affected paths, pre/post
  hashes and intent; change the smallest required behavior/test in the allowlist,
  rerun affected compile/tests/lint below, then repeat affected independent
  reviews on the repaired tree. If another path is necessary, obtain a bounded
  plan/review amendment first. Preserve unexpected drift and reconcile serially.
  Unchanged bytes reuse completed host gates; never rerun solely because this
  is a new workflow. Deliver final hash manifest and all three review decisions.
- [ ] **P1-6b-finalization** (wave 4, downstream serial workflow gates): After
  acceptance, align §17.5 and P1-6b plan/progress evidence only. Review README
  for accuracy; edit only if a concrete discrepancy warrants an exact amendment.
  Append commands, terminal exits, positive suite counts, complete logs, hashes,
  retained-code attribution and independent decisions to
  `impl-plans/progress/p1-dispatch.md`. Step 9 explicitly records P1-6c/d,
  P1-7a/b and parent P1 open and retains this active plan. Emit the exact reviewed
  file allowlist (nine Swift files plus directly affected design/plan/progress;
  exclude already committed checkpoint-only docs from a later commit).
  Native commit/push gates publish only accepted files, non-force to
  `origin/feat/remaining-impl-plans`, verifying matching accepted commit/push
  evidence. No broad staging, tmp files, force push, main merge or unrelated
  worktree changes. No workflow/prompt/script/skill change or digest refresh.

### Invariants and acceptance matrix

| Accepted requirement | Passing evidence |
| --- | --- |
| CLI parsing and typed text/JSON | Valid and invalid parsing; shared option precedence; text placement; typed diagnostics; correct nonzero failure exits |
| Exact identity and wait reason | Output IDs equal reserved durable rows on successful and failed admitted runs; ready/wait allocate nothing; wait reason matches dispatcher |
| Read-only dry-run | Same resolution/prospective placement, all byte/inventory/row-value checks unchanged across the matrix above; no misleading stale WAL read |
| P1-6a preserved | Final-source reservation and selected-worker/callee execution regression gates pass |
| Bounded publication | Independent test-integrity/adversarial/Astra integration acceptance, including the SQLite amendment, without unresolved material finding, exact file allowlist, matching committed/pushed hash; later slices open |

A preview is not a launch promise: real admission still rechecks dependency,
version, budget and capacity races. Do not add a second direct-mutation path or
weaken authentication, placement pinning, reservation tokens or uncertainty fences.

### Exact verification and evidence

All commands run in the foreground from repository root. Capture full stdout
and stderr, exact argv/environment, start/end timestamps, terminal exit code,
per-suite positive test counts and final relevant source SHA256 inventory in
`tmp/work-runtime-p1/p1-6b/attempt-N/verification-evidence.json`. Use immutable
numbered attempts, the log names below and the existing shared scratch path;
never run SwiftPM gates concurrently against it. Poll every yielded session
through terminal exit. Incomplete logs, timeouts and zero/absent selected suites
are failed/blocked checks, never passes. Reuse only evidence matching final
relevant sources and fixtures; unrelated documentation edits alone do not
invalidate Swift tests. The recorded host pass is reused evidence, not a fresh run by this plan author.
The commands below are conditional rerun gates; do not execute them all by
default on unchanged source bytes. The host aggregate in metadata includes
`SQLiteDatabaseTests`, both focused files, V1/V2/V4/V11 and parsing; use its
exact command for a full affected aggregate rerun on a listener-capable host.
A listener-denied run remains failed; retain its complete log and exit.

**Always-run source identity — hash-check.log**

Run this command before reviews and again before finalization. Capture its full
output and exit; any mismatch invalidates affected evidence and requires drift
reconciliation before acceptance. A documentation-only change does not invalidate
these nine Swift hashes.

```bash
python3 - <<'HASHCHECK'
import hashlib, json
from pathlib import Path
host = json.loads(Path("tmp/work-runtime-p1-6b-host/evidence.json").read_text())
prior = json.loads(Path("tmp/work-runtime-p1-6b-20260924-2f10916-comm000006/plans/p1-dispatch/attempt-1/verification-evidence-exact.json").read_text())
assert len(host["sourceHashes"]) == 9
for path, expected in host["sourceHashes"].items():
    actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    print(path, actual, flush=True)
    assert actual == expected == prior["sourceHashes"][path], path
print("PASS: 9/9 hashes match both manifests")
HASHCHECK
git diff --check
git diff --cached --check
```

Record each command's own exit code, not only the last shell command. Inspect
`tmp/work-runtime-p1-6b-host/aggregate.log` and the prior manifest's complete
logs; record the host aggregate's exact metadata command, exit 0, 194/194 and
per-suite counts separately from the failed sandbox run. The hash comparison
alone is not behavioral acceptance. Repaired bytes require a new manifest;
never overwrite the original evidence or claim old hashes match new code.

**V0 compile/typecheck — build.log**

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
```

**Parsing — parsing-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandParsingTests'
```

**V1 focused behavior — focused-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
```

**V2 reservation regression — reservation-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests'
```

**V4 capabilities/profile regression — capability-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
```

**V11 selected-host regression — selected-host-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
```

V1 retains each named suite, including existing task examples; it does not
certify later slices. Require positive counts for each selected suite. V2 proves
reservation/cancellation/budget compatibility. V4 proves placement and profile
read compatibility. V11 proves real selected-host and exact-session behavior.
The two focused test files are already present. If their evidence is invalidated,
run their gate and require a
positive count for each created suite (adjust the filter to the created names
and record exact argv; never report a missing suite as passing):

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'
```

If store evidence is invalidated, also run:

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreTests|TaskCommandTests|SQLiteDatabaseTests'
```

Before lint, build `tmp/work-runtime-p1/p1-6b/changed-swift-files.nul` from the
reviewed exact changed/new Swift paths relative to the accepted implementation
baseline; include newly created files, exclude unrelated changes, record the
list in evidence and require it nonempty. Never invoke xargs with an empty list.
**Strict changed-file lint — swiftlint.log**:

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6b/changed-swift-files.nul
git diff --check
git diff --cached --check
```

Capture diff checks as `diff-check.log` and `cached-diff-check.log` respectively;
the cached check is repeated by finalization after accepted staging. Inspect
changed Swift file sizes and keep files within the skill's 1000-line rule using
the named focused test files, without broad unrelated extraction. Build/tests
must compile touched modules. Broaden only for a concrete shared-path risk or
new failure; record exact additional command and reason. Pre-existing failures
remain failures: require an explicit independent bounded disposition, never
suppress them, count a failed gate as passing or repair unrelated baseline work.

### Completion and progress state

| Item | State at authoring |
| --- | --- |
| P1-6a | Accepted prerequisite at 2f10916; preserve |
| P1-6b | Revised plan awaits Step 5; final-source host aggregate passed 194/194, including listener-backed selected-host/HTTP cases. Independent reviews and publication remain pending. |
| P1-6c/d, P1-7a/b | Deferred/open |
| Parent P1 | Open; no global certification or archiving |

No unresolved user decision or design defect was identified. Progress entries
must distinguish source inspection, actual verification and independent
acceptance; record exact retained files, concrete repairs, hash drift and
invalidated/reused evidence. Design/plan acceptance is not implementation
acceptance. Finalization requires all scoped acceptance rows and reviewer
findings resolved, matching final-source evidence and exact accepted publication.

Operator-host follow-up after Step 6 terminal (2026-09-24): the nine Swift
source/test hashes in `tmp/work-runtime-p1-6b-host/evidence.json` match Step 6's
`verification-evidence-exact.json` before and after the host run. Using the
already resolved SwiftPM scratch path, the full P1-6b selected aggregate,
including listener-backed `TaskDispatcherIntegrationTests` and
`DistributedWorkerHTTPTests`, passed 194/194 with exit 0. The complete command,
log and exit are in `tmp/work-runtime-p1-6b-host/evidence.json` and
`aggregate.log`; `git diff --check` passed. This replaces the sandbox-only V11
verification gap for these unchanged source bytes, but it is not independent
review or publication acceptance. The SQLite shared-path amendment, remaining
P1 slices and parent P1 still require their own decisions.

## Historical parent-plan reference — not executable in this invocation

The following pre-P1-6b parent narrative is retained to preserve later work and
historical evidence. Its former scope, unchecked P1-6a status, predecessor
inventories and broad gates are superseded for this invocation by the current
contract above. Do not schedule, certify, update indexes for, or execute its
later tasks as part of P1-6b. Historical metadata is available in Git at
`2f10916a14501af68fd7e7f63cb91f244a343f8c` under this same plan path.

## Intent, authority and repository context

Complete every unchecked P1-6a–d and P1-7a–b requirement by reconciling retained
implementation, including necessary reservation, guard, capability and shared
applier repairs. Accepted design §17.7 governs this single plan; older six-plan
scheduler metadata is historical. The complete effective implementation input
is this file alone. `dependsOn: []` means no external scheduler predecessors;
it does not waive the internal prerequisite gates below. Supporting reservation,
guard/director, capability and finalization plans supply reference detail only;
do not launch or implement them as additional work packages.

Inspected HEAD is `f46ff788d522b6e53631862253fdcbcf17adfb1a` on
`feat/remaining-impl-plans`, also the deliberate base branch; supplied upstream
is `origin/feat/remaining-impl-plans`. Preserve the intake’s 93 retained files
(49 tracked, 44 untracked, zero staged) and the accepted Step 2 design edit.
Step 4 therefore starts with 50 tracked changes and 44 untracked files; its
plan edit adds one tracked change. The older 50/44 inventory predates the
f46ff788 checkpoint; reconcile exact paths/hunks rather than using counts
as ownership evidence. These include
dispatch, capability and example code. The CLI still rejects
`.director` dispatch in `Sources/RielaCLI/TaskDispatch.swift`; the retained
`AgentDirector.validate` escalates all accept output. Reconcile these concrete
P1-6d gaps; do not replace retained code wholesale or certify it from inventory.
Step 4 edits only this plan and preserves all prior source/design/progress work.

Runtime provenance is authoritative. Effective input requires the immutable
user-scope workflow package and supplies no minimum or exact version.
No contradiction exists; do not inspect, repair or validate registries or the
executing package from this node. No worktrees, private branches, concurrent
Git mutations, or changes to other directories/sessions. Preserve all unrelated
work and Monja tenant-sharding-d48. Commit/push of accepted P1 and necessary
documentation are authorized; finalization remains gated below.

Non-goals: P2–P7, loop-engineering, agent-node-output-contract, workflow defect
detection, Tauri, Note, gateway SDK, Monja implementations, task serve, new task-create CLI, remote
authentication, planner frameworks, compatibility/migration for removed
auto-improve state, recursive director repair, proposals, specialist classifiers,
optional hardening, style-only changes, broad cleanup or formatting. Preserve
accepted workflow-defect documents. Record external dependencies rather than
absorbing them. The supplied local Codex reference root
`../../codex-agent` is absent in accepted design evidence. Agent references are
execution provenance, not parity claims. Cursor-specific invocation/auth/probe/
heartbeat behavior stays in existing adapters; no cross-backend equivalence.

## Internal dependency gates and ownership

One implementation integration owner executes this plan. The DAG in metadata
orders tasks within this package; it is not a list of missing external plans.

| Wave | Tasks | Deliverable / gate |
| --- | --- | --- |
| 0 | P1-AUDIT | Fresh retained-diff attribution, source hashes, lint baseline, existing interface inventory; run canonical sandbox regression without editing workflow/package artifacts. |
| 1 | P1-PREREQ-R | Verify/repair only reservation primitives needed by §17.2: atomic rollback, dependency/version race, unique exact session, single-use digest token, uncertain launch fence, pending request consumption and durable cancellation acknowledgment. V2 and relevant store tests pass. |
| 2 | P1-PREREQ-L | Verify/repair §17.2–17.3 guard, deterministic ordering, causality, replay, store completion and budget enforcement. V3 passes against accepted reservation hashes. |
| 2 | P1-PREREQ-C | Verify/repair §17.4 reachable requirements, bounded probes, declarations, freshness, placement and host/planner inputs. V4 passes against accepted reservation hashes. |
| 3 | P1-6a, then P1-6b/c | Wire real exact-session dispatch, preview and human decisions; prerequisite checks must already pass. |
| 4 | P1-6d | Bounded child execution and authoritative judged-work acceptance; focused store, director and CLI integration checks pass. |
| 5 | P1-7b, then P1-7a | Task-backed examples and before-removal replacement evidence, then legacy removal and after-removal evidence. |
| 6 | P1-FINAL | Serial join/repair, aggregate tests/lint, author self-review, single adversarial implementation review, combined-tree review, docs/index reconciliation and final publication handoff. |

Independent investigation of lifecycle and capabilities may run in parallel
only after reservation interfaces are stable. Implementation overlap in schema,
store, CLI and tests is serialized, even within the same wave. P1-6b/c may use
parallel read-only investigations; the integration owner writes their shared
files. Child investigators return evidence to this plan's owner, who alone
appends `impl-plans/progress/p1-dispatch.md`. Do not edit another worker's log.
No additional executable plan files are created for tightly coupled repairs.

Each prerequisite handoff records source hashes, concrete interface signatures,
owner, exact passing command/log/final exit, positive suite counts and review
status. Inspect current code before deciding repair is needed. Unchanged code
can pass with fresh behavioral evidence; never invent changes or accepted IDs.
Failure blocks dependent tasks, while independent investigation may continue.
The canonical sandbox check concerns checked-in real payloads only; a failure
outside accepted P1 scope is reported as a dependency with command/log/exit,
not repaired through package rediscovery or unrelated workflow implementation.

After Step 5 accepts, the serial workflow checkpoint gate commits exactly the
accepted design and this plan before any native implementation/review fanout.
It preserves the existing index and excludes retained source, tests, progress
and scratch. Push that checkpoint before final git-push so exactly one
unpublished final commit remains. Record the checkpoint hash and publication
evidence; do not leave checkpoint commits stacked below an unpublished final
commit. This Step 4 neither commits nor certifies implementation. Later
final commit/push contains only accepted P1 implementation and necessary docs.

## Edit integrity and evidence ownership

Before EVERY edit, including deletion and retry, fresh-read the file and
contract; record pre-edit SHA-256 (or absent sentinel), original bytes, exact
paths, accepted requirement and intended behavior under immutable numbered
`tmp/work-runtime-p1/p1-dispatch/intents/` directories. Recheck hash immediately
before writing. On drift, stop, reread and create a new intent; never overwrite
from stale buffers. Record post-hash, exact diff and preserved behaviors.
After join, compare semantic changes to intents, repair serially and rerun
invalidated gates. Hashing alone cannot eliminate races; runtime change evidence
and independent combined-tree review remain required if work fans out.

Materialize exact paths from metadata globs before edits; metadata is a scope
ceiling, not permission to modify unrelated hunks. Necessary helper extractions
require exact-path ownership and accepted-requirement evidence first. Keep
builds/source verification stable: serialize commands against a stable source
snapshot and compare relevant source hashes before/after each run. A source
change during testing invalidates certification. Lockfile changes, all shared
indexes, final commit allowlist and any archiving are serial-only. No broad
formatting; no global archive or unrelated lockfile update is needed here.

## Prerequisite file-level repair map

The exact paths below belong to this plan's serial integration owner only for
necessary P1-6/7 prerequisite repair. Prefer proving retained code correct.

### P1-PREREQ-R

Atomic attempt/session/lease/decision placement commit, rollback, launch token, pending request and cancellation fencing. Preserve schema generation policy and P0 reads; use task-owned scratch stores, never reset user databases.

Exact repair/test paths:

- `Package.swift`
- `Sources/RielaWork/WorkModels.swift`
- `Sources/RielaWork/WorkStore.swift`
- `Sources/RielaWork/WorkStore+Schema.swift`
- `Sources/RielaWork/WorkStore+Reservation.swift`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
- `Tests/RielaWorkTests/WorkStoreTests.swift`
- `Tests/RielaWorkTests/WorkStoreReservationTests.swift`
- `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`
- `Sources/RielaWork/DecisionApplier.swift`
- `Sources/RielaWork/WorkStore+Decisions.swift`

### P1-PREREQ-L

Persist complete guard batch before action; stable priority/tie order, exact equality boundaries, last-admitted-attempt completion, budget admission, scoped causality, original replay and store-reconstructed completion. Human acceptance waives only requiresHumanAccept.

Exact repair/test paths:

- `Sources/RielaWork/WorkGuard.swift`
- `Sources/RielaWork/TaskGuardCoordinator.swift`
- `Sources/RielaWork/DeterministicDirector.swift`
- `Sources/RielaWork/DecisionApplier.swift`
- `Sources/RielaWork/CompletionEvaluator.swift`
- `Sources/RielaWork/WorkStore+Decisions.swift`
- `Sources/RielaWork/WorkDecision.swift`
- `Sources/RielaWork/WorkEvidence.swift`
- `Tests/RielaWorkTests/WorkGuardTests.swift`
- `Tests/RielaWorkTests/WorkGuardDispatcherTests.swift`
- `Tests/RielaWorkTests/DeterministicDirectorTests.swift`
- `Tests/RielaWorkTests/DecisionApplierTests.swift`
- `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`
- `Tests/RielaWorkTests/CompletionEvaluatorTests.swift`

### P1-PREREQ-C

One reachable/called-node requirement set and merged finite-freshness snapshot; disable wins, explicit unprobed enable stays unverified, failed refresh is not stale success, pin never falls back, declared capacity/liveness and required executables/environment are enforced. Host/profile reads stay nonmutating for dry-run.

Exact repair/test paths:

- `Sources/RielaCore/BackendCapability.swift`
- `Sources/RielaCore/WorkflowBackendPolicy.swift`
- `Sources/RielaCore/WorkflowRequirements.swift`
- `Sources/RielaCore/WorkflowModel.swift`
- `Sources/RielaCore/WorkflowNodeValidation.swift`
- `Sources/RielaCore/WorkflowValidationHelpers.swift`
- `Sources/RielaCore/DistributedWorkerModels.swift`
- `Sources/RielaAdapters/BackendCapabilityProbe.swift`
- `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`
- `Sources/RielaWork/BackendCapabilityPlacement.swift`
- `Sources/RielaWork/WorkStore+Hosts.swift`
- `Sources/RielaWork/WorkStore+Schema.swift`
- `Sources/RielaCLI/DoctorCommand.swift`
- `Sources/RielaCLI/DistributedWorkerCommand.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift`
- `Sources/RielaCLI/HostCapabilityResolver.swift`
- `Sources/RielaServer/DistributedWorkerProtocol.swift`
- `Sources/RielaServer/DistributedWorkerHTTPRouter.swift`
- `Sources/RielaServer/DistributedWorkerHTTPClient.swift`
- `Tests/RielaWorkTests/BackendCapabilityPlacementTests.swift`
- `Tests/RielaCLITests/DoctorBackendCapabilityTests.swift`
- `Tests/RielaCLITests/WorkflowHostCapabilityTests.swift`
- `Tests/RielaCLITests/DistributedWorkerConfigurationTests.swift`
- `Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift`
- `Tests/RielaAdaptersTests/BackendCapabilityProbeTests.swift`
- `Sources/RielaAppSupport/DaemonWorkflowSupport.swift`
- `Sources/RielaAppSupport/RielaAppDaemonWorkflowStore.swift`
- `Tests/RielaAppSupportTests/HostCapabilityConfigurationTests.swift`

Additional retained integration paths are `Sources/RielaCLI/WorkflowValidationOptions.swift`,
`WorkflowCalleeResolution.swift`, `ServeHTTPCommand.swift` (all RielaCLI),
`Sources/RielaCore/WorkflowValidation.swift`, `DistributedJobController.swift`
(RielaCore), `Sources/RielaServer/DistributedControllerHost.swift`,
`DistributedWorkerLoop.swift` (RielaServer), and
`Sources/RielaApp/EntryPoint+DistributedController.swift`. Verify only capability
snapshot registration/forwarding and selected host/backend execution in those
paths; no UI redesign or distributed subsystem redesign. Required matching
regressions include `Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`.
Add retained `WorkStoreCancellationTests`, `BudgetAdmissionStoreTests` and
`DecisionApplierCausalityStoreTests` under `Tests/RielaWorkTests` to prerequisite
gates so aggregate filters cannot hide these new regressions.

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
identify retained code or intended repair destinations; fresh-read actual APIs. Fresh-read existing
neighbors and accepted predecessor signatures before implementation; reuse
existing functions and avoid a generic framework. Extra helpers are allowed
only for necessary responsibility splits, with an exact-path serial assignment
and intent record first. The JSON writePaths list never authorizes unrelated
changes to a matched file. Prerequisite repair paths are assigned above; ownership transfers remain serial.

| Task / files | Intended change / required evidence |
| --- | --- |
| P1-6a: retained `Sources/RielaWork/TaskDispatcher.swift`; retained `Sources/RielaCLI/TaskDispatch.swift`; existing `WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift` in Sources/RielaCLI | Work coordinates accepted requirement/placement/reservation/decision contracts; CLI resolves canonical definition/store and bridges to existing runner using the reserved session ID and per-node host/backend. Project terminal evidence before completion/guard evaluation. Reuse runner execution; no RielaCore import of RielaWork. TaskDispatcherTests and TaskDispatcherIntegrationTests prove exact reserved ID, version/dependency races, wait without attempt/session/lease, stale launch rejection and projection-before-decision. |
| P1-6b/c: `Sources/RielaCLI/TaskCommands.swift`, `TaskCommandModels.swift`, `RielaCommand.swift`, `RielaArgumentParser+WorkflowAndMemory.swift`, retained `TaskDispatch.swift` | Add run/dry-run/decide parsing, typed result DTOs and text/JSON output. Preserve show/list and store-root precedence. Dry-run must select read-only dependency APIs before any loader that initializes/migrates/quarantines. Decide validates exactly one action, principal, expected version and stable ID. Route Ctrl-C through durable applier/runner cancellation, including pending-launch and acknowledgment windows. No second direct-mutation path. TaskCommandMutationTests and TaskCommandParsingTests assert parsing, replay and filesystem/row invariance. |
| P1-6a/c/d shared serial handoff: `Sources/RielaWork/WorkStore+Decisions.swift`, `TaskGuardCoordinator.swift`; `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`, `WorkGuardDispatcherTests.swift` | Consume and regression-test the accepted lifecycle implementation of scoped causality, reconstructed completion, original replay, atomic pending requests and live cancellation fencing. Only add narrowly necessary real-runner coordination after ownership transfer; complete lifecycle prerequisite repairs before dispatch integration. Coordinator must preserve complete guard-batch persistence before decisions. If durable outcome storage needs schema/model changes, assign the existing store/schema files to the serial integration owner and use existing storage; do not invent parallel storage. Add negative/rollback/crash/replay tests, not CLI-only checks. |
| P1-6d: retained `Sources/RielaWork/AgentDirector.swift`; `TaskDispatcher.swift`, `Sources/RielaCLI/TaskDispatch.swift` | One ordinary child workflow only when configured escalation needs it. Reconcile judged work before .director reservation; retain its TaskView; charge child attempt/session/cost once and use the same applier. Forward the accepted capability snapshot through planner workflow variables; no new planner. TaskDispatcherTests/TaskDispatcherIntegrationTests prove host input and selected backend delivery, last-admitted-attempt completion, invalid/forbidden/failed/budget-blocked child escalation and no recursion. Deterministic ordering is certified in P1-PREREQ-L. |
| P1-7a: `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift` (delete after barrier), `RielaCommand.swift`, `ParsedWorkflowOptions.swift`, `RielaArgumentParser+WorkflowAndMemory.swift`, `WorkflowCommands.swift`, `WorkflowRunCommand.swift`, `ProductionNodeAdapter.swift`, `RielaCLIApplication.swift` | Remove actual policy/mutation types in RielaCommand, flags, option plumbing, execution branch, remote serialization and scenario wrapper. SupervisedScenarioNodeAdapter actually lives in RielaCLIApplication.swift (not an Adapters file). Reject removed autoImprove/nestedSuperviser remote fields rather than ignoring or forwarding them. Keep normal run, mock scenario and authenticated remote paths intact. Rewrite legacy tests as rejection/preservation regressions only after replacement coverage passes. |
| P1-7a conditional retained call sites: `Sources/RielaCLI/SessionCommands.swift`, `SessionCommandModels.swift`, `RielaCommand+SessionParsing.swift`, `LoopCommands.swift`; `Sources/RielaCore/DeterministicWorkflowRunner.swift` | Remove only obsolete supervision plumbing/result fields tied to the deleted workflow path. Preserve loop/routine and specialist/event behavior and their stores; do not delete symbols merely for containing supervisor. Inspect callers/consumers before removal; contradictory retained behavior is a dependency blocker, not permission to redesign another plan. A newly discovered remote decoder outside listed paths requires exact serial ownership assignment before its narrow removed-input rejection edit and tests. |
| P1-7a regressions: `Tests/RielaCLITests/CommandParsingTests.swift`, `WorkflowCommandAutoImproveTests.swift`, `WorkflowCommandInspectionTests.swift`, `WorkflowCommandPackageLifecycleTests.swift`, `RielaExampleParityTests.swift`, `WorkflowRunHelpTests.swift` | Preserve equivalent scenarios in the four new dispatcher suites before deleting old tests. Assert removed flags/remote fields fail, plain runs create no task, help and package examples match; keep specialist supervisor, events, routines and loops green in V5. |
| P1-7b: `examples/task-repair-loop/` and `examples/task-agent-director/` each with `workflow.json`, required referenced `nodes/` and `prompts/`, `mock-scenario.json`, `EXPECTED_RESULTS.md`, `README.md`; `Tests/RielaCLITests/TaskRuntimeExampleTests.swift` | Minimal deterministic bundles; tests create task fixtures through existing store APIs then drive actual task run/decision lifecycle with mock node execution, not merely workflow run or string assertions. Document acceptance, gate recovery, guard stop, capacity wait, bounded child output/accounting/escalation. Remove only the three legacy directories after V1 before-removal passes. No new task-create CLI. |

The four required suites are exactly
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
  Latest-work verification/gates (with only the persisted bounded-child exception below) and applicable blocking findings govern
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


## Resumption execution detail from accepted §17.7

These tasks complete the retained implementation; they do not restart it or
certify existing checkmarks. Step 3 accepted this revision with empty findings
and feedback; no Step 5 revision request was delivered. Preserve the prior
attempt evidence in `impl-plans/progress/p1-dispatch.md`, including attempt 3
from `nested-v1-f637160bee4a0e57484a92a8400c09a6a58ec7ccbb82ac72bb5ebee0ca2d68ae`
and its logs under `tmp/p1-dispatch-step6-attempt3/`. The second workflow run
ended at `implementation-blocked-output`; neither its findings nor partial
passing suites certify the implementation or exhaust the remaining paths.
Use new numbered evidence directories; never overwrite prior logs.

Retained source now resolves reachable workflow/add-on requirements and sums
wall-clock durations from exact durable attempt sessions. Preserve these changes
and reverify them rather than reimplementing from the older gap inventory.
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` already supplies
`agentSandbox: .readOnly` in the previously failing callee fixture. V1 must
rerun that case and the cumulative wall-clock case on final source; a historical
passing rerun is not final acceptance.

### P1-AUDIT and P1-PREREQ-L: data flow beyond the reported gaps

Fresh-read `Sources/RielaCLI/TaskDispatch.swift`,
`Sources/RielaWork/TaskGuardCoordinator.swift`, `WorkGuard.swift`,
`DeterministicDirector.swift`, `WorkEvidence.swift` and `WorkStore+Decisions.swift`
(the last five under RielaWork). Trace cumulative wall-clock, token accounting,
repeated findings, gate visits and live heartbeat input from actual attempts
into guard evaluation. Inventory every unchecked criterion, its current test
and missing behavior. Reconcile the progress log's older claims against source.
Repair only broken accepted contracts. Extend `Tests/RielaWorkTests/WorkGuardDispatcherTests.swift`
and `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` to prove cumulative
multi-attempt budgets, repeated findings, stable simultaneous-violation order,
inactivity and successful completion of the last admitted attempt. No new
attempt may evade budget through human, agent or warning paths. V1/V3 must
exercise these cases; helper-only guard tests cannot certify dispatch input.
For repeated findings, use the existing fingerprint identity across real task
attempts; assert the configured equality threshold persists the violation and
applies the ordered decision, while replay neither duplicates evidence nor
counts the same observation again. For inactivity, drive a configured
heartbeat-capable backend through the live runner with a deterministic clock;
assert threshold-triggered cancellation is durably acknowledged before any
replacement admission. Include below-threshold and SDK-exemption cases, and
assert heartbeat loss alone cannot release the one-live-attempt fence. Route
signals through existing runner/guard seams; do not add a monitoring service.


### P1-6a: called workflow and selected-host delivery

1. In `Sources/RielaCLI/TaskDispatch.swift`, use existing
   `WorkflowCalleeResolution.swift` to supply reachable called bundles to
   `Sources/RielaCore/WorkflowRequirements.swift`, including add-on/environment
   requirements. Resolve from the actual entry; preserve returns/joins and
   workflow/step/node provenance, exclude reused prefixes/unreachable nodes,
   visit cycles once and diagnose unresolved executable targets before reserve.
2. In `Sources/RielaCLI/HostCapabilityResolver.swift` and TaskDispatch, replace
   the local-only/no-workers composition with the existing configured topology.
   Preserve explicit worker/group assignments and one fresh merged evaluation.
   Use `Sources/RielaWork/BackendCapabilityPlacement.swift` and existing host
   storage; no new capability registry. Waits create no attempt/session/lease.
3. In `Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift`,
   `WorkflowRunCommand.swift` and `WorkflowCalleeResolution.swift`, carry chosen
   host/backend/model into root and callee execution rather than rejecting all
   nonlocal/callee choices or filtering them out. Reuse configured distributed
   execution and existing authentication. Retain exact reserved session identity
   and single-use launch admission; deliver the snapshot through planner inputs.
4. Inspect and narrowly repair the existing distributed paths already listed:
   `Sources/RielaCore/DistributedJobController.swift`,
   `Sources/RielaServer/DistributedWorkerProtocol.swift`,
   `DistributedWorkerHTTPClient.swift`, `DistributedWorkerHTTPRouter.swift`,
   `DistributedWorkerLoop.swift` and `DistributedControllerHost.swift` (Server).
   Record an exact serial ownership intent before any additional seam is edited.
   Worker loss after admission cannot authorize local fallback or duplicate
   launch; preserve uncertainty fencing and durable session evidence.
5. Extend `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`,
   `WorkflowHostCapabilityTests.swift` (CLI),
   `Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift`,
   `DistributedJobControllerTests.swift` (Core), and
   `Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`. Use deterministic
   owned worker fixtures through the actual handoff/worker completion path.
   Observe which worker executed, selected backend/model and exact reserved
   session evidence. Cover callee-only requirements, cycle/return/join/reused
   prefix, explicit assignments, missing target, unavailable capacity and
   post-admission worker loss. DTO-only placement assertions are insufficient.
   V1/V4/V11 pass before P1-6a closes; V5 certifies preserved distributed behavior.

### P1-6c: durable request to live execution to acknowledgment

In `Sources/RielaCLI/TaskCommands.swift`, `TaskDispatch.swift`,
`WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift` and
`WorkflowRunCommand+SupervisionPersistence.swift`, connect the shared durable
cancellation request to the active runner and existing selected-host cancellation
path. Reuse `Sources/RielaWork/WorkStore+Decisions.swift` and
`WorkStore+Reservation.swift`; do not add another decision store or bypass them.
Human cancel/reject, guard stop/replacement and Ctrl-C persist before signalling.
Pending cancellation takes the acknowledgment path, never generic reconcile.
Require the exact cancelled terminal snapshot before fence release and task
terminal state; consume any replacement request once after acknowledgment.
Pre-launch cancel forbids authorization. Lost acknowledgment, write failure,
lease expiry or heartbeat loss retains the fence until explicit reconciliation.

Extend `Tests/RielaWorkTests/WorkStoreCancellationTests.swift`,
`WorkStoreReservationTests.swift`, `DecisionApplierStoreTests.swift` (Work),
`Tests/RielaCLITests/TaskCommandMutationTests.swift`,
`TaskDispatcherIntegrationTests.swift` (CLI), and
`Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`. Exercise real running
cancellation locally and on the selected worker, authorization races, terminal
persistence failure, acknowledgment loss, reopen/replay and pending replacement
consumption. Assert no premature terminal task, stale launch or duplicate
accounting. V1/V2/V11 must pass; store-only acknowledgment tests are insufficient.

### P1-7b/P1-7a and final evidence investigation

Complete task-backed gate recovery and real bounded director child cases in
`Tests/RielaCLITests/TaskRuntimeExampleTests.swift` and both example bundles.
The retained recommendation-only director test is not child lifecycle evidence.
Use the P1-6d linked-work cases below and prove exactly-once accounting on replay.
Record each scenario, test name and observed persisted outcome against
`EXPECTED_RESULTS.md`. Run V1 before any legacy deletion; only then perform
P1-7a and run V1 again. Preserve unrelated supervisor/event/loop/routine paths.

Investigate prior broad failures and the truncated XCTest aggregate as test
execution issues. For a truncated aggregate, retain the whole log and final
process exit, reproduce the last unfinished suite in the foreground, identify
premature process termination or harness behavior, then rerun the affected full
gate. A targeted success does not replace V5. Supply fixture-owned paths under
this worktree's tmp for tests requiring writable runtime state; do not inspect
or repair the executing workflow's scoped registry. Never weaken assertions,
skip required suites or classify incomplete zero exits as passing. Compare
unchanged-baseline failures without broadening product scope; record any
unresolved gate explicitly. Final acceptance requires complete passing evidence.

## P1-6d judged-work acceptance and child execution

Apply accepted §17.7 in `Sources/RielaWork/AgentDirector.swift`,
`WorkStore+Decisions.swift`, `WorkStore+Reservation.swift`, `WorkModels.swift`,
`WorkStore+Schema.swift`, `TaskGuardCoordinator.swift` (all RielaWork), and
`Sources/RielaCLI/TaskDispatch.swift`, `WorkflowRunCommand+TaskReservation.swift`
and `WorkflowRunCommand+SupervisionPersistence.swift` (RielaCLI), as required.
Reuse existing reservation/evidence persistence, not a second task store.

1. Replace the explicit director-dispatch rejection with one ordinary bounded
   child run after work reconciliation. Persist its relation to the judged work
   at child reservation in the same store transaction, using the existing
   durable record model or the smallest required typed extension. Record both
   attempt identities, child session and task identity; caller TaskView alone
   is not authority. Schema/model edits, if necessary, are serialized and
   covered by fresh/reopened store and rollback tests under existing policy.
2. Keep work TaskView stable across child execution, charge child attempt/cost
   once, and validate successful child output against configured allowed P1
   kinds. Invalid/forbidden/failed/budget-blocked output persists escalation and
   requires a human; never recursively invoke the director.
3. At shared application, validate persisted linkage, producer child session,
   same task, current version and child terminal state. Only that linked child
   may intervene after judged work; reject newer work or foreign/stale linkage.
   Reconstruct completion from the judged work's durable gates, verification,
   acceptance criteria and applicable blocking findings. Child success alone
   cannot accept work. Preserve latest-attempt enforcement for unrelated paths.
4. Remove the validator's unconditional accept escalation only once shared
   application can enforce those rules. Agent acceptance cannot waive human
   acceptance. Replays return the original result; neither replay nor child
   completion duplicates accounting or changes judged work evidence.
5. Extend `Tests/RielaWorkTests/AgentDirectorTests.swift`,
   `DecisionApplierStoreTests.swift`, `DecisionApplierCausalityStoreTests.swift`,
   `WorkStoreReservationTests.swift` and, for any storage-shape change,
   `WorkStoreTests.swift`; extend CLI `TaskDispatcherIntegrationTests.swift`
   and `TaskRuntimeExampleTests.swift`. Prove a valid allowed accept, child-only
   success rejection, newer-work rejection, foreign/missing linkage rejection,
   requiresHumanAccept rejection, current-version conflict, restart/replay,
   exact child session/cost/attempt accounting, and nonrecursive escalation.
   Test real shared store and runner paths; validator-only assertions do not
   establish this contract. Include passing last-admitted work and budget-blocked
   child admission independently.

## Common lint and validation contract

swift build is the Swift compile/typecheck gate. Swift edits follow the local
Swift skill: keep touched code responsibility-based, avoid speculative
abstraction, and split touched non-generated files over 1000 lines by actual
responsibility without unrelated cleanup. Include necessary extracted paths in
serial ownership records. Do not weaken tests or lint to accept retained WIP.

Before any implementation edit, the integration owner captures repository lint
baseline; the integration owner records that immutable log/hash. After edits,
materialize exact existing changed/new Swift paths from its intent records in
`tmp/work-runtime-p1/<planId>/changed-swift-files.nul`; do not rely on git diff
alone because it omits untracked files and predecessor commits. The plan ID below is fixed for this package.
The metadata above contains the exact p1-dispatch commands.

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-dispatch/changed-swift-files.nul
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
```

Skip xargs only for an explicitly empty Swift write set; strict touched-file
lint gates acceptance. Repository-wide output is a recorded baseline check:
fail new diagnostics attributable to this work, report existing unrelated ones,
and do not broaden edits to clear them. If a tool is unavailable, record a
blocked gate and environment error, not success. Run required focused tests,
then the broader V5 gate once on the joined tree; repeat only after
new changes/failures. No web code is planned, so browser E2E is not a P1 gate.

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
processes. No implementation commands below have run during Step 4; these are downstream requirements.

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
and durable cancellation tests from the stable P1-PREREQ-R revision.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests'
```

**V3 lifecycle readiness and shared-applier regression**, log
`lifecycle-tests.log`. Require positive counts for each suite and behavioral
proof of the shared file map and invariant checklist, stable simultaneous
violation ordering, gate recovery budget and latest-attempt completion.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|AgentDirectorTests|CompletionEvaluatorTests'
```

**V4 capability readiness**, log `capability-tests.log`. These suites/interfaces
are certified by this plan’s P1-PREREQ-C gate, not a separate scheduled plan. Require
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
Both commands are required for the retained capability/profile and planned
shared runtime changes. Do not
weaken unrelated failing tests: classify baseline versus caused failures and
report blocked verification explicitly.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests|RielaAppSupportTests'
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

**V10 canonical payload prerequisite**, log `sandbox-tests.log`. Require positive
executed counts and real checked-in payload checks. Do not inspect the executing
workflow package or registries, and do not expand this plan into workflow repairs.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter ImplementationWorkflowSandboxTests
```

**V11 selected-host execution and cancellation**, log `selected-host-tests.log`.
Require positive counts for each suite and the P1-6a/c integration cases above:
actual worker execution with root/callee choice delivery, exact reserved session,
worker loss fencing and live cancellation/acknowledgment. In-memory transport
fixtures may control scheduling, but cannot bypass the worker execution and
shared store boundaries under test. Every fixture stops before the test exits.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
```

At the P1-PREREQ-L gate, V3 certifies the existing lifecycle requirements;
record bounded-director cases as pending P1-6d, never passing by omission.
After P1-6d and at final acceptance, V3 must also prove reopened-store
judged-work linkage and all P1-6d cases above. For V5 the AppSupport suite is required because host declarations touch
profile/daemon loading. SurfaceCatalog, help, doctor and plain workflow behavior
must remain covered by positive suites; classify unrelated baseline failures,
never suppress them or report the affected gate passing. V2 also needs positive
counts for cancellation and budget suites; V3 for causality and agent-director.

## P1-FINAL documentation, review and publication

- [ ] Serially reconcile source against immutable intents and prerequisite
  handoffs; run affected checks after repairs, then V0–V11 on the final stable
  tree. No unresolved material high/mid finding or incomplete required evidence.
- [ ] Perform author self-review, independent test-integrity review and the workflow's single adversarial
  implementation review, followed by required combined-tree acceptance. Review
  material behavior/data-loss/security/regression/test gaps, not style nits or
  speculative abstraction. Record actual review IDs, decisions and findings.
- [ ] Refresh `README.md`, affected example READMEs/EXPECTED_RESULTS, and P1
  status in `design-docs/specs/design-work-runtime-consolidation.md`. Update
  `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`, `SurfaceCatalog+Rows.swift`,
  `SurfaceCatalog+RowSupport.swift`, `Sources/RielaCLI/CLISurfaceEnumeration.swift`
  and `Tests/RielaCoreTests/SurfaceCatalogTests.swift` only where task CLI/removal
  requires it. Task GraphQL/UI counterparts stay explicitly deferred.
- [ ] Reconcile this plan, `impl-plans/README.md`, `impl-plans/PROGRESS.json`,
  `impl-plans/progress/plans-index.json`, `meta.json`, `phases.json` and
  `plans/work-runtime-p1-dispatcher-guard-director.json` under that progress
  directory only where the existing index format requires it. Preserve all
  non-P1 entries and other plans' unchecked status unless their acceptance is
  explicitly evidenced; do not claim completion of separate work packages.
- [ ] Append this session's status/evidence only to
  `impl-plans/progress/p1-dispatch.md`: task state, exact changed paths/hashes,
  retained-hunk attribution, interface ownership, commands/start/end/final exits,
  complete log paths, positive per-suite counts, review findings/decisions,
  invalidated evidence and deferred/external dependencies. No checkboxes close
  on source inspection, planning acceptance or historical logs alone.
- [ ] Audit applicable repository-owned `riela-package.json` manifests only
  for modified workflow/prompt/script/skill artifacts; refresh actual owning
  digests with established tooling and record exact paths serially before edit.
  Do not invent a manifest, modify an immutable installation or inspect scoped
  registries. Review `.codex/skills/riela-impl-workflow/SKILL.md` for directly
  affected documentation; update only a necessary P1 contract with explicit
  owner/path and digest audit, not unrelated workflow material. No skill edit
  is necessary merely because this plan was authored.
- [ ] Lockfile generation is conditional on a necessary dependency change;
  do not opportunistically update `Package.resolved`. No archiving is necessary
  before execution completes. Exclude tmp evidence from staging.
- [ ] Prepare the exact accepted P1 file/hunk allowlist; retain unrelated hunks
  even in shared files. The authorized workflow finalization gate commits and
  pushes non-force to `origin` / `feat/remaining-impl-plans`, verifies the final
  accepted hash remotely and records matching commit/push evidence. Freshly
  check publication readiness at that gate; missing upstream is not a design
  blocker. Do not fabricate tracking state, change other worktrees or integrate
  a base branch. No broad `git add` and no concurrent Git operations.

Shared-file documentation changes invalidate affected test/lint gates; rerun
those gates before the final allowlist is accepted. Existing untracked files
must be included in evidence and strict lint, not omitted by git diff. If
commit tooling can stage only whole files, unrelated mixed hunks require an
isolated accepted-content preparation that preserves the worktree/index; do
not silently include them. Actual inability to publish is reported with its
concrete failed command/log/exit, not claimed as success.

## Planning author check and remaining gates

Step 3 accepted §17.7 in the runtime-delivered review with no findings. Step 5
plan acceptance, implementation, behavioral tests, lint, adversarial review,
documentation completion and final commit/push remain downstream. No Swift
build/test/lint result is claimed in Step 4. No unresolved user decision or
known design defect remains. The current concrete director integration gap is
an implementation task, not a reason to reopen accepted design.

Author check: `python3 tmp/work-runtime-p1/step4-f46ff788/self-check.py`.
Complete logs/final exits and source-preservation evidence are recorded in
`tmp/work-runtime-p1/step4-f46ff788/verification-evidence.json`.
This plan's source inspections are not behavioral acceptance. The author
checks the single-plan DAG, exact scope, file-level tasks, accepted §17.7 mapping,
evidence commands, review/finalization gates and preservation of all prior work.
