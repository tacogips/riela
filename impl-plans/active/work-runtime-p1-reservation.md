# Work Runtime P1: Atomic reservation and fencing

**Status**: Step 4 revised; Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete the Work Runtime P1 dependency DAG (number/url: null)
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.6 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review-attempt-1-exec-4`, `accepted_for_step4_implementation_planning`; findings/feedback empty; no Step 5 feedback supplied.
**Codex-agent references**: `workflowExecutionId:codex-design-and-implement-review-loop-session-1`, `communicationId:comm-000003`, `communicationId:comm-000004`, `sourceStepExecutionId:step2-design-doc-update-attempt-1-exec-3`, `stepId:step3-design-review`, `stepId:step4-impl-plan-create`, `designAuthorModel:gpt-6-astra`, `planAuthorModel:gpt-6-astra`, `gateModel:gpt-5.6-sol`, `implementationModel:gpt-5.6-terra`; downstream executions record actual IDs.
**Updated**: 2026-09-22

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
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaWork/WorkStore+Schema.swift",
    "Sources/RielaWork/WorkStore.swift"
  ],
  "progressLog": "impl-plans/progress/p1-reservation.md",
  "taskIds": [
    "P1-1"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-reservation",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-reservation --filter 'WorkStoreTests|WorkStoreReservationTests|WorkEvidenceProjectorTests'",
    "git diff --check",
    "xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-reservation/changed-swift-files.nul",
    "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache"
  ],
  "dependencyMode": "native-accepted-predecessor-DAG",
  "evidenceDirectory": "tmp/work-runtime-p1/p1-reservation/"
}
```

The execution, overwrite protection, evidence, and completion contract in
`impl-plans/active/work-runtime-p1-dispatcher-guard-director.md` applies to this plan.
No worker edits another worker’s progress log or marks a shared plan complete.


## Intent, context, non-goals and invariants

User intent is exactly one safely fenced task attempt whose runtime session
and reservation commit together. Checkpoint reservation APIs exist but are
not certified. This root plan supplies durable primitives to both wave-2
owners. Do not implement policy ordering, placement probes, dispatcher/CLI,
legacy removal, auto-improve migration or a second database/transaction path.

| Exact file | Smallest intended change / acceptance |
| --- | --- |
| `Package.swift` | Audit/repair only required existing Work/Core/CLI/test dependency wiring; preserve Core's independence from Work. No speculative dependency or lockfile generation. |
| `Sources/RielaWork/WorkModels.swift` | Only launch/fence/pending-request/cancellation and durable decision-outcome values required by §17.2; expose stable signatures to lifecycle. |
| `Sources/RielaWork/WorkStore.swift` | Shared connection/transaction access and required read-only opening seam; preserve P0 store semantics. |
| `Sources/RielaWork/WorkStore+Schema.swift` | Durable leases, requests/cancellation, original decision outcome storage needed by lifecycle; follow existing generation policy. Leave work_hosts table to capabilities. |
| `Sources/RielaWork/WorkStore+Reservation.swift` | Atomic reservation, authorization/node-start fence, terminal acknowledgment and transaction-scoped pending-request consumption primitives. Lifecycle must enqueue within its decision transaction, not in a later commit. |
| `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` | Minimal shared-connection snapshot insertion seam: duplicate IDs reject; every row rolls back with reservation. Core does not import Work. |
| `Tests/RielaWorkTests/WorkStoreTests.swift`, `Tests/RielaWorkTests/WorkStoreReservationTests.swift` | Independent-connection races, each rollback boundary, dependency/version/admission checks, token/fencing, durable request/cancellation and P0 behavior. |
| `impl-plans/progress/p1-reservation.md` | Record finalized type/method signatures, original-outcome storage seam, exact owner/hash and tests for both dependent plans. |

Invariants: one shared runtime database and transaction; unique attempt/session;
no wait-side attempt/session/lease; terminal-unreconciled fence retained;
digest-only one-use token; uncertainty cannot authorize relaunch; durable
runner acknowledgment precedes replacement. No source-text test substitutes
for independent database connections and injected transaction failures.

## Intended changes and acceptance (§11, §17.2)

- [ ] **P1-1a** Audit retained Package.swift, models, schema, reservation and
  SQLite changes against P0. Add only required launch metadata, leases and
  durable pending reservation/cancellation representation. Keep the shared
  runtime-records database and existing generation policy; no import/migration
  of auto-improve state. Keep `RielaWork -> RielaCore`, never a reverse import.
  Provide original decision-outcome storage and transaction-scoped enqueue
  seams for lifecycle; reserve the minimal schema/storage seam for later `work_hosts` persistence;
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
