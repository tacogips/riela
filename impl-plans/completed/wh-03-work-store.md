# wh-03: Work store — takeover reservation, leases and fence, answers, handover requests

```json
{
  "planId": "wh-03-work-store",
  "planPath": "impl-plans/active/wh-03-work-store.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Leases.swift",
    "Sources/RielaWork/WorkStore+Takeover.swift",
    "Sources/RielaWork/WorkStore+HandoverRequests.swift",
    "Sources/RielaWork/TaskDispatcher.swift",
    "Tests/RielaWorkTests/WorkStoreLeaseTests.swift",
    "Tests/RielaWorkTests/WorkStoreTakeoverTests.swift",
    "Tests/RielaWorkTests/WorkStoreHandoverRequestTests.swift",
    "impl-plans/progress/wh-03-work-store.md"
  ],
  "sharedPaths": ["Sources/RielaWork/DecisionApplier.swift"],
  "sharedPathNotes": [
    {"path": "Sources/RielaWork/DecisionApplier.swift", "intendedEdit": "Replace wh-01's throwing arms: `.handover` is applied like `.stop` (requires live cancellation, no pending reservation); `.answer` and `.takeover` keep throwing because they are only created by recordAnswer/requestTakeover."}
  ],
  "progressLog": "impl-plans/progress/wh-03-work-store.md"
}
```

## Intent and context

This plan holds all store-side rules for handover: who may reserve a takeover, lease heartbeat,
expiry and fence, orphan fencing, answers, operator handover requests, and late-arrival
(superseded) reconciliation. Design: §5 rules, §10.1, §10.4, §11, §21 R19. Everything runs in SQLite
transactions on `WorkStore`, as the existing reservation code does.

Non-goals: the packet builder or seal (wh-01, wh-04), CLI, runner, and the GraphQL token checks beyond the helpers below.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-03-work-store/`,
writePaths only, arm64 logs, no git state changes, own progress log).

## Deliverables (signatures pinned; wh-14/15/16/18 call them)

In `WorkStore+Reservation.swift`:
- `AttemptReservationRequest` gains `hostId: String = "local"` (last init parameter, defaulted).
- The lease insert writes `heartbeat_at = now`, `expires_at = now + (task.guardPolicy.lease ?? LeasePolicy()).ttlMs`,
  `fence = task.fence + 1` and `host_id`. The same transaction stores `task.fence = fence` on the updated task.
- `.takeover(fromAttemptId, handoverId)` entries are accepted only when **all** of these hold:
  a matching unconsumed pending reservation is consumed by this request (the existing pending-request rule);
  `loadHandover(handoverId)` exists, belongs to the task, has `fromAttemptId` equal to the entry, and has no successor.
  The same transaction then calls `attachSuccessor` and sets `attempt.takeoverLineage = TakeoverLineage(fromAttemptId, handoverId, hops: (predecessor.takeoverLineage?.hops ?? 0) + 1)` (note the parentheses: `??` binds looser than `+`).
  The session snapshot's `entryStepId`/`currentStepId` equal `request.entryStepId` (the caller passes the packet's resumeStepId).
- Non-takeover entries (start, resume, rerun, recover): if the task's latest handover has no successor,
  return `.wait(.handover(id))` before any write. Director entries are unaffected.
- `decisionKind(for:)`: `.takeover` maps to `.takeover(handoverId:, placement:)` with the placement taken from the pending decision
  (reservation always consumes a pending request for takeovers, so the stored decision is reused).

In `WorkStore+Leases.swift` (new):
- `func loadLease(attemptId: AttemptID) throws -> AttemptLease?`, `func loadLease(taskId: TaskID) throws -> AttemptLease?`
- `func heartbeat(attemptId: AttemptID, fence: Int, now: Date, ttlMs: Int) throws -> Bool` runs
  `UPDATE work_leases SET heartbeat_at=?, expires_at=?, updated_at=? WHERE attempt_id=? AND fence=?`.
  It returns `changes == 1`. Zero rows (row deleted or fence differs) means fenced.
- `func verifyLeaseToken(attemptId: AttemptID, token: String) throws -> AttemptLease` compares the digest with
  `launchTokenDigest(token)` and throws `WorkStoreError("lease token does not match")` on mismatch (used by GraphQL heartbeat/report).
- `func expiredLeases(now: Date) throws -> [AttemptLease]` returns rows with `expires_at < now`, ordered by expires_at.

In `WorkStore+Takeover.swift` (new):
- `func fenceOrphan(taskId: TaskID, now: Date, producer: DecisionProducer) throws -> OrphanFenceResult`
  (`OrphanFenceResult {predecessor: Attempt, evidence: OwnerLossEvidence, task: WorkTask, fenceEvidenceId: EvidenceID}`).
  Everything happens in one transaction. It throws `WorkStoreError("lease for task '<id>' has not expired (expires <iso>)")` if the lease is not expired, and
  throws if there is no lease. The predecessor may be `prepared`, `running` or `terminal` (an owner that died before launch
  is an orphan too). Otherwise it bumps `task.fence += 1` and version+1, sets the predecessor attempt to
  `.reconciled` with `AttemptOutcome(sessionStatus: .failed, failureKind: .leaseLost)` and
  `supersededByFence = task.fence`, deletes the lease row, and inserts `Evidence(kind: .leaseFence, producedBy: mapped producer,
  payload = OwnerLossEvidence JSON)`. The task state stays as it is (the caller seals next, which sets `.waiting`).
- `func recordAnswer(taskId: TaskID, questionId: String, payload: JSONObject, producer: DecisionProducer, decisionId: DecisionID, now: Date) throws -> WorkTask`.
  Preconditions: the latest handover has no successor, its reason is `userInputRequired(question)` with `question.id == questionId`,
  and the task is `.waiting`. When `answerSchema` is present, validate the payload with `DefaultWorkflowOutputValidator`
  (`Sources/RielaCore/RuntimeOutputValidation.swift:34`; wrap the payload as it validates node output). On failure, throw
  `WorkStoreError("answer does not match the question's answerSchema: <first error>")`. Then, in one transaction:
  insert `Decision(.answer(HandoverAnswer))`, `Evidence(.handoverAnswer)` and a pending reservation
  `entry: .takeover(fromAttemptId: packet.fromAttemptId, handoverId)`, and set the task to `.scheduled` with version+1.
  Replaying the same `decisionId` returns the current task without writes (the `sameReplayIntent` pattern in `WorkStore+Decisions.swift`).
- `func latestAnswer(handoverId: HandoverID) throws -> HandoverAnswer?`
- `func requestTakeover(taskId: TaskID, placement: TakeoverPlacement, producer: DecisionProducer, decisionId: DecisionID, now: Date) throws -> WorkTask`
  is for tasks whose latest unsucceeded handover is not an unanswered `userInputRequired`. It refuses those with
  `WorkStoreError("handover <id> needs an answer: riela task answer <taskId> --question <qid> …")`.
  If a takeover pending reservation already exists, it is a no-op that returns the task. Otherwise it inserts
  `Decision(.takeover(handoverId, placement))` and a pending reservation `.takeover(...)`, and sets the task to `.scheduled`.
- `reconcileAttempt` (existing, in Reservation) must return the stored attempt unchanged when it is already reconciled
  with `supersededByFence != nil`. This is a late terminal arrival: do not judge it, do not change the task, and do not throw.

In `WorkStore+HandoverRequests.swift` (new):
- `func requestHandover(taskId:, reason: String, immediate: Bool, target: String?, sinks: [HandoverSinkKind], now:) throws -> HandoverRequestRecord`
  requires a live attempt (`running`). Refuse with a clear error otherwise. It is idempotent while an unconsumed
  request exists (returns the existing one).
- `func pendingHandoverRequest(attemptId:) throws -> HandoverRequestRecord?`; `func consumeHandoverRequest(requestId:, now:) throws`.

`WorkStore+Decisions.swift` / `DecisionApplier.swift`:
`requiresLiveCancellation(.handover) = true`; `requiresPendingReservation(.handover) = false`;
`requiresCausalEvidence(.handover) = true` (the director cites the inactivity evidence);
`requestedEntry(for: .answer / .takeover) = nil` (they are never routed through `applyDecision`).

`TaskDispatcher.swift`: `preview` returns `.wait(.handover(id))` under the same rule as the reservation,
so `task run --dry-run` shows it.

## Pitfalls

- The one-live-attempt index covers `prepared|running|terminal`, so a takeover succeeds only after the
  predecessor is `reconciled`. Seal (wh-01) and `fenceOrphan` do that. Never delete attempts.
- Do not increment the fence twice in one transaction. Invariant: the live lease's `fence == task.fence`,
  and every fence value is strictly greater than every earlier one.
- Timestamps use the existing `Self.timestamp(_:)` format. `expires_at` comparisons are string comparisons of
  that fixed-width UTC format, so verify the format is lexicographically ordered, or compare as dates in Swift.
- `DecisionProducer` → `EvidenceProducer` uses the existing `evidenceProducer(for:)`.

## Tests

`WorkStoreLeaseTests`: reservation writes fence = task.fence+1 and sets expires/host; heartbeat extends; heartbeat with a
stale fence → false; after the row is deleted → false; `expiredLeases` ordering; `verifyLeaseToken` match and mismatch.
`WorkStoreTakeoverTests`: after a sealed handover a `.start` reservation → `.wait(.handover)`; `recordAnswer` with a wrong
question id, a schema-invalid payload, a valid option or a replay; `requestTakeover` refused for an unanswered S1 and
accepted for presence; a takeover reservation consumes the pending request, attaches the successor and sets lineage
hops; a second takeover for the same handover is refused; `fenceOrphan` refuses an unexpired lease; an expired lease → fence
bumped, predecessor reconciled `leaseLost` + `supersededByFence`, lease gone, evidence stored; a late `reconcileAttempt` on
that predecessor → unchanged; the dry-run `preview` shows the handover wait.
`WorkStoreHandoverRequestTests`: request needs a running attempt; idempotent while pending; consume.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-03-work-store/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-03-work-store/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "WorkStoreLeaseTests|WorkStoreTakeoverTests|WorkStoreHandoverRequestTests|WorkStoreReservationTests|WorkStoreCancellationTests|DecisionApplier|TaskDispatcherTests|BudgetAdmissionStoreTests" > tmp/work-handover/wh-03-work-store/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-03-work-store/focused.log'
git diff --check
```

Both must end with exit=0 and the new tests must pass. Existing reservation and cancellation tests must stay green.

## Done criteria

- [x] Every pinned API exists and is tested; the reservation invariants hold
- [x] The existing Work store tests are green or baseline-classified
- [x] The progress log is complete

**Closure (2026-10-01, Step 8)**: accepted; implemented in `d043cbad` (waves 1-2), acceptance recorded in `7182232d`. Evidence: `impl-plans/progress/wh-03-work-store.md`. Archived to `impl-plans/completed/`.
