#!/usr/bin/env sh

set -eu

MODE="${1:-}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TMP_ROOT="${REPO_ROOT}/tmp/session-sqlite-persistence-riela/codex-review"
mkdir -p "$TMP_ROOT"
OUT_FILE="$(mktemp "${TMP_ROOT}/${MODE}.XXXXXX.jsonl")"

extract_latest_review_json() {
  PREFIX="$1"
  FILE="$(ls -t "$TMP_ROOT"/"$PREFIX".*.jsonl 2>/dev/null | head -1 || true)"
  if [ -z "$FILE" ]; then
    printf '{"accepted":null,"missing":"%s review has not run"}\n' "$PREFIX"
    return
  fi
  TEXT="$(jq -rs -r '[.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | last // empty' "$FILE")"
  if [ -z "$TEXT" ]; then
    printf '{"accepted":null,"missing":"%s review did not produce an agent_message"}\n' "$PREFIX"
    return
  fi
  case "$TEXT" in
    '```'*)
      JSON_TEXT="$(printf '%s\n' "$TEXT" | sed '1d;$d')"
      ;;
    *)
      JSON_TEXT="$TEXT"
      ;;
  esac
  if ! printf '%s\n' "$JSON_TEXT" | jq -c .; then
    printf '{"accepted":null,"parseFailed":"%s review output was not JSON"}\n' "$PREFIX"
  fi
}

case "$MODE" in
  design)
    PROMPT='Adversarially review the current Riela session persistence design from the repository state and diff. Do not modify files. Return one JSON object only with keys: accepted, findings, designDecisions, requiredChanges. User intent: memory is already SQLite, and session persistence should also be SQLite by default; normal workflow run/event serve/session commands/viewer/resume/rerun must not depend on <sessionId>.json or runtime-records/<sessionId>/runtime-snapshot.json. JSON should remain only for explicit debug export or artifact output. Review whether the design should keep workflow_messages in runtime-message-log.sqlite or merge session/snapshot tables into the same database, how to preserve WorkflowSession, workflowName, resolution, mockScenarioPath, rootOutput, diagnostics, and workflowMessages, how to handle existing JSON backcompat when user said backcompat is unnecessary, how to avoid stale JSON files, how session list/load/status/progress/viewer should query SQLite, and how tests can prove no default JSON is created.'
    ;;
  implementation)
    PROMPT='Adversarially review the current Riela implementation from the repository state and diff for the session persistence SQLite migration. Do not modify files. Return one JSON object only with keys: accepted, needsRevision, findings, missingRequirements, verificationRecommendations. Prioritize: any remaining CLIWorkflowSessionStore JSON writes/reads in normal paths, FileWorkflowRuntimePersistenceStore runtime-snapshot.json writes in normal paths, session commands/viewer/resolve/resume/rerun still reading JSON only, runtime-message-log.sqlite compatibility, schema correctness and migrations, atomic writes/transactions, JSON export/artifact paths being explicit only, tests that assert no <sessionId>.json and no runtime-snapshot.json are produced by default, and preservation of unrelated memory SQLite behavior. Treat unrelated dirty files outside session/runtime persistence and tests as out of scope.'
    ;;
  summary)
    if ! command -v jq >/dev/null 2>&1; then
      printf 'jq is required to summarize codex JSONL output\n' >&2
      exit 127
    fi
    DESIGN_JSON="$(extract_latest_review_json design)"
    IMPLEMENTATION_JSON="$(extract_latest_review_json implementation)"
    jq -cn \
      --argjson design "$DESIGN_JSON" \
      --argjson implementation "$IMPLEMENTATION_JSON" \
      '{
        status: "reviewed",
        designAccepted: $design.accepted,
        implementationAccepted: $implementation.accepted,
        implementationNeedsRevision: $implementation.needsRevision,
        design: $design,
        implementation: $implementation
      }'
    exit 0
    ;;
  *)
    printf 'unsupported review mode: %s\n' "$MODE" >&2
    exit 2
    ;;
esac

cd "$REPO_ROOT"
codex exec --json --model gpt-5.4-mini -- "$PROMPT" </dev/null >"$OUT_FILE"

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq is required to parse codex JSONL output\n' >&2
  exit 127
fi

TEXT="$(jq -rs -r '[.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text] | last // empty' "$OUT_FILE")"
if [ -z "$TEXT" ]; then
  printf 'codex output did not contain an agent_message\n' >&2
  exit 1
fi

case "$TEXT" in
  '```'*)
    JSON_TEXT="$(printf '%s\n' "$TEXT" | sed '1d;$d')"
    ;;
  *)
    JSON_TEXT="$TEXT"
    ;;
esac

printf '%s\n' "$JSON_TEXT" | jq -c .
