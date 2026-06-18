#!/usr/bin/env python3
import datetime
import json
import os
from pathlib import Path
import sys


DEFAULT_STATE_FILE = ".riela-data/x-follower-ai-business-digest/state.json"
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


def resolved_input(envelope):
  value = envelope.get("input")
  return value if isinstance(value, dict) else envelope


def is_object(value):
  return isinstance(value, dict)


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
  for entry in source.get("upstream", []) if isinstance(source.get("upstream"), list) else []:
    payload = entry.get("output", {}).get("payload") if is_object(entry) else None
    if is_object(payload):
      payloads.append(payload)
  for entry in source.get("latestOutputs", []) if isinstance(source.get("latestOutputs"), list) else []:
    payload = entry.get("payload") if is_object(entry) else None
    if is_object(payload):
      payloads.append(payload)
  return payloads


def positive_int(name, fallback):
  raw = os.environ.get(name)
  if raw in (None, ""):
    return fallback
  try:
    value = int(raw)
  except ValueError as error:
    raise ValueError(f"{name} must be a positive integer") from error
  if value <= 0:
    raise ValueError(f"{name} must be a positive integer")
  return value


def assert_private_runtime_path(file_path):
  resolved = Path(file_path).resolve()
  try:
    normalized = resolved.relative_to(Path.cwd().resolve()).as_posix()
  except ValueError:
    normalized = ""
  allowed = normalized.startswith(PRIVATE_RELATIVE_PREFIXES) or str(resolved).startswith(PRIVATE_ABSOLUTE_PREFIXES)
  if not allowed:
    raise ValueError(f"RIELA_X_DIGEST_STATE_FILE must point to an ignored/private runtime path, got {file_path}")


def state_file_from_env_or_input(envelope):
  configured = workflow_input(envelope).get("stateFile")
  if isinstance(configured, str) and configured:
    return configured
  return os.environ.get("RIELA_X_DIGEST_STATE_FILE") or DEFAULT_STATE_FILE


def read_state_file(file_path):
  path = Path(file_path)
  if not path.exists():
    return {}
  return json.loads(path.read_text(encoding="utf-8"))


def utc_now():
  return datetime.datetime.now(datetime.timezone.utc)


def isoformat(value):
  return value.isoformat().replace("+00:00", "Z")


def parse_date(value):
  if not isinstance(value, str) or not value:
    return None
  try:
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
  except ValueError:
    return None


def numeric_post_id(value):
  return int(value) if isinstance(value, str) and value.isdigit() else None


def post_url(post):
  if isinstance(post.get("postUrl"), str) and post["postUrl"]:
    return post["postUrl"]
  author = post.get("author") if is_object(post.get("author")) else {}
  username = author.get("username", "") if isinstance(author.get("username"), str) else ""
  username = username.lstrip("@")
  return f"https://x.com/{username}/status/{post.get('id')}" if username and isinstance(post.get("id"), str) else ""


def author_url(post):
  if isinstance(post.get("authorUrl"), str) and post["authorUrl"]:
    return post["authorUrl"]
  author = post.get("author") if is_object(post.get("author")) else {}
  username = author.get("username", "") if isinstance(author.get("username"), str) else ""
  username = username.lstrip("@")
  return f"https://x.com/{username}" if username else ""


def read_state(envelope):
  state_file = state_file_from_env_or_input(envelope)
  assert_private_runtime_path(state_file)
  account_username = (
    workflow_input(envelope).get("accountUsername")
    if isinstance(workflow_input(envelope).get("accountUsername"), str)
    else None
  ) or os.environ.get("RIELA_X_DIGEST_ACCOUNT_USERNAME") or os.environ.get("X_GW_ACCOUNT_USERNAME") or "@tacogips"
  lookback_minutes = positive_int("RIELA_X_DIGEST_LOOKBACK_MINUTES", 60)
  max_posts = max(5, min(positive_int("RIELA_X_DIGEST_MAX_POSTS", 50), 50))
  state = read_state_file(state_file)
  since_id = state.get("lastPostId") if isinstance(state.get("lastPostId"), str) else ""
  now = utc_now()
  window_start = now - datetime.timedelta(minutes=lookback_minutes)
  return {
    "when": {"always": True},
    "payload": {
      "stateFile": state_file,
      "accountUsername": account_username,
      "accountUsernameBare": account_username.lstrip("@"),
      "lookbackMinutes": lookback_minutes,
      "maxPosts": max_posts,
      "sinceId": since_id,
      "windowStartIso": isoformat(window_start),
      "requestedAt": isoformat(now),
      "previousState": state,
    },
  }


def normalize_post(post):
  metrics = post.get("metrics") if is_object(post.get("metrics")) else {}
  author = post.get("author") if is_object(post.get("author")) else {}
  refs = post.get("referencedPosts") if isinstance(post.get("referencedPosts"), list) else []
  return {
    "id": post.get("id") if isinstance(post.get("id"), str) else "",
    "text": post.get("text") if isinstance(post.get("text"), str) else "",
    "createdAt": post.get("createdAt") if isinstance(post.get("createdAt"), str) else "",
    "author": {
      "username": author.get("username") if isinstance(author.get("username"), str) else "",
      "name": author.get("name") if isinstance(author.get("name"), str) else "",
    },
    "metrics": {
      "impressionCount": metrics.get("impressionCount") if isinstance(metrics.get("impressionCount"), (int, float)) else None,
      "likeCount": metrics.get("likeCount") if isinstance(metrics.get("likeCount"), (int, float)) else None,
      "replyCount": metrics.get("replyCount") if isinstance(metrics.get("replyCount"), (int, float)) else None,
      "repostCount": metrics.get("repostCount") if isinstance(metrics.get("repostCount"), (int, float)) else None,
      "quoteCount": metrics.get("quoteCount") if isinstance(metrics.get("quoteCount"), (int, float)) else None,
      "bookmarkCount": metrics.get("bookmarkCount") if isinstance(metrics.get("bookmarkCount"), (int, float)) else None,
    },
    "referencedPosts": [
      {
        "relation": ref.get("relation") if isinstance(ref.get("relation"), str) else "",
        "id": ref.get("id") if isinstance(ref.get("id"), str) else "",
        "text": ref.get("text") if isinstance(ref.get("text"), str) else "",
        "author": {
          "username": ref.get("author", {}).get("username") if is_object(ref.get("author")) and isinstance(ref["author"].get("username"), str) else "",
          "name": ref.get("author", {}).get("name") if is_object(ref.get("author")) and isinstance(ref["author"].get("name"), str) else "",
        },
      }
      for ref in refs
      if is_object(ref)
    ],
  }


def normalize_fetched_posts(envelope):
  payloads = upstream_payloads(envelope)
  cursor = next(
    (
      payload
      for payload in payloads
      if isinstance(payload.get("windowStartIso"), str)
      and isinstance(payload.get("requestedAt"), str)
      and isinstance(payload.get("maxPosts"), (int, float))
    ),
    {},
  )
  gateway_payload = next((payload for payload in payloads if is_object(payload.get("xGateway"))), {})
  gateway = gateway_payload.get("xGateway") if is_object(gateway_payload.get("xGateway")) else {}
  data = gateway.get("data", {}).get("data", {}) if is_object(gateway.get("data")) else {}
  timeline = data.get("followingTimeline") or data.get("homeTimeline") or {}
  raw_posts = timeline.get("posts") if isinstance(timeline.get("posts"), list) else []
  fetched_posts = [normalize_post(post) for post in raw_posts if is_object(post)]
  window_start = parse_date(cursor.get("windowStartIso"))
  window_end = parse_date(cursor.get("requestedAt")) or utc_now()
  since_id = cursor.get("sinceId") if isinstance(cursor.get("sinceId"), str) else ""
  since_numeric = numeric_post_id(since_id)
  max_posts = int(cursor.get("maxPosts")) if isinstance(cursor.get("maxPosts"), (int, float)) else 50
  selected = []
  for post in fetched_posts:
    created = parse_date(post.get("createdAt"))
    in_window = created is None or ((window_start is None or created >= window_start) and created <= window_end)
    post_id = numeric_post_id(post.get("id"))
    after_cursor = since_numeric is None or post_id is None or post_id > since_numeric
    if in_window and after_cursor:
      enriched = dict(post)
      enriched["postUrl"] = post_url(post)
      enriched["authorUrl"] = author_url(post)
      selected.append(enriched)
  selected.sort(key=lambda post: numeric_post_id(post.get("id")) or -1, reverse=True)
  fetched_ids = [post["id"] for post in fetched_posts if numeric_post_id(post.get("id")) is not None]
  fetched_ids.sort(key=int, reverse=True)
  return {
    "when": {"always": True},
    "payload": {
      "fetchWindow": {
        "startIso": cursor.get("windowStartIso", ""),
        "endIso": cursor.get("requestedAt", ""),
        "lookbackMinutes": cursor.get("lookbackMinutes", 60),
      },
      "sinceId": since_id,
      "maxPosts": max_posts,
      "fetchedPostCount": len(fetched_posts),
      "selectedPostCount": len(selected[:max_posts]),
      "maxFetchedPostId": fetched_ids[0] if fetched_ids else since_id,
      "pageInfo": timeline.get("pageInfo") if is_object(timeline.get("pageInfo")) else {},
      "selectedPosts": selected[:max_posts],
    },
  }


def clean_text(value, fallback):
  return " ".join(value.strip().split()) if isinstance(value, str) and value.strip() else fallback


def author_handle(post):
  author = post.get("author") if is_object(post.get("author")) else {}
  username = author.get("username") if isinstance(author.get("username"), str) else ""
  return f"@{username.lstrip('@')}" if username else "@unknown"


def source_post_ids(item):
  ids = item.get("sourcePostIds")
  if isinstance(ids, list):
    return [value for value in ids if isinstance(value, str) and value]
  return [item["id"]] if isinstance(item.get("id"), str) and item["id"] else []


def validate_summary(envelope):
  payloads = upstream_payloads(envelope)
  normalize_payload = next(
    (
      payload
      for payload in payloads
      if is_object(payload.get("fetchWindow"))
      and isinstance(payload.get("selectedPosts"), list)
      and isinstance(payload.get("maxFetchedPostId"), str)
    ),
    {},
  )
  summary_payload = next(
    (
      payload
      for payload in payloads
      if (isinstance(payload.get("topicDigests"), list) or isinstance(payload.get("filteredPosts"), list))
      and isinstance(payload.get("shouldSendTelegram"), bool)
    ),
    {},
  )
  selected_posts = [post for post in normalize_payload.get("selectedPosts", []) if is_object(post)]
  selected_by_id = {post["id"]: post for post in selected_posts if isinstance(post.get("id"), str) and post["id"]}
  topic_digests = summary_payload.get("topicDigests")
  if not isinstance(topic_digests, list):
    topic_digests = summary_payload.get("filteredPosts") if isinstance(summary_payload.get("filteredPosts"), list) else []
  validated = []
  for item in [entry for entry in topic_digests if is_object(entry)]:
    requested_ids = source_post_ids(item)
    posts = []
    seen = set()
    invalid_count = 0
    for post_id in requested_ids:
      post = selected_by_id.get(post_id)
      if post is None:
        invalid_count += 1
      elif post_id not in seen:
        seen.add(post_id)
        posts.append(post)
    if not posts:
      continue
    source_posts = sorted(
      [
        {
          "id": post["id"],
          "postUrl": post_url(post),
          "authorHandle": author_handle(post),
          "authorUrl": author_url(post),
          "viewCount": post.get("metrics", {}).get("impressionCount") if is_object(post.get("metrics")) else None,
        }
        for post in posts
      ],
      key=lambda post: post["viewCount"] if isinstance(post["viewCount"], (int, float)) else -1,
      reverse=True,
    )
    users = []
    seen_users = set()
    for post in posts:
      author = post.get("author") if is_object(post.get("author")) else {}
      key = author.get("username", "").lstrip("@").lower() if isinstance(author.get("username"), str) else ""
      if key and key not in seen_users:
        seen_users.add(key)
        users.append({"handle": author_handle(post), "url": author_url(post)})
    total_views = sum(post["viewCount"] for post in source_posts if isinstance(post["viewCount"], (int, float)))
    topic = {
      "topic": clean_text(item.get("topic"), "AI/business update"),
      "reason": clean_text(item.get("reason"), "AI/business relevant"),
      "totalViewCount": total_views,
      "postUserCount": len(users),
      "summary": clean_text(item.get("summary"), clean_text(posts[0].get("text"), "")),
      "userLinks": users[:3],
      "sourcePosts": [{key: value for key, value in post.items() if key != "authorHandle"} for post in source_posts[:3]],
      "sourcePostIds": [post["id"] for post in posts],
      "invalidSourcePostIdCount": invalid_count,
    }
    if isinstance(item.get("articleUrl"), str) and item["articleUrl"]:
      topic["articleUrl"] = item["articleUrl"]
    validated.append(topic)
  validated.sort(key=lambda topic: topic["totalViewCount"], reverse=True)
  reply_parts = []
  for index, topic in enumerate(validated, start=1):
    users = ", ".join(f"{user['handle']} {user['url']}" for user in topic["userLinks"])
    posts = " ".join(post["postUrl"] for post in topic["sourcePosts"] if post.get("postUrl"))
    article = f"\nArticle: {topic['articleUrl']}" if topic.get("articleUrl") else ""
    reply_parts.append(
      f"{index}. {topic['topic']} ({topic['totalViewCount']} views, {topic['postUserCount']} users)\n"
      f"{topic['summary']}\nUsers: {users}\nPosts: {posts}{article}"
    )
  max_fetched_post_id = normalize_payload.get("maxFetchedPostId")
  if not isinstance(max_fetched_post_id, str):
    max_fetched_post_id = summary_payload.get("maxFetchedPostId") if isinstance(summary_payload.get("maxFetchedPostId"), str) else ""
  selected_count = len(selected_posts)
  source_count = sum(len(topic["sourcePostIds"]) for topic in validated)
  discarded_count = (
    summary_payload.get("discardedCount") + (len(topic_digests) - len(validated))
    if isinstance(summary_payload.get("discardedCount"), (int, float))
    else selected_count - source_count
  )
  return {
    "when": {"should_send_telegram": bool(validated) and bool("".join(reply_parts).strip())},
    "payload": {
      "shouldSendTelegram": bool(validated),
      "maxFetchedPostId": max_fetched_post_id,
      "replyText": "\n".join(reply_parts),
      "topicDigests": validated,
      "filteredPosts": validated,
      "discardedCount": discarded_count,
      "droppedInvalidFilteredPostCount": len(topic_digests) - len(validated),
      "droppedInvalidSourcePostIdCount": sum(topic["invalidSourcePostIdCount"] for topic in validated),
    },
  }


def persist_state(envelope):
  payload = next(reversed(upstream_payloads(envelope)), {})
  state_file = state_file_from_env_or_input(envelope)
  assert_private_runtime_path(state_file)
  max_fetched_post_id = payload.get("maxFetchedPostId") if isinstance(payload.get("maxFetchedPostId"), str) else ""
  should_send = payload.get("shouldSendTelegram") is True or payload.get("hasDigest") is True
  reply_text = payload.get("replyText") if isinstance(payload.get("replyText"), str) else ""
  if max_fetched_post_id:
    path = Path(state_file)
    path.parent.mkdir(parents=True, exist_ok=True)
    retained_topics = payload.get("topicDigests") if isinstance(payload.get("topicDigests"), list) else payload.get("filteredPosts", [])
    retained_posts = payload.get("filteredPosts") if isinstance(payload.get("filteredPosts"), list) else []
    path.write_text(
      json.dumps(
        {
          "lastPostId": max_fetched_post_id,
          "updatedAt": isoformat(utc_now()),
          "retainedTopicCount": len(retained_topics) if isinstance(retained_topics, list) else 0,
          "retainedPostCount": len(retained_posts),
        },
        indent=2,
      )
      + "\n",
      encoding="utf-8",
    )
  return {
    "when": {"should_send_telegram": should_send and bool(reply_text.strip())},
    "payload": {
      "shouldSendTelegram": should_send,
      "replyText": reply_text,
      "maxFetchedPostId": max_fetched_post_id,
      "stateFile": state_file,
      "persisted": bool(max_fetched_post_id),
    },
  }


def no_digest_output(envelope):
  payload = next(reversed(upstream_payloads(envelope)), {})
  return {
    "when": {"always": True},
    "payload": {
      "status": "no_digest",
      "shouldSendTelegram": False,
      "replyText": "",
      "maxFetchedPostId": payload.get("maxFetchedPostId") if isinstance(payload.get("maxFetchedPostId"), str) else "",
      "stateFile": payload.get("stateFile") if isinstance(payload.get("stateFile"), str) else "",
      "persisted": payload.get("persisted") is True,
    },
  }


MODES = {
  "read-state": read_state,
  "normalize-fetched-posts": normalize_fetched_posts,
  "validate-summary-output": validate_summary,
  "persist-state": persist_state,
  "no-digest-output": no_digest_output,
}


def main():
  if len(sys.argv) != 2 or sys.argv[1] not in MODES:
    raise SystemExit("usage: x_digest.py " + "|".join(sorted(MODES)))
  output = MODES[sys.argv[1]](read_envelope())
  print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
  main()
