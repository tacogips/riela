# ch-03-storage-backstop: StorageCommandFailure never reports CleanExit as error JSON (#184)

```json
{
  "planId": "ch-03-storage-backstop",
  "planPath": "impl-plans/active/cli-subcommand-help-03-storage-backstop.md",
  "dependsOn": ["ch-01-help-core"],
  "wave": "W2",
  "writePaths": [
    "Sources/RielaCLI/StorageDoctorCommand.swift",
    "Sources/RielaCLI/StorageCompactCommand.swift",
    "Tests/RielaCLITests/StorageHelpBackstopTests.swift",
    "impl-plans/progress/ch-03-storage-backstop.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

This is the direct root cause of #184. In
`StorageCompactCommandRunner.run` (`Sources/RielaCLI/StorageCompactCommand.swift:73`),
`ParsedStorageCommandArguments.parse(tokens)` throws ArgumentParser
`CleanExit.helpRequested` for `--help`/`-h`. The catch at line 96 calls
`StorageCommandFailure.result(error)` (`Sources/RielaCLI/StorageDoctorCommand.swift:357-363`),
which JSON-encodes `String(describing: error)` with exit `.failure`.
`StorageDoctorCommandRunner.run` (line 86) has the same path.

Design §2.4 (`design-docs/specs/design-cli-subcommand-help.md`) adds
`StorageCommandFailure.result(_:usagePath:)`, which returns the help text
for the given path with exit 0 when the error is a `CleanExit`. ch-02's
detector already intercepts these paths in the full CLI. This backstop
covers direct runner calls and any remaining CleanExit.

ch-01 provides `CLISubcommandHelp.result(path:)` and
`CLISubcommandHelp.isCleanExit(_:)` in `Sources/RielaCLI/CLISubcommandHelp.swift`.
Read that file and use those names exactly.

## Non-goals

- Do not edit `CLISubcommandHelp.swift`, `RielaCLIApplication.swift` or
  `RielaClientFamilyArguments.swift`.
- Do not change storage compact or doctor behavior, output, exit codes or
  validation for any non-help input.
- Do not add new usage text.
- Do not import ArgumentParser into the test.

## File-level changes

1. **`StorageDoctorCommand.swift`.** Change
   `enum StorageCommandFailure { static func result(_ error: Error) -> CLICommandResult }`
   to:

   ```swift
   static func result(_ error: any Error, usagePath: [String]) -> CLICommandResult
   ```

   - The first statement: if `CLISubcommandHelp.isCleanExit(error)`, return
     `CLISubcommandHelp.result(path: usagePath)`.
   - The rest of the body stays as it is today.
   - The call at line 86 passes `usagePath: ["doctor", "storage"]`.
2. **`StorageCompactCommand.swift:96`.** Pass
   `usagePath: ["storage", "compact"]`. Change nothing else in the file.
3. Keep the one-parameter `result(_:)` out of the code. These two are its
   only callers; `grep -rn "StorageCommandFailure.result" Sources` must show
   exactly those 2 call sites. No compatibility overload.

## Pitfalls

- **Edit ordering.** Make these three edits as one uninterrupted sequence,
  and do not run any build, test or lint in between:
  1. the `StorageCommandFailure.result(_:usagePath:)` signature change
     (`StorageDoctorCommand.swift:357`)
  2. the call site at `StorageDoctorCommand.swift:86`
  3. the call site at `StorageCompactCommand.swift:96`

  Between them RielaCLI does not compile, and that would break ch-02's
  concurrent gates. Re-read both files immediately before this sequence.
- Do not special-case `--help` by scanning tokens in the runner. The fix is
  the error mapping (single mechanism, D1/D6).
- `CLIUsageError` must still map to `.usage` with `{"error": …}` JSON. Other
  errors must still map to `.failure`.
- `StorageCompactCommandRunner.run(["--help"])` takes the
  `arguments.first != "compact"` branch and throws
  `CLIUsageError("unknown storage command '--help'")` before parsing. That
  is unchanged and is not a help request at this level. The CLI-level
  detector handles `storage --help`.
- Do not assert on exact whitespace beyond what is listed below.

## Tests (`Tests/RielaCLITests/StorageHelpBackstopTests.swift`, `@testable import RielaCLI`)

These call the runners directly, so they bypass the detector:

- `StorageCompactCommandRunner().run(["compact","--help"])`:
  - exit `.success`, empty stderr
  - stdout contains
    `riela storage compact [--apply] [--max-batch <n>] [--abandoned-after-hours <h>] [--allow-live-vacuum] [--output text|json]`
  - stdout contains neither `helpRequested` nor `"error"`
- `StorageCompactCommandRunner().run(["compact","-h"])` → the same.
- `StorageDoctorCommandRunner().run(["--help"])` → exit `.success`, stdout
  contains `riela doctor storage`, no `helpRequested`.
- Regression guards:
  - `StorageCompactCommandRunner().run(["compact","--top","3"])` → exit
    `.usage`, stdout starts with `{"error"`.
  - `StorageCompactCommandRunner().run(["compact","--output","yaml"])` →
    exit `.usage`.
  - `StorageCommandFailure.result(CLIUsageError("x"), usagePath: ["storage","compact"])`
    → exit `.usage`, stdout `{"error":"x"}\n`.

## Verification (logs under `tmp/issue-184/ch-03/`)

1. `mkdir -p tmp/issue-184/ch-03`
2. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/issue-184/ch-03/build.log 2>&1'`
   → exit 0.
3. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter "StorageHelpBackstopTests|StorageCompactCommandTests" > tmp/issue-184/ch-03/test.log 2>&1'`
   → exit 0 and 0 failures.
4. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/StorageDoctorCommand.swift Sources/RielaCLI/StorageCompactCommand.swift Tests/RielaCLITests/StorageHelpBackstopTests.swift > tmp/issue-184/ch-03/swiftlint.log 2>&1'`
   → exit 0 and an empty log.
5. `grep -rn "StorageCommandFailure.result" Sources > tmp/issue-184/ch-03/callers.log`
   → exactly 2 lines, both with `usagePath:`.
6. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && for f in --help -h; do .build/debug/riela storage compact $f; echo "exit=$?"; done > tmp/issue-184/ch-03/manual-storage-compact.log 2>&1'`
   → usage text and `exit=0` twice. This uses the full CLI path, so it
   needs ch-02. If ch-02 has not landed yet, rerun this step after the wave
   joins and record that in the progress log.

## Concurrency hygiene

- ch-02 runs in the same wave. Do not touch its files.
- **Sibling-diagnostic rule.** `swift build` and `swift test --filter`
  always compile all of RielaCLI.
  - If `swift build` or `swift test` fails and every compiler diagnostic is
    in a file outside this plan's `writePaths`, do not edit that file. For
    example, a diagnostic in `RielaCLIApplication.swift` or
    `RielaClientFamilyArguments.swift` belongs to ch-02.
  - Record the diagnostic, the file and its owner plan in the progress log,
    wait, then rerun the same command. Make at most 3 attempts in total.
  - If it still fails, record the gate as `blocked-by-sibling` with the log
    path. Do not record it as PASS or FAIL.
  - A diagnostic in an owned file is always this plan's responsibility.
- The authoritative module-wide gate is the manifest's
  `integrationVerification`: the full `swift test --filter RielaCLITests`
  run after the W2 join, during serial reconciliation.
- Re-read each owned file right before editing it, and record pre/post
  SHA-256 hashes in the progress log. Record the hash of
  `Sources/RielaCLI/CLISubcommandHelp.swift` at the start and at the end.
- No git write operations.

## Done criteria

- The signature is `result(_:usagePath:)`, and there are exactly 2 callers.
- All tests and lint pass as listed above.
- `impl-plans/progress/ch-03-storage-backstop.md` has:
  - the changes
  - the hashes
  - a verification table: command, exit status, tests run, failures, log
    path
