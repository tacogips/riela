# ar-08-cli-triggers: post-run hook and serve/events schedulers (RielaCLI)

```json
{
  "planId": "ar-08-cli-triggers",
  "planPath": "impl-plans/active/automatic-retention-08-cli-triggers.md",
  "dependsOn": ["ar-07-cli-service-gc-docs"],
  "wave": 4,
  "writePaths": [
    "Sources/RielaCLI/AutomaticRetentionHook.swift",
    "Tests/RielaCLITests/AutomaticRetentionTests.swift",
    "impl-plans/progress/ar-08-cli-triggers.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/EntryPoint.swift",
    "Sources/RielaCLI/EventLiveServe.swift",
    "Sources/RielaCLI/ServeHTTPCommand.swift"
  ],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/EntryPoint.swift", "intendedEdit": "In RielaCLIMain.run, after stdout/stderr of `result` are written and before Foundation.exit, call AutomaticRetentionHook.runIfApplicable(arguments:exitCode:cancelled: runTask.isCancelled ...) and write each returned warning line to stderr; exit code unchanged."},
    {"path": "Sources/RielaCLI/EventLiveServe.swift", "intendedEdit": "In serve(eventRoot:target:parsed:output:), after EventLiveConfig.load succeeds and only when maximumEvents == nil, create and start a RielaRetentionScheduler(runImmediately: false) whose pass calls AutomaticRetentionHook.runAutomaticPass; `defer { scheduler?.stop() }` covers every return path. No other change."},
    {"path": "Sources/RielaCLI/ServeHTTPCommand.swift", "intendedEdit": "In run(command:parsed:onReady:), start a RielaRetentionScheduler(runImmediately: false) right before the long Task.sleep and stop it after the sleep returns or is cancelled. No other change."}
  ]
}
```

## Intent and context

Design §6.1. Automatic enforcement runs:

- after `workflow run`, `session resume`, `session rerun` and `session continue`,
  in the process entry point after the command result is written;
- periodically inside long-lived `riela events serve` and bare `riela serve`.

The command's exit code and stdout must never change. Warnings go only to stderr.
The service (ar-07) does all the work. The scheduler (ar-06) is generic.

`RielaCLIMain.run` (`Sources/RielaCLI/EntryPoint.swift:4-89`) writes
`result.stdout` and `result.stderr`, then calls `Foundation.exit`, which cannot
be unit tested. So the decision logic and the pass live in a testable
`AutomaticRetentionHook`.

Follow the shared worker protocol in `impl-plans/active/automatic-retention.md`.

## Non-goals

- No jsonl retention event, so stdout is untouched.
- No hook inside `RielaCLIApplication.run`. Tests call that function, and it
  must not prune.
- No RielaApp changes (ar-09).

## File-level changes

### `Sources/RielaCLI/AutomaticRetentionHook.swift` (new)

```swift
enum AutomaticRetentionHook {
  static func applies(arguments: [String], exitCode: CLIExitCode, cancelled: Bool) -> Bool
  static func request(arguments: [String], environment: [String: String], currentDirectory: String) -> RielaRetentionRequest
  /// Never throws; returns stderr lines prefixed "riela retention warning: ".
  static func runAutomaticPass(_ request: RielaRetentionRequest, service: RielaRetentionService = .init()) -> [String]
  static func runIfApplicable(arguments: [String], exitCode: CLIExitCode, cancelled: Bool,
                              environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
                              service: RielaRetentionService = .init()) -> [String]
}
```

**`applies`** returns true only when all of these hold:

- the arguments start with `["workflow","run"]` or `["session","resume"|"rerun"|"continue"]`;
- `exitCode != .usage`;
- neither `--help` nor `-h` is present;
- `!cancelled`.

**`request`** builds the automatic request:

- trigger `.automatic`, scope `.all`, `dryRun` false, empty overrides;
- home from `CLIRuntimeEnvironment.homeDirectory(environment:)`;
- `projectDirectory` from the value after `--working-dir` / `--working-directory`
  (also the `=value` form), else `currentDirectory`. A relative value resolves
  against `currentDirectory`;
- `explicitSessionStore` from `--session-store`, else nil. The resolver reads
  `RIELA_SESSION_STORE` itself.

The scan is lenient: unknown flags are ignored, and a flag missing its value is
ignored.

**`runAutomaticPass`**:

- calls `service.run`;
- maps a thrown config or usage error to one warning line
  (`riela retention warning: <localizedDescription>`);
- maps each target with status `failed` to one line with its first warning;
- emits nothing for success, `skippedThrottled` or `skippedBusy`.

### `EntryPoint.swift` edit

After the existing stdout and stderr writes, and before
`Foundation.exit(result.exitCode.rawValue)`:

```swift
for line in AutomaticRetentionHook.runIfApplicable(arguments: arguments, exitCode: result.exitCode, cancelled: runTask.isCancelled) {
  FileHandle.standardError.write(Data((line + "\n").utf8))
}
```

The exit code expression is unchanged. Do not hook the `worker` or
long-running-serve branches: they return through the same path, but `applies`
rejects them by their arguments.

### `EventLiveServe.swift` and `ServeHTTPCommand.swift` edits

Follow the `sharedPathNotes`. The scheduler pass closure is:

```swift
{ for line in AutomaticRetentionHook.runAutomaticPass(request) { FileHandle.standardError.write(...) } }
```

Build `request` once, from `CLIRuntimeEnvironment.mergedProcessEnvironment()`,
`parsed.workingDirectory ?? cwd` and `parsed.sessionStore`, with
`runImmediately: false`. The interval is the default 300 s.

## Patterns to imitate

- `EntryPoint.swift`: its existing stderr writes.
- `WorkflowCommandScenarioTests.swift:58-84`: mock-scenario runs against a temp
  `--session-store` and `--working-dir`.

## Pitfalls

- The process exit code must stay `result.exitCode` even when the pass emits
  warnings or throws internally. Write no stdout from the hook.
- `runTask.isCancelled` must be read after `runTask.value`. A signal-cancelled
  run skips retention.
- Events serve with `maximumEvents` set (tests, bounded runs) must not start the
  scheduler. Otherwise tests that use the real HOME could prune real data.
- `runImmediately: false` for both serve paths. The first pass happens after one
  interval.
- Never call `exit` or `fatalError` in the hook.

## Tests (`Tests/RielaCLITests/AutomaticRetentionTests.swift`, class `AutomaticRetentionTests`)

Use a temp HOME (`environment: ["HOME": home]`), a temp project and a temp
session store under `<cwd>/tmp`.

- **The acceptance case.** Write config `{"retention":{"results":{"maxAgeDays":1}}}`
  into `<home>/.riela/config.json`. Run `RielaCLIApplication().run(["workflow",
  "run", ..., "--session-store", <store>, "--working-dir", <project>,
  "--mock-scenario", ...], environment:)` twice, using
  `examples/worker-only-single-step` (via `--workflow-definition-dir` as in
  `WorkflowCommandScenarioTests`). Then set `updated_at` explicitly for BOTH
  sessions in BOTH `workflow_runtime_snapshots` and `cli_workflow_sessions`
  (ISO8601 with fractional seconds, as the store writes it), relative to the
  injected clock `fixedNow`: first session `fixedNow - 3 days`, second session
  `fixedNow - 1 hour`. Metadata takes `max(updated_at)` across both tables, so
  backdating only one table keeps the first session too young. Never combine
  real-run timestamps with the absolute `1_800_000_000` clock; alternatively
  derive `fixedNow` from the real time captured after the runs. Then call `AutomaticRetentionHook.runIfApplicable(arguments:, exitCode:
  result.exitCode, cancelled: false, environment:, service:
  RielaRetentionService(clock: fixedNow))`. Expect:
  - the returned warnings are empty;
  - the first session is gone from the store and the second remains;
  - `result.exitCode` and `result.stdout` are byte-identical to values captured
    before the hook ran.
- same setup with no config -> nothing deleted and no `retention` directory
  created
- same setup with a corrupt config (`{"retention":{"results":{"bogus":1}}}`) ->
  one warning line with the prefix, nothing deleted, and the exit code from
  `result` still `.success`
- `applies`: `["gc"]` -> false; `["workflow","run","x","--help"]` -> false; exit
  `.usage` -> false; cancelled -> false; `["session","continue","id"]` -> true
- `request`: `--working-dir=/a/b` and `--session-store rel` with
  `currentDirectory: /c` -> project `/a/b` and store `rel`; the resolver
  standardizes the relative path against the project
- a running session in the store with a cap of 1 byte -> the running session is
  untouched by the hook pass. If the session comes from a real run, apply the
  same explicit `updated_at` rule (both tables, relative to the injected clock)
  so it is not `unknownOrFutureTimestamp` by accident

## Verification

1. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter AutomaticRetentionTests > tmp/automatic-retention/ar-08-cli-triggers/test.log 2>&1'
   ```
   Must show exitStatus 0, testsRun ≥ 6 and failureCount 0.
2. ```
   arch -arm64 /bin/zsh -lc 'swift build --product riela > tmp/automatic-retention/ar-08-cli-triggers/build.log 2>&1'
   ```
   Must exit 0. If the product name differs, use `swift build` and record the
   command actually used.
3. Mock-scenario CLI evidence against a temp home. All scratch goes under
   `tmp/automatic-retention/ar-08-cli-triggers/home`:
   1. Write a config with `logs.maxAgeDays: 14`.
   2. Create a log file 20 days old under `<home>/.riela/logs`.
   3. Run the built binary:
      `HOME=<home> .build/debug/riela workflow run worker-only-single-step --workflow-definition-dir examples --mock-scenario examples/worker-only-single-step/mock-scenario.json --session-store <home>/.riela/sessions --working-dir <home> --output json`.
   4. Record the exit code, and confirm the old log file is gone and the
      command's stdout is a valid workflow-run JSON.
   Record `{command, logPath, exitStatus}` with testsRun 0 and failureCount 0.
4. ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCLI/AutomaticRetentionHook.swift Sources/RielaCLI/EntryPoint.swift Sources/RielaCLI/EventLiveServe.swift Sources/RielaCLI/ServeHTTPCommand.swift Tests/RielaCLITests/AutomaticRetentionTests.swift > tmp/automatic-retention/ar-08-cli-triggers/swiftlint.log 2>&1'
   ```
   Must exit 0.

## Done criteria

- `grep -n "AutomaticRetentionHook.runIfApplicable" Sources/RielaCLI/EntryPoint.swift`
  matches.
- `grep -n "RielaRetentionScheduler(" Sources/RielaCLI/EventLiveServe.swift Sources/RielaCLI/ServeHTTPCommand.swift`
  matches both files.
- `grep -n "AutomaticRetentionHook" Sources/RielaCLI/RielaCLIApplication.swift`
  prints nothing.
- The progress records exist with integer fields.
