# ypb-08: `riela/youtube-gateway-read` v1 built-in gateway add-on

```json
{
  "planId": "ypb-08-youtube-gateway-read",
  "planPath": "impl-plans/active/youtube-processing-builtins-08-youtube-gateway-read.md",
  "dependsOn": ["ypb-02-youtube-collect-filters"],
  "wave": "W2",
  "writePaths": [
    "Sources/RielaCLI/ProductionNodeAdapter+YouTubeGatewayAddons.swift",
    "Sources/RielaAddons/RielaAddons.swift",
    "Sources/RielaCLI/BuiltinStatefulAddonRegistry.swift",
    "Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift",
    "Tests/RielaCLITests/YouTubeGatewayReadAddonTests.swift",
    "Tests/RielaAddonsTests/RielaBuiltinAddonCatalogTests.swift",
    "docs/builtin-gateway-json.md",
    "examples/youtube-gateway-read",
    "impl-plans/progress/ypb-08-youtube-gateway-read.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design source: `design-docs/specs/design-youtube-processing-builtins.md` §A.

ART needs read-only YouTube API calls as a workflow node. The library is
already pinned in `Package.swift`: `YouTubeGatewayCore` at revision `33006f3a`,
with the product condition `.when(platforms: [.macOS])`. Its public
`YouTubeClient` has:

- `list(_ SubscriptionListOptions) -> SubscriptionPage`
- `videosList(_ VideoListOptions) -> VideoPage`
- `channelsList(_ ChannelListOptions) -> ChannelPage`
- `playlistItemsList(_ PlaylistItemsListOptions) -> PlaylistItemsPage`
- `static fromEnvironment(_ env: [String: String], transport: any HTTPTransport = URLSessionTransport())`

`HTTPTransport` is a public protocol, which is the test seam. The source can be
read under `.build/checkouts/youtube-gateway/Sources/YouTubeGatewayCore/`.

There is no GraphQL catalog, so follow the typed-operation pattern of
`Sources/RielaCLI/ProductionNodeAdapter+GoogleServiceGatewayAddons.swift`:

- `GoogleServiceGatewayAddonEngine.operationArguments`;
- `requestShapeIssue`;
- `parse`;
- `execute`;
- the output envelope `{status, addon, stepId, operation, data}`.

Also follow the env handling and registration of
`Sources/RielaCLI/ProductionNodeAdapter+YouTubeCollect.swift`.

ypb-02 makes `handleYouTubeRequestError(_:)` and
`youtubeFailureMessage(_:_:)` in `YouTubeCollection.swift` module-internal.
Check that before starting:

```bash
grep -n "^func handleYouTubeRequestError" Sources/RielaCLI/YouTubeCollection.swift
```

## Non-goals

- No write operations: no subscription insert or delete, and no
  `onBehalfOfContentOwner*`.
- No riela-side auto-pagination.
- No `ContainerGatewayAddonExecutor` changes. That path is the X/Gmail legacy
  reader container and does not apply.
- No change to `Package.swift`, `Package.resolved`, `YouTubeCollection.swift`,
  `ProductionNodeAdapter.swift` dispatch or `BuiltinGatewayRequestChecks.swift`.
- Do not update `rielaExampleWorkflowNames()` or the mock count. ypb-09 does
  that.

## File-level changes

### `Sources/RielaCLI/ProductionNodeAdapter+YouTubeGatewayAddons.swift` (new)

**SDK-free part**, which must not reference `YouTubeGatewayCore` symbols:

- `enum YouTubeGatewayReadRequest: Equatable, Sendable` with these cases:
  - `subscriptions(filter: Filter, forChannelId: String?, order: String?, parts: [String], maxResults: Int?, pageToken: String?)`,
    where `Filter` is `mine`, `channelId(String)`, `ids([String])`,
    `mySubscribers` or `myRecentSubscribers`;
  - `videos(ids: [String], parts: [String], pageToken: String?)`;
  - `channels(selector: ChannelSelector, parts: [String])`, where the selector
    is `ids`, `forHandle` or `mine`;
  - `playlistItems(selector: PlaylistSelector, parts: [String], maxResults: Int?, pageToken: String?)`,
    where the selector is `playlistId` or `ids`.
- `enum YouTubeGatewayReadEngine` (or a struct) with:
  - `static let addonName = "riela/youtube-gateway-read"`;
  - `static let operationArguments: [String: Set<String>]`, taken exactly from
    the design §A table;
  - `static func requestShapeIssue(config: JSONObject, inputs: JSONObject?) throws`;
  - `static func parse(operation: String, arguments: JSONObject) throws -> YouTubeGatewayReadRequest`.

Rules:

- Config keys are `⊆ {operation, arguments}`, and `operation` is required and
  known.
- `arguments` is an object or an exact placeholder.
- Argument names must be a subset of the operation's set.
- `inputs` cannot be combined with `arguments`.
- `parse` enforces:
  - exactly one filter or selector;
  - `ids` has 1–50 non-empty strings;
  - `maxResults` is an `.integer` in 1–50;
  - `order` is one of `alphabetical`, `relevance` or `unread`;
  - `parts` stays within the per-operation allowlist and defaults per the
    design table;
  - `mine`, `mySubscribers` and `myRecentSubscribers` must be literal `true`.
- Errors are `AdapterExecutionError(.policyBlocked, "riela/youtube-gateway-read …")`.
  They name the field and never include a value that could be a credential.

**macOS part**, inside `#if canImport(YouTubeGatewayCore)`:

- `protocol YouTubeGatewayReadClient: Sendable` with the four SDK methods, and
  `extension YouTubeClient: YouTubeGatewayReadClient {}`.
- `static func execute(_ request: YouTubeGatewayReadRequest, client: any YouTubeGatewayReadClient) async throws -> JSONObject`:
  - map the request to the SDK options;
  - encode the page with `JSONEncoder` and convert it to riela JSON, for
    example through `JSONDecoder().decode(JSONValue.self, from:)`;
  - for errors, call `handleYouTubeRequestError(error)` first, which rethrows
    cancellation and maps auth, configuration and quota errors to
    `policyBlocked`;
  - map any other error to
    `AdapterExecutionError(.providerError, youtubeFailureMessage("YouTube <operation> failed", error))`.

**Resolver entry and registration:**

- `static let youtubeGatewayReadRegistration = BuiltinAddonHandlerRegistration(name: "riela/youtube-gateway-read")`
  with a closure calling `resolver.executeYouTubeGatewayRead(input, context:)`.
- `func executeYouTubeGatewayRead(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext, makeClient: …default…) async throws -> AdapterExecutionOutput`:
  - version is `nil` or `"1"`;
  - run `requestShapeIssue`;
  - render arguments with
    `BuiltinGatewayJSONRequest.renderedArguments(config:variables:addonName:)`
    and `addonVariables(for:)`;
  - run `parse`;
  - addon.env targets must be a subset of
    {`YOUTUBE_GATEWAY_TOKEN_STORE_JSON`, `YOUTUBE_GATEWAY_ACCESS_TOKEN`};
  - resolve them with `resolveAddonEnvironment(_, runtimeEnvironment: environment)`
    and trim whitespace;
  - all blank → `policyBlocked` "Set YOUTUBE_GATEWAY_ACCESS_TOKEN or
    YOUTUBE_GATEWAY_TOKEN_STORE_JSON", which never includes the values;
  - build the client through `makeClient(env)`, which defaults to
    `YouTubeClient.fromEnvironment`; a construction failure is the same
    `policyBlocked`;
  - return the payload
    `["status": "ok", "addon": name, "stepId": input.stepId, "operation": op, "data": page]`;
  - if the encoded payload exceeds 8,000,000 bytes → `.invalidOutput`;
  - use `provider: "youtube-gateway"` and `model: input.addon.name`.
- On non-macOS, after `parse`, throw
  `AdapterExecutionError(.policyBlocked, "youtube-gateway requires macOS")`.

### `Sources/RielaAddons/RielaAddons.swift`

- Add
  `public static let youtubeGatewayAddons: [RielaAddonDescriptor] = [.init(name: "riela/youtube-gateway-read", version: "1")]`
  next to `notionGatewayAddons`.
- Append `+ youtubeGatewayAddons` to the `all` aggregation, right after
  `+ notionGatewayAddons`.

### `Sources/RielaCLI/BuiltinStatefulAddonRegistry.swift`

Add `BuiltinWorkflowAddonResolver.youtubeGatewayReadRegistration` right after
`youtubeCollectionRegistration`.

### `Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift`

Add a case `"riela/youtube-gateway-read"` to `extendedIssues`:

- run `requestShapeIssue`, reporting an issue at `""`;
- if the arguments contain no templates and are not an exact placeholder, run
  `parse` and report its failure as an issue at `"arguments"`.

Mirror `googleServiceIssues`. Routing is already confirmed:

- `BuiltinGatewayRequestChecks.issues` falls through to `extendedIssues` for
  add-ons that are neither GraphQL add-ons nor document add-ons.
- Core `validateGatewayAddon` (`Sources/RielaCore/WorkflowGatewayAddonValidation.swift`)
  calls `addonRequestChecker` for any `riela/` add-on, once no earlier
  diagnostics exist.

So no Core or `BuiltinGatewayRequestChecks.swift` change is needed.

The common pipeline handles `postprocess`, so do not reject a `postprocess`
key in validation or at runtime. Mirror how `GoogleServiceGatewayAddonEngine`
and `BuiltinGatewayRequestChecks.leafConfig` treat it. Add a test: a node with
`operation`, `arguments` and `postprocess` validates and executes with the
postprocess applied.

### `docs/builtin-gateway-json.md`

- Add a table row for `riela/youtube-gateway-read`:
  - input: literal `operation`, object `arguments`;
  - output: no selection, the page is under `data`, shape it with postprocess;
  - checks: operation/argument names, types, ranges, exactly one filter;
  - errors: thrown error, unchanged;
  - example link;
  - runtime: linked SDK, macOS build.
- Add a short section with:
  - the operations table;
  - the pagination loop through `data.nextPageToken` → `arguments.pageToken`;
  - the env bindings, which use `fromEnv` and never inline values.

### `examples/youtube-gateway-read/`

Create `workflow.json`, `mock-scenario.json`, `README.md` and
`EXPECTED_RESULTS.md`.

- `workflowId: "youtube-gateway-read"`.
- Steps:
  - `list` uses `riela/youtube-gateway-read` v1 with
    `{"operation": "subscriptions.list", "arguments": {"mine": true, "maxResults": 25}}`
    and env `{"YOUTUBE_GATEWAY_TOKEN_STORE_JSON": {"fromEnv": "YOUTUBE_GATEWAY_TOKEN_STORE_JSON", "required": false}}`;
  - then `summary`, which uses `riela/json-compose` to summarize
    `{{input.data.items}}` and `{{input.data.nextPageToken}}`.
- The mock scenario returns the envelope for `list`, with two fixture
  subscriptions and a `nextPageToken`. Imitate `examples/notion-gateway-json-sync`.

### Tests

`Tests/RielaCLITests/YouTubeGatewayReadAddonTests.swift` wraps its SDK-touching
tests in `#if canImport(YouTubeGatewayCore)`. Reuse the fake `HTTPTransport`
pattern from `YouTubeCollectionTests.swift`, around line 23.

`Tests/RielaAddonsTests/RielaBuiltinAddonCatalogTests.swift`: add the catalog
assertion.

## Invariants and pitfalls

- The parse and validation layer must compile on Linux. Every
  `YouTubeGatewayCore` type use must be inside `#if canImport`.
- Credentials and the token-store JSON must never appear in errors, output or
  logs.
- Do not add a `riela/youtube-gateway-read` branch to the
  `ProductionNodeAdapter.swift` dispatcher. Use the registry.
- Do not silently clamp `maxResults`. Out-of-range values are errors.

## Tests (situation → expected)

- `subscriptions.list` `{mine: true, maxResults: 25, pageToken: "P2"}` with a
  fake transport → the request query has `mine=true`, `maxResults=25` and
  `pageToken=P2`. `data.nextPageToken` passes through and `status` is `"ok"`.
- `videos.list` `{ids: ["a","b"]}` → `id=a,b` and the default parts
  `snippet,contentDetails,statistics`.
- `channels.list` `{forHandle: "@x"}` → `forHandle=x`.
- `playlistItems.list` `{playlistId: "UU1", maxResults: 50}` → the matching
  query.
- Two filters (`mine` + `channelId`), no filter, `ids: []`, 51 ids,
  `maxResults: 0` or `51`, an unknown argument, an unknown operation,
  `subscriptions.insert`, or `parts: ["statistics"]` on channels → a
  `policyBlocked` error naming the field. The validation issue is reported
  through `BuiltinGatewayRequestChecks.issues`.
- Templated arguments `{"pageToken": "{{input.token}}"}` → only name checks;
  no type issue at validation.
- An env target `OTHER` → policyBlocked. Blank values → policyBlocked, and the
  message has no value.
- A transport returning HTTP 401, 403 with quota, or 500 → the error
  categories as mapped. The message contains no response body. Plant a
  sentinel string in the fake body and assert it is absent.
- The catalog contains `riela/youtube-gateway-read@1`. The stateful registry
  has a unique registration.
- The example `workflow validate` and the mock run succeed. They are run by
  command below and asserted in the test file through `RielaCLIApplication`.

## Verification (evidence)

```bash
mkdir -p tmp/youtube-processing-builtins/ypb-08
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/youtube-processing-builtins/ypb-08/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter "YouTubeGatewayReadAddonTests|RielaBuiltinAddonCatalogTests|BuiltinStatefulAddonRegistryTests|BuiltinGatewayJSONRequestTests|CatalogWorkflowGatewayValidationTests|WorkflowGatewayValidationTests|YouTubeCollectionTests" > tmp/youtube-processing-builtins/ypb-08/test.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && .build/debug/riela workflow validate youtube-gateway-read --workflow-definition-dir examples --output json > tmp/youtube-processing-builtins/ypb-08/validate.json 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && .build/debug/riela workflow run youtube-gateway-read --workflow-definition-dir examples --mock-scenario examples/youtube-gateway-read/mock-scenario.json --session-store tmp/youtube-processing-builtins/ypb-08/sessions --max-steps 20 --output json > tmp/youtube-processing-builtins/ypb-08/run.json 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache "Sources/RielaCLI/ProductionNodeAdapter+YouTubeGatewayAddons.swift" Sources/RielaAddons/RielaAddons.swift Sources/RielaCLI/BuiltinStatefulAddonRegistry.swift "Sources/RielaCLI/BuiltinGatewayRequestChecks+Extended.swift" Tests/RielaCLITests/YouTubeGatewayReadAddonTests.swift Tests/RielaAddonsTests/RielaBuiltinAddonCatalogTests.swift > tmp/youtube-processing-builtins/ypb-08/swiftlint.log 2>&1'
git diff --quiet -- Package.swift Package.resolved Sources/RielaCLI/ProductionNodeAdapter.swift Sources/RielaCLI/YouTubeCollection.swift
```

What each command must show:

- After this plan's final owned edit, build and test must reach exit 0 with 0
  failures at least once. The only exception is a recorded
  `deferred-to-integration` entry whose diagnostics are all in non-owned files.

- build and test: exit 0 with 0 failures.
- validate: exit 0, valid.
- run: exit 0, completed.
- swiftlint: empty log.
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

- Before each edit, read the file fresh and record the pre/post SHA-256.
- Do not run any git write commands.
- Put scratch files under `tmp/youtube-processing-builtins/ypb-08/`.
- Never put real tokens in fixtures. Use obvious fake strings.

## Done criteria

- All tests in the Tests section pass.
- The add-on is in the catalog and the registry.
- The docs row and section are added.
- The example validates and its mock run succeeds.
- The progress log contains the hashes and the verification table.
