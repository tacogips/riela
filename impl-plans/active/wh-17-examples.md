# wh-17: Examples `task-handover-answer`, `task-handover-presence`, `task-handover-orphan`

```json
{
  "planId": "wh-17-examples",
  "planPath": "impl-plans/active/wh-17-examples.md",
  "wave": "W4",
  "dependsOn": [],
  "writePaths": [
    "examples/task-handover-answer",
    "examples/task-handover-presence",
    "examples/task-handover-orphan",
    "Tests/RielaCLITests/RielaExampleCatalog.swift",
    "Tests/RielaCLITests/RielaExampleParityTests.swift",
    "Tests/RielaCLITests/TaskHandoverExampleTests.swift",
    "impl-plans/progress/wh-17-examples.md"
  ],
  "sharedPaths": [
    "README.md",
    "Sources/RielaCLI/RielaLibrary.swift",
    "Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaCLI/TaskDispatch+Director.swift",
    "Sources/RielaCLI/TaskDispatch+Handover.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskHandoverGraphQLProvider.swift",
    "Sources/RielaCLI/TaskHandoverRuntime.swift",
    "Sources/RielaCLI/TaskHandoverSupport.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
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
      "path": "README.md",
      "intendedEdit": "Next to the `task-repair-loop` example link (~line 846), add one sentence linking the three new examples' READMEs."
    }
  ],
  "progressLog": "impl-plans/progress/wh-17-examples.md"
}
```

## Intent and context

This plan implements design §15.1 exactly. Each example ships a `mock-scenario.json`, is registered in `rielaExampleWorkflowNames()`,
and raises `ExampleCatalog.expectedMockScenarioCount` from 40 to 43. The generic parity loop learns one explicit set of examples that end suspended.
The full task flows run in `TaskHandoverExampleTests` through `TaskExampleHarness`, following the
`TaskRuntimeExampleTests` precedent. Copy the layout of `examples/task-repair-loop` (`workflow.json`, `nodes/*.json`, `prompts/*.md`,
`mock-scenario.json`, `EXPECTED_RESULTS.md`, `README.md`).

Non-goals: new runtime behavior (all of it comes from wh-02 and wh-14), CLI `--mock-scenario` for `task` commands (not added), and docs beyond the example READMEs.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-17-examples/`,
writePaths plus the README note, arm64 logs, temp stores, no git state changes, own progress log).

## Deliverables

- **task-handover-answer**: steps `plan` → `apply` → `report` (agent nodes; scenario-mock). The `plan` mock payload carries
  `handover {reason: userInputRequired, question {id: "q-deploy-target", text, options [staging, production],
  answerSchema {type: object, required: [option]}}, progressNote, resumeStepId: "apply"}` plus a small business payload
  that satisfies `plan`'s `output.jsonSchema`. The `apply` prompt uses `{{handover.answer.option}}`. The downstream `resumeStepId`
  means the successor never re-runs `plan`, so the per-node mock sequence cannot re-emit the envelope (§15.1).
- **task-handover-presence**: steps `check-login` → `publish` → `report`. The `check-login` mock carries
  `handover {reason: userPresenceRequired, presence {traits: [userReachable], instructions: "Run `gh auth login` on this host"},
  resumeStepId: "publish"}`.
- **task-handover-orphan**: steps `work` → `finish` with plain mock payloads (no envelope). The plain run completes.
- Each `EXPECTED_RESULTS.md` states the plain mock outcome (answer and presence: exit 5, `suspended`, suspend record; orphan:
  `completed`) and the harness flow outcome. Each `README.md` explains the scenario and the exact CLI steps
  (`task run`, `task answer`, `task takeover [--traits userReachable]`, `task takeover --force-orphan`).
- `RielaExampleCatalog.swift`: add the three names in sorted position.
- `RielaExampleParityTests.swift`: `expectedMockScenarioCount = 43`. Add `static let expectedSuspendedMockScenarioExamples: Set<String> =
  ["task-handover-answer", "task-handover-presence"]`. In `testMockScenarioExamplesRunThroughSwiftCLI`, for names in the set, assert
  `result.exitCode == .suspended`, `payload.status == .suspended` and `payload.session.suspend != nil` instead of success and completed.
  Every other example keeps its assertion.
- `TaskHandoverExampleTests` (harness, `scenarioPath` = the example's `mock-scenario.json`):
  - answer: seed the task → dispatch → `.suspended` with a stable digest (reload and recompute) → `TaskHandoverRuntime.answer(option: staging)` →
    takeover dispatch → `completed`. The `apply` execution's `inputSnapshot` contains the answer. Session B executions include the imported `plan`.
  - presence: dispatch → suspended → takeover with no local traits → waiting `host-traits-unavailable: userReachable` →
    with `localTraits: [.userReachable]` → completed.
  - orphan: seed with `guard.lease.ttlMs = 1000`. Reserve an attempt and let it die before execution (the harness `beforeExecution`
    hook throws, so the lease row stays while no process runs). Before the forced takeover, record the predecessor's `attemptId`
    and its lease `fence` (`store.loadLease(attemptId:)`, wh-03 API). `forceOrphan` with `now` = real now → refused (not expired).
    With `now` = expiresAt + 1 s → packet `ownerLost`. Takeover dispatch → completed. `task show` data: predecessor
    `supersededByFence`, lineage A → B. Revived-owner legs (§15.1): after the takeover, a heartbeat by the revived predecessor,
    `store.heartbeat(attemptId: <predecessor>, fence: <recorded predecessor fence>, now:, ttlMs:)`, returns `false` (fenced), and the
    predecessor attempt is `reconciled` with outcome `failed` / failureKind `leaseLost`.
    - Divergence from §15.1 ("owner stopped after launch"): the example workflows have no long-running node, so this test uses the
      never-launched owner. The live-owner leg (a *running* owner's heartbeat fails, its run is cancelled and its session persists
      `failed(.leaseLost)`) is proven by wh-14 `TaskHandoverLeaseTests` ("a running owner, then fenceOrphan ... session is
      `failed(.leaseLost)`"). Record this divergence in the wh-17 progress log.
    - Firm rule: `fenceOrphan` accepts a `prepared` or `running` predecessor (wh-03 contract). If it does not, the test fails and that
      is a defect to fix under wh-20's serial repair authority. Do not weaken the test.

## Pitfalls

- Node output schemas must not declare `handover` (wh-01 validation error). The envelope sits next to the business keys.
- Examples must validate with no errors (`RielaExampleParityTests` validation test) and no new warnings (no memory or KV add-ons).
- Use provider `scenario-mock` and a model string like `task-repair-loop`. No network or API keys.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-17-examples/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-17-examples/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverExampleTests|RielaExampleParityTests|TaskRuntimeExampleTests" > tmp/work-handover/wh-17-examples/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-17-examples/focused.log'
arch -arm64 /bin/zsh -lc 'for w in task-handover-answer task-handover-presence task-handover-orphan; do .build/debug/riela workflow validate $w --workflow-definition-dir examples; echo "validate $w exit=$?"; done > tmp/work-handover/wh-17-examples/validate.log 2>&1'
git diff --check
```

The build and tests must end with exit=0. `validate.log` must show `exit=0` three times.
If the sandbox cannot run the built binary (for example because it touches `~/.riela`), record that as blocked for wh-20 to run. It is not a pass.
If the validate flag spelling differs, use the form `riela workflow validate --help` documents and record it.

## Done criteria

- [ ] The three examples exist with all six artifact kinds; the catalog and count are updated; the suspended set is asserted; the revived-owner fence assertions are in the orphan test
- [ ] The harness flows pass; the parity loop passes; the progress log is complete


## Resume notes (2026-10-01, after run session-9)

A partial wh-17 implementation from run session-9 was parked because it broke the shared build: `tmp/work-handover/parked/wh-17-tracked.patch` (README.md, RielaExampleCatalog.swift, RielaExampleParityTests.swift) and `tmp/work-handover/parked/wh-17-untracked.tar` (TaskHandoverExampleTests.swift, the three examples/task-handover-* bundles, the progress log). Restore them first (`git apply tmp/work-handover/parked/wh-17-tracked.patch` and `tar -xf tmp/work-handover/parked/wh-17-untracked.tar`), then fix `TaskHandoverExampleTests.swift`, which passes an unsupported `beforeExecution` argument to `TaskDispatch.run`, against the current API. wh-17 now depends on wh-16 and runs alone.

At HEAD 09953552, `beforeExecution` is a stored property on `TaskDispatch` (`Sources/RielaCLI/TaskDispatch.swift:130`, invoked at `:322`), not a `run(...)` parameter. Set it on the `TaskDispatch` value before calling `run`, and do not add a parameter to `TaskDispatch.run`, which is outside writePaths. Before running any test, confirm that `arch -arm64 /bin/zsh -lc 'swift build'` exits 0 with the restored files.

### Serial-wave shared ownership (2026-10-01, after run session-13)

The remaining plans run strictly one at a time, so this plan may edit, as shared paths with minimal, documented changes, every task-dispatch, handover-runtime, work-store, decision and GraphQL-provider file that no remaining plan owns (listed in `sharedPaths`). Do not block on those files; fix a defect where it lives and add a regression. Record each shared edit (file, reason, test) in the progress log.

For wh-17: a partial wh-17 is committed ('wip: partial wh-17 task handover examples'); complete it. The orphan example exposed a runtime defect: successor guard evaluation at `Sources/RielaCLI/TaskDispatch.swift:432-439` rejects the takeover with "task attempt has no durable terminal session for guard evaluation" when the fenced dead predecessor never persisted a terminal session (tmp/work-handover/wh-17-examples/orphan-after-review.log). Fix it in the runtime so guard evaluation accepts a fenced, reconciled `failed(.leaseLost)` or never-launched predecessor without violating R26 (single terminal write), add a runtime regression, then make the orphan example pass end to end with a real session (no fake session).
