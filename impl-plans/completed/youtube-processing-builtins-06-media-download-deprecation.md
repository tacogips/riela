# ypb-06: `riela/media-download` deprecation warning in workflow validation

```json
{
  "planId": "ypb-06-media-download-deprecation",
  "planPath": "impl-plans/active/youtube-processing-builtins-06-media-download-deprecation.md",
  "dependsOn": ["ypb-03-fanout-step-outputs-core"],
  "wave": "W2",
  "writePaths": [
    "Sources/RielaCore/WorkflowDeprecatedAddonValidation.swift",
    "Tests/RielaCoreTests/MediaDownloadDeprecationValidationTests.swift",
    "Tests/RielaCLITests/MediaDownloadDeprecationWarningTests.swift",
    "impl-plans/progress/ypb-06-media-download-deprecation.md"
  ],
  "sharedPaths": [
    "Sources/RielaCore/WorkflowValidation.swift"
  ],
  "sharedPathNotes": [
    {
      "path": "Sources/RielaCore/WorkflowValidation.swift",
      "intendedEdit": "Add exactly one call, diagnostics += deprecatedAddonDiagnostics(node.addon, nodeId: node.id), inside the existing for (index, node) in workflow.nodeRegistry.enumerated() loop of DefaultWorkflowValidator.validate(_ workflow:). No other change. ypb-03 owns this file in W1, so this edit runs after it."
    }
  ]
}
```

## Intent and context

Design source: `design-docs/specs/design-youtube-processing-builtins.md` §E,
"Deprecation of riela/media-download".

`riela/media-download` stays executable for this release. Its implementation,
its catalog entry in `RielaAddons.dataAddons`, and its default image in
`BuiltinAddonContainerResolver.addonDefaultImages` do not change. Running
`riela workflow validate` must report a non-fatal deprecation warning with
migration guidance.

`riela workflow validate` (`WorkflowValidateInspectCommands.run`) merges two
diagnostic sources:

- `bundle.diagnostics`;
- `DefaultWorkflowValidator(context: .production()).validate(...)`. Its output
  is filtered with `!bundle.diagnostics.contains($0)`, so an identical
  diagnostic is not duplicated.

The command is valid only when no diagnostic has severity `.error`.

## Contract

Add a new file, `Sources/RielaCore/WorkflowDeprecatedAddonValidation.swift`,
with this internal function:

```swift
func deprecatedAddonDiagnostics(_ addon: WorkflowNodeAddonRef?, nodeId: String) -> [WorkflowValidationDiagnostic]
```

When `addon?.name == "riela/media-download"`, it returns exactly one
diagnostic:

- `severity: .warning`
- `path: "workflow.nodes.\(nodeId).addon.name"`
- `message`: "riela/media-download is deprecated; install an adaptable
  downloader add-on such as media/yt-dlp-download and wire its
  mediaDownload.path (see docs/workflows/video-pipeline.md, Migrating from
  riela/media-download)"

In every other case it returns `[]`.

## Non-goals

- Do not change how `riela/media-download` executes, its registration,
  `BuiltinAddonContainerResolver` or the catalog lists.
- No warning for `riela/audio-segments`, `riela/video-frames`,
  `riela/speech-to-text` or `riela/video-transcribe`.
- Do not touch `WorkflowNodeValidation.swift`.
- Do not edit `WorkflowValidation.swift` beyond the one call described in the
  shared-path note.

## Invariants and pitfalls

- Emit exactly one warning per node id. `nodeRegistry` ids are unique, which
  is already validated by `validateUniqueIds`.
- The warning must never be an `.error`. Existing validations of workflows that
  use `riela/media-download` must keep exit code success. Examples are the
  `docs/workflows/video-pipeline.md` blocks validated by
  `MediaPipelineWorkflowDocumentationTests`.
- Do not filter the warning out anywhere.

## Tests (situation → expected)

`Tests/RielaCoreTests/MediaDownloadDeprecationValidationTests.swift` uses
`DefaultWorkflowValidator().validate(workflow)`:

- A workflow with one `riela/media-download` node → exactly one diagnostic
  with severity warning, path `workflow.nodes.<id>.addon.name`, and a message
  containing `media/yt-dlp-download` and `Migrating from riela/media-download`.
  There are no error diagnostics.
- Two media-download nodes → two warnings, one per id.
- Nodes using `riela/audio-segments`, `riela/video-frames` or
  `riela/speech-to-text` → no deprecation warning.

`Tests/RielaCLITests/MediaDownloadDeprecationWarningTests.swift` writes a temp
workflow dir under `makeRielaCLITestTemporaryDirectory`. Imitate
`MediaPipelineWorkflowDocumentationTests`.

- `workflow validate <name> --workflow-definition-dir <tmp> --output json` on
  a workflow with a `riela/media-download` node → exit `.success`. The JSON
  `diagnostics` contain exactly one entry whose message equals the pinned
  deprecation message, and its severity is `warning`. Other warnings may exist,
  for example host-tool warnings, so do not assert the total diagnostic count.
  `valid` is true.

## Verification (evidence)

```bash
mkdir -p tmp/youtube-processing-builtins/ypb-06
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/youtube-processing-builtins/ypb-06/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter "MediaDownloadDeprecationValidationTests|MediaDownloadDeprecationWarningTests|MediaPipelineWorkflowDocumentationTests|MediaPipelineAddonRegistrationTests|BuiltinAddonContainerResolverTests" > tmp/youtube-processing-builtins/ypb-06/test.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCore/WorkflowDeprecatedAddonValidation.swift Sources/RielaCore/WorkflowValidation.swift Tests/RielaCoreTests/MediaDownloadDeprecationValidationTests.swift Tests/RielaCLITests/MediaDownloadDeprecationWarningTests.swift > tmp/youtube-processing-builtins/ypb-06/swiftlint.log 2>&1'
git diff -U0 -- Sources/RielaCore/WorkflowValidation.swift
```

What each command must show:

- After this plan's final owned edit, build and test must reach exit 0 with 0
  failures at least once. The only exception is a recorded
  `deferred-to-integration` entry whose diagnostics are all in non-owned files.

- build: exit 0.
- test: exit 0 with 0 failures.
- swiftlint: empty log.
- `git diff -U0`: compared with the ypb-03 post-hash recorded in its progress
  log, this plan adds exactly one line, the
  `deprecatedAddonDiagnostics(node.addon, nodeId: node.id)` call.

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

Before editing `WorkflowValidation.swift`:

1. Read it fresh.
2. Record its SHA-256.
3. Verify the `nodeRegistry` loop still exists. If ypb-03 restructured it,
   insert the call at the equivalent per-node point and note this in the
   progress log.

Further rules:

- Record the post-hash.
- Do not run any git write commands.
- Put scratch files under `tmp/youtube-processing-builtins/ypb-06/`.

## Done criteria

- The new file and both test files exist, and the tests pass.
- Existing media and container tests are green.
- The one-line shared edit is confirmed.
- The progress log contains the hashes and the verification table.
