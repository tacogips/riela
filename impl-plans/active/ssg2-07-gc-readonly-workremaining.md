# ssg2-07-gc-readonly-workremaining: read-only expired snapshot removal + compact workRemaining

**planId**: ssg2-07-gc-readonly-workremaining
**dependsOn**: ssg2-06-default-retention-review-isolation (wave W2)
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§1.2 (defects 2 and 3), §10.1, §10.2, §11 (isolation), §12 row (g); QA Q9
**Shared rules**: `impl-plans/active/ssg2-session-storage-gc.md` → "Shared execution rules"
**Progress log**: `impl-plans/progress/ssg2-07-gc-readonly-workremaining.md`
**Evidence root**: `tmp/ssg2/ssg2-07-gc-readonly-workremaining/`
**writePaths**: `Sources/RielaCore/RielaDataGarbageCollector.swift`, `Sources/RielaCLI/RielaRetentionService.swift`, `Sources/RielaCLI/StorageCompactCommand.swift`, `Tests/RielaCoreTests/RielaDataGarbageCollectorTests.swift`, `Tests/RielaCLITests/GarbageCollectionCommandTests.swift`, `Tests/RielaCLITests/StorageCompactCommandTests.swift`, `impl-plans/progress/ssg2-07-gc-readonly-workremaining.md`
**sharedPaths**: none

## Intent and context

Two defects seen on a real store:

1. `riela gc` reports the whole store `failed` because expired
   `~/.riela/workflow-history/*/snapshots/registry-before-*` directories are
   read-only (`dr-xr-xr-x`, files `r--r--r--`).
   `RielaDataGarbageCollector.remove` (`Sources/RielaCore/RielaDataGarbageCollector.swift:511-531`)
   calls `removeItem` once and records the error as a diagnostic, and
   `RielaRetentionService` marks the target `failed` whenever a generated
   diagnostic exists (`Sources/RielaCLI/RielaRetentionService.swift:~300-303`).
2. `riela storage compact --apply` reports `workRemaining: true` forever:
   it is set by a failed retention pass (`Sources/RielaCLI/StorageCompactCommand.swift:301`)
   and by `live`/`skipped` abandoned-invocation verdicts (`:265`), neither of
   which is conversion or reclamation work.

ssg2-06 (dependency) already isolated these suites with
`RielaCLIIsolatedEnvironment`; keep using it.

## Non-goals

- No change to handover git-ref collection, log pruning, retention planning,
  tombstones or protections.
- No change to the generated-sweep default gate (`sources.results != .builtInDefault`).
- Do not touch `AutomaticRetentionHook.swift` (it already prints only
  `failed` targets).
- No exit-code changes for `riela gc` or `storage compact` beyond the
  `failed` status no longer being set for unremovable paths.

## File-level changes

### 1. `Sources/RielaCore/RielaDataGarbageCollector.swift`

- `RielaGarbageCollectionReport`: add `public var warnings: [String]`
  (non-fatal unremovable paths), defaulting to `[]` in `init`. If any code
  decodes this report, decode `warnings` with `decodeIfPresent ?? []`.
  `diagnostics` keeps its meaning (collector-level errors).
- `remove(_:dryRun:report:countsAsSession:)`, non-dry-run only (design §10.1):
  1. Try `removeItem` as today.
  2. On failure, restore permissions and retry once, only when the entry is
     not a symbolic link, the resolved path of its parent lies inside the
     resolved collection root (pass the root into `remove`; compare
     `resolvingSymlinksInPath().path` with a trailing `/`), and the entry is
     owned by `geteuid()`.
  3. Restoration walks top-down without following symbolic links (check each
     node with `attributesOfItem(atPath:)`, which does not follow the final
     link; never descend into a link). For the entry and each descendant
     **directory** owned by `geteuid()`, add `S_IRWXU` when missing. Do not
     change files, nodes owned by another uid, or the entry's parent.
  4. If the retry fails or step 2 does not apply, append
     `"<path>: <error>"` to `report.warnings` (not `diagnostics`) and return
     `false`.

### 2. `Sources/RielaCLI/RielaRetentionService.swift` (generated-sweep block only)

Append `generated.warnings` to the target's `warnings` without changing
`status`. Keep `status = "failed"` only for non-empty filtered
`diagnostics`.

### 3. `Sources/RielaCLI/StorageCompactCommand.swift`

Make `workRemaining` follow design §10.2:

- line ~265: abandoned-invocation verdicts no longer set `workRemaining`
  (they stay in `reconciled`);
- line ~301: a failed or busy retention pass adds the warning
  `retention pass reported failure: <first target warning>` (or
  `retention target busy` for a `busy` target) and no longer sets
  `workRemaining`;
- every other existing `workRemaining = true` / `remaining = true` site
  (batch limit, lock-held or failed conversions, memory remaining, pin
  backfill failure, dry-run estimate, reclaimer states) stays.

## Pitfalls

- Never chmod through a symbolic link and never touch anything outside the
  collection root (`<home>/.riela` or `<project>/.riela`).
- Directories need owner `rwx` to list and unlink children; files do not need
  write permission to be unlinked.
- Restore permissions top-down; a directory without `r`/`x` cannot be
  enumerated until it is fixed.
- Dry runs must not change any mode.
- Tests must restore modes in teardown so temporary directories can be
  deleted.

## Tests (temporary HOME/stores only, via `RielaCLIIsolatedEnvironment`)

`Tests/RielaCoreTests/RielaDataGarbageCollectorTests.swift`:

- expired `snapshots/registry-before-x` (mode `0555`, `0444` files, `0555`
  subdirectory; set old mtimes before making read-only) → removed;
  `diagnostics` and `warnings` empty;
- symbolic link inside that entry pointing at a read-only directory outside
  the root → link removed; outside directory keeps its mode and contents;
- parent `snapshots/` made `0555` → entry reported once in `warnings`,
  `diagnostics` empty; an expired entry in another `snapshots/` directory is
  still removed;
- `dryRun: true` on the read-only entry → modes unchanged, nothing removed.

`Tests/RielaCLITests/GarbageCollectionCommandTests.swift`:

- `riela gc --results-max-age-days 1 --output json` with the read-only expired
  entry → exit 0, target `completed`, entry removed;
- same with an unremovable entry (parent `0555`) → exit 0, target
  `completed`, warning names the path.

`Tests/RielaCLITests/StorageCompactCommandTests.swift`:

- store whose only issue is the unremovable generated path, nothing to
  convert → `--apply` reports `workRemaining: false` and lists the warning;
- second `--apply` on a converted, reclaimed store → `workRemaining: false`,
  0 converted, 0 reclaimed;
- live nested invocation (`live` verdict) → `workRemaining: false`;
- lock-held legacy session → `workRemaining: true` (unchanged behavior).

## Acceptance criteria

- `rg -n "public var warnings" Sources/RielaCore/RielaDataGarbageCollector.swift` → one match.
- `rg -n "retention pass reported failure" Sources/RielaCLI/StorageCompactCommand.swift` → no assignment to `workRemaining` on that line.
- All tests above pass.

## Verification (each must exit 0)

```
mkdir -p tmp/ssg2/ssg2-07-gc-readonly-workremaining
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/ssg2/ssg2-07-gc-readonly-workremaining/build.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-07-gc-readonly-workremaining/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "RielaDataGarbageCollector|GarbageCollection|StorageCompact|RielaRetentionService" 2>&1 | tee tmp/ssg2/ssg2-07-gc-readonly-workremaining/test.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-07-gc-readonly-workremaining/test.log; exit $s'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCore/RielaDataGarbageCollector.swift Sources/RielaCLI/RielaRetentionService.swift Sources/RielaCLI/StorageCompactCommand.swift Tests/RielaCoreTests/RielaDataGarbageCollectorTests.swift 2>&1 | tee tmp/ssg2/ssg2-07-gc-readonly-workremaining/lint.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-07-gc-readonly-workremaining/lint.log; exit $s'
```

Evidence: logs end with `exit=0`; `test.log` shows the new cases executed
with 0 failures.

## Progress log

Record in `impl-plans/progress/ssg2-07-gc-readonly-workremaining.md`:
pre/post sha256, commands with exit codes and log paths, the list of
`workRemaining` sites kept and removed, and reconciliation items.
