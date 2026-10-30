# ypb-01: riela/durable-queue `pending` gains `limit` and `maxAttempts`

```json
{
  "planId": "ypb-01-durable-queue-pending",
  "planPath": "impl-plans/active/youtube-processing-builtins-01-durable-queue-pending.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "Sources/RielaCLI/ProductionNodeAdapter+DurableQueue.swift",
    "Tests/RielaCLITests/DurableQueueTests.swift",
    "docs/workflows/durable-queue.md",
    "impl-plans/progress/ypb-01-durable-queue-pending.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design source: `design-docs/specs/design-youtube-processing-builtins.md` §C.

ART needs to take several pending requests from one durable queue at once, and
to stop retrying requests that already failed too often. Today the `pending`
action in `riela/durable-queue` returns only one item: `found`, `identity` and
`request`. Its code is in `Sources/RielaCLI/ProductionNodeAdapter+DurableQueue.swift`
in `DurableQueue.apply`, case `.string("pending")`. That case selects
`candidates.min` with this comparator:

1. `attempted` ascending, where never-attempted rows use `.distantPast`;
2. then `registered` ascending;
3. then identity bytes, compared lexicographically.

Each journal row stores `attempts`, an integer in 0…1,000,000,000.

## Non-goals

- No journal schema change. No new action. `pending` stays a read-only
  transaction: `readOnly: config["action"] == .string("pending")`.
- Do not change `admit`, `attempted` or `finish` semantics, or the limits of
  10,000 rows, 256 KiB and `DurableQueueJournal.maximumBytes`.
- Do not touch `Sources/RielaCLI/DurableQueueJournal.swift`.

## File-level changes

### `Sources/RielaCLI/ProductionNodeAdapter+DurableQueue.swift`

- `executeDurableQueue`: add `"limit"` and `"maxAttempts"` to the outer
  `Set(config.keys).isSubset(of:)` allowlist.
- `DurableQueue.validateOperation`: the optional field set for `pending` becomes
  `["limit", "maxAttempts"]`; `finish` keeps `["completionField"]`.
  - `limit` must be `.integer` in 1…100.
  - `maxAttempts` must be `.integer` in 1…1,000,000,000.
  - Any other type or value, including `.number(2.0)`, throws
    `durableQueueInvalid()`.
  - Other actions still reject both keys.
- `DurableQueue.apply`, `pending` case:
  - Sort the candidates once with the existing comparator, extracted to a
    private function. Do not change its order.
  - When `maxAttempts` is present, split the candidates into eligible
    (`attempts < maxAttempts`) and exhausted.
  - `found`, `identity` and `request` come from the first eligible row, or
    `false`/`.null`/`.null`.
  - With `limit`, add `items`: an array of
    `{"identity", "request", "attempts"}` objects for the first `limit`
    eligible rows. Before appending each item, check that the encoded result
    would stay `<= DurableQueueJournal.maximumBytes`. If it would not, stop and
    set `"itemsTruncated": true`. Otherwise `itemsTruncated` is `false`.
  - With `maxAttempts`, add `"exhausted"`: an array of `{identity, attempts}`
    sorted by identity bytes, the same `Data(...utf8).lexicographicallyPrecedes`
    as the comparator. Also add `"exhaustedCount"` as an integer.
  - Without either option, the result is exactly the existing three keys.

### `Tests/RielaCLITests/DurableQueueTests.swift`

Add the tests listed in the Tests section below. Imitate the existing tests,
which call `DurableQueue.apply` directly and go through the resolver in
`testRealResolverUsesLiteralJSONAndRejectsInvalidOperationBeforeIO`.

### `docs/workflows/durable-queue.md`

- Action table row for `pending`: inputs become `optional limit (1–100),
  maxAttempts (1–1e9)`. Results become: `found`, nullable `identity`/`request`;
  plus `items`/`itemsTruncated` with `limit`; plus `exhausted`/`exhaustedCount`
  with `maxAttempts`.
- Add one paragraph covering:
  - items follow the selection order;
  - exhausted rows stay `pending` and are reported on every call until
    `finish`;
  - the default output is unchanged.

## Invariants and pitfalls

- Do not mutate rows during `pending`. The returned state must equal the input
  state, so the read-only journal transaction writes nothing.
- `completed` and legacy `acquired` rows are never candidates, so they never
  appear in `items` or `exhausted`.
- `limit` greater than the eligible count returns all eligible rows and
  `itemsTruncated: false`.
- Size check: encode the whole result object with the candidate item appended.
  Do not sum item sizes.
- Do not reorder the existing comparator's tie-breaks.

## Tests (situation → expected)

- No options → result keys are exactly {found, identity, request}, and the
  values equal what the code returns before this change (existing tests stay
  unmodified and green).
- 3 pending rows (one never attempted, two attempted at different times),
  `limit: 2` → `items` holds the never-attempted row, then the
  oldest-attempted row. `identity` equals `items[0].identity`, and
  `itemsTruncated` is false.
- `limit: 10` with 2 pending rows → 2 items.
- `maxAttempts: 2` with rows at attempts 0, 2 and 5 →
  - selection uses only the attempts-0 row;
  - `exhausted` contains the 2 rows in identity-byte order, each with
    `attempts`;
  - `exhaustedCount` is 2.
- `maxAttempts` where every row is exhausted → `found: false`, null
  identity/request, and `exhausted` lists them.
- `limit` + `maxAttempts` combined → items contain only eligible rows.
- A completed row with attempts ≥ maxAttempts → not in `exhausted`.
- `limit: 0`, `limit: 101`, `limit: "2"`, `maxAttempts: 0` → `durableQueueInvalid`.
- `limit` on `admit`/`attempted`/`finish` → `durableQueueInvalid`.
- Through the real resolver, with `pending` + `limit` on an absent queue
  directory → `found: false`, `items: []`, and no files created.
- Items large enough that the next one would exceed the byte bound (use
  near-256 KiB requests) → `itemsTruncated: true`, and items count is at
  least 1.

## Verification (evidence)

```bash
mkdir -p tmp/youtube-processing-builtins/ypb-01
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/youtube-processing-builtins/ypb-01/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter DurableQueueTests > tmp/youtube-processing-builtins/ypb-01/test.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache "Sources/RielaCLI/ProductionNodeAdapter+DurableQueue.swift" Tests/RielaCLITests/DurableQueueTests.swift > tmp/youtube-processing-builtins/ypb-01/swiftlint.log 2>&1'
git diff --quiet -- Sources/RielaCLI/DurableQueueJournal.swift
```

What each command must show:

- After this plan's final owned edit, build and test must reach exit 0 with 0
  failures at least once. The only exception is a recorded
  `deferred-to-integration` entry whose diagnostics are all in non-owned files.

- build: exit 0.
- test: exit 0 and 0 failures; the log lists the new test names.
- swiftlint: exit 0 with an empty log.
- the final `git diff --quiet`: exit 0.

## Working protocol

### Shared-wave build protocol

Sibling plans in the same wave edit Swift sources in this same working
directory at the same time. `swift build` and `swift test` compile the whole
package, so a sibling's half-finished edit can break your build.

- Diagnostics only in non-owned files. When build or test fails and every
  compiler diagnostic points at a file outside this plan's `writePaths` and
  `sharedPaths`:
  - never edit, revert or reformat that file;
  - append a progress-log row with status `blocked-by-sibling`, the file path,
    the first diagnostic line, the log path and the UTC time;
  - wait about 60 seconds, then re-run the same command in the foreground, at
    most 6 times.
- SwiftPM lock. The message `Another instance of SwiftPM is already running
  using '.build'` means lock contention, not failure. Let the command run to
  exit.
- Owned files. A diagnostic in a file this plan owns is always this plan's to
  fix.
- Persistent block. If the block remains after the bounded re-runs:
  - finish all owned-file work;
  - record status `deferred-to-integration`, naming the blocking file and the
    last log path;
  - stop without touching that file.

  Cross-plan breakage is repaired serially after the wave joins, and the
  dispatch manifest's `integrationVerification` is the authoritative full gate.

Before each edit:

1. Read the file fresh.
2. Record its SHA-256 in the progress log, together with a one-line intent.
3. If the hash changed since the intent snapshot, re-read the file and
   re-apply the edit. Never revert foreign edits.

Further rules:

- Edit only `writePaths`.
- Do not run any git write commands. Do not create worktrees or branches.
- Put scratch files only under `tmp/youtube-processing-builtins/ypb-01/`.

## Done criteria

- Every test in the Tests section exists and passes.
- `grep -n '"maxAttempts"' Sources/RielaCLI/ProductionNodeAdapter+DurableQueue.swift` matches in both the allowlist and the validation code.
- The docs table mentions `limit` and `maxAttempts`.
- `impl-plans/progress/ypb-01-durable-queue-pending.md` contains:
  - the changed files with pre/post SHA-256;
  - a verification table with command, exit status, tests run, failures and
    log path.
