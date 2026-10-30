# ypb-02: riela/youtube-collect `excludeLive` and `maxDurationSeconds`

```json
{
  "planId": "ypb-02-youtube-collect-filters",
  "planPath": "impl-plans/active/youtube-processing-builtins-02-youtube-collect-filters.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "Sources/RielaCLI/YouTubeCollection.swift",
    "Tests/RielaCLITests/YouTubeCollectionTests.swift",
    "docs/workflows/youtube-collection.md",
    "impl-plans/progress/ypb-02-youtube-collect-filters.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design source: `design-docs/specs/design-youtube-processing-builtins.md` §D.
Baseline: `design-native-source-collection.md` §YouTube.

ART has to drop live, upcoming and overly long videos from collected
metadata. `YouTubeCollection.collect` in `Sources/RielaCLI/YouTubeCollection.swift`
builds `records[id]` with `liveBroadcastContent` and `durationSeconds`. It then
returns `["videos": explicitOrder + orderedChannelIDs, "failures", "requests"]`.

This plan also has one contract duty for ypb-08: make two existing helpers
visible inside the module.

## Contract for ypb-08 (must be done exactly)

In `YouTubeCollection.swift`, inside the existing
`#if canImport(YouTubeGatewayCore)` block, change only the access level:

- `private func handleYouTubeRequestError(_ error: Error) throws` becomes
  `func handleYouTubeRequestError(_ error: Error) throws`;
- `private func youtubeFailureMessage(_ message: String, _ error: Error) -> String`
  becomes `func youtubeFailureMessage(_ message: String, _ error: Error) -> String`.

Their bodies and behavior do not change.

## Non-goals

- Do not change request counts, the uploads page size, the `publishedAfter`
  semantics or the batching.
- The filters must not fetch extra pages.
- Do not touch `ProductionNodeAdapter+YouTubeCollect.swift`. Its 8 MB checks
  and `context` handling stay as they are.

## File-level changes

### `YouTubeCollectionOptions`

- The allowed key set gains `"excludeLive"` and `"maxDurationSeconds"`.
- New stored properties: `let excludeLive: Bool` (default `false`) and
  `let maxDurationSeconds: Int?`.
- `excludeLive` must be `.bool`.
- `maxDurationSeconds` must be `.integer` in 1…604,800.
- Anything else throws `youtubeCollectionInvalid()`, including `.null`,
  strings and `.number`.

### `YouTubeCollection.collect`

After computing the final ordered id list, which is
`explicitOrder + orderedChannelIDs` filtered to existing records:

1. Walk the list in order.
2. If `excludeLive` is set and `liveBroadcastContent` is `"live"` or
   `"upcoming"`, append the id to `liveExcluded`.
3. Otherwise, if `maxDurationSeconds` is set and `durationSeconds` is a
   non-null integer greater than it, append the id to `durationExcluded`.
4. Otherwise, keep the video.

When `options.excludeLive || options.maxDurationSeconds != nil`, add this to
the result:

```json
"excluded": {"count": <live+duration>, "live": [ids], "duration": [ids]}
```

### `docs/workflows/youtube-collection.md`

Document:

- both options and their ranges;
- that they apply to explicit videos and channel uploads;
- that a null duration is kept;
- the attribution rule (a video matching both counts as live);
- the `excluded` shape;
- that a channel can return fewer than `maxPerChannel` videos;
- that the default output is unchanged.

## Invariants and pitfalls

- With neither option set, the output dictionary must have exactly the keys
  `videos`, `failures` and `requests`, with identical values. Do not emit an
  empty `excluded`.
- The filters apply to all records, explicit ones included. This is unlike
  `publishedAfter`, which is a deliberate design decision.
- A video whose metadata was not returned is still reported as a failure, as
  today. It is never counted in `excluded`.
- Do not change the "All attempted YouTube requests failed" rule.
- Keep option parsing outside `#if canImport(YouTubeGatewayCore)`, so Linux
  validation compiles.

## Tests (situation → expected)

Use the existing fake client and `HTTPTransport` fixtures in
`YouTubeCollectionTests.swift`, for example
`testChannelHandleSequenceFilteringDedupeAndOutputContract`.

- No new options → result keys are exactly {videos, failures, requests}, and
  existing tests stay unmodified and green.
- `excludeLive: true`, with videos whose `liveBroadcastContent` is `none`,
  `live` and `upcoming` → only the `none` video is kept, `excluded.live` lists
  the other two in output order, and `count` is 2.
- `maxDurationSeconds: 600`, with durations 300, 900 and null → keeps 300 and
  the null one, and `excluded.duration` is the 900 id.
- Both options, with a live video of duration 9999 → it is attributed to
  `live` only, and `count` equals live + duration.
- `excludeLive: false` alone → no `excluded` key.
- An explicit video reference that is live, with `excludeLive` → it is
  excluded too.
- `maxDurationSeconds: 0`, `604801`, `"600"` or `600.5`, and
  `excludeLive: "true"` → `youtubeCollectionInvalid`.

## Verification (evidence)

```bash
mkdir -p tmp/youtube-processing-builtins/ypb-02
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/youtube-processing-builtins/ypb-02/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter YouTubeCollectionTests > tmp/youtube-processing-builtins/ypb-02/test.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/YouTubeCollection.swift Tests/RielaCLITests/YouTubeCollectionTests.swift > tmp/youtube-processing-builtins/ypb-02/swiftlint.log 2>&1'
grep -n "^func handleYouTubeRequestError\|^func youtubeFailureMessage" Sources/RielaCLI/YouTubeCollection.swift
git diff --quiet -- "Sources/RielaCLI/ProductionNodeAdapter+YouTubeCollect.swift"
```

What each command must show:

- After this plan's final owned edit, build and test must reach exit 0 with 0
  failures at least once. The only exception is a recorded
  `deferred-to-integration` entry whose diagnostics are all in non-owned files.

- build and test: exit 0 with 0 failures.
- swiftlint: exit 0 with an empty log.
- grep: two matches.
- `git diff --quiet`: exit 0.

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
2. Record the pre/post SHA-256 and the intent in the progress log.
3. If the hash has drifted, re-read the file and re-apply the edit.

Further rules:

- Do not run any git write commands. Do not create worktrees.
- Put scratch files only under `tmp/youtube-processing-builtins/ypb-02/`.

## Done criteria

- All tests in the Tests section pass.
- The helpers are module-internal.
- The docs are updated.
- The progress log contains the hashes and the verification table.
