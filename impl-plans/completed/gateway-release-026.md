# Riela 0.2.6 gateway release

User explicitly requested commits, push, patch bump and release after native
gateway authentication and incremental source support.

- [x] Commit gateway reader privacy/home fixes, delegated native gateway CLI,
  and released X 0.1.8 native/image integration.
- [x] Verify latest remote release is 0.2.5; local main has no divergence.
- [x] Verify configured signing identity/certificate and notarization profile
  without logging credential values.
- [x] Integrate Gmail v0.1.20 released revision 5bbcb03bcd0ef09249081694b1a75dfc3a1ca2e1 in native dependency and official image.
- [x] Align VERSION and Package.swift embedded version at 0.2.6; run focused
  gateway/privacy/native auth/image regressions and changed-file lint.
- [x] Build final macOS arm64 CLI archive and signed/notarized/stapled app DMG.
- [x] Push source/tag, publish assets, run Linux x64 release workflow at tag.
- [x] Render/update formula and Cask, validate release assets and tap metadata.

The release follows the previous supported artifact layout: macOS arm64 CLI
and app, plus Linux x64 CLI. No UI behavior changes are part of this release.
Existing broad catalog parity failures for memory history/show-version/
restore-version were observed before this work; focused gateway catalog parity
passes and no unrelated memory catalog change is included.

Skills: .agents/skills/macos-release-build/SKILL.md and
.agents/skills/apple-notarization-setup/SKILL.md.

Final pre-release verification: 48 focused gateway/auth/privacy/resolver tests
passed with one optional Apple-container skip; four opt-in Docker gateway image
tests passed. Both official Gmail and X images rebuilt from public release
revisions. All nine provider help routes and X incremental schema passed on a
stable final-SDK 0.2.6 debug CLI copy; changed Swift files passed lint.

Gmail is pinned to the immutable v0.1.20 revision because SwiftPM rejects a
stable-version package that itself depends on revision-pinned packages. Its
standalone Linux CI retains an existing CryptoKit import issue; the Riela
maintained Linux image adaptations built successfully and passed image tests.

Completed release: https://github.com/tacogips/riela/releases/tag/v0.2.6
Release source: e856fe41452e22a3c7d09ccbb06cbf04da5e79de.

- Published six assets: macOS arm64 CLI tarball and checksum, signed notarized
  macOS arm64 DMG and checksum, Linux x64 CLI tarball and checksum. Unauthenticated
  GitHub API confirmed the public non-draft release and all uploaded assets.
- macOS archive and final signed CLI passed version, all nine provider help
  routes, Gmail 0.1.20, X 0.1.8 and incremental schema checks. DMG notarization
  accepted; stapling, validation and Gatekeeper assessment passed.
- Linux build run 39105734283 and release run 39105756268 succeeded. The release
  job checks archive checksum/version and runs a clean Ubuntu archive smoke test.
- Homebrew tap commit a1f1ef2d3a908f857ee1313e3f69cb85e232f701 updates formula
  and Cask. Both strict audits and fetch/checksum checks passed. Metadata run
  39106632912 succeeded; both public main JSON endpoints and immutable metadata
  commit e6b2a4ba376b1699c70c4c19a35e9a47ca473d50 report 0.2.6 and exact formula/
  Cask source checksums. The global Riela installation was not replaced.
- Cask build used the supported RIELA_CASK_RELEASE_DIR=dist/homebrew override to
  reuse the identical final-source Swift cache after CLI archive verification.
  Its DMG artifacts are therefore beside the CLI archive in dist/homebrew.
- Caller independently verified native Gmail/X collection and actual X recent
  sinceId/nextToken pagination with no page overlap. Caller node-memory/cache
  behavior is implemented in ART, not in this Riela release.
