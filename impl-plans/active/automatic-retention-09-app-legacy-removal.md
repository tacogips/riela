# ar-09-app-legacy-removal: RielaApp retention start and removal of legacy gc config

```json
{
  "planId": "ar-09-app-legacy-removal",
  "planPath": "impl-plans/active/automatic-retention-09-app-legacy-removal.md",
  "dependsOn": ["ar-07-cli-service-gc-docs"],
  "wave": 4,
  "writePaths": [
    "Sources/RielaApp/EntryPoint+GarbageCollection.swift",
    "Sources/RielaApp/EntryPoint+Retention.swift",
    "Sources/RielaCore/RielaDataGarbageCollector.swift",
    "Tests/RielaCoreTests/RielaDataGarbageCollectorTests.swift",
    "Tests/RielaAppSupportTests/RielaAppRetentionStartTests.swift",
    "impl-plans/progress/ar-09-app-legacy-removal.md"
  ],
  "sharedPaths": [
    "Sources/RielaApp/EntryPoint.swift"
  ],
  "sharedPathNotes": [
    {"path": "Sources/RielaApp/EntryPoint.swift", "intendedEdit": "Replace the `startGarbageCollection()` call in applicationDidFinishLaunching (line 90) with `startRetention()`, and add one stored property `var retentionScheduler: RielaRetentionScheduler?` next to the other stored properties (around line 53). No other change."}
  ]
}
```

## Intent and context

Design §6.1 (RielaApp runs retention at launch and then periodically) and §2.2
(`gc.retentionDays` is removed with no alias).

Today `Sources/RielaApp/EntryPoint+GarbageCollection.swift:startGarbageCollection`
runs `RielaDataGarbageCollector` once at launch, only when `gc.retentionDays`
is set. After ar-07, its only remaining user of
`RielaGarbageCollectionConfiguration` is this file, and
`Tests/RielaCoreTests/RielaDataGarbageCollectorTests.swift:6-33`.

RielaApp tests leak into the real `~/.riela` unless roots are injected, so the
request builder must be a pure function of the injected home, project root and
environment.

Follow the shared worker protocol in `impl-plans/active/automatic-retention.md`.

## Non-goals

- Do not change the `RielaDataGarbageCollector.collect(...)` signature or its
  sweep behavior. ar-07 calls it.
- Keep `RielaGarbageCollectionScope`, `RielaGarbageCollectionReport` and
  `RielaGarbageCollectionError`; `collect` still uses them.
- No UI for retention.

## File-level changes

1. **Delete `Sources/RielaApp/EntryPoint+GarbageCollection.swift`.**
2. **Add `Sources/RielaApp/EntryPoint+Retention.swift`**, wrapped in
   `#if os(macOS)` like the deleted file:
   - an internal free function
     `func rielaAppRetentionRequest(homeDirectory: URL, projectRoot: URL?,
     environment: [String: String]) -> RielaRetentionRequest`. It builds
     `trigger .automatic`, `scope .all`, `projectDirectory: projectRoot` (nil
     when unset, so the project target is skipped; never the process cwd),
     `explicitSessionStore: nil`, empty overrides and `dryRun: false`;
   - `extension RielaApp { func startRetention() }`. It builds the request from
     `appHomeDirectory`, `launchOptions.projectRoot` and
     `launchOptions.environment`. Then it creates
     `RielaRetentionScheduler(runImmediately: true, pass: { ... })`. The pass
     calls `RielaRetentionService().run(request)` inside do/catch. It writes the
     first warning of each failed target, or the thrown error, to stderr with the
     prefix `RielaApp retention warning:`. `AutomaticRetentionHook` is internal
     to RielaCLI and is not used here. Assign the scheduler to
     `retentionScheduler`, then call `start()`.
3. **`Sources/RielaApp/EntryPoint.swift`**: make only the edit in
   `sharedPathNotes`.
4. **`Sources/RielaCore/RielaDataGarbageCollector.swift`**:
   - delete `RielaGarbageCollectionConfiguration` (lines 9-59);
   - delete the stale diagnostic append at line 230
     (`"runtime sessions, artifacts and logs preserved; use scoped session
     prune..."`), because retention now covers those.
   Leave everything else unchanged.
5. **`Tests/RielaCoreTests/RielaDataGarbageCollectorTests.swift`**:
   - remove `testConfigurationDefaultsToDisabledAndSupportsEnvironmentOverride`
     and `testConfigurationFileEnablesRetention`;
   - keep every sweep test;
   - drop any assertion on the deleted diagnostic string.

## Patterns to imitate

- The deleted `startGarbageCollection`: how it reads `appHomeDirectory`,
  `launchOptions.projectRoot` and `launchOptions.environment`, and its stderr
  warning format.
- `Tests/RielaAppSupportTests/RielaAppLaunchOptionsTests.swift`: how App-level
  tests are written.

## Pitfalls

- Never compute the project directory from
  `FileManager.default.currentDirectoryPath` in RielaApp. A Finder launch has
  cwd `/`, and tests would hit the real tree.
- Do not instantiate `RielaApp` in tests. Test `rielaAppRetentionRequest` and run
  `RielaRetentionService` on the request it returns, against temp roots.
- `grep -rn "RielaGarbageCollectionConfiguration" Sources Tests` must return
  nothing when this plan is done. If a match remains outside your `writePaths`,
  ar-07 is incomplete; log it as a blocker dependency on ar-07.

## Tests (`Tests/RielaAppSupportTests/RielaAppRetentionStartTests.swift`, class `RielaAppRetentionStartTests`)

- `rielaAppRetentionRequest(homeDirectory: tmpHome, projectRoot: nil,
  environment: ["HOME": tmpHome.path])` -> trigger automatic, scope all,
  `projectDirectory == nil`, `homeDirectory == tmpHome`
- with config `{"retention":{"logs":{"maxAgeDays":14}}}` in `tmpHome/.riela`
  and a 20-day-old `tmpHome/.riela/logs/a.jsonl`, running
  `RielaRetentionService(clock: fixed).run(request)` -> the file is removed; the
  report has exactly one target, of kind `user` with `root == tmpHome/.riela`;
  no path outside `tmpHome` appears in the report
- with no config -> the report has no targets and nothing is created under
  `tmpHome`

`RielaDataGarbageCollectorTests` and `RielaDataGarbageCollectorHandoverTests`:
the remaining sweep tests stay green.

## Verification

1. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAppRetentionStartTests|RielaDataGarbageCollectorTests|RielaDataGarbageCollectorHandoverTests" > tmp/automatic-retention/ar-09-app-legacy-removal/test.log 2>&1'
   ```
   Must show exitStatus 0, testsRun ≥ 3 + (the remaining collector test count)
   and failureCount 0.
2. ```
   arch -arm64 /bin/zsh -lc 'swift build --product RielaApp > tmp/automatic-retention/ar-09-app-legacy-removal/build.log 2>&1'
   ```
   Must exit 0.
3. ```
   grep -rn "RielaGarbageCollectionConfiguration\|startGarbageCollection" Sources Tests
   ```
   Must print nothing (grep exit 1).
4. ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaApp/EntryPoint+Retention.swift Sources/RielaApp/EntryPoint.swift Sources/RielaCore/RielaDataGarbageCollector.swift Tests/RielaCoreTests/RielaDataGarbageCollectorTests.swift Tests/RielaAppSupportTests/RielaAppRetentionStartTests.swift > tmp/automatic-retention/ar-09-app-legacy-removal/swiftlint.log 2>&1'
   ```
   Must exit 0.

## Done criteria

- `test ! -e Sources/RielaApp/EntryPoint+GarbageCollection.swift`
- `grep -n "startRetention()" Sources/RielaApp/EntryPoint.swift` matches.
- The progress records exist with integer fields.
