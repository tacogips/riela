# xs-03 author sampling progress

Prior attempt (superseded by Continuation 1): incomplete. Implemented the SHA-256 deterministic draw and one distribution/edge test. The collector integration, strict rolling state codec, auto-sampling, count intervals, metadata and their required tests remain outstanding; the plan's done criteria are not met. No formal review has occurred.

Files and SHA-256 at verification:
- `Sources/RielaCLI/XCollectionSampling.swift`: `fcfdcc21c6873eaf5e7bc4e555c6da1ef42895a303fbdfd5bc19df509bf98bd0`
- `Tests/RielaCLITests/XCollectionSamplingTests.swift`: `daea1b3aeb7a31bcf6bbadf140cfa923639218ef37f1efc008f4181e7aa5ff8b`

Evidence under `tmp/x-collect-author-sampling/xs-03-author-sampling/`:
- `build.log`: exit 1 during concurrent xs-02 edits to `XCollectionWindow.swift`; `build-retry.log`: exit 0 after that edit changed, moving shared tree.
- `test.log`: exit 0, 16 tests, 1 skipped, 0 failures; moving shared tree.
- `lint.log`: exit 0, strict selected-file lint using `changed-swift.nul`.

## Continuation 1: implementation complete, review pending

Implemented explicit and automatic sampling in `XCollectionSampling.swift` and `ProductionNodeAdapter+XCollect.swift`: strict checkpoint state, frozen daily probabilities, interval and pending tallies, fresh one-page sampled reads, regular-query exclusion, failure/truncation metadata and all-sampled checkpoints. Preserved the xs-01 billing-day and depth wiring. Added collector tests in `XCollectionSamplingTests.swift`, including UTC clock-day behavior. State count overflow, fractional timestamps and stale tally after scan reset were corrected during self-check.

Final-source gates on the shared tree (logs under `tmp/x-collect-author-sampling/xs-03-author-sampling/`):
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests'`: exit 0, `build-final.log`.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'XCollectionSamplingTests|XCollectionTests|XCollectionReferenceDepthTests'"`: exit 0, 26 tests, 1 pre-existing skip, 0 failures, `test-final.log`.
- Strict lint of the three changed Swift files via `changed-swift-continuation.nul`: exit 0, `lint-continuation-2.log`. Plan's direct lint command: exit 0, `lint-plan.log`.
- `! rg -n Hasher Sources/RielaCLI/XCollectionSampling.swift`: exit 0, `no-hasher-final.log`; `git diff --check`: exit 0, `diff-check.log`.
- Earlier `lint-continuation-1.log` failed on statement position and function complexity; both fixed and rerun. `build-continuation-1.log` and `build-continuation-2.log` passed before final lint corrections.

Source SHA-256: sampling `0de2f4912da4ce06972c9418b265acc5f69dd9145739bddc3edcb061869b27ed`; collector `8ff1dc8c4890ba358647e84a504238f6f446a81f4d88410044924bfee01e4315`; tests `3e3ada3d7df14ff5f58833655bf6d5a3ea1c0d603648d837cd731b9911e2ba7d`. Formal integrity, adversarial and combined-tree integration reviews remain downstream.

## XS03-ADV-M1 revision

Validated stale author entries before filtering removed handles from auto, through, pending posts and daily buckets. Saved state is validated using its own timezone, then discarded on a timezone change. Existing malformed-state rejection is preserved. Added collector regressions for handle removal, timezone change and malformed removed-handle data. Before the fix, `reproduce-m1.log` recorded 2 tests and 2 expected failures (exit 1).

Final-source verification under `tmp/x-collect-author-sampling/xs-03-author-sampling/`: `build-m1.log` exit 0; `test-m1.log` exit 0, 42 tests, 1 pre-existing skip, 0 failures; `lint-m1.log` and `lint-m1-manifest.log` exit 0; `no-hasher-m1.log` exit 0. The three Swift source SHA-256 values are e26e19e93c89e0a4ea765bd417cb286d607d99360407ed0cc6495aaf284e086b, 8ff1dc8c4890ba358647e84a504238f6f446a81f4d88410044924bfee01e4315, and 78f3213f2efadab5ef327ba16ee89ccffda2aa4d60e3f99f4c9809ddea714b59, respectively. Independent re-review and combined integration verification remain downstream.
