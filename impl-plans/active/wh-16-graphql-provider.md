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
  "sharedPaths": [],
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
  evidence `{remoteHost, traits}`, then `authorizeAttemptLaunch`. Return `{attemptId, sessionId, fence, expiresAt, heartbeatToken:
  launch token, heartbeatMs: lease policy, packet}`. The controller does **not** run the workflow.
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

- The token is single-use for launch but is reused as the heartbeat and report credential. Only its digest is stored (lease row).
  Never log the token.
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
