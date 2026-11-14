#!/usr/bin/env python3
"""Run authored two-step workflows for every CLI vendor through bubblewrap."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SCRIPT = r'''#!/bin/sh
set -eu
if [ "${1:-}" = --version ]; then echo vendor-fixture; exit 0; fi
[ "$(cat "$HOME/.vendor/auth")" = fixture-key ]
if cat "$FIXTURE_HOST_SOURCE" >/dev/null 2>&1; then exit 11; fi
if /bin/sh -c 'echo bad > "$HOME/.vendor/auth"' 2>/dev/null; then exit 12; fi
resumed=0
for argument in "$@"; do [ "$argument" != fixture-thread ] || resumed=1; done
if [ "$resumed" = 1 ]; then [ "$(cat "$HOME/session-state")" = saved ]; else echo saved > "$HOME/session-state"; fi
printf '%s|%s\n' "$HOME" "$resumed" >> "$FIXTURE_RECEIPT"
cat >/dev/null
case "$FIXTURE_VENDOR" in
  codex-agent)
    printf '%s\n' '{"type":"thread.started","thread_id":"fixture-thread"}' \
      '{"type":"item.completed","item":{"type":"agent_message","text":"linux-cli-fixture"}}' \
      '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}' ;;
  *) printf '%s\n' '{"type":"result","subtype":"success","result":"linux-cli-fixture","session_id":"fixture-thread","usage":{"input_tokens":1,"output_tokens":1}}' ;;
esac
'''


def main():
    root = Path(tempfile.mkdtemp(prefix="riela-linux-cli-"))
    try:
        home = root / "host-home"
        home.mkdir()
        environment = dict(os.environ, HOME=str(home), RIELA_SANDBOX_WORKER_EXECUTABLE="/opt/riela/riela")
        cases = [("codex-agent", "codexExecutable"), ("claude-code-agent", "claudeExecutable"),
                 ("cursor-cli-agent", "cursorExecutable")]
        for backend, variable in cases:
            case_root = root / backend
            workspace, tools, definition = case_root / "workspace", case_root / "tools", case_root / "definitions/gate"
            for directory in [workspace, tools, definition]:
                directory.mkdir(parents=True)
            auth = case_root / "auth"
            auth.write_text("fixture-key")
            executable = tools / "vendor"
            executable.write_text(SCRIPT)
            executable.chmod(0o755)
            receipt = workspace / "receipt"
            bindings = dict(FIXTURE_VENDOR=backend, FIXTURE_RECEIPT=str(receipt), FIXTURE_HOST_SOURCE=str(auth))
            node = dict(id="worker", executionBackend=backend, model="fixture-model", agentSandbox="workspace-write",
                        workingDirectory=str(workspace), promptTemplate="fixture", sessionPolicy=dict(mode="reuse"),
                        variables={variable: str(executable)}, agentEnvironment={key: dict(value=value) for key, value in bindings.items()})
            (definition / "node.json").write_text(json.dumps(node))
            workflow = dict(workflowId="gate", defaults=dict(maxLoopIterations=2, nodeTimeoutMs=30000), entryStepId="first",
                            nodes=[dict(id="worker", nodeFile="node.json")], steps=[
                                dict(id="first", nodeId="worker", transitions=[dict(toStepId="second")]),
                                dict(id="second", nodeId="worker", sessionPolicy=dict(mode="reuse", inheritFromStepId="first"))])
            (definition / "workflow.json").write_text(json.dumps(workflow))
            patch = dict(worker=dict(sandbox=dict(backend="bubblewrap", readPaths=[str(tools)],
                                                 credentials=[dict(source=str(auth), homePath=".vendor/auth")])))
            command = ["/opt/riela/riela", "workflow", "run", "gate", "--workflow-definition-dir", str(definition.parent),
                       "--working-dir", str(workspace), "--node-patch", json.dumps(patch),
                       "--session-store", str(case_root / "sessions"), "--artifact-root", str(case_root / "artifacts"), "--output", "json"]
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=90)
            assert result.returncode == 0, result.stdout + result.stderr
            lines = receipt.read_text().splitlines()
            assert len(lines) == 2, lines
            assert lines[0].endswith("|0") and lines[1].endswith("|1"), lines
            private_home = lines[0][:-2]
            assert private_home == lines[1][:-2], lines
            assert not Path(private_home).exists(), "private session HOME was not cleaned at workflow end"
            assert auth.read_text() == "fixture-key"
            print("linux-cli-workflow-ok", backend, flush=True)
        print("linux-cli-gate-passed", flush=True)
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
