# mrot-02: Live root session probe (shared contract for Bug A)

**planId**: mrot-02-live-root-session-probe
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-manual-run-overlap-and-terminal-reserve.md §1 (Bug A persisted facts and liveness primitive), §3.1, §6 (probe helper row)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/mrot-02-live-root-session-probe.md
**Evidence root**: tmp/manual-overlap-terminal-reserve/mrot-02/

## Intent and context

Manual App runs (in the App process) and cron runs (in the
`riela events serve` child process) share one per-profile session store.
The cron dispatcher (mrot-04) and the App run route (mrot-05) both need one
read-only answer to the question "which root sessions of workflow W in store
S are live right now, and which of them are manual?". This plan provides
exactly that, as a **public** RielaCLI API, because `RielaApp` imports
`RielaCLI`.

## Contract (mrot-04 and mrot-05 depend on it; do not rename)

```swift
public struct LiveRootSession: Equatable, Sendable {
  public let sessionId: String
  public let createdAt: Date
  public let isManual: Bool
}
public enum LiveRootSessionProbe {
  public static func liveRootSessions(workflowId: String, sessionStoreRoot: String) throws -> [LiveRootSession]
}
```

The result is sorted by `createdAt` ascending, ties broken by `sessionId`.

## Non-goals

- No writes of any kind: no database or schema creation, no lock-file or
  lock-directory creation, no tombstone or session mutation.
- No changes to `SessionExecutionLockRegistry`, `SessionExecutionLock`,
  `SQLiteWorkflowRuntimePersistenceStore`, or reconcile.
- No caching and no async API.

## File-level changes

### Sources/RielaCLI/LiveRootSessionProbe.swift (new)

1. **Store root.** `let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot:)`
   (`Sources/RielaCLI/CLIWorkflowSessionStore.swift:853`). If the runtime
   database file does not exist, return `[]`.
2. **Candidates.** Open
   `SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)` and
   call `loadSessionOverviews(SQLiteWorkflowRuntimePersistenceStore.LoopSessionOverviewFilter(workflowId:
   workflowId, sessionStatus: "active", limit: 200))`. This is already
   read-only and already filters `session_status IN ('created','running')`.
   See `SQLiteWorkflowRuntimePersistenceStore.swift:362`. For each candidate,
   load the header read-only. Use the existing `loadStrictReadOnly(sessionId:)`
   (as `Tests/RielaAppSupportTests/ConfiguredWorkflowLaunchTests.swift` does),
   or a lighter header read if a public one exists. Skip candidates whose
   load throws `notFound` because they were deleted in between.
3. **Root only.** Keep a session only when `parentSessionId == nil`.
4. **Liveness, read-only flock probe.** The lock path is
   `<runtimeRoot>/execution-locks/<sessionId>.lock`. That is the same layout
   as `SessionExecutionLockRegistry.init` in
   `Sources/RielaCLI/SessionExecutionLock.swift`.
   - Validate `sessionId` against the same regex the registry uses. Skip it if
     invalid.
   - `open(path, O_RDONLY | O_CLOEXEC)` **without `O_CREAT`**. If the file is
     missing (`ENOENT`), the session is not live.
   - `flock(fd, LOCK_EX | LOCK_NB)`, retrying on `EINTR`. `EWOULDBLOCK` or
     `EAGAIN` means **live**. Success means not live: call `flock(fd, LOCK_UN)`
     immediately. Always `close(fd)`. Imitate the loop in
     `SessionExecutionLockRegistry.removeOrphanLocks`.
   - **Do not** call `SessionExecutionLockRegistry.acquire`. It creates
     directories and lock files and keeps the lock.
   - flock is per open-file-description on macOS. So this probe correctly
     reports **live** for a session whose lock is held by another registry in
     the **same** process (the App's own manual run). A test must pin this.
5. **isManual** is true when `instanceKind == "named"`, or when
   `instanceKind == "ephemeral"` and `instanceBaseIdentity` is non-nil and
   `!= WorkflowInstanceIdentity.defaultIdentity`. Compare against the
   `WorkflowInstanceKind` raw values; do not hardcode strings elsewhere.
6. Errors (SQLite open or query failures) propagate as `throws`. Callers
   decide whether to fail open.

## Tests: Tests/RielaCLITests/LiveRootSessionProbeTests.swift (new)

Fixtures: create a temp session store under `tmp/` (as
`ConfiguredWorkflowLaunchTests` does with `tmp/configured-run-<uuid>`) and
remove it in `defer`. Persist sessions with the real
`SQLiteWorkflowRuntimePersistenceStore` save API. Imitate
`Tests/RielaCLITests/SessionReconcileCommandTests.swift`, which persists
`running` sessions and holds execution locks. Hold a lock with
`SessionExecutionLockRegistry(sessionStoreRoot:).acquire(sessionId:)` (via
`@testable import RielaCLI`).

- Missing store directory → `[]`, and afterwards no directory or file was
  created at the path.
- Running root session with its lock held by a registry in this process →
  returned (live).
- Same session with the lock released, or no lock file → not returned.
- `created` root session with its lock held → returned.
- `completed` session with its lock held → not returned (status filter).
- Child session (`parentSessionId` set) with its lock held → not returned.
- Different `workflowId` → not returned.
- `instanceKind named` with identity `art` → `isManual == true`.
- `ephemeral` with `instanceBaseIdentity "art"` → `true`.
- `ephemeral` with base `default` → `false`.
- `default` kind → `false`.
- Two live sessions → sorted by `createdAt` ascending.
- After a probe of a held lock, the holder still holds it: a second probe
  still reports live, and `registry.holds(sessionId:)` is still true.

## Invariants

- The probe never creates files: assert that the directory listing of the
  store is unchanged before and after the call in the missing-lock case.
- The API is synchronous, `public`, and has exactly the contract above.

## Verification

- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift build --target RielaCLI'`: exit 0.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift test --filter LiveRootSessionProbeTests'`: all pass.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCLI/LiveRootSessionProbe.swift Tests/RielaCLITests/LiveRootSessionProbeTests.swift'`: clean.

Record each command's exit status and log path in the progress log, along
with the pre and post edit hashes (fresh read before each edit; stop if
drift is detected).

## Done when

- [ ] The contract compiles exactly as pinned.
- [ ] All the test bullets are implemented and green.
- [ ] Progress log complete.
