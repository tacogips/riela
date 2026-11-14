# Instance control 03: honour persisted web-server isEnabled at App launch

**Status**: Completed; accepted (code in checkpoint ca369733, recorded as acceptedDependency in `instance-control-dispatch.json`)
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

- [x] Autostart honours the persisted `isEnabled`.
- [x] Tests pass and logs are recorded.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Implementation (Codex): added the pure launch decision, controller guard, and isolated truth-table/persisted/missing settings tests. Existing listener start failure handling and save path remain unchanged. Entry point and shared control tests unchanged.

- Focused test: `tmp/instance-control/instance-control-03-webserver-autostart/test.log`, exit 1 before compilation; private `notion-gateway` checkout is absent and remote fetch requires authentication. Resume by making the resolved dependency available to SwiftPM, then rerun the focused test command with isolated HOME and RIELA_APP_ROOT.
- Plan lint: `tmp/instance-control/instance-control-03-webserver-autostart/lint.log`, exit 0.
- Strict changed-file lint: `tmp/instance-control/instance-control-03-webserver-autostart/strict-lint.log`, exit 0; path manifest `changed-swift.nul` in the same evidence directory.
- These checks ran on a moving shared tree. Formal review and serial integration remain downstream.

### Verification retry
- The resolved `.build/checkouts/notion-gateway` checkout is now present. The focused test remains unrun on this retry: the dispatch declares no artifact roots, while SwiftPM would create or update build products outside an authorized root. Resume after a checkpoint amendment authorizes a build artifact root and corresponding test command.
- Strict changed-file lint reran with exit 0: `tmp/instance-control/instance-control-03-webserver-autostart/strict-lint-retry.log`. The behavioral test criterion remains unchecked.

## Amendment 2026-11-10 (blocked-wave-scope-or-contract, round 1)

**Blocker resolved.** The dispatch declared `artifactRoots: []`, while `swift test` writes SwiftPM build output. This amendment authorizes build output in two serialized lanes. No design, contract, or source `writePaths` change.

**Lanes:**
- Lane A owns `.build`: plans 04 → 05 → 07 → 09 → 10.
- Lane B owns `tmp/instance-control/swiftpm-lane-b`: plans 03 → 08 → 06.
- The added `dependsOn` edges exist only for resource ordering, so no two plans that can run at once own the same root.

**This plan is the lane B head.**
- `writePaths` and `artifactRoots` add `tmp/instance-control/swiftpm-lane-b`.
- `dependsOn` stays none.
- Never run SwiftPM against `.build` from this plan. Read `.build` only, for seeding.

**Disk gate.** Before seeding or the first build, `df -k .` must show Available ≥ 10485760 KiB (10 GiB). Otherwise record a `disk-space` blocker with the df output and stop. Never delete `.build`, any scratch root, or any other file to free space.

**Seed (idempotent; skipped when `workspace-state.json` already exists):**
- APFS-clone (`cp -c -R`) `.build/checkouts`, `.build/repositories` and `.build/artifacts` into the scratch root.
- Write `workspace-state.json` with the absolute `<repo>/.build/` prefix rewritten to `<repo>/tmp/instance-control/swiftpm-lane-b/`.
- Leave the `Packages/RielaMemory` path untouched.

**SwiftPM rules:**
- Every `swift build` and `swift test` adds `--scratch-path tmp/instance-control/swiftpm-lane-b`.
- Never run `swift package clean`, `reset`, `update`, or anything that rewrites `Package.resolved`.
- If dependency resolution fails, record `dependency-resolution` with the log path and stop.
- Compile errors caused only by sibling files stay `sibling-blocked`.

**Superseding verification** (each must exit 0; logs under `tmp/instance-control/instance-control-03-webserver-autostart/`):
1. Seed. The log must list the four seeded entries:
   `mkdir -p tmp/instance-control/instance-control-03-webserver-autostart && arch -arm64 /bin/zsh -lc 'd=tmp/instance-control/swiftpm-lane-b; { df -k .; if [ ! -f $d/workspace-state.json ]; then mkdir -p $d && cp -c -R .build/checkouts .build/repositories .build/artifacts $d/ && sed "s#$PWD/.build/#$PWD/$d/#g" .build/workspace-state.json > $d/workspace-state.json; fi; ls -d $d/checkouts $d/repositories $d/artifacts $d/workspace-state.json; } 2>&1 | tee tmp/instance-control/instance-control-03-webserver-autostart/scratch-seed.log; exit ${pipestatus[1]}'`
2. Focused tests, 0 failures:
   `arch -arm64 /bin/zsh -lc 'swift test --scratch-path tmp/instance-control/swiftpm-lane-b --filter "RielaAppWebServerAutostartTests|RielaAppWebServerSettingsTests|RielaAppWebServerControlTests" 2>&1 | tee tmp/instance-control/instance-control-03-webserver-autostart/test.log; exit ${pipestatus[1]}'`
3. The lint command in `## Verification` is unchanged.

**Progress log.** Record the seed log, the df output, and the test exit code with its log path. Tick "Tests pass" only after command 2 exits 0.

### Lane B verification retry
- Seed exited 0; `scratch-seed.log` records 26,532,788 KiB available and all four seeded entries under `tmp/instance-control/swiftpm-lane-b`.
- Focused tests with HOME and RIELA_APP_ROOT isolated under this plan's evidence directory exited 0: 10 tests, 0 failures; `test-lane-b.log`.
- Plan lint and strict changed-file lint exited 0: `lint-lane-b.log` and `strict-lint-lane-b.log`; the strict manifest is `changed-swift-lane-b.nul`.
- Tests ran on the shared working tree; serial integration and formal review remain downstream. Source hashes are recorded in `pre-plan-edit-sha256.txt` and `post-plan-edit-sha256.txt` in the evidence directory.
