# sac-05-control-channel: owner-only Unix socket server, client and local-mode probe

- planId: `sac-05-control-channel`
- wave: 2, dependsOn: `sac-01-control-contract`, `sac-02-owner-lock-startup`
- design: `design-docs/specs/design-serverless-app-control.md` §3.4 (CLI probe), §3.5 (all), §3.8
- writePaths:
  - `Sources/RielaAppSupport/RielaAppControlChannelServer.swift` (new)
  - `Sources/RielaAppSupport/RielaAppControlChannelClient.swift` (new)
  - `Tests/RielaAppSupportTests/RielaAppControlChannelTests.swift` (new)
  - `impl-plans/progress/sac-05-control-channel.md`
  - `.build` (artifact root only; SwiftPM build cache, see Amendment 2026-11-12)
- artifactRoots: `.build`
- sharedPaths: none
- evidence: `tmp/serverless-app-control/sac-05/`

## Intent and context

The App serves a closed set of control operations on
`<appRoot>/run/control.sock` (`AF_UNIX`, `SOCK_STREAM`). The CLI connects to
it when `--server` is absent. This plan builds:

- the server, which is transport only: it receives a handler closure and knows
  nothing about RielaApp;
- the client;
- the local-mode probe (socket first, then lock).

sac-06 starts the server inside phase B and gives it the service from sac-04.
sac-07 and sac-08 use the client and the probe.

Use POSIX sockets through `Darwin`/`Glibc`: `socket`, `bind`, `listen`,
`accept`, `connect`, `getpeereid`, `read`, `write`, `poll`. The whole feature
is macOS-only, so wrap these files in `#if os(macOS)`. Linux keeps compiling,
because the CLI uses `app_server_required` there (sac-07/08).

## Non-goals

- No HTTP.
- No App or CLI wiring.
- No other operations besides the sac-01 enum.
- No persistence of requests or responses anywhere.

## File-level changes

### `RielaAppControlChannelServer.swift`

```swift
public final class RielaAppControlChannelServer: @unchecked Sendable {
  public typealias Handler = @Sendable (RielaAppControlOperation, _ profile: String) async -> RielaAppControlResult
  public init(run: RielaAppRunDirectory, handler: @escaping Handler,
              log: @escaping @Sendable (String) -> Void = { _ in },
              readDeadlineSeconds: Double = Double(RielaAppControlLimits.requestReadDeadlineSeconds),
              now: @escaping @Sendable () -> Date = Date.init,
              idempotencyCapacity: Int = RielaAppControlLimits.idempotencyCapacity)
  public func bind(socketURL: URL) throws   // used as RielaAppOwnerStartup bindChannel
  public func stop()                        // stop accepting, close fd; caller unlinks via RielaAppOwnerStartup.unlinkSocketIfOwned
}
```

**`bind`**

1. Check that the path is ≤ 103 bytes (`RielaAppControlLimits.maxSocketPathBytes`);
   otherwise throw `.pathTooLong`.
2. `run.validate()`.
3. Set `umask(0o177)` around `bind` and restore it; then `chmod 0600`.
4. `run.validateSocketFile()`. On failure, close and throw `.insecure`.
5. `listen` with backlog 16.
6. Start a dedicated accept thread. Each accepted connection is handled in its
   own `Task`.

**Per connection**

1. Check `getpeereid` uid == `geteuid()`; otherwise close silently.
2. Read the 4-byte big-endian length within the read deadline (`poll`).
3. If the length > `maxRequestFrameBytes`, write the response
   `{version:1, requestId:"", status:413, body:{error:{code:"request_too_large"}}}`
   and close **without reading the body**.
4. Read the body within the deadline. On a deadline miss or EOF, close with
   no response.
5. `RielaAppControlRequestEnvelope.decodeStrict`. On failure, respond 400
   `invalid_request` with `requestId` `""`.
6. Idempotency (non-read-only operations only), as an in-memory actor keyed by
   `requestId`:

| Cache state | Action |
| --- | --- |
| Entry with a different `digest()` | 409 `request_id_conflict` |
| `inFlight` | await the same result |
| `done` and not expired (TTL 600 s from completion, using `now`) | replay the cached result without calling the handler |
| Absent | insert `inFlight` and call the handler |

   At capacity (512), evict the oldest `done` entry. If every entry is
   `inFlight`, respond 503 `channel_busy`.

7. Write the response frame
   (`RielaAppControlResponseEnvelope{version:1, requestId, status, body}`).
   If the response is > `maxResponseFrameBytes`, write a 500
   `app_channel_protocol_error` instead.
8. Log one line only: `operation=<wireName> request=<first 8 chars of id> status=<n> code=<error.code or ->`.
   Never log bodies.

### `RielaAppControlChannelClient.swift`

```swift
public struct RielaAppControlChannelClient: Sendable {
  public init(socketURL: URL, connectTimeoutSeconds: Double = 2, responseTimeoutSeconds: Double = 30,
              makeRequestId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() })
  public func send(_ operation: RielaAppControlOperation, profile: String) async throws -> RielaAppControlResult
}
public enum RielaAppLocalControlProbe {
  public enum Outcome { case channel(RielaAppControlChannelClient); case notRunning(RielaAppOwnerLock) }
  public static func resolve(appRoot: URL) throws -> Outcome   // throws RielaAppControlChannelError
}
public enum RielaAppControlChannelError: Error, Equatable { case code(RielaAppControlErrorCode) }
```

**`send`**

1. Check the path length → `app_channel_path_too_long`.
2. `run.validate()` + `validateSocketFile()` → `app_channel_insecure`.
3. Connect, non-blocking with `poll`, within 2 s.
4. Check `getpeereid` of the server == euid → otherwise
   `app_channel_insecure`.
5. Write the frame using **one** `requestId` per `send`.
6. Read the response within 30 s. A timeout → `app_channel_timeout`.
7. If the connection closes after the request was fully written and **before
   any response byte**, retry exactly once with the same `requestId` (the
   envelope bytes are identical).
8. A malformed or oversized response, or a mismatched `requestId` →
   `app_channel_protocol_error`.

**`resolve`** (design §3.4 CLI probe)

1. Path too long → `app_channel_path_too_long`.
2. Try to connect to the socket:
   - connected → `.channel` (close that probe connection; `send` opens its
     own);
   - `ENOENT`/`ECONNREFUSED` → step 3.
3. `RielaAppRunDirectory.prepare()` + `RielaAppOwnerLock.tryAcquire`:
   - nil → `app_channel_unavailable`;
   - a lock → `.notRunning(lock)`;
   - `insecure` → `app_channel_insecure`.

The probe never deletes `control.sock`.

## Pitfalls

- Never write the request or response to disk. Never log bodies.
- Use `getpeereid` on both sides. Do not trust file permissions alone.
- Do not read the body when the length is oversized.
- The retry rule is **only** "closed before any response byte". A timeout is
  not retried.
- The `inFlight` waiters must not deadlock when the handler throws or the task
  is cancelled. The cache entry is completed or removed in every path.
- `sun_path` copying: use `withUnsafeMutableBytes` on `sockaddr_un.sun_path`,
  with an explicit length check. Set `sun_len` on macOS.
- Tests use roots `/tmp/rac-<8hex>` (short), never `$HOME`.

## Tests (`RielaAppControlChannelTests`, in-process server + client, temp roots)

| Situation | Expected outcome |
| --- | --- |
| Bootstrap round trip | the handler receives `.bootstrap`, `"default"`; the client returns the result |
| Socket file mode after bind | `0600`; `run/` is `0700` |
| Path of 104 bytes | `bind` throws `pathTooLong`; client → `app_channel_path_too_long` |
| Oversized length prefix (raw socket write of length `589_825`) | 413 `request_too_large`; the handler is never called |
| Malformed JSON / extra key | 400 `invalid_request` |
| A raw client sends 2 of 4 length bytes then stalls, with an injected `readDeadlineSeconds: 0.2` | the server closes; the handler is not called |
| The same `requestId` sent twice with an identical body | handler call count 1, identical results |
| The same `requestId` with a different body | 409 `request_id_conflict` |
| Two concurrent sends with the same id while the handler is blocked on a continuation | one handler call, both get the result |
| Read-only `environment.status` twice with the same id | handler called twice (not cached) |
| `idempotencyCapacity: 2` with 2 blocked in-flight requests | a third distinct id → 503 `channel_busy` |
| Expiry with an injected `now` advanced 601 s | the handler is called again |
| A server closing after reading the request with no response the first time (scripted raw server in the test) | the client retries once with the same `requestId`; the second response is returned |
| Server with mode `0666` socket (chmod after bind in the test) | client → `app_channel_insecure` |
| Probe with no socket and a free lock | `.notRunning(lock)`; a second probe while the lock is held → `app_channel_unavailable` |
| Probe with a stale socket file (bound then server closed without unlink) and a free lock | `.notRunning`, and the stale file still exists |
| Probe with a live server | `.channel` |
| Handler result containing `"SECRET_VALUE"` in a field the test injects | the log sink lines never contain `SECRET_VALUE` |

## Verification (`tmp/serverless-app-control/sac-05/`)

- `mkdir -p tmp/serverless-app-control/sac-05`
- `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/serverless-app-control/sac-05/build.log 2>&1`
  must exit 0.
- `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter RielaAppControlChannelTests" > tmp/serverless-app-control/sac-05/test-1.log 2>&1`,
  repeated as `test-2.log` and `test-3.log`. All must exit 0, with no flake.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaAppSupport/RielaAppControlChannelServer.swift Sources/RielaAppSupport/RielaAppControlChannelClient.swift Tests/RielaAppSupportTests/RielaAppControlChannelTests.swift' > tmp/serverless-app-control/sac-05/lint.log 2>&1`
- `! grep -n "write(to\|FileManager.default.createFile" Sources/RielaAppSupport/RielaAppControlChannelServer.swift Sources/RielaAppSupport/RielaAppControlChannelClient.swift`
  must print nothing (no disk persistence).

## Done criteria

- The symbols exist as listed.
- Every test in the table passes 3 times.
- The progress log records exit codes, log paths and hashes, using the drift
  rules from sac-01.

## Amendment 2026-11-12 (blocked-wave-scope-or-contract, round 1)

Blocker: "Authorized build-output location". The dispatch declared
`artifactRoots: []`, but this plan's verification runs
`swift build --build-tests` and `swift test --skip-build`, which write the
SwiftPM cache in the repository `.build` directory.

Decision:
- `.build` is added to this plan's `writePaths` and declared as its only
  `artifactRoots` entry. It is a generated build cache, not a source snapshot.
  The runtime records it as a digest/count manifest only.
- sac-05 is the only plan in its wave, so `.build` has exactly one writer
  while sac-05 runs. Verification commands are unchanged.
- Do not delete, clean, or `swift package reset` `.build`. Wave-3 plans
  (sac-06/07/08) seed their private scratch paths from it.
- Do not edit or commit anything under `.build`. It is gitignored, so it must
  never show up in `git status`.
- No source, contract, or design change is involved. All other sections stay
  in force.
