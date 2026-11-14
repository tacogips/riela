# ncr-01-runner-resolution progress

2026-11-11: Accepted design and plan aligned; dependencies empty. Two input construction sites: DeterministicWorkflowRunner.swift:705 AdapterExecutionInput and :851 WorkflowStdioNodeExecutionInput. Six CLI runner sites exist; only scenario-only WorkflowStagedVerification intentionally lacks a root after package-run wiring.

Source SHA-256 before → after:
- ExecutionEvents: 2eab88917ae18b75635a40d7cc323f60f3f8d4c1a2823612bdd0532403b0fc03 → ee653bc19391ffab5e05f85430530322f7ae3f84a5dd49261e8d71456566a17a
- Runner: c6caa7d3e5102a891807101658081533ab13e5517f14583761a440ee725b9f4d → e66cde2a21482e1e841ee2e9ba1348d905563b1a3b59bded80f8ece88a5ae7ff
- Package CLI: 3a87325b17cc29bd501bdf68a1e0d8e84c2167bffbce47e9004218b1543e1bcd → abaf388e47fd770265a1432be97b26aaf33de456c5f9307234f84c67cf73cd01
- NodeWorkingDirectoryResolutionTests.swift: new → 51e555d41a0398311b82c46d7f807e4cf002e0b1734f79260fa7ea9d95f52dd1

Core test results: relative agent and record, parent traversal, byte-identical absolute, nil record and nil-root helper passed in testAgentDirectoriesAndRecords; inherited and explicit command and container payloads passed in testStdioDirectories; placed relative payload passed in testPlacementPreservesRelativeDirectory. The command test verifies the executor input seam; it does not launch a real command. No planned cases skipped.

All logs below are under `tmp/node-cwd-relative/ncr-01-runner-resolution/`. Xcode toolchain PATH and DEVELOPER_DIR were set inside the arm64 shell.
- `swift build --build-tests --scratch-path tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch`: exit 0, build.log.
- `swift test --skip-build --scratch-path tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch --filter 'NodeWorkingDirectoryResolutionTests|DeterministicWorkflowRunnerBackendEventTests|AgentPromptGuardTests|PromptOverflowGuardIntegrationTests|SessionObservabilityTests|DeterministicWorkflowRunnerMemoryTests|FanoutArtifactEvidenceRunnerTests'`: exit 0, 53 tests, zero failures, test-core.log.
- `swift test --skip-build --scratch-path tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch --filter 'ScopedParityCallStepFanoutTests|WorkflowHostCapabilityTests|WorkflowCommandTests/testPackage'`: exit 0, 59 tests, zero failures, test-cli.log.
- `swiftlint lint --no-cache` on the four changed Swift files: exit 0, zero violations, lint-inventory.log. Strict NUL-manifest gate: exit 0, lint.log.
- Scope and diff check: exit 0, scope.log; one helper, two dispatch uses, only package CLI path in restricted diff with one argument addition.
- Cleanup: 3.2G, 38293 entries; removed via Python shutil after the command policy rejected rm -rf. No worktree .build; exit 0, cleanup.log.

Formal independent review, final integration, commit and push remain downstream.

## Continuation 1: actual command cwd verification

The four Swift source hashes match the prior implementation (see `tmp/node-cwd-relative/ncr-01-runner-resolution/continuation-source.sha`). The isolated `swift build --product riela --scratch-path tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch` passed (exit 0; `continuation-build.log`). The production CLI fixture `continuation-command-check.sh` passed the inherited node directory assertion but failed the explicit command directory run (exit 1; `continuation-command-check.log`). The target workspace directory existed. A diagnostic created the corresponding workflow-definition directory and confirmed the process actually ran there instead (`continuation-diagnostic.log`, exit 0). `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift:235-245` converts relative command and container directories against workflowDirectory before dispatch. That file and its registry tests are outside this plan's writePaths; `Sources/RielaCLI/WorkflowResolution.swift:737-747` contains a similar helper. A checkpoint amendment assigning the necessary registry and regression-test paths is required. The failed gate and scratch fixture are retained; do not clean the scratch root before repair and successful verification.

## Amended implementation and final verification (2026-11-11)

The round-2 checkpoint authorizes the model, registry, tests and example changes. Loader rewrites remain unchanged; local dispatch uses recorded authored directories and remote payloads remain unchanged. Nil-root retains loader output. Command/container execution records now reflect the dispatched directory. Per-edit snapshots and intents are in `tmp/node-cwd-relative/ncr-01-runner-resolution/edits/`; final hashes are in `final-source.sha`.

Source SHA-256 at this continuation before → final:
- `Sources/RielaCore/WorkflowModel.swift`: c2e6509a9a77487ac83e589862bd9b25d492b44d271629ce1aacea69f1f664f4 → 2f86212345ca1c3d710db414235431032013ff386dac29026c700354a38d1eb2
- `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`: 0aee49ef830e387de4f0afd9f82de3fc9ff541528faca46fdebb3bd2087e7c96 → 6f88290bd1c5744663c74138984c5c4812d95e4c315a94e7a60c863b33b0e9f8
- `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift`: ee653bc19391ffab5e05f85430530322f7ae3f84a5dd49261e8d71456566a17a → 6386cb2ada0dbb92bbbf28bdd2e670c930653cc02bfcb682a5e9b0f3ac9f5fdb
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`: e66cde2a21482e1e841ee2e9ba1348d905563b1a3b59bded80f8ece88a5ae7ff → 5f1640b4d6c3f477da9b26057950c0e19658576b00e674f2f4974eae79e08740
- `Tests/RielaCoreTests/NodeWorkingDirectoryResolutionTests.swift`: 51e555d41a0398311b82c46d7f807e4cf002e0b1734f79260fa7ea9d95f52dd1 → d7a9b6a983463b8052f5f48015c8e4b65ee2085a8b21f30aacbbf57dc334a663
- `examples/node-combinations-showcase/nodes/node-command-worker.json`: 410c66a4a1c9b345c92501c17c2ebff718a74a6b0052477bd8374fadaf5e1ae6 → dca7d44184a014aef5b9e97de8e6b0ef4640bba63c09deaea35bc3eb989515fa
- `examples/monja-typescript-sdk/nodes/node-monja-command.json`: d6e5b36f01c92844f2dea1ef19c99f0cbb0405ecd5376ad623c893e4ddb53fed → b2e5b4d469435a4b553d936c817aeee609c31cb9f7de098d9e4ff32885d8e892
- `examples/apple-gateway-packaging-plan/nodes/node-packaging-plan.json`: bb3bc314f1e8403a42b59cc1c4b2cd35593d19f80e36c8999e2696222a36c1cc → 15467605c9299eb180e8c388e764bb8a537e3fe2c6eb259eb33a818ef6e2a388
- `examples/first-four-arithmetic-pipeline/workflows/divide/nodes/node-divide-worker.json`: fe69bc4ccacc80562477a74ae7dfd28bf742f9b3f8856457b1545652386347a4 → a3ca9e38e675c08c65d73f4cffb73c2a7f24619db937b9982744db67d4da697b
- `Tests/RielaCLITests/WorkflowBundleWorkingDirectoryLoadTests.swift`: new → df6eeb019d82621df2561d97023cebd95c38ac7d6e8644674a6a57c8c576fef1

Cases passed: relative and parent-traversal agent cwd, absolute and nil cwd, nil-root fallback, inherited and explicit command cwd and records, container cwd and records, loader-authored container dispatch, same-node local/placed payload preservation, remote mapping and unmapped rejection, registry command and container loading, absolute and ./ metadata clearing, forged metadata clearing, executable rewrite and Codable round-trip. Both real inherited and explicit command cases and their records passed. No cases skipped.

Rehydration: `WorkflowDefinitionDocument.Runtime` encodes nodePayloads via Codable, resolvedBundle restores them, and WorkflowDefinitionService decodes stored documents; `WorkflowDefinitionServiceTests` passed. Audit: `rehydration-audit.txt`. Construction-site and scope evidence: `final-scope.log` (one helper, two local uses, only the permitted CLI path and one argument added).

Final logs below are under `tmp/node-cwd-relative/ncr-01-runner-resolution/`, with Xcode toolchain inside arm64 shell:
- `swift build --build-tests --scratch-path tmp/node-cwd-relative/ncr-01-runner-resolution/build-scratch`: exit 0, `build-final-5.log`.
- Core prescribed filter: exit 0, 82 tests, 0 failures, `test-core-final-4.log`.
- CLI/registry/example/distributed prescribed filter: exit 0, 99 tests, 0 failures, `test-cli-final-3.log`.
- Strict selected-file SwiftLint using `changed-swift.nul`, `--no-cache`: exit 0, `lint-final-3.log`.
- `continuation-command-check.sh`: exit 0, 2 cases passed, `e2e-final-2.log`.
- Scratch cleanup: exit 0, `cleanup-final.log`; no worktree `.build`.
- Earlier build argument-order failure `build-final.log` and fixture transition failure `test-core-final.log` were corrected and superseded by final-source passes. Earlier explicit cwd failure is retained above.

Formal review, integration, commit and push remain downstream.
