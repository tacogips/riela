# ypb-04: `media/yt-dlp-download` package container add-on and example pipeline

```json
{
  "planId": "ypb-04-yt-dlp-download-package",
  "planPath": "impl-plans/active/youtube-processing-builtins-04-yt-dlp-download-package.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "examples/video-pipeline-yt-dlp",
    "Tests/RielaCLITests/VideoPipelineYtDlpPackageTests.swift",
    "impl-plans/progress/ypb-04-yt-dlp-download-package.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design source: `design-docs/specs/design-youtube-processing-builtins.md` §E.

`riela/media-download` hard-codes yt-dlp inside the runtime. Users need an
adaptable downloader that lives outside the `riela/` namespace and emits the
tool-neutral `mediaDownload` contract. The required contract fields are
`mediaDownload.status = "downloaded"` and `mediaDownload.path`, an absolute
file path. Optional fields are `url`, `videoId`, `title`, `durationSeconds`,
`outputDir` and `cached`.

The existing third-party mechanism is the package-declared container node
add-on. It works like this:

- `riela-package.json` declares add-ons under `"addons"`, decoded as
  `WorkflowPackageManifest.nodeAddons`.
- Validation is `WorkflowPackageManifestValidator` in
  `Sources/RielaAddons/WorkflowPackageManifest.swift`.
- `riela package install` installs to `<project>/.riela/packages/<name>` and
  projects add-ons into `~/.riela/addons/<ns>/<name>/<version>/`
  (`SharedAddonStore.swift`).
- Runtime resolution happens in `installedContainerAddonRegistrations` and
  `ContainerWorkflowAddonResolver` (`ProductionNodeAdapter.swift`,
  `ContainerWorkflowAddonResolver.swift`):
  - stdin is one JSONL `AddonExecutionInput`;
  - stdout is exactly one JSONL object;
  - the artifact root is mounted at the same path;
  - `RIELA_ARTIFACT_DIR` is set;
  - network is enabled by a `network.egress` capability.
- Validate resolves package-owned add-ons through `bundle.packageManifest.nodeAddons`
  (`WorkflowValidateInspectCommands.swift` `addonHostRequirements`).
- Mock scenarios intercept add-on nodes by node id before execution.

## Non-goals

- Do not modify `Sources/`. No resolver changes.
- Do not change `riela/media-download` or `containers/video-addons`.
- No docs under `docs/`; ypb-05 owns them.
- No deprecation warning; ypb-06 owns it.
- Do not add the package to `rielaExampleWorkflowNames()`. It has no
  top-level `workflow.json`, so parity discovery
  (`RielaExampleParityTests.discoverWorkflowNames`) skips it by design.
- Never write to the real `~/.riela`. Every install in tests and manual
  checks runs with `HOME` under a tmp directory.

## Files to create (all under `examples/video-pipeline-yt-dlp/`)

### `riela-package.json`

Fields:

- `"name": "video-pipeline-yt-dlp"`, `"version": "1.0.0"`, a description, tags.
- `"registry": "local"`, `"checksumAlgorithm": "md5"` and a correct
  `"checksum"` (see the checksum recipe below).
- `"workflowDirectory": "workflow"`.
- One `"addons"` entry:
  - `"name": "media/yt-dlp-download"`
  - `"version": "1"`
  - `"sourcePath": "addons/yt-dlp-download"`
  - `"execution": {"kind": "container", "containerfilePath": "Containerfile", "entrypoint": "yt-dlp-download"}`
  - `"capabilities"`: a `network.egress` entry with `defaultPolicy` allowing
    egress, and a `filesystem.write` entry with scope `runtime.output`.
  - `"contentDigest": "sha256:<64 lowercase hex>"`. Compute it as the SHA-256
    of `Containerfile` bytes followed by `yt-dlp-download` bytes, and record the
    exact command in `README.md`. contentDigest is required for executable
    add-ons, per `validateNodeAddonExecutionRequirements` (Step-3 finding 1).

Copy the capability object shapes from existing manifest fixtures in
`Tests/RielaCLITests/WorkflowInstalledAddonMetadataTests.swift` and
`Tests/RielaCLITests/NodeCommandTests.swift`.

### `addons/yt-dlp-download/Containerfile`

- Base `ubuntu:24.04`. Do not use the riela worker image.
- Install `ca-certificates`, `ffmpeg` and `python3`.
- Install yt-dlp `2026.10.26` and Deno `2.9.8`. Reuse exactly the asset names
  and SHA-256 values from `containers/video-addons/Containerfile`, including
  the per-architecture `case`.
- Install the script as `/usr/local/bin/yt-dlp-download` (mode 0755).
- Do not set `ENTRYPOINT`. The resolver passes `--entrypoint yt-dlp-download`.

### `addons/yt-dlp-download/yt-dlp-download`

This is an executable Python 3 standard-library script with the shebang
`#!/usr/bin/env python3` and file mode 0755.

The entrypoint is a bare name, so it is a safe package-relative path that
exists in the package and also resolves through `PATH` in the image (Step-3
finding 2).

Behavior:

1. Read one stdin line as JSON and take
   `options = nodePayload.config.options`, which must be an object.
2. Validate the options:

   | Option | Rule | Default |
   | --- | --- | --- |
   | `url` | string, required | — |
   | `allowedHosts` | array of strings | — |
   | `maxFileSizeMB` | integer 1–1,000,000 | 2048 |
   | `maxDurationSeconds` | number 1–172,800 | 7200 |
   | `format` | string | `bv*[height<=720][ext=mp4]+ba[ext=m4a]/b[height<=720]/b` |
   | `cache` | bool | true |

   Unknown keys, including `ytDlpPath`, `ffmpegPath` and `outputDir`, are an
   error.
3. Apply the URL policy from `Sources/RielaCLI/MediaPipelineOptions.swift`
   (`normalizedURL`, `isSafeURL`, `host(_:matches:)`):
   - only `http`/`https`;
   - no userinfo;
   - reject `localhost`, `.local`, and loopback/private/link-local/unique-local
     IPv4/IPv6 literals;
   - `allowedHosts` is a suffix match on the host.
4. Compute `identity = sha256(normalized url).hexdigest()[:24]` and
   `outputDir = $RIELA_ARTIFACT_DIR/media-download/<identity>`.
   `RIELA_ARTIFACT_DIR` is required.
5. Cache:
   - the file is `media-download-manifest.json`, holding `fingerprint` and
     `payload`;
   - the fingerprint is the SHA-256 of the canonical JSON of
     `{format, maxFileSizeMB, url}` with sorted keys;
   - on a match where `payload.mediaDownload.path` exists, print the payload
     with `cached: true` and exit 0.
6. Metadata: run `yt-dlp --no-playlist -O "%(.{id,title,duration,is_live,live_status})j" <url>`.
   Reject `is_live` true, or `live_status` `is_live`/`is_upcoming`. Reject a
   missing duration, a duration ≤ 0, or one above `maxDurationSeconds`.
7. Remove existing `video.*` files in `outputDir`, then download:
   `yt-dlp --no-playlist --max-filesize <N>M --ffmpeg-location <ffmpeg on PATH> -f <format> --merge-output-format mp4 -o <outputDir>/video.%(ext)s --print after_move:filepath --no-simulate <url>`.
   The last stdout line must be an existing file.
8. Write the manifest, then print exactly one line to stdout:
   `{"mediaDownload": {"status": "downloaded", "url", "videoId", "title", "durationSeconds", "path", "outputDir", "cached": false}}`.
9. Errors go to stderr as one line `yt-dlp-download: <stage>: <reason>`, and
   the script exits 1. Never echo the raw stdin, environment or full yt-dlp
   output. Capture child stdout/stderr and never pass it through.

### `workflow/workflow.json`

- `workflowId: "video-pipeline-yt-dlp"`.
- Steps:
  - `download` uses addon `media/yt-dlp-download` v1 with
    `config.options.url` from `{{workflowInput.url}}`, or a literal public URL
    as in the docs example.
  - `audio` uses `riela/audio-segments` with
    `options.path: "{{input.mediaDownload.path}}"`.
  - `frames` uses `riela/video-frames` with
    `options.path: "{{input.audioSegments.sourcePath}}"` and
    `segments: "{{input.audioSegments.segments}}"`.
  - `summary` uses `riela/json-compose`.
- Follow the node and step shape of the first workflow in
  `docs/workflows/video-pipeline.md`.

### `workflow/mock-scenario.json`

Provide scenario-mock payloads for `download`, `audio` and `frames`, so no
media tools run. Use the shape of `examples/notion-gateway-json-sync/mock-scenario.json`.
The `download` payload must follow the `mediaDownload` contract, with an
absolute fixture path such as `/tmp/riela-fixture/video.mp4`. `summary` runs
for real.

### `README.md`

Cover:

- what the add-on does and the `mediaDownload` contract;
- building the image happens automatically from `containerfilePath`, and needs
  a container runtime;
- install, for example
  `riela package install video-pipeline-yt-dlp --source examples/video-pipeline-yt-dlp --working-dir <project>`;
- running with network egress;
- how to swap in another downloader: any add-on or step that emits
  `mediaDownload.path`;
- the contentDigest and checksum refresh commands.

### Checksum recipe

The checksum must be computed after every file is final.

1. Copy the package to `tmp/youtube-processing-builtins/ypb-04/pkg`.
2. Run `riela package init` on the copy with `--package-name video-pipeline-yt-dlp --overwrite`,
   or use the `packageChecksum(packageRoot:)` helper approach from
   `Tests/RielaCLITests/WorkflowCommandScenarioTests.swift`.
3. Copy only the resulting `checksum` value into the authored manifest. Keep
   `addons[]` and `workflowDirectory` intact.
4. Confirm with `riela package validate examples/video-pipeline-yt-dlp`.

Run python with `PYTHONDONTWRITEBYTECODE=1`, and never run the script from
inside `examples/`. A `__pycache__` directory breaks the checksum.

## Test file: `Tests/RielaCLITests/VideoPipelineYtDlpPackageTests.swift`

Use `CLIRuntimeEnvironment.$overrides.withValue(["HOME": <tmp home>, "RIELA_WORKFLOW_HOME": <tmp home>/.riela])`,
as in `WorkflowInstalledAddonMetadataTests`, and `RielaCLIApplication().run([...])`.

Always override `RIELA_WORKFLOW_HOME` as well. In
`Sources/RielaWorkflowRegistry/CLIRuntimeEnvironment.swift`,
`workflowHomeAnchor` prefers it over `HOME`. A value inherited from the real
environment would send user-scope installs into real user storage.

- `package validate examples/video-pipeline-yt-dlp --output json` → exit
  success, valid.
- Install into a temp project with
  `package install video-pipeline-yt-dlp --source <repo>/examples/video-pipeline-yt-dlp --working-dir <tmp project> --output json`
  → success. Expected files:
  - `<tmp project>/.riela/packages/video-pipeline-yt-dlp/riela-package.json`;
  - `<tmp home>/.riela/addons/media/yt-dlp-download/1/` exists.
- User scope, in a fresh tmp home and an empty, different working dir:
  `package install video-pipeline-yt-dlp --source <repo>/examples/video-pipeline-yt-dlp --scope user --working-dir <tmp other> --output json`
  → success.
  - `<tmp home>/.riela/packages/video-pipeline-yt-dlp/riela-package.json` exists.
  - `<tmp home>/.riela/addons/media/yt-dlp-download/1/` exists.
  - `workflow validate video-pipeline-yt-dlp --working-dir <tmp other> --output json`
    → success.
  - Nothing is created under `<tmp other>/.riela/packages`.
- `workflow validate video-pipeline-yt-dlp --working-dir <tmp project> --output json`
  → exit success, and no diagnostic mentions an unresolved add-on.
- `workflow run video-pipeline-yt-dlp --working-dir <tmp project> --mock-scenario <installed>/workflow/mock-scenario.json --session-store <tmp>/sessions --output json`
  → exit success, and the final output contains the mocked `mediaDownload.path`
  flowing into the `audio` input.
- Script contract test, which calls `XCTSkip` when `/usr/bin/env python3 --version`
  fails. Copy the script into a tmp dir and create fake `yt-dlp` and `ffmpeg`
  shell scripts in `<tmp>/bin`. The fake `yt-dlp` prints metadata JSON for
  `-O`, and for a download writes `<dir>/video.mp4` and prints its path. Run
  with `PATH=<tmp>/bin:/usr/bin:/bin`, `RIELA_ARTIFACT_DIR=<tmp>/artifacts` and
  `PYTHONDONTWRITEBYTECODE=1`.
  - A valid public URL → exit 0, exactly one stdout JSON line, `mediaDownload.path`
    exists under `<tmp>/artifacts/media-download/<24 hex>/`, and `cached` is
    false.
  - The same input again → `cached: true`, and the fake yt-dlp is not invoked
    for the download (use a call-count file).
  - `http://127.0.0.1/x`, `http://10.0.0.1/x` and `http://localhost/x` →
    exit 1, and stdout is empty.
  - Fake metadata with `live_status: "is_live"` → exit 1.
  - Duration above `maxDurationSeconds` → exit 1.
  - An unknown option `ytDlpPath` → exit 1.

## Invariants and pitfalls

- The package must keep validating after every edit. Any file change inside it
  requires a checksum refresh.
- Do not put a top-level `workflow.json` in `examples/video-pipeline-yt-dlp/`.
  It would enter example parity and change the mock count.
- The Containerfile pins must match `containers/video-addons/Containerfile`
  byte-for-byte in the version and SHA values.
- The mock run must not need a container runtime or network.

## Verification (evidence)

```bash
mkdir -p tmp/youtube-processing-builtins/ypb-04
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/youtube-processing-builtins/ypb-04/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && HOME=/Users/taco/gits/tacogips/riela/tmp/youtube-processing-builtins/ypb-04/home .build/debug/riela package validate examples/video-pipeline-yt-dlp --output json > tmp/youtube-processing-builtins/ypb-04/package-validate.json 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter VideoPipelineYtDlpPackageTests > tmp/youtube-processing-builtins/ypb-04/test.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Tests/RielaCLITests/VideoPipelineYtDlpPackageTests.swift > tmp/youtube-processing-builtins/ypb-04/swiftlint.log 2>&1'
test ! -e examples/video-pipeline-yt-dlp/workflow.json
find examples/video-pipeline-yt-dlp -name __pycache__
```

What each command must show:

- After this plan's final owned edit, build and test must reach exit 0 with 0
  failures at least once. The only exception is a recorded
  `deferred-to-integration` entry whose diagnostics are all in non-owned files.

- build: exit 0.
- package validate: exit 0 and valid in the JSON.
- test: exit 0 with 0 failures. If the script test was skipped, record that.
- swiftlint: empty log.
- `test`: exit 0.
- `find`: prints nothing.

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

- Edit only `writePaths`.
- Before each edit, record the pre/post SHA-256 in the progress log.
- Do not run any git write commands.
- Put scratch files only under `tmp/youtube-processing-builtins/ypb-04/`.

## Done criteria

- All six example files exist with the shapes above.
- package validate passes.
- `VideoPipelineYtDlpPackageTests` passes.
- The progress log records the contentDigest and checksum commands, the hashes
  and the verification table.
