# eh-11-catalog-help-docs progress

## Status

Completed on `feat/efficient-history`; changes remain in the working tree. No
commit, push, rebase, or reset was performed. Accepted prerequisites eh-08,
eh-09 and eh-10 were present. Earlier progress logs eh-01 through eh-10 and the
accepted design were reviewed before editing.

## Changes

- `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`: added `doctor.storage`,
  added memory `undo`/`redo` options, cataloged `--history-retention` on
  memory save/update/restore-version and `--diff-against` on show-version.
  Existing `storage.compact` and workflow definition undo/redo catalog rows
  were retained.
- `Sources/RielaCLI/CLISurfaceEnumeration.swift`: classifies `doctor` as an
  expanded route and enumerates both `doctor` and `doctor storage`; discovers
  storage options from `ParsedStorageCommandArguments` and hand-parsed workflow
  definition value/flag options.
- `Sources/RielaCLI/RielaCLIApplication.swift`: documented memory retention,
  memory diff and head-move flags, definition undo/redo, `doctor storage`,
  `storage compact`, and abandoned-session reconciliation options. Dispatch
  cases were not changed.
- `Tests/RielaCLITests/SurfaceParityCLITests.swift`: added expected command and
  option coverage for the newly documented surfaces. Existing parity,
  unclassified-route and dummy-descriptor assertions remain unchanged.
- `docs/evolution-history.md`: documented compressed full/splice history,
  legacy conversion, memory defaults 2 and 1, retention range, revision versus
  version, undo/redo, shared diff and `version_not_retained`; removed the stale
  statement that automatic retention is not implemented.
- `docs/memory-history-retirement.md`: explained that automatic retention
  makes manual retirement rarely needed and that new-format retirement drops
  every non-head version.
- `docs/workflow-definition-store.md`: documented default window 10, config
  key and flag, current/last-file/live-session/24-hour former-head pins,
  `pendingBackfill`, guarded-delete limits, audit-row deletion rule,
  CLI/GraphQL undo/redo, `definition_version_not_retained`, and generation 11.
  The `retention.definitions.keepVersions` alias is documented.
- `docs/session-cancellation-and-reconcile.md`: documented abandoned nested
  invocation eligibility, `--abandoned-after-hours`, apply behavior and report.
- `docs/terminal-retention.md`: documented canonical session snapshots,
  execution rows, family-scoped payload deduplication, nested references and
  family cleanup.
- Added `docs/storage-doctor-and-compact.md` for report fields, conversion and
  reconciliation steps, resumability, full-vacuum free-space requirements,
  `--allow-live-vacuum`, the low-space `VACUUM INTO` path and bounded run-end
  vacuum.
- `Sources/RielaCLI/RielaClientFamilyArguments.swift` already contained the
  definition `undo` and `redo` enum cases from earlier work; no change was
  needed there.

## Tests added

- `SurfaceParityCLITests.testRouterAndPreParserCommandsAreBothEnumerated` now
  checks definition undo/redo, doctor, doctor storage and storage compact.
- `SurfaceParityCLITests.testOptionUniverseContainsRealFlagsAndRejectsRetiredOnes`
  now checks history retention, memory diff, abandoned threshold, compact
  batching, doctor top count, cache/KV roots and definition expected revision.
- No existing assertion was removed or weakened.

## Edit hashes

SHA-256 before and after edits (recorded before the next edit to each file):

| File | Before | After |
| --- | --- | --- |
| `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift` | `6ee5eee7410bf7a953088db83fc9063fd844726ab96814ffa2c2e51067d0862d` | `3eca3073e77afc08b7454b6ffae59d65d7ff6dfad653d6907f60477fa3ef7c9d` |
| `Sources/RielaCLI/CLISurfaceEnumeration.swift` | `404920583c4fe642cf30cb7b772b3c0f731e8e44e1225a58073d35936fbde6f8` | `a6be4eec5f4b6eb7f18b1bb3fdfb0665b7026729a0cfd0f38ebe5056cad5b9ac` |
| `Sources/RielaCLI/RielaCLIApplication.swift` | `4dc5d7004d95d0a29558207ac99ee472833dd0d5d39e6bbd540b334032c83a84` | `65bc9c84ca3d6eb5a56e2f1678fa149679fccb5939c85aaa3149328877330318` |
| `Tests/RielaCLITests/SurfaceParityCLITests.swift` | `d0c8a88903e5ce49e4d6b29a1f8e7382c3100ad84bace390dbb6107673866f21` | `72aa67c30ca3d6eb5a56e2f1678fa149679fccb5939c85aaa3149328877330318` |
| `Tests/RielaCLITests/CommandParsingTests.swift` (out of scope) | `f01ae23f07aa01c70db5507867326757fd239a7956f9e1b0a93d5146c55abd61` | `d4522d808f5ccaba0388c32e1694b248d1ae424a6955a43ee95627e081fcf189` |
| `docs/evolution-history.md` | `62b40a66a493b48b097321170ecb09ee34a5e13831f98786604a3dbf44d7b249` | `e0db37bf3d72f5f614b27a62412e98bdea6eb00be2cad291b7d135e8c4c9e7a6` |
| `docs/memory-history-retirement.md` | `e33b4b330ba12c9a1ddcb031bcba6b5c13c49bd0f9ac329589b3003e3cdfeca1` | `0dcd43a282dd0a7487ff981d3eeef2ffb29ee340a4bd1d859633e071eb75ebba` |
| `docs/workflow-definition-store.md` | `24a2b6578c9ec92caff0a5f5e7a533eaada724ef64ae6139092f76dd7deb4b7a` | `4fb7f09c5ba8fc51330dd331222f3d645d201a38883a6d4caef130514b6e151a` |
| `docs/session-cancellation-and-reconcile.md` | `1c17c75e9f8e701bb7f8de122383387522dbf91b49f019e55055166454996de4` | `3a0548a5938ba2e32f6e4094e3f20f120e9427d58792b953a2468ada7727a11c` |
| `docs/terminal-retention.md` | `1f2270a5ac071a2d5570d7a6b1df09384001e3b84c1e4e9ab63a6b52b2ce3d64` | `10e363e17ab7a4c8fe2b9cee3329a6b4bebb901d36b9ec739784bb230a0b094c` |
| `docs/storage-doctor-and-compact.md` | absent | `994bc587fdd7d24f42075a46637fc15471a23026ffeb39fea4d970295fd719fe` |

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "SurfaceParity|CommandParsingTests"'` — final exit **0**, 78 tests, 1 skipped, 0 failures; log `tmp/efficient-history/eh-11-catalog-help-docs/test-final.log`. The first run had 1 failure in 78 tests: `CommandParsingTests.testArgumentParserRegistersEveryTopLevelClientCommand` had not listed the already registered `storage` route. The assertion was updated to include it, then the same gate passed.
- `arch -arm64 /bin/zsh -lc 'swift build'` — exit **0**; log `tmp/efficient-history/eh-11-catalog-help-docs/build-final.log`.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/SurfaceCatalog+RowsCLI.swift Sources/RielaCLI/RielaCLIApplication.swift Sources/RielaCLI/CLISurfaceEnumeration.swift Sources/RielaCLI/RielaClientFamilyArguments.swift Tests/RielaCLITests/SurfaceParityCLITests.swift Tests/RielaCLITests/CommandParsingTests.swift'` — exit **0**, no diagnostics; log `tmp/efficient-history/eh-11-catalog-help-docs/swiftlint-final.log`.
- `grep -n "Automatic history retention/pruning is not implemented" docs/evolution-history.md` — exit **1**, expected no match.
- `git diff --check -- docs` — exit **0**; no output.
- Route and enum greps verified `doctor` is in `expandedRoutes` and absent from `leafRoutes`, and both definition cases exist. `git diff --check` — exit **0**.

## Deviations and open risks

### Out-of-scope edits

- `Tests/RielaCLITests/CommandParsingTests.swift` adds `storage` to the fixed
  expected top-level router set. The planned `storage` surface was already
  registered by eh-10, and the required eh-11 enumerator change made the
  existing focused command-parsing test's stale list fail. This one-item update
  was needed to run the exact plan gate; no assertion was weakened.

### Risks

- No known implementation blocker or new behavioral risk. `swift build` emitted
  existing warnings in unrelated session-family sources; strict lint on all
  touched Swift files was clean.

## Done criteria

- [x] New CLI commands and flags have catalog coverage; SurfaceParity and
  CommandParsing tests pass with a nonzero test count, and existing parity
  assertions remain intact.
- [x] `doctor` is expanded rather than a leaf, and the definition undo/redo
  enumerator tokens are present.
- [x] All six documentation pages are updated or added; `git diff --check` is
  clean.
- [x] This progress record includes changes, tests, exact commands and exit
  codes, deviations, out-of-scope edits, and open risks.
