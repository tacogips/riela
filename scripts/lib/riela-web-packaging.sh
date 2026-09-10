#!/usr/bin/env bash
# Shared build/staging functions. Callers validate release versions and destinations.

riela_build_web_assets() {
  local packaging_repo="$1"
  command -v bun >/dev/null 2>&1 || { printf 'missing required command: bun\n' >&2; return 1; }
  (
    cd "$packaging_repo/web"
    bun install --frozen-lockfile
    bun run lint
    bun run typecheck
    bun run test
    bun run build
  )
  test -s "$packaging_repo/web/dist/index.html"
}

riela_build_desktop() {
  local packaging_repo="$1" configuration="$2" rust_target="${3:-}"
  local -a flags=(--locked --manifest-path "$packaging_repo/web/src-tauri/Cargo.toml")
  command -v cargo >/dev/null 2>&1 || { printf 'missing required command: cargo\n' >&2; return 1; }
  if [[ "$configuration" == release ]]; then flags+=(--release); fi
  if [[ -n "$rust_target" ]]; then flags+=(--target "$rust_target"); fi
  CARGO_TARGET_DIR="$packaging_repo/web/src-tauri/target" MACOSX_DEPLOYMENT_TARGET=14.0 cargo build "${flags[@]}"
}

riela_stage_web_assets() {
  local packaging_repo="$1" destination="$2"
  test -s "$packaging_repo/web/dist/index.html"
  mkdir -p "$destination"
  cp -R "$packaging_repo/web/dist/". "$destination/"
}

riela_stage_desktop_bundle() {
  local binary="$1" bundle_root="$2" version="$3"
  local short_version="${version%%[-+]*}" contents="$bundle_root/Contents"
  test -x "$binary"
  mkdir -p "$contents/MacOS"
  cp "$binary" "$contents/MacOS/riela-desktop"
  chmod 0755 "$contents/MacOS/riela-desktop"
  cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>riela-desktop</string>
<key>CFBundleIdentifier</key><string>com.tacogips.riela.desktop</string>
<key>CFBundleName</key><string>Riela</string>
<key>CFBundleDisplayName</key><string>Riela</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${short_version}</string>
<key>CFBundleVersion</key><string>${short_version}</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
}

riela_stage_swift_resources() (
  local bin_path="$1" destination="$2" resource
  shopt -s nullglob
  mkdir -p "$destination"
  for resource in "$bin_path"/*.bundle "$bin_path"/*.resources; do
    cp -R "$resource" "$destination/"
  done
)
