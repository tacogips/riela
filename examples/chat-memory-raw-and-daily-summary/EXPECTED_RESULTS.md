# Chat Memory Raw And Daily Summary

This example uses the built-in `riela/chat-memory-raw-daily-summary` add-on.
It has no workflow-local memory operation script; raw-log append and daily
summary create/update are implemented by Riela itself.

## Commands

Validate:

```bash
riela workflow validate chat-memory-raw-and-daily-summary --workflow-definition-dir ./examples --output json
```

Run two events with the same `memoryRoot` and conversation id:

```bash
riela workflow run chat-memory-raw-and-daily-summary \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/chat-memory-raw-and-daily-summary/mock-scenario.json \
  --variables '{"workflowInput":{"provider":"telegram","text":"first message","conversationId":"chat-1","receivedAt":"2026-06-22T09:00:00Z","memoryRoot":"tmp/chat-memory-example"}}' \
  --output json
```

## Expected Results

- The workflow completes with `status=completed`.
- `raw-chat-log.sqlite` and `daily-chat-summary.sqlite` are created under the configured memory root.
- Each run appends a raw log record to `raw-chat-log`.
- If the input includes local `attachments`, `files`, or `imagePaths`, Riela copies up to 10 files into `<memoryRoot>/files/<memoryId>/<recordId>/` and returns them from memory search/load as `record.files`.
- The first run creates one daily summary record in `daily-chat-summary`.
- Later runs for the same `conversationId` and UTC date update the same daily summary record instead of creating a second daily summary row.
- The daily summary payload includes `rawFileCount` and `lastRawFilePaths` when file-backed raw records are present.
- The workflow root output includes `rawRecordId`, `summaryRecordId`, `summaryAction`, `rawRecordCount`, and `rawFileCount`.
