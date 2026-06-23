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

## Known Example Targets

- Telegram trio: `examples/telegram-agent-trio-chat`
- Discord trio: `examples/discord-agent-trio-chat`
- Matrix trio: `examples/matrix-agent-trio-chat`
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
