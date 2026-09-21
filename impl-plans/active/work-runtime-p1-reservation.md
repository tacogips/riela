# Work Runtime P1: Atomic reservation and fencing

**Status**: Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete Work Runtime P1 using the accepted dispatcher, guard, and director design
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.5 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review`, `accepted_for_step4_implementation_planning`; no findings or revision request.
**Codex-agent references**: `riela-manager`, `step1-issue-intake`, `step2-design-doc-update`, `step3-design-review`, `step4-impl-plan-create`; downstream installed-package implementation/review executions must record their actual IDs.
**Updated**: 2026-09-21

```json
{
  "planId": "p1-reservation",
  "planPath": "impl-plans/active/work-runtime-p1-reservation.md",
  "dependsOn": [],
  "writePaths": [
    "Package.swift",
    "Sources/RielaWork/WorkModels.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Sources/RielaWork/WorkStore+Schema.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Tests/RielaWorkTests/WorkStoreTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "impl-plans/progress/p1-reservation.md"
  ],
  "sharedPaths": [
    "Package.swift",
    "Sources/RielaWork/WorkModels.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Sources/RielaWork/WorkStore+Schema.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift"
  ],
  "progressLog": "impl-plans/progress/p1-reservation.md",
  "taskIds": [
    "P1-1"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-reservation",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-reservation --filter 'WorkStoreTests|WorkStoreReservationTests|WorkEvidenceProjectorTests'",
    "git diff --check"
  ]
}
```

The execution, overwrite protection, evidence, and completion contract in
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` applies to this plan.
No worker edits another worker’s progress log or marks a shared plan complete.


## Intended changes and acceptance (§11, §17.2)

- [ ] **P1-1a** Audit retained Package.swift, models, schema, reservation and
  SQLite changes against P0. Add only required launch metadata, leases and
  durable pending reservation/cancellation representation. Keep the shared
  runtime-records database and existing generation policy; no import/migration
  of auto-improve state. Keep `RielaWork -> RielaCore`, never a reverse import.
  Reserve the minimal schema/storage seam for later `work_hosts` persistence;
  capability ownership adds that table in its subsequent wave.
- [ ] **P1-1b** Make `reserveAttempt` one `BEGIN IMMEDIATE` transaction on the
  runtime snapshot connection: reload task/version and dependency satisfaction,
  enforce admission budget and one-live-attempt, insert unique attempt/session
  `.created` snapshot, lease, dispatch decision or consumed pending request,
  placement evidence, and task advancement. Reject duplicate IDs rather than
  overwrite snapshots; any injected failure rolls back every row and version.
  Missing dependencies are errors; unmet existing dependencies wait without an
  attempt/session/lease. Terminal-but-unreconciled also holds the live fence.
- [ ] **P1-1c** Bind one-use opaque launch token to exact attempt/session; store
  digest only. Authorize before runner entry and mark node start. Test wrong,
  replayed and replaced tokens; never print tokens in evidence or logs. A
  provably unauthorized reservation can be fenced then explicitly replaced.
  Authorization/node-start uncertainty keeps the fence; neither lease expiry
  nor missing heartbeat proves non-execution. Reject stale terminal writers.
- [ ] **P1-1d** Supply durable one-time consumption of the rerun/recover request
  recorded by the decision applier. Link its existing decision to the new
  attempt, without duplicate decision insertion; replay reconciles the same
  request after process loss. Cancellation request/acknowledgment storage must
  prevent reconciliation or replacement before durable runner terminal state.

Deliverables: reviewed store/connection changes, fault-injection and concurrency
regressions, and a contract entry in this plan's progress log naming finalized
reservation, cancellation, acknowledgment and request-consumption signatures.
Later workers fresh-read these signatures rather than invent a second path.
The lifecycle worker owns decision semantics; this worker owns the durable
primitives and invariants only.

Acceptance tests must use independent connections racing on one database,
rollback at each transactional insertion, stale versions/dependencies,
duplicate attempt and session IDs, token replay, pre/post-authorization crash,
terminal-before-reconcile fencing, last-permitted-attempt admission, repeated
pending-request consumption, and stale launcher writes. P0 store/projector,
show/list fixtures stay valid. Capture the unchanged behavior before repairing
retained implementation; do not treat its old passing logs as current proof.

## Verification and completion

Run these commands in the foreground and record final exit status and complete
log paths in the plan-owned progress log. Named new suites below are required
deliverables, not claims that they already exist. Zero selected tests is a
failed gate; record the discovered test names and positive executed counts.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-reservation
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-reservation --filter 'WorkStoreTests|WorkStoreReservationTests|WorkEvidenceProjectorTests'
git diff --check
```

Also run the changed-file strict SwiftLint gate defined in the root plan for
this plan's actual Swift write set, including new untracked files. Retain P0
assertions affected by these changes. Each unchecked task below requires its
specified acceptance assertions, passing build/typecheck, focused tests and
lint, complete evidence, and independent review with no unresolved high/mid
finding. Passing this plan alone does not close P1. Report blocked commands
explicitly; never substitute source-text assertions for behavioral tests.
