# chg-01-delegated-help-tests: end-to-end help coverage for delegated runners (#184 GC1)

```json
{
  "planId": "chg-01-delegated-help-tests",
  "planPath": "impl-plans/active/cli-subcommand-help-gap-01-delegated-help-tests.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "Tests/RielaCLITests/SubcommandHelpApplicationTests.swift",
    "impl-plans/progress/chg-01-delegated-help-tests.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Issue #184 requires every routed subcommand to print usage and exit 0 for
`--help`/`-h`. The first fix landed on `main` at `dd6c94c9`. Design
`design-docs/specs/design-cli-subcommand-help.md` §6.2 GC1 found one coverage
gap.

The detector `CLIHelpRequest.detect` (`Sources/RielaCLI/CLISubcommandHelp.swift`)
returns nil for the delegated runners, which keep their own help (D4). Those
runners are `gc`, `session prune`, `session reconcile`, `cache <op>` and
`environment <op>`.

§3 of the design requires each delegated path to exit 0 through
`RielaCLIApplication().run`. Today
`SubcommandHelpApplicationTests.testTopLevelAndDelegatedHelpStayUnchanged`
(`Tests/RielaCLITests/SubcommandHelpApplicationTests.swift:41-49`) checks only
`gc --help`, `session prune --help` and `cache put --help`, and it checks only
the exit code.

Each of these runners returns help before doing any work, so the new tests are
safe to run end to end:

- `EnvironmentCommand.swift:34`
- `SessionReconcileCommand.swift:35`
- `SessionPruneCommand.swift:19`
- `CacheCommands.swift:53`
- `GarbageCollectionCommand.swift:14`

## Non-goals

- Do not change anything under `Sources/`. This is a test-only plan.
- Do not edit `SubcommandHelpTests.swift`, `StorageHelpBackstopTests.swift`,
  `README.md`, the design doc, `VERSION` or `Package.swift`.
- Do not add a new test file or a new test class.
- Do not run `serve`, `auth invite` or any non-delegated path end to end. Those
  are covered by the detector-only audit (`SubcommandHelpTests.testSurfaceAudit`).
- Do not touch or fix `StorageCompactCommandTests`. Its two failures exist on
  `main` already.

## File-level changes

Edit only `Tests/RielaCLITests/SubcommandHelpApplicationTests.swift`, and only
the method `testTopLevelAndDelegatedHelpStayUnchanged()`.

1. Keep the existing top-level assertions (`["--help"]` stdout equals
   `rielaCLIHelpText`) unchanged.
2. Replace the delegated argument list with this exact list of 11 argument
   arrays:
   - `["gc", "--help"]`, `["gc", "-h"]`
   - `["session", "prune", "--help"]`, `["session", "prune", "-h"]`
   - `["session", "reconcile", "--help"]`, `["session", "reconcile", "-h"]`
   - `["cache", "put", "--help"]`, `["cache", "put", "-h"]`
   - `["environment", "status", "--help"]`, `["environment", "status", "-h"]`
   - `["environment", "reload", "--help"]`
3. For every case, assert:
   - `result.exitCode == .success`, with message `"\(arguments): \(result.stderr)"`;
   - `!result.stdout.isEmpty`;
   - `!result.stdout.contains("helpRequested")`;
   - `!result.stdout.hasPrefix("{\"error\"")`.
4. Keep the existing style: a `for arguments in [...]` loop with
   `await RielaCLIApplication().run(arguments)`. Imitate the assertion style of
   `testSubcommandHelpPrintsUsageBeforeArgumentValidation` in the same file.
   If the literal list makes the line too long for swiftlint, put one entry
   per line.

## Pitfalls

- The list has exactly 11 arrays: both flags for gc, session prune, session
  reconcile, cache put and environment status, plus
  `["environment", "reload", "--help"]`.
- Do not assert exact help text. The delegated runners use ArgumentParser
  `USAGE:` output, which is not part of this contract.
- Do not assert that stderr is empty for delegated runners. Only the exit code,
  non-empty stdout, and the absence of `helpRequested`/`{"error"` are
  contractual here.
- If any case fails, do NOT modify `Sources/` to make it pass. Record the
  failing arguments, the exit code, stdout and stderr in the progress log as a
  finding, keep the test case in place, and stop. Review and reconcile decide
  the fix.
- Do not wrap the test in `environment:` overrides. These paths return before
  touching any store.

## Test cases

- `riela gc -h` -> exit 0, non-empty stdout, no `helpRequested`
- `riela session reconcile --help` / `-h` -> exit 0, non-empty stdout
- `riela session prune -h` -> exit 0, non-empty stdout
- `riela cache put -h` -> exit 0, non-empty stdout
- `riela environment status --help` / `-h`, `riela environment reload --help`
  -> exit 0, non-empty stdout, and no reload or network work happens
- existing cases (`gc --help`, `session prune --help`, `cache put --help`,
  top-level `--help`) -> unchanged results

## Edit discipline

The working tree is shared with chg-02, which edits only `README.md`.

- Before the edit, read the target file fresh and record its SHA-256 (`shasum -a 256`).
- Write a one-line intent note to `tmp/issue-184-gap/chg-01/intent.txt`.
- After the edit, record the new SHA-256.
- If the before-hash no longer matches when you are about to write, re-read
  the file and reapply the edit. Never overwrite blindly.
- No git operations: no commit, stash, checkout or branch.

## Verification

Run from the repository root. Put all logs under `tmp/issue-184-gap/chg-01/`.

1. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/issue-184-gap/chg-01/build.log 2>&1; echo "exit=$?"'`
   -> `exit=0`.
2. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter "SubcommandHelp|StorageHelpBackstopTests|CommandParsingTests|WorkflowRunHelpTests|PasskeyCommandTests" > tmp/issue-184-gap/chg-01/test.log 2>&1; echo "exit=$?"'`
   -> `exit=0`. The log must show more than 0 tests executed, 0 failures, and
   that `testTopLevelAndDelegatedHelpStayUnchanged` passed.
3. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict Tests/RielaCLITests/SubcommandHelpApplicationTests.swift > tmp/issue-184-gap/chg-01/swiftlint.log 2>&1; echo "exit=$?"'`
   -> `exit=0`.
4. `git diff --stat` -> only `Tests/RielaCLITests/SubcommandHelpApplicationTests.swift`
   and this plan's progress log changed, plus `README.md` from chg-02.

## Done criteria

- `testTopLevelAndDelegatedHelpStayUnchanged` contains all 11 delegated
  argument arrays listed above, each with the 4 assertions.
- Verification 1-3 each exit 0, and the full log paths are recorded.
- `git diff --name-only -- Sources VERSION Package.swift` is empty.
- `impl-plans/progress/chg-01-delegated-help-tests.md` exists and records:
  - a summary;
  - a before/after SHA-256 table;
  - a table of gate, exit code, test count, failure count and log path;
  - any finding raised under "Pitfalls".
