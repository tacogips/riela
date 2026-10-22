# pog-05-integration progress

Workflow mode: issue-resolution. Issue reference: none; incident opus-luna-design-and-implement-review-loop 0.1.8 session-471 (2026-10-22). Codex-agent reference: Luna implementers for pog-01..04 are represented in their branch evidence; this node is the pog-05 integration implementer.

Accepted dependencies from the runtime fanout item: `pog-02-fanout-observations`, `pog-03-prompt-guard`, `pog-04-failure-kind-consumers` (all present in `acceptedPlanIds`). Committed plan: `impl-plans/active/prompt-overflow-guard-05-integration.md`; design: `design-docs/specs/design-agent-prompt-overflow-guard.md`.

## Scope and edit record
- `Tests/RielaCoreTests/PromptOverflowGuardIntegrationTests.swift`: added a three-branch fanout run with 120 tracked files per branch, a 40 KB branch continuation, inline observation limit 50, spill-file digest assertions, completed join/session assertions, plus a retry-after-budget-raise test that confirms no backend call on `promptTooLarge` and a successful retry.
- `README.md`: added the Agent prompt size limits section immediately after Session Observability.
- `tmp/prompt-overflow/pog-05-integration/`: mock-scenario workflow/nodes/scenario, CLI output, session export, spill inventory, changed-Swift NUL manifest, and complete command logs.
- Before-edit README SHA-256: `1a7720df7502b012aadbdafa30386d433fed50e7ae5cd6d569524da311d7eaf3`.
- Before-edit plan SHA-256: `454be80d1b5ce32b4ce19b85d434db178c4ecbd63d2c001015a916ed6acb753e`.
- Final README SHA-256: `4f2a4c38a7f30d07c48ef8d370f874328a487bf4ddfa7d9e3eb46c58e15eaebc`.
- Final integration test SHA-256: `6a080771e456f16114a70adf24c4c2c1f4f9056691e181136ee66129ce18234d`.
- Progress pre-update SHA-256: `8d9c001f7d922902760ce9809617d813990bea890c9540bf94a8eafc0e561efd`.
- Per-edit intentions are recorded before changes in `tmp/prompt-overflow/pog-05-integration/edit-intentions-01.md` through `edit-intentions-14.md`. The initial integration test file did not exist before this plan.

## Verification
- **Build, exit 0:** `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/prompt-overflow/pog-05-integration/build-final.log'`; log `tmp/prompt-overflow/pog-05-integration/build-final.log` ends `Build complete! (5.85s)`.
- **Focused suites, exit 0:** `arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "PromptOverflowGuardIntegrationTests|PromptOverflowContractsTests|RuntimeVariablesPromptViewTests|WorkflowFanoutObservationBoundTests|AgentPromptGuardTests|PromptTooLargeRecoveryTests|PromptTooLargeResumeMessageTests|PromptTooLargeRerunTests|WorkflowFanoutMapReduceTests|FanoutArtifactEvidenceRunnerTests|DeterministicWorkflowRunnerFanoutTests|RuntimeVariablesPromptingTests|DeterministicWorkflowRunnerTests|WorkflowOutputContractPreflightTests|DeterministicDirectorTests|WorkGuardDispatcherTests" 2>&1 | tee tmp/prompt-overflow/pog-05-integration/swift-test-final.log'`; `swift-test-final.log` reports 141 tests, 0 failures.
- **Union strict SwiftLint, exit 0:** `arch -arm64 /bin/zsh -lc 'set -o pipefail; if [ -s tmp/prompt-overflow/pog-05-integration/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict < tmp/prompt-overflow/pog-05-integration/changed-swift-files.nul 2>&1 | tee tmp/prompt-overflow/pog-05-integration/lint-final.log; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'`; `lint-final.log` reports 0 violations in 32 files. The manifest includes all changed tracked Swift paths and untracked new Swift paths, including this integration test.
- **Mock scenario, exit 0:** `.build/debug/riela workflow run prompt-overflow-fanout --workflow-definition-dir /Users/taco/gits/tacogips/riela-worktrees/agent-prompt-overflow-guard/tmp/prompt-overflow/pog-05-integration/mock-run --working-dir /Users/taco/gits/tacogips/riela-worktrees/agent-prompt-overflow-guard/tmp/prompt-overflow/pog-05-integration/workdir --mock-scenario /Users/taco/gits/tacogips/riela-worktrees/agent-prompt-overflow-guard/tmp/prompt-overflow/pog-05-integration/mock-run/prompt-overflow-fanout/mock-scenario.json --output json`; complete output in `tmp/prompt-overflow/pog-05-integration/mock-run.log`; root and session status are `completed`, and join execution status is `completed` with `promptCompaction.outcome: spilled`.
- **Spill inventory:** `find tmp/prompt-overflow/pog-05-integration/workdir/tmp/riela-prompt-spill -name '*.json' | tee tmp/prompt-overflow/pog-05-integration/spill-files.txt`; exit 0 and one spill file listed.
- **Session export:** `.build/debug/riela session export prompt-overflow-fanout-session-2 --working-dir /Users/taco/gits/tacogips/riela-worktrees/agent-prompt-overflow-guard/tmp/prompt-overflow/pog-05-integration/workdir --output json > tmp/prompt-overflow/pog-05-integration/session-export.json`; exit 0; export status is completed and includes join `inputSnapshot.promptCompaction`.
- **README heading:** `grep -n 'Agent prompt size limits' README.md`; exit 0, one hit at line 545.
- **Whitespace:** `git diff --check`; exit 0.

### Resolved attempts

Earlier implementation attempts are superseded by final-source gates above: `integration-initial.log` and `integration-retry1.log` failed compilation due to async XCTest autoclosures (exit 1); `integration-retry2.log` rejected the test adapter's old node labels (exit 1); `integration-retry3.log` exposed the additional three directory observations (exit 1); `lint.log` found one force-try issue in the new test (exit 1). The final focused test and `lint-final.log` pass after those fixes. The first relative-path CLI invocation failed because the CLI resolves the workflow directory relative to its working directory; its original log destination was reused by the corrected successful run, so that failed output has no separate retained complete log. `mock-run-absolute.log` records the subsequent wrong-response-key failure. `mock-run.log` is the corrected successful absolute-path run. The first session export lookup omitted `--working-dir`; the corrected export above passed.

Implementation-phase acceptance criteria are met. Formal test-integrity/adversarial/integration review and any review-owned updates, staging, commit and push remain downstream workflow steps; no git write command was run.
