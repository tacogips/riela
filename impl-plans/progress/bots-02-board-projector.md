# bots-02-board-projector progress

Assigned implementation complete. Formal and serial integration reviews are pending.

## Implemented

- Added the pure RielaCore board, overview row and ordered list projector. It folds task attempts, preserves native permission options, derives live and limited status, and emits five named board arrays with bounded Closed history.
- Applied pin, manual order, return-to-top, snooze, settle and workspace grouping using projected records and the caller-supplied clock. The projector requires a result-redaction closure and redacts before selecting the first line and truncating it.
- Added transactional query, upsert and default-row deletion for `bot_list_state`. The bot-wide key uses an empty item ID.
- Added the three focused suites covering projection, ordering and SQLite behavior.

## Per-edit hashes

Exact intended diffs, the pre-edit and post-edit content hashes, and the progress file's own post-edit hash are recorded in `tmp/bots-overview/bots-02-board-projector/edit-intentions.md` and `tmp/bots-overview/bots-02-board-projector/edit-hashes.tsv`. The active plan matches its pre-node runtime snapshot.

| Path | Before | After |
| --- | --- | --- |
| `Sources/RielaCore/BotBoard/BotBoardModels.swift` | `absent` | `a1097a5b4a6f62ad09dd49295f212d036dc570d1eb8bd4274c12c943c8b8c77d` |
| `Sources/RielaCore/BotBoard/BotListStateStore.swift` | `absent` | `966c0c517f03bbb8f21ccad4ae2c84c7e9df59a355a8c8e695a7ed28c6c990d1` |
| `Sources/RielaCore/BotBoard/BotBoardProjector.swift` | `absent` | `b9f3306434380986460e8b15a4d27b31fa9dbdac2f7736591e989baf82b499dc` |
| `Sources/RielaCore/BotBoard/BotBoardProjector+Work.swift` | `absent` | `36e31165de3cd35f4d11894e3741e625fd86678799160d65ab7b0193a3feb41f` |
| `Sources/RielaCore/BotBoard/BotBoardProjector.swift` | `b9f3306434380986460e8b15a4d27b31fa9dbdac2f7736591e989baf82b499dc` | `84c8c403f8d20cbcc804559456a87bf71a6eef2246439c591b7dc387f19e1d7c` |
| `Sources/RielaCore/BotBoard/BotBoardProjector+Work.swift` | `36e31165de3cd35f4d11894e3741e625fd86678799160d65ab7b0193a3feb41f` | `b2544cc766a76a61c5add1cbb8f0a3dd44c5b60b072d7c394c9bdbe177244a49` |
| `Tests/RielaCoreTests/BotBoard/BotBoardProjectorTests.swift` | `absent` | `c6b76f1d56a7c45079bb3026795677d8cbdd6a7d416802d093b313c7a0857fae` |
| `Tests/RielaCoreTests/BotBoard/BotListProjectionTests.swift` | `absent` | `f0816e41e8b98e83f22e8b1df51c739c43e961af311bea3860bd414b4d5f8de6` |
| `Tests/RielaCoreTests/BotBoard/BotListStateStoreTests.swift` | `absent` | `a0a14103c5d5574a9ed879524bfc94bee40057eda84250d1c373a9aee819f4b3` |
| `Sources/RielaCore/BotBoard/BotListStateStore.swift` | `966c0c517f03bbb8f21ccad4ae2c84c7e9df59a355a8c8e695a7ed28c6c990d1` | `7249b2b9db5822517ba0618a0f112f69d3ade8dd8a5823b83cdde08cc5a8a8c2` |
| `Sources/RielaCore/BotBoard/BotBoardProjector.swift` | `84c8c403f8d20cbcc804559456a87bf71a6eef2246439c591b7dc387f19e1d7c` | `865f23b909fa4b2348269ff49ca3a6ed93fafa2782b641460bc7fef19930a86d` |
| `Tests/RielaCoreTests/BotBoard/BotBoardProjectorTests.swift` | `c6b76f1d56a7c45079bb3026795677d8cbdd6a7d416802d093b313c7a0857fae` | `4588ae5e532d849d534dd5243ded4501752ed055b479f3dde69592fec46c1446` |
| `Sources/RielaCore/BotBoard/BotBoardProjector.swift` | `865f23b909fa4b2348269ff49ca3a6ed93fafa2782b641460bc7fef19930a86d` | `8b7c264162ec71db2f3e9a58072c019c86c39c21aed33c86d68df5caf3531aea` |

## Verification

- `mkdir -p tmp/bots-overview/bots-02-board-projector` exited 0. Log `tmp/bots-overview/bots-02-board-projector/mkdir.log`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "BotBoardProjectorTests|BotListProjectionTests|BotListStateStoreTests"'` exited 0. Log `tmp/bots-overview/bots-02-board-projector/test.log` shows 15 tests with 0 failures, split 9, 5 and 1. The test process used plan-local `TMPDIR` and XDG roots.
- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/bots-overview/bots-02-board-projector/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` exited 0 across all seven changed Swift files. Log `tmp/bots-overview/bots-02-board-projector/swiftlint.log`.
- `grep -rn "Date()" Sources/RielaCore/BotBoard` and `grep -rn "import RielaWork" Sources/RielaCore/BotBoard` both exited 1 with no matches. Logs `tmp/bots-overview/bots-02-board-projector/clock-guard.log` and `tmp/bots-overview/bots-02-board-projector/import-guard.log`.
- The pre- and post-verification SHA-256 manifests for the seven Swift files and SwiftLint configuration match. Shared-tree comparison shows only the addition of `impl-plans/progress/bots-03-activity-core.md` during the passing run. Evidence `tmp/bots-overview/bots-02-board-projector/source-identity.log` and `tmp/bots-overview/bots-02-board-projector/shared-tree-drift.log`.

## Deviations

- The earlier `test-attempt-1.log` records SQLite binding compile errors in the concurrent activity plan. `test-attempt-2.log` through `test-attempt-4.log` record shared SwiftPM database locks. Each exited 1 before running tests. The final run passed after the sibling edits and lock contention cleared.
- `swiftlint-attempt-1.log` records a UTF-8 conversion diagnostic. The store now uses a checked UTF-8 conversion and strict lint passed on the final source.

## Open items

- Formal test-integrity and adversarial decisions and the serial cumulative wave gate belong to subsequent workflow steps.
