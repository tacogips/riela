# instance-cancel-09: Pure cancel coordinator (explicit session and no-session)

**planId**: instance-cancel-09-cancel-coordinator
**dependsOn**: instance-cancel-01-contracts (`RielaAppInstanceCancelPorts` and the DTOs, codes and frames)
**Design Reference**: design-docs/specs/design-instance-cancel.md §3 C4 steps 1-5, C4b steps 1-4, C6
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-09-cancel-coordinator.md
**Evidence root**: tmp/instance-cancel/instance-cancel-09-cancel-coordinator/

## Intent

Put every cancel decision in one pure, fully testable struct over
`RielaAppInstanceCancelPorts`, the same way reload uses
`Sources/RielaAppSupport/RielaAppInstanceReloadCoordinator.swift`.

## Non-goals

- No HTTP, App or store access, apart from the ports.
- No changes to the reload coordinator or contract.

## File-level changes: Sources/RielaAppSupport/RielaAppInstanceCancelCoordinator.swift (new)

```swift
public struct RielaAppInstanceCancelCoordinator: Sendable {
  public init(ports: any RielaAppInstanceCancelPorts, makeRequestId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() })
  public func cancel(identity: String, sessionId: String, request: RielaAppInstanceCancelRequest) async -> Result<RielaAppInstanceCancelResponse, RielaAppInstanceCancelError>
  public func cancelSole(identity: String, request: RielaAppInstanceCancelRequest) async -> Result<RielaAppInstanceCancelResponse, RielaAppInstanceCancelError>
}
```

The actor is `RielaAppInstanceCancelActor.actor(profile: await ports.profile())`.

`cancel(identity:sessionId:)`:
1. `request.expectedProfile != profile` → `configuration_conflict`.
2. `!instanceExists` → `instance_not_found`.
3. `cancelAppLaunch`: `.cancelRequested` or `.alreadyRequested` → success
   with owner "app".
4. If `childRunning`, send a `session-cancel` frame (new requestId, sessionId,
   reason, actor). An ack outcome of cancelRequested or alreadyRequested →
   success with owner "eventServe". Any thrown error is remembered as
   `channelError = true`.
5. Then `storedSessionState`:
   - `.absent` → `session_not_found`;
   - `.terminal` → `not_running`;
   - `.nonTerminal` with `channelError` → `cancel_unavailable`;
   - `.nonTerminal` otherwise → `session_not_owned`.

`cancelSole(identity:)`:
1. Same as steps 1–2 above.
2. `appInventory`; if `childRunning`, send a `session-list` frame. Any error →
   `cancel_unavailable`, with **no** cancel call made.
3. `ids` = the sorted union, `pending` = the sum.
   - `ids` empty and `pending == 0` → `no_running_execution`;
   - `ids.count + pending > 1` → `ambiguous_running_sessions` with
     `sessionIds = ids` and `pendingRunCount = pending`;
   - `ids` empty and `pending == 1` → `session_not_owned`.
4. Exactly one id → cancel it through its owner only: the app inventory id
   goes to `cancelAppLaunch`, the child id to a `session-cancel` frame. An
   owner answer of `.notFound` → `not_running`; a channel error →
   `cancel_unavailable`.

Pitfalls:
- On the ambiguous, zero and unavailable paths, make **zero** calls to
  `cancelAppLaunch` or to a `session-cancel` frame.
- Do not consult `storedSessionState` in `cancelSole`.

## Tests: Tests/RielaAppSupportTests/RielaAppInstanceCancelCoordinatorTests.swift (new)

Use a fake ports actor that records every call.

Explicit session:
- profile mismatch → configuration_conflict;
- unknown instance → instance_not_found;
- the app owns the session → 202 owner app;
- the app answers notFound and the child cancelRequested → owner eventServe;
- the child answers alreadyRequested → outcome alreadyRequested;
- the child throws and the store is nonTerminal → cancel_unavailable;
- no owner and the store is nonTerminal → session_not_owned;
- terminal → not_running;
- absent → session_not_found.

No-session (`cancelSole`), with the history-boundary cases from the design:
- running A hidden behind 100 newer terminal sessions in the fake store, while
  the child inventory is `[A]` → A is cancelled; assert that
  `storedSessionState` was never called;
- A live in the child plus B live in the App (with 99 terminal sessions in
  between) → ambiguous_running_sessions with `[A,B]`, and the recorded cancel
  calls are empty;
- one live id plus pending 1 → ambiguous, no cancel;
- zero live (only an orphan in the store) → no_running_execution;
- a child `session-list` throw → cancel_unavailable, no cancel;
- the sole id's owner answers notFound → not_running;
- pending 1 and no ids → session_not_owned.

## Verification (arm64 shell; tee to the evidence root)

- `swift build` → exit 0.
- `swift test --filter "RielaAppInstanceCancelCoordinatorTests"` → exit 0,
  0 failures.
- `swiftlint lint` on the 2 new files → no violations.

## Done criteria

- The tests pass.
- Exactly 2 new files.
- The progress log has exit codes and log paths.

## Drift protocol

Record pre/post sha256 of the new files.
