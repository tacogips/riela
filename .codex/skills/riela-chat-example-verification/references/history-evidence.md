# Recent Codex History Evidence

Use this reference when asked to reconstruct how Telegram, Discord, or Matrix chat examples were previously verified from Codex history. Treat this as evidence routing, not as proof that today's live credentials or listeners are working.

## Safe Search

Search recent Codex sessions, but redact before reporting:

```bash
python3 - <<'PY'
import json, pathlib, re, time
root = pathlib.Path.home() / ".codex/sessions"
cut = time.time() - 4 * 24 * 3600
chat = re.compile(r"telegram|discord|matrix|RielaApp|events serve|events list", re.I)
evidence = re.compile(r"completed|reply|replied|records|receipt|status.*ok|Process exited with code 0|成功|動作確認", re.I)
redact = [
    (re.compile(r"bot\d+:[A-Za-z0-9_-]+"), "<REDACTED_BOT_TOKEN>"),
    (re.compile(r"sk-[A-Za-z0-9_-]{20,}"), "<REDACTED_OPENAI_KEY>"),
    (re.compile(r"[A-Za-z0-9_-]{24,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{20,}"), "<REDACTED_DISCORD_TOKEN>"),
]

def flatten(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(flatten(item) for item in value)
    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=False)
    return str(value)

for path in sorted(root.rglob("*.jsonl")):
    try:
        if path.stat().st_mtime < cut:
            continue
    except OSError:
        continue
    for line_number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        payload = obj.get("payload") or {}
        texts = []
        if payload.get("type") == "message" and payload.get("role") in {"user", "assistant"}:
            for content in payload.get("content") or []:
                if isinstance(content, dict) and content.get("type") in {"input_text", "output_text"}:
                    texts.append(flatten(content.get("text")))
        elif payload.get("type") in {"function_call", "function_call_output"}:
            texts.append(flatten(payload.get("arguments") or payload.get("output")))
        text = " ".join("\n".join(texts).split())
        if not text or not chat.search(text) or not evidence.search(text):
            continue
        for pattern, replacement in redact:
            text = pattern.sub(replacement, text)
        print(f"{path}:{line_number}: {text[:1000]}")
PY
```

The output is a lead list. Follow up by inspecting the referenced artifact files under `tmp/`, not by copying full session lines into the final answer.

## Successful Evidence Found

As of the 2026-06-22 search, these useful artifacts existed in this repository:

- `tmp/telegram-live-persona/*.send-response.json`
- `tmp/telegram-trio-live/slim-events/serve-record.json`
- `tmp/trio-memory-recreate/{telegram,discord,matrix}/run.json`
- `tmp/trio-memory-recreate/{telegram,discord,matrix}/memory/persona-chat-memory.sqlite`
- `tmp/trio-memory-recreate/{telegram,discord,matrix}/sessions/runtime-records/*/runtime-snapshot.json`

The 2026-06-22 four-day Codex history search found a real three-platform success only for the
deterministic persona memory regression. It did not find a browser-visible live Telegram,
Discord, or Matrix chat success for all three services. Keep this distinction explicit in final
reports.

The useful Codex history leads were:

- `~/.codex/sessions/2026/06/20/rollout-2026-06-20T12-18-58-019ee309-ea81-7e43-8aad-bf2d577c9eb4.jsonl`
  showed RielaApp and `riela events serve` for `telegram-sdk-trio-chat` reaching `telegram-gateway-live` `status=ready`, then later showed no new sessions/receipts for a separate pasted chat. Treat this as a mixed live Telegram lead, not a full success.
- `~/.codex/sessions/2026/06/22/rollout-2026-06-22T16-59-21-019eee57-5683-7d23-8f2e-b4d693d6c983.jsonl`
  showed the regression suite executing the relevant Telegram, Discord, and Matrix checks, including `testTelegramAndDiscordTrioChatMemoryReadsAndWrites`, `testMatrixGatewayPayloadFixtureMatchesEventBinding`, and live-gateway unit coverage such as `testTelegramGatewayServePollsRunsWorkflowAndSendsReply` and `testDiscordGatewayServePollsRunsWorkflowAndSendsPersonaReplies`.
- `~/.codex/sessions/2026/06/22/rollout-2026-06-22T17-19-33-019eee69-d2bf-7cd2-b085-8b8cfb021185.jsonl`
  showed the migrated example contracts and the memory-regression test body that seeds `persona-chat-memory`, runs Telegram/Discord examples, and checks the resulting session output. It also showed Matrix trio handoff fixture changes that make the final reply come from Rina.
- `~/.codex/sessions/2026/06/19/rollout-2026-06-19T21-28-31-019edfda-af29-7b13-82b4-d06607ee656d.jsonl`
  showed an earlier Telegram trio workflow run completing with `exitCode=0`, `nodeExecutions=13`, `transitions=12`, and ordered send outputs for Yui, Mika, and Rina. It also records that duplicated Telegram messages from fallback Bot API sending were not accepted as proof of bot-to-bot live reading.

Current artifact verification commands:

```bash
for d in telegram discord matrix; do
  jq -r '[.workflowId,.status,.exitCode,(.nodeExecutions|tostring),(.transitions|tostring)] | @tsv' \
    "tmp/trio-memory-recreate/$d/run.json"
  sqlite3 "tmp/trio-memory-recreate/$d/memory/persona-chat-memory.sqlite" \
    'select (select count(*) from memory_metadata),(select count(*) from memory_entries),(select count(*) from memory_entry_references);'
  jq '{rootOutput: .rootOutput}' \
    "tmp/trio-memory-recreate/$d/sessions/runtime-records/"*"/runtime-snapshot.json"
done
```

Known output shape from the 2026-06-22 artifact check:

- `telegram-agent-trio-chat`, `discord-agent-trio-chat`, and `matrix-agent-trio-chat` all returned `completed`, `exitCode=0`, `nodeExecutions=13`, `transitions=12`.
- Each platform DB had `memory_metadata=1`, `memory_entries=2`, and `memory_entry_references=3`.
- Each final runtime snapshot had `rootOutput.status=ok`, `replyAs=rina`, and a non-empty `replyText`.

Exact output observed when rechecking the artifact on 2026-06-22:

```text
telegram-agent-trio-chat completed 0 13 12
discord-agent-trio-chat completed 0 13 12
matrix-agent-trio-chat completed 0 13 12
1|2|3
1|2|3
1|2|3
telegram: status=ok replyAs=rina hasReplyText=true
discord: status=ok replyAs=rina hasReplyText=true
matrix: status=ok replyAs=rina hasReplyText=true
```

This means the check proved:

- each platform workflow can read the seeded Yui memory from the SQLite-backed `persona-chat-memory`;
- the workflow can write new memory entries and references;
- the handoff chain reaches Rina and returns a final user-facing reply;
- Telegram, Discord, and Matrix examples use separate platform-specific workflow inputs while sharing the same memory contract.

This does not mean:

- RielaApp was processing live messages for all three services at that moment;
- a visible browser chat reply was observed for Discord or Matrix;
- image attachments were successfully downloaded and exposed as non-empty `imagePaths`.

Telegram live persona evidence:

```bash
jq '{ok, message_id: .result.message_id, chat: .result.chat.id, date: .result.date, text: .result.text}' \
  tmp/telegram-live-persona/*.send-response.json
```

Interpret `ok: true` plus a `message_id` as proof that Telegram accepted the bot message. This verifies Bot API posting, not necessarily RielaApp event ingestion.

Telegram live RielaApp/daemon lead:

```bash
jq '{eventRoot,mode,status,records}' tmp/telegram-trio-live/slim-events/serve-record.json
```

Interpret `mode=telegram-gateway-live` and `status=ready` as proof that the listener started. It is not enough by itself. Pair it with one of:

- A new receipt under `tmp/telegram-trio-live/slim-events/receipts`.
- A new runtime session after the chat message.
- Browser-visible bot reply in the same Telegram chat.

Telegram, Discord, and Matrix persona memory regression evidence:

```bash
for d in telegram discord matrix; do
  echo "--- $d run"
  jq '{workflowId,status,exitCode,nodeExecutions,transitions}' "tmp/trio-memory-recreate/$d/run.json"
  echo "--- $d memory counts"
  sqlite3 "tmp/trio-memory-recreate/$d/memory/persona-chat-memory.sqlite" \
    "select count(*) from memory_metadata; select count(*) from memory_entries; select count(*) from memory_entry_references;"
  echo "--- $d final reply"
  jq '{rootOutput: .rootOutput}' "tmp/trio-memory-recreate/$d/sessions/runtime-records/"*"/runtime-snapshot.json"
done
```

The known good pattern was:

- `status` was `completed`.
- `exitCode` was `0`.
- `nodeExecutions` was `13`.
- `transitions` was `12`.
- Each platform had one metadata row, two memory entries, and three memory references.
- Final `rootOutput.status` was `ok`, `replyAs` was `rina`, and `replyText` was present.

This verifies deterministic memory read/write and reply generation for Telegram, Discord, and Matrix examples. It does not prove live Telegram/Discord/Matrix browser chat replies unless paired with visible UI or event receipt evidence from the same run.

Do not report live Discord or live Matrix success from the current history search. The successful three-platform evidence is deterministic workflow regression, not browser-visible live chat ingestion. The Matrix evidence is `events emit` / fixture parity and the `matrix-agent-trio-chat` deterministic memory run.

Matrix local-synapse note:

The recent history search found references to `examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh`, but no clear successful local-synapse run log. Do not report Matrix live/local-synapse as verified from history unless a fresh run or a matching success artifact is found.

## How To Reproduce The Historical Checks

For deterministic memory regression:

```bash
rm -rf tmp/trio-memory-recreate
mkdir -p tmp/trio-memory-recreate/{telegram,discord,matrix}
# Create or reuse platform-specific mock scenarios under tmp/trio-memory-recreate/<platform>/.
# Run each platform workflow with --mock-scenario and --session-store under the same platform directory.
riela workflow run telegram-agent-trio-chat --workflow-definition-dir ./examples \
  --mock-scenario tmp/trio-memory-recreate/telegram/mock-scenario.json \
  --session-store tmp/trio-memory-recreate/telegram/sessions \
  --output json > tmp/trio-memory-recreate/telegram/run.json
```

Repeat with `discord-agent-trio-chat` and `matrix-agent-trio-chat`. Then query the sqlite memory database and runtime snapshot as above.

For live chat, require stronger evidence:

- RielaApp or `riela events serve` child is running for the relevant source.
- `riela events list --source <source-id> --event-root <event-root> --limit 20 --output json` shows a new receipt.
- Browser/Computer Use shows the reply in Telegram, Discord, or Matrix.
- The workflow session created after the chat message completed.
