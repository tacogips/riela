#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/build-homebrew-cask-release.sh [--dry-run] [target ...]

Targets:
  darwin-arm64  darwin-x64

Required environment for real builds:
  APPLE_SIGNING_IDENTITY  Developer ID Application identity for RielaApp and the CLI executable.
  APPLE_ID                Apple ID email for notarization.
  APPLE_PASSWORD          Apple app-specific password for notarization.
  APPLE_TEAM_ID           Apple Developer Team ID for notarization.

Optional environment:
  RIELA_VERSION             Override archive version used in archive names.
  RIELA_CASK_RELEASE_DIR    Output directory. Defaults to dist/homebrew-cask.
  RIELA_SWIFT               Swift executable. Defaults to Xcode's Swift toolchain.
  RIELA_SWIFT_DEVELOPER_DIR Defaults to /Applications/Xcode.app/Contents/Developer.
  RIELA_SWIFT_SDKROOT       Defaults to Xcode's macOS SDK path.
  RIELA_APP_BUNDLE_ID       Defaults to com.tacogips.riela.menubar.
  RIELA_NOTARYTOOL          Defaults to Xcode's notarytool.
  RIELA_STAPLER             Defaults to Xcode's stapler.

Examples:
  scripts/build-homebrew-cask-release.sh --dry-run darwin-arm64 darwin-x64
  kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
    scripts/build-homebrew-cask-release.sh darwin-arm64 darwin-x64

This builder stages signed, notarized, and stapled macOS .dmg artifacts for the
Homebrew Cask. Each DMG contains RielaApp.app and the riela CLI. It does not
publish release assets, mutate a tap, or push commits.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    return 1
  fi
}

require_env() {
  if [[ -z "${!1:-}" ]]; then
    printf 'missing required environment variable: %s\n' "$1" >&2
    return 1
  fi
}

detect_target() {
  local kernel arch
  kernel="$(uname -s)"
  arch="$(uname -m)"

  case "$kernel:$arch" in
    Darwin:arm64) printf '%s\n' "darwin-arm64" ;;
    Darwin:x86_64) printf '%s\n' "darwin-x64" ;;
    *)
      printf 'unsupported Swift cask host platform: %s/%s\n' "$kernel" "$arch" >&2
      return 1
      ;;
  esac
}

validate_target() {
  case "$1" in
    darwin-arm64 | darwin-x64) ;;
    *)
      printf 'unsupported Swift cask target: %s\n' "$1" >&2
      printf 'Homebrew Cask DMGs are macOS-only.\n' >&2
      usage >&2
      return 1
      ;;
  esac
}

validate_version() {
  local version
  version="$1"

  if [[ "$version" == *..* || ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$ ]]; then
    printf 'unsafe Swift cask version: %s\n' "$version" >&2
    printf 'expected archive-safe semver-like value without path separators or parent traversal\n' >&2
    return 1
  fi
}

validate_bundle_id() {
  local bundle_id part
  local -a parts
  bundle_id="$1"

  if [[ "$bundle_id" != *.* ]]; then
    printf 'unsafe RielaApp bundle identifier: %s\n' "$bundle_id" >&2
    printf 'expected reverse-DNS identifier using letters, numbers, dots, or hyphens\n' >&2
    return 1
  fi
  IFS='.' read -r -a parts <<< "$bundle_id"
  for part in "${parts[@]}"; do
    if [[ ! "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
      printf 'unsafe RielaApp bundle identifier: %s\n' "$bundle_id" >&2
      printf 'expected reverse-DNS identifier using letters, numbers, dots, or hyphens\n' >&2
      return 1
    fi
  done
}

absolute_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$repo_root" "$1" ;;
  esac
}

validate_release_dir() {
  local path part
  local -a parts
  path="$1"

  if [[ -z "$path" ]]; then
    printf 'unsafe Swift cask release directory: empty path\n' >&2
    return 1
  fi

  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    if [[ "$part" == "." || "$part" == ".." ]]; then
      printf 'unsafe Swift cask release directory: %s\n' "$path" >&2
      printf 'release directory must not contain . or .. path components\n' >&2
      return 1
    fi
  done
}

assert_child_path() {
  local root child
  root="${1%/}"
  child="$2"

  if [[ -z "$root" || "$root" == "/" || "$child" != "$root"/* ]]; then
    printf 'unsafe Swift cask path outside release directory: %s\n' "$child" >&2
    return 1
  fi
}

swift_triple_for_target() {
  case "$1" in
    darwin-arm64) printf '%s\n' "arm64-apple-macosx" ;;
    darwin-x64) printf '%s\n' "x86_64-apple-macosx" ;;
  esac
}

install_prefix_for_target() {
  case "$1" in
    darwin-arm64) printf '%s\n' "/opt/homebrew" ;;
    darwin-x64) printf '%s\n' "/usr/local" ;;
  esac
}

write_sha256() {
  local file dir base
  file="$1"
  dir="$(dirname "$file")"
  base="$(basename "$file")"

  if command -v shasum >/dev/null 2>&1; then
    ( cd "$dir" && shasum -a 256 "$base" )
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$dir" && sha256sum "$base" )
    return
  fi

  printf 'missing checksum tool: expected shasum or sha256sum\n' >&2
  return 1
}

package_version() {
  if [[ -n "${RIELA_VERSION:-}" ]]; then
    printf '%s\n' "$RIELA_VERSION"
    return
  fi

  tr -d '[:space:]' < "$repo_root/VERSION"
}

swift_release_bin_path() {
  local target product swift_bin developer_dir sdkroot triple
  target="$1"
  product="$2"
  swift_bin="${RIELA_SWIFT:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift}"
  developer_dir="${RIELA_SWIFT_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  sdkroot="${RIELA_SWIFT_SDKROOT:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
  triple="$(swift_triple_for_target "$target")"

  (
    cd "$repo_root"
    DEVELOPER_DIR="$developer_dir" SDKROOT="$sdkroot" \
      "$swift_bin" build -c release --product "$product" --triple "$triple" >/dev/null
    DEVELOPER_DIR="$developer_dir" SDKROOT="$sdkroot" \
      "$swift_bin" build -c release --product "$product" --triple "$triple" --show-bin-path
  )
}

assert_codesigning_identity() {
  local identity
  identity="$1"
  security find-identity -v -p codesigning | grep -F -- "$identity" >/dev/null
}

bundle_short_version() {
  printf '%s\n' "${1%%[-+]*}"
}

write_app_icon() {
  local icon_source resources_dir icon_name iconset_dir size scale output_size suffix
  icon_source="$1"
  resources_dir="$2"
  icon_name="$3"
  iconset_dir="$resources_dir/${icon_name}.iconset"

  if [[ ! -f "$icon_source" ]]; then
    printf 'missing RielaApp icon source: %s\n' "$icon_source" >&2
    return 1
  fi

  require_command sips
  require_command iconutil

  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"

  for size in 16 32 128 256 512; do
    for scale in 1 2; do
      output_size=$((size * scale))
      suffix=""
      if [[ "$scale" -eq 2 ]]; then
        suffix="@2x"
      fi
      sips -z "$output_size" "$output_size" "$icon_source" \
        --out "$iconset_dir/icon_${size}x${size}${suffix}.png" >/dev/null
    done
  done

  iconutil -c icns "$iconset_dir" -o "$resources_dir/${icon_name}.icns"
  rm -rf "$iconset_dir"
}

write_riela_app_bundle() {
  local bundle_root source_executable version bundle_id contents_dir macos_dir resources_dir app_icon_source app_icon_name
  bundle_root="$1"
  source_executable="$2"
  version="$3"
  bundle_id="${RIELA_APP_BUNDLE_ID:-com.tacogips.riela.menubar}"
  contents_dir="$bundle_root/Contents"
  macos_dir="$contents_dir/MacOS"
  resources_dir="$contents_dir/Resources"
  app_icon_source="$repo_root/img/riela_icon.png"
  app_icon_name="RielaAppIcon"

  rm -rf "$bundle_root"
  mkdir -p "$macos_dir" "$resources_dir"
  cp "$source_executable" "$macos_dir/RielaApp"
  chmod 0755 "$macos_dir/RielaApp"
  write_app_icon "$app_icon_source" "$resources_dir" "$app_icon_name"
  test -s "$repo_root/web/dist/index.html"
  mkdir -p "$resources_dir/Web"
  cp -R "$repo_root/web/dist/". "$resources_dir/Web/"

  cat > "$contents_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>RielaApp</string>
  <key>CFBundleExecutable</key>
  <string>RielaApp</string>
  <key>CFBundleIconFile</key>
  <string>$app_icon_name</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>RielaApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$(bundle_short_version "$version")</string>
  <key>CFBundleVersion</key>
  <string>$(bundle_short_version "$version")</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST
}

build_web_assets() {
  require_command bun
  (
    cd "$repo_root/web"
    bun install --frozen-lockfile
    bun run lint
    bun run typecheck
    bun run test
    bun run build
  )
  test -s "$repo_root/web/dist/index.html"
}

print_plan() {
  local version target release_dir work_dir dmg_path staged_binary staged_app triple install_prefix
  version="$1"
  target="$2"
  release_dir="$3"
  work_dir="$release_dir/work/riela-$version-$target"
  dmg_path="$release_dir/riela-$version-$target.dmg"
  staged_binary="$work_dir/riela"
  staged_app="$work_dir/RielaApp.app"
  triple="$(swift_triple_for_target "$target")"
  install_prefix="$(install_prefix_for_target "$target")"

  assert_child_path "$release_dir" "$work_dir"
  assert_child_path "$release_dir" "$dmg_path"

  printf 'Swift Homebrew Cask DMG plan\n'
  printf '  product: riela\n'
  printf '  app product: RielaApp\n'
  printf '  target: %s\n' "$target"
  printf '  swift triple: %s\n' "$triple"
  printf '  cask install prefix: %s\n' "$install_prefix"
  printf '  staged signed app: %s\n' "$staged_app"
  printf '  staged signed binary: %s\n' "$staged_binary"
  printf '  notarized DMG: %s\n' "$dmg_path"
  printf '  checksum: %s.sha256\n' "$dmg_path"
  printf '  required Apple env: APPLE_SIGNING_IDENTITY, APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID\n'
  printf '  publish side effects: false\n'
}

build_target() {
  local version target release_dir work_dir dmg_path staged_binary staged_app riela_bin_path app_bin_path notarytool stapler
  version="$1"
  target="$2"
  release_dir="$3"
  work_dir="$release_dir/work/riela-$version-$target"
  dmg_path="$release_dir/riela-$version-$target.dmg"
  staged_binary="$work_dir/riela"
  staged_app="$work_dir/RielaApp.app"
  notarytool="${RIELA_NOTARYTOOL:-/Applications/Xcode.app/Contents/Developer/usr/bin/notarytool}"
  stapler="${RIELA_STAPLER:-/Applications/Xcode.app/Contents/Developer/usr/bin/stapler}"

  assert_child_path "$release_dir" "$work_dir"
  assert_child_path "$release_dir" "$dmg_path"

  require_env APPLE_SIGNING_IDENTITY
  require_env APPLE_ID
  require_env APPLE_PASSWORD
  require_env APPLE_TEAM_ID
  require_command codesign
  require_command hdiutil
  require_command security
  require_command spctl
  test -x "$notarytool"
  test -x "$stapler"
  assert_codesigning_identity "$APPLE_SIGNING_IDENTITY"

  rm -rf "$work_dir" "$dmg_path" "$dmg_path.sha256"
  mkdir -p "$work_dir"

  riela_bin_path="$(swift_release_bin_path "$target" riela | tail -n 1)"
  cp "$riela_bin_path/riela" "$staged_binary"
  chmod 0755 "$staged_binary"
  app_bin_path="$(swift_release_bin_path "$target" RielaApp | tail -n 1)"
  write_riela_app_bundle "$staged_app" "$app_bin_path/RielaApp" "$version"

  codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$staged_binary"
  codesign --verify --strict --verbose=2 "$staged_binary"
  codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$staged_app"
  codesign --verify --deep --strict --verbose=2 "$staged_app"

  hdiutil create -quiet -fs HFS+ -format UDZO -volname "riela" -srcfolder "$work_dir" "$dmg_path"
  codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$dmg_path"
  codesign --verify --strict --verbose=2 "$dmg_path"
  "$notarytool" submit "$dmg_path" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  "$stapler" staple "$dmg_path"
  "$stapler" validate "$dmg_path"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
  write_sha256 "$dmg_path" > "$dmg_path.sha256"

  printf 'built %s\n' "$dmg_path"
  cat "$dmg_path.sha256"
}

main() {
  local dry_run
  dry_run=false

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return
  fi

  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
    shift
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'Homebrew Cask DMG builds must run on macOS.\n' >&2
    return 1
  fi

  local version release_dir
  version="$(package_version)"
  validate_version "$version"
  validate_bundle_id "${RIELA_APP_BUNDLE_ID:-com.tacogips.riela.menubar}"
  release_dir="$(absolute_path "${RIELA_CASK_RELEASE_DIR:-dist/homebrew-cask}")"
  validate_release_dir "$release_dir"

  local -a targets
  if [[ "$#" -eq 0 ]]; then
    targets=("$(detect_target)")
  else
    targets=("$@")
  fi

  local target
  if [[ "$dry_run" != true ]]; then
    build_web_assets
  fi
  for target in "${targets[@]}"; do
    validate_target "$target"
    if [[ "$dry_run" == true ]]; then
      print_plan "$version" "$target" "$release_dir"
    else
      mkdir -p "$release_dir"
      build_target "$version" "$target" "$release_dir"
    fi
  done

  printf '\nRender a cask after all platform DMGs exist:\n'
  printf '  scripts/render-homebrew-cask.sh %s\n' "$version"
}

main "$@"
