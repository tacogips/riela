# Instance control 03: honour persisted web-server isEnabled at App launch

**Status**: Planned
**planId**: instance-control-03-webserver-autostart
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md §2 row 1, D2; design-docs/specs/design-rielaapp-web-server-lifecycle-packaging.md §2.2
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-03-webserver-autostart/

## Intent and context

**Root cause.** `RielaAppWebServerController.startIfRequested(by:)` (`Sources/RielaApp/RielaAppWebServerController.swift`) starts the listener only when the App was launched with `--start-web-server` (`RielaAppLaunchOptions.startsWebServer`). `start()` persists `isEnabled = true`, but the next launch ignores it. As a result `~/.riela/rielaapp/web-server.json` says `{isEnabled:true, port:19091}` while nothing listens.

**Fix.** Start the listener when `launchOptions.startsWebServer || settings.isEnabled`. This is the one-time App upgrade the design documents.

## Non-goals

- No change to binding (127.0.0.1), port handling, Host/Origin/CSRF guards, or stop/start persistence.
- No menu change.
- Do not restart or touch the installed App or `~/.riela/rielaapp/*`. Tests use temp settings files only.

## File-level changes

1. `Sources/RielaAppSupport/RielaAppWebServerSettings.swift`: add a pure decision to `RielaAppWebServerSettings`, `public func shouldStartAtLaunch(launchFlag: Bool) -> Bool { launchFlag || isEnabled }`. This keeps it testable without AppKit.
2. `Sources/RielaApp/RielaAppWebServerController.swift`: `startIfRequested(by:)` uses `settings.shouldStartAtLaunch(launchFlag: options.startsWebServer)`.
   - `settings` is already loaded in `init` from the store.
   - A failed start keeps the existing behaviour: `state = .failed(...)`, App launch continues, and no throw.
   - **Pitfall:** do not call `settingsStore.save` on the autostart path beyond what `start()` already does.
3. `Sources/RielaApp/EntryPoint+WebServer.swift`: no logic change is expected. Only update it if the call site needs adjusting, and keep `webServerSetupError = store.load().diagnostic` as is.
   - When web assets are missing, the controller is nil and nothing starts. That is unchanged.

## Tests

Add **Tests/RielaAppSupportTests/RielaAppWebServerAutostartTests.swift (new)**. Imitate `Tests/RielaAppSupportTests/RielaAppWebServerSettingsTests.swift`.

| Case | Expected |
| --- | --- |
| `shouldStartAtLaunch` truth table: (false,false)→false, (true,false)→true, (false,true)→true, (true,true)→true | as listed |
| A settings file `{version:1,isEnabled:true,port:19091}` loaded from a temp `RielaAppWebServerSettingsStore` | `shouldStartAtLaunch(launchFlag:false) == true` |
| A missing settings file | false |

If `Tests/RielaAppSupportTests/RielaAppWebServerControlTests.swift` already constructs a controller with a fake server, add one case there only if it can be done without editing other cases. Otherwise the pure-function tests are sufficient. Do not edit that file otherwise.

## Invariants

- `isEnabled` is still written only by explicit start/stop.
- Loopback-only binding and all request guards are untouched.

## Verification

1. `mkdir -p tmp/instance-control/instance-control-03-webserver-autostart && arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAppWebServerAutostartTests|RielaAppWebServerSettingsTests|RielaAppWebServerControlTests" 2>&1 | tee tmp/instance-control/instance-control-03-webserver-autostart/test.log; exit ${pipestatus[1]}'` — 0 failures.
2. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaAppSupport/RielaAppWebServerSettings.swift Sources/RielaApp/RielaAppWebServerController.swift Sources/RielaApp/EntryPoint+WebServer.swift Tests/RielaAppSupportTests/RielaAppWebServerAutostartTests.swift 2>&1 | tee tmp/instance-control/instance-control-03-webserver-autostart/lint.log; exit ${pipestatus[1]}'`

## Edit safety

Fresh-read before each edit; record the pre- and post-edit sha256. Single owner.

## Completion criteria

- [ ] Autostart honours the persisted `isEnabled`.
- [ ] Tests pass and logs are recorded.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.
