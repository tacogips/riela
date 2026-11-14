# eh-01-history-engine progress

## Assignment and readiness

- Workflow mode: `issue-resolution`, Step 6 implementation.
- Plan: `eh-01-history-engine`, `impl-plans/active/efficient-history-01-history-engine.md`.
- Issue reference: owner issue “One shared versioned history (diff, undo/redo, retention: memory 2 / state 1 / workflow definitions 10) and efficient session storage with storage doctor/compact” (no GitHub number).
- Workflow execution: `opus-luna-design-and-implement-review-loop-session-518`; current implementation step `step6-implement`; dispatch execution `nested-v1-0e56c6c26d53f7f09a4e71f0d4ebd2ddf964ec33a22130defb3acfdee0bfdaea`.
- Codex agent: `/root`, primary implementer.
- Dependency readiness: `dependsOn: []`; no predecessor acceptance required. The pre-node snapshot `tmp/riela-fanout/5C8D3C3E-DF9D-4640-B3FD-A6B171A1D03A/C34644A1-A768-4326-A3D0-7F066BABA757.json` showed only the existing `Package.swift`; assigned engine, CZlib, tests, and progress paths were absent.
- Design alignment: `design-docs/specs/design-efficient-history-and-storage.md` §2 places the shared engine in `RielaMemory`, behind the SQL executor, and keeps transaction ownership in adapters. This plan owns only the engine seam and does not integrate memory/definition stores.

## Implemented

- Added local `CZlib` system library target and RielaMemory dependency only; retained the `swift-crypto` dependency declaration and pins.
- Added the binary zlib/full-or-splice codec, SQL value/protocol and SQLite executor, shared history types/schema/store operations, SHA-256 checked reconstruction, CAS revisions, head movement, pins, redo detachment, guarded retention deletes, chain import and shared JSON diff/byte fallback.
- Added 10 in-memory SQLite tests covering both stored and external heads; codec round trips including binary/Unicode/empty data; 1,000 writes of a roughly 660 KB JSON payload; retention windows and pins; revisions, dedupe, forced writes, undo/redo, branch detachment/deletion, import, corruption, SQL guarded deletes, and JSON diff paths/arrays/numbers/fallback.
- No edits to downstream adapters or sibling-owned paths.

## Edit evidence

The immutable dispatch snapshot established the initial state: `Packages/RielaMemory/Package.swift` SHA-256 `99ae4f74255132c5559c21e1dfd1fc2d519860735d3f68076d665c0aa4610eff`; all other assigned code/test/progress paths were absent. Per-edit behavior intentions were preserved in `tmp/efficient-history/eh-01-history-engine/edit-intents.md`. Final authored file SHA-256 values:

- `Packages/RielaMemory/Package.swift`: `c285f8a7a9fe383e42a3ef05f1d2afcc33bcd59e08d2db8b80b5130969fe8ef7`
- `Packages/RielaMemory/Sources/CZlib/module.modulemap`: `80a5aa1a428378f336bd0ecbb1691fe89cf5e834624bd9fa674b1f052b0a0420`
- `Packages/RielaMemory/Sources/CZlib/shim.h`: `80324eed37fb3c06611102a5ed598bb3d60aa818eeb6f848068e359677a07ea7`
- `Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/VersionedHistoryTypes.swift`: `363fa471a35a73e0c5df0976a3e6360db09d911e72e0129c5d955d129911e595`
- `Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/VersionedHistorySQL.swift`: `4ee0d72674fe1fd193ab39aa5d7dfd2ff1ba2cdcd997098331f50e9ee170e667`
- `Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/VersionedHistoryCodec.swift`: `79fc884f0b093b5f162546b0ba0517e2956a551b9e17387e72fc422ee863253d`
- `Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/VersionedHistoryStore.swift`: `76d35581f4b5eae881f8d3c1ea83b466dd334a2478e19a34376d248362bdf2ce`
- `Packages/RielaMemory/Sources/RielaMemory/VersionedHistory/VersionedHistoryDiff.swift`: `14efc9cbc430b7bac5ae6a283b41efffdb97366a9969b63e2753d6bd419505bf`
- `Packages/RielaMemory/Tests/RielaMemoryTests/VersionedHistoryTests.swift`: `123abec8af6f44636c079f2b402ed233cbc79d38e283a4f9e708c320d06a6c11`

## Final verification (current source)

- `arch -arm64 /bin/zsh -lc 'swift build --package-path Packages/RielaMemory'` — exit 0; complete log `tmp/efficient-history/eh-01-history-engine/build-final.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory --filter VersionedHistoryTests'` — exit 0; 10 tests, 0 failures; complete log `tmp/efficient-history/eh-01-history-engine/test-final2.log`.
- Changed-file strict lint used NUL manifest `tmp/efficient-history/eh-01-history-engine/changed-swift-files.nul`: `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/efficient-history/eh-01-history-engine/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` — exit 0; complete log `tmp/efficient-history/eh-01-history-engine/swiftlint-final2.log`.
- `rg -n 'public struct VersionedHistoryStore' Packages/RielaMemory/Sources` matched at `VersionedHistoryStore.swift:3`.
- `git diff --check -- Packages/RielaMemory/Package.swift` — exit 0. Manifest diff contains only CZlib target and RielaMemory dependency lines; no dependency pin edits.

## Superseded attempts

Earlier compile/test attempts found and resolved implementation/test issues (API Sendable mismatch, malformed test fixture, SQL head upsert, redo expectations). The current-source final checks above supersede those attempts. A late rerun reused `test-final.log` before the passing run and replaced one failed test-expectation log; the failure was the unpinned redo test expecting version 4 where the accepted monotonic revision contract correctly creates version 5. The source expectation was corrected, and the final same-command rerun at `test-final2.log` passed all 10 tests. Earlier retained logs include `build.log`, `build-retry.log`, `test.log`, `test-retry.log`, `test-retry2.log`, `test-retry3.log`, `test-final-candidate.log`, and `test-final-candidate2.log`.

## Completion boundary

The assigned eh-01 source, tests, progress record, and required plan-local checks are complete. Memory/definition integrations, formal implementation review, downstream docs, serial reconciliation, staging, commit, rebase, and push remain owned by later workflow steps.

## Adversarial review repair: EH01-ADV-F1

- Review decision: accepted and fixed. `applyRetentionInternal` previously assumed the head was the greatest non-detached version, which fails after undo. It now keeps `headVersion`, all non-detached redo-branch versions above the head, the newest `max(R-1, 0)` non-detached versions below the head, and pins. The `R == 0` early return and remaining retention/re-encoding flow are unchanged.
- Added `testApplyRetentionAfterUndoKeepsHeadAndRedoBranch` for `.stored` and `.external`. It verifies R=1 drops only version 1 while preserving head version 2 and redo versions 3/4, reports freed bytes, then redo and a following write succeed. Its R=2 case verifies the previous version 1 remains retained.
- Source hashes before this repair (recorded before edits): Store `76d35581f4b5eae881f8d3c1ea83b466dd334a2478e19a34376d248362bdf2ce`; tests `123abec8af6f44636c079f2b402ed233cbc79d38e283a4f9e708c320d06a6c11`; progress log `11ba7fbdb63481982b63a20973c50ad760c0d257bbaaf80e468e8db8eb085ae9`.
- Source hashes after repair: Store `b9ec2f58c26c6595f6ad1965a96e944a57bc98c36e9c19da3cfe5ae0ea675161`; tests `9f193ff8e849446f27bb47738b7297bc19119e4906e0f1b7586bec6319272bc5`.
- `arch -arm64 /bin/zsh -lc 'swift build --package-path Packages/RielaMemory'` — exit 0; log `tmp/efficient-history/eh-01-history-engine/build-f1.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory --filter VersionedHistoryTests'` — exit 0; 11 tests, 0 failures; log `tmp/efficient-history/eh-01-history-engine/test-f1.log`.
- Changed-file strict lint through `tmp/efficient-history/eh-01-history-engine/changed-swift-files.nul` — exit 0; log `tmp/efficient-history/eh-01-history-engine/swiftlint-f1.log`.
- Existing write-path window regressions passed unchanged in the 11-test run: R=2 large history, R=5, and R=10 with pin 3.
- No public signature/error case or sibling-owned file changed. Review finding EH01-ADV-F1 is resolved on current source; independent Opus re-review is pending.
