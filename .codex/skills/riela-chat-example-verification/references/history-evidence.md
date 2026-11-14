# Recent Codex History Evidence

Use this reference when asked to reconstruct how Telegram, Discord, or Matrix
chat examples were previously verified. Treat history as evidence routing, not
proof that current credentials, listeners, workflows, or storage contracts work.

## Safe Search

Search recent Codex sessions and redact before reporting:

```bash
python3 - <<'PY'
import json, pathlib, re, time
root = pathlib.Path.home() / ".codex/sessions"
cut = time.time() - 4 * 24 * 3600
chat = re.compile(r"telegram|discord|matrix|RielaApp|events serve|events list", re.I)
evidence = re.compile(r"completed|reply|records|receipt|status.*ok|Process exited with code 0|成功|動作確認", re.I)
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

Treat the output as a lead list. Inspect referenced artifacts under `tmp/`
instead of copying full session lines into a report.

## Legacy Evidence Boundary

Artifacts created before the Note-backed migration may contain obsolete
standalone-memory databases, row-count checks, paths, or add-on names. They can
prove what an old build did, but they are not reusable verification commands and
must not be reported as current success.

In particular, the 2026-06-22 three-platform artifacts predate the Note-backed
contract. Keep their conclusions limited to historical handoff behavior. Do not
query their old databases or compare their old storage row counts with a current
run.

## Current Deterministic Reproduction

Regenerate evidence from the checked-in workflows with an isolated Note root:

```bash
rm -rf tmp/skill-chat-history-current
mkdir -p tmp/skill-chat-history-current/{logs,sessions,notes}
for workflow in telegram-agent-trio-chat discord-agent-trio-chat matrix-agent-trio-chat; do
  RIELA_NOTE_ROOT="$PWD/tmp/skill-chat-history-current/notes/$workflow" \
    .build/arm64-apple-macosx/debug/riela workflow run "$workflow" \
      --workflow-definition-dir ./examples \
      --mock-scenario "./examples/$workflow/mock-scenario.json" \
      --session-store tmp/skill-chat-history-current/sessions \
      --output json > "tmp/skill-chat-history-current/logs/$workflow.json"
done
```

For every workflow, require:

- `status` is `completed` and `exitCode` is `0`;
- final `rootOutput.replyAs` is `rina`;
- final `rootOutput.handoffTrail` is `yui,mika,rina` in order; and
- the isolated `note-store.sqlite` contains persona-tagged notes in the
  `notebook-kind:system-memory` notebook.

Example Note evidence query:

```bash
sqlite3 tmp/skill-chat-history-current/notes/telegram-agent-trio-chat/note-store.sqlite \
  "select n.note_id,t.name
   from notebooks b
   join notebook_tags bt on bt.notebook_id=b.notebook_id
   join tags kind on kind.tag_id=bt.tag_id and kind.name='notebook-kind:system-memory'
   join notes n on n.notebook_id=b.notebook_id
   join note_tags nt on nt.note_id=n.note_id
   join tags t on t.tag_id=nt.tag_id
   where t.name like 'persona:%'
   order by n.created_at,t.name;"
```

## Live Evidence Boundary

For live chat, require evidence created after the test message:

- RielaApp or the matching `riela events serve` child remains running;
- `riela events list` shows a new matching receipt;
- a new workflow session completes; and
- the browser/chat UI shows the corresponding reply.

A listener-ready record or successful direct Bot API post proves only that the
listener started or the platform accepted a message. Neither proves end-to-end
chat ingestion or a visible reply.
