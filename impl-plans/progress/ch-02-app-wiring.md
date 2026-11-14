# ch-02-app-wiring progress (#184)

Implemented by the orchestrating session after opus-terra session 542 ended
blocked-only (wave 2: empty `implementation.artifactRoots` contract stopped
`swift build` writes to `.build`; not a code defect).

## Changes

- `RielaCLIApplication.runParsed`: `CLIHelpRequest.detect(arguments)` runs first, before the sandbox/auth/worker pre-dispatch.
- Final generic `catch` delegates to `unexpectedErrorResult(arguments:error:)`, which maps `CleanExit` to the resolved subcommand usage (or `rielaCLIHelpText`).
- `RielaClientFamilyArguments.parseCLI` rethrows `CleanExit` instead of wrapping it in `CLIUsageError`.
- `Tests/RielaCLITests/SubcommandHelpApplicationTests.swift`: end-to-end help cases, delegated help, auth invite no-op, parseCLI and final-catch backstops.

## Verification

| Command | Exit | Tests | Failures | Log |
| --- | --- | --- | --- | --- |
| swift build | 0 | - | - | tmp/issue-184/ch-02/build.log |
| swift test --filter (help + parsing + delegated suites) | 0 | 123 | 0 | tmp/issue-184/ch-02/test.log |
| swift test --filter RielaCLITests | 1 | 2286 | 4 (2 tests, pre-existing on main) | tmp/issue-184/full-cli.log |
| swiftlint --strict (changed files) | 0 | - | - | - |
| .build/debug/riela storage compact --help / -h, session status --help, workflow validate --help | 0 | - | - | manual |

The 4 failing assertions are in `StorageCompactCommandTests`
(testDryRunReportsLegacyMemoryWorkAndLeavesFileUnchanged,
testApplySweepsOrphanMemoryHistoryAndReportsCount) and fail identically on
main 6f4b963e without these changes (tmp/issue-184/baseline-compact.log).
