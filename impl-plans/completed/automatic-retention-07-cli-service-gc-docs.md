# ar-07-cli-service-gc-docs: retention service, `riela gc` front door, docs (RielaCLI)

```json
{
  "planId": "ar-07-cli-service-gc-docs",
  "planPath": "impl-plans/active/automatic-retention-07-cli-service-gc-docs.md",
  "dependsOn": [],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/RielaRetentionService.swift",
    "Sources/RielaCLI/GarbageCollectionCommand.swift",
    "Tests/RielaCLITests/RielaRetentionServiceTests.swift",
    "Tests/RielaCLITests/GarbageCollectionCommandTests.swift",
    "README.md",
    "docs/terminal-retention.md",
    "Resources/skills/riela-workflow-run/SKILL.md",
    "impl-plans/progress/ar-07-cli-service-gc-docs.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Tests/RielaCLITests/CommandParsingTests.swift"
  ],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/RielaCLIApplication.swift", "intendedEdit": "Replace only the `riela gc [...]` usage line in rielaCLIHelpText (currently line 322) with the new flag list; no other change."},
    {"path": "Tests/RielaCLITests/CommandParsingTests.swift", "intendedEdit": "Replace only the gc passthrough parsing case (currently lines 52-60) so it uses `--results-max-age-days 30` instead of `--retention-days 30`; no other change."}
  ]
}
```

## Resume note (2026-10-19)

Session 452 blocked this plan on two items. Both are resolved, so do not report them again:

1. `CommandParsingTests.testArgumentParserRegistersEveryTopLevelClientCommand` failed on
   `main` because its expected set omitted the existing `cache` and `gateway` commands. The
   operator added both names to the expected set in the working tree (shared path of this plan).
   The required aggregate command now passes.
2. Runtime-database reclamation ran twice and ignored the injected `freeSpace`. The operator
   fixed `TerminalRetentionExecutor` (stored `reclaimer`, single reclamation in `finalize`,
   `runPolicy(... reclamationMode:)`) in commit 10e9aa6e, and wired it in
   `RielaRetentionService` (`makeExecutor()`, `reclamationMode(_:)`) with the regression test
   `testManualRunReclaimsRuntimeDatabaseOnceThroughInjectedFreeSpace`.

ar-05 and ar-06 are accepted and committed in 10e9aa6e. Keep the existing work in progress, finish
the remaining plan items, rerun the exact verification commands and submit the result.

## Intent and context

Design §2 (policy resolution and overrides), §3 (targets), §5 (throttle, lock,
order, bounds) and §6.2 (the `riela gc` contract and report), plus the docs in
§9. This plan wires ar-01 (config), ar-05 (executor), ar-06 (targets, state,
logs), the existing generated sweep `RielaDataGarbageCollector.collect`, and
ar-03 (reclaimer, through ar-05) into one service. Automatic triggers (ar-08),
RielaApp (ar-09) and the manual command all call this service.

Follow the shared worker protocol in `impl-plans/completed/automatic-retention.md`.

## Non-goals

- No trigger wiring in `EntryPoint.swift`, serve or events (ar-08).
- No RielaApp changes (ar-09).
- Do not delete `RielaGarbageCollectionConfiguration` (ar-09). After this plan,
  just stop using it.
- No GraphQL or SDL change (design §6.3).
- `session prune` flags stay unchanged.

## File-level changes

### `Sources/RielaCLI/RielaRetentionService.swift` (new; public, because RielaApp uses it)

Pinned contract:

```swift
public enum RielaRetentionTrigger: String, Codable, Sendable { case automatic, manual }
public struct RielaRetentionOverrides: Equatable, Sendable {
  public var resultsMaxAgeDays: Int?; public var resultsMaxTotalBytes: Int64?
  public var messagesMaxAgeDays: Int?; public var messagesMaxTotalBytes: Int64?
  public var logsMaxAgeDays: Int?; public var logsMaxTotalBytes: Int64?
  public var isEmpty: Bool { get }
}
public struct RielaRetentionRequest: Sendable {
  public var trigger: RielaRetentionTrigger; public var homeDirectory: URL; public var projectDirectory: URL?
  public var explicitSessionStore: String?; public var environment: [String: String]
  public var scope: RielaGarbageCollectionScope; public var overrides: RielaRetentionOverrides; public var dryRun: Bool
}
public struct RielaRetentionTargetReport: Codable, Equatable, Sendable {
  public var kind: RielaRetentionTargetKind; public var root: String
  public var status: String   // completed|skippedThrottled|skippedBusy|busy|skippedUnsafePath|failed
  public var results: RetentionCategoryReport; public var messages: RetentionCategoryReport; public var logs: RetentionCategoryReport
  public var generated: Generated   // { removedEntryCount: Int; removedBytes: Int64 }
  public var orphanLocks: OrphanLocks?  // { selectedCount, removedCount, skippedBusy }
  public var reclamation: [Reclamation] // mirrors RetentionReclamationResult fields, actions as strings
  public var warnings: [String]
}
public struct RielaRetentionReport: Codable, Equatable, Sendable {
  public var dryRun: Bool; public var trigger: RielaRetentionTrigger; public var targets: [RielaRetentionTargetReport]
  public var hasFailure: Bool { get }   // any target status failed or busy
}
public enum RielaRetentionUsageError: Error, Equatable, LocalizedError { case keepForeverOverride(category: String), invalidOverride(String) }
public struct RielaRetentionService: Sendable {
  public init(clock: @escaping @Sendable () -> Date = Date.init,
              freeSpace: (@Sendable (String) -> Int64?)? = nil)    // nil = reclaimer default
  public func run(_ request: RielaRetentionRequest) throws -> RielaRetentionReport
}
```

`run` behavior:

1. Load the config with `RielaRetentionConfiguration.load(homeDirectory:projectDirectory:environment:)`.
   Config errors are rethrown; callers decide whether to warn or fail.
2. Resolve targets with `RetentionTargetResolver.resolve(...)`.
3. **Per-target policy.** Start from `configuration.policy(for: target.kind)`.
   Apply the overrides per category:
   - an override for a `keepForever` category throws
     `.keepForeverOverride(category:)` before any work;
   - an override value outside the ranges of ar-01 throws `.invalidOverride`;
   - overrides may make a `notConfigured` category active. In manual mode with
     no policy, start from an empty policy, so every category is
     `notConfigured`.
4. **Automatic gate.** With trigger `.automatic`, a target is skipped silently
   (not included in `targets`) when its policy is nil or `automatic == false`.
   With trigger `.manual`, the target is included even with a nil policy, and all
   categories are reported `notConfigured`.
5. **Unsafe target.** It gets status `skippedUnsafePath` with inactive reports.
6. **Throttle and lock.** In automatic mode, `RetentionRunStamp.isFresh` gives
   `skippedThrottled` and no lock is taken. In a dry run, take no lock and write
   no stamp. Otherwise, call `RetentionTargetLock.tryAcquire`. A nil result gives
   `skippedBusy` (automatic) or `busy` (manual). In automatic mode, re-read the
   stamp under the lock and skip as throttled if it is now fresh. Write
   `lastAttemptAt` before the work.
7. **Work order** (design §5.2):
   1. Executor `runPolicy` on `TerminalRetentionPaths(sessionRoot:
      target.sessionStoreRoot, artifactRoot: nil, memoryRoot: target.memoryRoot)`,
      with `keepWorkflowIds` from results.
   2. `RetentionLogPruner.run` on `logsRoot`.
   3. The generated sweep via `RielaDataGarbageCollector().collect(retentionDays:
      results.maxAgeDays, scope: .user or .project, homeDirectory:,
      projectDirectory:, dryRun:, now:)`. Run it only for user and project targets
      when results are `active` with `maxAgeDays`.
   4. Executor `finalize`, with mode `.automatic` or `.manual` from the trigger.

   Mapping the executor inputs:
   - results policy nil when its state is not `active`;
   - messages `.followResults` when `notConfigured`, `.keepForever` when
     `keepForever`, `.independent` when `active`.
8. **Failures.** Any thrown error in a step goes into the target's `warnings`
   and the target status becomes `failed`. Continue with the next step where
   safe; always continue with the next target. Write `lastCompletedAt` and
   `lastStatus` after the work, but not in a dry run. Release the lock by letting
   it go out of scope.
9. **Bounds** come from ar-05 and ar-06 (500, 1000, 2000 and the reclaimer page
   budget). Do not add config for them.

### `Sources/RielaCLI/GarbageCollectionCommand.swift`

Replace `ParsedGarbageCollectionOptions`:

- Flags:
  - `--scope user|project|all` (default `all`);
  - `--working-dir` / `--working-directory`;
  - `--session-store <path>`;
  - `--dry-run`;
  - `--results-max-age-days N`, `--results-max-total-bytes SIZE`;
  - `--messages-max-age-days N`, `--messages-max-total-bytes SIZE`;
  - `--logs-max-age-days N`, `--logs-max-total-bytes SIZE`;
  - `--output text|json|jsonl`.
- `SIZE` is parsed with `RielaByteSize.parse` or as a bare integer.
- `--retention-days` is removed and ArgumentParser rejects it.
- `run`:
  - build the request with trigger `.manual`, home from
    `CLIRuntimeEnvironment.homeDirectory(environment:)`, `projectDirectory` from
    the working dir, and the explicit store from the flag;
  - call the service;
  - exit codes: `.usage` (2) for parse errors, config errors and
    `RielaRetentionUsageError`; `.failure` when `report.hasFailure`; otherwise
    `.success`;
  - JSON: encode `RielaRetentionReport` with sorted keys;
  - text: one block per target with header `<kind> <root>: <status>`. Then one
    line per category: `results: removed|would remove N (B bytes); cap
    achieved|not achieved|no cap; protected: reason=n,...`. Then the logs,
    generated, orphan-lock and reclamation lines (`database action reclaimed=B
    reusable=B`), then the warnings.

### Docs

- **`README.md`** lines 540-574 ("Runtime Data Garbage Collection"): rewrite as
  "Runtime Data Retention". Cover:
  - the config shape;
  - the copy-paste keep-forever example (results and messages `keepForever`,
    logs 14 days / `"1GB"`);
  - precedence (`RIELA_RETENTION` > project > user) and
    `RIELA_RETENTION_AUTOMATIC`;
  - the removed `gc.retentionDays`, with the error message;
  - the automatic triggers;
  - `riela gc` usage including `--dry-run --output json`;
  - the large-DB conversion note (run `riela gc` once with about 2x the DB size
    free);
  - alternate stores via `--session-store` / `RIELA_SESSION_STORE`;
  - the unpaired-journal behavior.
- **`docs/terminal-retention.md`**: describe `session prune` as the low-level
  command. Replace the VACUUM sentence around line 64 with the reclaimer
  behavior, and link to the README section.
- **`Resources/skills/riela-workflow-run/SKILL.md`**: add a short "Disk
  retention" section with the keep-forever example and `riela gc --dry-run
  --output json`.

## Patterns to imitate

- The current `GarbageCollectionCommand.run`: ArgumentParser help handling, and
  the usage/failure mapping.
- The existing `RielaCLIApplication().run(args, environment:)` test style in
  `GarbageCollectionCommandTests`.

## Pitfalls

- The automatic trigger with no config must touch nothing. Do not even create
  `<root>/retention/`.
- A dry run must write nothing anywhere: no stamp, no lock file, no tombstone
  tables. The JSON still reports `selected*`.
- A `keepForever` category is untouchable even in manual mode. An override flag
  is a usage error, not a silent ignore.
- Never pass an artifact root.
- Always pass `projectDirectory` explicitly. Never default to the process cwd
  inside the service; the command passes the working dir.
- Do not change the `gc` route registrations in `RielaClientCommandRouter.swift`
  or `CLISurfaceEnumeration.swift`. They stay as they are.

## Tests

`RielaRetentionServiceTests` (temp HOME and project under `<cwd>/tmp`, fake
clock, `freeSpace` injected):

- automatic with no config -> `targets` empty and no `retention` directory
  created anywhere
- automatic with `{"retention":{"logs":{"maxAgeDays":14}}}` and a 20-day-old log
  -> removed, and the stamp written with `lastStatus` completed
- a second automatic run 5 minutes later -> `skippedThrottled` and nothing more
  removed
- the lock held by the test via `RetentionTargetLock.tryAcquire` -> automatic
  `skippedBusy`, manual `busy` with `report.hasFailure`
- results `keepForever`, messages notConfigured, logs active -> an old terminal
  session and its messages untouched, logs pruned
- messages `keepForever` with results maxAgeDays 1 -> session rows removed and
  message rows kept
- logs `keepForever` with results active -> logs untouched
- a manual override on a `keepForever` category -> throws `.keepForeverOverride`
- manual with no config and `logs` override `logsMaxAgeDays: 14` -> logs pruned
  and the other categories `notConfigured`
- dry run -> files identical before and after (compare a recursive listing with
  sizes and mtimes), and no stamp
- a project config overriding the user config -> the project target uses the
  project policy
- a corrupt session DB in the project store -> project target `failed` with a
  warning, and the user target still completed

`GarbageCollectionCommandTests` (rewrite):

- `gc --dry-run --output json` with a configured policy -> exit 0; the JSON has
  per-category `selectedCount`, `selectedBytes`, `protected`, `capAchieved` and
  `reclamation`; nothing changed on disk
- `gc --retention-days 1` -> exit 2
- `gc --results-max-age-days 1` while results are `keepForever` -> exit 2
- `config.json` with a `gc` key -> exit 2, and stderr contains
  `gc.retentionDays was removed`
- `gc --help` -> lists `--results-max-age-days` and `--logs-max-total-bytes`,
  and not `--retention-days`
- text output contains `results:` and `logs:` lines

`CommandParsingTests`: the updated gc case still parses as passthrough.

## Verification

1. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "RielaRetentionServiceTests|GarbageCollectionCommandTests|CommandParsingTests" > tmp/automatic-retention/ar-07-cli-service-gc-docs/test.log 2>&1'
   ```
   Must show exitStatus 0, testsRun ≥ 18 + (the pre-existing CommandParsingTests
   count) and failureCount 0.
2. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetention|RetentionTargetState|RetentionLogPruner|RielaDataGarbageCollector" > tmp/automatic-retention/ar-07-cli-service-gc-docs/deps.log 2>&1'
   ```
   Must exit 0.
3. ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCLI/RielaRetentionService.swift Sources/RielaCLI/GarbageCollectionCommand.swift Sources/RielaCLI/RielaCLIApplication.swift Tests/RielaCLITests/RielaRetentionServiceTests.swift Tests/RielaCLITests/GarbageCollectionCommandTests.swift Tests/RielaCLITests/CommandParsingTests.swift > tmp/automatic-retention/ar-07-cli-service-gc-docs/swiftlint.log 2>&1'
   ```
   Must exit 0.
4. ```
   grep -n '"keepForever": true' README.md Resources/skills/riela-workflow-run/SKILL.md
   ```
   Must exit 0 with matches in both files.
5. ```
   grep -n "retention-days\|RIELA_GC_RETENTION_DAYS" README.md docs/terminal-retention.md Resources/skills/riela-workflow-run/SKILL.md Sources/RielaCLI/RielaCLIApplication.swift Sources/RielaCLI/GarbageCollectionCommand.swift
   ```
   May only match the README sentence saying the old key was removed.

## Done criteria

- `grep -n "RielaGarbageCollectionConfiguration" Sources/RielaCLI/GarbageCollectionCommand.swift`
  prints nothing.
- `grep -n "public func run(_ request: RielaRetentionRequest) throws -> RielaRetentionReport" Sources/RielaCLI/RielaRetentionService.swift`
  matches.
- The progress records exist with integer fields.
