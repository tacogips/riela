# wh-16: Task-handover GraphQL provider, serve wiring and authorization (controller side)

```json
{
  "planId": "wh-16-graphql-provider",
  "planPath": "impl-plans/active/wh-16-graphql-provider.md",
  "wave": "W4",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/TaskHandoverGraphQLProvider.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift",
    "Sources/RielaCLI/RielaLibrary.swift",
    "Tests/RielaCLITests/TaskHandoverGraphQLProviderTests.swift",
    "Sources/RielaWork/TaskDispatcher.swift",
    "Tests/RielaWorkTests/TaskDispatcherTests.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaWork/WorkStore+Leases.swift",
    "Tests/RielaWorkTests/WorkStoreLeaseTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "impl-plans/progress/wh-16-graphql-provider.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/TaskDispatch+Director.swift",
    "Sources/RielaCLI/TaskDispatch+Handover.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskHandoverRuntime.swift",
    "Sources/RielaCLI/TaskHandoverSupport.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaWork/DecisionApplier.swift",
    "Sources/RielaWork/HandoverBriefRenderer.swift",
    "Sources/RielaWork/HandoverCoordinator.swift",
    "Sources/RielaWork/HandoverPacketBuilder.swift",
    "Sources/RielaWork/HandoverProtocols.swift",
    "Sources/RielaWork/HandoverRedaction.swift",
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/WorkHandover.swift",
    "Sources/RielaWork/WorkStore+Adoption.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Director.swift",
    "Sources/RielaWork/WorkStore+HandoverRequests.swift",
    "Sources/RielaWork/WorkStore+Handovers.swift",
    "Sources/RielaWork/WorkStore+Hosts.swift",
    "Sources/RielaWork/WorkStore+Isolation.swift",
    "Sources/RielaWork/WorkStore+Schema.swift",
    "Sources/RielaWork/WorkStore+Takeover.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+Director.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+GuardPolicy.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskHandoverCommandTests.swift",
    "Tests/RielaCLITests/TaskHandoverDispatchTests.swift",
    "Tests/RielaCLITests/TaskHandoverLeaseTests.swift",
    "Tests/RielaCLITests/TaskHandoverRepositoryTests.swift",
    "Tests/RielaWorkTests/DecisionApplierCausalityStoreTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaWorkTests/DecisionApplierTests.swift",
    "Tests/RielaWorkTests/DeterministicDirectorHandoverTests.swift",
    "Tests/RielaWorkTests/HandoverCoordinatorTests.swift",
    "Tests/RielaWorkTests/HandoverPacketBuilderTests.swift",
    "Tests/RielaWorkTests/WorkHandoverModelsTests.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreHandoverRecordsTests.swift",
    "Tests/RielaWorkTests/WorkStoreHandoverRequestTests.swift",
    "Tests/RielaWorkTests/WorkStoreTakeoverTests.swift",
    "Tests/RielaWorkTests/WorkStoreTests.swift"
  ],
  "progressLog": "impl-plans/progress/wh-16-graphql-provider.md"
}
```

## Intent and context

This plan makes the seven fields pinned in wh-12 executable over `/graphql` in `riela serve` (and through the local
`riela graphql` document commands and the library), under manager-session authentication (design §10.2, §12, §14,
§21 R8 and R16). The controller reserves, heartbeats and reconciles remote successor attempts. The remote client is wh-18.
Chain pattern: `ServeWebRegistryExecutor` (`ServeWebHost.swift:182-213`), `ScopedParityCommands+GraphQLDocument.swift:28-45`,
`RielaLibrary.swift:130`. Auth pattern: `WorkflowExecutionAuthorizationWrapper` (`Sources/RielaGraphQL/WorkflowExecutionGraphQL.swift:5`)
and how `ServeWebHost.swift:~145` applies it.

Non-goals: SDL, root-field registration and catalog rows (wh-20); the successor client (wh-18); new auth mechanisms.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-16-graphql-provider/`,
writePaths only, arm64 logs, temp stores, no git state changes, own progress log).

## Deliverables

`TaskHandoverGraphQLProvider: TaskHandoverGraphQLProviding` (`init(workingDirectory:sessionStore:scope:)`). It locates the
store exactly as `TaskCommandRunner.locateTask`/`storeRoots` do and delegates to `TaskHandoverRuntime`/`TaskDispatch` (wh-14)
and the `WorkStore` APIs (wh-01, wh-03):
- `taskHandover` → `loadHandover` or `latestHandover`, mapped to `GraphQLHandoverPacket` (`packet` = the canonical JSON object).
- `tasksAwaitingHandover(traits:)` → `store.tasksAwaitingHandover(traits:)`. An unknown trait string → `invalid_input`.
- `requestTaskHandover` → `requestHandover`. `answerTask` → `answer` (producer `.human(principal ?? "graphql")`).
- `takeoverTask`: the input traits must ⊇ the packet's required traits, else `conflict` "host-traits-unavailable: …".
  `requestTakeover(traits:)` (no-op if already pending), then reserve through `TaskDispatcher.reserve` with
  `AttemptReservationRequest.hostId = input.hostId`, session id `task-session-<uuid>`, entry step = resume step, and placement
  evidence `{remoteHost, traits}`, then launch authorization. Return `{attemptId, sessionId, fence, expiresAt, heartbeatToken:
  the lease credential minted by launch authorization (design §14, §21 R31; not the launch token), heartbeatMs: lease policy,
  packet}`. The controller does **not** run the workflow.
- `heartbeatAttempt`: no lease row → `{fenced: true}`; token mismatch (`verifyLeaseToken`) → `unauthorized`; otherwise
  `store.heartbeat` → `{fenced: !ok, fence, expiresAt}`.
- `reportAttempt`: `verifyLeaseToken`. Decode `snapshot` into `WorkflowRuntimePersistenceSnapshot` and `deliverables` into
  `[DeliverableRef]` (with `JSONCanonical.decoder()` for dates). Require `snapshot.session.sessionId == attempt.sessionId`,
  then `TaskDispatch.reconcileExternalTerminal(...)`. The result gives `{attemptId, taskState, decisionKind, handoverId?}`.
  A successor that suspended is sealed here (R16).
- Wiring: add `TaskHandoverGraphQLDocumentExecutor(provider:next:)` to the three chains. In `ServeWebHost`, wrap it so that
  non-locally-trusted requests without a valid manager-session bearer get `unauthorized`, with the same decision logic
  the wrapper applies to `executeWorkflow`. Reuse the wrapper type if it can wrap an arbitrary executor. Otherwise replicate its check
  in a small private wrapper and cite the reused function.

## Pitfalls

- The launch token is single-use. The heartbeat and report credential is the separate lease credential that launch
  authorization mints (R31). Only its digest is stored (lease row). Never log either token.
- `reportAttempt` must run the director and verification exactly as a local terminal does. Do not re-implement them; call wh-14's entry.
- The reservation path must go through the one-live-attempt fence and the pending reservation (never insert rows directly).

## Tests (`TaskHandoverGraphQLProviderTests`)

- `taskHandover` and `tasksAwaitingHandover` over a store holding a sealed presence handover (filtered by traits)
- `answerTask` → task scheduled; `requestTaskHandover` without a live attempt → error
- `takeoverTask` with missing traits → conflict; with traits → reservation row with `host_id = input.hostId`, the lease fence equals the task fence, and the token is returned
- heartbeat extends; a wrong token → unauthorized; after `fenceOrphan` → `fenced: true`
- `reportAttempt` with a completed snapshot for a task whose completion contract is met → task `succeeded`, accept decision recorded
  (the director ran); with a suspended snapshot → a new handover sealed and `handoverId` returned
- through the serve executor chain: a non-trusted request without a bearer → unauthorized; with a valid manager bearer → handled
  (follow `WorkflowExecutionGraphQLTests` for building authorized requests)

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-16-graphql-provider/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLProviderTests|TaskHandoverGraphQLTests|WorkflowExecutionGraphQLTests|ServeWeb" > tmp/work-handover/wh-16-graphql-provider/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/focused.log'
git diff --check
```

Both must end with exit=0 and a non-zero count; the existing GraphQL and serve suites must be green or baseline-classified.

## Done criteria

- [ ] All seven fields are executable over serve, the parity document command and the library; auth is enforced in serve
- [ ] The tests pass; the progress log is complete


## Scope amendment (2026-10-01, after run session-9)

`Sources/RielaWork/TaskDispatcher.swift` and `Tests/RielaWorkTests/TaskDispatcherTests.swift` are now owned by this plan: `TaskDispatcher.reserve` needs a `hostId` parameter forwarded to `AttemptReservationRequest` so `takeoverTask` reserves the successor on `input.hostId` (default stays "local"). Add a regression for the forwarded host. wh-16 now depends on wh-15 and runs alone.

### Scope amendment (2026-10-01, after run session-10)

wh-15 is accepted and committed. A partial wh-16 is committed ('wip: partial wh-16 ...'); complete it, do not restart it. This plan now also owns `WorkStore+Reservation.swift`, `WorkStore+Leases.swift`, `WorkStoreLeaseTests.swift` and `WorkStoreReservationTests.swift`. `authorizeAttemptLaunch` rotates the lease token digest, so the token `takeoverTask` returns cannot authenticate `heartbeatAttempt` or `reportAttempt` (focused 40/41, see tmp/work-handover/wh-16-graphql-provider/focused-retry3.log). Fix it so the token handed to the successor verifies against the stored lease digest after launch authorization, without weakening the one-use launch-token guarantee for local runs (for example a separate heartbeat token digest, or return the post-authorization token). Add regressions for heartbeat plus completed and suspended reportAttempt.

### Lease credential fix (2026-10-01, run session-11; design §14 and §21 R31)

This section decides the choice the session-10 amendment left open. Where it conflicts with the text above, this section wins.

Resume from HEAD, where the partial provider is at f4daa148. Do not restart the provider, the executor chains or the serve wiring.
The only failing behavior is the token handed to the successor. The provider currently returns `reservation.launchToken`
(`TaskHandoverGraphQLProvider.swift:196`). After `authorizeAttemptLaunch` (`WorkStore+Reservation.swift:342-356`), the lease
digest is `SHA256("consumed:<attemptId>:<sessionId>")`. That value can be derived from public ids, and the token
`verifyLeaseToken` (`WorkStore+Leases.swift:39-45`) is given fails to match it.

File-level changes:
- `Sources/RielaWork/WorkStore+Reservation.swift`
  - Add `public struct AuthorizedAttemptLaunch: Sendable { public var attempt: Attempt; public var leaseCredential: String }`.
  - Add `func authorizeAttemptLaunchIssuingLeaseCredential(attemptId: AttemptID, launchToken: String, now: Date = Date()) throws -> AuthorizedAttemptLaunch`.
    It holds today's `authorizeAttemptLaunch` body with one change: in place of the `consumed:` digest, mint
    `UUID().uuidString.lowercased()` (the idiom at `WorkStore+Reservation.swift:211` and `WorkStore+Director.swift:50`). Write
    `launchTokenDigest(credential)` to both `attempt.launch.tokenDigest` and `work_leases.token_digest` in the same
    transaction. Keep the `WHERE ... token_digest = <launch digest>` guard and the `changed == 1` check.
  - Keep `authorizeAttemptLaunch(attemptId:launchToken:now:) -> Attempt` with the same signature. It delegates to the new
    function and returns `.attempt`, discarding the credential. About 20 callers in files outside writePaths (for example
    `WorkStoreTakeoverTests.swift:212`, `DecisionApplierStoreTests.swift:568`, `TaskRuntimeExampleTests.swift:582`) must compile
    unchanged.
  - Remove the `consumed:` digest line entirely. No derivable digest may remain.
- `Sources/RielaWork/WorkStore+Leases.swift`: no behavior change is expected. `verifyLeaseToken` already compares against
  `work_leases.token_digest`. Touch it only if a test shows a gap.
- `Sources/RielaWork/TaskDispatcher.swift`: add `authorizeIssuingLeaseCredential(_ reservation: AttemptReservation, now: Date = Date()) throws -> AuthorizedAttemptLaunch`
  next to `authorize(_:now:)`, which stays as it is (`TaskDispatcherTests.swift:106-107` depend on it).
- `Sources/RielaCLI/TaskHandoverGraphQLProvider.swift`: `takeoverTask` calls `dispatcher.authorizeIssuingLeaseCredential` and
  returns `.leaseCredential` as `heartbeatToken`. `heartbeatAttempt` and `reportAttempt` keep using `verifyLeaseToken`.

Invariants, which a careless fix would break:
- Afterwards, `attempt.launch.tokenDigest == work_leases.token_digest` still holds. `markAttemptNodeStarted`
  (`WorkStore+Reservation.swift:373-380`) and the director child rotation (`WorkStore+Director.swift:46-56`) rely on it.
- Replaying the launch token after authorization still throws, because the digest is gone and the phase is no longer
  `reserved`.
- Do not add a column, and do not bump `schemaGeneration`. Store only the digest. Never write the credential to a log, an
  evidence payload, a progress log or a test failure message.
- Do not change `recoverPreLaunchReservation` or any pre-authorization path.
- Do not edit `TaskDispatch+Handover.swift` or other files outside writePaths. If `reconcileExternalTerminal` misbehaves,
  record it in the progress log as a finding.

Tests to add:
- `WorkStoreReservationTests`: after authorization, the lease digest equals `launchTokenDigest(leaseCredential)`, differs from
  the launch-token digest and from `launchTokenDigest("consumed:<attemptId>:<sessionId>")`, and equals
  `attempt.launch.tokenDigest`. A second authorization with the launch token throws. `markAttemptNodeStarted` still succeeds
  after authorization.
- `WorkStoreLeaseTests`: `verifyLeaseToken(leaseCredential)` succeeds, and `verifyLeaseToken(launchToken)` and
  `verifyLeaseToken("consumed:<attemptId>:<sessionId>")` both throw.
- `TaskDispatcherTests`: `authorizeIssuingLeaseCredential` returns a non-empty credential that differs from
  `reservation.launchToken`.
- `TaskHandoverGraphQLProviderTests`:
  - `takeoverTask` → the returned `heartbeatToken` makes `heartbeatAttempt` extend `expiresAt` with `fenced: false`.
  - The launch token → `unauthorized`.
  - `reportAttempt` with that token and a completed snapshot → task `succeeded` and an accept decision.
  - With a suspended snapshot → a new `handoverId`.
  - A wrong token → `unauthorized`.

Verification: the log directory is `tmp/work-handover/wh-16-graphql-provider/`. Each command must end with `exit=0`, and each test
command must report a non-zero test count and 0 failures.
```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-16-graphql-provider/build-s11.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/build-s11.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "WorkStoreLeaseTests|WorkStoreReservationTests|TaskDispatcherTests|WorkStoreTakeoverTests|DecisionApplierStoreTests|WorkStoreCancellationTests" > tmp/work-handover/wh-16-graphql-provider/work-s11.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/work-s11.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLProviderTests|TaskHandoverGraphQLTests|WorkflowExecutionGraphQLTests|ServeWeb" > tmp/work-handover/wh-16-graphql-provider/focused-s11.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-16-graphql-provider/focused-s11.log'
git diff --check
grep -rn 'consumed:' Sources/RielaWork
```
The last grep must print nothing (exit 1). Update the progress log's Blocked completion section to resolved, citing these logs.

### Serial-wave shared ownership (2026-10-01, after run session-11)

The remaining plans run strictly one at a time, so this plan may edit, as shared paths with minimal, documented changes, every task-dispatch, handover-runtime, work-store and decision file that no remaining plan owns (listed in this plan's `sharedPaths`). Do not block on those files; fix the defect where it lives and add a regression. Record each shared edit (file, reason, test) in the progress log.
For wh-16 specifically: completed `reportAttempt` fails with "reported task attempt has no recorded decision" in `TaskDispatch+Handover.swift` (tmp/work-handover/wh-16-graphql-provider/focused-r31-retry.log). Fix it so a completed remote report is reconciled and the director records its decision, exactly as for a local attempt. A partial wh-16 is committed ('wip: continue wh-16 ...'); complete it.
