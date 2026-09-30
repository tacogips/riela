# wh-02-runner-suspend progress

Plan: `impl-plans/active/wh-02-runner-suspend.md`  
Dependency: `wh-01-contracts` accepted in the dispatch runtime (`acceptedPlanIds`).  
Branch: `feat/work-handover-and-takeover`  
Issue reference: no GitHub issue supplied; tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.

## Implementation

- Extracted `handover` after output-contract normalization for adapter, inline, and candidate-path outputs; the normalized business payload no longer contains the reserved key.
- Added defaulted `WorkflowPublicationResult.handover`; default/self-step envelopes suspend without validating or publishing business output. Downstream envelopes validate and publish normally, then reject a resume-step mismatch before commit.
- Added runner envelope and boundary suspension, durable `SuspendRecord` storage, ordered handover/session-completed events, suspended exit code 5, and resume from the recorded step. Session state clears its suspend record when execution resumes.
- Forwarded suspend mutations through the fail-closed SQLite store. Added resume answer gating and delivered-message injection, text hints, and suspend details in session inspection.
- Added runner regressions for default/downstream/malformed/mismatched/boundary/resume paths and a CLI scenario covering status, question gating, and answer resume.

## Verification

| Command | Outcome | Log |
| --- | --- | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-02-runner-suspend/build-final-confirm.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-02-runner-suspend/build-final-confirm.log'` | exit 0; build complete | `tmp/work-handover/wh-02-runner-suspend/build-final-confirm.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "DeterministicWorkflowRunnerSuspendTests|SessionResumeSuspendedTests|DeterministicWorkflowRunnerFailureStateTests|RuntimeStoreTests|SessionPreservedHistoryTests|SessionObservabilityCommandTests|AgentGatewayNodeAdapterTests" > tmp/work-handover/wh-02-runner-suspend/focused-final-passing.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-02-runner-suspend/focused-final-passing.log'` | 44 tests, 0 failures; exit 0 | `tmp/work-handover/wh-02-runner-suspend/focused-final-passing.log` |
| `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/work-handover/wh-02-runner-suspend/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi > tmp/work-handover/wh-02-runner-suspend/swiftlint-final-confirm.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-02-runner-suspend/swiftlint-final-confirm.log'` | exit 0 | `tmp/work-handover/wh-02-runner-suspend/swiftlint-final-confirm.log`; selected paths are listed NUL-delimited in `tmp/work-handover/wh-02-runner-suspend/changed-swift-files.nul` |
| `git diff --check > tmp/work-handover/wh-02-runner-suspend/diff-check-final-confirm.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-02-runner-suspend/diff-check-final-confirm.log` | exit 0 | `tmp/work-handover/wh-02-runner-suspend/diff-check-final-confirm.log` |

Earlier attempts: the first local build found a CLI hint type mismatch, which was corrected; early focused attempts found test fixture/assertion issues and concurrent wh-03 source edits. Those attempts are preserved in `build.log`, `core-test-first.log`, `core-test-second.log`, `focused-final.log`, `focused-final-retry.log`, and `focused-final-repair.log`; the final source-matched gates above pass.

## Final source hashes

SHA-256 values for the 13 wh-02 source and test files are recorded in `tmp/work-handover/wh-02-runner-suspend/final-source-sha256.txt`.

## Completion criteria

- [x] Envelope extraction, publication, runner suspend, store, resume, and CLI deliverables implemented; `WorkflowPublicationResult.handover` is defaulted.
- [x] New suspend and resume regressions pass; focused regressions are green.
- [x] Source hashes, commands, and complete log paths recorded above.

Formal test-integrity, adversarial, and serial integration review remain assigned to downstream workflow steps.

## Residual note

Handover question JSON currently requires an `options` array under strict Codable decoding; provide `[]` when there are no options.

## Step 6 test-integrity review (self-repair)

- Coverage repair 1: `testDefaultEnvelopeSuspendsWithoutPublishingBusinessOutputAndResumesAtStep` now checks every SuspendRecord field the plan requires: reasonKind, stepExecutionId, question id/text and producer `.stepExecution(<id>)`.
- Coverage repair 2: `testWorkflowRunSuspendQuestionGateAndAnswerResume` now checks the answer message. After an unanswered resume, the persisted canonical snapshot holds no handover message. After an answered resume, it holds exactly one delivered message: to `start`, `fromStepId` nil, payload `{"handover":{"answer":{"option":"a"}}}`, and `sourceStepExecutionId` set to the suspended execution id.
- Only test files changed; no Sources/ edits. Hunks, preimages and prehashes are in `tmp/work-handover/wh-02-runner-suspend/step6-review/`.
- Verification:
  - The reviewer reran the focused filter on the real tree: 44 tests executed, 0 failures, `exit=0` (`step6-review/focused-reviewer.log`).
  - Strict SwiftLint on the 2-file NUL manifest: `exit=0` (`swiftlint-reviewer.log`).
  - `git diff --check`: `exit=0`.
  - Current hashes are in `step6-review/final-source-sha256.txt`. The two test-file hashes supersede those in `final-source-sha256.txt`.

## Step 7 adversarial review self-repair

- Finding: a boundary handover (`task handover`) or an envelope `handover.resumeStepId` could suspend at the target of a fanout or cross-workflow dispatch transition. Resume would then run the fanout target once without items or join, or skip the callee entirely.
- Change 1: `requestedSuspendRecord` (`DeterministicWorkflowRunner+Suspend.swift`) returns nil without invoking `boundaryHandover` when the publication carries a `crossWorkflowDispatch` or `fanoutDispatch`. The hook fires at the next ordinary boundary. The envelope branch is unchanged.
- Change 2: `publishAcceptedOutput` (`RuntimePublication.swift`) rejects a downstream `handover.resumeStepId` when the selected transition is a live fanout or cross-workflow dispatch, with `invalidOutput` "handover.resumeStepId cannot target a fanout or cross-workflow dispatch transition", before commit. The mismatch message and behaviour for other transitions are unchanged.
- Tests added in `DeterministicWorkflowRunnerSuspendTests`: `testEnvelopeResumeStepOnFanoutTransitionFailsClosedWithoutPublishing`, `testBoundaryHandoverIsNotInvokedAtFanoutBoundaryAndFiresAtNextOrdinaryBoundary`.
- Verification (logs in `tmp/work-handover/wh-02-runner-suspend/step7-review/`): `build.log` exit=0; `focused.log` 90 tests, 0 failures, exit=0; `swiftlint.log` strict exit=0; `diff-check.log` exit=0.
- New hashes: `step7-review/final-source-sha256.txt` (supersedes step6 hashes); preimages and prehashes are in the same directory.
