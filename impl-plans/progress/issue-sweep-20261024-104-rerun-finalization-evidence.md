# ISW-104 implementation progress

**Plan:** `ISW-104-rerun-finalization-evidence`  
**Issue:** `tacogips/riela#104`  
**Workflow mode:** full `issue-resolution`  
**Branch:** `feat/issue-sweep-20261024`  
**Status:** implementation complete; independent review and workflow finalization remain downstream.

## Readiness and design alignment

The assigned `dependsOn` is `ISW-135-retry-timeout-rerun-carryover`. Its membership in the runtime-owned `acceptedPlanIds` admitted this plan. The ISW-135 progress log reports the D2 contract complete and documents its shared `Recovery.swift`, `RerunCarryover.swift`, and `docs/preserved-history-recovery.md` changes. The assigned plan and accepted D3 design were read before edits; implementation follows the pinned signature, graph and dominance rules, recovery wording, and shared-path ownership.

## Completion criteria

- [x] Add pure `rerunFinalizationEvidenceExecutions(workflow:source:targetStepId:available:)`; unprotected workflows return `[]`.
- [x] Build graph edges from local `toStepId`, cross-workflow `resumeStepId`, and fanout `joinStepId`; keep transition identity and label while filtering only the policy's planning routes.
- [x] Bind the latest accepted Git evidence; bind mode evidence only when unreachable from the rerun target; the completed retry wins after a failed attempt.
- [x] Reject incomplete evidence before `createSession`, with the pinned recovery message; runner-level test proves no new session and no adapter invocation.
- [x] Wire evidence into plain and preserve-history reruns; merge plain-rerun evidence and D2 inbox producers by source order and execution identity.
- [x] Change only visibility for `expectedGitFinalizationMode` and `WorkflowGitFinalizationMode` in `DeterministicWorkflowRunner+GitFinalizationEvidence.swift`.
- [x] Add the ambiguous-boundary recovery hint and document D3 and the recovery path.
- [x] Cover the topology table, including early-target guarantee, parallel labeled edge filtering, retry selection, validator round trip, and runner behavior.
- [x] Build, all four required filters, strict changed-file SwiftLint, and diff check pass with integer evidence.

## Changes

- `Sources/RielaCore/DeterministicWorkflowRunner+RerunFinalizationEvidence.swift`: static protected-workflow selector, latest accepted binding, planning-route filtering and node-removal dominance checks.
- `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`: plain-rerun D2/D3 preflight and ordered deduplicated import; preserve-history D3 preflight.
- `Sources/RielaCore/DeterministicWorkflowRunner+GitFinalizationEvidence.swift`: visibility-only change for the existing mode enum and derivation function.
- `Sources/RielaCore/DeterministicWorkflowRunner+History.swift`: recovery hint on the ambiguous repeated-boundary diagnostic; declaration formatting needed for strict lint.
- `Tests/RielaCoreTests/WorkflowRerunFinalizationEvidenceTests.swift`: 11 tests cover the D3 table, planning-route edge identity, validator round trips, and preflight/runner behavior.
- `Tests/RielaCoreTests/WorkflowPreservedHistoryTests.swift`: failed-then-completed prefix retry import and exact ambiguous-boundary recovery hint.
- `docs/preserved-history-recovery.md`: D3 behavior and recovery guidance.

## Edit evidence and shared paths

Every edit has a plan-local intent record and pre-edit SHA-256 record under `tmp/issue-sweep-20261024/ISW-104/evidence/edit-*-intent.md` and `edit-*-pre.sha256`. The initial shared-path hashes were:

| Shared path | Pre-edit SHA-256 |
|---|---|
| `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift` | `6b937c08395c3987d500b6396d740095b06ec826765aabc28cb39be7ed8b79e9` |
| `Sources/RielaCore/DeterministicWorkflowRunner+RerunCarryover.swift` | `f498484f976f6e3574d06fd95b242012f8fa69e4e328222be601c46794403d7b` |
| `docs/preserved-history-recovery.md` | `8f90bdc21530de1189d803ec4a2e7be8eec8996e694d68307ff9caa6613d979b` |

ISW-135's completed progress record was checked before the two shared-path edits. The combined final post-edit hashes, including the progress record, are in `tmp/issue-sweep-20261024/ISW-104/evidence/final-post-hashes.sha256`. `DeterministicWorkflowRunner+GitFinalizationEvidence.swift` was checked with `git diff`; its only changes are the two required `private` to internal visibility changes. The selected Swift paths are recorded as a NUL-delimited manifest in `tmp/issue-sweep-20261024/ISW-104/evidence/changed-swift-files.nul`.

## Final-source verification

Commands ran from the repository root via `arch -arm64 /bin/zsh -lc`. Every log below is complete and ends with `exitStatus=...`.

| Command | exitStatus | testsRun | failureCount | Log |
|---|---:|---:|---:|---|
| `swift build` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-104/build-final6.log` |
| `swift test --filter WorkflowRerunFinalizationEvidenceTests` | 0 | 11 | 0 | `tmp/issue-sweep-20261024/ISW-104/rerun-evidence-final6.log` |
| `swift test --filter WorkflowGitFinalizationEvidenceTests` | 0 | 21 | 0 | `tmp/issue-sweep-20261024/ISW-104/git-evidence-final6.log` |
| `swift test --filter WorkflowPreservedHistoryTests` | 0 | 7 | 0 | `tmp/issue-sweep-20261024/ISW-104/preserved-final6.log` |
| `swift test --filter "WorkflowRerunInputCarryoverTests|DeterministicWorkflowRunnerFailureStateTests|DeterministicWorkflowRunnerTests|WorkflowModelTests"` | 0 | 73 | 0 | `tmp/issue-sweep-20261024/ISW-104/regression-final6.log` |
| `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-20261024/ISW-104/evidence/changed-swift-files.nul` (invoked through the required arm64 shell guard) | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-104/lint-final6.log` |
| `git diff --check` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-104/diff-check-final8.log` |

The regression aggregate's 73 tests comprise 2 failure-state, 36 runner, 28 model, and 7 carryover tests. The final D3 table run also includes the failed-plan-commit/no-plan-push early-target case and a parallel non-planning edge sharing endpoints with the filtered planning route.

## Superseded attempts

- `rerun-evidence-attempt-001.log` exited 1: the first synthetic fixture omitted a topology back-edge, so an assertion expected no mode binding incorrectly; the run then hit duplicate plan-node IDs. The fixture now includes the accepted topology back-edge and unique node IDs.
- `rerun-evidence-final3.log` exited 1 before tests: the edge-identity refinement initially used `String.map` for an optional join ID. It now appends explicitly typed graph edges; current-source `rerun-evidence-final6.log` passes 11/11.
- `lint-final.log` exited 1 on three pre-existing parameter alignment diagnostics in `History.swift` and one test `if/else` position. Those declarations and the conditional were formatted; strict selected-file lint now exits 0 in current-source `lint-final6.log`.

## Handoff

No unresolved implementation requirement or verification gap remains for ISW-104. Formal test-integrity/adversarial/integration review, review-dependent shared documentation, staging, commit, and push are downstream workflow steps; `gitPush=false` remains in force.
