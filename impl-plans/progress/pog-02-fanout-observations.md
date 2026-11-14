# pog-02 implementation progress

Plan: `pog-02-fanout-observations` (`issue-resolution`, incident session-471; no GitHub issue). Dependency `pog-01-contracts` is accepted in the fanout item's runtime-owned `acceptedPlanIds`. Codex-agent reference: read-only runner/test-helper scout reported the existing fanout join capture seam; no delegated edits.

## Implementation

- `WorkflowFanoutChangeEvidence.reduce(observationInlineLimit:)` clamps to 0...10000, aggregates raw findings by `(branchId, selection, path)`, preserves first `reason`, distinct ordered `reasons`, occurrence count and first/last attribution, sorts by plain String order, caps inline output, and derives `hasDrift` from total count.
- The full aggregate including ordered `occurrenceDetails` is serialized as compact sorted-key JSON and written to `observations.json` with a 0600 O_EXCL temp file followed by same-directory atomic `rename`, replacing prior reductions deterministically. Persistence errors append a reduce diagnostic and leave inline observations available with null `observationsPath` and `complete: false`.
- Join fields include aggregate/raw/inline counts, truncation, path, branch counts, and effective `limits.observationInline`. The fanout runner passes the configured/default limit.
- Added high-cardinality, zero-limit, empty-list, persistence-failure, determinism and runner-wiring assertions. Existing reason assertions accept compatibility `reason` or aggregate `reasons`.

## Per-edit source hashes

Hashes below were read immediately before/after the scoped edits; initial values are also preserved in `tmp/prompt-overflow/pog-02-fanout-observations/edit-intentions.md` and tool outputs for individual repair edits.

| File | Pre-edit SHA-256 | Final SHA-256 |
| --- | --- | --- |
| `Sources/RielaCore/WorkflowFanoutChangeEvidence.swift` | `e04386969946cd8b156a858a4fd0191f10afeca2cf857f99799e0928bb3d8b59` | `e238bc1441998250a4abec320d744e5c90ae09cf8d9bdd08451550455356caad` |
| `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift` | `4ce57b5f6170990ca31e96672477eae36761aa45d11061121316da6d3ed8d5f7` | `e16bc3ab7aa130054a5c75d67e315715c8d3b357df96c6b3b4791b1c8cfd3da7` |
| `Tests/RielaCoreTests/WorkflowFanoutObservationBoundTests.swift` | absent (new file) | `9690196b5c07f3c6770ead47f57810fe99b0c3e276ff7fe68b7db9e9a2775c5e` |
| `Tests/RielaCoreTests/WorkflowFanoutMapReduceTests.swift` | `72f1860eefd7d46be4781c8e7f06bbc15935511bea535f3568d2b2fb24c9a267` | `d718129a2d3062718af7ec1ec1edc77ced001411e401866ee422902df7eb1a24` |
| `Tests/RielaCoreTests/FanoutArtifactEvidenceRunnerTests.swift` | `62c1272ba0727cfd46d4b95e98ed6d2c2560414d6d42c3d88710d22a5ce886b6` | `c3918ebb07c7716b980c6eafb635d788a43825c4f3c17402d2f02b690b6e708a` |

## Verification attempts and final gates

1. `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/build.log'` — exit 0; `build.log` ends `Build complete! (6.19s)`.
2. `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "WorkflowFanoutObservationBoundTests|WorkflowFanoutMapReduceTests|FanoutArtifactEvidenceRunnerTests|DeterministicWorkflowRunnerFanoutTests" 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/test.log'` — exit 1 before tests ran. Initial compile found three issues in the new test file plus concurrent `Tests/RielaCoreTests/PromptTooLargeRecoveryTests.swift` errors. The new test issues were corrected and are not repeated in the retry.
3. `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "WorkflowFanoutObservationBoundTests|WorkflowFanoutMapReduceTests|FanoutArtifactEvidenceRunnerTests|DeterministicWorkflowRunnerFanoutTests" 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/test-retry1.log'` — exit 1 before tests ran. Concurrent filtered tests were active; compile reported missing `RielaCLIApplication.nonBudgetFailureResumeMessage` in `Tests/RielaCLITests/PromptTooLargeResumeMessageTests.swift` and that the file changed during build. No current behavioral test count is available; rerun is pending once shared compile activity settles.
4. Selected-file SwiftLint manifest: `tmp/prompt-overflow/pog-02-fanout-observations/changed-swift-files.nul`. Command: `changed_swift_manifest='tmp/prompt-overflow/pog-02-fanout-observations/changed-swift-files.nul'; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest" 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/lint.log; else printf '%s\\n' 'No Swift files changed; selected-file SwiftLint not run.'; fi` — exit 0; quiet log is empty.

5. Final focused suite: `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "WorkflowFanoutObservationBoundTests|WorkflowFanoutMapReduceTests|FanoutArtifactEvidenceRunnerTests|DeterministicWorkflowRunnerFanoutTests" 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/test-final.log'` — exit 0; 46 tests, 0 failures, including 4 new bound tests and runner propagation. The high-cardinality test asserts 1,203 aggregates, 3,609 occurrences and serialized join size below 262,144 bytes.
6. Final build: `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/build-final.log'` — exit 0; `Build complete! (6.08s)`.
7. Final selected-file strict SwiftLint: `arch -arm64 /bin/zsh -lc 'changed_swift_manifest="tmp/prompt-overflow/pog-02-fanout-observations/changed-swift-files.nul"; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest" 2>&1 | tee tmp/prompt-overflow/pog-02-fanout-observations/lint-final.log; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` — exit 0; empty quiet log.

## Step 6 completion criteria

- [x] Aggregated reducer contract, caps, join fields, persistence failure handling and deterministic replacement are implemented.
- [x] Full list includes ordered `occurrenceDetails`; empty and no-drift reductions persist the file.
- [x] Required bound, zero-limit, no-drift, failure, determinism and runner-wiring tests pass.
- [x] Final arm64 build, focused test suite and exact changed-file strict lint pass.
- [x] Logs and final source hashes are recorded above. Earlier compile failures are preserved as prior attempts; final source-matched verification resolves them.

No Git writes were run. Formal integrity/adversarial and combined integration reviews, review-dependent documentation, staging, commit and push remain downstream workflow steps.
