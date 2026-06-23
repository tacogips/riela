#!/usr/bin/env sh

set -eu

MODE="${1:-}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TMP_ROOT="${REPO_ROOT}/tmp/riela-today-review-improve-loop"
mkdir -p "$TMP_ROOT"

json_string() {
  jq -Rsa .
}

write_json_file() {
  OUTPUT_NAME="$1"
  shift
  "$@" >"${TMP_ROOT}/${OUTPUT_NAME}.json"
  cat "${TMP_ROOT}/${OUTPUT_NAME}.json"
}

review() {
  cd "$REPO_ROOT"
  FINDINGS="${TMP_ROOT}/findings.jsonl"
  CHECKS="${TMP_ROOT}/checks.jsonl"
  : >"$FINDINGS"
  : >"$CHECKS"

  add_check() {
    printf '{"name":%s,"status":%s,"evidence":%s}\n' \
      "$(printf '%s' "$1" | json_string)" \
      "$(printf '%s' "$2" | json_string)" \
      "$(printf '%s' "$3" | json_string)" >>"$CHECKS"
  }

  add_finding() {
    printf '{"severity":%s,"title":%s,"detail":%s}\n' \
      "$(printf '%s' "$1" | json_string)" \
      "$(printf '%s' "$2" | json_string)" \
      "$(printf '%s' "$3" | json_string)" >>"$FINDINGS"
  }

  memory_lines="$(wc -l < Packages/RielaMemory/Sources/RielaMemory/RielaMemory.swift | tr -d ' ')"
  if [ "$memory_lines" -lt 1000 ]; then
    add_check "RielaMemory.swift remains under 1000 lines after today's additions" "pass" "$memory_lines lines"
  else
    add_finding "medium" "RielaMemory.swift is still too large" "RielaMemory.swift has ${memory_lines} lines; split model/helper responsibilities further."
  fi

  SESSION_JSON_HITS="${TMP_ROOT}/session-json-hits.$$"
  if rg -n 'sessionFilePath|appendingPathComponent\("\\\\\(sessionId\)\.json"\)|cli-workflow-sessions\.sqlite' Sources/RielaCLI Sources/RielaCore Sources/RielaViewer >"$SESSION_JSON_HITS" 2>/dev/null; then
    add_finding "high" "Default session JSON or split session SQLite path remains" "$(cat "$SESSION_JSON_HITS")"
  else
    add_check "Default session persistence avoids <sessionId>.json and cli-workflow-sessions.sqlite" "pass" "No source hits in normal CLI/Core/Viewer paths."
  fi
  rm -f "$SESSION_JSON_HITS"

  REPAIR_HITS="${TMP_ROOT}/repair-hits.$$"
  if rg -n 'catch WorkflowRuntimePersistenceStoreError\.notFound \{' Sources/RielaCLI/SessionCommands.swift Sources/RielaCLI/ScopedParityCommands.swift >"$REPAIR_HITS" 2>/dev/null; then
    add_finding "medium" "Runtime snapshot repair fallback remains" "$(cat "$REPAIR_HITS")"
  else
    add_check "Missing runtime snapshots fail instead of synthetic repair" "pass" "No notFound repair catch remains in session/control-plane load paths."
  fi
  rm -f "$REPAIR_HITS"

  file_store_hits="$(rg -n 'FileWorkflowRuntimePersistenceStore' Sources/RielaCLI Sources/RielaCore Sources/RielaViewer || true)"
  FILE_STORE_HITS="${TMP_ROOT}/file-store-hits.$$"
  if printf '%s\n' "$file_store_hits" | rg -v 'WorkflowRuntimePersistenceSnapshot.swift|artifactRoot|artifactURL' >"$FILE_STORE_HITS" 2>/dev/null; then
    add_finding "high" "File runtime snapshot store is used outside explicit artifact paths" "$(cat "$FILE_STORE_HITS")"
  else
    add_check "FileWorkflowRuntimePersistenceStore is explicit artifact/debug only" "pass" "$file_store_hits"
  fi
  rm -f "$FILE_STORE_HITS"

  NONATOMIC_HITS="${TMP_ROOT}/nonatomic-hits.$$"
  if rg -n 'try CLIWorkflowSessionStore\(rootDirectory: [^)]+\)\.save\(PersistedCLIWorkflowSession' Sources/RielaCLI >"$NONATOMIC_HITS" 2>/dev/null; then
    add_finding "medium" "Potential non-atomic CLI session/runtime persistence call remains" "$(cat "$NONATOMIC_HITS")"
  else
    add_check "Normal CLI persistence call sites use combined session/runtime save" "pass" "No direct PersistedCLIWorkflowSession-only save call pattern in Sources/RielaCLI."
  fi
  rm -f "$NONATOMIC_HITS"

  LIMIT_HITS="${TMP_ROOT}/limit-hits.$$"
  if rg -n 'maximumMemoryTags = 10|maximumRelatedRecordIds = 10|maximumMemoryFiles = 10' Packages/RielaMemory/Sources/RielaMemory/SQLiteMemorySupport.swift >"$LIMIT_HITS" 2>/dev/null; then
    add_check "Memory tag/related/file limits are capped at 10" "pass" "$(cat "$LIMIT_HITS")"
  else
    add_finding "high" "Memory limits are not visibly capped at 10" "Expected maximumMemoryTags, maximumRelatedRecordIds, and maximumMemoryFiles constants set to 10."
  fi
  rm -f "$LIMIT_HITS"

  MEMORY_SCHEMA_HITS="${TMP_ROOT}/memory-schema-hits.$$"
  if rg -n 'memory_metadata|tags_json|related_record_ids_json|memory_files' Packages/RielaMemory/Sources/RielaMemory >"$MEMORY_SCHEMA_HITS" 2>/dev/null; then
    add_check "Memory metadata/tags/related/files schema paths exist" "pass" "$(cat "$MEMORY_SCHEMA_HITS")"
  else
    add_finding "high" "Memory schema additions are missing" "Expected memory metadata, tags, related ids, and file storage support."
  fi
  rm -f "$MEMORY_SCHEMA_HITS"

  findings_count="$(wc -l < "$FINDINGS" | tr -d ' ')"
  jq -cn \
    --argjson findings "[$(paste -sd, "$FINDINGS")]" \
    --argjson checks "[$(paste -sd, "$CHECKS")]" \
    --arg findingsCount "$findings_count" \
    '{
      accepted: ($findingsCount == "0"),
      findings: $findings,
      checkedInvariants: $checks,
      recommendations: (if $findingsCount == "0" then ["Run verification step and keep review workflow output as evidence."] else ["Fix findings, then rerun this workflow."] end)
    }' | tee "${TMP_ROOT}/review.json"
}

verify() {
  cd "$REPO_ROOT"
  LOG_DIR="${TMP_ROOT}/logs"
  SMOKE_ROOT="${TMP_ROOT}/session-smoke"
  mkdir -p "$LOG_DIR"
  rm -rf "$SMOKE_ROOT"
  mkdir -p "$SMOKE_ROOT"

  run_command() {
    COMMAND_NAME="$1"
    shift
    LOG_FILE="${LOG_DIR}/${COMMAND_NAME}.log"
    if "$@" >"$LOG_FILE" 2>&1; then
      printf '{"name":%s,"status":"pass","log":%s}\n' "$(printf '%s' "$COMMAND_NAME" | json_string)" "$(printf '%s' "$LOG_FILE" | json_string)"
    else
      printf '{"name":%s,"status":"fail","log":%s,"tail":%s}\n' \
        "$(printf '%s' "$COMMAND_NAME" | json_string)" \
        "$(printf '%s' "$LOG_FILE" | json_string)" \
        "$(tail -80 "$LOG_FILE" | json_string)"
    fi
  }

  COMMANDS="${TMP_ROOT}/commands.jsonl"
  : >"$COMMANDS"
  run_command "swift-build" direnv exec . swift build >>"$COMMANDS"
  run_command "memory-package-tests" direnv exec . sh -c 'cd Packages/RielaMemory && swift test' >>"$COMMANDS"
  run_command "session-runtime-tests" direnv exec . swift test --filter WorkflowCommandTests --filter SQLiteWorkflowMessageLogTests --filter WorkflowViewerTests --filter CLIWorkflowSessionResolutionTests >>"$COMMANDS"
  run_command "chat-example-regression-tests" direnv exec . swift test --filter RielaExampleParityTests --filter EventLiveServeTests --filter MemoryAddonFileTests --filter CommandParsingTests >>"$COMMANDS"

  SMOKE_LOG="${LOG_DIR}/session-sqlite-smoke.log"
  if direnv exec . .build/arm64-apple-macosx/debug/riela workflow run first-four-arithmetic-pipeline \
    --workflow-definition-dir "$REPO_ROOT/examples" \
    --mock-scenario "$REPO_ROOT/examples/first-four-arithmetic-pipeline/mock-scenario.json" \
    --session-store "$SMOKE_ROOT/sessions" \
    --output json >"$SMOKE_ROOT/run.json" 2>"$SMOKE_LOG"; then
    DB="$SMOKE_ROOT/sessions/runtime-records/runtime-message-log.sqlite"
    JSON_COUNT="$(find "$SMOKE_ROOT/sessions" -name '*.json' -print | wc -l | tr -d ' ')"
    TABLES="$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('cli_workflow_sessions','workflow_runtime_snapshots','workflow_messages') ORDER BY name;" | paste -sd, -)"
    COUNTS="$(sqlite3 "$DB" "SELECT count(*) FROM cli_workflow_sessions; SELECT count(*) FROM workflow_runtime_snapshots; SELECT count(*) FROM workflow_messages;" | paste -sd, -)"
    if [ "$JSON_COUNT" = "0" ] && [ "$TABLES" = "cli_workflow_sessions,workflow_messages,workflow_runtime_snapshots" ]; then
      printf '{"name":"session-sqlite-smoke","status":"pass","database":%s,"jsonFiles":0,"tables":%s,"counts":%s}\n' \
        "$(printf '%s' "$DB" | json_string)" \
        "$(printf '%s' "$TABLES" | json_string)" \
        "$(printf '%s' "$COUNTS" | json_string)" >>"$COMMANDS"
    else
      printf '{"name":"session-sqlite-smoke","status":"fail","database":%s,"jsonFiles":%s,"tables":%s,"counts":%s}\n' \
        "$(printf '%s' "$DB" | json_string)" \
        "$JSON_COUNT" \
        "$(printf '%s' "$TABLES" | json_string)" \
        "$(printf '%s' "$COUNTS" | json_string)" >>"$COMMANDS"
    fi
  else
    printf '{"name":"session-sqlite-smoke","status":"fail","log":%s,"tail":%s}\n' \
      "$(printf '%s' "$SMOKE_LOG" | json_string)" \
      "$(tail -80 "$SMOKE_LOG" | json_string)" >>"$COMMANDS"
  fi

  failures="$(jq -r 'select(.status != "pass") | .name' "$COMMANDS" | paste -sd, -)"
  jq -cn \
    --argjson commands "[$(paste -sd, "$COMMANDS")]" \
    --arg failures "$failures" \
    '{
      accepted: ($failures == ""),
      commands: $commands,
      failures: (if $failures == "" then [] else ($failures | split(",")) end),
      residualRisks: ["Full swift test is intentionally not run here because unrelated branch/gate tests are known to be environment-sensitive; run it separately before release."]
    }' | tee "${TMP_ROOT}/verify.json"
}

summary() {
  REVIEW_JSON="$(cat "${TMP_ROOT}/review.json" 2>/dev/null || printf '{"accepted":false,"findings":[{"severity":"high","title":"review missing","detail":"review step did not produce output"}]}')"
  VERIFY_JSON="$(cat "${TMP_ROOT}/verify.json" 2>/dev/null || printf '{"accepted":false,"failures":["verify missing"]}')"
  jq -cn \
    --argjson review "$REVIEW_JSON" \
    --argjson verify "$VERIFY_JSON" \
    '{
      accepted: ($review.accepted == true and $verify.accepted == true),
      reviewAccepted: $review.accepted,
      verificationAccepted: $verify.accepted,
      reviewFindings: ($review.findings // []),
      verificationFailures: ($verify.failures // []),
      review: $review,
      verification: $verify
    }'
}

case "$MODE" in
  review)
    write_json_file review review
    ;;
  verify)
    write_json_file verify verify
    ;;
  summary)
    summary
    ;;
  *)
    printf 'unsupported mode: %s\n' "$MODE" >&2
    exit 2
    ;;
esac
