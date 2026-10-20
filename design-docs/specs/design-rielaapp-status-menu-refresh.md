# RielaApp Status Menu Refresh and Launch on Login Status

Status: accepted for implementation (issue-resolution, single plan).

Issue: "RielaApp menu bar is extremely slow: periodic menu rebuild blocks the
main thread on SMAppService.status" (local operator report with `sample`
evidence; no tracker number).

Related: the presentation rules for the status menu, including the Launch on
Login checked state and its supplementary line, stay in
[design-rielaapp-workflow-instances.md](design-rielaapp-workflow-instances.md#status-menu).
This document only covers *when* the menu is rebuilt and *where* the
login-item status comes from.

## Problem

- `RielaApp.startDaemonStatusRefreshTimer()` schedules a 2-second repeating
  timer in `RunLoop.Mode.common`. Each tick runs
  `refreshDaemonWorkflowWindow(refreshesInstanceCache: false)`, which ends in
  `rebuildMenu()`.
- `rebuildMenu()` reads `launchAtLogin.isEnabled` and
  `launchAtLogin.menuSupplementaryStatusDescription`. `RielaLaunchAtLoginController`
  implements both as live `SMAppService.mainApp.status` reads. Each read is a
  synchronous XPC round trip to `smd`. That puts at least two blocking calls on
  the main thread every 2 s. The samples show up to 100% of main-thread time
  blocked in `-[SMAppService status]`.
- `.common` includes event tracking. The timer therefore also fires while the
  status menu is open, replaces `statusItem.menu`, and blocks while the user is
  choosing an item.
- `rebuildMenu()` has 12 call sites (launch, timer path, toggle, autostart,
  distributed controller transitions, web server state changes). The fix must
  make `rebuildMenu()` itself free of ServiceManagement calls; it is not enough
  to special-case the timer.

## Goals

1. No path reachable from the refresh timer or from `rebuildMenu()` calls
   ServiceManagement.
2. The login-item status is read off the main thread, and only at three
   triggers: app launch, after a Launch on Login toggle, and when the status
   menu opens.
3. An open status menu is never replaced. A changed Launch on Login state is
   applied to the open menu in place, and a full rebuild happens after the menu
   closes.
4. The periodic refresh does not run during menu or event tracking.
5. Toggling Launch on Login still registers/unregisters, and the status text
   and menu show the refreshed status.

## Non-Goals

- Changing the refresh interval, the daemon-window update logic, or the menu
  layout and copy.
- Making `register()` / `unregister()` asynchronous. An explicit user toggle may
  block briefly.
- Observing login-item changes made in System Settings while the menu is closed
  and the app is idle. The next menu open picks them up.

## Design

### Launch on Login controller (`Sources/RielaApp/RielaLaunchAtLoginController.swift`)

- Change it from a `@MainActor struct` to a `@MainActor final class`, so that
  `RielaApp.launchAtLogin` (a `let`) shares one cache.
- Give it an injectable status reader,
  `typealias StatusReader = @Sendable () -> SMAppService.Status`, defaulting
  to `{ SMAppService.mainApp.status }`. The reader is nonisolated and Sendable.
  `SMAppService.Status` is an integer-backed enum, so it can cross isolation
  safely. Tests inject a counting fake.
- Cache the status as `private(set) var status: SMAppService.Status?`. It is
  `nil` until the first refresh completes.
- Cache-only derived properties:
  - `isEnabled`: `status == .enabled`. `nil` reads as off.
  - `statusDescription`: `.enabled` "On", `.notRegistered` "Off",
    `.requiresApproval` "Requires approval in System Settings", `.notFound`
    "Unavailable", `nil` "Checking", unknown "Unknown".
  - `menuSupplementaryStatusDescription`: `nil` for `.enabled`,
    `.notRegistered` and `nil`. Otherwise it is the same copy as
    `statusDescription`: approval, unavailable, unknown.
- `refreshStatus() async -> Bool` (discardable):
  - Runs the reader in `Task.detached(priority: .utility)` and applies the
    result on the main actor.
  - Latest request wins. Each call increments a refresh generation before
    awaiting. A result whose generation is no longer current is discarded and
    returns `false`. A slow launch-time read can then never overwrite the
    post-toggle status. Overlapping refreshes are not otherwise
    deduplicated; every trigger issues its own read.
  - Returns `true` only when the applied value differs from the cached value.
    The first successful read always counts as a change, because the cache
    starts as `nil`.
- `setEnabled(_:) throws` stays synchronous and is called only from the
  explicit toggle action. Its guards read the **live** status once,
  `SMAppService.mainApp.status`, rather than the cache. The guards are:
  - Enable: skip when the status is `.enabled` or `.requiresApproval`.
  - Disable: skip when the status is `.notRegistered` or `.notFound`.

  `setEnabled` does not update the cache. The caller refreshes it afterwards.
  This is the only main-thread ServiceManagement use, and only a user action
  reaches it.

### Status menu open state (`Sources/RielaApp/EntryPoint.swift`, `EntryPoint+Menu.swift`)

- `RielaApp` conforms to `NSMenuDelegate`. Every menu built by `rebuildMenu()`
  sets `menu.delegate = self`. The status menu is the only menu with this
  delegate.
- `RielaApp` stores two flags:
  - `isStatusMenuOpen`: set in `menuWillOpen(_:)`, cleared in
    `menuDidClose(_:)`.
  - `statusMenuNeedsRebuild`
- `rebuildMenu()`:
  - If `isStatusMenuOpen`, set `statusMenuNeedsRebuild = true` and return
    without building or assigning a menu. This one guard covers all 12 call
    sites, including `@MainActor` task completions. Those run from the main
    queue during event tracking too.
  - Otherwise build the menu from cached state only. This is today's layout,
    unchanged. Then assign `statusItem.menu` and clear
    `statusMenuNeedsRebuild`.
- `menuWillOpen(_:)`: set `isStatusMenuOpen = true`, then call
  `refreshLaunchAtLoginStatus()`.
- `menuDidClose(_:)`:
  - Set `isStatusMenuOpen = false`.
  - If `statusMenuNeedsRebuild`, schedule `rebuildMenu()` asynchronously on the
    main queue. Do not rebuild inside the callback. AppKit delivers the
    selected item's action after `menuDidClose`, and the action must be sent
    from the menu the user picked from.

### Applying a refreshed status

`refreshLaunchAtLoginStatus()` starts a `@MainActor` task that awaits
`launchAtLogin.refreshStatus()`. When the result reports a change:

- **Menu open:**
  - Update the Launch on Login item's `state` in place. Find the item in
    `statusItem.menu` by its action, `#selector(toggleLaunchAtLogin)`, not by
    its title.
  - Set `statusMenuNeedsRebuild = true`, so that adding or removing the
    supplementary line happens on the deferred rebuild after close. The open
    menu's item list is never changed.
- **Menu closed:** call `rebuildMenu()`.
- **No change:** do nothing.

### Triggers

| Trigger | Action |
| --- | --- |
| `applicationDidFinishLaunching` | Keep the existing `rebuildMenu()`, which shows the `nil` status as off with no supplementary line. Then call `refreshLaunchAtLoginStatus()`. |
| `menuWillOpen` | Call `refreshLaunchAtLoginStatus()`. |
| `toggleLaunchAtLogin` | See below. |
| Refresh timer and every other `rebuildMenu()` caller | No status read. These use the cache only. |

`toggleLaunchAtLogin`:

1. Call `launchAtLogin.setEnabled(!launchAtLogin.isEnabled)`. This flips what
   the user saw, which is the cached state.
2. On error, set the failure status text and call `rebuildMenu()`.
3. On success, start a `@MainActor` task that:
   - awaits `refreshStatus()`,
   - sets `status = "Launch on Login \(statusDescription)"`,
   - calls `rebuildMenu()`.

   The rebuild runs even when the cache did not change, because the status text
   changed.

### Refresh timer

`startDaemonStatusRefreshTimer()` adds the timer with `forMode: .default`
instead of `.common`. This is an intended tradeoff: daemon-window and menu
refresh ticks also pause while any window or control is tracking events, or
while a modal session runs. Refresh resumes on the next tick after tracking
ends. The `rebuildMenu()` guard is still required, because non-timer callers
can run while the menu is open.

## Validation Rules

- Reading `isEnabled`, `statusDescription` or
  `menuSupplementaryStatusDescription` never calls the status reader.
- `refreshStatus()` calls the reader exactly once per call. It returns `true`
  only for a real change, and discards superseded results.
- `.requiresApproval` and `.notFound` still produce the supplementary menu line.
  `nil`, `.enabled` and `.notRegistered` do not.

## Verification

- New suite `Tests/RielaAppSupportTests/RielaLaunchAtLoginControllerTests.swift`
  (`@testable import RielaApp`):
  - Uses an injected, lock-protected counting reader.
  - Does not construct `RielaApp()`, call `setEnabled`, or touch `~/.riela`,
    RielaApp storage, or the real login item.
  - Covers:
    - the `nil` state and cache-only reads, with a zero reader count after
      repeated property access;
    - change reporting: first, unchanged, changed;
    - the supplementary text for `.requiresApproval` and `.notFound`;
    - latest-request-wins, using a gated reader so that the first read
      finishes after the second.
- Build and focused tests from an arm64 shell:
  `arch -arm64 /bin/zsh -lc 'swift build --skip-update --build-tests && swift test --skip-update --skip-build --filter "RielaLaunchAtLoginControllerTests|RielaAppUXOnboardingTests|RielaAppAPIKeyTests"'`
- Lint:
  `arch -arm64 /bin/zsh -lc 'swiftlint --strict Sources/RielaApp/RielaLaunchAtLoginController.swift Sources/RielaApp/EntryPoint.swift Sources/RielaApp/EntryPoint+Menu.swift Tests/RielaAppSupportTests/RielaLaunchAtLoginControllerTests.swift'`
- Static check that ServiceManagement is used only in
  `RielaLaunchAtLoginController.swift`:
  `grep -rn "SMAppService" Sources/RielaApp`
- Optional extra guard: the existing
  `RielaAppBehaviorRegressionTests/testStatusMenuUsesCompactSummaryItemsAtRuntime`
  already calls `rebuildMenu()` on a `RielaApp()`. After this change it reads
  only the cache.
- Every verification record has these fields:
  - integer `exitStatus`, `testsRun` and `failureCount`;
  - a complete log under `tmp/`.

## Rollout Constraints

- One implementation plan in `Sources/RielaApp`, plus one new test file. No
  storage, schema, CLI or GraphQL change, and no migration.
- Local commits only on `fix/menubar-launch-at-login-status` (`gitPush=false`).
- The operator draft `tmp/menubar/reference-manual-fix.patch` matches most of
  this design. It lacks three things:
  - latest-request-wins;
  - the deferred rebuild on close (`statusMenuNeedsRebuild`);
  - the in-place lookup by action instead of title.

  It may be adopted as a starting point, but it must be extended to this design
  and re-verified.
