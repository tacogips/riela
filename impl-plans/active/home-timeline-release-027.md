# Riela 0.2.7 home timeline support

Issue: https://github.com/tacogips/riela/issues/142

Integrate X gateway 0.1.9, which adds optional date/ID bounds and continuation tokens to the authenticated homeTimeline field. Preserve all Riela execution/authentication boundaries.

- Update native released SDK pin and official image immutable source revision.
- Extend image schema regression; run focused gateway CLI/privacy/image tests.
- Provide the official image promptly for the already-authorized one-off fetch using Riela 0.2.6.
- Bump patch to 0.2.7, build macOS CLI and signed/notarized app DMG, publish Linux x64 CLI and checksums.
- Verify public release and Homebrew formula/Cask plus metadata.

No unrelated memory catalog changes. Release skills: .agents/skills/macos-release-build/SKILL.md and .agents/skills/apple-notarization-setup/SKILL.md.

Pre-release gates passed: 20 focused gateway tests with one optional Apple-container skip, four live Docker image tests, changed-file SwiftLint, native 0.2.7 version and bounded home timeline schema checks. X v0.1.9 is public at 1ca8380b74e5fc1da02d80bb0e1a46ee43a0765a with all four assets and Homebrew metadata verified. Official X reader image sha256:588ab44e4427efaa78ee017c8721db0662cf01eef02398173f67ded64bd700a8 passed readonly/no-network schema/version checks.

Parent independently reviewed the scoped X parameter forwarding and found no blocker. Current X documentation limits this reverse chronological followed-account feed to the most recent 3,200 posts or seven days; callers must not claim unlimited historical completeness.
