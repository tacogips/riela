# YouTube processing built-ins

## Status

Design accepted for implementation 2026-10-30. No GitHub issue: the request
comes from runtime session `opus-terra-design-and-implement-review-loop-session-558`
(`comm-010583`, intake `comm-010584`). Workflow mode: `issue-resolution`.
No Codex-agent reference or Cursor adapter is involved.

Implementation accepted 2026-10-30 after the integration review (`comm-010664`).
The plans `youtube-processing-builtins-01` … `09` are archived under
[`impl-plans/completed/`](../../impl-plans/completed/), with progress logs in
`impl-plans/progress/ypb-0*.md`. The dispatch manifest
`impl-plans/active/youtube-processing-builtins-dispatch.json` records the
original plan paths.

This document generalizes five workarounds seen in the ART YouTube workflow:

| Part | Change | Baseline it amends |
| --- | --- | --- |
| A | New `riela/youtube-gateway-read` v1 | `design-gateway-sdk-addons.md`, `docs/builtin-gateway-json.md` |
| B | Opt-in fanout `includeStepOutputs` | `design-bounded-fanout-join-workflow-execution.md` |
| C | durable-queue `pending` `limit` / `maxAttempts` | `docs/workflows/durable-queue.md` |
| D | youtube-collect `excludeLive` / `maxDurationSeconds` | `design-native-source-collection.md` §YouTube |
| E | Tool-neutral `mediaDownload` contract, yt-dlp as a package add-on, `riela/media-download` deprecated | `design-native-source-collection.md` §Composable media pipeline |

The baseline designs stay valid. This document only adds the deltas below.

## Global constraints

- Backward compatible. Without the new options, workflows, join payloads,
  durable-queue results and youtube-collect outputs stay byte-for-byte
  unchanged.
- The `YouTubeGatewayCore` pin (`33006f3a`) and the macOS-only
  `condition: .when(platforms: [.macOS])` stay as they are. Its source is not
  vendored. Code that imports it is wrapped in `#if canImport(YouTubeGatewayCore)`,
  so Linux still compiles. On Linux, execution fails with a policy error.
- Add read-only YouTube operations only: no subscription insert or delete.
- Tests make no live network calls. They use injected clients, the public
  `HTTPTransport` seam of `YouTubeClient`, fixtures and mock scenarios.
- Credentials never appear in source, docs, examples, outputs or diagnostics.
- No VERSION, `rielaVersion`, formula or release change. No ART edit. No write
  to the real `~/.riela`: package-install tests set `HOME` under `tmp/`.

## A. `riela/youtube-gateway-read`, version `1`

### Pattern choice

The pinned `YouTubeGatewayCore` exposes a typed Swift `YouTubeClient`
(`list`, `videosList`, `channelsList`, `playlistItemsList`). It has no
GraphQL `GatewaySchemaCatalog`. So the Notion/Wrike `LocalGatewayGraphQLEngine`
path does not apply. The add-on therefore follows the typed-operation pattern of
`riela/google-service-gateway-read`
(`ProductionNodeAdapter+GoogleServiceGatewayAddons.swift`):

- a literal `operation`;
- an object `arguments`;
- a riela-owned request enum;
- a client protocol;
- the `{status, addon, stepId, operation, data}` output envelope.

It is macOS-only like `riela/notion-gateway-read`, and it uses the same
environment allowlist as `riela/youtube-collect`.

`ContainerGatewayAddonExecutor` does not apply. That path serves the legacy
X/Gmail reader containers, and YouTube is linked in-process. When the add-on
runs in the builtin worker container (Linux guest), it fails with the same macOS
policy error as Notion.

### Registration

- `Sources/RielaAddons/RielaAddons.swift`: add a new
  `youtubeGatewayAddons = [riela/youtube-gateway-read v1]` list and include it
  wherever `notionGatewayAddons` is aggregated into the public catalog.
- Register a `BuiltinAddonHandlerRegistration` named
  `riela/youtube-gateway-read` in `BuiltinStatefulAddonRegistry`, alongside
  `youtubeCollectionRegistration`. Do not add a provider-name branch to the
  `ProductionNodeAdapter` dispatcher.
- New file `Sources/RielaCLI/ProductionNodeAdapter+YouTubeGatewayAddons.swift`
  holds the engine. The request parsing in the engine must not reference
  `YouTubeGatewayCore` types, so validation also works on Linux. Only the
  client mapping and execution sit inside `#if canImport(YouTubeGatewayCore)`.

### Request contract

`config` has the closed keys `operation` and `arguments`. `arguments` can be one
of three forms:

- a literal object;
- an object with templates, rendered at runtime through
  `BuiltinGatewayJSONRequest.renderedArguments`;
- an exact `{{...}}` placeholder.

`addon.inputs` cannot be combined with `arguments`.

| Operation | Arguments (closed set) | Rules |
| --- | --- | --- |
| `subscriptions.list` | `mine`, `channelId`, `ids`, `mySubscribers`, `myRecentSubscribers`, `forChannelId`, `order`, `parts`, `maxResults`, `pageToken` | Exactly one filter: `mine:true`, `channelId`, `ids` (1–50 non-empty), `mySubscribers:true` or `myRecentSubscribers:true`. `order` is `alphabetical`, `relevance` or `unread`. `parts` ⊆ {`id`,`snippet`,`contentDetails`,`subscriberSnippet`}, default `["snippet","contentDetails"]`. `maxResults` is 1–50. |
| `videos.list` | `ids`, `parts`, `pageToken` | `ids` is 1–50 non-empty. `parts` ⊆ {`id`,`snippet`,`contentDetails`,`statistics`}, default `["snippet","contentDetails","statistics"]`. |
| `channels.list` | `ids`, `forHandle`, `mine`, `parts` | Exactly one of `ids` (1–50), `forHandle` or `mine:true`. `parts` ⊆ {`id`,`snippet`,`contentDetails`}, default both content parts. |
| `playlistItems.list` | `playlistId`, `ids`, `parts`, `maxResults`, `pageToken` | Exactly one of `playlistId` or `ids`. `maxResults` is 1–50. `parts` ⊆ {`id`,`snippet`,`contentDetails`}. |

Notes on the table:

- `onBehalfOfContentOwner*` is intentionally not exposed.
- `channels.list` has no pagination arguments because the pinned SDK has no
  page options for it. Its `nextPageToken` is still passed through when the API
  returns one.

### Pagination

Each execution makes one SDK call and returns one page. Callers paginate by
passing `data.nextPageToken` back as `arguments.pageToken`, for example through
a loop step. There is no riela-side auto-pagination. This keeps the request
bounded and deterministic, and it matches the request-level contract of
google-service.

### Credentials

`addon.env` targets are limited to `YOUTUBE_GATEWAY_TOKEN_STORE_JSON` and
`YOUTUBE_GATEWAY_ACCESS_TOKEN`; the token store is the documented one. Any other
target is a policy error. They are resolved with `resolveAddonEnvironment` and
passed to `YouTubeClient.fromEnvironment` with only those keys. Whitespace is
trimmed. If both values are blank, the result is a policy error naming the two
variable names, never their values.

### Output

```json
{
  "status": "ok",
  "addon": "riela/youtube-gateway-read",
  "stepId": "<step>",
  "operation": "subscriptions.list",
  "data": { "kind": "...", "etag": "...", "nextPageToken": "...", "prevPageToken": null,
            "pageInfo": { "totalResults": 3, "resultsPerPage": 25 }, "items": [] }
}
```

`data` is the SDK page (`SubscriptionPage`, `VideoPage`, `ChannelPage` or
`PlaylistItemsPage`), encoded with `JSONEncoder` and converted to riela JSON.
Output is limited to 8 MB, the same as youtube-collect. A larger output is an
`invalidOutput` error.

### Errors

Errors reuse the youtube-collect mapping. The helpers move from `private` to
file-internal shared helpers, without behavior change:

| Condition | Result |
| --- | --- |
| Cancellation | Propagates |
| `authentication`, `configuration` | `policyBlocked` "YouTube authentication failed; check …" |
| `quotaExceeded` | `policyBlocked` |
| Any other failure | `providerError` with `kind` and HTTP status only |

Provider response bodies, request URLs with tokens, and credential values are
never included.

### Validation

`BuiltinGatewayRequestChecks.extendedIssues` gets a
`riela/youtube-gateway-read` case. It runs the engine's `requestShapeIssue`:

- the operation is known;
- config keys are closed;
- argument names belong to the operation.

When `arguments` contains no templates, it also runs full `parse`, which checks:

- types and ranges;
- exactly one filter;
- the `parts` allowlist.

Templated arguments get only name checks, which matches the existing gateways.

### Tests and example

`Tests/RielaCLITests/YouTubeGatewayReadAddonTests.swift` is macOS-gated where it
touches the SDK. It covers:

- each operation's argument mapping, through a fake `HTTPTransport` that asserts
  `maxResults`, `pageToken` and filter query items;
- `nextPageToken` passthrough;
- the env allowlist and blank-credential errors;
- the error mapping, with a redaction assertion;
- registry and catalog membership;
- validation issues for an unknown operation, an unknown argument, two filters,
  and out-of-range `maxResults`.

Add `RielaBuiltinAddonCatalogTests` updates.

Example `examples/youtube-gateway-read/` contains `workflow.json`,
`mock-scenario.json`, `README.md` and `EXPECTED_RESULTS.md`. The flow is
`subscriptions.list` (`mine:true`, `maxResults:25`) → `riela/json-compose`
summary. It uses the env binding and mock pattern of
`examples/notion-gateway-json-sync`. Document the add-on in a
`docs/builtin-gateway-json.md` table row and a short section.

## B. Fanout `includeStepOutputs`

### Problem

`FanoutBranchOutcome.success` records only `result.rootOutput`, the branch's
last output. ART recovers an earlier branch step's transcript by reading
`riela/speech-to-text`'s private `<segment>.stt.json` cache.

### Contract

`WorkflowStepFanout` gains the optional field `includeStepOutputs: [String]?`.

```json
"fanout": { "groupId": "segments", "itemsFrom": "/segments", "joinStepId": "join",
            "includeStepOutputs": ["speech-to-text", "describe-segment"] }
```

When the field is present, each completed branch record gains:

```json
{ "index": 0, "item": {}, "status": "completed", "output": {}, "sessionId": "...",
  "branchId": "0",
  "stepOutputs": { "speech-to-text": { "text": "..." }, "describe-segment": {} } }
```

- A named step's value is the `acceptedOutput.payload` of the last execution of
  that step, in `session.executions` order, that has an accepted output. This
  includes imported (rerun-lineage) executions. The session is the branch's
  child session, `result.session` from the branch `run`.
- A named step that never produced an accepted output in that branch is omitted
  from `stepOutputs`. Omitted keys are never written as `null`. A completed
  branch always carries a `stepOutputs` object, possibly `{}`.
- Failed and cancelled branch records, which can reach the join under
  `collect-partial`, are unchanged and get no `stepOutputs`.
- When the field is absent, no key is added anywhere. The join payload, message
  bytes and durable receipt stay identical to today.

### Same-workflow and cross-workflow fanouts

Both use the same rule. For a same-workflow fanout, the named ids are steps of
the same workflow. For a `toWorkflowId` fanout, they are steps of the callee
workflow. Values come from the durable child session, so no persistence schema
change is needed.

### Determinism and resume

`stepOutputs` is derived only from the child session's durable accepted
outputs, never from in-memory adapter output. A resumed parent therefore rebuilds
an identical join, and `publishFanoutParentMessage`'s receipt match
(`nestedMessage(_:matches:)`) still holds. `includeStepOutputs` must be carried
on `WorkflowFanoutDispatchDirective` and set at every construction site:

- `RuntimePublication.swift` (the publisher);
- `DeterministicWorkflowRunner+NestedReservations.swift`, both the zero-selected
  rebuild and the resume rebuild.

### Size bound

The bound matches the existing `contextFrom` bound. If the compact-JSON size of
all `stepOutputs` values in one join exceeds 8,000,000 bytes, the dispatch fails
before join publication with `fanoutDispatchFailed(groupId:)`. The reason names
the first branch index and step id that crossed the bound, and no join message
is written. Large but legal joins are still subject to the existing agent
prompt overflow guard (`design-agent-prompt-overflow-guard.md`) when an agent
consumes them.

### Validation

| Layer | Rule |
| --- | --- |
| Raw (`WorkflowRawValidation.validateFanout`) and typed (`validateTypedFanout`) | When present, must be a non-empty array of unique non-empty strings |
| Core `DefaultWorkflowValidator`, `toWorkflowId == nil` | Each id must be a `workflow.steps[]` id and must not equal `joinStepId`, because a local branch stops before the join |
| CLI `workflow validate`, `toWorkflowId != nil` | A new pass beside `crossWorkflowCalleeResolutionDiagnostics` resolves the callee with `FileSystemWorkflowCalleeResolver`. Each id must be a callee step. This pass does not require `resumeStepId`, so fanouts without one are covered too. An unresolved callee reports the existing resolution error once. |

The error path is `workflow.steps.<id>.transitions[<i>].fanout.includeStepOutputs[<j>]`.

### Docs, tests and example

- Document the field in `docs/workflows/json-data-processing.md`, next to
  `contextFrom`.
- Add a pointer in `design-bounded-fanout-join-workflow-execution.md`.
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift` covers:
  same-workflow `stepOutputs`; latest-execution selection; omission of steps
  that never ran; failed records unchanged under `collect-partial`; the 8 MB
  bound error; and byte equality of the encoded join with and without an absent
  field against a fixture.
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutResumeTests.swift`
  covers a cross-workflow fanout and a resume that rebuilds the identical
  join.
- Core validation tests cover unknown, duplicate, empty and join ids. They go
  in `DeterministicWorkflowRunnerFanoutTests.swift`, next to the existing
  `contextFrom` validation cases. A CLI validate test covers an unknown callee
  step; put it in `Tests/RielaCLITests/PartialFanoutResumeTests.swift` or a new
  sibling file.
- The example `examples/fanout-include-step-outputs/` is a same-workflow
  fanout with a two-step branch built from `riela/json-compose` nodes. It has a
  mock scenario, and its join asserts `stepOutputs`.

## C. `riela/durable-queue` `pending` options

`pending` accepts two optional fields. Both are closed to `pending`, so other
actions still reject them. The outer key allowlist in `executeDurableQueue`
gains `limit` and `maxAttempts`.

| Field | Type / range | Effect |
| --- | --- | --- |
| `limit` | integer 1–100 | Adds `items`: up to N selected rows, in selection order |
| `maxAttempts` | integer 1–1,000,000,000 | Excludes pending rows with `attempts >= maxAttempts` from selection, and reports them |

- Ordering keeps the existing comparator: never-attempted first, then oldest
  `last_attempt_at`, then oldest `registered_at`, then identity bytes.
- `found`, `identity` and `request` are always present. They equal the first
  selected row under the same exclusion rule, or `false`/`null`/`null`. Without
  either option the output is exactly today's three fields.
- With `limit`, the output adds `items: [{identity, request, attempts}]` and
  `itemsTruncated` (bool). Items are added in order while the encoded output
  stays within `DurableQueueJournal.maximumBytes`. If the next item would
  exceed it, selection stops with `itemsTruncated: true`. A single request is at
  most 256 KiB, so at least one item always fits.
- With `maxAttempts`, the output adds `exhausted: [{identity, attempts}]`,
  ordered by identity bytes, and `exhaustedCount`. Exhausted rows stay
  `pending` in the journal. `pending` remains a read-only transaction, so the
  journal schema and other writers are unaffected. `completed` and legacy
  `acquired` rows are never reported as exhausted. A caller retires an
  exhausted identity through the existing `finish` action.

Update `docs/workflows/durable-queue.md` (action table and a paragraph). Extend
`Tests/RielaCLITests/DurableQueueTests.swift` to cover: limit ordering, limit
greater than pending count, maxAttempts exclusion and reporting, both options
combined, rejection on non-pending actions and out-of-range values, and an
unchanged default output.

## D. `riela/youtube-collect` filters

`options` gains `excludeLive` (bool, default `false`) and `maxDurationSeconds`
(integer 1–604,800, default absent).

- The filters run after `videos.list` enrichment and apply to every returned
  record, both explicit videos and channel uploads. They are content filters,
  unlike `publishedAfter`, which narrows only channel uploads.
- `excludeLive` drops records whose `liveBroadcastContent` is `live` or
  `upcoming`. `maxDurationSeconds` drops records whose non-null
  `durationSeconds` exceeds it. A null duration is kept.
- A record matching both filters is attributed to `live` only.
- When either option is set, the output adds
  `excluded: {"count": n, "live": [ids], "duration": [ids]}`, with ids in output
  order. The key is present even when nothing was excluded. Without either
  option the output is byte-identical to today.
- Excluded videos are not failures, and the collector does not fetch
  replacements. A channel can therefore return fewer than `maxPerChannel`
  videos. `requests` and the all-requests-failed rule are unchanged.

Update `docs/workflows/youtube-collection.md`. Extend
`Tests/RielaCLITests/YouTubeCollectionTests.swift` with the existing fake
client. It covers: each filter, the combined attribution, the null-duration
keep, the default output being unchanged, and option type/range rejection.

## E. Adaptable media download

### Contract: `mediaDownload` v1

This is documented in `docs/workflows/video-pipeline.md`. A producer step
outputs:

| Field | Required | Meaning |
| --- | --- | --- |
| `mediaDownload.status` | yes | `"downloaded"` |
| `mediaDownload.path` | yes | Absolute path of a regular media file. It must be readable on the host or container that runs the consumer stage, which means under the workflow working directory or the artifact root when stages run in containers. |
| `url`, `videoId` (string or null), `title`, `durationSeconds`, `outputDir`, `cached` | no | Descriptive. Consumers do not depend on them. |

`riela/audio-segments`, `riela/video-frames` and `riela/speech-to-text` are
unchanged and stay built-in. They take only `options.path`, so a workflow wires
`{{input.mediaDownload.path}}` from any producer, or any plain local path.
`riela/media-download` already emits this shape, and its output does not change.

### Downloader: `media/yt-dlp-download` v1, a package container add-on

The existing mechanism for third-party add-ons is the package-declared node
add-on. A `riela-package.json` file lists `addons[]` with `execution.kind:
container`. `riela package install` installs it in project scope
(`.riela/packages`) or user scope, and projects it into the shared add-on store
at `~/.riela/addons/<namespace>/<name>/<version>/`. At runtime it is resolved by
`installedContainerAddonRegistrations` and `ContainerWorkflowAddonResolver`
(JSONL in, one JSONL object out). Workflow validation resolves it through the
owning package manifest. The downloader uses this mechanism, and no new resolver
is added.

The example package is `examples/video-pipeline-yt-dlp/`. It has no top-level
`workflow.json`, so `RielaExampleParityTests` discovery skips it. It contains:

- `riela-package.json`: `kind: workflow` and `workflowDirectory: "workflow"`,
  with this add-on entry:
  - `name`: `media/yt-dlp-download`
  - `version`: `1`
  - `sourcePath`: `addons/yt-dlp-download`
  - `execution`: `{kind: container, containerfilePath: "Containerfile", entrypoint: <script path in image>}`
  - `capabilities`: `network.egress` and a `filesystem.write` capability scoped
    to `runtime.output`
- `addons/yt-dlp-download/Containerfile`: a self-contained image. It does not
  extend the riela worker image. It includes `python3`, `ffmpeg`, and yt-dlp
  plus Deno pinned to the same versions and SHA-256 values as
  `containers/video-addons/Containerfile`.
- `addons/yt-dlp-download/yt_dlp_download.py`: a Python 3 standard-library
  entrypoint. It reads one `AddonExecutionInput` JSONL line from stdin and takes
  its options from `nodePayload.config.options`:
  - `url` (required);
  - `allowedHosts`;
  - `maxFileSizeMB` (1–1,000,000, default 2048);
  - `maxDurationSeconds` (1–172,800, default 7200);
  - `format` (default identical to the builtin);
  - `cache` (default true).

  The script applies the same safety rules as the builtin: only http/https,
  reject local and private hosts and private IP literals, `allowedHosts` suffix
  match, reject live or upcoming streams, and reject a missing or over-long
  duration. It writes to `$RIELA_ARTIFACT_DIR/media-download/<sha256(url) first
  24 hex>/`, the same layout as the builtin default. The cache manifest
  `media-download-manifest.json` is fingerprinted by `url`, `maxFileSizeMB` and
  `format`, and is reused only when the referenced file exists. On success it
  writes one `{"mediaDownload": {...}}` object. On failure it exits non-zero with
  a one-line stderr reason that contains no credentials and no raw yt-dlp output
  beyond that reason. `ytDlpPath`, `ffmpegPath` and `outputDir` are not
  supported, because the image owns the tools and output must stay on the
  artifact mount.
- `workflow/workflow.json` (`workflowId: video-pipeline-yt-dlp`): download
  (`media/yt-dlp-download`) → `riela/audio-segments` (`{{input.mediaDownload.path}}`)
  → `riela/video-frames` → `riela/json-compose`. It comes with
  `workflow/mock-scenario.json`.
- `README.md`: install, run, and how to swap the downloader.

### Deprecation of `riela/media-download`

`riela/media-download` keeps its in-process implementation, catalog entry and
default container image for this release. It does not delegate to the new
add-on, so ART and other existing pipelines behave the same. Validation behavior:

- `DefaultWorkflowValidator` emits one `.warning` per node id whose
  `addon.name == "riela/media-download"`. The path is
  `workflow.nodes.<nodeId>.addon.name`, and the message is: "riela/media-download
  is deprecated; install an adaptable downloader add-on such as
  media/yt-dlp-download and wire its mediaDownload.path (see
  docs/workflows/video-pipeline.md, Migrating from riela/media-download)".
- Warnings do not fail `riela workflow validate` or a run.

### Docs and tests

Docs:

- `docs/workflows/video-pipeline.md`: add the contract, "Plugging in a
  different downloader" (any add-on or step that emits `mediaDownload.path`, or
  a plain path), and "Migrating from riela/media-download". For the migration,
  a workflow package vendors the add-on directory into its own `addons[]`, or
  depends on it through the existing node-addon dependency lock.
- `docs/container-addons.md`, video section: mark the add-on deprecated and
  describe the package container add-on and its egress capability.
- `design-native-source-collection.md` media section: add a pointer.

`Tests/RielaCLITests/MediaPipelineWorkflowDocumentationTests.swift` asserts
that `video-pipeline.md` contains exactly three ```` ```json ```` blocks and
validates the first two as workflows. Keep those three blocks first, in order
and unchanged. They still use `riela/media-download`, which now validates with
a warning and still exits successfully. Place a sentence before them that
points to the migration section. Add new contract and migration snippets as
`json` blocks after them, and update the expected block count. The test keeps
validating only the first two.

Tests:

- The deprecation warning is emitted once and is not an error, and
  non-deprecated media add-ons emit none.
- A `RielaCLITests` package test runs in a temporary project with `HOME` set
  under the test tmp directory. It runs `riela package validate` and a
  project-scope install of `examples/video-pipeline-yt-dlp`. It then validates
  the installed `video-pipeline-yt-dlp` workflow (valid, no unresolved add-on)
  and runs its mock scenario.
- A script contract test runs only when `python3` is available, and otherwise
  calls `XCTSkip`. It runs the entrypoint with a fake `yt-dlp`/`ffmpeg` on
  `PATH` in tmp and asserts: the `mediaDownload` shape, rejection of private
  URLs, rejection of live streams, and a cache hit.

## Rollout and verification

Suggested waves:

1. Wave 1, in parallel because the files are disjoint: C, D and A.
2. Wave 2: B.
3. Wave 3: E.
4. Last, serialized: `rielaExampleWorkflowNames()` gets
   `fanout-include-step-outputs` and `youtube-gateway-read`, and
   `ExampleCatalog.expectedMockScenarioCount` goes up by 2.

Run from an arm64 shell (`arch -arm64 /bin/zsh -lc '…'`):

```bash
swift build
swift test --filter 'YouTubeGatewayReadAddonTests|RielaBuiltinAddonCatalogTests|BuiltinGatewayJSONRequestTests|CatalogWorkflowGatewayValidationTests'
swift test --filter 'DeterministicWorkflowRunnerFanoutTests|DeterministicWorkflowRunnerFanoutResumeTests|PartialFanoutResumeTests|WorkflowGatewayValidationTests'
swift test --filter 'DurableQueueTests|YouTubeCollectionTests'
swift test --filter 'MediaPipelineAddonRegistrationTests|MediaPipelineMediaLogicTests|MediaPipelineWorkflowDocumentationTests|VideoPipelineYtDlpPackageTests'
swift test --filter 'RielaExampleParityTests'
swiftlint lint --strict <changed Swift files>
.build/debug/riela workflow validate youtube-gateway-read --workflow-definition-dir examples
.build/debug/riela workflow validate fanout-include-step-outputs --workflow-definition-dir examples
.build/debug/riela workflow run <each new example> --workflow-definition-dir examples --mock-scenario examples/<name>/mock-scenario.json --session-store tmp/<task>/sessions --output json
```

Logs go under `tmp/youtube-processing-builtins/`.

## Intentional divergences from the request wording

- **Typed-operation engine for A.** A uses the google-service typed-operation
  engine instead of the x-gateway-read/notion GraphQL path, because the pinned
  `YouTubeGatewayCore` has no schema catalog. Registration, validation
  placement, the macOS gating and the docs/example layout still follow the
  notion/x pattern.
- **Package manifest instead of `addon.json` for E.** The `addon.json` scoped
  layout in `design-docs/specs/node-addon-catalog-and-chat-reply-worker/` is not
  implemented. The shipped equivalent is the package node-add-on mechanism
  (`riela-package.json` `addons[]`, projected to
  `~/.riela/addons/<ns>/<name>/<version>/`). The request allows "an equivalent
  host-provided resolver", so the downloader uses it rather than adding a second
  resolver.
- **No delegation for the deprecated add-on.** The deprecated
  `riela/media-download` keeps its own implementation instead of delegating to
  the container add-on. This avoids requiring a container runtime for existing
  ART runs.
- **Cross-workflow validation in the CLI.** Cross-workflow
  `includeStepOutputs` ids are validated in CLI `workflow validate`, where callee
  resolution exists. Core validates only the shape and same-workflow ids.

## Risks

- Join payload drift: the field-absent byte-equality test and the resume rebuild
  test guard it.
- If a directive construction site misses `includeStepOutputs`, resumed joins
  diverge and the receipt conflicts. All three sites are listed above and
  covered by the resume test.
- If the deprecation warning appears in examples or tests that assert zero
  diagnostics, those assertions must be scoped to errors.
- A Linux compile break from `YouTubeGatewayCore` symbols leaking outside
  `#if canImport`. Keep the parsing layer SDK-free.
- The container add-on cannot be live-verified without network and a container
  runtime. Verification relies on package install/validate, a mock run and the
  fake-tool script test.
- Workflows outside the owning package that reference `media/yt-dlp-download`
  resolve at runtime through the shared store, but `workflow validate` requires
  package ownership or a dependency lock. This is existing behavior, and the
  migration doc covers it (see the user-QA file).
