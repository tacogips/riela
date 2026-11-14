# wh-15: CLI — `task handover|takeover|answer|handovers|reconcile`, `task show` additions, `session handover`

```json
{
  "planId": "wh-15-task-commands",
  "planPath": "impl-plans/active/wh-15-task-commands.md",
  "wave": "W4",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/TaskHandoverCommands.swift",
    "Sources/RielaCLI/RielaCommand+SessionParsing.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Tests/RielaCLITests/TaskHandoverCommandTests.swift",
    "impl-plans/progress/wh-15-task-commands.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/SessionCommands.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift"
  ],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCLI/RielaCommand.swift",
      "intendedEdit": "Add TaskCommandKind cases `handover, takeover, answer, handovers, reconcile` (in this order after `decide`) and `SessionCommand.handover(CLICommandOptions)`. Keep CLIExitCode as wh-01 left it."
    },
    {
      "path": "Sources/RielaCLI/SessionCommands.swift",
      "intendedEdit": "Add the `session handover` handler that calls TaskHandoverRuntime.adoptAndSeal; do not change wh-02's resume logic."
    },
    {
      "path": "Sources/RielaCLI/CLISurfaceEnumeration.swift",
      "intendedEdit": "Only if session subcommands are a hard-coded list: add `handover`. Task subcommands come from TaskCommandKind.allRawValues automatically."
    }
  ],
  "progressLog": "impl-plans/progress/wh-15-task-commands.md"
}
```

## Intent and context

This is a thin CLI over the wh-14 runtime (design §12 table, §10.4, §10.5, §11, QA Q6 and Q7). Parse flags in the style of
`ParsedTaskRunOptions` and `runDecide` (`TaskCommands.swift`). Shared store options are `--scope --session-store --working-dir --output`.
Render text and JSON like `TaskShowCommandResult` and `TaskRunCommandResult`. Usage errors → `CLIExitCode.usage`, runtime errors →
`.failure`, a sealed handover → `.suspended`.

Non-goals: `--endpoint` and `task serve` (wh-18), GraphQL, catalog rows (wh-20), docs (wh-19).

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-15-task-commands/`,
writePaths plus the shared edits, arm64 logs, temp stores under `tmp/`, no git state changes, own progress log).

## Deliverables (`TaskHandoverCommands.swift` holds the handlers; `TaskCommands.run` switches to them)

- `task handover <taskId> --reason <text> [--now] [--to <host|group>] [--sink <kind>[,<kind>]] [--principal <p>]` →
  `requestHandover`. JSON: `{taskId, requestId, attemptId, immediate}`.
- `task takeover <taskId> [--packet <locator|path>] [--force-orphan] [--clone-into <dir>] [--traits <t>[,<t>]] [--sink …] [--principal <p>]`:
  - Traits are parsed strictly into `HostTrait`; an unknown value → a usage error naming it.
  - `--force-orphan` → `forceOrphan`, then `TaskDispatch.run(localTraits:)`.
  - Otherwise, when there is no pending takeover reservation (an answer already creates one) → `requestTakeover(traits:)`, then `TaskDispatch.run(localTraits:)`.
  - `--packet`: a value with `:` and `#sha256:` is a locator → `HandoverSinkFactory.reader(for:)`. Otherwise it is a file path read directly.
    Verify with `HandoverSinkVerification.verify`, and require `digest == store.latestHandover(taskId).digest`. Refuse on mismatch.
  - `--clone-into <dir>`: needs a repository deliverable whose `remote` is a URL. If `<dir>` is absent → `git clone <remote> <dir>`
    (through `FoundationGitCommandRunner`), then use `<dir>` as the working dir for the run. An existing non-empty dir that is not
    that repository → refuse. There is no cloning without the flag.
- `task answer <taskId> --question <id> (--answer-json <json> | --answer-file <path> | --text <s> | --option <optionId> | --use-default) [--principal <p>]`:
  exactly one payload flag. `--text` → `{"text": s}`. `--option` → `{"option": id}` (must be one of the question's options).
  `--use-default` requires `defaultAnswer`. Then `runtime.answer`. JSON: `{taskId, questionId, taskState}`.
- `task handovers <taskId>` → rows `{handoverId, createdAt, reasonKind, digest, successorAttemptId, sinks: [serialized]}`, ordered by createdAt.
- `task reconcile --expired-leases [--dry-run]` → `reconcileExpired`. Without `--expired-leases` → a usage error
  ("task reconcile supports --expired-leases").
- `task show`: `TaskShowCommandResult` gains `handovers` (the same rows), `lease` `{fence, expiresAt, hostId}` (nil when none) and
  `suspend` (the latest attempt session's `SuspendRecord`, if any). The text lines are appended after the existing sections.
- `session handover <sessionId> [--reason <text>] [--task <taskId>] [--sink …] [--principal <p>]` → `adoptAndSeal(existingTaskId:)`.
  JSON: `{sessionId, taskId, handoverId}`. Exit `.suspended`.
- `--principal` defaults the same way `task decide` does. The producer for all commands is `.human(principal:)`.

## Pitfalls

- `TaskCommandKind.allRawValues` feeds the surface enumeration. The parity gates stay red until wh-20 adds rows (expected; do not add rows here).
- The takeover must not double-request when an answer already enqueued the pending reservation. Check `dispatcher.pendingReservation(taskId:)`.
- Keep the existing `task decide/run/show/list` output unchanged except for the new `show` fields.

## Tests (`TaskHandoverCommandTests`; drive `RielaCLIApplication().run([...])` with a temp session store, fixture bundles from wh-14's `TaskHandoverTestSupport`)

- run an envelope task (via `task run`) → `task show --output json` lists the handover with its digest and the task is waiting; `task handovers` lists one row
- `task answer --option staging` → task scheduled; `task takeover` → completes; `task show` lineage A → B
- `task answer` with two payload flags → usage; `--option` not among the options → failure message; `--use-default` without a default → failure
- `task takeover --traits bogus` → usage error naming `bogus`; a presence handover with `--traits userReachable` → completes
- `task takeover --packet <file-locator>` for a tampered file → refused; a valid one → proceeds
- `task reconcile` without the flag → usage; `--expired-leases --dry-run` → JSON list
- `session handover <id>` on a suspended plain session → exit `.suspended` and a task exists; `--task <existing>` attaches
- `task handover --now` on a task with no live attempt → a failure message

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-15-task-commands/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-15-task-commands/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverCommandTests|TaskCommandTests|TaskCommandParsingTests|TaskCommandMutationTests|SessionObservabilityCommandTests" > tmp/work-handover/wh-15-task-commands/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-15-task-commands/focused.log'
git diff --check
```

Both must end with exit=0 and a non-zero count. The existing command suites must be green or baseline-classified.
This plan proves acceptance signals 1, 2, 4 (`--force-orphan` flag) and 5 at CLI level. Record the test names in the progress log.

## Done criteria

- [x] Every command and flag above is implemented with strict parsing; `task show` additions are present
- [x] The tests pass; the progress log is complete

**Closure (2026-10-01, Step 8)**: accepted; completed at `e95096c3`, acceptance recorded in `09953552`. Evidence: `impl-plans/progress/wh-15-task-commands.md`. Archived to `impl-plans/completed/`.


## Resume notes (2026-10-01, after run session-9)

wh-14 is accepted and committed. A partial wh-15 implementation is committed ('wip: partial wh-15 task handover commands'): the package builds with tests, but focused tests have not run. Complete and verify it; do not restart it. The remaining wave now runs strictly serially (wh-15 -> wh-16 -> wh-17 -> wh-18 -> wh-19 -> wh-20) because parallel branches in one shared tree broke each other's builds.

## Resume status at ffec37fc (2026-10-01)

- The test-target blocker recorded in `impl-plans/progress/wh-15-task-commands.md` ("Remaining") is gone: `Tests/RielaCLITests/TaskHandoverExampleTests.swift` was parked with the rest of wh-17 and is not in the tree at HEAD. Do not restore or edit any `tmp/work-handover/parked/` content here; wh-17 owns it.
- First, run the focused command from Verification unchanged and record `testsRun`/`failureCount`. Fix any wh-15 failure inside writePaths.
- Already committed at 33d05e75 (verify, do not rewrite): routing for the five task kinds, strict answer/trait/sink/reconcile parsing, `--clone-into`, `--packet` digest match, `session handover` returning exit 5, `task show` handovers/lease/suspend. Tests present: `testShowIncludesHandoverLeaseAndSuspendFields`, `testHandoversReturnsEmptyListForTaskWithoutHandover`, `testForceOrphanFlagReachesOrphanFenceRuntime`, `testTakeoverRejectsUnknownTraitByName`, `testTaskCommandRoutingIncludesHandoverSurface`, `testAnswerRequiresExactlyOnePayloadFlag`, `testReconcileRequiresExpiredLeasesFlag`, `testImmediateHandoverWithoutRunningAttemptFails`.
- Remaining tests to add in `TaskHandoverCommandTests.swift` (the Tests bullets above that no test covers yet):
  - envelope task via `task run` → exit 5; `task show --output json` has one handover row with a 64-hex digest and the task is waiting; `task handovers` lists that one row (packet-present rendering)
  - `task answer --option staging` → scheduled; `task takeover` → completed; `task show` lineage A → B; no second reservation (exactly one takeover attempt)
  - `--option` not in the question's options → failure; `--use-default` with no `defaultAnswer` → failure
  - presence handover: `task takeover` with no traits → waiting `host-traits-unavailable`; `--traits userReachable` → completed
  - `--packet <file locator>` of a tampered file → refused, store unchanged; an untampered one → proceeds
  - `task reconcile --expired-leases --dry-run --output json` → a JSON list, and no lease or packet written
  - `session handover <id>` on a suspended plain session in a non-repository temp dir → exit 5, the task exists, `{sessionId, taskId, handoverId}`; `--task <existing>` attaches
- Fixtures for the remaining tests: the wh-14 fixtures do not cover these cases. `handoverEnvelopeBundle(workflowId:)` (`Tests/RielaCLITests/TaskHandoverTestSupport.swift:119`) builds a `riela/handover-request` addon whose question has an empty `options` list, no `defaultAnswer`, and only the `userInputRequired` reason. `TaskHandoverTestSupport.swift` is outside writePaths: do not edit it.
  - Build the needed fixtures as private helpers inside `TaskHandoverCommandTests.swift`, modelled on `handoverEnvelopeBundle`: an envelope variant whose question `options` include `staging` (a `HandoverOption` object with `id` and `label`), a variant with no `defaultAnswer` for the `--use-default` failure, and a `userPresenceRequired` variant whose `presence` config requires the `userReachable` trait (`PresenceRequirement` in `Sources/RielaCore/HandoverContracts.swift` has `traits` and `instructions`). Use the addon config keys the existing fixture uses (`reason`, `question`, `progressNote`, `resumeStepId`) plus `presence` for the presence reason; confirm them against the envelope-key list in `Sources/RielaCLI/ProductionNodeAdapter+HandoverRequestAddon.swift` and the `WorkHandover.swift` reason encoding before writing.
  - For tests driven through `task run`, write the workflow on disk under the test's temp project, following `writeSuspendedAdoptionFixture` (`TaskHandoverTestSupport.swift:166`): `<project>/.riela/workflows/<workflowId>/workflow.json` plus the node json files. Alternatively, seed the handover through the runtime (`TaskDispatch.run`) with the in-memory bundle and then exercise only the CLI command under test (show, handovers, answer, takeover).
- Hermetic git (umbrella rule 11): every test that can run git (`session handover`, `--clone-into`) uses a temp dir with `GIT_CEILING_DIRECTORIES` set to its parent (non-repository), or its own temp repo plus a local bare remote. It asserts the resolved root is inside the temp dir and never uses the process cwd. A `--clone-into` test is optional; if added, it clones only from a local bare remote.
- `task handover` requires `--reason` (design §21 R30); keep the committed usage error.
- Do not edit `Sources/RielaWork/TaskDispatcher.swift` (wh-16 owns it), catalog rows or SDL (wh-20), or docs (wh-19). `SurfaceParity*` stays red until wh-20 and is not in this plan's filter.
- Done when the focused log ends `exit=0` with testsRun > 0 and failureCount 0, `git diff --check` exits 0, and the progress log maps signals 1, 2, 4 and 5 to passing test names.
