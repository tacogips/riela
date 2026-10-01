# wh-20: Serial reconciliation — join audit, catalog rows, SDL, gates, full verification, plan closure

```json
{
  "planId": "wh-20-reconcile",
  "planPath": "impl-plans/active/wh-20-reconcile.md",
  "wave": "W6 (serial)",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "impl-plans/active/work-handover-and-takeover.md",
    "impl-plans/README.md",
    "docs/work-handover.md",
    "docs/distributed-workers.md",
    "docs/preserved-history-recovery.md",
    "Resources/skills/riela-workflow-run/SKILL.md",
    "Resources/skills/riela-workflow-reference/SKILL.md",
    "impl-plans/progress/wh-20-reconcile.md"
  ],
  "sharedPaths": [
    "README.md",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
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
    "Sources/RielaCLI/TaskRemoteTakeover.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaCLI/TaskServeTakeover.swift",
    "Sources/RielaCore/SurfaceCatalog+RowSupport.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsConsole.swift",
    "Sources/RielaCore/SurfaceCatalog.swift",
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
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
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
    "impl-plans/completed",
    "impl-plans/progress/wh-14-task-dispatch-runtime.md"
  ],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCLI/TaskHandoverRuntime.swift",
      "intendedEdit": "Design §21 R35(b): gitEnvironment becomes `static func gitEnvironment() -> [String: String]` returning CLIRuntimeEnvironment.mergedProcessEnvironment() unchanged (no GIT_CEILING_DIRECTORIES assignment); update runAdoptionGit and the publisher GitBranchWorkspaceRuntime call site. Nothing else in this file changes."
    },
    {
      "path": "Sources/RielaCLI/TaskDispatch+Handover.swift",
      "intendedEdit": "Design §21 R35(b): the two GitBranchWorkspaceRuntime(environment:) call sites (~lines 125 and 167) call TaskHandoverRuntime.gitEnvironment() without a ceiling argument. Nothing else changes."
    },
    {
      "path": "Tests/RielaCLITests/TaskHandoverCommandTests.swift",
      "intendedEdit": "Design §21 R35(b) regression: add testSessionHandoverHonorsApplicationGitCeilingForNonRepositoryWorkingDirectory (see 'R35 amendment')."
    },
    {
      "path": "impl-plans/progress/wh-14-task-dispatch-runtime.md",
      "intendedEdit": "wh-14 low finding (stale progress entries): append one closing section only; do not rewrite or delete earlier entries."
    },
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

- [x] The join audit is clean; the catalog rows and SDL are in place; the parity gates are green
- [x] All focused suites and example checks pass; the full suite has no new failures against wh-00
- [x] The umbrella Completion Criteria are checked with evidence; archive or keep active accordingly; the README and index are updated
- [x] R35 amendment: SDL uses the design §12 / wh-12 signatures; gitEnvironment uses mergedProcessEnvironment with no ceiling; the ceiling regression test passes (r35-ceiling.log exit=0) and failed before the fix (r35-ceiling-prefix.log); wh-14 closure note appended

**Closure (2026-10-01, Step 8)**: Step 7 adversarial review `comm-000371` accepted it with no findings. Evidence is under `tmp/work-handover/wh-20-reconcile/`: `catalog-final.log` (7/7), `parity-reconcile.log` (46, 1 skipped, exit=0), `focused-reconcile.log` (218/218), `examples-reconcile.log`, `r35-ceiling.log` exit=0 after `r35-ceiling-prefix.log` exit=1, `sdl-2-diff.txt` 0 bytes, and `full-suite-baseline-gate-final.log` exit=0 with an empty `new-failures.txt`. Progress: `impl-plans/progress/wh-20-reconcile.md`. Archived to `impl-plans/completed/` with the README and index updated in Step 8.


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

### wh-19 folded in (2026-10-01, after run session-15)

wh-01..wh-18 are accepted and committed. wh-19's docs and skills work is committed ('wip: work handover docs and skills (wh-19)') but its only behavioral gate, `SurfaceParitySkillTests`, needs this plan's surface catalog rows: it currently fails 2 of 7 (`testEveryDocumentedCommandResolvesToACatalogRow`, `testEveryDocumentedFlagIsAnOptionSomeParserAccepts`; see tmp/work-handover/recovery/skill-parity.log). So wh-20 now also owns wh-19's docs and skills files. Add the catalog rows and SDL for every new task/session/GraphQL surface (including the takeoverTask answer fields added by wh-18), finish and correct the docs and skills against the shipped surfaces, make SurfaceParitySkillTests pass, then do the reconcile work below (low findings from wh-14, full suite against the wh-00 baseline, plan archive).

### R35 amendment (2026-10-01, run session-16 design intake)

The accepted design gained §21 R35 (design review accepted, session-16, no findings). It makes three wh-20 items exact. Nothing else in this plan changes: no new plan, and no renumbering.

**A. SDL signatures (design §12, R35(a)).** In step 3, the seven root fields are the ones in the design §12 block. They match `impl-plans/active/wh-12-graphql-contracts.md:41-49` and the provider protocol in `Sources/RielaGraphQL/TaskHandoverGraphQL.swift`: `String` arguments (not `ID`), `traits: [String!]`, and the `*Payload!` return types. Pitfall: do not copy the pre-R35 draft names (`TakeoverReservation`, `LeaseState`, `[HostTrait!]` and the others). They are not in the schema block, and SDL validation would reject them. Register `taskHandoverGraphQLSchemaTypes` unchanged. Do not edit that block.

**B. Catalog options (design §12 note).** For each CLI row, list every `@Option`/`@Flag` the parser declares:
- `ParsedTaskHandoverOptions`, `ParsedTaskTakeoverOptions`, `ParsedTaskAnswerOptions`, `ParsedTaskSharedOptions` (handovers) and `ParsedTaskReconcileOptions` in `Sources/RielaCLI/TaskHandoverCommands.swift`.
- `task serve` in `Sources/RielaCLI/TaskServeTakeover.swift`: `--takeover`, `--endpoint`, `--poll-interval-ms`, `--once`, `--traits`, the auth options and the store options.
- `session handover` in `ParsedSessionHandoverOptions`.

Include the shared store options (`--scope`, `--working-dir`, `--session-store`, `--output`, `--principal` where declared) and, where declared, the remote options (`--auth-token`, `--auth-token-env`, `--manager-session-id`, `--handover-id`). Pitfall: the design §12 table is a summary. Rows built from it alone miss `--traits`/`--sink`, and SurfaceParitySkillTests keeps failing.

**C. wh-14 low findings (R35(b)).** There are three.
1. *Ceiling.* Change the call sites listed in the `sharedPathNotes` above:
   - `TaskHandoverRuntime.gitEnvironment()` takes no argument and returns `CLIRuntimeEnvironment.mergedProcessEnvironment()` exactly.
   - Update all four callers: `runAdoptionGit`, the publisher in `TaskHandoverRuntime`, and `TaskDispatch+Handover.swift` about lines 125 and 167.
   - Do not set, remove or rewrite `GIT_CEILING_DIRECTORIES` in production code.
   - Do not touch `GitBranchWorkspaceRuntime.swift`'s default initializer. R35 does not list it.

   Pitfalls:
   - Setting the ceiling to the parent directory in production breaks R27 item 1: adoption from a subdirectory must resolve the enclosing top level.
   - Using `ProcessInfo.processInfo.environment` drops the test's application-level ceiling. `RielaCLIApplication.run(environment:)` sets it through the `CLIRuntimeEnvironment.$overrides` task-local (`Sources/RielaCLI/RielaCLIApplication.swift:100`).
2. *reservationFence.* No change. It stays `Int?`: `nil` only for the lease-less adopted attempt, and `-1` for a leased attempt with a missing lease. Record "no change, per R35" in the progress log.
3. *Stale progress entries.* Append one section, "Closure note (wh-20)", to `impl-plans/progress/wh-14-task-dispatch-runtime.md`. It states that the earlier "remaining work" lists are superseded by the continuation-1 evidence and by the acceptance at `2cd392b8`. Do not edit or delete the earlier text.

Regression test: `TaskHandoverCommandTests.testSessionHandoverHonorsApplicationGitCeilingForNonRepositoryWorkingDirectory`. Imitate `testSessionHandoverAdoptsSuspendedSessionInHermeticRepository` and the existing `run(_:project:)` helper.

The fixture:
- A resolved temp root `T`.
- `git init` of an outer repository `T/outer` with one commit and a local bare remote under `T`.
- A plain directory `T/outer/inner`, which is not a repository.
- A suspended session whose working directory is `T/outer/inner`.

Run `session handover <sessionId> --reason r --scope project --working-dir T/outer/inner --session-store <store>` with the application `environment:` containing `GIT_CEILING_DIRECTORIES=T/outer` and `RIELA_SESSION_STORE`. `T/outer` is a proper ancestor of `inner`, so git must not walk into `outer`.

Expected outcomes:
- The command succeeds.
- The adopted task has no repository `context`, and its packet has no repository deliverable.
- `git -C T/outer` shows an unchanged branch, `HEAD` sha and `for-each-ref` output, and no `riela/task/*` ref.
- Every git call the test makes itself uses `TaskHandoverHermeticGit.environment(ceiling: T)`.
- Assert that the resolved top level of `outer` is inside `T`.

Before the fix, the production ceiling (`inner` itself) is ignored and the application ceiling is lost, so git finds `outer` and the task gets a repository context. The test must fail on the old code. Record that failing run in `tmp/work-handover/wh-20-reconcile/r35-ceiling-prefix.log` before applying the fix.

Evidence (append to the verification list; each command's log ends with `exit=`):
- `! grep -q "GIT_CEILING_DIRECTORIES" Sources/RielaCLI/TaskHandoverRuntime.swift` exits 0.
- `grep -q "mergedProcessEnvironment" Sources/RielaCLI/TaskHandoverRuntime.swift` exits 0.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverCommandTests|TaskHandoverDispatchTests|TaskHandoverRepositoryTests" > tmp/work-handover/wh-20-reconcile/r35-ceiling.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-20-reconcile/r35-ceiling.log'` ends `exit=0` with 0 failures and includes the new test.

Order: do C before step 4, so the focused and full runs include it. A and B belong to steps 2–3.

### Final scope amendment (2026-10-01, after run session-16)

wh-20's work so far is committed ('wip: wh-20 reconcile ...'); complete it, do not restart it. The full suite now has exactly 3 new failures beyond the wh-00 baseline, all in `SurfaceCatalogTests` (tmp/work-handover/wh-20-reconcile/new-failures.txt): `testIdsCLICommandsGraphQLFieldsAndRoutesAreUnique` (duplicate operation id `task.serve`), `testCatalogInvariantsHold`, and `testWorkRuntimeReadAndP1TaskCommandsAreCataloged` (expectations still describe the pre-handover surface, e.g. 'task.handover must declare the CLI surface blocked'). This plan now has shared ownership of `SurfaceCatalog+RowsConsole.swift`, `SurfaceCatalog.swift`, `SurfaceCatalog+RowSupport.swift` and `SurfaceCatalogTests.swift`. Remove the duplicate `task.serve` row (keep the one that reflects `task serve --takeover` as built), update the test expectations to the shipped handover surfaces, rerun SurfaceCatalogTests and SurfaceParity, then rerun the full suite and the baseline-comparison gate; it must report no failure outside the wh-00 baseline.

### Remaining-work checklist at 78b955d0 (2026-10-01, run session-17)

Every other wh-20 gate is already green at e8bbf3f7 with complete logs in `tmp/work-handover/wh-20-reconcile/`. These include build-final, sdl-repeat-final (diffExit=0), parity-final, focused-final (211 tests), r35-ceiling (exit 0) and r35-ceiling-prefix (exit 1), examples (validate 0×3; runs 5/5/0), swiftlint-changed/swiftlint and diff-check-final. Do not redo the earlier steps. Before each edit, read the file fresh and record its `shasum -a 256` before and after in the progress log.

1. **Delete the placeholder row.** Remove only `surfaceRow(notYetBuilt, id: "task.serve", family: "task", kind: .stream)` from `SurfaceCatalog.workRuntimeRows` in `Sources/RielaCore/SurfaceCatalog+RowsConsole.swift`. Keep the `.process` `task.serve` row in `taskMutationRows` (`SurfaceCatalog+RowsCLI.swift`). Its options must equal what `Sources/RielaCLI/TaskServeTakeover.swift` declares. Do not change `notYetBuilt`, its evidence strings, or any other row.
2. **Pin the catalog test to the shipped surface.** In `Tests/RielaCoreTests/SurfaceCatalogTests.swift`, rewrite only `testWorkRuntimeReadAndP1TaskCommandsAreCataloged` and its doc comment. The other two failing tests pass once the duplicate is gone, so leave them unchanged. Assert exact values; never replace them with "non-empty" or "any availability" checks.
   - Id set (exactly 18): task.submit, task.list, task.show, task.run, task.decide, task.serve, task.handover, task.takeover, task.answer, task.handovers, task.reconcile, task.handover-query, task.awaiting-handover, task.heartbeat, task.report, intent.create, intent.list, intent.show.
   - CLI `.implemented`, with `cli.command` equal to the command and non-empty options: task.show "task show", task.list "task list", task.run "task run", task.decide "task decide", task.serve "task serve", task.handover "task handover", task.takeover "task takeover", task.answer "task answer", task.handovers "task handovers", task.reconcile "task reconcile". The task.serve options must contain `--takeover` and `--traits`.
   - CLI `.blocked` with evidence containing "work-runtime P1" and `cli == nil`: task.submit, intent.create, intent.list, intent.show.
   - GraphQL-only rows, with `cli == nil` and CLI availability not `.implemented`: task.handover-query, task.awaiting-handover, task.heartbeat, task.report.
   - GraphQL `.implemented`, with `graphql.qualifiedField` equal to: task.handover→`Mutation.requestTaskHandover`, task.takeover→`Mutation.takeoverTask`, task.answer→`Mutation.answerTask`, task.handover-query→`Query.taskHandover`, task.awaiting-handover→`Query.tasksAwaitingHandover`, task.heartbeat→`Mutation.heartbeatAttempt`, task.report→`Mutation.reportAttempt`. These are the seven design §12 fields. Every other row stays GraphQL `.blocked`, with evidence containing "work-runtime P5" and `graphql == nil`.
   - Library: every row is `.blocked`, with evidence containing "work-runtime P5" and `library == nil`.
   - The test applies only to the `task` and `intent` families. The `session.handover` row lives in `sessionRows` and is checked by the parity gates.
3. **Correct the evidence check for R34.** The SDL file does not contain `HandoverAnswerPayload` literally. `GraphQLContractProjector+Schema.swift` interpolates `\(taskHandoverGraphQLSchemaTypes)`, so the literal grep from the "Pending-branch removal" section exits 1 even when the SDL is correct. Replace it with all three of these checks:
   - `grep -qF '\(taskHandoverGraphQLSchemaTypes)' Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` exits 0.
   - `grep -q 'type HandoverAnswerPayload' Sources/RielaGraphQL/TaskHandoverGraphQL.swift` exits 0.
   - `TaskHandoverGraphQLTests` passes. It asserts the type and the `answer` field at lines 142-143.
4. **Verify, serially, with logs under `tmp/work-handover/wh-20-reconcile/`.** Each log must end in `exit=`.
   - `swift test --filter SurfaceCatalogTests` → `catalog.log`.
   - `swift test --filter SurfaceParity` → `parity.log`.
   - `swift build` → `build.log`.
   - The manifest's focused filter → `focused.log`.
   - The full suite → `full-swift-test.log`.
   - The manifest's baseline-comparison command → `full-suite-baseline-gate.log`, which must show exit 0 with an empty `new-failures.txt`.
   - `swiftlint lint --strict` on the two edited Swift files → `swiftlint-final.log`.
   - `git diff --check`.

   The examples step runs again outside the Codex sandbox (the Opus verification step), using the same command as before.
5. **Closure.** This is task 7 above. Check each umbrella Completion Criteria box with the test name and log path. Archive with `git mv` to `impl-plans/completed/` only if every box has evidence and the gate exit is 0. Archive the umbrella and wh-00..wh-20 together; `work-handover-dispatch.json` stays in active. Otherwise keep everything active and list each missing box in the progress log.

Do not touch any other `SurfaceCatalog*` file, `GraphQLSchemaGenerator.swift`, or the generated SDL (it is already idempotent). Do not loosen `invariantViolations()`.
