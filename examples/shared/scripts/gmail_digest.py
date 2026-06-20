#!/usr/bin/env python3
import datetime
import email.utils
import json
import os
from pathlib import Path
import sys


DEFAULT_STATE_FILE = ".riela-data/gmail-latest-mail-digest-telegram/state.json"
DEFAULT_MESSAGE_FILE_ROOT = ".riela-data/gmail-latest-mail-digest-telegram/messages"
DEFAULT_ACCOUNT_ID = "gmail"
DEFAULT_GMAIL_QUERY = "in:inbox"
MAX_MESSAGE_LIMIT = 10
MAX_RETAINED_IDS = 500
PRIVATE_RELATIVE_PREFIXES = (
  ".riela-data/",
  ".riela-artifact/",
  ".riela-artifacts/",
  ".private/",
  "tmp/",
  "temp/",
)
PRIVATE_ABSOLUTE_PREFIXES = ("/tmp/", "/var/tmp/", "/var/folders/")


def read_envelope():
  return json.load(sys.stdin)


def is_object(value):
  return isinstance(value, dict)


def resolved_input(envelope):
  value = envelope.get("input")
  return value if is_object(value) else envelope


def workflow_input(envelope):
  variables = envelope.get("variables")
  if is_object(variables):
    candidate = variables.get("workflowInput")
    if is_object(candidate):
      return candidate
  runtime = envelope.get("runtimeVariables")
  if is_object(runtime):
    candidate = runtime.get("workflowInput")
    if is_object(candidate):
      return candidate
  return {}


def upstream_payloads(envelope):
  source = resolved_input(envelope)
  payloads = []
  upstream = source.get("upstream")
  if isinstance(upstream, list):
    for entry in upstream:
      payload = entry.get("output", {}).get("payload") if is_object(entry) else None
      if is_object(payload):
        payloads.append(payload)
  latest_outputs = source.get("latestOutputs")
  if isinstance(latest_outputs, list):
    for entry in latest_outputs:
      payload = entry.get("payload") if is_object(entry) else None
      if is_object(payload):
        payloads.append(payload)
  return payloads


def utc_now():
  return datetime.datetime.now(datetime.timezone.utc)


def isoformat(value):
  return value.isoformat().replace("+00:00", "Z")


def assert_private_runtime_path(file_path):
  resolved = Path(file_path).resolve()
  try:
    normalized = resolved.relative_to(Path.cwd().resolve()).as_posix()
  except ValueError:
    normalized = ""
  allowed = normalized.startswith(PRIVATE_RELATIVE_PREFIXES) or str(resolved).startswith(PRIVATE_ABSOLUTE_PREFIXES)
  if not allowed:
    raise ValueError(f"RIELA_GMAIL_DIGEST_STATE_FILE must point to an ignored/private runtime path, got {file_path}")


def assert_private_runtime_directory(directory_path, label):
  resolved = Path(directory_path).resolve()
  try:
    normalized = resolved.relative_to(Path.cwd().resolve()).as_posix()
  except ValueError:
    normalized = ""
  allowed = normalized.startswith(PRIVATE_RELATIVE_PREFIXES) or str(resolved).startswith(PRIVATE_ABSOLUTE_PREFIXES)
  if not allowed:
    raise ValueError(f"{label} must point to an ignored/private runtime path, got {directory_path}")


def text_from_input_or_env(envelope, key, env_name, fallback):
  candidate = workflow_input(envelope).get(key)
  if isinstance(candidate, str) and candidate.strip():
    return candidate.strip()
  raw = os.environ.get(env_name)
  return raw.strip() if isinstance(raw, str) and raw.strip() else fallback


def max_messages_from_input_or_env(envelope):
  candidate = workflow_input(envelope).get("maxMessages")
  raw = candidate if candidate not in (None, "") else os.environ.get("RIELA_GMAIL_MAX_MESSAGES")
  if raw in (None, ""):
    return MAX_MESSAGE_LIMIT
  try:
    value = int(raw)
  except (TypeError, ValueError) as error:
    raise ValueError("maxMessages/RIELA_GMAIL_MAX_MESSAGES must be a positive integer") from error
  if value <= 0:
    raise ValueError("maxMessages/RIELA_GMAIL_MAX_MESSAGES must be a positive integer")
  return min(value, MAX_MESSAGE_LIMIT)


def state_file_from_env_or_input(envelope):
  configured = workflow_input(envelope).get("stateFile")
  if isinstance(configured, str) and configured.strip():
    return configured.strip()
  return os.environ.get("RIELA_GMAIL_DIGEST_STATE_FILE") or DEFAULT_STATE_FILE


def message_file_root_from_env_or_input(envelope):
  configured = workflow_input(envelope).get("messageFileRoot")
  if isinstance(configured, str) and configured.strip():
    return configured.strip()
  return os.environ.get("RIELA_GMAIL_MESSAGE_FILE_ROOT") or DEFAULT_MESSAGE_FILE_ROOT


def read_state_file(file_path):
  path = Path(file_path)
  if not path.exists():
    return {}
  return json.loads(path.read_text(encoding="utf-8"))


def read_state(envelope):
  state_file = state_file_from_env_or_input(envelope)
  message_file_root = message_file_root_from_env_or_input(envelope)
  assert_private_runtime_path(state_file)
  assert_private_runtime_directory(message_file_root, "RIELA_GMAIL_MESSAGE_FILE_ROOT")
  state = read_state_file(state_file)
  known_ids = state.get("seenMessageIds") if isinstance(state.get("seenMessageIds"), list) else []
  known_ids = [value for value in known_ids if isinstance(value, str) and value]
  return {
    "when": {"always": True},
    "payload": {
      "stateFile": state_file,
      "messageFileRoot": message_file_root,
      "accountId": text_from_input_or_env(envelope, "accountId", "RIELA_GMAIL_ACCOUNT_ID", DEFAULT_ACCOUNT_ID),
      "gmailSearchQuery": text_from_input_or_env(envelope, "gmailSearchQuery", "RIELA_GMAIL_SEARCH_QUERY", DEFAULT_GMAIL_QUERY),
      "maxMessages": max_messages_from_input_or_env(envelope),
      "knownMessageIds": known_ids,
      "lastFetchedMessageId": state.get("lastFetchedMessageId") if isinstance(state.get("lastFetchedMessageId"), str) else "",
      "requestedAt": isoformat(utc_now()),
      "previousState": state,
    },
  }


def compact_text(value, fallback=""):
  if isinstance(value, str) and value.strip():
    return " ".join(value.strip().split())
  return fallback


def display_address(value):
  if isinstance(value, str):
    return compact_text(value)
  if is_object(value):
    name = compact_text(value.get("name"))
    address = compact_text(value.get("address") or value.get("email"))
    if name and address:
      return f"{name} <{address}>"
    return name or address
  return ""


def display_address_list(value):
  if isinstance(value, list):
    return [display_address(item) for item in value if display_address(item)]
  rendered = display_address(value)
  return [rendered] if rendered else []


def parse_datetime(value):
  if not isinstance(value, str) or not value.strip():
    return None
  raw = value.strip()
  if raw.isdigit():
    try:
      number = int(raw)
      if number > 10_000_000_000:
        number = number / 1000
      return datetime.datetime.fromtimestamp(number, tz=datetime.timezone.utc)
    except (OverflowError, ValueError, OSError):
      return None
  try:
    return datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
  except ValueError:
    parsed = email.utils.parsedate_to_datetime(raw)
    if parsed is not None and parsed.tzinfo is None:
      parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    return parsed


def date_sort_key(message):
  parsed = parse_datetime(message.get("receivedAt"))
  return parsed.timestamp() if parsed is not None else 0


def first_list(value, key_names):
  if isinstance(value, list):
    return value
  if not is_object(value):
    return []
  for key in key_names:
    candidate = value.get(key)
    if isinstance(candidate, list):
      return candidate
    if is_object(candidate):
      nested = first_list(candidate, key_names)
      if nested:
        return nested
  for candidate in value.values():
    nested = first_list(candidate, key_names)
    if nested:
      return nested
  return []


def gateway_object(payload):
  gateway = payload.get("mailGateway")
  if is_object(gateway):
    return gateway
  return {}


def gateway_messages(payloads):
  gateway_payload = next((payload for payload in payloads if is_object(payload.get("mailGateway"))), {})
  gateway = gateway_object(gateway_payload)
  data = gateway.get("data")
  if is_object(data) and is_object(data.get("data")):
    data = data["data"]
  search_root = data if data is not None else gateway
  return first_list(search_root, ("messages", "mailMessages", "gmailMessages", "nodes", "items"))


def safe_path_component(value):
  cleaned = "".join(ch if ch.isalnum() or ch in "-_." else "_" for ch in str(value))
  cleaned = cleaned.strip("._-")
  return cleaned or "item"


def write_message_payload_file(root, account_id, message_id, filename, content):
  assert_private_runtime_directory(root, "messageFileRoot")
  directory = Path(root) / safe_path_component(account_id) / safe_path_component(message_id)
  directory.mkdir(parents=True, exist_ok=True)
  path = directory / filename
  path.write_text(content, encoding="utf-8")
  return str(path)


def normalize_file_descriptor(value):
  if not is_object(value):
    return {}
  local_path = value.get("localPath") or value.get("path")
  download_key = value.get("downloadKey")
  if (not isinstance(local_path, str) or not local_path) and (not isinstance(download_key, str) or not download_key):
    return {}
  descriptor = {
    "kind": value.get("kind") if isinstance(value.get("kind"), str) else value.get("role") if isinstance(value.get("role"), str) else "FILE",
    "filename": value.get("filename") if isinstance(value.get("filename"), str) else Path(local_path).name if isinstance(local_path, str) else "file",
    "hasPayload": value.get("hasPayload") if isinstance(value.get("hasPayload"), bool) else bool(download_key or local_path),
    "mimeType": value.get("mimeType") if isinstance(value.get("mimeType"), str) else "",
    "sizeBytes": value.get("sizeBytes") if isinstance(value.get("sizeBytes"), (int, float)) else None,
    "materializationState": value.get("materializationState") if isinstance(value.get("materializationState"), str) else "CACHED",
  }
  if isinstance(download_key, str) and download_key:
    descriptor["downloadKey"] = download_key
  if isinstance(local_path, str) and local_path:
    descriptor["localPath"] = local_path
  return descriptor


def message_file_descriptors(message):
  files = []
  for key in ("files", "messageFiles", "bodyFiles", "temporaryFiles", "tempFiles", "attachments"):
    values = message.get(key)
    if isinstance(values, list):
      files.extend(normalize_file_descriptor(item) for item in values)
  return [item for item in files if item]


def normalize_message(message, account_id, message_file_root):
  if not is_object(message):
    return {}
  message_id = message.get("id") or message.get("messageId")
  if not isinstance(message_id, str) or not message_id:
    return {}
  date_value = (
    message.get("date")
    or message.get("internalDate")
    or message.get("receivedAt")
    or message.get("createdAt")
  )
  files = message_file_descriptors(message)
  text_body = message.get("textBody") or message.get("plainText") or message.get("bodyText") or message.get("body")
  if isinstance(text_body, str) and text_body:
    files.append({
      "kind": "BODY_TEXT",
      "filename": "body.txt",
      "mimeType": "text/plain",
      "sizeBytes": len(text_body.encode("utf-8")),
      "localPath": write_message_payload_file(message_file_root, account_id, message_id, "body.txt", text_body),
      "materializationState": "MATERIALIZED",
    })
  html_body = message.get("htmlBody")
  if isinstance(html_body, str) and html_body:
    files.append({
      "kind": "BODY_HTML",
      "filename": "body.html",
      "mimeType": "text/html",
      "sizeBytes": len(html_body.encode("utf-8")),
      "localPath": write_message_payload_file(message_file_root, account_id, message_id, "body.html", html_body),
      "materializationState": "MATERIALIZED",
    })
  return {
    "id": message_id,
    "threadId": message.get("threadId") if isinstance(message.get("threadId"), str) else "",
    "subject": compact_text(message.get("subject"), "(no subject)"),
    "snippet": compact_text(message.get("snippet")),
    "from": display_address(message.get("from") or message.get("sender")),
    "to": display_address_list(message.get("to")),
    "cc": display_address_list(message.get("cc")),
    "receivedAt": compact_text(date_value),
    "files": files,
  }


def latest_state_payload(payloads):
  return next(
    (
      payload
      for payload in payloads
      if isinstance(payload.get("knownMessageIds"), list)
      and isinstance(payload.get("maxMessages"), (int, float))
    ),
    {},
  )


def normalize_new_mail(envelope):
  payloads = upstream_payloads(envelope)
  state_payload = latest_state_payload(payloads)
  known = {value for value in state_payload.get("knownMessageIds", []) if isinstance(value, str) and value}
  max_messages = int(state_payload.get("maxMessages")) if isinstance(state_payload.get("maxMessages"), (int, float)) else MAX_MESSAGE_LIMIT
  account_id = state_payload.get("accountId", DEFAULT_ACCOUNT_ID)
  message_file_root = state_payload.get("messageFileRoot", DEFAULT_MESSAGE_FILE_ROOT)
  fetched = [normalize_message(message, account_id, message_file_root) for message in gateway_messages(payloads)]
  fetched = [message for message in fetched if message]
  fetched.sort(key=date_sort_key, reverse=True)
  fetched = fetched[:max_messages]
  selected = [message for message in fetched if message["id"] not in known]
  fetched_ids = [message["id"] for message in fetched]
  return {
    "when": {"has_new_mail": bool(selected)},
    "payload": {
      "stateFile": state_payload.get("stateFile", DEFAULT_STATE_FILE),
      "messageFileRoot": message_file_root,
      "accountId": state_payload.get("accountId", DEFAULT_ACCOUNT_ID),
      "gmailSearchQuery": state_payload.get("gmailSearchQuery", DEFAULT_GMAIL_QUERY),
      "maxMessages": max_messages,
      "fetchedMessageCount": len(fetched),
      "selectedMessageCount": len(selected),
      "fetchedMessageIds": fetched_ids,
      "selectedMessages": selected,
      "lastFetchedMessageId": fetched_ids[0] if fetched_ids else state_payload.get("lastFetchedMessageId", ""),
    },
  }


def digest_message_ids(item):
  ids = item.get("messageIds")
  if isinstance(ids, list):
    return [value for value in ids if isinstance(value, str) and value]
  value = item.get("id") or item.get("messageId")
  return [value] if isinstance(value, str) and value else []


def validate_summary(envelope):
  payloads = upstream_payloads(envelope)
  normalize_payload = next(
    (
      payload
      for payload in payloads
      if isinstance(payload.get("selectedMessages"), list)
      and isinstance(payload.get("fetchedMessageIds"), list)
    ),
    {},
  )
  summary_payload = next(
    (
      payload
      for payload in payloads
      if isinstance(payload.get("messageDigests"), list)
      or isinstance(payload.get("mailDigests"), list)
    ),
    {},
  )
  selected = [message for message in normalize_payload.get("selectedMessages", []) if is_object(message)]
  selected_by_id = {message["id"]: message for message in selected if isinstance(message.get("id"), str)}
  raw_digests = summary_payload.get("messageDigests")
  if not isinstance(raw_digests, list):
    raw_digests = summary_payload.get("mailDigests") if isinstance(summary_payload.get("mailDigests"), list) else []
  validated = []
  for item in [entry for entry in raw_digests if is_object(entry)]:
    ids = []
    messages = []
    invalid_count = 0
    for message_id in digest_message_ids(item):
      message = selected_by_id.get(message_id)
      if message is None:
        invalid_count += 1
      elif message_id not in ids:
        ids.append(message_id)
        messages.append(message)
    if not messages:
      continue
    first = messages[0]
    validated.append({
      "title": compact_text(item.get("title"), first.get("subject", "(no subject)")),
      "summary": compact_text(item.get("summary"), compact_text(first.get("snippet"))),
      "from": compact_text(item.get("from"), first.get("from", "")),
      "receivedAt": compact_text(item.get("receivedAt"), first.get("receivedAt", "")),
      "messageIds": ids,
      "invalidMessageIdCount": invalid_count,
    })
  reply_parts = []
  for index, item in enumerate(validated, start=1):
    received = f" / {item['receivedAt']}" if item["receivedAt"] else ""
    sender = f"From: {item['from']}{received}" if item["from"] or received else ""
    reply_parts.append(
      "\n".join(part for part in [
        f"{index}. {item['title']}",
        sender,
        item["summary"],
      ] if part)
    )
  fetched_ids = [value for value in normalize_payload.get("fetchedMessageIds", []) if isinstance(value, str) and value]
  should_send = bool(validated) and bool("\n".join(reply_parts).strip())
  return {
    "when": {"should_send_telegram": should_send},
    "payload": {
      "shouldSendTelegram": should_send,
      "replyText": "\n\n".join(reply_parts),
      "messageDigests": validated,
      "fetchedMessageIds": fetched_ids,
      "lastFetchedMessageId": normalize_payload.get("lastFetchedMessageId") if isinstance(normalize_payload.get("lastFetchedMessageId"), str) else "",
      "stateFile": normalize_payload.get("stateFile", DEFAULT_STATE_FILE),
      "selectedMessageCount": len(selected),
      "discardedCount": max(len(selected) - sum(len(item["messageIds"]) for item in validated), 0),
      "droppedInvalidDigestCount": len(raw_digests) - len(validated),
      "droppedInvalidMessageIdCount": sum(item["invalidMessageIdCount"] for item in validated),
    },
  }


def prior_known_ids(envelope):
  payloads = upstream_payloads(envelope)
  state_payload = latest_state_payload(payloads)
  return [value for value in state_payload.get("knownMessageIds", []) if isinstance(value, str) and value]


def ordered_unique(values):
  seen = set()
  output = []
  for value in values:
    if isinstance(value, str) and value and value not in seen:
      seen.add(value)
      output.append(value)
  return output


def persist_state(envelope):
  payload = next(reversed(upstream_payloads(envelope)), {})
  state_file = payload.get("stateFile") if isinstance(payload.get("stateFile"), str) and payload.get("stateFile") else state_file_from_env_or_input(envelope)
  assert_private_runtime_path(state_file)
  fetched_ids = [value for value in payload.get("fetchedMessageIds", []) if isinstance(value, str) and value]
  retained_ids = ordered_unique(fetched_ids + prior_known_ids(envelope))[:MAX_RETAINED_IDS]
  if fetched_ids:
    path = Path(state_file)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
      json.dumps(
        {
          "lastFetchedMessageId": fetched_ids[0],
          "seenMessageIds": retained_ids,
          "updatedAt": isoformat(utc_now()),
          "retainedMessageIdCount": len(retained_ids),
          "latestFetchedMessageIdCount": len(fetched_ids),
        },
        indent=2,
      )
      + "\n",
      encoding="utf-8",
    )
  reply_text = payload.get("replyText") if isinstance(payload.get("replyText"), str) else ""
  should_send = payload.get("shouldSendTelegram") is True and bool(reply_text.strip())
  return {
    "when": {"should_send_telegram": should_send},
    "payload": {
      "shouldSendTelegram": should_send,
      "replyText": reply_text,
      "stateFile": state_file,
      "persisted": bool(fetched_ids),
      "fetchedMessageIds": fetched_ids,
      "lastFetchedMessageId": fetched_ids[0] if fetched_ids else payload.get("lastFetchedMessageId", ""),
      "messageDigests": payload.get("messageDigests") if isinstance(payload.get("messageDigests"), list) else [],
    },
  }


def no_mail_output(envelope):
  payload = next(reversed(upstream_payloads(envelope)), {})
  return {
    "when": {"always": True},
    "payload": {
      "status": "no_new_mail_digest",
      "shouldSendTelegram": False,
      "replyText": "",
      "stateFile": payload.get("stateFile") if isinstance(payload.get("stateFile"), str) else "",
      "persisted": payload.get("persisted") is True,
      "fetchedMessageIds": payload.get("fetchedMessageIds") if isinstance(payload.get("fetchedMessageIds"), list) else [],
      "lastFetchedMessageId": payload.get("lastFetchedMessageId") if isinstance(payload.get("lastFetchedMessageId"), str) else "",
    },
  }


MODES = {
  "read-state": read_state,
  "normalize-new-mail": normalize_new_mail,
  "validate-summary-output": validate_summary,
  "persist-state": persist_state,
  "no-mail-output": no_mail_output,
}


def main():
  if len(sys.argv) != 2 or sys.argv[1] not in MODES:
    raise SystemExit("usage: gmail_digest.py " + "|".join(sorted(MODES)))
  output = MODES[sys.argv[1]](read_envelope())
  print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
  main()
