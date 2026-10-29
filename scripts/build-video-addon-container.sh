#!/usr/bin/env bash
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime=${1:-${RIELA_CONTAINER_RUNTIME:-auto}}
worker_image=${2:-riela-builtin-addons:local}
if [ "$#" -gt 2 ]; then shift 2; else set --; fi
allow_stale_base=false
build_args=()
for argument in "$@"; do
  if [ "$argument" = --allow-stale-base ]; then
    allow_stale_base=true
  else
    build_args+=("$argument")
  fi
done

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

current_revision=$(git -C "$repo_root" rev-parse HEAD)
base_revision=$("$runtime" image inspect "$worker_image" | python3 -c '
import json, sys
images = json.load(sys.stdin)
for image in images if isinstance(images, list) else [images]:
    config = image.get("Config", {}).get("Labels", {})
    if not config:
        for variant in image.get("variants", []):
            config = variant.get("config", {}).get("config", {}).get("Labels", {})
            if config:
                break
    revision = config.get("org.opencontainers.image.revision", "")
    if revision:
        print(revision)
        break
')
if [ "$base_revision" != "$current_revision" ] && [ "$allow_stale_base" != true ]; then
  echo "Base image '$worker_image' revision '${base_revision:-missing}' does not match checkout '$current_revision'. Rebuild base with scripts/build-builtin-addon-container.sh (or pass --allow-stale-base to override)." >&2
  exit 1
fi

if [ "${#build_args[@]}" -eq 0 ] && [ "$runtime_name" = container ]; then
  build_args=(--cpus 4 --memory 8G)
fi

"$runtime" build --build-arg "WORKER_IMAGE=$worker_image" \
  -t riela-video-addons:local -f "$repo_root/containers/video-addons/Containerfile" "${build_args[@]}" \
  "$repo_root/containers/video-addons"
