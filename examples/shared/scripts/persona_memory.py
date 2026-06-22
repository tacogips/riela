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
  reply_aliases = ("replyText", "text", "message", "reply", "reply_text", "response", "content")
  if is_object(source) and any(isinstance(source.get(alias), str) for alias in reply_aliases):
    payloads.append(source)
  nested_payload = source.get("payload") if is_object(source) else None
  if is_object(nested_payload) and any(isinstance(nested_payload.get(alias), str) for alias in reply_aliases):
    payloads.append(nested_payload)
  for entry in source.get("upstream", []) if isinstance(source.get("upstream"), list) else []:
    payload = entry.get("output", {}).get("payload") if isinstance(entry, dict) else None
    if is_object(payload):
      payloads.append(payload)
      nested_payload = payload.get("payload")
      if is_object(nested_payload) and any(isinstance(nested_payload.get(alias), str) for alias in reply_aliases):
        payloads.append(nested_payload)
  for entry in source.get("latestOutputs", []) if isinstance(source.get("latestOutputs"), list) else []:
    payload = entry.get("payload") if isinstance(entry, dict) else None
    if is_object(payload):
      payloads.append(payload)
      nested_payload = payload.get("payload")
      if is_object(nested_payload) and any(isinstance(nested_payload.get(alias), str) for alias in reply_aliases):
        payloads.append(nested_payload)
  return payloads


def latest_persona_payload(payloads):
  for payload in reversed(payloads):
    if isinstance(payload.get("replyText"), str):
      return payload
    for alias in ("text", "message", "reply", "reply_text", "response", "content"):
      if isinstance(payload.get(alias), str):
        normalized = dict(payload)
        normalized["replyText"] = payload[alias]
        return normalized
  return {}


def text_mentions_persona(text, persona_name):
  if not isinstance(text, str):
    return False
  pattern = rf"(^|[^A-Za-z0-9_@])@?{re.escape(persona_name)}([^A-Za-z0-9_]|$)"
  return re.search(pattern, text, flags=re.IGNORECASE) is not None


def conversation_texts(envelope, payloads):
  texts = []
  texts.extend(conversation_texts_from_object(workflow_input(envelope)))
  variables = envelope.get("variables")
  if isinstance(variables, dict):
    for key in ("humanInput", "event"):
      value = variables.get(key)
      if isinstance(value, dict):
        texts.extend(conversation_texts_from_object(value))
  runtime = envelope.get("runtimeVariables")
  if isinstance(runtime, dict):
    for key in ("humanInput", "event"):
      value = runtime.get(key)
      if isinstance(value, dict):
        texts.extend(conversation_texts_from_object(value))
  texts.extend(conversation_texts_from_object(resolved_input(envelope)))
  for payload in payloads:
    for key in ("replyText", "text", "message", "reply", "reply_text", "response", "content"):
      value = payload.get(key)
      if isinstance(value, str):
        texts.append(value)
  return texts


def conversation_texts_from_object(value):
  texts = []
  if not isinstance(value, dict):
    return texts
  for key in ("request", "text", "message", "replyText", "content"):
    candidate = value.get(key)
    if isinstance(candidate, str):
      texts.append(candidate)
  nested_input = value.get("input")
  if isinstance(nested_input, dict):
    texts.extend(conversation_texts_from_object(nested_input))
  return texts


def primary_request_text(envelope):
  for value in [
    workflow_input(envelope),
    resolved_input(envelope),
  ]:
    for text in conversation_texts_from_object(value):
      if text.strip():
        return text.strip()
  variables = envelope.get("variables")
  if isinstance(variables, dict):
    for key in ("humanInput", "event"):
      for text in conversation_texts_from_object(variables.get(key)):
        if text.strip():
          return text.strip()
  runtime = envelope.get("runtimeVariables")
  if isinstance(runtime, dict):
    for key in ("humanInput", "event"):
      for text in conversation_texts_from_object(runtime.get(key)):
        if text.strip():
          return text.strip()
  return ""


def conversation_id(envelope):
  for value in [workflow_input(envelope), resolved_input(envelope)]:
    if isinstance(value, dict):
      candidate = value.get("conversationId")
      if isinstance(candidate, str) and candidate.strip():
        return candidate.strip()
      event = value.get("event")
      if isinstance(event, dict):
        conversation = event.get("conversation")
        if isinstance(conversation, dict) and isinstance(conversation.get("id"), str):
          return conversation["id"].strip()
  variables = envelope.get("variables")
  if isinstance(variables, dict):
    event = variables.get("event")
    if isinstance(event, dict):
      conversation = event.get("conversation")
      if isinstance(conversation, dict) and isinstance(conversation.get("id"), str):
        return conversation["id"].strip()
  return "default"


def state_file_path(root, envelope):
  return Path(root) / "_conversation_state" / f"{safe_segment(conversation_id(envelope), 'default')}.json"


def load_conversation_state(root, envelope, request_text):
  path = state_file_path(root, envelope)
  if not path.exists():
    return {"turns": 0, "request": request_text}
  try:
    state = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError):
    return {"turns": 0, "request": request_text}
  if state.get("request") != request_text:
    return {"turns": 0, "request": request_text}
  return state


def save_conversation_state(root, envelope, request_text, turns):
  path = state_file_path(root, envelope)
  path.parent.mkdir(parents=True, exist_ok=True)
  payload = {"request": request_text, "turns": turns}
  path.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def autonomous_chat_requested(texts):
  markers = (
    "しばらく",
    "自律",
    "自然に雑談",
    "自然な雑談",
    "続けて",
    "続ける",
    "for a while",
    "keep chatting",
    "continue chatting",
    "autonomous",
  )
  lowered = "\n".join(text for text in texts if isinstance(text, str)).lower()
  return any(marker in lowered for marker in markers)


def sent_reply_count(payloads):
  counts = []
  for payload in payloads:
    value = payload.get("autonomousTurns")
    if isinstance(value, int):
      counts.append(value)
    elif isinstance(value, float):
      counts.append(int(value))
  return max(counts) if counts else sum(1 for payload in payloads if isinstance(payload.get("replyAs"), str))


def fallback_reply(persona_id, persona_name, texts, autonomous_turns):
  if persona_id == "yui":
    return "では、肩の力を抜いて続けましょう。最近少し気分が上がったことはありますか？ @Mika なら、今の空気に合う軽い話題を拾えそうです。"
  if persona_id == "mika":
    return "いいね、ゆるく続けよ。最近は配信やSNSの話題も流れが早いし、ちょっとした発見でも盛り上がれる感じあるよね。@Rina は最近気になった作品や技術の話ある？"
  if persona_id == "rina":
    if autonomous_chat_requested(texts) and autonomous_turns < 6:
      return "了解。私は最近、配信サービスごとの独占作品が増えている流れが少し気になっている。見る側の選択肢は増えたようで、実際は追う負荷も増えている。@Yui はこういう変化、生活目線だとどう見える？"
    return "了解。ここまでで一度区切れる。次に話題を変えるなら、作品、開発、日常のどれでも対応できる。"
  return f"{persona_name}です。今の話題を受けて、自然に続けます。"


def final_autonomous_reply(text):
  cleaned = re.sub(r"\s*@(?:Yui|Mika|Rina)[^。！？\n]*(?:[。！？]|$)", "", text).strip()
  if len(cleaned) >= 15:
    return f"{cleaned}\n\nここで一度区切る。"
  return "了解。ここまでで自然な雑談として一度区切る。次は話題を変えても、この続きを拾っても対応できる。"


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
  payloads = upstream_payloads(envelope)
  persona_payload = latest_persona_payload(payloads)
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

  handoffs = {
    "handoff_yui": persona_payload.get("handoff_yui") is True,
    "handoff_mika": persona_payload.get("handoff_mika") is True,
    "handoff_rina": persona_payload.get("handoff_rina") is True,
  }
  base_texts = conversation_texts(envelope, payloads)
  request_text = primary_request_text(envelope)
  state = load_conversation_state(root, envelope, request_text)
  autonomous_turns = max(sent_reply_count(payloads), int(state.get("turns", 0))) + 1
  reply_text = persona_payload.get("replyText") if isinstance(persona_payload.get("replyText"), str) else ""
  if not reply_text.strip():
    reply_text = fallback_reply(persona_id, persona_name, base_texts, autonomous_turns)
  if persona_id == "rina" and autonomous_chat_requested(base_texts) and autonomous_turns >= 6:
    reply_text = final_autonomous_reply(reply_text)
  texts = base_texts + [reply_text]
  if persona_id == "mika" and any(text_mentions_persona(text, "rina") for text in texts):
    handoffs["handoff_rina"] = True
    handoffs["handoff_yui"] = False
    handoffs["handoff_mika"] = False
  if persona_id == "rina" and autonomous_chat_requested(texts) and autonomous_turns < 6:
    handoffs["handoff_yui"] = True
    handoffs["handoff_mika"] = False
    handoffs["handoff_rina"] = False
  elif persona_id == "rina" and any(text_mentions_persona(text, "mika") for text in texts):
    handoffs["handoff_yui"] = False
    handoffs["handoff_mika"] = False
    handoffs["handoff_rina"] = False
  true_handoffs = [name for name, enabled in handoffs.items() if enabled]
  if len(true_handoffs) > 1:
    priorities = {
      "yui": ["handoff_mika", "handoff_rina"],
      "mika": ["handoff_rina", "handoff_yui"],
      "rina": ["handoff_mika", "handoff_yui"],
    }.get(persona_id, ["handoff_mika", "handoff_rina", "handoff_yui"])
    selected = next((name for name in priorities if name in true_handoffs), true_handoffs[0])
    handoffs = {name: name == selected for name in handoffs}
  payload = dict(persona_payload)
  payload.update(handoffs)
  payload["replyText"] = reply_text
  payload["autonomousTurns"] = autonomous_turns
  payload["memory"] = {
    "personaId": persona_id,
    "memoryRoot": root,
    "memoryDirectory": persona_dir,
    "memoryFile": str(memory_file) if entries else None,
    "entriesWritten": len(entries),
    "recordedAt": recorded_at,
  }
  save_conversation_state(root, envelope, request_text, autonomous_turns)
  return {"when": {**handoffs, "always": True}, "payload": payload}


def main():
  if len(sys.argv) != 2 or sys.argv[1] not in {"read", "write"}:
    raise SystemExit("usage: persona_memory.py read|write")
  envelope = read_envelope()
  output = read_memory(envelope) if sys.argv[1] == "read" else write_memory(envelope)
  print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
  main()
