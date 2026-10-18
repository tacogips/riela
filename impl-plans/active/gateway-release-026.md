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
- [ ] Build final macOS arm64 CLI archive and signed/notarized/stapled app DMG.
- [ ] Push source/tag, publish assets, run Linux x64 release workflow at tag.
- [ ] Render/update formula and Cask, validate release assets and tap metadata.

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
