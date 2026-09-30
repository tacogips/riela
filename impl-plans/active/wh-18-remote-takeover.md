# wh-18: Remote takeover (`task takeover --endpoint`) and `task serve --takeover`

```json
{
  "planId": "wh-18-remote-takeover",
  "planPath": "impl-plans/active/wh-18-remote-takeover.md",
  "wave": "W5",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/TaskRemoteTakeover.swift",
    "Sources/RielaCLI/TaskServeTakeover.swift",
    "Tests/RielaCLITests/TaskRemoteTakeoverTests.swift",
    "impl-plans/progress/wh-18-remote-takeover.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaLibrary.swift",
    "Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch+Director.swift",
    "Sources/RielaCLI/TaskDispatch+Handover.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskHandoverCommands.swift",
    "Sources/RielaCLI/TaskHandoverGraphQLProvider.swift",
    "Sources/RielaCLI/TaskHandoverRuntime.swift",
    "Sources/RielaCLI/TaskHandoverSupport.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaGraphQL/TaskHandoverGraphQL.swift",
    "Sources/RielaWork/DecisionApplier.swift",
    "Sources/RielaWork/HandoverBriefRenderer.swift",
    "Sources/RielaWork/HandoverCoordinator.swift",
    "Sources/RielaWork/HandoverPacketBuilder.swift",
    "Sources/RielaWork/HandoverProtocols.swift",
    "Sources/RielaWork/HandoverRedaction.swift",
    "Sources/RielaWork/TaskDispatcher.swift",
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/WorkHandover.swift",
    "Sources/RielaWork/WorkStore+Adoption.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Director.swift",
    "Sources/RielaWork/WorkStore+HandoverRequests.swift",
    "Sources/RielaWork/WorkStore+Handovers.swift",
    "Sources/RielaWork/WorkStore+Hosts.swift",
    "Sources/RielaWork/WorkStore+Isolation.swift",
    "Sources/RielaWork/WorkStore+Leases.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaWork/WorkStore+Schema.swift",
    "Sources/RielaWork/WorkStore+Takeover.swift",
    "Sources/RielaWork/WorkStore.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+Director.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+GuardPolicy.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskHandoverCommandTests.swift",
    "Tests/RielaCLITests/TaskHandoverDispatchTests.swift",
    "Tests/RielaCLITests/TaskHandoverGraphQLProviderTests.swift",
    "Tests/RielaCLITests/TaskHandoverLeaseTests.swift",
    "Tests/RielaCLITests/TaskHandoverRepositoryTests.swift",
    "Tests/RielaGraphQLTests/TaskHandoverGraphQLTests.swift",
    "Tests/RielaWorkTests/DecisionApplierCausalityStoreTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaWorkTests/DecisionApplierTests.swift",
    "Tests/RielaWorkTests/DeterministicDirectorHandoverTests.swift",
    "Tests/RielaWorkTests/HandoverCoordinatorTests.swift",
    "Tests/RielaWorkTests/HandoverPacketBuilderTests.swift",
    "Tests/RielaWorkTests/TaskDispatcherTests.swift",
    "Tests/RielaWorkTests/WorkHandoverModelsTests.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreHandoverRecordsTests.swift",
    "Tests/RielaWorkTests/WorkStoreHandoverRequestTests.swift",
    "Tests/RielaWorkTests/WorkStoreLeaseTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/WorkStoreTakeoverTests.swift",
    "Tests/RielaWorkTests/WorkStoreTests.swift"
  ],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCLI/RielaCommand.swift",
      "intendedEdit": "Add `case serve` to TaskCommandKind (after `reconcile`)."
    },
    {
      "path": "Sources/RielaCLI/TaskCommands.swift",
      "intendedEdit": "Route `.serve` to TaskServeTakeover."
    },
    {
      "path": "Sources/RielaCLI/TaskHandoverCommands.swift",
      "intendedEdit": "In the takeover parser, add `--endpoint <url>`, `--auth-token <t>`, `--auth-token-env <NAME>` and `--manager-session-id <id>`; when `--endpoint` is set, route to TaskRemoteTakeover. `--endpoint` with `--force-orphan` is a usage error (fencing is controller-side)."
    }
  ],
  "progressLog": "impl-plans/progress/wh-18-remote-takeover.md"
}
```

## Intent and context

This is the successor side of cross-host takeover. It pulls the packet, reserves the attempt on the controller, runs locally
in its own session store, heartbeats, and reports at terminal. The controller verifies and runs the director on the report
(wh-16). It also adds an unattended poller (design §3.10, §10.2, QA Q3 default: ship `task serve --takeover` as its own loop, R11, R16).
HTTP pattern: `URLSessionWorkflowGraphQLRunTransport` (`WorkflowCommands.swift:367-400`: bearer header,
`X-Riela-Manager-Session-Id`, trace headers, http/https check). The field names are pinned in wh-12.

Non-goals: controller logic (wh-16), a local-store `task takeover` (wh-15), and any new auth scheme.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-18-remote-takeover/`,
writePaths plus the shared edits, arm64 logs, temp stores and repos, no network, no git state changes, own progress log).

## Deliverables

- `protocol TaskHandoverGraphQLTransporting: Sendable { func execute(endpoint: String, query: String, variables: JSONObject, auth: TaskRemoteAuth) async throws -> JSONObject }`.
  `URLSessionTaskHandoverGraphQLTransport` mirrors the workflow transport's headers. Test transport:
  `InProcessTaskHandoverGraphQLTransport(executor:)` calls a `GraphQLDocumentExecuting` chain (the wh-16 provider wrapped as serve wraps it).
- `TaskRemoteTakeover.run(taskId:handoverId?:endpoint:auth:traits:workingDirectory:cloneInto:sessionStore:output:)`:
  1. `taskHandover` → packet. Verify its digest locally (recompute `canonicalDigest()` from `packet` JSON; it must equal `digest`).
  2. If the packet has a repository deliverable with `state != .published` or a remote that is not a URL → refuse
     ("remote takeover needs a published branch with a reachable remote", design §17).
  3. `takeoverTask(hostId: <local host id from HostCapabilityResolver/profile, else ProcessInfo hostName>, traits)` →
     reservation `{attemptId, sessionId, fence, heartbeatToken, heartbeatMs}`.
  4. Materialize the branch (`GitBranchWorkspaceRuntime.materialize`, `--clone-into` handling as in wh-15). Resolve the workflow
     locally from `packet.workflow` (name, scope, definition dir) with `FileSystemWorkflowBundleResolver` and `--working-dir`.
  5. In the local session store, create a `.created` snapshot **with the controller's `sessionId`** (the report must carry
     that id), `entryStepId = resumeStepId`. Import the bundle (wh-05 bundle init), append the answer message if the packet or
     the `taskHandover` payload includes an answer, save, then run through `WorkflowRunCommand` with `resumeSessionId`, variables
     `handover` and `rielaTask {taskId, attemptId, fence}`, and `workingDirectory = isolation.path`.
  6. A heartbeat task runs every `heartbeatMs`. `fenced == true` or an `unauthorized` error → cancel the run, persist the local session as
     `failed(.leaseLost)`, do not report, exit `.failure` with "fenced out by a newer takeover".
  7. At terminal (`completed | failed | suspended`): when there is an isolation, run `checkpoint` + `publish` (fence checked via one last
     heartbeat first), collect deliverables (`DeliverableCollector`), then `reportAttempt(snapshot, deliverables)` (≤ 4 MiB; larger →
     fail with a clear error and keep heartbeating until the lease expires. Never truncate silently). Render
     `{taskId, attemptId, sessionId, controllerTaskState, handoverId?}`. The exit code is `.success`, `.failure` or `.suspended`, following the local status.
- `TaskServeTakeover.run(options)`: `task serve --takeover [--traits …] [--endpoint URL] [--poll-interval-ms 5000] [--once]`
  (plus the auth flags). Without `--takeover` → usage error "task serve supports --takeover only until Work Runtime P3". Each poll:
  `tasksAwaitingHandover(traits:)` (remote), or `store.tasksAwaitingHandover` (local when no endpoint). Skip `needsAnswer`. Take the
  first row by `createdAt` and run the remote takeover (or the local `TaskDispatch` takeover), one at a time. `--once` exits after one poll.
  SIGINT stops cleanly (reuse the CLI signal cancellation used by `task run`).

## Pitfalls

- Never talk to the controller's SQLite directly. Everything goes through GraphQL.
- The heartbeat must start before the workflow runs and stop after the report.
- The successor's local session id must equal the controller's attempt `sessionId`, or wh-16 rejects the report.
- Auth token values come from `--auth-token` or the env var named by `--auth-token-env`. Never echo them.

## Tests (`TaskRemoteTakeoverTests`, two temp stores: controller A, successor B; in-process transport over wh-16's provider + serve auth wrapper)

- a presence handover sealed in A; successor B with traits `[userReachable]` → heartbeats advance A's lease `expiresAt`; the report → A's task
  `succeeded` with an accept decision (the director ran) and lineage A → B
- a successor without the traits → conflict error, no reservation in A
- missed heartbeats: stop B's heartbeats via a test hook, `fenceOrphan` in A with an injected `now` → B's next heartbeat is fenced → B's local session
  `failed(.leaseLost)`, no report, exit failure
- B's workflow suspends again → the report returns a new `handoverId` sealed in A
- repository: a temp repo + bare remote shared by A and B → B materializes the published branch, commits, and publishes before the report; A holds
  `publication` evidence whose repository deliverable `headCommit` equals B's pushed sha, and the bare remote has that sha on the branch
- `--endpoint` with `--force-orphan` → usage; an unpublished repository deliverable → refused
- `task serve --takeover --once --traits userReachable` (local mode) takes the eligible presence task and skips an unanswered S1 task; without `--takeover` → usage

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-18-remote-takeover/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-18-remote-takeover/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "TaskRemoteTakeoverTests|TaskHandoverCommandTests|TaskHandoverGraphQLProviderTests" > tmp/work-handover/wh-18-remote-takeover/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-18-remote-takeover/focused.log'
git diff --check
```

Both must end with exit=0 and a non-zero count. This plan proves acceptance signals 3 (second clone over the remote path) and 6.
Record the test names in the progress log.

## Done criteria

- [ ] Remote takeover and serve are implemented to the flow above; the auth and fence behaviors are tested
- [ ] The tests pass; the progress log is complete

### Serial-wave shared ownership (2026-10-01, after run session-11)

The remaining plans run strictly one at a time, so this plan may edit, as shared paths with minimal, documented changes, every task-dispatch, handover-runtime, work-store and decision file that no remaining plan owns (listed in this plan's `sharedPaths`). Do not block on those files; fix the defect where it lives and add a regression. Record each shared edit (file, reason, test) in the progress log.

### Answer delivery amendment (2026-10-01, after run session-14)

wh-17 is accepted. A partial wh-18 is committed ('wip: partial wh-18 remote takeover'); complete it. Adversarial review (mid) found that remote takeover never delivers the stored S1 answer: the packet is sealed before the answer exists and neither `takeoverTask` nor `taskHandover` carries it. This plan now has shared ownership of `Sources/RielaGraphQL/TaskHandoverGraphQL.swift`, `Tests/RielaGraphQLTests/TaskHandoverGraphQLTests.swift`. Add the bound answer (question id, payload, answeredBy, answeredAt) to the `takeoverTask` reservation payload and the provider, deliver it to the successor as the `handover.answer` variable and as a delivered message to the resume step exactly as the local takeover does, and refuse a remote takeover of an unanswered S1 handover. Add a provider-backed answered-S1 remote takeover test. Leave SDL regeneration and surface-catalog rows to wh-20; note any schema change in the progress log so wh-20 regenerates the SDL.

### R34 answer contract (2026-10-01, run session-15)

Design §10.2 steps 2-3 and §21 R34 (accepted in session-15) pin the answer delivery amendment. Scope is exactly this; nothing else in the plan changes.

Contract (`Sources/RielaGraphQL/TaskHandoverGraphQL.swift`):
- Add `public struct GraphQLHandoverAnswer: Codable, Equatable, Sendable { questionId: String; payload: JSONObject; answeredBy: JSONObject; answeredAt: String }` and `answer: GraphQLHandoverAnswer?` on `GraphQLTakeoverTaskPayload`. Add the init parameter with a default of `nil`, so `failurePayload` and every existing call site compile unchanged.
- In `taskHandoverGraphQLSchemaTypes`, add `type HandoverAnswerPayload { questionId: String!, payload: JSONObject!, answeredBy: JSONObject!, answeredAt: String! }` and the field `answer: HandoverAnswerPayload` on `TakeoverTaskPayload`. Do NOT change `TakeoverTaskInput`, `HandoverPacket`, `TaskHandoverPayload` or the `taskHandover` query.
- Do NOT touch `GraphQLSchemaGenerator.swift`, `GraphQLContractProjector+Schema.swift`, `GraphQLVariableValidation.swift` or any SurfaceCatalog file (wh-20 step 3). Record in the progress log: "schema change for wh-20: new type HandoverAnswerPayload; new field TakeoverTaskPayload.answer".

Controller (`Sources/RielaCLI/TaskHandoverGraphQLProvider.swift` `takeoverTask`):
- After loading the packet and before the trait check and `requestTakeover`, read `located.store.latestAnswer(handoverId: packet.id)`. This is the ONLY lookup (R25). Do not filter `listDecisions` here.
- If `packet.reason` is `.userInputRequired(question)` and the answer is nil, throw `TaskHandoverGraphQLError(code: "conflict", message: "handover <handoverId> needs an answer: riela task answer <taskId> --question <question.id> …")`. The refusal happens before any reservation, so no attempt, lease or fence is created.
- On success, set `answer` only for a `.userInputRequired` packet:
  - `questionId` and `payload` come from `HandoverAnswer`.
  - `answeredBy` is the `DecisionProducer` JSON encoding (same `JSONEncoder` → `JSONObject` route the provider already uses).
  - `answeredAt` is `Self.timestamp(answer.answeredAt)`, the same helper as `expiresAt`.
  - For every other reason, `answer` stays nil.

Successor (`Sources/RielaCLI/TaskRemoteTakeover.swift`):
- Decode `answer` from the `takeoverTask` response, and add `answer { questionId payload answeredBy answeredAt }` to the takeover selection set.
- If the packet is S1 and `answer` is absent, fail with a clear error BEFORE saving the local session or launching the runner. Do not report.
- If `answer` is present, mirror `TaskDispatch+Handover.swift` (`:221-235` variables, `:393-406` message):
  - Set `"answer": payload` inside the `handover` variable object, and `"delivered": {"handover": {"answer": payload}}` as a top-level variable.
  - Before the snapshot is saved, append one `WorkflowMessageRecord` to the imported messages with these fields:
    - `communicationId` `handover-answer-<handoverId>-<attemptId>`
    - `workflowExecutionId` = the local session id
    - `fromStepId` nil and `toStepId` = `packet.contract.resumeStepId`
    - `sourceStepExecutionId` = the last imported execution's id
    - payload `{"handover": {"answer": payload}}`
    - `.delivered`
    - `createdOrder` = max + 1
    - `createdAt` = parsed `answeredAt`
  - If the bundle imported no execution, skip the message without crashing. This is the same guard as the local `if let sourceExecution`.

Pitfalls:
- Do not put the answer into the packet or recompute the packet digest: the packet is sealed (R17/R19).
- Do not rely on `requestTakeover`'s `WorkStoreError`. It surfaces as the generic `internal` error (`TaskHandoverGraphQL.swift:274`).
- Never log or render the answer payload in stderr.
- Parse `answeredAt` with an `ISO8601DateFormatter` whose `formatOptions` are `[.withInternetDateTime, .withFractionalSeconds]`, the same options as the controller's `timestamp` helper (`TaskHandoverGraphQLProvider.swift:321`). A default formatter returns nil for this form.
- If parsing fails, treat the response as malformed: fail before launch like a missing answer. Do not fall back to `Date()`.
- Stub test fixtures must use the fractional form (for example `2026-10-01T00:00:00.000Z`).
- Keep the existing `isPendingSchemaRegistration` helper. The new provider-backed test uses it until wh-20 step 3, and wh-20 removes it.

Tests (hermetic temp stores, no network, no git on the process-cwd repository):
- `TaskHandoverGraphQLTests` (RielaGraphQLTests):
  - A payload with `answer` round-trips encode/decode with all four fields.
  - A payload without `answer` decodes to nil.
  - `taskHandoverGraphQLSchemaTypes` contains `HandoverAnswerPayload` and `answer: HandoverAnswerPayload`.
- `TaskHandoverGraphQLProviderTests`, calling the provider directly with no variable validation (these pass today, with no pending branch):
  - S1 handover sealed, then `answerTask`, then `takeoverTask` → `answer.questionId` equals the question id, `answer.payload` equals the stored answer, and `answeredAt` is non-empty.
  - S1 handover sealed with no answer, then `takeoverTask` → `code == "conflict"`, the message contains `needs an answer`, and the controller attempt count and lease rows are unchanged.
  - Presence handover, then `takeoverTask` → `answer == nil`.
- `TaskRemoteTakeoverTests`:
  - Stub transport returns an S1 packet with `answer` → the resume step's first execution `inputSnapshot` contains `handover.answer`, and the local session has a delivered message to `resumeStepId` with id `handover-answer-<handoverId>-<attemptId>`, and that message's `createdAt` equals the stub's `answeredAt`.
  - Stub S1 without `answer` → exit failure, no `reportAttempt` call, and no local session saved.
  - Provider-backed answered-S1: controller A is a `TaskExampleHarness` running `task-handover-answer`, which suspends; then `answerTask`; then B runs `TaskRemoteTakeover` over `InProcessTaskHandoverGraphQLTransport`. Assert A's task `succeeded`, a `.takeover` successor attempt exists, and B's resume-step input has the answer. Until wh-20 step 3 it takes the same strict `isPendingSchemaRegistration` branch (strict `XCTExpectFailure`, A's attempt count unchanged, return) as the two existing signal-6 tests.

Verification (the arm64 wrapper, logs under `tmp/work-handover/wh-18-remote-takeover/`):
- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-18-remote-takeover/build-r34.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-18-remote-takeover/build-r34.log'` → exit=0.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskRemoteTakeoverTests|TaskHandoverCommandTests|TaskHandoverGraphQLProviderTests|TaskHandoverGraphQLTests" > tmp/work-handover/wh-18-remote-takeover/focused-r34.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-18-remote-takeover/focused-r34.log'` → exit=0, 0 unexpected failures, and exactly three strict expected failures (the pending branches). Record testsRun and failureCount.
- `grep -c "isPendingSchemaRegistration(" Tests/RielaCLITests/TaskRemoteTakeoverTests.swift` → 4 (the helper plus three call sites).
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <each changed Swift file>'` → exit 0.
- `git diff --check` → exit 0.

Done criteria (R34):
- [ ] `GraphQLTakeoverTaskPayload.answer` and the `HandoverAnswerPayload` SDL block exist; `TakeoverTaskInput` is unchanged
- [ ] The provider refuses an unanswered S1 with `conflict` before reserving, and returns the bound answer for an answered S1
- [ ] The remote successor delivers `handover.answer`, `delivered` and the resume-step message; an S1 response with no answer fails before launch
- [ ] The tests above pass (focused-r34.log exit=0); the schema change for wh-20 is recorded in the progress log
