# routine-task-runner expected results

Deterministic mock run:

```bash
riela workflow run routine-task-runner \
  --workflow-definition-dir examples \
  --mock-scenario examples/routine-task-runner/mock-scenario.json \
  --output json
```

- `run-task` is mocked and returns `conditionMet: false`.
- `complete-routine` (`riela/routine-complete`) is therefore a no-op: its
  payload reports `completed: false` with reason "completion condition not
  met; routine stays active", and no routine store is touched.
- The session completes with both steps `completed`.

Live behaviour (created through `riela routine create --workflow
routine-task-runner ...` and fired by `riela events serve`):

- The workflow input carries `routineId`, `routineName`, `task`,
  `completionCriteria`, and the tick timestamps from the routine's cron
  binding template.
- When the agent judges the completion criteria met, `complete-routine` marks
  the routine `completed` in the routine store, disables the routine's event
  source/binding files, and (when the routine was created with
  `--deactivate-workflow-on-completion`) deactivates the target workflow.
