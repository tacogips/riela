#!/usr/bin/env python3
"""Run in a disposable Linux VM with riela, bubblewrap and Python installed.

Python is a verification-only dependency, not part of the Riela runtime image.
The VM must permit nested user/PID namespaces and proc mounts.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile

PROBE = r'''
import os, socket, subprocess, sys
from pathlib import Path
root, port, allowed = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "yes"
assert os.environ.get("FIXTURE_TOKEN") == "selected-only"
assert "SECRET_AMBIENT" not in os.environ
credential = Path.home() / ".vendor/auth"
assert credential.read_bytes() == b"fixture-key"
try:
    credential.write_text("mutated")
except OSError:
    pass
else:
    raise AssertionError("credential snapshot was writable")
for hidden in ["auth", "unshared"]:
    try:
        (Path(root) / hidden).read_text()
    except OSError:
        pass
    else:
        raise AssertionError("unshared host data was readable")
child = subprocess.run(["/bin/sh", "-c", 'cat "$1"', "probe", root + "/unshared"], capture_output=True)
assert child.returncode != 0, "child escaped the filesystem boundary"
connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
connection.settimeout(2)
try:
    connection.connect(("127.0.0.1", port))
except OSError:
    assert not allowed, "explicit IP egress was denied"
else:
    assert allowed, "default-denied network connected to host"
finally:
    connection.close()
for address in [root + "/unix.sock", "\0" + Path(root).name]:
    try:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(address)
    except OSError:
        pass
    else:
        raise AssertionError("host Unix IPC was accessible")
    finally:
        connection.close()
try:
    pair = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
except OSError:
    pass
else:
    for connection in pair:
        connection.close()
    raise AssertionError("reconnectable Unix datagram socketpair was allowed")
left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
left.send(b"ok")
assert right.recv(2) == b"ok"
left.close()
right.close()
nested = subprocess.run(["/usr/bin/bwrap", "--unshare-user", "--ro-bind", "/", "/", "--", "/bin/true"], capture_output=True)
assert nested.returncode != 0, "guest created another user namespace"
(Path.cwd() / "guest-result").write_text("isolated")
print("linux-sandbox-policy-ok", allowed)
'''


def main():
    root = Path(tempfile.mkdtemp(prefix="riela-linux-gate-"))
    try:
        workspace, tools = root / "workspace", root / "tools"
        workspace.mkdir()
        tools.mkdir()
        (root / "auth").write_bytes(b"fixture-key")
        (root / "unshared").write_text("host-only")
        (tools / "probe.py").write_text(PROBE)
        environment = dict(os.environ, FIXTURE_TOKEN="selected-only", SECRET_AMBIENT="must-not-leak")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener, \
                socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as unix_listener, \
                socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as abstract_listener:
            unix_listener.bind(str(root / "unix.sock"))
            unix_listener.listen(2)
            abstract_listener.bind("\0" + root.name)
            abstract_listener.listen(2)
            listener.bind(("127.0.0.1", 0))
            listener.listen(8)
            port = listener.getsockname()[1]
            for allowed in [False, True]:
                options = dict(backend="bubblewrap", networkPolicy="egress-allowed" if allowed else "denied",
                               readPaths=[str(tools)], environment=["FIXTURE_TOKEN"],
                               credentials=[dict(source=str(root / "auth"), homePath=".vendor/auth")])
                options_path = root / "options.json"
                options_path.write_text(json.dumps(options))
                command = ["/opt/riela/riela", "sandbox", "run", "--working-dir", str(workspace),
                           "--options", "@" + str(options_path), "--", "/usr/bin/python3", str(tools / "probe.py"),
                           str(root), str(port), "yes" if allowed else "no"]
                result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=30)
                assert result.returncode == 0, result.stdout + result.stderr
                assert "linux-sandbox-policy-ok" in result.stdout, result.stdout
                assert (root / "auth").read_bytes() == b"fixture-key"
                assert (workspace / "guest-result").read_text() == "isolated"
                print(result.stdout.strip(), flush=True)
        denied = subprocess.run(["/opt/riela/riela", "sandbox", "run", "--backend", "seatbelt", "--working-dir",
                                 str(workspace), "--", "/bin/touch", "must-not-exist"], capture_output=True, timeout=10)
        assert denied.returncode != 0
        assert not (workspace / "must-not-exist").exists(), "unsupported backend fell back to host execution"
        print("linux-boundary-gate-passed", flush=True)
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
