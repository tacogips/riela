# routine-chat-manager expected results

Deterministic mock run:

```bash
riela workflow run routine-chat-manager \
  --workflow-definition-dir examples \
  --mock-scenario examples/routine-chat-manager/mock-scenario.json \
  --output json
```

- `parse-instruction` is mocked and yields name "release status check",
  schedule `0 */30 * * * *` (every 30 minutes), timezone `Asia/Tokyo`, and a
  completion criteria.
- `create-routine` (`riela/routine-create`) runs live against the working
  directory: it writes the routine record into
  `.riela/routines/routines.sqlite` and the cron source/binding JSON under
  `.riela/events/sources|bindings`, targeting the `routine-task-runner`
  workflow. Its payload carries `created: true`, the generated `routineId`
  (prefix `routine-release-status-check-`), and diagnostics with the written
  paths.
- `send-reply` renders the confirmation text; without a live chat target it
  resolves as a dry-run reply.
- The session completes with all three steps `completed`.

Live behaviour: bind this workflow to a chat source (telegram/discord/slack)
with an `inputMapping.mode: "event-input"` binding. A message like
"リリース状況をチェックして30分おきに要約して。v2.0が公開されたら終わり" creates the
routine and confirms in the same thread; the routine then fires through
`riela events serve` (restart it once so the new cron source is loaded).
