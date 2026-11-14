# Notes reads and gateway archive diagnostics

Issue: https://github.com/tacogips/riela/issues/143

Integrate published Apple gateway0.1.10 and X gateway0.1.10. Apple note HTML selection must request the HTML representation and reject simultaneous plaintext/HTML selection before launch. Allow project .runtime download roots while preserving owner-only and symlink checks. Preserve only known SDK error codes/classifications and explicit numeric HTTP status across failed container execution; never forward provider text.

Tests: Notes request construction/no-launch, private path acceptance and protection regressions, container error allowlist/rejection, gateway native help/schema and official image regressions. Publish Riela0.2.8 macOS CLI/signed-notarized DMG and Linuxx64 CLI, verify tap formula/Cask and public metadata. Include native Notes attachment import; caller verified disposable PNG import/export byte identity. No unrelated memory catalog changes.

Pre-release:48 focused tests (one optional Apple-container skip), four official Docker image tests, changed-file lint clean; added linked Apple full/reader schema regression. Parent reviewed finite diagnostic allowlist and found no blocker. Apple SDK final281 tests+smoke/lint clean; exact pinned public revision includes import and attachment-ID dedup. X0.1.10 release/tap fully verified.

Final tree gates:49 focused tests, one optional Apple-container skip, zero failures; four official Docker image tests; zero lint violations in nine changed Swift files. Native Apple schema exposes HTML and attachment import only on full role. Final staged debug CLI verifies Riela0.2.8 and Apple0.1.10.
