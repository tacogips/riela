#!/usr/bin/env python3
"""Exercise every linked HTTP SDK inside the real bubblewrap Swift worker."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading


class ProviderFixture(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_arguments):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.requests.append((self.path, dict(self.headers)))
        if self.path == "/v1/agents":
            body = json.dumps(dict(id="fixture-session", result="linux-sdk-fixture")).encode()
            content_type = "application/json"
        else:
            content_type = "text/event-stream"
            if self.path == "/v1/responses":
                record = dict(type="response.output_text.delta", delta="linux-sdk-fixture")
            elif self.path == "/v1/messages":
                record = dict(type="content_block_delta", delta=dict(text="linux-sdk-fixture"))
            elif self.path.startswith("/v1/models/fixture-model:streamGenerateContent"):
                record = dict(candidates=[dict(content=dict(parts=[dict(text="linux-sdk-fixture")]))])
            else:
                self.send_error(404)
                return
            body = ("data: " + json.dumps(record) + "\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    root = Path(tempfile.mkdtemp(prefix="riela-linux-sdk-"))
    server = ThreadingHTTPServer(("127.0.0.1", 0), ProviderFixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        workspace = root / "workspace"
        workspace.mkdir()
        cases = [("openai", "OPENAI_API_KEY"), ("anthropic", "ANTHROPIC_API_KEY"),
                 ("gemini", "GEMINI_API_KEY"), ("cursor", "CURSOR_API_KEY")]
        for vendor, key in cases:
            request = dict(version=1, supervisorMode=False, input=dict(
                node=dict(id="sdk", executionBackend="official/" + vendor + "-sdk", model="fixture-model",
                          baseURL="http://127.0.0.1:" + str(server.server_port) + "/v1", apiKeyEnvironment=key),
                promptText="fixture", arguments={}, mergedVariables={}, agentEnvironment={}, executionIndex=1,
                executionIdentity=dict(workflowRunId="linux-run", workflowSessionId="linux-session", stepId=vendor)))
            request_path = workspace / "request.json"
            request_path.write_text(json.dumps(request) + "\n")
            command = ["/opt/riela/riela", "sandbox", "run", "--backend", "bubblewrap", "--allow-network",
                       "--working-dir", str(workspace), "--read-path", "/opt/riela", "--env", key,
                       "--", "/bin/sh", "-c", 'exec /opt/riela/riela __riela-node-worker < "$1"',
                       "worker", str(request_path)]
            environment = dict(os.environ, **{key: "fixture-only-key"})
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, result.stdout + result.stderr
            records = [json.loads(line) for line in result.stdout.splitlines()]
            terminal = records[-1]
            assert terminal["kind"] == "result", terminal
            assert terminal["output"]["payload"]["text"] == "linux-sdk-fixture", terminal
            assert any(record["kind"] == "event" for record in records), records
            print("linux-sdk-worker-ok", vendor, flush=True)
        assert len(ProviderFixture.requests) == 4
        for path, headers in ProviderFixture.requests:
            headers = {key.lower(): value for key, value in headers.items()}
            if path == "/v1/messages":
                assert headers["x-api-key"] == "fixture-only-key"
            elif path.startswith("/v1/models/"):
                assert "key=fixture-only-key" in path
            elif path == "/v1/agents":
                assert headers["authorization"] == "Basic " + base64.b64encode(b"fixture-only-key:").decode()
            else:
                assert headers["authorization"] == "Bearer fixture-only-key"
        print("linux-sdk-gate-passed", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
