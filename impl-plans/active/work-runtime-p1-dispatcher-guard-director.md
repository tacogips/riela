# Work Runtime P1: P1-6b task run and read-only dry-run

**Status**: P1-6b planning updated; Step 5 review and implementation acceptance pending.
**Workflow mode**: issue-resolution
**Issue reference**: Work Runtime P1-6b; no GitHub issue number supplied.
**Accepted design**: `design-docs/specs/design-work-runtime-consolidation.md` §17.5, “P1-6b bounded continuation (2026-09-24)”; SHA256 `d80ac30d217450772a535f2308f99f87ac225aea6db0876e08d4c7a18b5ee98f`.
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
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/HostCapabilityResolver.swift",
    "Sources/RielaWork/TaskDispatcher.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Sources/RielaWork/WorkStore+Hosts.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskRunResultTests.swift",
    "Tests/RielaCLITests/TaskDryRunReadOnlyTests.swift",
    "Tests/RielaWorkTests/TaskDispatcherTests.swift",
    "Tests/RielaWorkTests/WorkStoreTests.swift",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/HostCapabilityResolver.swift",
    "Sources/RielaWork/TaskDispatcher.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Sources/RielaWork/WorkStore+Hosts.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskRunResultTests.swift",
    "Tests/RielaCLITests/TaskDryRunReadOnlyTests.swift",
    "Tests/RielaWorkTests/TaskDispatcherTests.swift",
    "Tests/RielaWorkTests/WorkStoreTests.swift",
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
      "P1-6b-results"
    ],
    "P1-6b-verification": [
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
  "evidenceDirectory": "tmp/work-runtime-p1/p1-6b/"
}
```

## Current P1-6b executable contract

### Intent, context, and non-goals

Finish the retained task run command and prove allocation-free dry-run using
accepted P1-6a dispatch. Inspected branch is `feat/remaining-impl-plans`, HEAD
`2f10916a14501af68fd7e7f63cb91f244a343f8c`; Step 4 begins with only the accepted
design edit. Recheck actual status before implementation; never reset changes.
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
orders audit → results → read-only boundary → verification → finalization.
All listed paths are exclusively owned by this single implementation owner;
reviewers inspect without edits. The write set is a ceiling, not a demand to
change every file. Production edits to WorkStore/host reads are conditional on
concrete P1-6b failures. Tests may live in the two named focused new files to
avoid swelling the existing integration suite; if created, both execute in the
explicit additional gate below. No other path is implicitly writable: a needed
path expansion requires a concrete finding, exact path and bounded plan/review
amendment before editing, not a blanket new abstraction or unrelated repair.

Before each edit, fresh-read the file and capture SHA256 plus an immutable
intent snapshot under `tmp/work-runtime-p1/p1-6b/attempt-N/` recording intended
hunks and accepted requirement. Record post-edit hashes. Compare predecessor
hashes at every handoff; preserve unexpected changes, invalidate affected
verification, and reconcile serially instead of restoring whole files. No
concurrent Git operations or private implementation branches. The workflow
must accept and commit the design and this plan before native implementation
begins; this author node does not preempt Step 5 or commit an unreviewed plan.

Workers append only to `impl-plans/progress/p1-dispatch.md`. Shared indexes,
lockfile generation, formatting and global archiving are reserved for serial
finalization and are unnecessary for this slice. Never archive this parent plan.
If native join supplies change evidence, the serial integration owner compares
all intended hunks and hashes and repairs overwritten accepted behavior before
independent combined-tree review.

### Tasks and exact deliverables

- [ ] **P1-6b-audit**: Fresh-read the listed command, dispatcher, host and store
  files plus nearby tests. Trace from `TaskCommandRunner.locateTask` through
  pending request, dependency, host and placement reads, including constructors.
  Record retained behavior and concrete defects in the progress log. Read-only
  labels are not proof: `WorkStore.openReadOnlyIfPresent`,
  `WorkStore+Hosts` and `TaskDispatcher.pendingReservation` must be checked
  against `Sources/RielaSQLite/SQLiteDatabase.swift`, whose ordinary `.readOnly`
  can fall back to read-write. Inspect existing strict modes before choosing the
  smallest caller-level repair. Inspect profile initialization and controller
  inspection for side effects; no package rediscovery or real user-state probes.
- [ ] **P1-6b-results**: In `Sources/RielaCLI/TaskDispatch.swift` and, only where
  needed, `TaskCommandModels.swift`/`TaskCommands.swift`, preserve existing wire
  field names and optional-field conventions while exposing prospective
  per-node host/backend choices in text as well as JSON. Use typed statuses
  with existing wire spellings if touching the closed result status domain.
  Keep exact reservation identities available once admitted, including runner
  failures and post-reservation errors; never substitute a child or generated
  replacement session ID. Preserve nonzero exits and diagnostic details.
  Pre-admission structured errors use the existing task failure envelope;
  failures before a durable terminal result must not pretend completion.
  A ready preview has no IDs or wait reason; waits have the exact typed reason
  and no allocated IDs. Do not change runner execution or reconciliation policy.
  Extend `TaskCommandParsingTests` for target, dry-run/shared options, missing
  ID, invalid options and precedence; add command-level text/JSON success,
  ready/wait and pre-/post-admission error assertions in `TaskCommandMutationTests`
  or `TaskRunResultTests`. Compare reported IDs with durable attempt/session rows.
- [ ] **P1-6b-readonly**: Keep the same task/reference/entry/requirement/placement
  resolution in both modes. At the earliest applicable read boundary in
  `TaskCommands.swift`, `TaskDispatch.swift`, `TaskDispatcher.swift`,
  `HostCapabilityResolver.swift`, `WorkStore.swift` and `WorkStore+Hosts.swift`,
  select existing nonmutating APIs or add only the minimal task-preview read
  option needed to avoid writable loaders. Preserve ordinary inspection and
  real-run compatibility; no global SQLite semantics rewrite. No migration,
  generation reset, checkpoint, quarantine, host cache persistence, lock-file
  creation, pending-request consumption, reservation, launch or runner call on
  dry-run. Absent stores remain absent; incompatible/corrupt stores fail with
  diagnostics; absent optional profiles use in-memory defaults; corrupt profiles
  fail without repair. Never use immutable SQLite reads over an active WAL and
  silently ignore committed data. If a sidecar layout cannot be read safely,
  diagnose it before opening rather than create/alter sidecars or return stale
  readiness. Preserve current WAL contents and existing sidecars even on error.
  Prove this with real store/profile APIs, not a stub that skips the risky read.
- [ ] **P1-6b-verification**: In `TaskDispatcherIntegrationTests`,
  `TaskDryRunReadOnlyTests`, `TaskDispatcherTests` and conditionally
  `WorkStoreTests`, build controlled fixtures under repository `tmp/`. Compare
  file inventory plus bytes and complete affected row values (not just counts)
  before/after: tasks, attempts, sessions, decisions, leases, evidence, pending
  requests and `work_hosts`. Include database/WAL/SHM and host/profile/controller
  files. Cover ready and dependency/capacity waits, absent/incompatible/corrupt
  stores, present/absent/corrupt profiles, existing and absent sidecars, and
  committed WAL data. Disable unrelated concurrent writes during snapshots;
  snapshot helpers must not checkpoint, migrate or mutate fixtures. For corrupt
  data that cannot decode, require diagnostic and byte/inventory equivalence,
  explicitly marking row comparison inapplicable. Retain P1-6a selected-host,
  reservation/race and exact-session tests. Run the gates below to terminal exit.
- [ ] **P1-6b-finalization**: Independent integration and adversarial reviews
  inspect final changed bytes and actual logs. Resolve all material findings;
  repeat only invalidated checks. Append commands, exits, positive per-suite
  counts, complete log paths, hashes, retained-code attribution and review
  decisions to `impl-plans/progress/p1-dispatch.md`. Update only P1-6b evidence
  in this plan and §17.5 of the design. Review README for accuracy; an actual
  required change needs an exact scoped amendment, not a general refresh.
  Mark P1-6b accepted only after both independent reviews; keep parent and
  later slices open. Final workflow gates commit the exact accepted allowlist
  and non-force push to `origin/feat/remaining-impl-plans`; verify matching
  accepted commit/push evidence. No broad staging, tmp files, force push or
  main merge. No workflow/prompt/script/skill edit is planned, so no package
  digest refresh is needed.

### Invariants and acceptance matrix

| Accepted requirement | Passing evidence |
| --- | --- |
| CLI parsing and typed text/JSON | Valid and invalid parsing; shared option precedence; text placement; typed diagnostics; correct nonzero failure exits |
| Exact identity and wait reason | Output IDs equal reserved durable rows on successful and failed admitted runs; ready/wait allocate nothing; wait reason matches dispatcher |
| Read-only dry-run | Same resolution/prospective placement, all byte/inventory/row-value checks unchanged across the matrix above; no misleading stale WAL read |
| P1-6a preserved | Final-source reservation and selected-worker/callee execution regression gates pass |
| Bounded publication | Independent integration/adversarial acceptance without unresolved material finding, exact file allowlist, matching committed/pushed hash; later slices open |

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
invalidate Swift tests. No implementation test pass is claimed by this plan.

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
If the two new focused test files are used, run their gate and require a
positive count for each created suite (adjust the filter to the created names
and record exact argv; never report a missing suite as passing):

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'
```

If `WorkStore.swift` or `WorkStore+Hosts.swift` changes, also run:

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreTests|TaskCommandTests'
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
| P1-6b | Plan authored; Step 5 and implementation/review gates pending |
| P1-6c/d, P1-7a/b | Deferred/open |
| Parent P1 | Open; no global certification or archiving |

No unresolved user decision or design defect was identified. Progress entries
must distinguish source inspection, actual verification and independent
acceptance; record exact retained files, concrete repairs, hash drift and
invalidated/reused evidence. Design/plan acceptance is not implementation
acceptance. Finalization requires all scoped acceptance rows and reviewer
findings resolved, matching final-source evidence and exact accepted publication.

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
