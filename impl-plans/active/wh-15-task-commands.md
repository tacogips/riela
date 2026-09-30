# wh-15: CLI — `task handover|takeover|answer|handovers|reconcile`, `task show` additions, `session handover`

```json
{
  "planId": "wh-15-task-commands",
  "planPath": "impl-plans/active/wh-15-task-commands.md",
  "wave": "W4",
  "dependsOn": [
    "wh-14-task-dispatch-runtime"
  ],
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

- [ ] Every command and flag above is implemented with strict parsing; `task show` additions are present
- [ ] The tests pass; the progress log is complete
