#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
bundle_root="${repo_root}/.build/${configuration}/RielaApp.app"
contents_dir="${bundle_root}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
app_icon_source="${repo_root}/img/riela_icon.png"
app_icon_name="RielaAppIcon"
swift_bin="${RIELA_SWIFT:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift}"
developer_dir="${RIELA_SWIFT_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdkroot="${RIELA_SWIFT_SDKROOT:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
version="${RIELA_VERSION:-$(tr -d '[:space:]' < "${repo_root}/VERSION")}"
bundle_id="${RIELA_APP_BUNDLE_ID:-com.tacogips.riela.menubar}"
short_version="${version%%[-+]*}"

validate_version() {
  local value
  value="$1"

  if [[ "$value" == *..* || ! "$value" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$ ]]; then
    printf 'unsafe RielaApp version: %s\n' "$value" >&2
    printf 'expected archive-safe semver-like value without path separators or parent traversal\n' >&2
    return 1
  fi
}

validate_bundle_id() {
  local value part
  local -a parts
  value="$1"

  if [[ "$value" != *.* ]]; then
    printf 'unsafe RielaApp bundle identifier: %s\n' "$value" >&2
    printf 'expected reverse-DNS identifier using letters, numbers, dots, or hyphens\n' >&2
    return 1
  fi
  IFS='.' read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    if [[ ! "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]; then
      printf 'unsafe RielaApp bundle identifier: %s\n' "$value" >&2
      printf 'expected reverse-DNS identifier using letters, numbers, dots, or hyphens\n' >&2
      return 1
    fi
  done
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    return 1
  fi
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

validate_version "$version"
validate_bundle_id "$bundle_id"

cd "${repo_root}"
DEVELOPER_DIR="${developer_dir}" SDKROOT="${sdkroot}" \
  "${swift_bin}" build -c "${configuration}" --product RielaApp

rm -rf "${bundle_root}"
mkdir -p "${macos_dir}" "${resources_dir}"
cp ".build/${configuration}/RielaApp" "${macos_dir}/RielaApp"
write_app_icon "${app_icon_source}" "${resources_dir}" "${app_icon_name}"

cat > "${contents_dir}/Info.plist" <<PLIST
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
  <string>${app_icon_name}</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_id}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>RielaApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${short_version}</string>
  <key>CFBundleVersion</key>
  <string>${short_version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "${bundle_root}"
