#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=${1:-${RIELA_CONTAINER_RUNTIME:-auto}}
image=${2:-riela-builtin-addons:local}
if [ "$#" -gt 2 ]; then shift 2; else set --; fi
riela_revision=$(git -C "$repo_root" rev-parse HEAD)
if [ -n "$(git -C "$repo_root" status --porcelain)" ]; then
  riela_revision="$riela_revision-dirty"
fi
riela_version=$(tr -d '[:space:]' < "$repo_root/VERSION")

if [ "$runtime" = auto ]; then
  if [ "$(uname -s)" = Darwin ] && command -v container >/dev/null 2>&1; then
    runtime=container
  elif command -v docker >/dev/null 2>&1; then
    runtime=docker
  elif command -v podman >/dev/null 2>&1; then
    runtime=podman
  else
    echo "No container runtime found. Run riela setup container or install Docker/Podman." >&2
    exit 1
  fi
fi

if [ "$#" -eq 0 ] && [ "$(basename "$runtime")" = container ]; then
  set -- --cpus 4 --memory 8G
fi

mkdir -p "$repo_root/tmp"
build_context=$(mktemp -d "$repo_root/tmp/builtin-addon-container.XXXXXX")
trap 'rm -rf "$build_context"' EXIT HUP INT TERM

tar -cf - --exclude=.build --exclude=.git --exclude=tmp -C "$repo_root" \
  Package.swift Package.resolved Packages Sources Tests Resources | tar -xf - -C "$build_context"
cp "$repo_root/containers/builtin-addons/Containerfile" "$build_context/Containerfile"
mkdir -p "$build_context/scripts"
cp "$repo_root/scripts/prepare-container-gateway-source.py" "$build_context/scripts/prepare-container-gateway-source.py"
cp "$repo_root/scripts/strip-macos-only-pins.swift" "$build_context/scripts/strip-macos-only-pins.swift"
cp "$repo_root/scripts/collect-swift-runtime.sh" "$build_context/scripts/collect-swift-runtime.sh"
cp -R "$repo_root/scripts/container-gateway-support" "$build_context/scripts/container-gateway-support"
"$runtime" build --build-arg "RIELA_REVISION=$riela_revision" --build-arg "RIELA_VERSION=$riela_version" \
  -t "$image" -f "$build_context/Containerfile" "$@" "$build_context"
