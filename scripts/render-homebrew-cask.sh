#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/render-homebrew-cask.sh <version> [output-file]

Reads archive checksums from:
  dist/homebrew-cask/riela-<version>-<target>.dmg.sha256

Environment:
  RIELA_CASK_RELEASE_DIR       Directory containing archives and .sha256 files.
  RIELA_CASK_RELEASE_BASE_URL  Release URL base. Defaults to GitHub v<version>.

Example:
  scripts/build-homebrew-cask-release.sh darwin-arm64 darwin-x64
  scripts/render-homebrew-cask.sh 0.1.0 ../homebrew-tap/Casks/riela.rb

This renderer expects signed, notarized, and stapled macOS .dmg artifacts. Linux Cask
artifacts are unsupported.
EOF
}

sha_for_target() {
  local version target release_dir sha_file
  version="$1"
  target="$2"
  release_dir="$3"
  sha_file="$release_dir/riela-$version-$target.dmg.sha256"

  if [[ ! -f "$sha_file" ]]; then
    printf 'missing checksum file: %s\n' "$sha_file" >&2
    return 1
  fi

  awk '{print $1}' "$sha_file"
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return
  fi
  if [[ "${1:-}" == "" ]]; then
    usage
    return 2
  fi

  local version output release_dir release_base_url
  version="$1"
  output="${2:-$repo_root/Casks/riela.rb}"
  release_dir="${RIELA_CASK_RELEASE_DIR:-$repo_root/dist/homebrew-cask}"
  release_base_url="${RIELA_CASK_RELEASE_BASE_URL:-https://github.com/tacogips/riela/releases/download/v$version}"

  local darwin_arm64_sha darwin_x64_sha
  darwin_arm64_sha="$(sha_for_target "$version" darwin-arm64 "$release_dir")"
  darwin_x64_sha="$(sha_for_target "$version" darwin-x64 "$release_dir")"

  mkdir -p "$(dirname "$output")"
  cat > "$output" <<EOF
cask "riela" do
  version "$version"
  arch arm: "darwin-arm64", intel: "darwin-x64"

  sha256 arm: "$darwin_arm64_sha",
         intel: "$darwin_x64_sha"

  url "$release_base_url/riela-#{version}-#{arch}.dmg",
      verified: "github.com/tacogips/riela/releases/download/"
  name "riela"
  desc "Swift-native workflow runtime for cooperative multi-agent execution"
  homepage "https://github.com/tacogips/riela"

  livecheck do
    url :url
    strategy :github_latest
  end

  binary "riela"

  caveats do
    <<~EOS
      This cask installs the signed and notarized macOS command line tool.
      Homebrew links riela into the native Homebrew prefix for this Mac.
    EOS
  end
end
EOF

  printf 'rendered %s\n' "$output"
}

main "$@"
