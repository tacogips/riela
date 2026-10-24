# ar-06-cli-targets-logs: targets, lock/stamp, log pruner, scheduler (RielaCLI)

```json
{
  "planId": "ar-06-cli-targets-logs",
  "planPath": "impl-plans/active/automatic-retention-06-cli-targets-logs.md",
  "dependsOn": ["ar-01-core-config", "ar-02-core-planners"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCLI/RetentionTargets.swift",
    "Sources/RielaCLI/RetentionTargetState.swift",
    "Sources/RielaCLI/RetentionLogPruner.swift",
    "Sources/RielaCLI/RielaRetentionScheduler.swift",
    "Tests/RielaCLITests/RetentionTargetStateTests.swift",
    "Tests/RielaCLITests/RetentionLogPrunerTests.swift",
    "Tests/RielaCLITests/RielaRetentionSchedulerTests.swift",
    "impl-plans/progress/ar-06-cli-targets-logs.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

This plan builds four independent pieces that ar-07, ar-08 and ar-09 consume:

- target resolution (design §3);
- the per-target non-blocking lock and durable stamp (design §5.1);
- the logs-root pruner (design §4.4, filesystem side of ar-02's planner);
- a generic periodic scheduler (design §6.1). It takes a closure, so it does not
  depend on the service.

Follow the shared worker protocol in `impl-plans/completed/automatic-retention.md`.

## Non-goals

- No config loading. The caller passes policies.
- No session-store pruning.
- No CLI flags.
- No edits to serve, events or RielaApp files (ar-08 and ar-09).

## File-level changes

### `RetentionTargets.swift` (new)

```swift
struct RetentionTarget: Equatable, Sendable {
  var kind: RielaRetentionTargetKind
  var root: String                 // riela root (`<home>/.riela`, `<project>/.riela`) or explicit store root
  var sessionStoreRoot: String?    // `<root>/sessions` for user/project, the store itself for explicit
  var memoryRoot: String?          // `<root>/memory`; explicit: RIELA_MEMORY_ROOT or nil
  var logsRoot: String?            // `<root>/logs`; explicit: nil
  var stateDirectory: String       // `<root>/retention` (explicit: `<store>/retention`)
  var unsafeReason: String?        // "unsafePath" when any component is a symlink (TerminalRetentionPaths.checked throws)
}
enum RetentionTargetResolver {
  static func resolve(scope: RielaGarbageCollectionScope, homeDirectory: URL, projectDirectory: URL?,
                      explicitSessionStore: String?, environment: [String: String]) -> [RetentionTarget]
}
```

Resolution rules:

1. Which targets are considered depends only on scope:
   - the user target when scope is `user` or `all`;
   - the project target when `projectDirectory` is not nil and scope is
     `project` or `all`;
   - the explicit target only when scope is `all` and `explicitSessionStore`, or
     a non-empty `RIELA_SESSION_STORE`, is set.

   Automatic triggers always pass `.all`.
2. Paths are standardized. A relative explicit store resolves against
   `projectDirectory`, or the current directory when that is nil, as
   `CLIWorkflowSessionStore.resolveRootDirectory` does.
3. Deduplicate:
   - drop the project target when its root equals the user root;
   - drop the explicit target when its store equals the user or project
     `sessionStoreRoot`, because that target already covers it.
4. Drop targets whose `root` does not exist. Never create directories.
5. Set `unsafeReason` when `TerminalRetentionPaths.checked(root)` throws. That
   static API already exists; call it read-only.
6. The order is user, project, explicit.

### `RetentionTargetState.swift` (new)

```swift
final class RetentionTargetLock {          // flock on `<stateDirectory>/automatic.lock`
  static func tryAcquire(stateDirectory: String) throws -> RetentionTargetLock?   // nil when busy (EWOULDBLOCK)
}
struct RetentionRunStamp: Codable, Equatable, Sendable {
  var lastAttemptAt: Date?; var lastCompletedAt: Date?; var lastStatus: String?
  static func read(stateDirectory: String) -> RetentionRunStamp?   // nil when missing or undecodable
  func write(stateDirectory: String) throws                        // temp file + rename, ISO8601 dates
  static func isFresh(_ stamp: RetentionRunStamp?, now: Date, minInterval: TimeInterval) -> Bool
}
```

- `tryAcquire` creates `stateDirectory` with intermediate directories. The lock
  file has mode 0600 and `O_CLOEXEC`. It is released on deinit.
- `isFresh` is true only when `lastAttemptAt` exists, is not in the future, and
  `now - lastAttemptAt < minInterval`. A future stamp counts as stale.
- The stamp file name is `last-run.json`.

### `RetentionLogPruner.swift` (new)

```swift
struct RetentionLogPruner {
  var now: () -> Date
  func run(logsRoot: String, state: RielaRetentionCategoryState, policy: RetentionPolicySnapshot?,
           dryRun: Bool, removalLimit: Int = 1000) -> (report: RetentionCategoryReport, warnings: [String])
}
```

1. When the state is not `active`, or the root is missing, return
   `RetentionCategoryReport.inactive(state)` (zero bytes for a missing root).
2. List direct children with `lstat` (Darwin `lstat`, or `FileManager`
   attributes without following links). Build a `RielaLogFileEntry` for each:
   kind, `st_size`, mtime, device and inode. Do not recurse.
3. Plan with `RielaLogRetentionPlan.make(entries:now:maxAge:maxBytes:removalLimit:)`,
   where `maxAge = maxAgeDays*86400`.
4. In a non-dry run, for each selected entry, `lstat` again just before
   `unlink`. If the device, inode, size or mtime changed, or the entry is no
   longer regular, skip it, count it as protected `changedDuringAdmission` and
   add its bytes back to `remainingBytes`.
5. An `unlink` failure adds a warning and skips the entry.
6. Fill the report:
   - `selectedCount` and `selectedBytes` come from the plan;
   - `removed*` counts what was actually unlinked;
   - `remainingBytes = before - removed`;
   - `capAchieved` is nil when there is no cap, else `remaining <= cap`;
   - `protected` holds the planner reasons plus `changedDuringAdmission`;
   - `protectedFamilies` is empty.

### `RielaRetentionScheduler.swift` (new, public for RielaApp)

```swift
public final class RielaRetentionScheduler: @unchecked Sendable {
  public init(interval: TimeInterval = 300, runImmediately: Bool,
              sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
              pass: @escaping @Sendable () -> Void)
  public func start()      // idempotent; spawns one Task(priority: .utility) loop
  public func stop()       // cancels the loop; safe to call twice
}
```

- The loop runs `pass()` when `runImmediately` is set, then repeats:
  sleep, check for cancellation, run `pass()`.
- Passes run sequentially inside the loop task, so they never overlap.
- `pass` must not throw. The caller wraps its errors.

## Patterns to imitate

- `RielaDataGarbageCollector.collectionRoots`: user and project root
  computation.
- `SessionExecutionLock.init`: the `open` plus `flock(LOCK_EX|LOCK_NB)` idiom
  and the EINTR loop.
- `CLIWorkflowSessionStore.resolveRootDirectory`: relative path handling.

## Pitfalls

- The project target uses `<projectDirectory>/.riela`, not `<cwd>`. Never read
  the real HOME. Callers pass `homeDirectory`.
- Never follow symlinks in the logs root. Never delete directories.
- `tryAcquire` returns nil on contention. Do not wait.
- The stamp write must be atomic: write a temp file in the same directory, then
  `rename`.
- The scheduler must stop on `stop()` even while it sleeps. Use task
  cancellation, so the injected `sleep` throws `CancellationError`.

## Tests

`RetentionTargetStateTests`:

- home and project roots exist, scope `all`, no explicit store -> two targets
  with the documented subpaths
- project equals home -> one target
- `RIELA_SESSION_STORE` equals `<home>/.riela/sessions` -> no extra target
- a separate explicit store with `RIELA_MEMORY_ROOT` set -> an explicit target
  whose `memoryRoot` is that value and whose `logsRoot` is nil
- missing project root -> skipped and no directory created
- the root is a symlink -> `unsafeReason == "unsafePath"`
- two `tryAcquire` calls on the same dir -> the second returns nil; after
  releasing the first, the next acquire succeeds
- stamp round-trip; `isFresh` for a stamp 10 minutes old with a 60-minute
  interval -> true, 61 minutes -> false, future -> false

`RetentionLogPrunerTests` (files under `<cwd>/tmp`, mtimes set with
`FileManager.setAttributes`, fake `now`):

- maxAgeDays 14 -> a 20-day-old file removed; a 1-day-old file and a 2h-old file
  kept (the 2h one protected `withinGraceWindow`)
- maxTotalBytes -> oldest removed until the total is ≤ cap
- a symlink pointing at an old file outside the root -> the symlink and its
  target are both untouched
- a subdirectory and a `.hidden` file -> untouched
- dry run -> nothing removed and `selectedCount > 0`
- state `keepForever` -> an inactive report and nothing removed
- a file swapped between plan and unlink (driven by an injected pre-unlink hook
  on the pruner) -> `changedDuringAdmission`

`RielaRetentionSchedulerTests`: inject `sleep` that records its calls and
returns immediately; stop after N passes.

- `runImmediately: true` -> the first pass happens before any sleep
- `runImmediately: false` -> a sleep comes first
- `stop()` while sleeping -> the loop ends and no further pass runs
- `start()` called twice -> one loop only

## Verification

1. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "RetentionTargetStateTests|RetentionLogPrunerTests|RielaRetentionSchedulerTests" > tmp/automatic-retention/ar-06-cli-targets-logs/test.log 2>&1'
   ```
   Must show exitStatus 0, testsRun ≥ 19 and failureCount 0.
2. ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCLI/RetentionTargets.swift Sources/RielaCLI/RetentionTargetState.swift Sources/RielaCLI/RetentionLogPruner.swift Sources/RielaCLI/RielaRetentionScheduler.swift Tests/RielaCLITests/RetentionTargetStateTests.swift Tests/RielaCLITests/RetentionLogPrunerTests.swift Tests/RielaCLITests/RielaRetentionSchedulerTests.swift > tmp/automatic-retention/ar-06-cli-targets-logs/swiftlint.log 2>&1'
   ```
   Must exit 0.

## Done criteria

- `grep -n "public final class RielaRetentionScheduler" Sources/RielaCLI/RielaRetentionScheduler.swift`
  matches.
- `grep -n "static func tryAcquire(stateDirectory: String)" Sources/RielaCLI/RetentionTargetState.swift`
  matches.
- The progress records exist with integer fields.
