# ch-01-help-core progress (#184)

Implementation complete for the detector/renderer seam. Application dispatch and storage backstops remain assigned to ch-02 and ch-03; formal reviews and finalization are downstream.

Changed symbols: `CLIHelpRequest.detect`, `resolve`; `CLISubcommandHelp.result(for:)`, `result(path:)`, `isCleanExit`; `SandboxCommand.helpText`; `DistributedWorkerCommand.helpText`; `SubcommandHelpTests`. The surface audit covered 175 paths with both flags. No assertion was skipped. Review finding `ch01-isCleanExit-misses-parsererror` is addressed: real storage parse errors for `--help`, `-h`, and `-help` are recognized via the public ArgumentParser exit-code API; unknown-option and `CLIUsageError` cases remain failures, while a direct `CleanExit` remains recognized.

SHA-256 (pre → post; absent indicates new file):

| Path | Pre | Post |
| --- | --- | --- |
| Sources/RielaCLI/CLISubcommandHelp.swift | absent | 865630a5f7560cb1938a31de0e914b2a81e679f5cb8c9f6e2de84642cbb1c41b |
| Sources/RielaCLI/SandboxCommand.swift | e72760b5274704796c4a65c9c75dd794152a961f5cf19a1653cd6220c6135493 | f58f3a281c010cc256e4f24d8617676260e24468fdcfa2aa0679520bf5fdbbd7 |
| Sources/RielaCLI/DistributedWorkerCommand.swift | 5875b3e1d37589954061cbff8be0de2cd49c920d8b7e06cd4a2f790fa0d9c9b4 | 002da562a6c64250e978d9a0070eefd0807df630d54e493669f94dfdbc62535e |
| Tests/RielaCLITests/SubcommandHelpTests.swift | absent | 12d78ff74f9e172a0cd8f1c9ccc3416f2d5212fad4bc7f83b8f23b2dce2d6a2c |
| impl-plans/progress/ch-01-help-core.md | absent | recorded externally in `revision-progress-sha256.txt` to avoid a self-referential digest |

Verification on the shared working tree, arm64 with Xcode toolchain environment. Logs and per-edit intentions are under `tmp/issue-184/ch-01-help-core/` (the dispatched verification-record contract requires the full plan ID directory).

| Command | Exit | Tests | Failures | Log |
| --- | --- | --- | --- | --- |
| `swift build` | 0 | 0 | 0 | revision-xcode-build.log |
| `swift test --filter SubcommandHelpTests` | 0 | 5 | 0 | revision-xcode-test.log |
| `swift test --filter "WorkflowRunHelpTests|PasskeyCommandTests|GatewayCommandTests|SandboxContainerShareValidationTests"` | 0 | 25 | 0 | revision-xcode-neighbors.log |
| `xargs -0 swiftlint lint --strict --quiet --no-cache < revision-changed-swift.nul` | 0 | 0 | 0 | revision-xcode-swiftlint.log |

Earlier `test.log` had two failures: unenumerated session prune delegation and the incorrect CleanExit assumption. Both were corrected and rerun. Earlier `swiftlint.log` found a large tuple; the test was rewritten and strict lint rerun successfully. Scope diff for ch-02/ch-03 files was clean at self-check. No commits or shared documentation updates were made.

Review reproduction: `revision-reproduction.log` recorded three help-request assertion failures before the fix; current-source `revision-test.log` passes all five tests. The exact requested commands also wrote logs under `tmp/issue-184/ch-01/`; copies under the plan-ID directory preserve the same completed evidence. The separate selected-file lint gate uses the NUL manifest. Independent review and integration after the join remain pending.
