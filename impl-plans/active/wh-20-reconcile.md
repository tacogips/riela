# wh-20: Serial reconciliation — join audit, catalog rows, SDL, gates, full verification, plan closure

```json
{
  "planId": "wh-20-reconcile",
  "planPath": "impl-plans/active/wh-20-reconcile.md",
  "wave": "W6 (serial)",
  "dependsOn": [
    "wh-19-docs-skills"
  ],
  "writePaths": [
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "impl-plans/active/work-handover-and-takeover.md",
    "impl-plans/README.md",
    "impl-plans/progress/wh-20-reconcile.md"
  ],
  "sharedPaths": [
    "README.md",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
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
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
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
    "Tests/RielaCLITests/TaskRemoteTakeoverTests.swift",
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
    "Tests/RielaWorkTests/WorkStoreTests.swift",
    "impl-plans/completed"
  ],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCore/SurfaceCatalog+Rows.swift",
      "intendedEdit": "Only if the GraphQL-only operation rows live here rather than in +RowsCLI: add the handover field rows."
    },
    {
      "path": "Sources/RielaCLI/CLISurfaceEnumeration.swift",
      "intendedEdit": "Only if a parity gate reports a missing session subcommand or option enumeration for the new commands."
    },
    {
      "path": "Tests/RielaCLITests/TaskRemoteTakeoverTests.swift",
      "intendedEdit": "After step 3 registers the schema, delete the isPendingSchemaRegistration helper and its three strict XCTExpectFailure pending branches so the provider-backed signal-6 and answered-S1 flows run unconditionally."
    },
    {
      "path": "README.md",
      "intendedEdit": "One link to docs/work-handover.md in the Work Runtime section."
    },
    {
      "path": "impl-plans/completed",
      "intendedEdit": "Move the umbrella plan and wh-00…wh-20 here only if every completion criterion has evidence; otherwise leave everything active."
    }
  ],
  "progressLog": "impl-plans/progress/wh-20-reconcile.md"
}
```

## Intent and context

This plan is the single serial owner of shared indexes, generated SDL, parity gates and final evidence (umbrella "Common
execution contract" rule 7). It runs after every other plan has joined. **Serial repair authority:** to fix a
regression or drift found here, it may edit any file in the union of earlier plans' `writePaths`. Record each such edit
with its cause, and rerun that plan's focused verification.

Non-goals: new features, redesign, and anything outside the accepted scope. A defect that needs a design change is recorded as
a finding and the plan stays active.

## Tasks

1. **Join audit.** For each plan, compare the current file hashes with the posthashes in its progress log. Investigate every drift
   (another plan's later edit is fine if it matches that plan's sharedPathNotes). Confirm that `git status --porcelain=v1 -uall`
   contains no scratch files outside `tmp/`.
2. **Catalog rows.** Imitate `taskMutationRows` (`SurfaceCatalog+RowsCLI.swift:76-106`):
   - CLI rows: `task.handover`, `task.takeover`, `task.answer`, `task.handovers`, `task.reconcile`, `task.serve`,
     `session.handover`, each with its exact `cliOptions` as implemented (read each parser). Kinds: mutation for handover/answer/reconcile,
     process for takeover/serve, query for handovers. GraphQL column bound where a field exists
     (`task.handover` ↔ `requestTaskHandover`, `task.answer` ↔ `answerTask`, `task.takeover` ↔ `takeoverTask`) via
     `graphQLMutation(...)`, as `routineCLIRows` does. Otherwise use the P5 `.blocked` evidence. Skills: `["riela-workflow-run"]`.
   - GraphQL-only rows for `taskHandover`, `tasksAwaitingHandover`, `heartbeatAttempt`, `reportAttempt` (skills
     `["riela-workflow-reference"]`), in the file where other GraphQL-only rows live.
3. **SDL.** Add the seven signatures to `GraphQLSchemaGenerator.rootFields` (exact wh-12 arguments and types). Add
   `taskHandoverGraphQLSchemaTypes` to `handWrittenSchemaBlocks` and to `handWrittenSchemaBlockNames`. Then run
   `scripts/surface-parity/generate-sdl.sh`, and run it again to prove an empty diff on the second pass.
4. **Gates and focused suites, serially.** Run the parity suites, then every child plan's focused filter, then the example checks with the built binary.
5. **Full suite** compared with the wh-00 baseline. Classify each failure as `pre-existing` (in the baseline list), `flake` (passes on
   an isolated rerun, with both logs kept) or `regression` (fix it under the serial repair authority and rerun).
6. **Lint.** `swiftlint --strict` on every Swift file changed on the branch since `01b38f02`.
7. **Closure.** Update the umbrella Module Status, check each Completion Criteria box with evidence (test names and log paths),
   update the umbrella and `impl-plans/README.md` Active Plans line, and add the README docs link. Archive only if **every** box has
   evidence. Otherwise leave the plans active with an accurate progress log. Do not commit or push here; that is a workflow step.

## Verification (record every log and exit line)

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-20-reconcile/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-20-reconcile/build.log'
scripts/surface-parity/generate-sdl.sh > tmp/work-handover/wh-20-reconcile/sdl-1.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-20-reconcile/sdl-1.log
scripts/surface-parity/generate-sdl.sh > tmp/work-handover/wh-20-reconcile/sdl-2.log 2>&1; git diff --stat -- Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift > tmp/work-handover/wh-20-reconcile/sdl-2-diff.txt
arch -arm64 /bin/zsh -lc 'swift test --filter "SurfaceParity" > tmp/work-handover/wh-20-reconcile/parity.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-20-reconcile/parity.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "HandoverContractsTests|JSONCanonicalTests|WorkHandoverModelsTests|WorkStoreHandoverRecordsTests|DeterministicWorkflowRunnerSuspendTests|SessionResumeSuspendedTests|WorkStoreLeaseTests|WorkStoreTakeoverTests|WorkStoreHandoverRequestTests|HandoverPacketBuilderTests|HandoverCoordinatorTests|TaskAdoptionTests|RuntimeHistoryImportHandoverTests|BackendWaitSignalClassifierTests|GitBranchWorkspaceRuntimeTests|GitPublishBranchAddonTests|DeliverableCollectorTests|HandoverSinkTests|BackendCapabilityPlacementTraitsTests|HostTraitsResolverTests|DeterministicDirectorHandoverTests|LoopNotificationHandoverTests|TaskHandoverGraphQLTests|RielaDataGarbageCollectorHandoverTests|TaskHandoverDispatchTests|TaskHandoverLeaseTests|TaskHandoverRepositoryTests|HandoverRequestAddonTests|TaskHandoverCommandTests|TaskHandoverGraphQLProviderTests|TaskHandoverExampleTests|RielaExampleParityTests|TaskRemoteTakeoverTests" > tmp/work-handover/wh-20-reconcile/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-20-reconcile/focused.log'
arch -arm64 /bin/zsh -lc 'for w in task-handover-answer task-handover-presence task-handover-orphan; do .build/debug/riela workflow validate $w --workflow-definition-dir examples; echo "validate $w exit=$?"; .build/debug/riela workflow run $w --workflow-definition-dir examples --mock-scenario examples/$w/mock-scenario.json --session-store tmp/work-handover/wh-20-reconcile/sessions --output json; echo "run $w exit=$?"; done > tmp/work-handover/wh-20-reconcile/examples.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test > tmp/work-handover/wh-20-reconcile/full-swift-test.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-20-reconcile/full-swift-test.log'
arch -arm64 /bin/zsh -lc 'git diff --name-only 01b38f02 -- "*.swift" | xargs swiftlint lint --strict > tmp/work-handover/wh-20-reconcile/swiftlint.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-20-reconcile/swiftlint.log'
git diff --check
```

The expected results are:
- The build, parity and focused runs end with exit=0.
- `sdl-2-diff.txt` is empty.
- `examples.log` shows validate exit=0 three times, `run task-handover-answer exit=5`, `run task-handover-presence exit=5` and `run task-handover-orphan exit=0`.
- Every failure in the full suite is classified, with no unfixed regression.
- swiftlint ends with exit=0.

Use the flag spellings each command's `--help` shows, and record any adjustment.

## Done criteria

- [ ] The join audit is clean; the catalog rows and SDL are in place; the parity gates are green
- [ ] All focused suites and example checks pass; the full suite has no new failures against wh-00
- [ ] The umbrella Completion Criteria are checked with evidence; archive or keep active accordingly; the README and index are updated


## Full-suite gate (amended 2026-09-30)

The base commit already fails one test (`WorkflowCommandCrossWorkflowDispatchTests.testSubprocessAbruptTerminationCheckpointsReopenCanonicalSQLiteWithoutDuplicatingDurableEffect`, a 180 s scratch-build subprocess timeout; see `impl-plans/progress/wh-00-baseline.md`). So the raw `swift test` exit status is informational: report it as `suiteExit`. The behavioral full-suite gate is the baseline-comparison command in the dispatch manifest. It exits 0 only when the suite log ends with an `exit=` line and `tmp/work-handover/wh-20-reconcile/new-failures.txt` is empty. If a baseline test newly passes or the timing test fails differently, record it and do not treat it as a regression. Any other new failure must be fixed or classified with evidence.

### Serial-wave shared ownership (2026-10-01, after run session-13)

The remaining plans run strictly one at a time, so this plan may edit, as shared paths with minimal, documented changes, every task-dispatch, handover-runtime, work-store, decision and GraphQL-provider file that no remaining plan owns (listed in `sharedPaths`). Do not block on those files; fix a defect where it lives and add a regression. Record each shared edit (file, reason, test) in the progress log.

### Pending-branch removal and R34 schema (2026-10-01, run session-15)

wh-18 adds `type HandoverAnswerPayload` and the field `TakeoverTaskPayload.answer` to `taskHandoverGraphQLSchemaTypes` (design §21 R34). Step 3 registers that constant as a whole, so they need no separate block. After the second SDL pass, confirm that `HandoverAnswerPayload` appears in the generated schema.

After step 3, delete `isPendingSchemaRegistration`, `pendingSchemaRegistrationMessage` and all three pending branches in `Tests/RielaCLITests/TaskRemoteTakeoverTests.swift`, together with their strict `XCTExpectFailure` calls. This applies to the two signal-6 provider tests and the wh-18 answered-S1 provider test. Do not weaken any assertion that follows a branch.

Evidence:
- `! grep -q -E "isPendingSchemaRegistration|XCTExpectFailure" Tests/RielaCLITests/TaskRemoteTakeoverTests.swift` exits 0.
- `grep -q "HandoverAnswerPayload" Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` exits 0.
- In `focused.log`, `TaskRemoteTakeoverTests` passes with no expected failures.

If a provider-backed test fails once the branch is gone, it is a regression: fix it under the serial repair authority. Never restore the branch.
