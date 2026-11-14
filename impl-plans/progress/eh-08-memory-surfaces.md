# eh-08-memory-surfaces progress

## Assignment and status

- Plan: `impl-plans/active/efficient-history-08-memory-surfaces.md`.
- Branch: `feat/efficient-history`; no commit, push, rebase, or reset performed.
- Dependency: eh-03 memory history API is present and was used as pinned.
- Implementation status: eh-08 implementation and the independent review repairs are complete. The focused root test command compiles the changed targets and passes; no commit or push was performed.

## Changes

- `Sources/RielaCLI/MemoryCommandModels.swift`: added `undo` and `redo` commands, `diffAgainst`, and `historyRetention` options.
- `Sources/RielaCLI/ParsedMemoryOptions.swift`: parses `--diff-against` and `--history-retention`; rejects malformed diff references and retention outside 1...1000.
- `Sources/RielaCLI/MemoryCommands.swift`: routes head moves, emits the `{record, revision, headVersion, fromVersion}` result, emits `{record, diff}` using the definition diff value shape (including optional bytes fallback fields), passes retention through save/update/restore, and formats versioned-history error codes and retained-version details in the existing memory error envelope.
- `Sources/RielaCore/WorkflowModel.swift`: added optional `WorkflowMemoryDeclaration.historyRetention`; synthesized Codable continues to decode missing values and omit nil values.
- `Sources/RielaCore/WorkflowMemoryValidation.swift`: allows the declaration key and validates 1...1000 for typed and raw authored workflows, naming the memory id in range diagnostics.
- `Sources/RielaCore/DeterministicWorkflowRunner+Memory.swift`: serializes the declaration field, merges it when deduplicating declarations, and passes it to runner memory saves.
- `Sources/RielaCLI/ProductionNodeAdapter+MemoryAddonCore.swift` and `ProductionNodeAdapter+PersonaMemory.swift`: pass the retention declared for the target memory id to store save/update calls; snapshot-store writes remain unchanged at R=1.
- Tests added: `MemoryHistoryCommandTests.swift` covers default retention, structured history, dropped versions, undo/redo boundaries, stale revision, parsed retention, and diff JSON keys. `WorkflowMemoryHistoryRetentionValidationTests.swift` covers valid and invalid declarations, raw unknown-key rejection, Codable compatibility without the new key, and five successive workflow-style writes at retention 3.
- Existing test updates: `MemoryEvolutionCommandTests.swift` now checks new-format history metadata instead of legacy reverse deltas. `MemoryHistoryRetirementCommandTests.swift` expects the new `version_not_retained` code after retirement. These assertions changed because converted memory history now uses VersionedHistory rows and its over-window error.

## Out-of-scope edits

- `Sources/RielaCore/WorkflowAddonExecution.swift`: added optional `memoryHistoryRetentions` to carry declarations to built-in memory add-ons without injecting internal data into user-visible variables. The add-on execution input had no path for workflow declarations, and the assigned production adapter files cannot resolve declaration values otherwise. The property is optional and omitted when absent, preserving old Codable output.
- `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`: supplies the declaration map to the add-on input from workflow/node memory declarations. Required to propagate declarations to the production add-on writes above.
- `Sources/RielaCLI/RielaCommand.swift`: added `.undo` and `.redo` to the existing no-extra-validation switch so the new enum cases compile and continue through the common memory parser. This exhaustive switch is outside the assigned write paths.

No other out-of-scope files were edited. `SnapshotStoreAddonTests.swift` and `PersonaMemoryAddonTests.swift` needed no test setup changes; both suites pass with snapshot retention unchanged.

## Edit hashes

Task-start hashes were taken before edits; assigned paths were clean at task start. New tests were absent. Out-of-scope source paths were clean at task start and their baseline hashes are from `HEAD`.
The `After` values below capture the original eh-08 implementation before these review repairs; the final repair paths and verification are recorded in the following section.

| Path | Before | After |
|---|---|---|
| `Sources/RielaCLI/MemoryCommands.swift` | `0cd03b4985b2398efbd4e943a3311150827cc832a427dd222bb7f960b54ae890` | `9684cab6aefa3bbc75374622b04161161a4dbae54ed709aec094f03b1bfe322a` |
| `Sources/RielaCLI/MemoryCommandModels.swift` | `cc3dff9999bc45758e8bc116c7100b909b69aa28126d67d5fec38040a3b6fe00` | `88a7e94851cdd8a87fdbcecc77d812bad61d5e815138c85497235a5fe4446140` |
| `Sources/RielaCLI/ParsedMemoryOptions.swift` | `fe16a36fdd528b18473791367db0474be06c15af7d71c7770d40d20fe0691118` | `84b48d9f9f88f0be5f89944da036d17d375b4c8809ef0481ecaa8b0b6883c9b1` |
| `Sources/RielaCore/WorkflowModel.swift` | `ed68bcca4110bb15d2fb8054a898f4ec67e87020758408f4178d36ed4d2a384a` | `a5ae872a52ab61ed4907ff989e94daec99217b95655d09eaef06cfad20632373` |
| `Sources/RielaCore/WorkflowMemoryValidation.swift` | `9d964f29a4d562db8494952b371b59e70437b38c0861b222e372b6c91f98f131` | `0e5fd18ef5ce8e07a50690cc546df56895b46ea10d6f61ab9792f4896fad69cf` |
| `Sources/RielaCore/DeterministicWorkflowRunner+Memory.swift` | `d974a8edecd681961b01722e558c111c8d36d1736a6c1f1823beea9d094f64fe` | `b348e2351a80ea3872ebbaca4a56df6793be58da7b193cf39b81c6e5edfd3917` |
| `Sources/RielaCLI/ProductionNodeAdapter+MemoryAddonCore.swift` | `f0151f71f0ab5644e66948c0396b9eb583320309193dea148e8d6472799ba686` | `5c29cc98ed299c6545dc2939f38755bed607f190d5da7ea6c4d94d8cdb3e630a` |
| `Sources/RielaCLI/ProductionNodeAdapter+PersonaMemory.swift` | `5e3329d64af654cf882000a239a11c40fcb2688bf9d64b2aed3332dc8bc76183` | `57614b8d5dbce8f4a9377d9d8cdd54058100ae5fb54fa3f317b374484c689079` |
| `Tests/RielaCLITests/MemoryEvolutionCommandTests.swift` | `a16c3ebaf905b964c8189f9e396a43ef27cec3df3f0888e713971ba9fe0c566b` | `c47b0f3f68926c7b83c57dc961f926802648bcc04445821b9eb6ddf6c6a5fa10` |
| `Tests/RielaCLITests/MemoryHistoryRetirementCommandTests.swift` | `af582d045e67f2b89419088cfb6302443afe44303eb755c1e7a1aa6e65db9b98` | `66316a440a0ef77ebc98159281cf10a6f35b1dd65ca8b544767b99f1e6b6b317` |
| `Tests/RielaCLITests/MemoryHistoryCommandTests.swift` (new) | absent | `1a0ef129a31678d215214bd35d09be47ed799a214dc9e33d3b43f55b58aa9053` |
| `Tests/RielaCoreTests/WorkflowMemoryHistoryRetentionValidationTests.swift` (new) | absent | `63e98fe89cb06b1d581338b2d8ac8293c798c1a79b81e3758e3b8429489aa4ce` |
| `Sources/RielaCore/WorkflowAddonExecution.swift` (out of scope) | `c7a2215355cd9947e39ed3ec0d9faf3035e635f4c31a4f026ab12f60e993f5ce` | `6894272c88ea5de46e520447e30c608a3ebc1fce9e96354fa5dccb29965d9051` |
| `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift` (out of scope) | `6b3956fde889a766eb919e1eec693467c72ec2308be2216d08babe9db1183ef2` | `32d8c9734da0345cb8fc03aac6f10334af73a16ee839a0850262f17b35c71ceb` |
| `Sources/RielaCLI/RielaCommand.swift` (out of scope) | `cd9f268da55358e12d88c14e3ac909a9dc6a97711cdb952df6bfe6892ac39525` | `f04a189e7f86305dc3b2f5f73815ba6bc4d338402c26ad2561d405c539ff5fb7` |

## Verification

All listed commands ran under the required arm64 zsh wrapper. Logs are under `tmp/efficient-history/eh-08-memory-surfaces/`.

| Command | Exit | Result / log |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "MemoryHistoryCommandTests|MemoryEvolutionCommandTests|MemoryHistoryRetirementCommandTests|SnapshotStoreAddonTests|PersonaMemoryAddonTests|MemoryAddonFileTests|WorkflowMemoryHistoryRetentionValidationTests|DeterministicWorkflowRunnerMemoryTests|MemoryPayload"'` | 0 | Initial run: 39 tests, 0 failures; `test.log`. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/MemoryCommands.swift Sources/RielaCLI/MemoryCommandModels.swift Sources/RielaCLI/ParsedMemoryOptions.swift Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/WorkflowMemoryValidation.swift Sources/RielaCore/DeterministicWorkflowRunner+Memory.swift Sources/RielaCLI/ProductionNodeAdapter+MemoryAddonCore.swift Sources/RielaCLI/ProductionNodeAdapter+PersonaMemory.swift Tests/RielaCLITests/MemoryHistoryCommandTests.swift Tests/RielaCLITests/MemoryEvolutionCommandTests.swift Tests/RielaCLITests/MemoryHistoryRetirementCommandTests.swift Tests/RielaCLITests/SnapshotStoreAddonTests.swift Tests/RielaCLITests/PersonaMemoryAddonTests.swift Tests/RielaCoreTests/WorkflowMemoryHistoryRetentionValidationTests.swift'` | 0 | Strict lint passed; `swiftlint.log`. |
| `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Sources/RielaCore/WorkflowAddonExecution.swift Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift Sources/RielaCLI/RielaCommand.swift'` | 0 | Strict lint passed for out-of-scope compile/propagation edits; `swiftlint-out-of-scope.log`. |
| `arch -arm64 /bin/zsh -lc 'swift build'` | 1 | This earlier run reported an eh-04 compile diagnostic; the independent reviewer subsequently confirmed the error no longer reproduces. The later focused test build compiled and passed. |
| `git diff --check` | 0 | Clean. |

Earlier superseded attempts: the first focused run found an invalid guard body; the next compile found missing `defaults`/`nodes` in the new fixture; the next behavioral run found an incorrect validation test path and expected legacy assertions. These were fixed. The final focused command above is the passing current eh-08 evidence.

## Review repairs (2026-10-27)

- **Finding 1 (High):** Added `effectiveMemoryDeclarations`, which keeps node declarations first and fills missing fields from workflow declarations. The add-on retention map and runner automatic saves use this merge, while the automatic save record list stays scoped to node memories. The runner regression runs five save/update writes with workflow-only and node-level retention declarations; it also updates an automatic runner record to confirm its persisted retention. Adapter and persona tests verify their real write paths persist R=3.
- **Finding 2 (Medium):** Replaced the direct-store “workflow mock” test with a `DeterministicWorkflowRunner` mock run. Added a production add-on adapter test using `WorkflowAddonExecutionInput(memoryHistoryRetentions: ["chat-memory": 3])` and checked the resulting retained versions.
- **Finding 3 (Medium):** `moveMemoryHead` now imports old-format evolution rows on first undo/redo touch inside the transaction before moving the head. Added an old-format seeded undo conversion regression in `Packages/RielaMemory/Tests/RielaMemoryTests/MemoryHistoryRetirementTests.swift`.
- **Finding 4 (Low):** Normalized stale restore errors to `stale_revision`; legacy retired/invalid version reads now return `version_not_retained` with the retained versions. Added stale `restore-version --expected-head-version` CLI coverage.
- **Finding 5 (Low):** Text history now shows the head revision, storage encoding and byte count, plus a retention-drop line when the oldest retained version exceeds 1. Added text output assertions.
- **Finding 6 (Low):** Removed the undocumented `addon.config.historyRetention` fallback. Parser validation rejects `--diff-against` outside `show-version` and `--history-retention` outside `save`, `update`, and `restore-version`.
- **Finding 7 (Low):** Added update/undo/update/redo branch-discard coverage (`nothing_to_redo`), numeric `--diff-against` coverage, literal replace-entry key-set assertions, and separate add/remove assertions that omit `before` and `after`.
- **Design note (L4):** Documented the new history text output behavior in `design-docs/specs/design-efficient-history-and-storage.md`.
- The only repair paths outside the plan's `writePaths` are the explicitly reviewed `Packages/RielaMemory/Sources/RielaMemory/MemoryEvolutionHistory.swift`, its regression test `Packages/RielaMemory/Tests/RielaMemoryTests/MemoryHistoryRetirementTests.swift`, and the design document named for the L4 documentation request. No unrelated CLI files were edited.

### Changed existing assertions and preservation

- `MemoryEvolutionCommandTests` replaced its legacy `reverseDelta == next-to-previous` check with assertions that new-format history omits `reverseDelta` and exposes `isHead` and storage metadata. The new assertions check the versioned-history contract more directly.
- `MemoryHistoryRetirementCommandTests` now expects `version_not_retained` after a new-format retirement. The test still checks non-zero status, absence of the retired body, and preservation of the head record.
- No pre-existing test was weakened or removed. The direct store test in the newly added `WorkflowMemoryHistoryRetentionValidationTests` file was replaced by runner-driven coverage; that file was new in the eh-08 implementation, not a pre-existing test.

### Repair verification

| Command | Exit | Result / log |
|---|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "MemoryHistoryCommandTests|MemoryEvolutionCommandTests|MemoryHistoryRetirementCommandTests|SnapshotStoreAddonTests|PersonaMemoryAddonTests|MemoryAddonFileTests|WorkflowMemoryHistoryRetentionValidationTests|DeterministicWorkflowRunnerMemoryTests|MemoryPayload"'` | 0 | Final: 42 tests, 0 failures; all matching suites executed; `repair-test-final-pass-3.log`. |
| `cd Packages/RielaMemory && arch -arm64 /bin/zsh -lc 'swift test --filter MemoryHistoryRetirementTests.testUndoConvertsLegacyHistoryOnFirstTouch'` | 0 | 1 test, 0 failures; `legacy-history-test.log`. |
| `arch -arm64 /bin/zsh -lc 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/MemoryCommands.swift Sources/RielaCLI/ParsedMemoryOptions.swift Sources/RielaCLI/RielaCommand.swift Sources/RielaCLI/ProductionNodeAdapter+MemoryAddonCore.swift Sources/RielaCLI/ProductionNodeAdapter+PersonaMemory.swift Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift Sources/RielaCore/DeterministicWorkflowRunner+Memory.swift Tests/RielaCLITests/MemoryHistoryCommandTests.swift Tests/RielaCLITests/MemoryEvolutionCommandTests.swift Tests/RielaCLITests/MemoryHistoryRetirementCommandTests.swift Tests/RielaCLITests/MemoryAddonFileTests.swift Tests/RielaCLITests/PersonaMemoryAddonTests.swift Tests/RielaCoreTests/WorkflowMemoryHistoryRetentionValidationTests.swift Packages/RielaMemory/Sources/RielaMemory/MemoryEvolutionHistory.swift Packages/RielaMemory/Tests/RielaMemoryTests/MemoryHistoryRetirementTests.swift'` | 0 | Strict lint passed; `swiftlint-repair-final.log`. |
| `git diff --check` | 0 | Clean. |

Two intermediate focused-build retries were blocked by concurrently edited, unrelated runtime persistence files (one also reported “input file modified during the build”). After those edits settled, the final focused run completed without build errors. One interim diff-shape assertion was corrected to match the shared schema (`add` has `after` only; `remove` has `before` only); the final run passes. Full `swift build` was not rerun because the requested focused verification compiled the changed targets and the reviewer independently confirmed the earlier compile error had cleared.

## Done criteria

- [x] Memory undo/redo and `show-version --diff-against` implemented and covered.
- [x] `--history-retention` parsed and declaration range/unknown-key validation covered.
- [x] Declared retention is passed to runner and built-in memory add-on writes; snapshot-store retention remains unchanged.
- [x] All plan-listed suites in the focused filter execute; 42 tests pass after review repairs.
- [x] Existing test changes are explained above; out-of-scope edits are itemized above.
- [x] Independent review findings are repaired and covered by regressions.
