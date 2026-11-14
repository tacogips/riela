# eh-03-memory-history progress

## Continuation audit (before implementation edits)

This audit compares the pinned API, tests, and done criteria with the current working tree. Initial statuses record source presence; final verification and test outcomes are recorded below.

| Contract item | Current tree status | Evidence / gap |
|---|---|---|
| Pinned save/update/restore APIs with defaulted `historyRetention` | Done | Present and compiled; defaulted parameters preserve existing call sites |
| Undo/redo, diff, legacy conversion APIs and result types | Done | Present and exercised by package tests |
| Schema version 7 and additive migration | Done | Exact declaration in `SQLiteMemorySupport.swift`; schema-6 conversion test passes |
| Default retention 2, range validation, snapshot retention 1, pins, incremental vacuum | Done | Implemented in the adapter/write and snapshot paths; retention/pinning tests pass |
| Legacy `memory_evolution` read and conversion on first write / batch conversion | Done | Legacy read, first-write conversion, and batch conversion coverage passes |
| New `MemoryHistoryRetentionTests` | Done | 6 tests pass, including 1,000 large writes, bounded vacuum reclamation, conversion, undo/redo, snapshots, and validation |
| Changed existing tests justified | Done | Rationale recorded below for all three changed pre-existing test files |
| `MemoryModels.swift` limited to history-retention error case | Done | Diff adds only `RielaMemoryError.invalidHistoryRetention(Int)` |
| No writes to `memory_evolution` outside test fixtures; schema 7 grep | Done | Source has no `INSERT INTO memory_evolution`; hits are fixtures. Exact `currentSchemaVersion = 7` grep matches |
| Public API remains additive; no `VersionedHistory/` edits | Done | New parameters default to `nil`; new methods/types are additive. Shared engine files were not edited by eh-03 |
| Full RielaMemory package suite and selected-file strict SwiftLint | Done | Final build passed; 112 tests passed; selected-file `swiftlint lint --strict` passed |
| Complete progress record with per-edit SHA-256 and outcomes | Done | Baseline and owned-source edit hashes below; final progress-log digest is task-local evidence |

### Pre-edit SHA-256 baseline

Captured before creating this progress log; missing progress log is recorded explicitly.

```text
b8fa7e0be27b219250d7c7070e2a9da675d1ab330876ce115c0c7cd2e3425694  Packages/RielaMemory/Sources/RielaMemory/RielaMemory.swift
8cfe86bcd3973eaccafea766d4c7e41984ffbef0808a1e8cb54c5e048fa52a79  Packages/RielaMemory/Sources/RielaMemory/SQLiteMemorySupport.swift
e47f8e383e99a5d59039f1abbcb2ecf938722b8eca1c5481ed6598427650322f  Packages/RielaMemory/Sources/RielaMemory/MemoryEvolutionHistory.swift
13ed3ccc71e885afca6f6985f51368926e8eaa594dad7f6e6604644643efecbc  Packages/RielaMemory/Sources/RielaMemory/MemorySnapshot.swift
9f7c6d6d01f92d43894c49b0d8cb9b045a38c9b1b6032566d5f61b6609d1aa60  Packages/RielaMemory/Sources/RielaMemory/MemorySnapshotRetention.swift
70549cbfabb065e80296fc8a11c9e9b296dc5e4ec14616a5c39f297e08417f24  Packages/RielaMemory/Sources/RielaMemory/MemoryHistoryRetirement.swift
32ed9cd7b0e7dc2495273b3a4ace58d1cbca180d3ef8089d967ef2c85dd6299c  Packages/RielaMemory/Sources/RielaMemory/MemoryHistoryAdapter.swift
e4e8453ef37c6463e68ff6ef205edc6b5d1ae7229bdd2d648eff7e6c052ea5d8  Packages/RielaMemory/Sources/RielaMemory/MemoryModels.swift
6b15376929be04d3a895432a0e815784cbbf5af3481819d65937815c267ccbf0  Packages/RielaMemory/Tests/RielaMemoryTests/MemoryHistoryRetentionTests.swift
ecd443f0e91d731261ee9e564a7d637133f14b02ec13b06f1707705bfd13d5de  Packages/RielaMemory/Tests/RielaMemoryTests/MemoryEvolutionHistoryTests.swift
5a8b638296b62a2d547705119ba545d8e21789e19341e5f24001dd31e2bb77a1  Packages/RielaMemory/Tests/RielaMemoryTests/MemorySnapshotTests.swift
6222a50e3d0e861c567535c211c4d628d54bb1ffa707aa2c3efdc6bfdbae5dcb  Packages/RielaMemory/Tests/RielaMemoryTests/MemorySnapshotRetentionTests.swift
bea58a0c8672bf4a3da18c9812fecb125f96ff45afa4035a198ae4facaa1e8d3  Packages/RielaMemory/Tests/RielaMemoryTests/MemoryHistoryRetirementTests.swift
695bc83a6fa3fe909e575a117bfb2a3163731310a5f43701177d20999066c4b8  Packages/RielaMemory/Tests/RielaMemoryTests/RielaMemoryTests.swift
MISSING  impl-plans/progress/eh-03-memory-history.md
```

## Implementation record

### Implementation changes

- Routed memory history writes through the shared engine with schema 7, default retention 2, configurable 1...1000 retention, legacy conversion, snapshot retention 1, active snapshot pins, undo/redo, structural diff, and best-effort incremental vacuum.
- Added `MemoryHistoryAdapter.swift`, the pinned result/report types, and `MemoryHistoryRetentionTests.swift`. `MemoryModels.swift` contains only the requested `invalidHistoryRetention(Int)` case.
- Kept `VersionedHistory/` and sibling plan write paths untouched. No new `memory_evolution` row writes exist in source.
- Extracted the two value-list queries into a same-file `RielaMemoryStore` extension to keep selected-file strict SwiftLint clean without changing API or query behavior. The shared engine's three-field legacy import tuple is represented locally with a named type; retirement flow was split into a focused helper without changing its guards or outcomes.

### Changed pre-existing test rationale

- `MemoryEvolutionHistoryTests.swift`: explicit `historyRetention` values preserve the tests' intended multi-version/restore/concurrency coverage under the new default window of two; the stored-version assertion now checks the shared engine's `external` encoding instead of a legacy reverse-delta payload.
- `MemoryHistoryRetirementTests.swift`: fixtures explicitly reconstruct legacy rows where tests exercise retirement of old-format histories; longer-history tests request larger windows; expired versions now assert the shared `VersionedHistoryError.versionNotRetained` contract.
- `MemorySnapshotTests.swift`: snapshot/state writes have retention one, so an unpinned pre-snapshot version must no longer be readable. The assertions now verify that expiration. Pinned snapshot history is covered in `MemoryHistoryRetentionTests` and existing snapshot-retention tests.

### Per-edit SHA-256 records

The complete owned-file pre-edit baseline is in the table above. Source edits made during this implementation:

| Edit | File | Pre-edit SHA-256 | Post-edit SHA-256 |
|---|---|---|---|
| 1 (create this progress log) | `impl-plans/progress/eh-03-memory-history.md` | Missing | `6d86db17829882c96fb44277a9d518d60a1154f9e9a9ada81b7a14339047c16a` (before final progress update; final digest is in task-local evidence) |
| 3 | `MemoryHistoryAdapter.swift` | `32ed9cd7b0e7dc2495273b3a4ace58d1cbca180d3ef8089d967ef2c85dd6299c` | `ad25345fbfebec0d622ab2120dd04c4a492e077f764a6a4fbd70e6f115293982` |
| 3 | `MemoryHistoryRetirement.swift` | `70549cbfabb065e80296fc8a11c9e9b296dc5e4ec14616a5c39f297e08417f24` | `8930b77198bd72da57723b1d1aa6d09791d05ec474d7c5cdae1abec9bdc88079` |
| 3 | `MemoryEvolutionHistory.swift` | `e47f8e383e99a5d59039f1abbcb2ecf938722b8eca1c5481ed6598427650322f` | `6246e6c228678e95d639099db015a66f9fa0eaf6aca21fca7538da8b4ba3db16` |
| 3 | `RielaMemory.swift` | `b8fa7e0be27b219250d7c7070e2a9da675d1ab330876ce115c0c7cd2e3425694` | `cf545daf98320a119aecbfde1c7c21f1adcae9d257c680cf29640049c2d11808` (superseded by edit 4) |
| 4 | `RielaMemory.swift` | `cf545daf98320a119aecbfde1c7c21f1adcae9d257c680cf29640049c2d11808` | `c23ca272c17caf123b0095f10770bfbfcc868967e6729f4fee43d78aef15dfc1` |
| 5 (final progress update) | `impl-plans/progress/eh-03-memory-history.md` | `6d86db17829882c96fb44277a9d518d60a1154f9e9a9ada81b7a14339047c16a` | See `tmp/efficient-history/eh-03-memory-history/progress-update-post-sha256.txt` |
| 6 (vacuum test) | `MemoryHistoryRetentionTests.swift` | `6b15376929be04d3a895432a0e815784cbbf5af3481819d65937815c267ccbf0` | `ad6251de024c46ff5a2fbf17a9755a5e432679ece9a188f36fe4cc6b8571f4b2` |
| 7 (use freelist evidence because writes can reuse pages) | `MemoryHistoryRetentionTests.swift` | `ad6251de024c46ff5a2fbf17a9755a5e432679ece9a188f36fe4cc6b8571f4b2` | `98e50b1990d9ee501fd5bbcf82863bb0a6a50ee7520606995d6295e0b3c09022` |
| 8 (negative-control mutation, restored byte-for-byte) | `MemoryHistoryAdapter.swift` | `ad25345fbfebec0d622ab2120dd04c4a492e077f764a6a4fbd70e6f115293982` | Temporary disabled-body SHA-256 `a11c5b4e5e1440b4ac23580d34219c021b7a17b6fe118246a531d1585e794e56`; restored SHA equals pre-edit |
| 9 (review progress update) | `impl-plans/progress/eh-03-memory-history.md` | `878bf20596c20c8622e309222ab8354ed781d15caeab86d4eb450d95fe239cc8` | See `tmp/efficient-history/eh-03-memory-history/progress-update-post-sha256-review.txt` |
| 10 (final review evidence update) | `impl-plans/progress/eh-03-memory-history.md` | `429da9d509afaca3031a48f04ea494690017474f2fe6c8827b1af460a92a914e` | See `tmp/efficient-history/eh-03-memory-history/progress-update-post-sha256-review-final.txt` |

The task-local `pre-edit-sha256.txt` contains the SHA-256 baseline for every plan-owned file, including files that were missing or unchanged at task start.

### Final-source verification

| Command | Exit | Result | Complete log |
|---|---:|---|---|
| `arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory --filter MemoryHistoryRetentionTests'` | 0 | 6 tests, 0 failures; new vacuum test passed | `tmp/efficient-history/eh-03-memory-history/test-vacuum-focused-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift build --package-path Packages/RielaMemory'` | 0 | Build passed | `tmp/efficient-history/eh-03-memory-history/build-vacuum-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory'` | 0 | 112 tests, 0 failures; `MemoryHistoryRetentionTests` listed and passed | `tmp/efficient-history/eh-03-memory-history/test-eh03-final2.log` |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/efficient-history/eh-03-memory-history/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | Strict lint passed for the exact changed-file manifest | `tmp/efficient-history/eh-03-memory-history/swiftlint-vacuum-final.log` |

### Test-integrity repair EH03-TI-01

- Added `testRetentionDeleteReclaimsDatabasePages`. It verifies a fresh database has `auto_vacuum = 2`, writes three distinct deterministic pseudo-random 256 KB payloads at default retention 2, estimates pages in the soon-to-be-deleted history BLOB, then checks `freelist_count` after the update is below that estimate and the database file did not grow. Metrics are read through separate database connections.
- The initial assertion that `page_count` must decrease failed (`134` before and after) even with vacuum enabled: pages can be reused during the write. The test now checks freelist reclamation directly, which passed.
- Negative control: temporarily made `reclaimHistoryPages` a no-op and ran only `testRetentionDeleteReclaimsDatabasePages`; it failed as required (1 test, 2 assertion failures: freelist `47` was not below estimate `47`, and file size grew from `548864` to `741376`). `MemoryHistoryAdapter.swift` was restored with SHA-256 exactly `ad25345fbfebec0d622ab2120dd04c4a492e077f764a6a4fbd70e6f115293982`.
- The first page-count attempt is preserved in `test-vacuum-focused.log` (exit 1, 1 test, 1 failure). The successful focused run is `test-vacuum-focused-final.log` (exit 0, 6 tests, 0 failures). The final full suite and lint logs are listed above.
- Negative-control command: `arch -arm64 /bin/zsh -lc 'swift test --package-path Packages/RielaMemory --filter MemoryHistoryRetentionTests.testRetentionDeleteReclaimsDatabasePages'`; observed exit 1, 1 test, 2 failures, complete log `tmp/efficient-history/eh-03-memory-history/test-vacuum-negative.log`. This is an expected-failure mutation check, not passing behavioral evidence.

Earlier attempts are retained rather than overwritten: the first build wrapper used zsh's reserved `status` variable (the captured build log itself showed “Build complete”); the first strict lint run reported plan-local formatting/complexity issues plus a pre-existing type-body-length violation, and the second run reported only that violation. Edits 3 and 4 fixed those findings. The initial vacuum test also exposed that `page_count` can remain constant when freed pages are reused; the freelist assertion and negative control now demonstrate the intended behavior.

### Handoff

The assigned eh-03 implementation, tests, progress record, and required package verification are complete. Formal integration/adversarial review, later-plan work, final staging, commit, rebase, and push remain with their assigned downstream workflow steps.
