#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$repo_root/tmp"
work_dir="$(mktemp -d "$repo_root/tmp/riela-brand.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
/usr/bin/arch -arm64 "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
  -parse-as-library "$repo_root/Sources/RielaApp/RielaBrandImage.swift" \
  "$repo_root/scripts/RenderRielaBrandAssets.swift" -o "$work_dir/render"
"$work_dir/render" "$repo_root"
