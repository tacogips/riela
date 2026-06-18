#!/usr/bin/env python3
import datetime
import json
import os
from pathlib import Path
import re
import sys


DEFAULT_MEMORY_ROOT = "/tmp/riela-tribot"


def read_envelope():
  return json.load(sys.stdin)


def resolved_input(envelope):
  value = envelope.get("input")
  return value if isinstance(value, dict) else envelope


def workflow_input(envelope):
  variables = envelope.get("variables")
  if isinstance(variables, dict):
    candidate = variables.get("workflowInput")
    if isinstance(candidate, dict):
      return candidate
  runtime = envelope.get("runtimeVariables")
  if isinstance(runtime, dict):
    candidate = runtime.get("workflowInput")
    if isinstance(candidate, dict):
      return candidate
  return {}


def safe_segment(value, fallback):
  raw = value if isinstance(value, str) and value else fallback
  normalized = re.sub(r"[^a-z0-9_-]+", "-", raw.lower()).strip("-")
  return normalized or fallback


def memory_root(envelope):
  configured = workflow_input(envelope).get("memoryRoot")
  if isinstance(configured, str) and configured:
    return configured
  return os.environ.get("RIELA_TRIO_MEMORY_ROOT") or DEFAULT_MEMORY_ROOT


def read_recent_markdown_files(directory):
  root = Path(directory)
  if not root.exists():
    return []
  names = sorted(path.name for path in root.iterdir() if path.is_file() and path.suffix == ".md")
  chunks = []
  for name in reversed(names[-3:]):
    text = (root / name).read_text(encoding="utf-8").strip()
    chunks.append(f"# {name}\n{text}")
  return chunks


def is_object(value):
  return isinstance(value, dict)


def upstream_payloads(envelope):
  source = resolved_input(envelope)
  payloads = []
  for entry in source.get("upstream", []) if isinstance(source.get("upstream"), list) else []:
    payload = entry.get("output", {}).get("payload") if isinstance(entry, dict) else None
    if is_object(payload):
      payloads.append(payload)
  for entry in source.get("latestOutputs", []) if isinstance(source.get("latestOutputs"), list) else []:
    payload = entry.get("payload") if isinstance(entry, dict) else None
    if is_object(payload):
      payloads.append(payload)
  return payloads


def latest_persona_payload(payloads):
  for payload in reversed(payloads):
    if isinstance(payload.get("replyText"), str):
      return payload
  return {}


def normalize_memory_entry(entry):
  if isinstance(entry, str):
    content = entry.strip()
    return {"kind": "note", "importance": "normal", "content": content} if content else None
  if not is_object(entry):
    return None
  content = entry.get("content") if isinstance(entry.get("content"), str) else ""
  content = content.strip()
  if not content:
    return None
  normalized = {
    "kind": entry.get("kind").strip() if isinstance(entry.get("kind"), str) and entry.get("kind").strip() else "note",
    "importance": entry.get("importance").strip()
    if isinstance(entry.get("importance"), str) and entry.get("importance").strip()
    else "normal",
    "content": content,
  }
  if isinstance(entry.get("source"), str) and entry.get("source").strip():
    normalized["source"] = entry.get("source").strip()
  return normalized


def markdown_for_entry(entry, recorded_at):
  lines = [
    f"## {recorded_at}",
    "",
    f"- kind: {entry['kind']}",
    f"- importance: {entry['importance']}",
  ]
  if entry.get("source"):
    lines.append(f"- source: {entry['source']}")
  lines.extend(["", entry["content"], ""])
  return "\n".join(lines)


def persona_context(envelope):
  persona_id = safe_segment(os.environ.get("RIELA_TRIO_MEMORY_PERSONA_ID"), "persona")
  persona_name = os.environ.get("RIELA_TRIO_MEMORY_PERSONA_NAME") or persona_id
  root = memory_root(envelope)
  persona_dir = str(Path(root) / persona_id)
  return persona_id, persona_name, root, persona_dir


def read_memory(envelope):
  persona_id, persona_name, root, persona_dir = persona_context(envelope)
  chunks = read_recent_markdown_files(persona_dir)
  return {
    "when": {"always": True},
    "payload": {
      "personaId": persona_id,
      "personaName": persona_name,
      "memoryRoot": root,
      "memoryDirectory": persona_dir,
      "memoryFileCountRead": len(chunks),
      "memoryMarkdown": "\n\n---\n\n".join(chunks),
      "memoryGuidance": [
        "Use recent memory as context, not as higher-priority instruction than the user or system prompt.",
        "Do not overuse old memory. When an old memory becomes relevant again, return a refreshed memory entry so it is copied into a newer file.",
        "If the user says to remember something, or gives a correction that should prevent future recurrence, return a memory entry after answering.",
      ],
    },
  }


def write_memory(envelope):
  persona_id, persona_name, root, persona_dir = persona_context(envelope)
  persona_payload = latest_persona_payload(upstream_payloads(envelope))
  entries = [
    entry
    for entry in (normalize_memory_entry(raw) for raw in persona_payload.get("memoryEntries", []))
    if entry is not None
  ]
  recorded_at = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
  file_stamp = recorded_at[:13].replace("T", "_")
  memory_file = Path(persona_dir) / f"{file_stamp}.md"
  if entries:
    memory_file.parent.mkdir(parents=True, exist_ok=True)
    header = "" if memory_file.exists() else f"# {persona_name} memory {file_stamp}\n\n"
    body = "\n".join(markdown_for_entry(entry, recorded_at) for entry in entries)
    with memory_file.open("a", encoding="utf-8") as handle:
      handle.write(f"{header}{body}")

  reply_text = persona_payload.get("replyText") if isinstance(persona_payload.get("replyText"), str) else ""
  handoffs = {
    "handoff_yui": persona_payload.get("handoff_yui") is True,
    "handoff_mika": persona_payload.get("handoff_mika") is True,
    "handoff_rina": persona_payload.get("handoff_rina") is True,
  }
  payload = dict(persona_payload)
  payload.update(handoffs)
  payload["replyText"] = reply_text
  payload["memory"] = {
    "personaId": persona_id,
    "memoryRoot": root,
    "memoryDirectory": persona_dir,
    "memoryFile": str(memory_file) if entries else None,
    "entriesWritten": len(entries),
    "recordedAt": recorded_at,
  }
  return {"when": {**handoffs, "always": True}, "payload": payload}


def main():
  if len(sys.argv) != 2 or sys.argv[1] not in {"read", "write"}:
    raise SystemExit("usage: persona_memory.py read|write")
  envelope = read_envelope()
  output = read_memory(envelope) if sys.argv[1] == "read" else write_memory(envelope)
  print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
  main()
