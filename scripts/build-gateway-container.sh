#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
gateway=${1:?Usage: build-gateway-container.sh x|gmail [runtime] [build options]}
case "$gateway" in x|gmail) ;; *) echo "Expected x or gmail" >&2; exit 1 ;; esac
runtime=${2:-${RIELA_CONTAINER_RUNTIME:-auto}}
if [ "$#" -gt 2 ]; then shift 2; else set --; fi
if [ "$runtime" = auto ]; then
  if [ "$(uname -s)" = Darwin ] && command -v container >/dev/null 2>&1; then runtime=container
  elif command -v docker >/dev/null 2>&1; then runtime=docker
  elif command -v podman >/dev/null 2>&1; then runtime=podman
  else echo "No container runtime found" >&2; exit 1
  fi
fi
if [ "$#" -eq 0 ] && [ "$(basename "$runtime")" = container ]; then set -- --cpus 4 --memory 4G; fi
mkdir -p "$repo_root/tmp"
build_context=$(mktemp -d "$repo_root/tmp/gateway-container.XXXXXX")
trap 'rm -rf "$build_context"' EXIT HUP INT TERM
cp "$repo_root/containers/$gateway-gateway/Containerfile" "$build_context/Containerfile"
if [ "$gateway" = gmail ]; then
  cp "$repo_root/containers/gmail-gateway/entrypoint.sh" "$build_context/entrypoint.sh"
fi
cp "$repo_root/scripts/prepare-container-gateway-source.py" "$build_context/prepare-container-gateway-source.py"
cp "$repo_root/containers/gateway-support/guard.c" "$build_context/guard.c"
cp "$repo_root/scripts/collect-swift-runtime.sh" "$build_context/collect-swift-runtime.sh"
cp -R "$repo_root/scripts/container-gateway-support" "$build_context/container-gateway-support"
"$runtime" build -t "riela-$gateway-gateway:local" -f "$build_context/Containerfile" "$@" "$build_context"
