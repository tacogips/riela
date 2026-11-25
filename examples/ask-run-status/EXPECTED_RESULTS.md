# Expected results

Run from the repository root with `riela` on PATH and `jq` available.

```bash
mkdir -p "$PWD/tmp/ask-riela"
scratch="$(mktemp -d "$PWD/tmp/ask-riela/example.XXXXXX")"
export HOME="$scratch/home"
export RIELA_WORKFLOW_HOME="$scratch/workflows"
export RIELA_CREDENTIAL_DIR="$scratch/credentials"
export XDG_CONFIG_HOME="$scratch/config"
export XDG_DATA_HOME="$scratch/data"
mkdir -p "$HOME" "$RIELA_WORKFLOW_HOME" "$RIELA_CREDENTIAL_DIR"
riela workflow run ask-run-status \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/ask-run-status/mock-scenario.json \
  --session-store "$scratch/store" --artifact-root "$scratch/artifacts" \
  --output json > "$scratch/run.json"
session_id="$(jq -er '.session.sessionId' "$scratch/run.json")"
sed "s/__SESSION_ID__/$session_id/g" examples/ask-run-status/ask-script.json > "$scratch/ask-script.json"
RIELA_ASK_SCRIPTED_BACKEND="$scratch/ask-script.json" \
  riela ask --remote local --session-store "$scratch/store" \
  --session "$session_id" "what is the state of this run?"
```

The workflow completes with one step execution. Ask prints a `session_status`
tool line, `The run completed.`, a `Records:` entry for the session ID, and
the conversation ID. With `--output json`, the turn is `completed` and the
assistant message's `citations` contains that session ID.
