# RielaApp Status Menu Refresh Implementation Plan

**planId**: `rielaapp-status-menu-refresh`
**Status**: Ready for implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: local:workflowInput.issueTitle — "RielaApp menu bar is extremely slow: periodic menu rebuild blocks the main thread on SMAppService.status" (no issue URL or number)
**Design Reference**: `design-docs/specs/design-rielaapp-status-menu-refresh.md` (accepted by Step 3, `comm-008019`, no findings); presentation rules in `design-docs/specs/design-rielaapp-workflow-instances.md#status-menu`
**dependsOn**: none (single plan, wave 1)
**Branch**: `fix/menubar-launch-at-login-status` (local commits only; `gitPush=false`)
**Progress log**: `impl-plans/progress/rielaapp-status-menu-refresh.md`

## Intent and Context

The status bar menu is slow because three things happen on the main thread.

- A 2-second timer, `RielaApp.startDaemonStatusRefreshTimer` in
  `Sources/RielaApp/EntryPoint.swift`, runs `RunLoop.main.add(timer, forMode: .common)`.
- Each tick calls `refreshDaemonWorkflowWindow(refreshesInstanceCache: false)`,
  which calls `rebuildMenu()` in `Sources/RielaApp/EntryPoint+Menu.swift`.
- `rebuildMenu()` reads `launchAtLogin.isEnabled` and
  `launchAtLogin.menuSupplementaryStatusDescription`. Both are live
  `SMAppService.mainApp.status` reads, each a synchronous XPC call to `smd`,
  defined in `Sources/RielaApp/RielaLaunchAtLoginController.swift`.

Because the timer runs in `.common` mode, it also fires while the menu is
open, and the rebuild replaces `statusItem.menu` mid-selection.

The fix:

- Cache the login-item status.
- Read it off the main thread only at launch, on `menuWillOpen`, and after a
  toggle.
- Never replace an open menu.
- Run the timer in `.default` mode.

There are 12 `rebuildMenu()` call sites, so the guard must live inside
`rebuildMenu()`, not at the timer.

The operator draft `tmp/menubar/reference-manual-fix.patch` implements most
of this. You may use it as a starting point, for example with
`git apply tmp/menubar/reference-manual-fix.patch`, after a fresh read of HEAD.
It is missing three things the design requires; tasks T1 and T2 cover them:

- a refresh generation so that the latest request wins;
- the `statusMenuNeedsRebuild` flag and the deferred rebuild on close;
- an in-place lookup by action, not by title.

The draft's test file is also missing the `.notFound` and latest-request-wins
tests.

## Non-Goals (do not do these)

- Do not change `daemonStatusRefreshInterval`, `refreshDaemonWorkflowWindow`
  logic, menu layout, menu copy, or item order.
- Do not make `register()` or `unregister()` async. Do not move `setEnabled` off
  the main actor.
- Do not observe System Settings changes. Do not add notifications, KVO, or
  polling of `SMAppService`.
- Do not touch any of these:
  - the other 11 `rebuildMenu()` callers
    (`EntryPoint+DistributedController.swift`, `EntryPoint+WebServer.swift`, and
    the other `EntryPoint.swift` sites); the guard inside `rebuildMenu()`
    covers them;
  - `RielaAppBehaviorRegressionTests.swift`;
  - storage code;
  - `Package.swift`.
- Do not construct `RielaApp()` in new tests. Do not call `setEnabled` in tests.
  Do not touch `~/.riela` or the real login item.
- Do not launch the app or use accessibility automation.
- Do not push, merge, or integrate `origin/main`.

## File-Level Changes

Before each edit, read the file fresh. Record `git hash-object <file>` before
and after each edit in the progress log. If a file's hash differs from the last
value you recorded, before you write, re-read it and reapply your intent; do not
overwrite blindly.

### 1. `Sources/RielaApp/RielaLaunchAtLoginController.swift` (T1)

Keep the `#if os(macOS)` and `import ServiceManagement` wrapper.

Contract:

```swift
@MainActor final class RielaLaunchAtLoginController {
  typealias StatusReader = @Sendable () -> SMAppService.Status
  init(readStatus: @escaping StatusReader = { SMAppService.mainApp.status })
  private(set) var status: SMAppService.Status?   // nil until first applied refresh
  var isEnabled: Bool { get }
  var statusDescription: String { get }
  var menuSupplementaryStatusDescription: String? { get }
  @discardableResult func refreshStatus() async -> Bool
  func setEnabled(_ enabled: Bool) throws
}
```

Requirements:

- The derived properties read only `status`. They never call `readStatus` or
  `SMAppService`.
  - `isEnabled` is `status == .enabled`.
  - `statusDescription`:

    | status | text |
    | --- | --- |
    | `nil` | "Checking" |
    | `.enabled` | "On" |
    | `.notRegistered` | "Off" |
    | `.requiresApproval` | "Requires approval in System Settings" |
    | `.notFound` | "Unavailable" |
    | `@unknown default` | "Unknown" |

  - `menuSupplementaryStatusDescription` is `nil` for `nil`, `.enabled` and
    `.notRegistered`. For the other cases it uses the same copy as
    `statusDescription`.
- `refreshStatus()`:
  - Add a private `refreshGeneration: Int` counter.
  - Increment it and capture the value **before** the await.
  - Copy `readStatus` into a local constant.
  - Run it with `await Task.detached(priority: .utility) { reader() }.value`.
  - After the await, return `false` without assigning if the captured
    generation is no longer current.
  - Otherwise return `false` if the value equals `status`. If it differs,
    assign it and return `true`.
- `setEnabled(_:)`:
  - Read `SMAppService.mainApp.status` once into a local constant, `current`.
  - Enable: skip when `current` is `.enabled` or `.requiresApproval`;
    otherwise `register()`.
  - Disable: skip when `current` is `.notRegistered` or `.notFound`;
    otherwise `unregister()`.
  - It must **not** read or write the cache. It must not read the status twice;
    the old code read `service.status` twice per guard.
- Pattern to imitate:
  - `@Sendable` closure injection, as in the `kaibaCatalogLoader` property in
    `Sources/RielaApp/EntryPoint.swift`;
  - `@unknown default` switch style, as in the existing controller.

Pitfalls:

- Under Swift 6 mode (`Package.swift` `swiftLanguageModes: [.v6]`), the default
  argument closure must be `@Sendable`, which the typealias makes it. Do not
  make it `@MainActor`, and do not capture `self` in the detached task. Capture
  only the local reader copy.
- Do not use `Task {}` instead of `Task.detached`. A plain `Task` inherits main
  actor isolation, so the XPC call would run on main.

### 2. `Sources/RielaApp/EntryPoint.swift` (T2)

Changes inside `final class RielaApp`:

- Keep `let launchAtLogin = RielaLaunchAtLoginController()`. It is now a class
  instance.
- Add two stored properties near `daemonStatusRefreshTimer`, each with a
  one-line doc comment:
  - `var isStatusMenuOpen = false`
  - `var statusMenuNeedsRebuild = false`

  These must stay stored on the class; Swift extensions cannot add stored
  properties.
- `applicationDidFinishLaunching`: right after the existing `rebuildMenu()` and
  before `startDaemonStatusRefreshTimer()`, call `refreshLaunchAtLoginStatus()`.
- `startDaemonStatusRefreshTimer()`:
  - Change `forMode: .common` to `forMode: .default`.
  - Add a short comment saying that the pause during any event tracking or
    modal session is intended.
- `toggleLaunchAtLogin()`:
  1. `try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)`. This flips the
     cached value the user saw.
  2. On `catch`: set
     `status = "Failed to update Launch on Login: \(error.localizedDescription)"`,
     call `rebuildMenu()`, then return.
  3. On success: start `Task { @MainActor [weak self] in ... }`. It awaits
     `launchAtLogin.refreshStatus()`, then sets
     `status = "Launch on Login \(launchAtLogin.statusDescription)"`, then calls
     `rebuildMenu()` **unconditionally**.
- Add `func refreshLaunchAtLoginStatus()`. It starts
  `Task { @MainActor [weak self] in ... }`, which awaits `refreshStatus()`. On
  `true`:
  - Menu open: find the item in `statusItem.menu?.items` whose `action` is
    `#selector(toggleLaunchAtLogin)` and set its `state` to `.on` or `.off`
    from `launchAtLogin.isEnabled`. Then set `statusMenuNeedsRebuild = true`.
  - Menu closed: call `rebuildMenu()`.

  On `false`, do nothing.

Pitfalls:

- Do not look the item up with `item(withTitle:)`.
- Do not insert or remove items in an open menu.

### 3. `Sources/RielaApp/EntryPoint+Menu.swift` (T2)

- Change the declaration to `extension RielaApp: NSMenuDelegate`.
- `rebuildMenu()`, first lines: `guard !isStatusMenuOpen else { statusMenuNeedsRebuild = true; return }`.
- After the guard, build the menu exactly as today and set
  `menu.delegate = self`.
- After `statusItem.menu = menu`, set `statusMenuNeedsRebuild = false`.
- `func menuWillOpen(_ menu: NSMenu)`: set `isStatusMenuOpen = true`, then call
  `refreshLaunchAtLoginStatus()`.
- `func menuDidClose(_ menu: NSMenu)`:
  - Set `isStatusMenuOpen = false`.
  - If `statusMenuNeedsRebuild`, run
    `DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }`. In Swift 6
    you may need `MainActor.assumeIsolated` inside the block; prefer
    `Task { @MainActor [weak self] in self?.rebuildMenu() }` if it compiles more
    cleanly. Either way the rebuild must be asynchronous.
  - Never call `rebuildMenu()` synchronously inside `menuDidClose`. AppKit sends
    the selected item's action after this callback.

Do not change any of the following:

- menu items, titles or order;
- `supplementaryMenuItem` or `menuItem`;
- `failedDaemonInstanceMenuLines`.

Existing guard: `RielaAppBehaviorRegressionTests.testStatusMenuUsesCompactSummaryItemsAtRuntime`
calls `rebuildMenu()` while the menu is closed. It must keep passing unchanged.

### 4. `Tests/RielaAppSupportTests/RielaLaunchAtLoginControllerTests.swift` (T3, new)

Setup:

- Wrap the file in `#if os(macOS)`.
- Imports: `ServiceManagement`, `XCTest`, `@testable import RielaApp`.
- Declare `@MainActor final class RielaLaunchAtLoginControllerTests: XCTestCase`.
- Add a private lock-protected `final class StatusProbe: @unchecked Sendable`,
  using `NSLock` as in the draft. It holds:
  - the current value, with a `set(_:)` method;
  - a read counter;
  - an optional one-shot gate for the first read: a "started" `XCTestExpectation`
    and a `DispatchSemaphore` release.

Test cases (`situation -> expected`):

- `testCachedPropertiesNeverInvokeReader`: before any refresh, and after one
  refresh with 50 repeated reads of `isEnabled`, `statusDescription` and
  `menuSupplementaryStatusDescription`, the probe read count stays 0 before and
  exactly 1 after.
- `testNilStatusShowsOffWithoutSupplementaryLine`: on a fresh controller,
  `isEnabled == false`, `statusDescription == "Checking"`, and
  `menuSupplementaryStatusDescription == nil`.
- `testRefreshReportsOnlyRealChanges`: with probe `.notRegistered`, the first
  refresh returns `true`. A second refresh returns `false`. After setting
  `.enabled`, the third returns `true` and `isEnabled == true` with
  `statusDescription == "On"`. Read count is 3.
- `testRequiresApprovalAndNotFoundSurfaceSupplementaryLine`: after a refresh,
  `.requiresApproval` gives "Requires approval in System Settings", and
  `.notFound` gives "Unavailable". `isEnabled` is false for both.
- `testLatestRefreshWins`:
  1. The first read signals "started", blocks on the semaphore (use a timeout
     of at most 5 s so a failure never hangs), and returns `.enabled`. Later
     reads return `.notRegistered`.
  2. Start refresh A in a `Task`.
  3. `await fulfillment(of: [started], timeout: 5)`.
  4. Await refresh B. Expect `true`, with `status == .notRegistered`.
  5. Release the semaphore and await A. Expect `false`, with `status` still
     `.notRegistered`.

  Imitate `fulfillment(of:)` usage in
  `Tests/RielaAppSupportTests/DistributedControllerSettingsTests.swift`.

## Invariants

- `grep -rn "SMAppService" Sources/RielaApp` matches only
  `RielaLaunchAtLoginController.swift`.
- In that file, only the default reader and `setEnabled` reference
  `SMAppService.mainApp`.
- `rebuildMenu()` never assigns `statusItem.menu` while `isStatusMenuOpen` is
  true.
- The cache is written only in `refreshStatus()`.

## Tasks

- [ ] T1: Rewrite the controller per File-Level Changes 1.
- [ ] T2: Wire `EntryPoint.swift` and `EntryPoint+Menu.swift` per File-Level
  Changes 2 and 3. Same plan as T1, done in serial order, because it uses T1's
  API.
- [ ] T3: Add the test suite per File-Level Changes 4.
- [ ] T4: Run verification V1–V3 and record each result in the progress log.
- [ ] T5: Commit locally, as one commit on
  `fix/menubar-launch-at-login-status`. The commit contains the four
  File-Level Changes files and the progress log. The design and plan files are
  committed by the workflow before implementation starts. Do not commit
  `tmp/`. Do not push.

## Verification

Put logs under `tmp/menubar-impl/` (gitignored). Each record in the progress
log must have these fields:

- `command`
- integer `exitStatus`
- integer `testsRun`
- integer `failureCount`
- the full `logPath`

Run `mkdir -p tmp/menubar-impl` first. Then copy each command exactly as written. The `--filter` value is a regex with
plain `|` separators; do not escape the pipes.

V1: build and focused tests.

```sh
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela/tmp/menubar-fix-worktree && swift build --skip-update --build-tests && swift test --skip-update --skip-build --filter "RielaLaunchAtLoginControllerTests|RielaAppUXOnboardingTests|RielaAppAPIKeyTests"' > tmp/menubar-impl/v1-build-test.log 2>&1
```

- Must show exit 0.
- The log ends with an XCTest summary showing 0 failures.
- `RielaLaunchAtLoginControllerTests` runs 5 tests.
- No Swift 6 concurrency errors or warnings appear for the touched files.
- Take `testsRun` from the "Executed N tests" line.

V2: lint.

```sh
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela/tmp/menubar-fix-worktree && swiftlint --strict Sources/RielaApp/RielaLaunchAtLoginController.swift Sources/RielaApp/EntryPoint.swift Sources/RielaApp/EntryPoint+Menu.swift Tests/RielaAppSupportTests/RielaLaunchAtLoginControllerTests.swift' > tmp/menubar-impl/v2-lint.log 2>&1
```

- Must show exit 0 with 0 violations.
- Record `testsRun` 0 and `failureCount` 0.
- The `RielaApp` class body (`EntryPoint.swift` lines 12–664) is about 650
  lines. `type_body_length` warns at 800, and `--strict` turns that warning
  into an error. Keep the additions small.

V3: static checks.

```sh
grep -rn "SMAppService" Sources/RielaApp > tmp/menubar-impl/v3-grep.log
grep -n "forMode" Sources/RielaApp/EntryPoint.swift >> tmp/menubar-impl/v3-grep.log
```

- Every `SMAppService` match is in `RielaLaunchAtLoginController.swift`.
- The `forMode` line shows `.default`.
- Record `testsRun` 0 and `failureCount` 0.

V4 (optional): an existing menu regression test.

```sh
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela/tmp/menubar-fix-worktree && swift test --skip-update --skip-build --filter RielaAppBehaviorRegressionTests/testStatusMenuUsesCompactSummaryItemsAtRuntime' > tmp/menubar-impl/v4-menu-regression.log 2>&1
```

- Must show exit 0, 1 test, 0 failures.
- This test already exists in the repository; it is not a new test.

## Completion Criteria

- V1, V2 and V3 records exist in the progress log with exit 0 and failureCount 0.
- `git diff --stat` touches only these files:
  - the four files in File-Level Changes;
  - `impl-plans/progress/rielaapp-status-menu-refresh.md`.
- One local commit exists on `fix/menubar-launch-at-login-status`, with nothing
  pushed.
- Every item in Invariants holds.

## Progress Log Expectations

Maintain `impl-plans/progress/rielaapp-status-menu-refresh.md` with:

- task checkbox status for T1–T5;
- pre and post hashes for each edited file;
- whether the reference patch was used and what was changed from it;
- verification records V1–V4 in the format above;
- residual notes. Do not start a note with a severity word.
