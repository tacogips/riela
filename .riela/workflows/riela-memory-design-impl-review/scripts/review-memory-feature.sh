#!/usr/bin/env sh

set -eu

MODE="${1:-}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TMP_ROOT="${REPO_ROOT}/tmp/memory-feature-riela/codex-review"
mkdir -p "$TMP_ROOT"
OUT_FILE="$(mktemp "${TMP_ROOT}/${MODE}.XXXXXX.jsonl")"

case "$MODE" in
  design)
    PROMPT='Adversarially review the current Riela memory feature design from the repository diff. Do not modify files. Return one JSON object only with keys: accepted, findings, designDecisions, requiredChanges. Focus on whether the Python-script behavior has been generalized into Riela correctly: the built-in riela/chat-memory-raw-daily-summary add-on contract and naming, whether it is reusable beyond one example, whether memory metadata/dataSchema remains discoverable by workflow nodes, whether tags and related ids remain bounded and pageable, whether raw chat logs and daily summaries are correctly separated into different memory databases, and whether Telegram/Discord chat memory regression coverage proves memory still works. Also check independent RielaMemory package, workflow/node memory declarations, workflow-id scoped save/load/search/update, JSONB payloads, one SQLite file per memory id, default registered-desc limit 30, LLM command guidance, and chat memory replacement. Treat unrelated dirty files outside memory/add-on/example/test scope as out of scope.'
    ;;
  implementation)
    PROMPT='Adversarially review the current Riela memory feature implementation from the repository diff. Do not modify files. Return one JSON object only with keys: accepted, needsRevision, findings, missingRequirements, verificationRecommendations. Prioritize compile failures, schema/model mismatches, CLI parsing/output bugs, SQLite/JSONB persistence bugs, schema initialization races, memory update semantics, genericity and safety of riela/chat-memory-raw-daily-summary, whether metadata/dataSchema are preserved and discoverable, whether tags and related ids enforce uniqueness and maximum 10, whether unique values remain sorted/pageable, whether raw logs and daily summaries use distinct DB files, whether the example no longer depends on a Python script, and whether Telegram/Discord regression tests actually prove memory read/write behavior. Treat unrelated dirty files outside memory/add-on/example/test scope as out of scope.'
    ;;
  summary)
    printf '%s\n' '{"status":"reviewed","designAccepted":false,"implementationAccepted":false,"blockingFindings":["Read design-review and implementation-review payloads from the workflow inbox for details."],"nextImplementationActions":["Fix high and mid findings from prior review steps, then rerun verification."],"residualRisks":["Summary node intentionally avoids another model call to keep the Riela review loop deterministic."]}'
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
