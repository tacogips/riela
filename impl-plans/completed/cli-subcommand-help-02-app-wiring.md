# ch-02-app-wiring: run the help detector first in RielaCLIApplication, plus CleanExit backstops (#184)

```json
{
  "planId": "ch-02-app-wiring",
  "planPath": "impl-plans/active/cli-subcommand-help-02-app-wiring.md",
  "dependsOn": ["ch-01-help-core"],
  "wave": "W2",
  "writePaths": [
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Tests/RielaCLITests/SubcommandHelpApplicationTests.swift",
    "impl-plans/progress/ch-02-app-wiring.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

The design is `design-docs/specs/design-cli-subcommand-help.md`: §2.1 (the
detector runs first in `runParsed`), §2.2 (output contract), §2.4 (CleanExit
backstops in the `runParsed` final catch and in
`RielaClientFamilyArguments.parseCLI`), and §3.

ch-01 already provides these internal symbols in
`Sources/RielaCLI/CLISubcommandHelp.swift`:

- `CLIHelpRequest.detect(_:) -> CLIHelpRequest?`
- `CLIHelpRequest.resolve(_:) -> CLIHelpRequest?`
- `CLISubcommandHelp.result(for:) -> CLICommandResult`
- `CLISubcommandHelp.result(path:) -> CLICommandResult`
- `CLISubcommandHelp.isCleanExit(_:) -> Bool`

Read that file first and use those names exactly.

Current code:

- `RielaCLIApplication.runParsed` (`Sources/RielaCLI/RielaCLIApplication.swift:110-170`)
  dispatches `sandbox`, `auth` and `worker` before `parser.parse`.
  - `catch let error as CLIUsageError` goes to `renderParserFailure`.
  - The final `catch` returns `.failure` with stderr `"\(error)"`.
- `RielaClientFamilyArguments.parseCLI` (`Sources/RielaCLI/RielaClientFamilyArguments.swift:7-13`)
  wraps every error, including ArgumentParser's `CleanExit`, in
  `CLIUsageError(Self.message(for: error))`.

## Non-goals

- Do not edit `CLISubcommandHelp.swift`, `SandboxCommand.swift`,
  `DistributedWorkerCommand.swift` (ch-01), or
  `StorageCompactCommand.swift` and `StorageDoctorCommand.swift` (ch-03).
- Do not edit `RielaCommand.swift` or the parse-level help returns.
  `CommandParsingTests` must keep passing unchanged.
- Do not change `renderParserFailure`, the `AutomaticRetentionHook`, or any
  ad-hoc `catch { throw CLIUsageError(Self.message(for:)) }` wrapper outside
  `RielaClientFamilyArguments.parseCLI`.
- Do not add help handling inside individual runners.

## File-level changes

1. **`RielaCLIApplication.runParsed`.** The very first statement, before the
   `arguments.first == "sandbox"` check, is a single
   `if let request = CLIHelpRequest.detect(arguments)` that returns
   `CLISubcommandHelp.result(for: request)`. Add nothing else at the top.
2. **Final `catch` of `runParsed`.** Keep the existing
   `catch let error as CLIUsageError` branch first and unchanged. In the
   generic final `catch`:
   - If `CLISubcommandHelp.isCleanExit(error)`, return
     `CLIHelpRequest.resolve(arguments).map(CLISubcommandHelp.result(for:))`,
     or `CLICommandResult(exitCode: .success, stdout: rielaCLIHelpText)` when
     `resolve` returns nil.
   - Otherwise keep today's `.failure` result.
   - Put this mapping in a small private helper, for example
     `private func unexpectedErrorResult(arguments:error:)`, so that
     `runParsed`'s cyclomatic complexity does not grow past the swiftlint
     warning (30).
3. **`RielaClientFamilyArguments.parseCLI`.** In the `catch`, if
   `CLISubcommandHelp.isCleanExit(error)`, rethrow the error unchanged.
   Otherwise throw `CLIUsageError(Self.message(for: error))` as today.
   - This file already imports ArgumentParser, so `error is CleanExit` would
     also work. Prefer `isCleanExit` for one source of truth.

## Invariants

- Exact help output, exit `.success`, empty stderr:
  - `riela --help`, `riela -h` and bare `riela` still give `rielaCLIHelpText`.
  - `package --help` still gives the package help.
  - `workflow run demo --help` still gives `workflowRunHelpText(target: "demo")`.
- Invocations without a help token before `--` behave exactly as before.
- Delegated runners (`gc`, `session prune`, `session reconcile`, `cache`,
  `environment`) and `gateway <name>` still get their arguments, because
  `detect` returns nil for them.
- No help path runs a command body: no store access, no invite, no listener.

## Pitfalls

- Do not place the detector after the `sandbox`/`auth`/`worker`
  pre-dispatch. `auth invite --help` must not reach `PasskeyCommand.run`.
- Do not move the `CleanExit` handling ahead of the `CLIUsageError` catch.
  Do not turn usage errors into success.
- Do not import ArgumentParser into the test file. RielaCLITests does not
  depend on it.
- Do not run `serve --help` or `events serve --help` through
  `RielaCLIApplication().run` in tests. A regression there would start a
  listener and hang the suite. ch-01's detector audit covers those paths.

## Tests (`Tests/RielaCLITests/SubcommandHelpApplicationTests.swift`, `@testable import RielaCLI`)

Run each case through `RielaCLIApplication().run(args)` and check exit
`.success`, empty stderr, and stdout not containing `helpRequested` or
`"error"`, plus the expected content:

- `["storage","compact","--help"]` and `["storage","compact","-h"]` → stdout
  contains `riela storage compact [--apply]`
- `["doctor","storage","--help"]` → contains `riela doctor storage`
- `["session","status","--help"]` → contains
  `riela session status|continue|step-runs|export|logs <session-id>`, and
  does not contain `requires a session id`
- `["session","resume","-h"]` → contains `riela session resume <session-id>`
- `["workflow","validate","--help"]` → contains
  `riela workflow validate <workflow>`, and does not contain
  `requires a workflow name`
- `["workflow","inspect","--help"]` and `["workflow","delete","--help"]` →
  contain their usage lines
- `["loop","start","--help"]` → contains `riela loop start <workflow>`
- `["storage","compact","--help","--output","json"]` → plain-text usage,
  exit 0 (D5)
- `["auth","invite","--help"]`, run with
  `environment: ["HOME": tmp, "RIELA_WEB_AUTH_ROOT": tmp/auth, "RIELA_WEB_ORIGIN": "https://riela.example"]`
  (imitate `Tests/RielaCLITests/PasskeyCommandTests.swift:10-13`):
  - stdout contains `Passkey`
  - a following `["auth","users"]` run in the same environment does not
    list `--help`
- Unchanged behavior, which must still hold:
  - `["--help"]` → stdout equals `rielaCLIHelpText`
  - `["workflow","run","demo","--help"]` → contains `Riela workflow run`
  - `["workflow","--help"]` → contains `workflow register` and
    `--exclude-mutable`
  - `["gc","--help"]`, `["session","prune","--help"]`,
    `["cache","put","--help"]` → exit `.success`
- Backstop through `parseCLI`:
  - `ParsedWorkflowRegisterArguments.parseCLI(["--help"])` throws an error
    for which `CLISubcommandHelp.isCleanExit` is true.
  - `ParsedWorkflowRegisterArguments.parseCLI(["--bogus"])` throws a
    `CLIUsageError`.
- Backstop through the final catch:
  - Add a test-local
    `struct HelpThrowingParser: CLIArgumentParsing` whose `parse` calls
    `_ = try ParsedWorkflowRegisterArguments.parseCLI(["--help"])`.
  - `RielaCLIApplication(parser: HelpThrowingParser()).run(["workflow","status"])`
    has no help token, so the detector does not intercept. Expect exit
    `.success` and stdout containing `riela workflow status <workflow>`.
  - `.run(["bogus"])` → exit `.success` and stdout equal to
    `rielaCLIHelpText` (resolve returns nil).

## Verification (logs under `tmp/issue-184/ch-02/`)

1. `mkdir -p tmp/issue-184/ch-02`
2. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/issue-184/ch-02/build.log 2>&1'`
   → exit 0.
3. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter "SubcommandHelpApplicationTests|SubcommandHelpTests|CommandParsingTests|WorkflowRunHelpTests|PasskeyCommandTests|WorkflowTemporaryRegistrationTests|GarbageCollectionCommandTests|CacheCommandTests|SessionReconcileCommandTests|RuntimeEnvironmentChannelTests" > tmp/issue-184/ch-02/test.log 2>&1'`
   → exit 0 and 0 failures.
4. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/RielaCLIApplication.swift Sources/RielaCLI/RielaClientFamilyArguments.swift Tests/RielaCLITests/SubcommandHelpApplicationTests.swift > tmp/issue-184/ch-02/swiftlint.log 2>&1'`
   → exit 0 and an empty log.
5. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && .build/debug/riela session status --help > tmp/issue-184/ch-02/manual-session-status.log 2>&1; echo "exit=$?" >> tmp/issue-184/ch-02/manual-session-status.log'`
   → the log shows the usage line and `exit=0`.
   Do the same for `workflow validate --help` (`manual-workflow-validate.log`).

## Concurrency hygiene

- ch-03 runs in the same wave and owns the storage files. Do not touch them.
- **Sibling-diagnostic rule.** `swift build` and `swift test --filter`
  always compile all of RielaCLI, so a build can fail because of a sibling
  plan's unfinished edit.
  - If `swift build` or `swift test` fails and every compiler diagnostic is
    in a file outside this plan's `writePaths`, do not edit that file. For
    example, `missing argument for parameter 'usagePath'` in
    `StorageCompactCommand.swift` or `StorageDoctorCommand.swift` belongs to
    ch-03.
  - Record the diagnostic, the file and its owner plan in the progress log,
    wait, then rerun the same command. Make at most 3 attempts in total.
  - If it still fails, record the gate as `blocked-by-sibling` with the log
    path. Do not record it as PASS or FAIL.
  - A diagnostic in an owned file is always this plan's responsibility.
- The authoritative module-wide gate is the manifest's
  `integrationVerification`: the full `swift test --filter RielaCLITests`
  run after the W2 join, during serial reconciliation.
- Re-read each owned file right before editing it, and record pre/post
  SHA-256 hashes in the progress log.
- Before you start and again at the end, record `shasum -a 256` of
  `Sources/RielaCLI/CLISubcommandHelp.swift`, and record any drift.
- No git write operations.

## Done criteria

- `grep -n "CLIHelpRequest.detect(arguments)" Sources/RielaCLI/RielaCLIApplication.swift`
  shows it inside `runParsed` before the `"sandbox"` check.
- `grep -n "isCleanExit" Sources/RielaCLI/RielaClientFamilyArguments.swift`
  shows one hit.
- All verification commands meet their expected results.
- `impl-plans/progress/ch-02-app-wiring.md` has:
  - the changes
  - the hashes
  - a verification table: command, exit status, tests run, failures, log
    path
