---
name: "riela-chat-example-verification"
description: "Verify Riela chat examples and live chat memory regressions through RielaApp, especially Telegram, Discord, Matrix, persona trio chats, image attachment prompts, raw-log/daily-summary memory examples, event-source receipts, and chat reply visibility checks."
---

# Riela Chat Example Verification

Use this skill when asked to prove that Riela chat examples actually work, not just that messages were posted. Treat "sent in chat" as preparation only; verification requires a running event listener and observable processing evidence.

## Required Evidence

Collect at least one of these before calling a chat example verified:

- A visible bot reply in the target chat UI.
- A new event receipt from `riela events list` for the matching source.
- A completed workflow session created after the test message, with expected memory read/write or reply output.

For RielaApp verification, also confirm the app process launched and whether its daemon `riela events serve` child stayed running or exited. Preserve command logs under `tmp/<task-name>/`; do not write scratch files at the repository root.

## Preflight

Run these checks from the repo root:

```bash
swift build --product RielaApp
riela events validate --workflow-definition-dir ./examples --event-root ./examples/event-sources/.riela-events --output json
ps aux | rg 'RielaApp|riela events serve' | rg -v 'rg|Brave Helper|Discord Helper' || true
```

Check environment readiness by listing variable names only, never values:

```bash
kinko status || true
direnv exec . sh -lc 'env | cut -d= -f1 | rg "^(RIELA_TELEGRAM|RIELA_DISCORD|DISCORD_BOT|RIELA_MATRIX|GEMINI|OPENAI)"' || true
find "$HOME/.riela" -maxdepth 2 -type f \( -name 'rielaapp.env' -o -name 'env' \) -print 2>/dev/null
```

RielaApp-launched daemon children read `~/.riela/rielaapp.env`, `~/.riela/env`, and the app process environment. Shell-only `direnv` state is not enough for GUI-launched RielaApp.

## RielaApp Launch Check

Start RielaApp and inspect the daemon result:

```bash
swift run RielaApp
```

Expected log shape:

- `profile=... discovered ... user daemon workflow candidate(s)`
- `launch ... riela events serve ...`
- either `pid=... running after startup grace` or a precise exit message such as a missing token/env var.

If using Computer Use, inspect the RielaApp status-bar app or "Riela Workflows" window. If accessibility cannot inspect the accessory app, record the timeout and use process/log evidence instead.

## Chat Regression Flow

Use this sequence for Telegram, Discord, and Matrix:

1. Start RielaApp or `riela events serve` for the exact event root and workflow set under test.
2. Confirm a matching listener process is running.
3. Send a text-only sanity message to the primary bot. The message should invite a normal conversation, not only a ping.
4. Confirm the primary bot's visible response includes mentions or handoff text that targets the other two bots/personas.
5. Confirm bot1 and bot2 each produce meaningful visible replies, or collect event receipts/completed sessions that prove their turns ran.
6. After that conversation, verify chat memory by asking the primary bot, bot1, and bot2 to summarize what was just discussed. Each summary should reference the actual conversation content, not a generic "I do not know" answer.
7. Send the image test to Mika with the Yui image asset and ask what is visible in the image.
8. Confirm the image answer describes image content. Do not accept replies that only say a photo, square image, or attachment exists.
9. Ask about the same image again without reattaching it to verify image memory reuse.
10. Confirm the follow-up reply describes the previously stored image content, or record the exact blocker.

Do not mark image behavior verified when `imagePaths` is empty unless the workflow intentionally reasons from attachment metadata only.

## Required Live Chat Scenario

When the user asks for end-to-end chat memory regression, run this scenario on
each requested surface rather than only sending isolated prompts:

1. Talk to the primary bot with an arbitrary but concrete conversation topic.
   The bot's reply must mention or hand off to bot1 and bot2.
2. Verify bot1 and bot2 answer meaningfully in the same chat flow.
3. Ask the primary bot, bot1, and bot2 to summarize the conversation. Treat this
   as the text-memory check.
4. Show an image and ask what is in it.
5. Ask again later what was in the image without reattaching it. Treat this as
   the file/image-memory check.

Acceptable proof is visible browser/chat UI evidence, fresh event receipts, or
completed workflow sessions with memory read/write details. A sent message alone
is never enough.

## Shared Persona NodeRef And Handoff Guard Regression

Use this when verifying the shared Yui/Mika/Rina persona nodes, cross-workflow
`nodeRef`, or the deterministic handoff loop guard. This is the regression that
prevents prompt-only handoff flags from creating Yui/Mika/Rina loops.

First validate the shared workflow and each vendor workflow:

```bash
direnv exec . .build/arm64-apple-macosx/debug/riela workflow validate \
  shared-agent-trio-personas --workflow-definition-dir ./examples
direnv exec . .build/arm64-apple-macosx/debug/riela workflow validate \
  telegram-agent-trio-chat --workflow-definition-dir ./examples
direnv exec . .build/arm64-apple-macosx/debug/riela workflow validate \
  discord-agent-trio-chat --workflow-definition-dir ./examples
direnv exec . .build/arm64-apple-macosx/debug/riela workflow validate \
  matrix-agent-trio-chat --workflow-definition-dir ./examples
```

Run deterministic mock checks for all three chat vendors:

```bash
mkdir -p tmp/skill-chat-verification/logs tmp/skill-chat-verification/sessions
for workflow in telegram-agent-trio-chat discord-agent-trio-chat matrix-agent-trio-chat; do
  direnv exec . .build/arm64-apple-macosx/debug/riela workflow run "$workflow" \
    --workflow-definition-dir ./examples \
    --mock-scenario "./examples/$workflow/mock-scenario.json" \
    --session-store tmp/skill-chat-verification/sessions \
    --output json |
    tee "tmp/skill-chat-verification/logs/run-$workflow-node-ref-handoff.json"
done
```

Expected mock evidence:

- `status` is `completed`.
- `exitCode` is `0`.
- Final `rootOutput.replyAs` is `rina`.
- Final `rootOutput.handoffTrail` is `["yui","mika","rina"]`.
- Final `rootOutput.handoff_yui`, `handoff_mika`, and `handoff_rina` are all false.

Run an adversarial loop check when the file is available in `tmp/` or recreate
it under `tmp/skill-chat-verification/adversarial/`. The adversarial Rina output
must try to set `handoff_yui: true`; the memory-write add-on must block it:

```bash
direnv exec . .build/arm64-apple-macosx/debug/riela workflow run \
  telegram-agent-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario tmp/skill-chat-verification/adversarial/telegram-agent-trio-loop-mock.json \
  --session-store tmp/skill-chat-verification/sessions \
  --output json |
  tee tmp/skill-chat-verification/logs/run-agent-trio-adversarial-loop.json
```

Expected adversarial evidence:

- `rootOutput.handoffGuard.blocked` is true.
- `rootOutput.handoffGuard.reason` is `target-persona-already-replied`.
- `rootOutput.handoffGuard.selectedTarget` is `yui`.
- `rootOutput.handoff_yui` is false.
- `rootOutput.replyText` no longer contains a visible request to send the chat
  back to Yui or another already visited persona.

For a live Telegram browser check, start a listener for the trio event root under
test, then post in Telegram Web. Keep all transient event roots and logs under
`tmp/`:

```bash
rm -rf tmp/live-agent-trio-node-ref
mkdir -p \
  tmp/live-agent-trio-node-ref/events/sources \
  tmp/live-agent-trio-node-ref/events/bindings \
  tmp/live-agent-trio-node-ref/events/destinations \
  tmp/live-agent-trio-node-ref/sessions
cp examples/event-sources/.riela-events/sources/telegram-gateway-personas.json \
  tmp/live-agent-trio-node-ref/events/sources/
cp examples/event-sources/.riela-events/bindings/telegram-gateway-personas-to-workflow.json \
  tmp/live-agent-trio-node-ref/events/bindings/
cp examples/event-sources/.riela-events/destinations/telegram-gateway-persona-replies.json \
  tmp/live-agent-trio-node-ref/events/destinations/
direnv exec . .build/arm64-apple-macosx/debug/riela events validate \
  --workflow-definition-dir ./examples \
  --event-root tmp/live-agent-trio-node-ref/events
direnv exec . .build/arm64-apple-macosx/debug/riela events serve \
  --workflow-definition-dir ./examples \
  --event-root tmp/live-agent-trio-node-ref/events \
  --session-store tmp/live-agent-trio-node-ref/sessions \
  2>&1 | tee tmp/live-agent-trio-node-ref/events-serve.log
```

Open the exact Telegram chat URL in Brave Browser with Computer Use and send a
fresh marker message such as:

```text
@YuiCodexF0529Bot nodeRef-live-HHMM final sanitizer retest. Ask @mikatrend0529bot then @rinacursor0529bot for short opinions. Mika must not answer for Rina.
```

Live Telegram is verified only when all of these are true:

- Browser shows the user marker message.
- Browser shows visible Yui, Mika, and Rina replies for that same marker.
- `serve-record.json` reports `lastReplyAs` as `yui,mika,rina`.
- The matching Telegram history file contains the marker plus three assistant
  entries with `replyAs` `yui`, `mika`, and `rina`.
- The newest SQLite workflow snapshot is `completed`, has final
  `rootOutput.replyAs = rina`, and has
  `rootOutput.handoffTrail = ["yui","mika","rina"]`.
- Rina's final visible reply does not include a handoff request or continuation
  cue back to Yui or Mika, such as `@Yui`, `@Mika`, `次はミカ`, or another
  already visited persona request.

Useful evidence commands:

```bash
cat tmp/live-agent-trio-node-ref/events/serve-record.json
tail -n 60 tmp/live-agent-trio-node-ref/events/telegram-history/*/*.json
sqlite3 tmp/live-agent-trio-node-ref/sessions/runtime-records/runtime-message-log.sqlite \
  "select workflow_execution_id, json_extract(root_output_json,'$.replyAs'), json_extract(root_output_json,'$.replyText'), json_extract(root_output_json,'$.handoffTrail'), json_extract(session_json,'$.status'), updated_at from workflow_runtime_snapshots order by updated_at desc limit 5;"
```

For a live Discord browser check, use the checked-in persona event source as a
template and inject the target guild/channel from the local environment. The
example source may intentionally contain placeholder IDs, so do not run it
directly without this rewrite:

```bash
rm -rf tmp/live-discord-node-ref
mkdir -p \
  tmp/live-discord-node-ref/events/sources \
  tmp/live-discord-node-ref/events/bindings \
  tmp/live-discord-node-ref/events/destinations \
  tmp/live-discord-node-ref/sessions \
  tmp/live-discord-node-ref/logs
direnv exec . sh -lc '
set -eu
jq --arg guild "$RIELA_DISCORD_SERVER_ID" --arg channel "$RIELA_DISCORD_CHANNEL_ID" \
  ".guildIds = [\$guild] | .channels = [(.channels[0] | .id = \$channel)]" \
  examples/event-sources/.riela-events/sources/discord-gateway-personas.json \
  > tmp/live-discord-node-ref/events/sources/discord-gateway-personas.json
'
cp examples/event-sources/.riela-events/bindings/discord-gateway-personas-to-workflow.json \
  tmp/live-discord-node-ref/events/bindings/
cp examples/event-sources/.riela-events/destinations/discord-gateway-persona-replies.json \
  tmp/live-discord-node-ref/events/destinations/
direnv exec . .build/arm64-apple-macosx/debug/riela events validate \
  --workflow-definition-dir ./examples \
  --event-root tmp/live-discord-node-ref/events \
  --output json | tee tmp/live-discord-node-ref/logs/events-validate.json
direnv exec . .build/arm64-apple-macosx/debug/riela events serve \
  --workflow-definition-dir ./examples \
  --event-root tmp/live-discord-node-ref/events \
  --session-store tmp/live-discord-node-ref/sessions \
  2>&1 | tee tmp/live-discord-node-ref/logs/events-serve.log
```

Open the Discord channel URL for `$RIELA_DISCORD_SERVER_ID` and
`$RIELA_DISCORD_CHANNEL_ID` in Brave Browser with Computer Use, then send a fresh
marker such as:

```text
Yui, nodeRef-discord-live-HHMM final sanitizer retest. Ask Mika then Rina for short opinions. Mika must not answer for Rina.
```

Live Discord is verified only when all of these are true:

- Browser shows the marker in the target channel.
- Browser shows visible Yui, Mika, and Rina replies for that same marker.
- `serve-record.json` reports `lastReplyAs` as `yui,mika,rina` and
  `lastReplyDispatchCount` as `3`.
- The matching Discord history file contains the marker plus three assistant
  entries with `replyAs` `yui`, `mika`, and `rina`.
- The newest SQLite workflow snapshot is `completed`, has final
  `rootOutput.replyAs = rina`, and has
  `rootOutput.handoffTrail = ["yui","mika","rina"]`.
- Rina's final visible reply does not include a handoff request or continuation
  cue back to Yui or Mika.

Useful Discord evidence commands:

```bash
cat tmp/live-discord-node-ref/events/serve-record.json
tail -n 80 tmp/live-discord-node-ref/events/discord-history/*/*.json
sqlite3 tmp/live-discord-node-ref/sessions/runtime-records/runtime-message-log.sqlite \
  "select workflow_execution_id, json_extract(root_output_json,'$.replyAs'), json_extract(root_output_json,'$.replyText'), json_extract(root_output_json,'$.handoffTrail'), json_extract(session_json,'$.status'), updated_at from workflow_runtime_snapshots order by updated_at desc limit 5;"
```

If a marker appears in Telegram or Discord but no workflow session is created,
check the event source offset and seen-message files before retrying. Do not call
the run verified until either the browser shows fresh bot replies or
SQLite/session evidence proves the listener processed the marker. Stop the manual
listener with `Ctrl-C` after the check unless the user asks to keep it running.

## Known Example Targets

- Telegram trio: `examples/telegram-agent-trio-chat`
- Discord trio: `examples/discord-agent-trio-chat`
- Matrix trio: `examples/matrix-agent-trio-chat`
- Shared Yui/Mika/Rina persona nodes: `examples/shared-agent-trio-personas`
- Raw log and daily summary memory split: `examples/chat-memory-raw-and-daily-summary`
- Yui image asset: `examples/telegram-agent-trio-chat/assets/icons/yui-codex.png`

For Matrix, prefer the deterministic local sample when live homeserver credentials are unavailable. Read [matrix-local.md](references/matrix-local.md) when Matrix needs local verification.

## Recent History Evidence

When asked to reuse previous Codex evidence, search only session logs and redact credentials before displaying anything:

```bash
find "$HOME/.codex/sessions" -type f -mtime -4 -name '*.jsonl' -print0 |
  xargs -0 rg -n -i 'telegram|discord|matrix|RielaApp|events serve|events list|completed|reply|records|receipt'
```

Do not trust broad search output directly because Codex session files include developer prompts, tool schemas, and possibly secret-looking strings. Read [history-evidence.md](references/history-evidence.md) for the known successful artifacts and the safer interpretation checklist.

For the 2026-06-22 four-day history search, treat `tmp/trio-memory-recreate/{telegram,discord,matrix}` as the known good three-platform memory regression. It proves deterministic Telegram/Discord/Matrix workflow memory behavior when each run is `completed`, `exitCode=0`, `nodeExecutions=13`, `transitions=12`, the SQLite counts are `1|2|3`, and final `rootOutput.replyAs` is `rina`. It is not live browser-chat proof unless paired with a fresh visible reply, receipt, or post-message session from the same run.

## Attachment Blocker Check

Before testing the image flow, inspect gateway support:

```bash
rg -n 'caption|photo|imagePaths|attachments|message\.text' Sources/RielaCLI/EventLiveServe*.swift
```

The image flow is blocked if:

- Telegram accepts only `message.text` and ignores `caption` or `photo`.
- Telegram/Discord populate attachment descriptors but leave `imagePaths: []` while the workflow expects real image analysis.
- The event source config says `resolveFilePaths: true` but the gateway implementation does not download or materialize image files.

Report these as implementation blockers, not test success.

## Telegram File Memory Live Check

Use this when asked to prove that Telegram image memory is stored as file-backed memory and can be reused by a later persona turn.

Start the listener for the installed Telegram SDK trio workflow:

```bash
direnv exec . .build/arm64-apple-macosx/debug/riela events serve \
  --workflow-definition-dir "$HOME/.riela/workflows" \
  --event-root "$HOME/.riela/workflows/telegram-sdk-trio-chat/.riela-events" \
  --session-store "$HOME/.riela/sessions"
```

Confirm the listener before sending messages:

```bash
ps aux | rg -i 'riela events serve' | rg -v 'rg -i'
cat "$HOME/.riela/workflows/telegram-sdk-trio-chat/.riela-events/serve-record.json"
```

In Telegram Web, open the exact target chat URL, attach the Yui image asset as Photo or Video, and send a caption that mentions Mika, for example:

```text
@mikatrend0529bot Live file-memory retest HHMM: What is visible in this image? Reply briefly.
```

After Mika replies, verify all three layers:

```bash
find "$HOME/.riela/workflows/telegram-sdk-trio-chat/.riela-events/attachments" \
  -type f -mmin -10 -print -exec file {} \;

sqlite3 "$PWD/.riela/memory/chat-memory.sqlite" \
  'select file_id,record_id,path,media_type,kind,name,size_bytes from memory_files order by file_id desc limit 10;'

jq -r '.session | [.sessionId,.status,.entryStepId,.createdAt,.updatedAt] | @tsv' \
  "$HOME/.riela/sessions"/telegram-sdk-trio-chat-session-*.json | tail
```

The expected evidence is:

- Telegram event root has a fresh downloaded image under `.riela-events/attachments/...`.
- `memory_files` has a row for the same logical image copied under `.riela/memory/files/chat-memory/<record-id>/...`.
- The session starts at `save-chat-event-memory`, not a persona node.
- `load-mika-chat-memory` returns `memoryAttachmentCountRead > 0` and non-empty `imagePaths`.
- The visible Mika reply describes the image content, not only that a square photo exists.

Then ask Rina about the same image without reattaching it:

```text
@rinacursor0529bot Live file-memory retest HHMM: What image did I just show Mika? Reply briefly.
```

Verify the follow-up session:

```bash
jq -r '.session.executions[] |
  [.stepId,.status,(.acceptedOutput.payload.operation // .acceptedOutput.payload.replyAs // ""),
   (.acceptedOutput.payload.memoryAttachmentCountRead // ""),
   (.acceptedOutput.payload.imagePaths // "" | tostring),
   (.acceptedOutput.payload.replyText // "")] | @tsv' \
  "$HOME/.riela/sessions/telegram-sdk-trio-chat-session-<id>.json"
```

The Rina turn is verified only when `load-rina-chat-memory` returns non-empty `imagePaths` and the visible Rina reply describes the previously stored image. Stop the manual listener after the check with `Ctrl-C` unless the user asks to keep it running.

## Final Report

Include:

- RielaApp launch result and daemon child status.
- Which chat surfaces were tested.
- Message timestamp or latest event/session id.
- Whether memory write/update/read was observed.
- Whether image attachment content was actually available to the model.
- Any missing env vars by name only.
