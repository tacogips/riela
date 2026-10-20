# ar-01-core-config implementation progress

Issue: `workflowInput:automatic-config-driven-retention` (no GitHub issue URL or number).
Workflow mode: `issue-resolution`. Implementation agent: Codex `/root` (Step 6).
Branch: `feat/automatic-retention`.

## Changes

- Added strict retention config loading, category/policy state, target selection, removed-key handling, environment precedence and human byte-size parsing in `Sources/RielaCore/RielaRetentionConfiguration.swift`.
- Added shared per-category report DTOs and inactive factory in `Sources/RielaCore/RielaRetentionReport.swift`.
- Added 21 focused configuration/report behavioral test methods in `Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift`.
- Preserved `Sources/RielaCore/RielaDataGarbageCollector.swift`; its SHA-256 remains `197cbdcb2d3a5915380f4abd7115fc8089ca5f010636c81115a5c2688d650cbb`.

## Verification

| Command | exitStatus | testsRun | failureCount | Outcome | Evidence |
|---|---:|---:|---:|---|---|
| `arch -arm64 /bin/zsh -lc 'swift test --scratch-path tmp/automatic-retention/ar-01-core-config/scratch --skip-update --disable-sandbox --filter RielaRetentionConfigurationTests > tmp/automatic-retention/ar-01-core-config/test-verified.log 2>&1'` | 0 | 21 | 0 | Final declaration source compiled and suite completed with 21 tests and zero failures. | `tmp/automatic-retention/ar-01-core-config/test-verified.log`; matching hashes in `source-identity-verified-before.sha256` and `source-identity-verified-after.sha256` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/automatic-retention/ar-01-core-config/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-01-core-config/changed-swift-files.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | 0 | 0 | Strict changed-file SwiftLint passed; empty diagnostic log. | `tmp/automatic-retention/ar-01-core-config/swiftlint-verified.log` |
| `git diff --quiet -- Sources/RielaCore/RielaDataGarbageCollector.swift` | 0 | 0 | 0 | Protected garbage collector source is unchanged. | `tmp/automatic-retention/ar-01-core-config/collector-unchanged.txt` |
| `grep -n 'public static func load(homeDirectory: URL, projectDirectory: URL?' Sources/RielaCore/RielaRetentionConfiguration.swift && grep -n 'struct RetentionCategoryReport' Sources/RielaCore/RielaRetentionReport.swift` | 0 | 0 | 0 | Both pinned contract declarations matched. | Command output: config line 81 and report line 23. |

Prior failed attempt retained for audit:

| Command | exitStatus | testsRun | failureCount | Outcome | Evidence |
|---|---:|---:|---:|---|---|
| `arch -arm64 /bin/zsh -lc 'swift test --scratch-path tmp/automatic-retention/ar-01-core-config/scratch --skip-update --disable-sandbox --filter RielaRetentionConfigurationTests > tmp/automatic-retention/ar-01-core-config/test.log 2>&1'` | 1 | 0 | 0 | Build aborted because another worker modified `Tests/RielaCLITests/SessionMessageRetentionAdmissionTests.swift` during compilation. The successful rerun above resolved this transient mutation failure. | `tmp/automatic-retention/ar-01-core-config/test.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/automatic-retention/ar-01-core-config/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-01-core-config/changed-swift-files.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 1 | 0 | 0 | First signature-only formatting attempt violated vertical parameter alignment; corrected and verified above. | `tmp/automatic-retention/ar-01-core-config/swiftlint-final.log` |

The first shared `.build` invocation waited behind concurrent fanout builds and was interrupted before compilation (exit 130); its incomplete wait output is retained at `tmp/automatic-retention/ar-01-core-config/shared-build-wait.log`. It is not verification evidence.

## Completion criteria

- [x] Public configuration API, strict validation, removed-key errors and precedence implemented.
- [x] Human byte-size parser supports decimal/binary units and rejects decimals/invalid ranges.
- [x] Shared report DTOs expose public initializers and inactive report factory.
- [x] 21 behavioral test methods added with temporary roots under repository `tmp/`.
- [x] `RielaDataGarbageCollector.swift` unchanged.
- [x] Strict selected-file SwiftLint passed.
- [x] Focused arm64 `RielaRetentionConfigurationTests` run completes with 21 tests and zero failures on the final source identity.
