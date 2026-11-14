# xs-01 implementation progress

- Mode: issue-resolution; accepted design alignment confirmed; dependencies: none.
- Implemented validated option contract, depth-aware selection, checkpoint identity/reset, frozen UTC billing day, and needsRequest seam. Synthetic freshness heads retain their depth identity.
- Added focused reference-depth tests. Per-edit preimages, intentions and before/after SHA-256 hashes are preserved under `tmp/x-collect-author-sampling/xs-01-options-and-depth/`.
- Strict selected-file lint, plan lint, needsRequest inspection, and unchanged-file diff passed. Build and focused tests passed: 21 tests executed, one optional fixture skipped, zero failures.
- Sampling and UTC-day segment logic belong to dependent plans. Independent reviews, integration, commit and push remain downstream.

## Verification and hashes

- `arch -arm64 /bin/zsh -lc 'swift build --build-tests'`: exit 0; `tmp/x-collect-author-sampling/xs-01-options-and-depth/build.log`.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'XCollectionReferenceDepthTests|XCollectionTests|XLookupCollectionTests'"`: exit 0; 21 tests, 1 skipped, 0 failures; `tmp/x-collect-author-sampling/xs-01-options-and-depth/test.log`.
- Plan lint and strict selected-file lint: exit 0, zero violations; `lint.log` and `strict-lint-final.log` in the evidence directory.
- `git grep -n needsRequest Sources/RielaCLI`: exit 0; `needs-request.log`. Unchanged lookup and existing test diff: exit 0, empty `unchanged.log`.
- Per-edit SHA-256 pre/post identities and exact intent are in the evidence directory; final source hashes:

```
715b123085ca64f9f1476676b17baf6ced5e55703361d6ad04fe03374b99867a  Sources/RielaCLI/XCollectionOptions.swift
6b9fcfd0cbd713f5f88451fdd7dcf7fa8d336d3f7e60955fb38727502bd2b70e  Sources/RielaCLI/XCollectionWindow.swift
a49ad9ddd0f310a766e71a005a2cd2a8d21179a4c7db87dc80a2d6935934f5d4  Sources/RielaCLI/ProductionNodeAdapter+XCollect.swift
f020e84b94fcb76e4788721971050207ba527c10a3b703e960f169016c396a50  Tests/RielaCLITests/XCollectionReferenceDepthTests.swift
```
