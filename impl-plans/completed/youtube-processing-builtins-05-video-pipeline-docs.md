# ypb-05: Video pipeline docs: mediaDownload contract, swapping the downloader, migration

```json
{
  "planId": "ypb-05-video-pipeline-docs",
  "planPath": "impl-plans/active/youtube-processing-builtins-05-video-pipeline-docs.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "docs/workflows/video-pipeline.md",
    "docs/container-addons.md",
    "Tests/RielaCLITests/MediaPipelineWorkflowDocumentationTests.swift",
    "impl-plans/progress/ypb-05-video-pipeline-docs.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design source: `design-docs/specs/design-youtube-processing-builtins.md` §E,
"Contract" and "Docs and tests".

Users need documentation for three things:

- the tool-neutral `mediaDownload` v1 contract;
- how to plug in a different downloader;
- how to migrate from the deprecated `riela/media-download` to the package
  add-on `media/yt-dlp-download` v1.

The package is shipped by ypb-04 at `examples/video-pipeline-yt-dlp/`. Its
package name is `video-pipeline-yt-dlp`, its workflow is `video-pipeline-yt-dlp`,
and it declares an add-on with `entrypoint: yt-dlp-download`,
`network.egress`, and `filesystem.write` scoped to `runtime.output`.

The deprecation warning is added by ypb-06. Its exact message is:

> riela/media-download is deprecated; install an adaptable downloader add-on
> such as media/yt-dlp-download and wire its mediaDownload.path (see
> docs/workflows/video-pipeline.md, Migrating from riela/media-download)

Use these pinned names verbatim. The docs reference them, but this plan does
not depend on those files existing.

## Non-goals

- Do not change any Swift source.
- Do not change `README.md`, `containers/` or the `examples/` contents.

## File-level changes

### `docs/workflows/video-pipeline.md`

Keep the existing three fenced json blocks as the first three json blocks,
byte-identical and in their current order:

1. the `video-pipeline` workflow;
2. the `video-pipeline-segment` workflow;
3. the `describe-segment.json` node.

`MediaPipelineWorkflowDocumentationTests` validates the first two.

Changes:

- Before the first block, add one sentence. It says that `download` uses the
  deprecated `riela/media-download`, which still runs with a validation
  warning, and points to "Migrating from riela/media-download".
- After the existing content, add these sections, using these exact headings
  because the warning message links to the migration one:
  - `## Media download contract`: a table of the `mediaDownload` fields, with
    `status` and `path` required and the rest optional, plus the rules for
    `path`:
    - it is absolute and points to a regular file;
    - it is readable where the consumer runs;
    - under containers, it lives under the workflow working directory or the
      artifact root.

    Also state that `riela/audio-segments`, `riela/video-frames` and
    `riela/speech-to-text` read only `options.path`, so any producer or a plain
    local path works.
  - `## Plugging in a different downloader`: any add-on or step that emits
    `mediaDownload.path`. Mention package container add-ons (`addons[]` with
    `execution.kind: container`, JSONL stdin/stdout, `RIELA_ARTIFACT_DIR`), and
    refer to `examples/video-pipeline-yt-dlp/README.md`.
  - `## Migrating from riela/media-download`:
    1. replace the node `addon.name` with `media/yt-dlp-download`, version `1`;
    2. keep `options.url`, `allowedHosts`, `maxFileSizeMB`,
       `maxDurationSeconds`, `format` and `cache`;
    3. drop `ytDlpPath`, `ffmpegPath` and `outputDir`, which the add-on does
       not support;
    4. make the add-on resolvable by validation, either by vendoring
       `addons/yt-dlp-download` into your workflow package's `addons[]` or by
       adding a node-addon dependency lock;
    5. install the package (`riela package install`) in project or user scope.

    Include one json snippet of the replaced download node.
- Update `XCTAssertEqual(blocks.count, 3)` in the test to the new total number
  of ```` ```json ```` blocks.

### `docs/container-addons.md`, section "Video media add-ons"

- State that `riela/media-download` is deprecated and still selects
  `riela-video-addons:local`.
- Describe the package container add-on `media/yt-dlp-download`:
  - its self-contained image is built from its `Containerfile`;
  - it needs a `network.egress` capability;
  - it writes under the same-path artifact root.
- Link to `workflows/video-pipeline.md#migrating-from-rielamedia-download`.
  This is the GitHub slug: lowercase, spaces become hyphens, and `/` is
  dropped.

### `Tests/RielaCLITests/MediaPipelineWorkflowDocumentationTests.swift`

Only update the expected block count. It must still validate only
`blocks.prefix(2)`.

## Invariants and pitfalls

- If a new json block lands before the existing three, the test validates the
  wrong JSON. Append new blocks only after them.
- The heading text "Migrating from riela/media-download" must match the
  warning message exactly.
- Never include real URLs that carry tokens, or any credentials.

## Tests (situation → expected)

- The docs test passes with the updated count, and the first two blocks still
  validate with exit success. Since ypb-06, they validate with a warning, which
  does not affect the exit code.

## Verification (evidence)

```bash
mkdir -p tmp/youtube-processing-builtins/ypb-05
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter MediaPipelineWorkflowDocumentationTests > tmp/youtube-processing-builtins/ypb-05/test.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Tests/RielaCLITests/MediaPipelineWorkflowDocumentationTests.swift > tmp/youtube-processing-builtins/ypb-05/swiftlint.log 2>&1'
grep -c "^## Migrating from riela/media-download$" docs/workflows/video-pipeline.md
grep -c "media/yt-dlp-download" docs/container-addons.md
```

What each command must show:

- After this plan's final owned edit, build and test must reach exit 0 with 0
  failures at least once. The only exception is a recorded
  `deferred-to-integration` entry whose diagnostics are all in non-owned files.

- test: exit 0 with 0 failures.
- swiftlint: empty log.
- first grep: 1.
- second grep: at least 1.

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

- Before each edit, read the file fresh and record the pre/post SHA-256.
- Edit only `writePaths`.
- Do not run any git write commands.
- Put scratch files under `tmp/youtube-processing-builtins/ypb-05/`.

## Done criteria

- The three sections exist.
- The container doc is updated.
- The docs test passes.
- The progress log contains the hashes and the verification table.
