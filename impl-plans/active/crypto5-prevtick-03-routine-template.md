# c5pt-03-routine-template: routine binding template exposes the previous tick

```json
{
  "planId": "c5pt-03-routine-template",
  "planPath": "impl-plans/active/crypto5-prevtick-03-routine-template.md",
  "dependsOn": ["c5pt-01-deps"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaWorkflowRegistry/RoutineService.swift",
    "Tests/RielaCLITests/RoutineCommandTests.swift",
    "impl-plans/progress/c5pt-03-routine-template.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Routines write a cron binding whose template copies the cron envelope keys
into the workflow input. Design §2.3 requires that this default template also
expose `previousScheduledAt` and `previousScheduledLocalTime`.

The template is built in `RoutineService.eventBinding(for:storeRoot:)`, at
`Sources/RielaWorkflowRegistry/RoutineService.swift:390-397`. It is a
`JSONObject` with `"scheduledAt": .string("{{event.input.scheduledAt}}")` and
similar entries.

## File-level changes

In `RoutineService.eventBinding(for:storeRoot:)`, add two entries in the same
style, next to `scheduledAt` and `scheduledLocalTime`:

- `"previousScheduledAt": .string("{{event.input.previousScheduledAt}}")`
- `"previousScheduledLocalTime": .string("{{event.input.previousScheduledLocalTime}}")`

Nothing else changes.

## Non-goals and pitfalls

- Do not add a migration that rewrites existing routine binding files. They
  pick up the keys when the routine is next created or updated, which is the
  existing behavior and is documented in design §2.3.
- Do not change `completionCriteria` handling, overlap keys or `enabled`
  logic. `set-overlap-policy` patches only overlap keys. Leave that path
  untouched.
- Do not edit `examples/routine-task-runner`. Its prompt change is not
  required.

## Test cases (`Tests/RielaCLITests/RoutineCommandTests.swift`)

Add one test, for example
`testRoutineBindingTemplateExposesPreviousScheduledTick`. Follow the existing
pattern at lines 73-83: create a routine through the CLI runner or
`RoutineService`, then decode the binding file as `EventBindingContract`.

- The created routine's binding `inputMapping.template` object has
  `previousScheduledAt == "{{event.input.previousScheduledAt}}"` and
  `previousScheduledLocalTime == "{{event.input.previousScheduledLocalTime}}"`.
- The existing keys `scheduledAt`, `scheduledLocalTime`, `firedAt` and
  `timezone` are still present and unchanged.

## Verification (commands → required evidence)

```
arch -arm64 /bin/zsh -lc "swift test --filter 'RoutineCommandTests|EventRoutineBindingTests' > tmp/crypto5-prevtick/c5pt-03-routine-template/test.log 2>&1; echo exit=\$?"
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaWorkflowRegistry/RoutineService.swift Tests/RielaCLITests/RoutineCommandTests.swift > tmp/crypto5-prevtick/c5pt-03-routine-template/lint.log 2>&1; echo exit=$?'
```

Required results: test `exit=0`, `testsRun > 0`, `failureCount 0`, with the
new test name present in the log. Lint `exit=0`.

## Done criteria

- `grep -c 'event.input.previousScheduled' Sources/RielaWorkflowRegistry/RoutineService.swift`
  returns `2`.
- The new test name appears in `test.log` as passed.
