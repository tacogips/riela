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
    PROMPT='Review the current Riela memory feature design from the repository diff. Return one JSON object only with keys: accepted, findings, designDecisions, requiredChanges. Check independent RielaMemory package, workflow/node memory declarations, workflow-id scoped save/load/search, JSONB payloads, one SQLite file per memory id, multiple regex match search, default registered-desc limit 30, LLM command guidance, node templates, and chat memory replacement. Treat unrelated Launch on Login changes as out of scope.'
    ;;
  implementation)
    PROMPT='Review the current Riela memory feature implementation from the repository diff. Return one JSON object only with keys: accepted, needsRevision, findings, missingRequirements, verificationRecommendations. Prioritize compile failures, schema/model mismatches, CLI bugs, SQLite JSONB persistence bugs, missing tests, missing save/load/search node templates, missing chat example migration, and whether LLM nodes can discover and safely use riela memory commands. Treat unrelated Launch on Login changes as out of scope.'
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
