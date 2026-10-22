# pog-03-prompt-guard implementation progress

Workflow mode: `issue-resolution`. Plan: `impl-plans/active/prompt-overflow-guard-03-prompt-guard.md`. Issue reference: none; incident session-471. Codex-agent reference: Step 6 implementation agent in native fanout branch `pog-03-prompt-guard`; no nested Riela/Codex CLI or subagents.

Dependency readiness: `pog-01-contracts` appears in the fanout item's `acceptedPlanIds`, satisfying the only DAG dependency.

## Implementation

Added `DeterministicWorkflowRunner+PromptGuard.swift` with the pinned 400000/4096/256 constants, budget precedence, UTF-8 prompt sizing, deterministic RFC 6901 candidate enumeration and selection, deduplicated runtime-variable view, content-addressed spill files, private directories (0700) and exclusive files (0600), stub replacement/recomposition, and `promptCompaction` evidence. Mismatched existing files reject with `policyBlocked`; budget/placement/no-candidate rejection uses `promptTooLarge`.

Integrated the guard after prompt composition and before adapter input construction. `AdapterExecutionInput.mergedVariables` remains original and uncompacted. `executeAndPublish` records evidence on the input snapshot, then publishes guard rejection after recording the execution and before backend invocation. `Prompting.swift` and `RuntimePublication.swift` were not edited by this plan.

Focused tests cover under-budget evidence absence, budget precedence, placed-step rejection without spill files, spill hash/path/modes, original merged variables, smallest-covering and pointer tie-break selection, deterministic replay/evidence and content-addressed file reuse, template interpolation of both top-level and latest-message spill stubs, and a failed promptTooLarge execution without adapter invocation.

## Pre/post SHA-256

Pre-edit hashes were read immediately before the first edits; new source/test paths did not exist. The security follow-up pre-edit hash for the guard source was `87559e115c0c48d90e34acdb6624c4a96ae3696771352c08089a0463124a8254`; its verified post-edit hash is `f13c76991de1de8a1873438c66567302c1aded390a7ab981835a687f015a3786`. The permission assertion pre-edit test hash was `30a858fa97a912bc2f56ff93a206d1a77b5fabcdc07f0a8518d10efe51dd193b`; its post-edit hash is `2e2c49e51677d8406a4fd6bfae7ae5e370cd557098e714c6a10a5191434e90fe`.

| Path | Initial pre-edit SHA-256 | Final SHA-256 |
| --- | --- | --- |
| `Sources/RielaCore/DeterministicWorkflowRunner.swift` | `47a312a40a5c7540814e7526996a9699caaf58ffe77bda1caf3e2b5a82fda923` | `92f3054ed453165743f623ac7477cc776a79005a66ced6bc7da9f9410887b55d` |
| `Sources/RielaCore/DeterministicWorkflowRunner+AdapterPublication.swift` | `626099ae439c7f7267dbb2ed2fe33c76be0e8395545625462ce9a9b23247e3af` | `3cf7365b0223b39068c0e47fdd7098c097934d2f74815697c5221504dea98441` |
| `Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift` | absent | `e4de314aef372e5dc2fe4a6231d1d263b7018ae4d3cfee04a4a6c2a9597b4d54` |
| `Tests/RielaCoreTests/AgentPromptGuardTests.swift` | absent | `441adfda90e6ed68e97f6634b069c808fac556eeaabcc06524a01fde6ec91add` |

Exact per-file behavior intentions and follow-ups: `tmp/prompt-overflow/pog-03-prompt-guard/edit-intentions.md`.

## Verification

All final gates ran in arm64 shells. Final logs are complete and plan-local.

| Gate | Exact command | Result |
| --- | --- | --- |
| Build | `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/build-final.log'` | exit 0; `Build complete! (8.86s)` |
| Focused tests | `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "AgentPromptGuardTests|RuntimeVariablesPromptingTests|DeterministicWorkflowRunnerTests|WorkflowOutputContractPreflightTests" 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/test-final.log'` | exit 0; 52 tests, 0 failures |
| Changed-file SwiftLint | `arch -arm64 /bin/zsh -lc 'set -o pipefail; changed_swift_manifest=tmp/prompt-overflow/pog-03-prompt-guard/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi' 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/lint-final.log` | exit 0; zero diagnostics; exact NUL manifest in `tmp/prompt-overflow/pog-03-prompt-guard/changed-swift-files.nul` |

Resolved earlier test attempts: `test-rerun.log` executed 47 tests with one fixture failure because it assumed a generated session ID. `test-placement-failure.log` captured a placement fixture whose prompt was under budget; the fixture now uses a large authored system prompt. `test-alias-regression.log` captured a test budget that selected the enclosing `_rielaInput` candidate; the corrected test targets the nested leaf and proves the latest-message template alias is updated. The final source-matched run passed all 52 tests. A concurrent SwiftPM owner initially delayed build/test commands; final foreground commands completed successfully.

## Completion

Assigned source, tests, and progress updates are complete. No known implementation-phase blocker or verification gap remains. Formal integrity, adversarial, and integration reviews remain downstream workflow steps.

## Test-integrity repairs (comm-008763)

- POG03-TI-1 resolved in `Tests/RielaCoreTests/AgentPromptGuardTests.swift`: the placed request now includes a 6,000-character spillable `huge` variable in both composed runtime variables and request variables. The placed guard keeps the `promptTooLarge`, `overBudget`, empty-spills, and no-spill-directory assertions. An unplaced control uses the same value and a measured budget that permits the spill; it asserts a non-empty spill list.
- POG03-TI-2 resolved in `Tests/RielaCoreTests/AgentPromptGuardTests.swift`: a first guard call supplies the content-addressed path from spill evidence; the test overwrites that file with `tampered`, runs the guard again for the same session and step, and passes its `policyBlocked` rejection through `executeAndPublish`. It asserts `different content`, no adapter invocation, one failed execution, and `promptCompaction.outcome == overBudget`.
- Test-file SHA-256 edit chain: `441adfda90e6ed68e97f6634b069c808fac556eeaabcc06524a01fde6ec91add` (pre-repair) → `c97ff593e34ee409cdcc6c7455d6d8ef9e0096376848ee5adcf11e3a803ec296` (fixtures/tests) → `57fd4da9b21d54a649a09d079a07ef904dfaf610ebd5f878c5431589efa729c6` (publication assertions) → `4e7b311ca0e039d22938d9f40e872f09fadadf72797b0470c57d8b44cc0610a5` (unused local removed; final).
- Final repair verification, all run from the repository root in foreground arm64 shells:
  - `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/build-ti.log'` — exit 0; complete log `tmp/prompt-overflow/pog-03-prompt-guard/build-ti.log`.
  - `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "AgentPromptGuardTests|RuntimeVariablesPromptingTests|DeterministicWorkflowRunnerTests|WorkflowOutputContractPreflightTests" 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/test-ti.log'` — exit 0; 53 tests, 0 failures; complete log `tmp/prompt-overflow/pog-03-prompt-guard/test-ti.log`. Log mtime 09:49:26 is newer than the final test source mtime 09:48:58.
  - `arch -arm64 /bin/zsh -lc 'set -o pipefail; xargs -0 swiftlint lint --strict < tmp/prompt-overflow/pog-03-prompt-guard/changed-swift-files.nul 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/lint-ti.log'` — exit 0; 0 violations in the 4 manifest files; complete log `tmp/prompt-overflow/pog-03-prompt-guard/lint-ti.log`.
- Final repair hashes: guard `e4de314aef372e5dc2fe4a6231d1d263b7018ae4d3cfee04a4a6c2a9597b4d54`; runner `92f3054ed453165743f623ac7477cc776a79005a66ced6bc7da9f9410887b55d`; adapter publication `3cf7365b0223b39068c0e47fdd7098c097934d2f74815697c5221504dea98441`; test `4e7b311ca0e039d22938d9f40e872f09fadadf72797b0470c57d8b44cc0610a5`.
- Formal combined-tree integration review and session-471 end-to-end/retry scenarios remain downstream in pog-05.

## Integration repair: IR-POG03-LINUX-IMPORT

Finding: the new guard source imported Darwin unconditionally and compared raw S_IFMT/S_IFDIR against st_mode, breaking Linux RielaCore portability. Re-read immediately before edit; verified pre-edit SHA-256: `e4de314aef372e5dc2fe4a6231d1d263b7018ae4d3cfee04a4a6c2a9597b4d54` (matches the repair brief). Intention and exact hunk are recorded at `tmp/prompt-overflow/pog-03-prompt-guard/IR-POG03-LINUX-IMPORT-intention.md`.


Repair result: `Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift` now uses the guarded Linux Glibc/macOS Darwin import and wraps both S_IFMT and S_IFDIR with mode_t. Post-edit SHA-256: `519ad3eb18e743f617ba3b1f017f72dae6aadd839d1c4285fd306d4e620dd0f9`. No guard behavior or tests changed. The exact changed-Swift manifest is `tmp/prompt-overflow/pog-03-prompt-guard/changed-swift-files.nul` (32 paths).

Repair verification (foreground arm64 shell; complete logs):
- `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build --disable-automatic-resolution 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/build-ir-linux.log'` — exit 0; `Build complete! (34.12s)`.
- `arch -arm64 /bin/zsh -lc "set -o pipefail; swift test --disable-automatic-resolution --filter 'AgentPromptGuardTests|PromptOverflowGuardIntegrationTests|PromptTooLargeRecoveryTests|RuntimeVariablesPromptingTests|DeterministicWorkflowRunnerTests|WorkflowOutputContractPreflightTests' 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/test-ir-linux.log"` — exit 0; 57 tests, 0 failures.
- `arch -arm64 /bin/zsh -lc 'set -o pipefail; xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/prompt-overflow/pog-03-prompt-guard/changed-swift-files.nul 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/lint-ir-linux.log'` — exit 0; quiet strict lint, 0 diagnostics.
- Optional Linux container verification was unavailable: `docker info --format '{{.ServerVersion}}'` exited 1 because the Docker daemon socket `/var/run/docker.sock` does not exist. No Linux container build is claimed. Import and mode_t source patterns are verified; macOS build and behavioral tests pass.


## Linux verification (IR-POG03-LINUX-IMPORT-VERIFICATION-SCOPE)

The accepted integration-review scope is satisfied by a debug aarch64 Glibc compile of the `RielaCore` target in the CI-pinned Swift image. Exact foreground command:

`/opt/homebrew/bin/container run --rm --name pog03-linux-ir-verify --arch arm64 -v "$PWD:/workspace" -w /workspace swift@sha256:c2f3ac2eb806ce43f68859c3d52bd3bb1cfc88672fb3a948b76e136d98e39278 bash -lc 'set -euo pipefail; uname -m; apt-get update >/dev/null && apt-get install -y libsqlite3-dev >/dev/null; sha256sum Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift; swift build --scratch-path tmp/prompt-overflow/pog-03-prompt-guard/linux-scratch --target RielaCore' > tmp/prompt-overflow/pog-03-prompt-guard/linux-build-ir.log 2>&1; result=$?; echo "exit=$result" >> tmp/prompt-overflow/pog-03-prompt-guard/linux-build-ir.log; exit "$result"`

Result: exit 0; `aarch64`; in-container guard SHA-256 `519ad3eb18e743f617ba3b1f017f72dae6aadd839d1c4285fd306d4e620dd0f9`; `Build of target: 'RielaCore' complete! (53.41s)`. Complete log: `tmp/prompt-overflow/pog-03-prompt-guard/linux-build-ir.log`, SHA-256 `2dfdfebffa41c08f2d1fcea9bbb8f7d44133a5410679548d210f0c328742a7a6`. The log contains one SwiftPM warning about an optional notion-gateway cache clone (`warning: ... error: Failed to clone`) and no compiler error diagnostics. The source hash remained unchanged. `Package.resolved` was restored from the task-local pre-run copy and `git diff --quiet HEAD -- Package.resolved` exited 0. `container list` confirms no `pog03-linux-ir-verify` container remains; the linux-scratch tree and backup were deleted.

Renewed current-source macOS gates:
- `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build --disable-automatic-resolution 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/build-ir-verify.log'` — exit 0; complete log `tmp/prompt-overflow/pog-03-prompt-guard/build-ir-verify.log`; `Build complete! (9.72s)`.
- `arch -arm64 /bin/zsh -lc "set -o pipefail; swift test --disable-automatic-resolution --filter 'AgentPromptGuardTests|PromptOverflowGuardIntegrationTests|PromptTooLargeRecoveryTests|RuntimeVariablesPromptingTests|DeterministicWorkflowRunnerTests|WorkflowOutputContractPreflightTests' 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/test-ir-verify.log"` — exit 0; 57 tests, 0 failures; complete log `tmp/prompt-overflow/pog-03-prompt-guard/test-ir-verify.log`.
- `arch -arm64 /bin/zsh -lc "set -o pipefail; xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/prompt-overflow/pog-03-prompt-guard/changed-swift-files.nul 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/lint-ir-verify.log"` — exit 0; 32-file exact changed-Swift manifest; complete log `tmp/prompt-overflow/pog-03-prompt-guard/lint-ir-verify.log` (empty, zero diagnostics).

Scope decision: the amd64 release `riela` product build remains deferred to PR Linux CI. `authorSelfCheck.verificationGaps` is empty for this plan; no source or test file changed during this verification repair. Post-run SHA-256: guard `519ad3eb18e743f617ba3b1f017f72dae6aadd839d1c4285fd306d4e620dd0f9`; test `4e7b311ca0e039d22938d9f40e872f09fadadf72797b0470c57d8b44cc0610a5`.
