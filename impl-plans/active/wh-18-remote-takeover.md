# wh-18: Remote takeover (`task takeover --endpoint`) and `task serve --takeover`

```json
{
  "planId": "wh-18-remote-takeover",
  "planPath": "impl-plans/active/wh-18-remote-takeover.md",
  "wave": "W5",
  "dependsOn": [
    "wh-17-examples"
  ],
  "writePaths": [
    "Sources/RielaCLI/TaskRemoteTakeover.swift",
    "Sources/RielaCLI/TaskServeTakeover.swift",
    "Tests/RielaCLITests/TaskRemoteTakeoverTests.swift",
    "impl-plans/progress/wh-18-remote-takeover.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch+Director.swift",
    "Sources/RielaCLI/TaskDispatch+Handover.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskHandoverCommands.swift",
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
