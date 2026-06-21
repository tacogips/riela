#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
bundle_root="${repo_root}/.build/${configuration}/RielaApp.app"
contents_dir="${bundle_root}/Contents"
macos_dir="${contents_dir}/MacOS"
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

validate_version "$version"
validate_bundle_id "$bundle_id"

cd "${repo_root}"
DEVELOPER_DIR="${developer_dir}" SDKROOT="${sdkroot}" \
  "${swift_bin}" build -c "${configuration}" --product RielaApp

rm -rf "${bundle_root}"
mkdir -p "${macos_dir}"
cp ".build/${configuration}/RielaApp" "${macos_dir}/RielaApp"

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
