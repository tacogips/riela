# Riela 0.2.13 X long-text integration

Issue: https://github.com/tacogips/riela/issues/147

Pin released X gateway 0.1.12 (f91fae662e45606cfd6847e884e170c02d8e83cd)
in the native SDK and official image source. This adds full `note_tweet.text`
projection for roots/originals/quotes and optional verified `homeTimeline(userId: ID)`
to avoid repeated account lookup during pagination. Authorization, reference depth
and container isolation are unchanged. The upstream release passed 39 offline tests.

Verify native schema/argument handling and existing gateway/privacy regressions.
Update the opt-in image schema assertion without executing container tests during
the caller's exclusive build window. Build a complete bundled native candidate
for ART, then publish macOS CLI, signed/notarized app DMG and Linux x64 CLI with
checksums. Coordinate tap publication after 0.2.12 completes. Preserve all 0.2.12
staged artifacts. No live provider requests are authorized for this source work.

Source gates: 40 focused gateway command/privacy/resolver tests passed (one
unrequested live-container test skipped). Changed-file SwiftLint and diff checks
passed. The separately authorized Apple-container X image schema check passed
one test with no provider credentials/network. The staged full debug candidate
reports 0.2.13 and exposes the new userId schema. Parent reviewed the production
pin/version/image changes with no blockers. The candidate remains immutable while
ART runs its independently authorized manual workflow; release builds use separate
versioned directories.

Release complete: https://github.com/tacogips/riela/releases/tag/v0.2.13 at
1ce5f45468ead411819504d64d125c09186a220a. Six assets are public; every GitHub
digest matches its verified local file. Optimized macOS CLI version, new X schema,
and all nine gateway help routes pass. App/helper/DMG signing, notarization,
stapling and Gatekeeper validation passed (submission
2fc46b18-b3be-4b3c-8c21-0c7553a91a7f). Linux workflow 39127775614 succeeded,
including clean-runtime archive/version verification.

Tap formula/Cask commit c065bff88f5561519e5bb597f1d44e33b531bd6e passed Ruby
syntax, strict audits and fetches. Metadata workflow 39128627378 succeeded;
public main and immutable 9cbf6b22285130d5b83ccaa2e37b18102d643f28 JSON report
0.2.13 and exact committed Ruby source hashes. The complete optimized archive
was staged separately for ART; X 0.1.12, Gmail 0.1.21 and Apple 0.1.13 version
checks passed. Read-only Apple permission status reported Notes automation granted.
No provider data mutation was performed by this release work.
