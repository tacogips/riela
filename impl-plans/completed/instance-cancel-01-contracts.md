# instance-cancel-01: Shared contracts (cancel box, session-control frames, live registry, App cancel DTOs/ports)

**planId**: instance-cancel-01-contracts
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-instance-cancel.md §3 C1, C2, C3, C4, C4b
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-01-contracts.md
**Evidence root**: tmp/instance-cancel/instance-cancel-01-contracts/

## Intent and context

`riela instance cancel` cancels one running RielaApp instance execution. Later
plans implement the parts: events-serve child (05), App parent channel (06),
App manual launches (07), coordinator (08) and route (10). They all share
types that must be identical. This plan pins those types in four **new** files
so wave-2 plans can work in parallel. It contains no behavior beyond the
types, codecs and the lock-protected registry.

## Non-goals

- Do not edit any existing source file. Every file below is new.
- No wiring into runners, channels, routes or the CLI.
- Do not change `WorkflowServeAdmissionFrame`/`Acknowledgement` in
  `Sources/RielaServer/WorkflowServeAdmission.swift`.

## File-level changes

### Sources/RielaCore/OperatorCancellation.swift (new)

`public final class OperatorCancellation: @unchecked Sendable`, using an
`NSLock`:
- `public init()`
- `public func request(reason: String, actor: String) -> Bool`. The first
  call stores both values and returns true; later calls return false and
  change nothing.
- `public var isRequested: Bool`
- `public var failureReason: String?`, exactly
  `"operator_cancelled by \(actor): \(reason)"` once requested, otherwise nil.

### Sources/RielaServer/WorkflowServeSessionControl.swift (new)

Imitate `Sources/RielaServer/WorkflowServeAdmission.swift` (sorted-key
encoding, a trailing `\n`, and the `maxFrameBytes` 1,048,576 guard).
- `public enum WorkflowServeSessionControlWire { static let controlTypes = ["session-cancel","session-list"]; static let acknowledgementTypes = ["session-cancel-ack","session-list-ack"]; static let maxReasonBytes = 512 }`
- `public struct WorkflowServeSessionControlFrame: Codable, Equatable, Sendable { type, requestId: String; sessionId, reason, actor: String? }`
  with `encodedLine() throws -> Data` and
  `static func decodeControlLine(_ data: Data) -> Self?`. The decode accepts
  only the two control types. For `session-cancel` it also requires a
  non-empty sessionId, a reason of 1...512 UTF-8 bytes with no NUL, and a
  non-empty actor; otherwise it returns nil.
- `public enum WorkflowServeSessionCancelOutcome: String, Codable, Sendable { case cancelRequested, alreadyRequested, notFound }`
- `public struct WorkflowServeSessionControlAcknowledgement: Codable, Equatable, Sendable { type, requestId: String; sessionId: String?; outcome: WorkflowServeSessionCancelOutcome?; sessionIds: [String]?; pendingRunCount: Int? }`
  with `static func decodeLine(_:) -> Self?`, which accepts only the two ack
  types, and convenience factories `cancelAck(requestId:sessionId:outcome:)`
  and `listAck(requestId:sessionIds:pendingRunCount:)`.
- `public enum WorkflowServeSessionControlError: Error, Equatable, Sendable { case unsupported, noAcknowledgement, childExited }`

Pitfalls:
- The type strings must not overlap the admission types. An admission line
  must decode as nil here, and a session line must decode as nil through
  `WorkflowServeAdmissionFrame.decodeControlLine`.
- An environment frame (`{"generation":..}`) must decode as nil.

### Sources/RielaCLI/LiveSessionCancelRegistry.swift (new)

`public final class LiveSessionCancelRegistry: @unchecked Sendable`, using one
`NSLock`:
- `public func beginRun()` / `public func endRun()`: the in-flight counter,
  never below 0.
- `public func register(sessionId: String, cancellation: OperatorCancellation, cancel: @escaping @Sendable () -> Void)`
- `public func unregister(sessionId: String)`
- `public func requestCancel(sessionId: String, reason: String, actor: String) -> WorkflowServeSessionCancelOutcome`.
  Under the lock: an unknown id returns `.notFound`. If
  `cancellation.request` returns false, return `.alreadyRequested`. Otherwise
  call `cancel()` and return `.cancelRequested`. Calling `cancel()` while
  holding the lock is allowed **only** because `cancel` merely calls
  `Task.cancel()`; document that callers must not pass a blocking closure.
- `public func liveSnapshot() -> (sessionIds: [String], pendingRunCount: Int)`.
  Ids are sorted. `pendingRunCount = max(0, inFlight - registered.count)`.

### Sources/RielaAppSupport/RielaAppInstanceCancelContract.swift (new)

Imitate `Sources/RielaAppSupport/RielaAppInstanceReloadContract.swift`.
- `public struct RielaAppInstanceCancelRequest: Codable, Equatable, Sendable { expectedProfile: String; reason: String }`
  with `static func decodeStrict(_ body: Data) throws -> Self`. The key set
  must be exactly `{expectedProfile, reason}`, and the body at most 65,536
  bytes. The reason is trimmed of whitespace and newlines and must be
  1...512 UTF-8 bytes with no NUL. Every failure throws
  `RielaAppInstanceCancelError(code: .invalidCancelRequest)`.
- `public enum RielaAppInstanceCancelCode: String, Codable, Sendable, CaseIterable`.
  Raw values and `httpStatus`: `invalid_cancel_request` 400,
  `instance_not_found` 404, `session_not_found` 404,
  `configuration_conflict` 409, `not_running` 409, `session_not_owned` 409,
  `cancel_unavailable` 409, `instance_busy` 409, `no_running_execution` 409,
  `ambiguous_running_sessions` 409.
- `public struct RielaAppInstanceCancelError: Error, Equatable, Sendable { code; message: String = ""; sessionIds: [String]?; pendingRunCount: Int? }`
- `public struct RielaAppInstanceCancelResponse: Codable, Equatable, Sendable { identity, profile, sessionId, owner, outcome: String }`.
  `owner` is "app" or "eventServe"; `outcome` is "cancelRequested" or
  "alreadyRequested".
- `public struct RielaAppLiveSessionInventory: Equatable, Sendable { sessionIds: [String]; pendingRunCount: Int }`
- `public enum RielaAppStoredSessionState: Equatable, Sendable { case absent, terminal, nonTerminal }`
- `public static let rielaAppCancelActorPrefix = "rielaapp-api:"`, used as
  the actor `rielaapp-api:<profile>`. Put it on an enum namespace
  `RielaAppInstanceCancelActor.actor(profile:) -> String`.
- The ports protocol, pinned exactly; plans 08 and 10 depend on it:

```swift
public protocol RielaAppInstanceCancelPorts: Sendable {
  func profile() async -> String
  func instanceExists(identity: String) async -> Bool
  func cancelAppLaunch(identity: String, sessionId: String, reason: String, actor: String) async -> WorkflowServeSessionCancelOutcome
  func appInventory(identity: String) async -> RielaAppLiveSessionInventory
  func childRunning(identity: String) async -> Bool
  func childSessionControl(identity: String, frame: WorkflowServeSessionControlFrame) async throws -> WorkflowServeSessionControlAcknowledgement
  func storedSessionState(identity: String, sessionId: String) async -> RielaAppStoredSessionState
}
```

## Tests (new files)

- `Tests/RielaCoreTests/OperatorCancellationTests.swift`:
  - first request → true, and failureReason equals the exact string;
  - second request → false, and the first reason is kept;
  - not requested → `isRequested == false` and failureReason nil.
- `Tests/RielaServerTests/WorkflowServeSessionControlTests.swift`:
  - each frame and ack round-trips encode/decode;
  - admission lines, environment frames and unknown types → nil;
  - a cancel frame with a 513-byte reason or a NUL → nil;
  - an oversize line → nil;
  - `WorkflowServeAdmissionFrame.decodeControlLine` of a session line → nil.
- `Tests/RielaCLITests/LiveSessionCancelRegistryTests.swift`:
  - register + requestCancel → `.cancelRequested`, and the closure is called
    once;
  - a second request → `.alreadyRequested`, and the closure is not called
    again;
  - unknown → `.notFound`;
  - unregister, then request → `.notFound`;
  - `beginRun` ×2 + register 1 → snapshot `(["id"], 1)`;
  - `endRun` below zero stays 0;
  - concurrent stress (1,000 iterations, a `DispatchQueue.concurrentPerform`
    of unregister vs requestCancel) → each iteration is either `.notFound` or
    a cancel with exactly one closure call.
- `Tests/RielaAppSupportTests/RielaAppInstanceCancelContractTests.swift`:
  - the strict decode accepts the exact keys;
  - an extra key, a missing key, a reason that is empty after trimming, a
    513-byte reason, or a body over 64 KiB → `invalid_cancel_request`;
  - every code's raw value and httpStatus match the table above;
  - the response encodes exactly the five keys.

## Invariants

- No existing file changes.
- Code strings are exactly as in the design.
- The registry never holds the lock across `await`. It is a class, not an
  actor.

## Verification (all via `arch -arm64 /bin/zsh -lc` from the worktree root; tee each to the evidence root)

- `swift build 2>&1 | tee tmp/instance-cancel/instance-cancel-01-contracts/build.log`
  → exit 0.
- `swift test --filter "OperatorCancellationTests|WorkflowServeSessionControlTests|LiveSessionCancelRegistryTests|RielaAppInstanceCancelContractTests" 2>&1 | tee tmp/instance-cancel/instance-cancel-01-contracts/test.log`
  → exit 0, all listed tests executed, 0 failures.
- `swiftlint lint <the 8 new files> 2>&1 | tee tmp/instance-cancel/instance-cancel-01-contracts/lint.log`
  → 0 violations.

## Done criteria

- The 8 new files exist; the listed test classes pass.
- `git diff --stat` shows no modified pre-existing files.
- The progress log records each command, its exit status and its log path.

## Drift protocol

Before each edit, re-read the file. Record pre/post `shasum -a 256` in the
progress log. If a file you own changed unexpectedly, stop and record drift;
do not overwrite it.
