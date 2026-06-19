#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
bundle_root="${repo_root}/.build/${configuration}/RielaApp.app"
contents_dir="${bundle_root}/Contents"
macos_dir="${contents_dir}/MacOS"

cd "${repo_root}"
swift build -c "${configuration}" --product RielaApp

rm -rf "${bundle_root}"
mkdir -p "${macos_dir}"
cp ".build/${configuration}/RielaApp" "${macos_dir}/RielaApp"

cat > "${contents_dir}/Info.plist" <<'PLIST'
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
  <string>com.tacogips.riela.menubar</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>RielaApp</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.2</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

echo "${bundle_root}"
