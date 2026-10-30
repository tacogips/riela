# sgc-02-default-retention: built-in default retention policy

**Status**: Ready
**planId**: sgc-02-default-retention
**dependsOn**: none (wave W1)
**Design Reference**: design-docs/specs/design-session-storage-efficiency-and-default-gc.md §4 (and §9 retention/gc tests); QA Q1-Q3
**Progress log**: impl-plans/progress/sgc-02-default-retention.md
**Evidence root**: tmp/session-storage-gc/sgc-02-default-retention/

## Intent and context

Today a missing `retention` config means that automatic passes and
`riela gc` delete nothing. `RielaRetentionConfiguration.policy(for:)` returns
`nil`, and `RielaRetentionService.run` drops nil-policy targets on automatic
triggers (`Sources/RielaCLI/RielaRetentionService.swift:151-157`).

The accepted design adds `RielaRetentionPolicy.builtInDefault`:

- results `maxAgeDays: 30`;
- messages follow results (state `notConfigured`, today's behavior);
- logs `maxAgeDays: 30`;
- no default byte cap;
- automatic `true`, `minIntervalMinutes` 60, definitions unchanged.

The default fills each category the config leaves absent. The planner,
protections, locks and tombstones are reused unchanged
(`Sources/RielaCore/TerminalRetentionPlan.swift`; terminal means
`completed|failed|cancelled`, line 128).

Existing code to imitate:

- `Sources/RielaCore/RielaRetentionConfiguration.swift`: `RielaRetentionPolicy`,
  `RielaRetentionCategory.state`, `load(homeDirectory:projectDirectory:environment:fileManager:)`
  (env `RIELA_RETENTION_AUTOMATIC`, lines 132-145), `parseCategory`.
- `Sources/RielaCore/RielaRetentionReport.swift`: `RetentionCategoryReport`
  and `.inactive(_:)`.
- `Sources/RielaCLI/RielaRetentionService.swift`: `run`, `runTarget`, the
  generated sweep gate (lines 277-288), and `apply(_ overrides:to:)`.
- `Sources/RielaCLI/GarbageCollectionCommand.swift`: `renderText` and
  `renderCategory` (line 64-68 prints "no cap"), and the `CommandConfiguration`
  abstract and discussion used by `riela gc --help`.

## Non-goals

- No change to `TerminalRetentionPlan`, `TerminalRetentionExecutor`,
  protections, locks, tombstones, log-pruner rules or reclaimer behavior.
- No default byte caps (QA Q1).
- No storage maintenance, conversion or doctor work. Those belong to sgc-03
  and sgc-04.
- No README or docs edits (sgc-05), and no `RielaCLIApplication.swift` help
  edit (the flags are unchanged).
- Do not remove or rename the existing optional `userPolicy`, `projectPolicy`
  or `policy(for:)`. They keep meaning "configured policy" for existing
  callers and tests.

## Contract (pinned; sgc-03 and sgc-04 compile against it)

```swift
public enum RielaRetentionPolicySource: String, Codable, Equatable, Sendable { case configured, builtInDefault = "default", override }
public struct RielaRetentionPolicySources: Codable, Equatable, Sendable { public var results, messages, logs: RielaRetentionPolicySource }
public struct RielaEffectiveRetentionPolicy: Equatable, Sendable { public var policy: RielaRetentionPolicy; public var sources: RielaRetentionPolicySources }
extension RielaRetentionPolicy { public static let builtInDefault: RielaRetentionPolicy }
extension RielaRetentionConfiguration { public func effectivePolicy(for kind: RielaRetentionTargetKind) -> RielaEffectiveRetentionPolicy }
// RetentionCategoryReport gains: public var policySource: RielaRetentionPolicySource?  (init parameter defaulted to nil; inactive(_:) keeps nil)
```

## File-level changes

### 1. `Sources/RielaCore/RielaRetentionConfiguration.swift`

- Add the contract types and `builtInDefault`, using the values above.
- `RielaRetentionConfiguration` stores the parsed env automatic override
  (`automaticOverride: Bool?`) in addition to today's optional policies, so
  that `RIELA_RETENTION_AUTOMATIC` also applies when no `retention` object
  exists. Today it is applied only through `userPolicy?.automatic = ...`.
  Keep that behavior for the configured policies, and also record the value.
- **`effectivePolicy(for:)`.**
  - Start from `policy(for:)`, the configured policy.
  - If it is `nil`, use `builtInDefault` with every category sourced
    `builtInDefault`.
  - Otherwise fill each category separately. A results or logs category whose
    `state == .notConfigured` takes the default `maxAgeDays: 30` and keeps any
    `keepWorkflowIds`; its source is `builtInDefault`. A messages
    `notConfigured` category stays `notConfigured` (follow results) with
    source `builtInDefault`. Any `keepForever` or explicit-limit category is
    `configured`.
  - Finally apply `automaticOverride` if it is set.
- Validation rules, precedence (env `RIELA_RETENTION` > project > user), and
  the removed-key errors are unchanged.

### 2. `Sources/RielaCore/RielaRetentionReport.swift`

- Add `policySource: RielaRetentionPolicySource?` to `RetentionCategoryReport`
  as a stored property and as a defaulted init parameter (`= nil`), so that no
  existing call site breaks.

### 3. `Sources/RielaCLI/RielaRetentionService.swift`

- **`run`.** Use `configuration.effectivePolicy(for: target.kind)`. On automatic
  triggers, skip a target only when `!policy.automatic`. Overrides
  (`apply(_:to:)`) set the overridden category's source to `.override`. Keep
  the existing `keepForever` override error.
- **Reports.** Set `policySource` on the results, messages and logs reports
  after `runTarget` builds them. Use the sources of the effective policy after
  overrides are applied.
- **Generated sweep (design §4.3).** Change the gate at lines ~277 to
  `results.state == .active && results.maxAgeDays != nil && sources.results != .builtInDefault`.
  A defaulted policy must never call `RielaDataGarbageCollector`.
- Everything else in `runTarget` is unchanged. Results become `active` with
  defaults, so the planner prunes terminal families older than 30 days and
  messages follow.

### 4. `Sources/RielaCLI/GarbageCollectionCommand.swift`

- **Text output.**
  - When `policySource == .builtInDefault` and `policy.maxAgeDays` is set,
    `renderCategory` prints `older than <N> days (built-in default)`.
  - For messages that follow results, it prints
    `follow results (built-in default)`.
  - It prints "no cap" only when a category is genuinely `active` with no
    byte cap AND its source is not the default. In that case the cap text
    stays as today.
- **JSON output.** It gains `policySource` automatically through `Codable`.
- **`--help` discussion.** State the defaults (results 30 days, messages with
  results, logs 30 days, no byte cap) and the opt-outs
  (`{"keepForever": true}` per category, `"automatic": false`,
  `RIELA_RETENTION_AUTOMATIC=0`).

## Pitfalls

- **Invariant change.** "No config means no deletion" is intentionally
  replaced. Every existing test that asserted it must be updated to the new
  rule, not deleted. Each updated test must still assert that running,
  suspended, created, locked and tree-member families are kept.
- **Defaulting messages.** Defaulting messages to an age limit would switch
  them to independent messages-only pruning with tombstones. That is wrong.
  Messages stay "follow results".
- **`keepWorkflowIds`.** `keepWorkflowIds` without limits must not disable
  the default age. It becomes the default age plus the kept ids.
- **Dry runs.** A dry run still writes nothing: no stamp, no lock and no
  tombstone tables.
- **Explicit targets** use the user effective policy, as today.

## Tests

`Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift`:

- No config: `effectivePolicy(for: .user)` equals `builtInDefault`, with all
  sources `builtInDefault`, and `userPolicy` is still `nil`.
- `{"retention":{"logs":{"maxAgeDays":7}}}`: results `maxAgeDays` 30
  (`builtInDefault`), logs 7 (`configured`), messages `notConfigured`
  (`builtInDefault`).
- `{"retention":{"results":{"keepForever":true}}}`: results stay
  `keepForever` (`configured`) and logs are defaulted.
- `{"retention":{"results":{"keepWorkflowIds":["a"]}}}`: `maxAgeDays` 30 and
  `keepWorkflowIds == ["a"]`.
- `RIELA_RETENTION_AUTOMATIC=0` with no config gives
  `effectivePolicy.policy.automatic == false`.
- Existing assertions that the configured policy is `nil` stay valid. Keep
  them.

`Tests/RielaCLITests/RielaRetentionServiceTests.swift`,
`Tests/RielaCLITests/AutomaticRetentionTests.swift` and
`Tests/RielaCLITests/TerminalRetentionPolicyTests.swift` (update the
no-config cases):

- No config and an automatic pass: a completed family that is 31 days old is
  removed. A 29-day-old completed family is kept. Running, suspended, created
  and lock-held families, and a family whose member is a non-terminal child,
  are all kept (`protected` reasons are reported).
- No config: the generated sweep does not run. A workflow-history snapshot
  older than 30 days still exists, and `generated.removedEntryCount == 0`.
- `results.keepForever`: the results are kept while logs older than 30 days
  are removed.
- `"automatic": false`: the automatic pass removes nothing, while manual
  `riela gc` still applies the defaults.
- The report's `policySource` is `default` for defaulted categories and
  `override` for a flag-overridden category.

`Tests/RielaCLITests/GarbageCollectionCommandTests.swift`:

- `riela gc --dry-run --output json` with no config: results
  `policy.maxAgeDays == 30`, `policySource == "default"`, a non-zero
  `selectedCount` for an old family, and nothing written (no `retention/`
  state dir and no tombstone table).
- `riela gc` with no config removes the old terminal family and exits 0.
- The text output contains `(built-in default)` and does not contain
  `no cap` for defaulted categories.
- `--results-max-age-days 5` gives `policySource == "override"`.

`Tests/RielaCLITests/StorageCompactCommandTests.swift`:

- Update cases that expected `prune: notConfigured` with no config. The prune
  step now reports the default policy.

## Acceptance criteria

- `rg -n "builtInDefault|effectivePolicy|policySource" Sources/RielaCore Sources/RielaCLI`
  shows the contract and its uses.
- The generated sweep is gated on a non-default source (a test proves it).
- All listed suites pass. No test asserting "no config means no deletion"
  remains.

## Verification (every log must end with `exit=0`)

Build cache: writes to `.build/` and `.swiftpm/` by these commands are
authorized and untracked. They are not part of `writePaths`, `sharedPaths` or
`artifactRoots`, and `artifactRoots` is intentionally empty. See the index
`impl-plans/active/session-storage-gc.md`, Shared execution rules, "Build
cache". Never block on them.

```
mkdir -p tmp/session-storage-gc/sgc-02-default-retention
arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/session-storage-gc/sgc-02-default-retention/build.log; echo "exit=$?" >> tmp/session-storage-gc/sgc-02-default-retention/build.log'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "RielaRetentionConfiguration|RielaRetentionService|AutomaticRetention|TerminalRetentionPolicy|GarbageCollection|StorageCompact|RetentionLogPruner|RetentionReclamation" 2>&1 | tee tmp/session-storage-gc/sgc-02-default-retention/test.log; echo "exit=$?" >> tmp/session-storage-gc/sgc-02-default-retention/test.log'
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Sources/RielaCore/RielaRetentionConfiguration.swift Sources/RielaCore/RielaRetentionReport.swift Sources/RielaCLI/RielaRetentionService.swift Sources/RielaCLI/GarbageCollectionCommand.swift 2>&1 | tee tmp/session-storage-gc/sgc-02-default-retention/lint.log'
```

What each command must show:

- `build.log`: `exit=0`.
- `test.log`: `exit=0` and 0 failures.
- `lint.log`: no new violations.

## Progress-log expectations

Record in `impl-plans/progress/sgc-02-default-retention.md`:

- file hashes before and after;
- each command with its exit code and log path;
- every test that changed from "no deletion" to the default rule, with the
  reason;
- any other failing suite outside `writePaths`, for reconciliation.
