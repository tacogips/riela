# sac-02-owner-lock-startup: app.lock ownership, run/ directory validation, deferred owner startup

- planId: `sac-02-owner-lock-startup`
- wave: 1, dependsOn: none
- design: `design-docs/specs/design-serverless-app-control.md` §3.4 (ownership invariant, deferred initialization, CLI probe lock step), §3.5 Ownership, §5 startup-versus-local-reload regression
- writePaths:
  - `Sources/RielaAppSupport/RielaAppOwnerLock.swift` (new)
  - `Sources/RielaAppSupport/RielaAppOwnerStartup.swift` (new)
  - `Tests/RielaAppSupportTests/RielaAppOwnerStartupTests.swift` (new)
  - `impl-plans/progress/sac-02-owner-lock-startup.md`
- sharedPaths: none
- evidence: `tmp/serverless-app-control/sac-02/`

## Intent and context

The App must hold `<appRoot>/run/app.lock` (`flock(LOCK_EX)`) whenever it has
profile state in memory or can write it. A local CLI reload takes the same lock
with `LOCK_NB` while no App runs. The App launch waits for the lock without any
timeout, and only then runs phase B: unlink the stale socket, bind, load state.
This plan builds the reusable, testable pieces in `RielaAppSupport`. sac-06
wires them into `EntryPoint.swift`, and sac-07 uses them for the CLI probe and
local reload.

Pattern to imitate for `flock`: `Sources/RielaCore/DistributedStoreLock.swift`
(open the fd, `flock`, retry on `EINTR`, `LOCK_UN` + `close` on release).

## Non-goals

- No socket listener or client (sac-05).
- No App wiring (sac-06).
- No edit to `DistributedStoreLock.swift`.

## File-level changes

### `RielaAppOwnerLock.swift`

**`public struct RielaAppRunDirectory: Sendable`**

- `init(appRoot: URL)`.
- Properties: `directoryURL` (`<appRoot>/run`), `lockURL` (`run/app.lock`),
  `socketURL` (`run/control.sock`).
- `func prepare() throws`: create `run/` with mode `0700` if absent (create
  the parent `appRoot` with default permissions if absent), then call
  `validate()`.
- `func validate() throws`, using `lstat`. It must be:
  - a directory and not a symlink;
  - `st_uid == geteuid()`;
  - `st_mode & 0o077 == 0`.

  Otherwise it throws `RielaAppOwnerLockError.insecure`.
- `func validateSocketFile() throws`: if the socket exists it must be
  `S_IFSOCK`, owned by euid, with mode `& 0o177 == 0`; otherwise
  `.insecure`. A missing socket is not an error here.
- `var socketPathFits: Bool`: `socketURL.path.utf8.count <= 103`. sac-01 runs
  in parallel in the same wave, so use a file-local
  `private let maxSocketPathBytes = 103` and do not reference
  `RielaAppControlLimits` here. Serial reconciliation may replace it later.

**`public final class RielaAppOwnerLock: @unchecked Sendable`**

- `static func tryAcquire(_ run: RielaAppRunDirectory) throws -> RielaAppOwnerLock?`
  validates, opens or creates `app.lock` with `O_RDWR|O_CREAT|O_CLOEXEC`,
  mode `0600`, and calls `flock(LOCK_EX|LOCK_NB)`. It returns nil on
  `EWOULDBLOCK` (closing the fd) and throws on other errors.
- `static func acquireBlocking(_ run: RielaAppRunDirectory) throws -> RielaAppOwnerLock`
  calls `flock(LOCK_EX)` and retries on `EINTR`. It must **only** be called
  off the main thread; document this in a doc comment.
- `func release()` is idempotent; `deinit` releases.

**`public enum RielaAppOwnerLockError: Error, Equatable`**

Cases: `insecure`, `io(Int32)`.

### `RielaAppOwnerStartup.swift`

**`public final class RielaAppOwnerStartup: @unchecked Sendable`**

```swift
public init(run: RielaAppRunDirectory,
            waitObserver: (@Sendable () -> Void)? = nil,
            acquire: @escaping @Sendable (RielaAppRunDirectory) throws -> RielaAppOwnerLock = RielaAppOwnerLock.acquireBlocking)
public func start(bindChannel: @escaping @Sendable (URL) throws -> Void,
                  phaseB: @escaping @MainActor @Sendable (RielaAppOwnerLock) -> Void,
                  failed: @escaping @MainActor @Sendable (RielaAppOwnerLockError) -> Void)
```

`start` runs this sequence:

1. `run.prepare()`. On `insecure`, hop to the main actor, call `failed`, and
   stop. No lock, no unlink, no phaseB.
2. Call `waitObserver` (if any) just before the blocking acquire. This is the
   deterministic "waiting" signal for tests and the App status line.
3. On a dedicated `Thread` (not the main thread, not the cooperative pool),
   call `acquire(run)`.
4. After acquisition:
   1. If `socketURL` exists, unlink it.
   2. If `socketPathFits`, call `bindChannel(socketURL)`. A bind error is
      logged by the caller's closure and does **not** prevent phaseB; the App
      keeps the lock and its state (design §3.5).
   3. Hop to `@MainActor` and call `phaseB(lock)`.
5. The lock object must be retained by the caller of phaseB (the App) for the
   process lifetime.

Expose `public static func unlinkSocketIfOwned(_ run: RielaAppRunDirectory, lock: RielaAppOwnerLock)`,
used at App termination (sac-06). It requires a live `lock` parameter, so it
cannot be called without ownership.

## Pitfalls

- **Never** unlink or bind `control.sock` before the lock is acquired.
- Never block the main thread on `flock`.
- Never add a timeout or an unlocked fallback. The design forbids both.
- `flock` locks belong to the open file description, so two `open()` calls in
  the **same process** do conflict under `flock` on macOS. This is what lets
  the tests run the "CLI" and the "App" in one process. Verify it in a test;
  if it does not hold, use a subprocess-free alternative and record it.
- Do not use `fcntl` locks: POSIX record locks are per-process and would not
  conflict in-process.
- `umask` is not changed here (that is socket bind, sac-05).
- Temp roots must be short: `/tmp/rac-<8 hex>`. Never use `$HOME` or
  `~/Library`.

## Tests (`RielaAppOwnerStartupTests`, temp root `/tmp/rac-<8hex>`, removed in tearDown)

| Situation | Expected outcome |
| --- | --- |
| `prepare()` on a fresh root | `run/` mode `0700`; `validate()` passes |
| `run/` chmod `0755` | `validate()` throws `insecure` |
| `run/` replaced by a symlink to a 0700 dir | `insecure` |
| Socket stand-in mode `0666` | `validateSocketFile()` throws `insecure` |
| `tryAcquire` twice in-process | first returns a lock, second returns nil; after `release()` a third returns a lock |
| `socketPathFits` with a root whose socket path is 104 bytes | false; at 103 bytes, true |

**Startup-versus-local-reload regression** (design §5). This test must be
deterministic: synchronize with expectations and semaphores, not sleeps.

1. Write `profiles/default/daemon-workflows.json` through
   `RielaAppDaemonWorkflowStore` with one preference whose `sourceIdentity` is
   `selected-workflow:<dirA>`. Find the store's init by reading
   `Sources/RielaAppSupport/RielaAppDaemonWorkflowStore.swift`.
2. The "CLI" calls `RielaAppOwnerLock.tryAcquire`, which returns a lock.
3. Call `RielaAppOwnerStartup.start` with a `waitObserver` that fulfils
   `waiting`, a `bindChannel` that records a call, and a `phaseB` that records
   that it ran and loads the state into a local copy.
4. Wait for `waiting`. Assert that phaseB has not run and `bindChannel` was
   not called, inverting an expectation with a short timeout (≤0.5 s). This
   stands in for "longer than the former 10 s policy", because the acquire is
   unbounded by design.
5. The "CLI" mutates `sourceIdentity` to `selected-workflow:<dirB>`, saves,
   and releases.
6. Wait for phaseB. Assert that the loaded copy has source B and that
   `bindChannel` was called with `run/control.sock`.
7. Mutate an unrelated field on the loaded copy (for example, toggle a
   preference's `active`), save it with the store, re-read the file, and assert
   that the source is still B.

**No unlink of a live owner's socket.** While another `tryAcquire` holds the
lock, create a stand-in file at `run/control.sock`. Start startup, wait for
`waiting`, and assert the file is still present with the same inode (`stat`).
Then release, so startup proceeds and unlinks it; the inode changes or the file
disappears before bind.

**Insecure `run/`.** With `run/` at mode `0755`, `failed(.insecure)` is called.
phaseB, bind and lock creation never happen: `app.lock` is absent.

## Verification (`tmp/serverless-app-control/sac-02/`)

- `mkdir -p tmp/serverless-app-control/sac-02`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/serverless-app-control/sac-02/build.log 2>&1`
  must exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter RielaAppOwnerStartupTests" > tmp/serverless-app-control/sac-02/test.log 2>&1`
  must exit 0; run it 3 times (`test-1.log` … `test-3.log`) to show there is
  no flakiness.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaAppSupport/RielaAppOwnerLock.swift Sources/RielaAppSupport/RielaAppOwnerStartup.swift Tests/RielaAppSupportTests/RielaAppOwnerStartupTests.swift' > tmp/serverless-app-control/sac-02/lint.log 2>&1`
- `! grep -n "Library/Application Support\|NSHomeDirectory" Tests/RielaAppSupportTests/RielaAppOwnerStartupTests.swift`

## Done criteria

- The listed symbols exist with the exact signatures above.
- All the tests above pass 3 times in a row.
- The progress log records the exit codes, log paths and file hashes, using
  the drift rules from sac-01.

## Implementation status

Owner-lock and deferred-startup components and regression tests are implemented.
The build and three consecutive focused test runs pass on the shared tree; see
`impl-plans/progress/sac-02-owner-lock-startup.md` for evidence. Formal reviews
and serial integration remain downstream.
