# Expected results

From the repository root, use the built `riela` binary and a fresh scratch
directory for each walkthrough. Both agent steps use mock scenarios. The
routine is registered with its next run scheduled, and you run the triage
workflow manually with the same task to demonstrate the overview without
starting a scheduler.

```sh
mkdir -p tmp/bots-overview/example
demo=$(mktemp -d "$PWD/tmp/bots-overview/example/walkthrough.XXXXXX")
riela="$PWD/.build/debug/riela"
examples="$PWD/examples"
bundle="$examples/bot-routine-memory-upkeep"
export RIELA_SESSION_STORE="$demo/sessions"
export RIELA_ROUTINE_STORE="$demo/routines"
export RIELA_MEMORY_ROOT="$demo/memory"
export RIELA_WORKFLOW_HOME="$demo/workflows"
export RIELA_CREDENTIAL_DIR="$demo/credentials"
export XDG_STATE_HOME="$demo/state"
```

1. Create a bot. The ID is `triage-bot`.

   ```sh
   "$riela" bot create --name "Triage Bot" --backend codex-agent \
     --working-dir "$demo" --session-store "$RIELA_SESSION_STORE" --output json
   ```

2. Register an active daily routine for that bot.

   ```sh
   "$riela" routine create --name nightly-triage --task "Summarize reports for the next review." \
     --schedule '0 0 0 * * *' --timezone UTC --workflow bot-routine-memory-upkeep --bot triage-bot \
     --working-dir "$demo" --routine-store "$RIELA_ROUTINE_STORE" --event-root "$demo/events"
   ```

3. Run the routine workflow manually. The `triage` step publishes
   `summary: "Flagged two reports for the next review."` and
   `conditionMet: false`. The session completes and belongs to `triage-bot`.

   ```sh
   "$riela" workflow run bot-routine-memory-upkeep --workflow-definition-dir "$examples" \
     --mock-scenario "$bundle/mock-scenario.json" --bot triage-bot \
     --variables '{"workflowInput":{"task":"Summarize reports for the next review."}}' \
     --working-dir "$demo" --session-store "$RIELA_SESSION_STORE" --artifact-root "$demo/artifacts" --output json
   ```

4. Check the overview. It lists one bot with a last-activity timestamp and a
   last-result summary.

   ```sh
   "$riela" bot list --working-dir "$demo" --session-store "$RIELA_SESSION_STORE" --output json
   ```

5. Inspect the board. The completed session is under Closed with
   `activitySource: session`. The daily routine has a next run and appears
   once under Planned.

   ```sh
   "$riela" bot show triage-bot --working-dir "$demo" --session-store "$RIELA_SESSION_STORE" --output json
   ```

6. Seed riela memory. A fresh memory root gives the instruction ID 1 and the
   two notes IDs 2 and 3 in file order. The upkeep scenario uses those IDs.

   ```sh
   "$riela" bot memory edit triage-bot --file "$bundle/memory-seed.md" \
     --working-dir "$demo" --session-store "$RIELA_SESSION_STORE" --memory-root "$RIELA_MEMORY_ROOT"
   ```

7. Run upkeep now using the mock reply. The job succeeds and the runtime
   applies the consolidated Markdown.

   ```sh
   "$riela" bot job run triage-bot upkeep --force --mock-scenario "$bundle/upkeep-mock-scenario.json" \
     --working-dir "$demo" --session-store "$RIELA_SESSION_STORE" --output json
   ```

8. Check history and the current Markdown. History is newest first and shows
   `upkeep` followed by `cli`. The instruction is unchanged and one merged
   note remains.

   ```sh
   "$riela" bot memory history triage-bot --working-dir "$demo" \
     --session-store "$RIELA_SESSION_STORE" --memory-root "$RIELA_MEMORY_ROOT" --output json
   "$riela" bot memory show triage-bot --working-dir "$demo" \
     --session-store "$RIELA_SESSION_STORE" --memory-root "$RIELA_MEMORY_ROOT"
   ```

9. Undo the latest change and show memory again. All three original entries
   are restored.

   ```sh
   "$riela" bot memory undo triage-bot --working-dir "$demo" \
     --session-store "$RIELA_SESSION_STORE" --memory-root "$RIELA_MEMORY_ROOT"
   "$riela" bot memory show triage-bot --working-dir "$demo" \
     --session-store "$RIELA_SESSION_STORE" --memory-root "$RIELA_MEMORY_ROOT"
   ```
