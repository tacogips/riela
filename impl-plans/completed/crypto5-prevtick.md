# swift-crypto 5.x refresh + cron previous tick: plan set index

Mode: `issue-resolution`. The issue comes from workflowInput: "Integrate latest
gateways/kaiba on swift-crypto 5.x and expose previousScheduledAt on cron
ticks". It has no GitHub issue number. Run: opus-luna session 515. There are
no Codex-agent references.

Sources of truth:

- Design: `design-docs/specs/design-crypto5-dependency-refresh-and-cron-previous-tick.md`,
  accepted by Step 3 with no findings.
- Baseline revision:
  `design-docs/specs/event-listener-workflow-trigger/provider-source-types.md`
  §Cron.

Continuation (opus-luna session 519): base `main` is `c14c3b30`. Plan
c5pt-01-deps is **completed**: it landed as `35a910d5`, with progress in
`impl-plans/progress/c5pt-01-deps.md`. It is an accepted dependency and is not
dispatched again. The implementation branch is `main` (`gitPush=true`), and
serial finalization commits and pushes. Do not revert or
rework the definition store (#179/#180) or the agent tool-policy presets
(`0b25d5b2`). Do not bump `VERSION` and do not release.

No worker edits this file. Serial finalization updates it.

## Waves

| Wave | planId | Plan | dependsOn |
|---|---|---|---|
| done | c5pt-01-deps | `crypto5-prevtick-01-deps.md` | — (completed, `35a910d5`) |
| 1 | c5pt-02-cron-core | `crypto5-prevtick-02-cron-core.md` | — |
| 1 | c5pt-03-routine-template | `crypto5-prevtick-03-routine-template.md` | — |
| 1 | c5pt-04-notion-catalog-test | `crypto5-prevtick-04-notion-catalog-test.md` | — |
| 1 | c5pt-05-docs-fixtures | `crypto5-prevtick-05-docs-fixtures.md` | — |
| 2 | c5pt-06-cron-envelope | `crypto5-prevtick-06-cron-envelope.md` | c5pt-02, c5pt-05 |

Why it is now two waves: the earlier wave-2 plans waited only for c5pt-01,
which has landed. c5pt-06 still needs two things:

- the `previousOccurrence` contract from c5pt-02;
- the fixture values from c5pt-05, which re-applies
  `tmp/crypto5-prevtick/held/cron-docs.patch`. The c5pt-06
  fixture-agreement test reads them.

Three wave-1 plans run `swift test` concurrently, so `.build` lock contention
is expected. Handle it with the peer-breakage retry rule below.

The `writePaths` of all plans are disjoint. No plan has `sharedPaths`.
`Package.resolved` and `Packages/RielaMemory/Package.resolved` belong to
c5pt-01 only.

**Contract pinned for wave 2/3**, owned by c5pt-02, consumed by c5pt-06:

```swift
// Sources/RielaCore/CronSchedule.swift
public func previousOccurrence(before date: Date, calendar: Calendar) -> Date?
```

## Shared worker protocol

Every plan follows this protocol.

- **Workspace.** Work in the repository root
  `/Users/taco/gits/tacogips/riela`, on the branch already checked out
  (`main`). Do not create branches or worktrees. Do not run `git commit`,
  `stash`, `reset`, `checkout`, `add`, `restore` or `push`. Serial
  finalization commits and pushes.
- **Edit scope.** Edit only your own `writePaths`. If a compile error or
  required change is in a file outside your `writePaths`:
  - do not edit it;
  - record it in your progress log as
    `outOfScope: <path>:<line> — <reason>`;
  - mark the plan `blocked`.

  The dispatcher performs a bounded checkpoint amendment.
- **Hash every edit.** Before each edit:
  1. Read the file fresh.
  2. Record `shasum -a 256 <file>` (the pre-hash) and a one-line intent
     snapshot in your progress log.
  3. After the edit, record the post-hash.

  If a pre-hash differs from your last recorded post-hash, another writer
  changed the file. Re-read it and re-apply your intent on top. Never revert a
  foreign change, and log the drift.
- **Peer breakage.** If the build fails in a file outside your `writePaths`, or
  SwiftPM holds the `.build` lock (several wave-2 plans run `swift test`
  concurrently), log it as peer drift. Retry up to 3 times, a few minutes
  apart. Never edit the other file.
- **Scratch files.** Scratch files and logs go only under
  `tmp/crypto5-prevtick/<planId>/`. Never commit them.
- **Progress log.** Write only to `impl-plans/progress/<planId>.md`. It holds:
  - task checkboxes;
  - the hash records;
  - decisions taken;
  - one record per verification, as
    `{command, logPath, exitStatus, testsRun, failureCount}`.

  `testsRun` and `failureCount` are the integer totals from the XCTest
  `Executed N tests, with F failures` lines and the swift-testing
  `Test run with N tests` lines, summed. A filter that matches 0 tests is a
  failure, not a pass. A blocked check is recorded as `blocked: <reason>`
  with the exact command and exit status. Never record it as a pass.
- **Commands.** Run every command in the foreground, from an arm64 shell, in
  this form:

  ```
  arch -arm64 /bin/zsh -lc '<cmd> > tmp/crypto5-prevtick/<planId>/<name>.log 2>&1; echo exit=$?'
  ```

  Lint only the files you own, with
  `swiftlint lint --strict --quiet --no-cache <files>`.
- **Out of scope for every plan.**
  - VERSION bump or release;
  - edits inside `.build/checkouts`, forks, `.package(path:)` overrides or
    unsafe flags;
  - changes to `maximumCatchUpSeconds` or `dueTicks`;
  - next-occurrence fields;
  - receipt backfill;
  - explicit Notion catalog entries;
  - any change to the definition store or the tool-policy presets.

## Final gate (serial reconciliation, not a per-plan gate)

```
arch -arm64 /bin/zsh -lc 'swift package resolve'
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc "swift test --filter 'RielaPasskeyTests|PasskeyCommandTests|NotionGatewayAddonTests|BuiltinGatewayJSONBehaviorTests|WorkflowGatewayValidationTests|Kaiba|EventLiveServeCronTests|EventCronOverlapTests|EventCronOverlapServeTests|EventRoutineBindingTests|TimeSignalAddonTests|RoutineCommandTests|CronSchedulePreviousOccurrenceTests'"
arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory'
arch -arm64 /bin/zsh -lc 'swift test'
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <every touched Swift file>'
```

Full `swift test` failures are compared against the baseline that c5pt-01
captured before any edit. The assertion lines are in
`tmp/crypto5-prevtick/c5pt-01/baseline-failures.txt` (the full log was not
kept), and the continuation workflow input confirms the same failures:

- `DeterministicWorkflowRunnerFailureStateTests.testRetryFailedStepErrorNamesTimeoutForCompletedSession`
- `HandoverContractsTests.testSessionSuspendAndClosedStatusRoundTrip`
- `ServeWebHostTests.testBrowserExecutionUsesProfileStoreAndGatesSummaryReads`
- `SessionObservabilityTests.testTransitionalCancelledFailureKindIsTerminal`
- `WorkflowCommandTests.testCancellationWithoutAutoImprovePersistsTerminalFailure`
- `WorkflowHostCapabilityTests.testIssue116BuiltinsResolveWithoutExternalExecutable`
- `WorkflowCommandTests.testConcurrentFreshRunsReceiveDistinctSessionIds` (flaky)

Only a failure in that list counts as pre-existing. Every other failure is a
regression to fix. Do not fix the baseline failures here.

Write the final gate logs under `tmp/crypto5-prevtick/reconcile-final/`.
