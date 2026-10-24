#!/usr/bin/env python3
"""Check that container gateway source pins match Package.resolved.

Every `git remote add origin <url>` + `git fetch ... origin <revision>` pair in
containers/*/Containerfile must use the revision that Package.resolved pins for
the same package identity, so the worker image links the SDKs the host
validates against. `--crypto-version` arguments must match the resolved
swift-crypto version. Standard library only; safe to run with `python3 -I`.
"""

import argparse
import json
import re
import sys
from pathlib import Path

REMOTE = re.compile(r"git remote add origin (https://github\.com/[^\s/]+/([^\s/]+?)(?:\.git)?)(?=\s|&&|$)")
FETCH = re.compile(r"git fetch\b[^&;]*?\borigin\s+(\"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?\"?|[0-9a-f]{40})")
ARG = re.compile(r"^\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)=([0-9a-f]{40})\s*$")
CRYPTO = re.compile(r"--crypto-version\s+(\S+)")
SHA = re.compile(r"^[0-9a-f]{40}$")


def logical_lines(text: str) -> list[str]:
    lines, current = [], ""
    for raw in text.splitlines():
        if raw.rstrip().endswith("\\"):
            current += raw.rstrip()[:-1] + " "
        else:
            lines.append(current + raw)
            current = ""
    if current:
        lines.append(current)
    return lines


def resolved_pins(path: Path) -> dict[str, dict]:
    lock = json.loads(path.read_text())
    return {pin["identity"].lower(): pin.get("state", {}) for pin in lock.get("pins", [])}


def check(root: Path) -> tuple[list[str], list[str]]:
    pins = resolved_pins(root / "Package.resolved")
    checked, errors = [], []
    containerfiles = sorted((root / "containers").glob("*/Containerfile"))
    if not containerfiles:
        errors.append("no containers/*/Containerfile found")
    for containerfile in containerfiles:
        relative = containerfile.relative_to(root)
        lines = logical_lines(containerfile.read_text())
        args = {match.group(1): match.group(2) for line in lines if (match := ARG.match(line))}
        for number, line in enumerate(lines, start=1):
            for crypto in CRYPTO.findall(line):
                expected = pins.get("swift-crypto", {}).get("version")
                if crypto != expected:
                    errors.append(f"{relative}: --crypto-version {crypto} != Package.resolved swift-crypto {expected}")
                else:
                    checked.append(f"{relative}: swift-crypto {crypto}")
            remote = REMOTE.search(line)
            if not remote:
                continue
            identity = remote.group(2).lower()
            fetch = FETCH.search(line)
            if not fetch:
                errors.append(f"{relative} (logical line {number}): {identity} clone has no pinned git fetch revision")
                continue
            revision = fetch.group(1) if SHA.match(fetch.group(1)) else args.get(fetch.group(2) or "")
            if not revision:
                errors.append(f"{relative}: {identity} revision variable {fetch.group(2)} has no 40-hex ARG default")
                continue
            expected = pins.get(identity, {}).get("revision")
            if expected is None:
                errors.append(f"{relative}: {identity} is not pinned in Package.resolved")
            elif revision != expected:
                errors.append(f"{relative}: {identity} {revision} != Package.resolved {expected}")
            else:
                checked.append(f"{relative}: {identity} {revision}")
    if not checked and not errors:
        errors.append("no pinned gateway sources found in containers/*/Containerfile")
    return checked, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent,
                        help="repository root (default: the parent of this script's directory)")
    arguments = parser.parse_args()
    checked, errors = check(arguments.root.resolve())
    for line in checked:
        print(f"ok    {line}")
    for line in errors:
        print(f"error {line}", file=sys.stderr)
    if errors:
        print(f"container pin check failed: {len(errors)} mismatch(es)", file=sys.stderr)
        return 1
    print(f"container pin check passed: {len(checked)} pin(s) match Package.resolved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
