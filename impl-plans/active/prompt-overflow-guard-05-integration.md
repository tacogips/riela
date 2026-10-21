# Prompt Overflow Guard 05: Integration Tests, Mock Run and Documentation

**planId**: `pog-05-integration`
**Wave**: 3
**dependsOn**: `pog-02-fanout-observations`, `pog-03-prompt-guard`,
`pog-04-failure-kind-consumers`
**Workflow Mode**: issue-resolution
**Issue Reference**: none. Incident: opus-luna 0.1.8 session-471. Current
run: `opus-luna-design-and-implement-review-loop-session-475`.
**Design Reference**: `design-docs/specs/design-agent-prompt-overflow-guard.md`
Documentation, Verification and Rollout sections.
**Branch**: `feat/agent-prompt-overflow-guard`. Do not run any git write
command.
**Progress log**: `impl-plans/progress/pog-05-integration.md`
**Evidence dir**: `tmp/prompt-overflow/pog-05-integration/`
**planPath**: `impl-plans/active/prompt-overflow-guard-05-integration.md`

**writePaths**:

- `Tests/RielaCoreTests/PromptOverflowGuardIntegrationTests.swift`
- `README.md`
- `impl-plans/progress/pog-05-integration.md`
- `tmp/prompt-overflow/pog-05-integration`

**sharedPaths**: none. A wave-2 file may be edited only to fix an
integration defect, and only with a fresh read, a hash, and the owning plan
recorded.

**artifactRoots**: `tmp/prompt-overflow/pog-05-integration`. It holds the mock
run, the workdir, the spill files and the logs.

## Intent and Context

This plan proves the session-471 shape end to end: parallel fanout branches
with change tracking are joined into an agent step whose input exceeds the
budget. The join is bounded, the guard spills, and the agent step succeeds.

It also covers:

- recovery after raising the budget;
- the README section;
- the final focused-suite and lint pass over every changed Swift file.

Contracts it relies on:

- From `pog-02`: join fields `observationCount`, `observationsTruncated`,
  `observationsPath` and `limits.observationInline`.
- From `pog-03`: `inputSnapshot.promptCompaction`
  (`outcome`/`spills`/`budgetBytes`/`finalBytes`), the stub
  `{"$rielaSpilled", pointer, path, bytes, sha256, preview}`, and spill files
  under `<workdir>/tmp/riela-prompt-spill/<sessionId>/<stepId>/`.
- From `pog-01` and `pog-04`: `failureKind == promptTooLarge` and
  `--retry-failed-step` eligibility.

## Non-Goals

- No committed example workflow, and no `rielaExampleWorkflowNames()`
  registration.
- No SDL regeneration. There is no GraphQL DTO change.
- Do not refactor the wave-2 code. Fix only a cross-plan integration defect.
  Each fix must be minimal and recorded in the progress log, naming the
  owning plan.

## File-Level Changes

### 1. `Tests/RielaCoreTests/PromptOverflowGuardIntegrationTests.swift` (new)

- **Session-471 shape.**
  - Build a `DeterministicWorkflowRunner` with `fanoutWorkspaceRoot` set to a
    scratch directory under the repository `tmp/`, removed in teardown.
  - The workflow fans out over 3 items with
    `changeTracking.pathsFrom` (each item's own `logs/<branch>` directory)
    and `observationInlineLimit: 50`. Imitate the runner setup in
    `Tests/RielaCoreTests/FanoutArtifactEvidenceRunnerTests.swift` and
    `DeterministicWorkflowRunnerFanoutTests.swift`.
  - Each branch's adapter writes about 120 files into its directory and
    returns a payload with a 40 KB string.
  - The join agent step has `promptMaxBytes` set below the composed join size
    but above the non-spillable text. Expected:
    - `changeEvidence.observationsTruncated == true` and
      `observations.count == 50`;
    - the join agent step `status == .completed` and the adapter is invoked
      once;
    - `promptCompaction.outcome == "spilled"`;
    - each spill file exists with a matching sha256;
    - the session is `.completed`.
- **Recovery after raising the budget.**
  1. Run with `promptMaxBytes: 100`. Expected: the session fails with
     `.promptTooLarge` and the backend is not invoked.
  2. Resume with `retryFailedStep = true`, with the node payload changed to
     `promptMaxBytes` large enough to fit after spilling. Expected:
     `.completed`, and the retried execution has
     `promptCompaction.outcome == "spilled"` or no `promptCompaction`.

  The resume request carries the updated `nodePayloads`, as
  `DeterministicWorkflowRunnerFailureStateTests` passes `request()` on resume.
  This confirms the design's residual risk that a retry uses the current
  definition.

### 2. Mock-scenario CLI run (scratch only; nothing committed)

- Author a fixture under
  `tmp/prompt-overflow/pog-05-integration/mock-run/prompt-overflow-fanout/`:
  `workflow.json`, `nodes/*.json` and `mock-scenario.json`.
  - A fanout over 3 items, with branch nodes whose scenario payload includes
    a 30 KB string.
  - A join agent node with `promptMaxBytes: 20000`.
  - Imitate the scenario format in
    `examples/claude-riela-codex-coding/mock-scenario.json` and the fanout
    block in `examples/design-and-implement-review-loop/workflow.json`
    (lines 112-124).
- Run:
  `arch -arm64 /bin/zsh -lc 'swift build && .build/debug/riela workflow run prompt-overflow-fanout --workflow-definition-dir tmp/prompt-overflow/pog-05-integration/mock-run --working-dir tmp/prompt-overflow/pog-05-integration/workdir --mock-scenario tmp/prompt-overflow/pog-05-integration/mock-run/prompt-overflow-fanout/mock-scenario.json --output json' 2>&1 | tee tmp/prompt-overflow/pog-05-integration/mock-run.log`
  - Expected: `"status": "completed"`.
- Evidence:
  - `find tmp/prompt-overflow/pog-05-integration/workdir/tmp/riela-prompt-spill -name '*.json' | tee tmp/prompt-overflow/pog-05-integration/spill-files.txt`
    lists at least one file.
  - `.build/debug/riela session export <sessionId> --output json > tmp/prompt-overflow/pog-05-integration/session-export.json`
    should show the join step's `promptCompaction` if the export includes
    `inputSnapshot`. If the export does not include it, record that fact. The
    runner integration test above is then the authoritative proof of
    evidence.
- If `workflow validate` or the run rejects the fixture shape, fix the
  fixture, not the runtime. Never mirror repository trees into the workdir.

### 3. `README.md`

Add a section "Agent prompt size limits" immediately after the "Session
Observability" section (README `## Session Observability`, about line 491).
Keep it to about 40 lines. It covers:

- the three settings and their defaults, from the design's Configuration
  summary;
- the measured quantity;
- the `$rielaElidedKeys` and `$rielaSameAs` markers;
- the spill stub format and file location;
- the 4096-byte minimum and 256-character preview;
- `inputSnapshot.promptCompaction`;
- `failureKind: promptTooLarge` and the four provider phrases;
- the fact that `riela session resume <id> --retry-failed-step` and
  `rerunOnAdapterFailure` apply to it;
- the new `changeEvidence` fields (`observationCount`,
  `observationOccurrenceCount`, `inlineObservationCount`,
  `observationsTruncated`, `observationsPath`, `observationCountsByBranch`)
  and the fact that `hasDrift` comes from the total.

## Invariants

- The mock run and integration tests write only under
  `tmp/prompt-overflow/pog-05-integration/` and test scratch directories.
- No production source edits, unless they fix an integration defect, which
  must then be recorded with the owning planId.

## Verification (final focused pass)

1. `arch -arm64 /bin/zsh -lc 'swift build' 2>&1 | tee tmp/prompt-overflow/pog-05-integration/build.log`
   must exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "PromptOverflowGuardIntegrationTests|PromptOverflowContractsTests|RuntimeVariablesPromptViewTests|WorkflowFanoutObservationBoundTests|AgentPromptGuardTests|PromptTooLargeRecoveryTests|PromptTooLargeResumeMessageTests|PromptTooLargeRerunTests|WorkflowFanoutMapReduceTests|FanoutArtifactEvidenceRunnerTests|DeterministicWorkflowRunnerFanoutTests|RuntimeVariablesPromptingTests|DeterministicWorkflowRunnerTests|WorkflowOutputContractPreflightTests|DeterministicDirectorTests|WorkGuardDispatcherTests"' 2>&1 | tee tmp/prompt-overflow/pog-05-integration/swift-test.log`
   must exit 0 and show 0 failures.
   - This is the intake's focused test command. The log lives inside this
     plan's artifact root instead of `tmp/prompt-overflow/swift-test.log`,
     so change tracking never snapshots a large log as source.
3. `arch -arm64 /bin/zsh -lc "{ git diff --name-only -z 3f921eb46e0a099b0d849adb62b8fb7ca69eb9af -- '*.swift'; git ls-files --others --exclude-standard -z -- '*.swift'; } | xargs -0 swiftlint lint --strict" 2>&1 | tee tmp/prompt-overflow/pog-05-integration/lint.log`
   must exit 0.
   - This lints the union of tracked changes and untracked new Swift files,
     so new files from waves 1-3 are covered even if serial reconciliation
     has not committed them.
   - After the final commit, the
     `git diff --name-only -z 3f921eb46e0a099b0d849adb62b8fb7ca69eb9af HEAD -- '*.swift'`
     form is equivalent.
4. The mock-scenario run (section 2): `mock-run.log` shows completed, and
   `spill-files.txt` is non-empty.
5. `grep -n "Agent prompt size limits" README.md` must show 1 hit.

## Done Criteria

- The integration tests pass.
- The mock run has completed, with spill evidence captured.
- The README section exists.
- Verification commands 1-5 pass, with every log path and exit code recorded
  in the progress log.
- The lint in step 3 covers every new Swift file from this run, including
  `Tests/RielaCoreTests/PromptOverflowGuardIntegrationTests.swift` and the
  new files from pog-01, pog-02, pog-03 and pog-04. Confirm this in the
  progress log, for example with
  `git ls-files --others --exclude-standard -- '*.swift'` output.

## Overwrite Safety

- Re-read before editing, and hash before and after.
- If a wave-2 file needs a fix, re-read and hash it first, and record the
  owning plan and the reason.
