# xs-02 UTC-day aware re-reads (segmented regular scan)

```json
{
  "planId": "xs-02-utc-day-segments",
  "planPath": "impl-plans/active/xs-02-utc-day-segments.md",
  "dependsOn": ["xs-01-options-and-depth"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/XCollectionWindow.swift",
    "Tests/RielaCLITests/XCollectionUTCDayTests.swift",
    "impl-plans/progress/xs-02-utc-day-segments.md"
  ],
  "sharedPaths": [],
  "artifactRoots": []
}
```

Artifacts: none. `.build/` is the shared SwiftPM build cache and is not owned by any
plan; no plan installs or downloads tools. Evidence logs go under the gitignored
`tmp/x-collect-author-sampling/xs-02/` and are not source.

- planId: `xs-02-utc-day-segments`
- wave: 2, dependsOn: `xs-01-options-and-depth`
- design: `design-docs/specs/design-native-source-collection.md` → "UTC-day aware
  re-reads" (Billing boundary, When it applies, segments, Order and continuation,
  Segment switch, Failure, Validation, Completion, Scope, assertions 1–12).
- progress log: `impl-plans/progress/xs-02-utc-day-segments.md`

## Intent and context

X bills a post again on each new UTC day. When a regular window starts fresh and the
previous checkpoint's complete coverage overlaps a previous UTC day, the collector must
never request that historical covered range H, yet must still collect the uncovered
suffix and prefix, resumably and truthfully. All logic lives in `XCollectionWindow`;
the collector already calls `window.needsRequest` and sets
`options.billingDayStart` (xs-01).

## Non-goals

- Do not edit `XCollectionOptions.swift`, `ProductionNodeAdapter+XCollect.swift`
  (owned by xs-03 in this wave), `XCollectionTests.swift`, lookup mode, sampling.
- No change for windows where H is empty or `billingDayStart` is nil.

## File-level changes — `Sources/RielaCLI/XCollectionWindow.swift` only

1. **H computation (fresh branch of `init`, i.e. no `pending_scan` after the
   account/query/depth reset)**: requires `previous["coverage"]` object with
   `complete == true`, same `account_id`, parseable `start`/`end` (cs, ce) and
   `options.billingDayStart = D`. `H = [max(cs,start), min(ce,end,D))`; empty ⇒
   today's scan exactly (same keys/bytes). Coverage values come from the *previous*
   checkpoint before it is overwritten.
2. **Segment keys** (only when H non-empty): `skip {start: hs, end: he}` (ISO
   strings as in `coverage`), `segment "suffix"|"prefix"`. Suffix = [he, end) with
   `search_start = wire(max(he, searchStart(since_id, start: he, end: end)))`
   (reuse `Self.searchStart`); prefix = [start, hs) with no `search_start`.
   Initial segment = suffix if non-empty else prefix; both empty ⇒ no request.
   Keep `start`, `end`, `wire_start`, `wire_end`, `window_start`, `coverage.start`
   equal to the requested window.
3. **Requests** (`arguments()`): suffix ⇒ `startTime = search_start`, `endTime =
   wire(end, upper)`, no `sinceId`; prefix ⇒ `startTime = wire(start)`, `endTime =
   wire(hs, upper:true)`, no `sinceId`. Legacy scans unchanged.
4. **Accept filter** (`acceptPage`): interval check uses the active segment
   bounds; the `since_id` filter applies only in the suffix (and in legacy scans);
   `recent_ids`, run-level `seen`, `max_id` stay shared.
5. **Segment switch** inside `acceptPage` when the suffix page has no next token and
   the prefix is non-empty: `segment = "prefix"`, `next_token = null`,
   `visited_tokens = []`, `page_count = 0`, remove `search_start`. In-memory
   `pages`/`fetched`/`bytes` are NOT reset.
6. **`needsRequest`**: legacy scans keep `pages == 0 || cursor != nil`. Skip scans:
   true iff the active segment is unstarted (`page_count == 0`, non-empty segment)
   or has a token; false when both segments are finished or both empty.
7. **Finalization (`result(at:)`)**: define `scanFinished` (legacy: `cursor == nil`;
   skip scans: no remaining segment). For skip scans not finished, ALWAYS persist
   `pending_scan` (also on a zero-page failure and on a budget stop at an unstarted
   prefix), keep committed `since_id` unchanged, `coverage.complete = false`,
   `scan_stop_reason` `gateway-failure` or `page-budget`. When finished with no
   failure: `since_id = max_id`, drop `pending_scan`, coverage complete for
   [start,end). Legacy path unchanged byte-for-byte. Report `scan_page_count` as the
   active segment's `page_count`.
8. **Pending validation** (`init`, pending branch): scans with `skip` use the
   design's rule set (hs/he ordering, segment enum and non-empty, `visited.count ==
   page_count` in 0…10000, token null ⇔ page_count 0, suffix `search_start`
   recomputed equal, prefix has none, other existing checks unchanged). Allowed key
   sets: legacy sets unchanged; add the skip variants explicitly. Pending scans
   never recompute H.

Pitfalls: (a) today a null token + `page_count` 0 is invalid for legacy scans —
keep that; (b) do not let the `since_id` filter drop prefix posts; (c) the shared
`visited_tokens` bug the review found: reset at the switch, never share; (d) `D`
must come from `options.billingDayStart`, never from `end` or `options.timezone`;
(e) zero-request completion must not set `catchup_pending` or a failure.

## Tests — `Tests/RielaCLITests/XCollectionUTCDayTests.swift` (new)

Own class + private fakes (copy helper style from `XCollectionTests.swift`); drive
`XAuthorCollector` with `clock` frozen at 2026-11-11T12:00:00Z and a recording fetch.
Implement design assertions 1–12 (`input → expected`):
1. coverage = request = [11-10T01:00Z,06:00Z), since_id at 05:00Z → 0 searches, complete, since_id retained.
2. full 11-09 day replay → 0 searches.
3. coverage [11-11T01:00Z,05:00Z), request [11-11T01:00Z,08:00Z) → request args identical to today's (since narrowing).
4. coverage [11-10T00:00Z,12:00Z), request [11-10T00:00Z,11-11T06:00Z) → one segment, startTime ≥ 11-10T12:00Z.
5. coverage [11-09T12:00Z,11-10T00:00Z), request [11-09T00:00Z,11-11T06:00Z), since at 11-09T18:00Z → suffix startTime 11-10T00:00Z; prefix [11-09T00:00Z,12:00Z) without sinceId; no request overlaps H.
6. coverage [11-09T12:00Z,11-11T06:00Z), request [11-09T00:00Z,11-11T06:00Z) → suffix [11-11T00:00Z,06:00Z) + prefix.
7. case 5, maxPages 1, suffix returns a token → persisted `segment:"suffix"`+`skip`; next run (later clock) sends that token, then prefix; never H.
8. existing `XCollectionTests` green (run in verification).
9. case 5, maxPages 2, suffix page 1 no token → page 2 is prefix's first request (no nextToken); complete.
10. case 5, maxPages 1, suffix ends without token → persisted prefix-unstarted state validates; next run's first request is prefix; a repeated token within a segment is rejected.
11. first suffix request fails → pending_scan with skip, segment suffix, null token, page_count 0, unchanged since_id; coverage incomplete; retry never requests H.
12. suffix completes, first prefix request fails → segment prefix, max_id kept; retry requests only prefix; on completion since_id = max_id.
Also: `billingDayStart` nil (direct window construction) → legacy behavior.

## Concurrency / drift protocol

Runs beside xs-03 (disjoint files). Record pre/post SHA-256 of each owned file per
edit in the progress log; on unexpected drift re-read and re-apply only this intent.
No git index/branch operations.

## Verification (evidence under `tmp/x-collect-author-sampling/xs-02/`)

1. `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/x-collect-author-sampling/xs-02/build.log 2>&1` → exit 0 (if it fails only in xs-03-owned files, record it and rerun after that plan lands).
2. `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter 'XCollectionUTCDayTests|XCollectionTests|XCollectionReferenceDepthTests'" > tmp/x-collect-author-sampling/xs-02/test.log 2>&1` → exit 0, 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/XCollectionWindow.swift Tests/RielaCLITests/XCollectionUTCDayTests.swift' > tmp/x-collect-author-sampling/xs-02/lint.log 2>&1` → no violations in these files.

## Done criteria

- Only the two owned source/test files plus the progress log changed by this plan.
- Assertions 1–7 and 9–12 exist as named test methods and pass; existing tests unchanged and green.
- Progress log lists commands, exit codes, log paths and hashes.
