# sac-01-control-contract: shared control operation, result, ports and wire envelope

- planId: `sac-01-control-contract`
- wave: 1, dependsOn: none
- design: `design-docs/specs/design-serverless-app-control.md` §3.3, §3.5, §3.10
- writePaths:
  - `Sources/RielaAppSupport/RielaAppControlContract.swift` (new)
  - `Tests/RielaAppSupportTests/RielaAppControlContractTests.swift` (new)
  - `impl-plans/progress/sac-01-control-contract.md` (new, progress log)
- sharedPaths: none
- evidence: `tmp/serverless-app-control/sac-01/`

## Intent and context

RielaApp instance control must work in two ways: over HTTP (`--server`), and
over an App-owned Unix socket when `--server` is absent. Both paths call one
shared service, `RielaAppInstanceControlService`, which sac-04 builds. This
plan only pins the **types** that every later plan compiles against:

- the operation enum;
- the result type;
- the ports protocol;
- the socket wire envelope and its strict decoder;
- the limits;
- the new error codes.

It writes no service logic, no socket I/O and no App or CLI wiring.

## Non-goals

- No edits to existing files. In particular, do not touch
  `RielaAppInstanceReloadContract.swift` or
  `RielaAppInstanceCancelContract.swift`; sac-04 owns the reload contract
  change.
- No socket code (sac-05) and no service implementation (sac-04).

## File-level changes (`Sources/RielaAppSupport/RielaAppControlContract.swift`)

Everything below is `public` and `Sendable`. Use `JSONValue`/`JSONObject` from
`RielaCore`, as `Sources/RielaAppSupport/RielaWebAPIProjection.swift` does.

### 1. `RielaAppControlOperation` (enum, `Equatable`)

```swift
case bootstrap
case reload(identity: String, body: Data)
case run(identity: String, body: Data)
case cancel(identity: String, sessionId: String?, body: Data)
case environmentStatus(identity: String)
case environmentReload(identity: String, body: Data)
case launchStatus(launchId: String)
```

- Also add `var wireName: String`, returning exactly: `bootstrap`,
  `instance.reload`, `instance.run`, `instance.cancel`,
  `environment.status`, `environment.reload`, `launch.status`.
- Add `var isReadOnly: Bool`, true for `bootstrap`, `environmentStatus` and
  `launchStatus`.

### 2. `RielaAppControlResult` (struct, `Equatable`)

```swift
public var status: Int
public var body: JSONValue
public init(status: Int, body: JSONValue)
```

Add these static helpers:

- `static func error(status: Int, code: String, message: String? = nil) -> RielaAppControlResult`
  produces `{"error":{"code":…,"message":…}}`. The `message` key is present
  only when non-nil, which matches `webConfiguredRunResponse` (no message) and
  `instanceAPIError` (with message).
- `init(httpResponse: RielaHTTPResponse)` decodes `body` as `JSONValue`; an
  empty or undecodable body becomes `.null`.
- `var httpResponse: RielaHTTPResponse` returns `RielaHTTPResponse.json(status:…, body)`.
  Find the existing `.json` factory in `Sources/RielaServer` and reuse it.

### 3. `RielaAppControlBootstrap` (struct, `Codable`, `Equatable`)

Fields: `profile: String`, `revision: Int`.

### 4. `RielaAppControlConflict` (struct, `Error`, `Equatable`)

Fields: `code: String`, `message: String`, `status: Int`. This is the
App-mapped form of a revision/profile validation failure; the App adapter maps
`RielaConfigurationGraphQLError` into it.

### 5. `RielaAppEnvironmentReloadOutcome` (enum)

```swift
case reloaded(RuntimeEnvironmentStatus)
case notReady
case failed(RuntimeEnvironmentStatus)   // status.lastError already set
```

### 6. `RielaAppConfiguredRunInput` (struct, `Equatable`)

Fields: `expectedProfile: String`, `expectedRevision: Int`,
`variables: JSONObject`, `allowOverlap: Bool?`.

### 7. `RielaAppInstanceControlPorts` (protocol, `Sendable`)

These are the exact requirements:

```swift
func profile() async -> String
func bootstrap() async -> RielaAppControlBootstrap
func isShuttingDown() async -> Bool
func serialized(_ body: @escaping @Sendable () async -> RielaAppControlResult) async -> RielaAppControlResult
func reloadPorts() -> any RielaAppInstanceReloadPorts
func cancelPorts() -> any RielaAppInstanceCancelPorts
func validateRevision(expectedRevision: Int, expectedProfile: String) async -> RielaAppControlConflict?
func instanceExists(identity: String) async -> Bool
func environmentStatus(identity: String) async -> RuntimeEnvironmentStatus
func reloadEnvironment(identity: String) async -> RielaAppEnvironmentReloadOutcome
func launchConfiguredRun(identity: String, input: RielaAppConfiguredRunInput) async -> RielaAppControlResult
func launchStatus(launchId: String, profile: String) async -> RielaAppControlResult
```

### 8. `RielaAppControlLimits` (enum namespace of static lets)

| Name | Value |
| --- | --- |
| `maxRequestFrameBytes` | `589_824` |
| `maxResponseFrameBytes` | `1_048_576` |
| `requestReadDeadlineSeconds` | `5` |
| `connectTimeoutSeconds` | `2` |
| `responseTimeoutSeconds` | `30` |
| `idempotencyTTLSeconds` | `600` |
| `idempotencyCapacity` | `512` |
| `maxSocketPathBytes` | `103` |
| `reloadBodyMaxBytes` | `65_536` |
| `runBodyMaxBytes` | `524_288` |
| `localReloadCapSeconds` | `30` |

### 9. `RielaAppControlErrorCode` (`String` raw enum)

Cases: `app_not_running`, `app_channel_unavailable`, `app_channel_insecure`,
`app_channel_path_too_long`, `app_channel_timeout`,
`app_channel_protocol_error`, `request_too_large`, `invalid_request`,
`request_id_conflict`, `channel_busy`. Use camelCase case names with raw
snake values.

### 10. `RielaAppControlRequestEnvelope` (struct, `Equatable`)

Fields:

- `version: Int` (must be 1)
- `requestId: String`
- `operation: RielaAppControlOperation`
- `profile: String`

Requirements:

- `static func decodeStrict(_ data: Data) throws -> RielaAppControlRequestEnvelope`.
  The top-level JSON object must have **exactly** these keys: `version`,
  `requestId`, `operation`, `profile`, `identity`, `sessionId`, `launchId`,
  `body`. Each value may be JSON `null` where noted. Rules:
  - `requestId` matches a lowercase UUID:
    `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`.
  - `profile` is 1…128 UTF-8 bytes.
  - `identity`: required and 1…1024 bytes for every operation except
    `bootstrap` and `launch.status`, where it must be null.
  - `sessionId`: optional for `instance.cancel` only (null or 1…1024 bytes);
    null elsewhere.
  - `launchId`: required (1…1024 bytes) for `launch.status` only; null
    elsewhere.
  - `body`: a JSON object for `instance.reload`, `instance.run`,
    `instance.cancel` and `environment.reload`; null elsewhere.
  - The operation is converted with `body` re-encoded to `Data` by
    `JSONEncoder` (`.sortedKeys`).
  - Any violation throws `RielaAppControlEnvelopeError.invalidRequest`.
- `func encoded() throws -> Data` writes all 8 keys, with explicit `null` for
  absent fields.
- `func digest() throws -> String` is `JSONCanonical.sha256Hex` (see
  `Sources/RielaCore/JSONCanonical.swift:29`) over the canonical sorted-keys
  encoding of the envelope **without** `requestId`.

### 11. `RielaAppControlResponseEnvelope` (struct, `Codable`, `Equatable`)

Fields: `version: Int`, `requestId: String`, `status: Int`, `body: JSONValue`.
Add `static func decodeStrict(_:)` with an exact key set of 4 keys.

### 12. `RielaAppControlEnvelopeError` (enum, `Error`)

Cases: `invalidRequest`, `invalidResponse`.

## Pitfalls

- Use `JSONSerialization` or `JSONValue` decoding to check the key set. A
  synthesized `Decodable` silently ignores extra keys, which is the wrong
  approach.
- `null` versus an absent key: an absent key is invalid, `null` is valid where
  allowed.
- `RuntimeEnvironmentStatus` lives in `RielaAppSupport/RuntimeEnvironmentSnapshot.swift:29`;
  reuse it, do not copy it.
- Do not add a CSRF or Origin field to the envelope (design §3.5).

## Tests (`RielaAppControlContractTests`)

- A valid envelope for each of the 7 operations decodes, round-trips through
  `encoded()`, and keeps `wireName`.
- An extra key, a missing key, `version` 2, an uppercase or non-UUID
  `requestId`, an empty profile or a 129-byte profile, or `identity` non-null
  for bootstrap → `invalidRequest`.
- `instance.cancel` with `sessionId` null → valid; `instance.run` with a
  non-null `sessionId` → `invalidRequest`.
- Two envelopes that differ only in `requestId` have equal `digest()`. A
  changed body or reordered body keys behave as follows: semantic equality
  gives an equal digest, and a different value gives a different digest.
- `RielaAppControlResult.error(status:400, code:"invalid_configured_run")`
  encodes to `{"error":{"code":"invalid_configured_run"}}` with no `message`
  key.
- `RielaAppControlResult(httpResponse:)` round-trips the status and body with
  `httpResponse`.
- The response envelope's strict decode rejects an extra key.

## Verification (evidence under `tmp/serverless-app-control/sac-01/`)

- `mkdir -p tmp/serverless-app-control/sac-01`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/serverless-app-control/sac-01/build.log 2>&1`
  must exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter RielaAppControlContractTests" > tmp/serverless-app-control/sac-01/test.log 2>&1`
  must exit 0, with all tests passed.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaAppSupport/RielaAppControlContract.swift Tests/RielaAppSupportTests/RielaAppControlContractTests.swift' > tmp/serverless-app-control/sac-01/lint.log 2>&1`
  must report 0 serious violations.
- `git status --short` must show only this plan's writePaths changed.

Wave-1 siblings build in the same tree. If an unrelated sibling's half-edit
breaks the build, record it in the progress log and rerun after the sibling
settles. Never edit a sibling's files.

## Done criteria

- All 12 symbols exist with the exact names and signatures above (checked by
  `grep -n` in the progress log).
- The tests pass, and the logs exist with exit 0.
- The progress log `impl-plans/progress/sac-01-control-contract.md` records the
  commands, exit codes, log paths, and pre/post `shasum` of the owned files.

## Progress-log and drift rules (all plans)

- Re-read every owned file immediately before each edit.
- Record a `shasum -a 256` of each owned file before the first edit and after
  the last edit.
- If a file you own changed unexpectedly between your edits (drift), stop,
  record it, and re-apply your intent from your immutable intent notes in the
  progress log. Never revert another plan's edits.
