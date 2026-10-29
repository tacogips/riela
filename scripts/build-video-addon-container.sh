#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=${1:-${RIELA_CONTAINER_RUNTIME:-auto}}
worker_image=${2:-riela-builtin-addons:local}
if [ "$#" -gt 2 ]; then shift 2; else set --; fi

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

runtime_name=$(basename "$runtime")
if ! "$runtime" image inspect "$worker_image" >/dev/null 2>&1; then
  echo "Base image '$worker_image' is missing. Run scripts/build-builtin-addon-container.sh first." >&2
  exit 1
fi

if [ "$#" -eq 0 ] && [ "$runtime_name" = container ]; then
  set -- --cpus 4 --memory 8G
fi

"$runtime" build --build-arg "WORKER_IMAGE=$worker_image" \
  -t riela-video-addons:local -f "$repo_root/containers/video-addons/Containerfile" "$@" "$repo_root"
