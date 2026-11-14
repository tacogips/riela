# ar-01-core-config: retention configuration and report DTOs (RielaCore)

```json
{
  "planId": "ar-01-core-config",
  "planPath": "impl-plans/active/automatic-retention-01-core-config.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCore/RielaRetentionConfiguration.swift",
    "Sources/RielaCore/RielaRetentionReport.swift",
    "Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift",
    "impl-plans/progress/ar-01-core-config.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

The user wants one retention policy in `config.json` to replace
`gc.retentionDays`, with no alias. Design §2 gives the shape, the validation
rules and the precedence. Today `Sources/RielaCore/RielaDataGarbageCollector.swift`
contains `RielaGarbageCollectionConfiguration` (lines 9-59). This plan adds the
new type alongside it. Do not delete the old type: ar-09 deletes it after its
last users are rewritten. This plan also pins the per-category report DTO that
ar-05, ar-06 and ar-07 share.

Follow the shared worker protocol in `impl-plans/completed/automatic-retention.md`.

## Non-goals

- Do not touch `RielaDataGarbageCollector.swift`, any CLI file or any App file.
- No filesystem pruning and no executor logic.
- No GraphQL or SDL change.

## File-level changes

### `Sources/RielaCore/RielaRetentionConfiguration.swift` (new)

Pinned public contract:

```swift
public enum RielaRetentionTargetKind: String, Codable, Equatable, Sendable { case user, project, explicit }
public enum RielaRetentionCategoryState: String, Codable, Equatable, Sendable { case keepForever, active, notConfigured }
public struct RielaRetentionCategory: Codable, Equatable, Sendable {
  public var keepForever: Bool; public var maxAgeDays: Int?; public var maxTotalBytes: Int64?
  public var keepWorkflowIds: [String]          // results only
  public var state: RielaRetentionCategoryState { get }
}
public struct RielaRetentionPolicy: Codable, Equatable, Sendable {
  public var automatic: Bool                    // default true
  public var minIntervalMinutes: Int            // default 60, 1...10080
  public var results: RielaRetentionCategory; public var messages: RielaRetentionCategory; public var logs: RielaRetentionCategory
}
public struct RielaRetentionConfiguration: Equatable, Sendable {
  public var userPolicy: RielaRetentionPolicy?      // nil when no retention anywhere for user/explicit targets
  public var projectPolicy: RielaRetentionPolicy?   // effective policy for the project target
  public static func load(homeDirectory: URL, projectDirectory: URL?, environment: [String: String],
                          fileManager: FileManager = .default) throws -> RielaRetentionConfiguration
  public func policy(for kind: RielaRetentionTargetKind) -> RielaRetentionPolicy?
}
public enum RielaByteSize { public static func parse(_ text: String) throws -> Int64 }
public enum RielaRetentionConfigurationError: Error, Equatable, LocalizedError {
  case removedKey(String)                          // "gc" or "RIELA_GC_RETENTION_DAYS"
  case invalid(path: String, reason: String)       // path like "retention.results.maxAgeDays"
}
```

Load rules (design §2.2 and §2.3):

1. Read `<home>/.riela/config.json` and, when `projectDirectory` is not nil,
   `<project>/.riela/config.json`. A missing file is fine. Top-level JSON must be
   an object. Malformed JSON gives `.invalid(path: <file path>, reason:)`.
2. A top-level `gc` key in either file throws `.removedKey("gc")`.
   `RIELA_GC_RETENTION_DAYS`, when present and not empty, throws
   `.removedKey("RIELA_GC_RETENTION_DAYS")`. `errorDescription` for either case
   is exactly `gc.retentionDays was removed; configure "retention" (see riela gc --help)`.
3. Other unknown top-level keys are ignored.
4. Inside `retention` and inside each category, unknown keys are errors.
   `keepWorkflowIds` is allowed only under `results`. Under `messages` or `logs`
   it is an unknown-key error.
5. `keepForever: true` together with `maxAgeDays` or `maxTotalBytes` in the same
   category is an error.
6. Value checks:
   - `maxAgeDays`: integer 1...36500.
   - `maxTotalBytes`: a JSON integer 1...2^50, or a string parsed by
     `RielaByteSize.parse`.
   - `keepWorkflowIds`: strings that are non-empty after trimming, each at most
     512 UTF-8 bytes.
   - `minIntervalMinutes`: 1...10080.
7. `RIELA_RETENTION`, when present and not empty, is JSON for the `retention`
   object, with the same strict validation. It sets both `userPolicy` and
   `projectPolicy`, and the files are then ignored. The files are still parsed
   for the removed-key check, so a `gc` key still errors.
8. Without `RIELA_RETENTION`:
   - `userPolicy` = the user file's `retention`.
   - `projectPolicy` = the project file's `retention` if it is present, else
     `userPolicy`. The project object replaces the user policy as a whole; there
     is no field merge.
   - When `projectDirectory` standardizes to the home directory, the project file
     is the user file.
9. `RIELA_RETENTION_AUTOMATIC` applies last, to both policies when they are not
   nil. Accepted values are `true`, `false`, `1` and `0`, case-insensitive. Any
   other value is `.invalid(path: "RIELA_RETENTION_AUTOMATIC", ...)`. It never
   creates a policy when none exists.
10. `policy(for: .explicit)` returns `userPolicy`.

`RielaByteSize.parse` accepts the regex
`^[0-9]+ ?(B|KB|MB|GB|TB|KiB|MiB|GiB|TiB)$` with case-insensitive units.
KB/MB/GB/TB are 1000-based and KiB/MiB/GiB/TiB are 1024-based. The result must
be 1...2^50. Decimals, negatives, empty strings and overflow throw `.invalid`.
Bare digits without a unit inside a string are rejected; only JSON integers may
omit the unit.

### `Sources/RielaCore/RielaRetentionReport.swift` (new)

Pinned shared DTO:

```swift
public struct RetentionPolicySnapshot: Codable, Equatable, Sendable { public var maxAgeDays: Int?; public var maxTotalBytes: Int64? }
public struct RetentionProtectedFamily: Codable, Equatable, Sendable { public var rootId: String; public var reason: String }
public struct RetentionCategoryReport: Codable, Equatable, Sendable {
  public var state: RielaRetentionCategoryState
  public var policy: RetentionPolicySnapshot?
  public var selectedCount: Int; public var removedCount: Int
  public var selectedBytes: Int64; public var removedBytes: Int64
  public var beforeBytes: Int64; public var remainingBytes: Int64
  public var capAchieved: Bool?            // nil when no cap configured
  public var protected: [String: Int]      // reason -> count
  public var protectedFamilies: [RetentionProtectedFamily]   // first 50, sorted by rootId
  public var pendingCleanupCount: Int; public var workLimitReached: Bool; public var orphanSessionCount: Int
  public static func inactive(_ state: RielaRetentionCategoryState) -> RetentionCategoryReport  // all zero, policy nil
}
```

Give every field a memberwise public init.

## Patterns to imitate

- Decoding and validation style: `RielaDataGarbageCollector.swift:RielaGarbageCollectionConfiguration.load`
  and its `LocalizedError` extension.
- Strict key checking: use `JSONSerialization` to get `[String: Any]`, then
  validate keys explicitly. This is simpler than `Codable` with `allKeys`, and
  either is acceptable.

## Pitfalls

- An empty category object `{}` and an absent category both mean
  `notConfigured`. They are not errors.
- `automatic` defaults to true only when a `retention` object exists. An absent
  `retention` means the policy is nil.
- JSON numbers decoded through `JSONSerialization` arrive as `NSNumber`. Reject
  booleans where an integer is required: `NSNumber` true would otherwise read as 1.
- Do not read the real HOME. Every path is derived from the `homeDirectory`
  argument.

## Tests (`Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift`, class `RielaRetentionConfigurationTests`)

- no config files, empty env -> `userPolicy == nil`, `projectPolicy == nil`
- `{"retention":{"results":{"maxAgeDays":30}}}` -> automatic true, interval 60,
  results active, messages and logs notConfigured
- the keep-forever example from design §2.1 -> results and messages keepForever,
  logs active with `maxTotalBytes == 1_000_000_000`
- `"5GB"` -> 5_000_000_000; `"1GiB"` -> 1_073_741_824; `"1.5GB"`, `"-1MB"`,
  `"12"`, `"0B"` -> `.invalid`
- `{"gc":{"retentionDays":30}}` -> `.removedKey("gc")`, with the exact message
- `RIELA_GC_RETENTION_DAYS=14` -> `.removedKey`
- an unknown key `retention.results.maxAge` -> `.invalid` whose path names that key
- `keepWorkflowIds` under `logs` -> `.invalid`
- `keepForever: true` with `maxAgeDays` -> `.invalid`
- `maxAgeDays: 0` or `36501` -> `.invalid`; `minIntervalMinutes: 0` -> `.invalid`
- a project file with its own retention -> `policy(for: .project)` is the project
  policy and `policy(for: .user)` is the user policy
- `RIELA_RETENTION` set -> both policies equal the env policy and the file values
  are ignored
- `RIELA_RETENTION_AUTOMATIC=false` -> `automatic == false` on both; `=maybe` ->
  `.invalid`; with no retention it stays nil
- unknown top-level key `{"theme":"x"}` -> ignored, no error
- `RetentionCategoryReport.inactive(.keepForever)` round-trips through
  `JSONEncoder` and `JSONDecoder` unchanged

## Verification

1. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter RielaRetentionConfigurationTests > tmp/automatic-retention/ar-01-core-config/test.log 2>&1'
   ```
   Must show exitStatus 0, testsRun ≥ 15 and failureCount 0.
2. ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCore/RielaRetentionConfiguration.swift Sources/RielaCore/RielaRetentionReport.swift Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift > tmp/automatic-retention/ar-01-core-config/swiftlint.log 2>&1'
   ```
   Must exit 0 with no output.

## Done criteria

- `grep -n "public static func load(homeDirectory: URL, projectDirectory: URL?" Sources/RielaCore/RielaRetentionConfiguration.swift`
  matches.
- `grep -n "struct RetentionCategoryReport" Sources/RielaCore/RielaRetentionReport.swift`
  matches.
- Both verification records exist in `impl-plans/progress/ar-01-core-config.md`
  with integer fields.
- `RielaDataGarbageCollector.swift` is unchanged
  (`git diff --quiet -- Sources/RielaCore/RielaDataGarbageCollector.swift` exits 0).
