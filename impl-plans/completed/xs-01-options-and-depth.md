# xs-01 x-collect options contract and `referenceDepth`

```json
{
  "planId": "xs-01-options-and-depth",
  "planPath": "impl-plans/active/xs-01-options-and-depth.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCLI/XCollectionOptions.swift",
    "Sources/RielaCLI/XCollectionWindow.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+XCollect.swift",
    "Tests/RielaCLITests/XCollectionReferenceDepthTests.swift",
    "impl-plans/progress/xs-01-options-and-depth.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. `.build/` is the shared SwiftPM build cache and is not owned by any
plan; no plan installs or downloads tools. Evidence logs go under the gitignored
`tmp/x-collect-author-sampling/xs-01/` and are not source.

- planId: `xs-01-options-and-depth`
- wave: 1 (contract plan), dependsOn: none
- design: `design-docs/specs/design-native-source-collection.md` — options table,
  "Per-author sampling → Validation", "Reference depth" (incl. "Depth identity"),
  "UTC-day aware re-reads → Billing boundary" (only the frozen `D` plumbing).
- progress log: `impl-plans/progress/xs-01-options-and-depth.md` (only this plan writes it)

## Intent and context

The user hit their X spend cap. `riela/x-collect` (search mode) must accept three
new options and cut billable expansions with `referenceDepth`. This plan is the
first-wave contract: it pins every new `XCollectionOptions` field, the depth-aware
selection, the depth continuation identity, the frozen billing day and a
`needsRequest` seam in the read loop. xs-02 (UTC-day segments) and xs-03
(sampling) build on these exact shapes in wave 2 and must not need to edit
`XCollectionOptions.swift`.

## Non-goals

- No sampling logic (draw, state, metadata, regular-query filtering) — xs-03.
- No UTC-day exclusion / `skip` / `segment` logic — xs-02. This plan only stores `D`.
- No change to lookup mode (`XLookupCollection.swift` must not be edited) or to
  `XCollectionOptions.postFields(depth:links:coverage:)` (lookup still calls it).
- No docs/README edits (xs-04). No edits to `XCollectionTests.swift`.

## File-level changes

### `Sources/RielaCLI/XCollectionOptions.swift`
1. Add `"authorSampling"`, `"authorDailyPostThreshold"`, `"referenceDepth"` to the
   allowed key set in `init(_:)`.
2. New stored properties (exact names/types — contract for xs-02/xs-03):
   - `let authorSampling: [String: Double]?` — nil when the key is absent; keys
     lowercased handles; values in [0,1].
   - `let authorDailyPostThreshold: Int?` — nil when absent; 1…100000.
   - `let referenceDepth: Int` — effective depth, 2 when absent.
   - `let customSelection: Bool` — true iff `select` was supplied.
   - `var billingDayStart: Date?` — UTC 00:00 of the execution clock's day; set
     by the collector, nil by default (nil ⇒ UTC-day rule disabled).
   - computed `var depthIdentity: Int?` — `nil` when `customSelection` or
     `referenceDepth == 2`, else `referenceDepth`. This is the value written as
     checkpoint `reference_depth`.
3. Validation (throw `xCollectionInvalid()`; all before any provider call):
   - `authorSampling` not an object; key not matching a handle in `authorHandles`
     case-insensitively; two keys equal case-insensitively; value not
     `.integer` 0/1 or `.number` in [0,1] (reject NaN/inf, negative, >1, strings, bools).
   - `authorDailyPostThreshold` not `.integer` in 1…100000.
   - `referenceDepth` not `.integer` in 0…2; `referenceDepth` present together
     with `select` (even if 2).
4. New `static func postFields(level: Int, referenceDepth: Int, links: Bool, coverage: Bool) -> JSONObject`
   implementing the design rule: base fields always; `references {id relation}`
   when `level == 0 || level < referenceDepth`; `quote`/`repost` = level+1 selection
   when `level < referenceDepth`. Default selection (no `select`) uses
   `postFields(level: 0, referenceDepth: referenceDepth, …)`.
   Pitfall: depth 2 must be *byte-identical* to today's
   `postFields(depth: 0, links:coverage:)` for all four links/coverage combos.

### `Sources/RielaCLI/XCollectionWindow.swift`
1. Depth identity in `init(options:query:account:previous:)`: read
   `previous["reference_depth"]` — absent ⇒ 2; `.integer(0|1)` ⇒ that value;
   anything else ⇒ `xCollectionInvalid()`. Effective = `options.depthIdentity ?? 2`.
   Extend the existing reset condition (`account_id`/`author_query` mismatch ⇒
   keep only `config_key`) with "previous depth ≠ effective depth". Imitate the
   existing `previous.filter { $0.key == "config_key" }` branch exactly.
2. `result(at:)`: set `reference_depth` = `.integer(depthIdentity)` when
   `options.depthIdentity != nil`, otherwise remove the key. Default path output
   must not gain the key.
3. Add `var needsRequest: Bool { pages == 0 || cursor != nil }` (legacy semantics,
   xs-02 will redefine it inside this file). No other behavior change.

### `Sources/RielaCLI/ProductionNodeAdapter+XCollect.swift` (`XAuthorCollector`)
1. In `collect`, read `clock()` once at the start and compute
   `billingDayStart` = UTC start of that day (`Calendar(identifier: .gregorian)`
   with `TimeZone(identifier: "UTC")`, not `options.timezone`). Assign it to every
   per-group `child` options before `XCollectionWindow` creation (head windows
   derive from `window.options`, so they inherit it).
2. In `read(_:shard:label:failures:fetch:)` replace the loop condition
   `window.pages == 0 || window.cursor != nil` with `window.needsRequest`.
   Keep `window.pages < window.options.maxPages` and the budget guard unchanged.
3. Do not touch the rest of `collect` (xs-03 owns its sampling edits in wave 2).

### `Tests/RielaCLITests/XCollectionReferenceDepthTests.swift` (new)
Own `final class XCollectionReferenceDepthTests: XCTestCase` with private fakes
(imitate `Tests/RielaCLITests/XCollectionTests.swift:options()/previous()/page()`
helpers by copying, not by editing that file). Cases:
- depth 2 / absent: default `selection` == `["posts": postFields(depth:0,…), "pageInfo": …]`
  for links/coverage ∈ {false,true}² → equal.
- depth 1: `posts.quote` exists and has no `quote`/`repost`/`references`; root has `references`.
- depth 0: root has `references`, no `quote`/`repost`.
- validation → throws: `referenceDepth` 3, -1, "2", 1.5; `referenceDepth`+`select`;
  `authorSampling` {"unknown":0.5}, {"Bob":0.5,"bob":0.2}, {"bob":1.5}, {"bob":-0.1},
  {"bob":"0.5"}, `[]`; threshold 0, 100001, 2.5. Accepts {"BOB":0}, {"bob":1}, {"bob":0.25}, threshold 1.
- parsed values: `authorSampling` keys lowercased; absent ⇒ nil; threshold nil when absent.
- depth identity (collector with fake fetch, frozen `clock`):
  - depth-2 checkpoint with `pending_scan` token run with depth 0 → first search has
    no `nextToken`, no `sinceId`, `startTime` == wire(start); result has `reference_depth: 0`.
  - completed depth-2 checkpoint (with `since_id`) run with depth 1 → no `sinceId`/no
    since-derived `startTime`; `startTime` == wire(start).
  - depth-0 pending checkpoint run with depth 0 → exact token continued.
  - legacy pending checkpoint run with absent and with explicit 2 → token continued;
    result has no `reference_depth` key.
  - `previous.reference_depth: 2` or `"0"` → invalid input before any search.
- `XCollectionOptions` parsed from any valid input → `billingDayStart == nil` (the
  collector-side assignment is exercised end-to-end by xs-02 assertion 1, which fails
  if `D` is not plumbed). Add no extra API just for testing it.

## Invariants

- Without the three new options: selection, request arguments, checkpoint bytes
  and output keys are unchanged; all existing `XCollectionTests` and
  `XLookupCollectionTests` pass unmodified.
- Custom `select` behavior unchanged (a changed `select` still continues a cursor;
  no `reference_depth` written).
- Never send a provider token after a depth change.

## Concurrency / drift protocol

Wave 1 runs beside xs-04 (disjoint files). Before each edit re-read the file and
record its SHA-256 in the progress log; after the edit record the new hash. If a
pre-edit hash differs from the last recorded one, stop, re-read and re-apply only
this plan's intent. Never run git commands that modify the index or branches.

## Verification (evidence under `tmp/x-collect-author-sampling/xs-01/`)

1. `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/x-collect-author-sampling/xs-01/build.log 2>&1` → exit 0.
2. `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'XCollectionReferenceDepthTests|XCollectionTests|XLookupCollectionTests'" > tmp/x-collect-author-sampling/xs-01/test.log 2>&1` → exit 0, 0 failures, new class executed.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/XCollectionOptions.swift Sources/RielaCLI/XCollectionWindow.swift Sources/RielaCLI/ProductionNodeAdapter+XCollect.swift Tests/RielaCLITests/XCollectionReferenceDepthTests.swift' > tmp/x-collect-author-sampling/xs-01/lint.log 2>&1` → no new violations in these files.

## Done criteria

- All properties in "File-level changes §XCollectionOptions 2" exist with exact names/types.
- `git grep -n "needsRequest" Sources/RielaCLI` shows the window property and the read-loop use.
- `git diff --stat -- Tests/RielaCLITests/XCollectionTests.swift Sources/RielaCLI/XLookupCollection.swift` is empty.
- Verification 1–3 pass; progress log lists commands, exit codes, log paths and file hashes.

## Implementation status

Completed and accepted (2026-11-11): Step 6 verification, adversarial review and combined-tree integration review passed (50 tests, 0 failures); see `impl-plans/progress/xs-01-options-and-depth.md`.
