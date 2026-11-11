# xs-03 Per-author sampling (`authorSampling`, `authorDailyPostThreshold`)

```json
{
  "planId": "xs-03-author-sampling",
  "planPath": "impl-plans/active/xs-03-author-sampling.md",
  "dependsOn": ["xs-01-options-and-depth"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/XCollectionSampling.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+XCollect.swift",
    "Tests/RielaCLITests/XCollectionSamplingTests.swift",
    "impl-plans/progress/xs-03-author-sampling.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. `.build/` is the shared SwiftPM build cache and is not owned by any
plan; no plan installs or downloads tools. Evidence logs go under the gitignored
`tmp/x-collect-author-sampling/xs-03/` and are not source.

- planId: `xs-03-author-sampling`
- wave: 2, dependsOn: `xs-01-options-and-depth`
- design: `design-docs/specs/design-native-source-collection.md` → "Per-author
  sampling" (all paragraphs: Sampled set, Deterministic draw, Sampled read, Query
  change, Auto-sampling state, Output metadata, Validation).
- progress log: `impl-plans/progress/xs-03-author-sampling.md`

## Intent and context

Two prolific authors used two thirds of ART's page budget and the user's X spend.
Configured handles (never hard-coded) are read only in a deterministic fraction of
runs, outside the regular query, and only for that run's window. Options are already
parsed by xs-01: `options.authorSampling: [String: Double]?` (lowercased keys),
`options.authorDailyPostThreshold: Int?`, `options.billingDayStart`.

## Non-goals

- Do not edit `XCollectionOptions.swift`, `XCollectionWindow.swift` (xs-02 owns it in
  this wave), `XCollectionTests.swift`, lookup mode, docs.
- No new options, no persistence outside the returned checkpoint.

## File-level changes

### `Sources/RielaCLI/XCollectionSampling.swift` (new)
Pure, testable helpers (internal visibility, `enum XCollectionSampling` namespace):
- `static func drawValue(handle: String, end: String) throws -> Double` — first 8 bytes
  of SHA-256(UTF-8(lowercase(handle) + "\n" + canonicalEnd)) big-endian / 2^64;
  `canonicalEnd = ISO8601DateFormatter().string(from: xInstant(end))`. Use
  `CryptoKit`/existing SHA helper (`JSONCanonical.sha256Hex` → parse first 16 hex).
  Never `Hasher`.
- `static func drawn(probability:value:) -> Bool` = `value < probability`.
- State codec for `author_sampling` (version 1, timezone, auto_day, auto, through,
  pending, days) with strict validation (malformed ⇒ `xCollectionInvalid()` when the
  threshold is set); bounded to handles in `authorHandles`; `days` pruned to the last 7
  calendar days of `end` in `options.timezone`; `pending` keyed by 24-hex SHA-256 of
  `author_query`.
- Effective probabilities: explicit entry wins; else frozen auto entry; recompute auto
  set only when `end`'s day (options.timezone) ≠ `auto_day` or no state, using the
  pre-run state; volume = Σposts/Σseconds×86400 only when Σseconds ≥ 86400; keep the
  previous auto entry when not evaluable.
- Count-interval application per design (regular scan pending tally vs completion;
  sampled complete vs truncated `[t_old, end)`; failures count nothing;
  `through[h]` only moves forward; bucket = calendar day of interval end).
- Metadata builder for output `sampling` {version, threshold, day, handles[] sorted by
  lowercase handle with handle/source/probability/observedDailyVolume/status/fetchedCount/truncated}.

### `Sources/RielaCLI/ProductionNodeAdapter+XCollect.swift` (`XAuthorCollector.collect`)
Ordered steps (design "Bucket and order"):
1. Strip `author_sampling` from `options.previous` ALWAYS before windows (single-shard
   windows otherwise carry it through `checkpoint = previous`). Load/validate it only
   when the threshold is set.
2. Compute effective sampled set; regular handles = `authorHandles` minus sampled;
   rebuild groups/scope from the regular handles (set `options.handles` on a local copy
   before using `.groups`/`.scope`). Pitfall: `groups` returns `[[]]` for zero handles —
   handle "all sampled" explicitly: no regular search, minimal checkpoint per design.
3. Regular windows exactly as today (xs-01 already sets `billingDayStart`).
4. Drawn handles packed into 512-byte `from:` groups; each read through a fresh
   `XCollectionWindow` with `previous: [:]`, `maxPages 1`, `maximum = pageSize`,
   `fresh = false`, `start/end = options.start/end`, via existing `read(…, label: "sampled")`.
   A sampled failure appends a `failures` entry with `stage: "sampled"` and never fails
   the run; a leftover token is not persisted (`truncated: true`).
5. Merge sampled posts after regular posts; existing run-level ID dedup; post-count
   guard becomes `maxPosts + pageSize × drawnGroupCount`; 6 MB / 8 MB limits unchanged.
6. Apply counts (regular shards in index order, then sampled groups), prune, attach
   `author_sampling` to the final checkpoint (single or combined) only when the
   threshold is set. `complete`/`coverage` describe only the regular query.
7. Add output `sampling` only when `authorSampling` or the threshold is present.

Pitfalls: without both options the code path, checkpoint bytes and output keys must be
identical to today (guard every step); head-probe posts are never counted; attribution
by `author.username` case-insensitively, unknown/absent author not counted.

### `Tests/RielaCLITests/XCollectionSamplingTests.swift` (new)
Own class, private fakes, frozen clock. Cases (`input → expected`):
- same (handle,end) → same `drawValue`; 4000 distinct ends at p=0.25 → drawn fraction in [0.22,0.28]; p=0 never, p=1 always; handle case-insensitive.
- `authorSampling {"Bob":0.25}`, handles [alice,bob,carol] → every regular search query lacks `from:bob`; `author_query`/checkpoint lack bob.
- drawn bob → separate search with query `from:bob`, `startTime` wire(start), `endTime` wire(end), no `nextToken`/`sinceId`, maxResults = pageSize; posts merged with `_fetched_at`/`_account_id`; next token on that page → `truncated:true`, not in checkpoint.
- skipped bob → no bob search; metadata status `skipped`.
- sampled read failure → `failures` has `stage:"sampled"`, run succeeds, `complete` reflects regular only.
- threshold 10 with state showing bob 40 posts over 86400 s, new day → auto p = 0.25, `source:"auto"`; explicit `{"bob":0.5}` overrides (`source:"explicit"`, 0.5).
- same-day second run with changed volumes → auto set unchanged (frozen until day changes).
- query change from sampling with a pending token for the old query → no invalid-cursor error, fresh scan from `start` (not `earliest`), no `nextToken` sent.
- all handles sampled → no regular search; minimal checkpoint with `author_query: ""` and coverage complete.
- replayed completed window does not double count (40/day stays 40/day); truncated sampled page counts only [t_old,end).
- malformed `previous.author_sampling` with threshold → invalid before any search; without threshold the key is dropped from the output checkpoint.
- no new options → output has no `sampling` key and checkpoint equals the pre-change checkpoint for the same fake inputs.

## Concurrency / drift protocol

Runs beside xs-02 (disjoint files). Pre/post SHA-256 per edit in the progress log;
re-read and re-apply only this intent on drift. No git index/branch operations.

## Verification (evidence under `tmp/x-collect-author-sampling/xs-03/`)

1. `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/x-collect-author-sampling/xs-03/build.log 2>&1` → exit 0 (record and rerun if blocked only by xs-02 files).
2. `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'XCollectionSamplingTests|XCollectionTests|XCollectionReferenceDepthTests'" > tmp/x-collect-author-sampling/xs-03/test.log 2>&1` → exit 0, 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/XCollectionSampling.swift Sources/RielaCLI/ProductionNodeAdapter+XCollect.swift Tests/RielaCLITests/XCollectionSamplingTests.swift' > tmp/x-collect-author-sampling/xs-03/lint.log 2>&1` → no violations in these files.

## Done criteria

- `git grep -n "Hasher" Sources/RielaCLI/XCollectionSampling.swift` → no match.
- Every case above is a named passing test; existing tests unchanged and green.
- Progress log lists commands, exit codes, log paths and hashes.
