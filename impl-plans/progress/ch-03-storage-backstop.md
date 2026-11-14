# #184 ch-03 storage backstop

The accepted ch-01 dependency supplies `CLISubcommandHelp`. The storage error mapper now accepts a usage path, maps parser success exits to existing plain-text help, and retains the previous mapping for other errors. Its two callers supply their respective paths. Direct runner tests cover both compact help flags, doctor help, parser help errors, and usage errors. Formal review and integration remain downstream.

## SHA-256

| Path | Before | After |
| --- | --- | --- |
| Sources/RielaCLI/StorageDoctorCommand.swift | ceedb315b8ca58fb9ac10d9783fd368d1771662a113ecbd622f5ff650a4dec8b | dbddeb9011343174161ae900c299dc5ab94b15bc6dd5a3abb549819a767c879e |
| Sources/RielaCLI/StorageCompactCommand.swift | d903f936e518b1653748f1d0795091853a7e97319983cdd6f2c06ed375142a2a | 608be3479b6413441d075f5ee79a6ea338edfe7d4a56bb8aceffa817bfb2f564 |
| Tests/RielaCLITests/StorageHelpBackstopTests.swift | absent | c3ac68f4fd329de75c87ab662d239d55f68ec815a43c58dc39043047f3c7f5ca |
| Sources/RielaCLI/CLISubcommandHelp.swift (dependency) | 865630a5f7560cb1938a31de0e914b2a81e679f5cb8c9f6e2de84642cbb1c41b | 865630a5f7560cb1938a31de0e914b2a81e679f5cb8c9f6e2de84642cbb1c41b |

## Verification

Logs and per-edit intentions are under `tmp/issue-184/ch-03-storage-backstop/`. Build and test used arm64 and Xcode's toolchain. Counts below are XCTest tests and assertion failures.

| Gate | Exit | Tests | Failures | Log |
| --- | ---: | ---: | ---: | --- |
| swift build | 0 | 0 | 0 | build.log |
| swift test --filter "StorageHelpBackstopTests\|StorageCompactCommandTests" | 1 | 21 | 4 | test.log |
| Same suites with --package-path from clean-cwd | 1 | 21 | 4 | test-clean-cwd.log |
| swift test --filter StorageHelpBackstopTests | 0 | 4 | 0 | test-backstop.log |
| swiftlint lint --strict via changed-swift.nul | 0 | 0 | 0 | swiftlint.log |
| rg StorageCommandFailure.result Sources | 0 | 0 | 0 | callers.log |
| manual storage compact --help and -h | 0 | 2 | 0 | manual-rerun.log and manual-*.stdout/stderr |

The combined suite has four assertion failures in two existing tests at `StorageCompactCommandTests.swift:25-28,378`: the first report store is session instead of memory. The checkout contains existing `.riela` stores; this is a plausible environmental cause, not a verified baseline disposition. SwiftPM's clean-cwd retry gave identical failures. The required suite remains unresolved; do not mark it passing. No sibling compiler diagnostic was observed. The first manual script attempt failed due to zsh's read-only `status` variable; the corrected rerun passed. Review and serial integration verification are pending.
