# ar-02-core-planners implementation progress

- Workflow mode: `issue-resolution`.
- Issue reference: `workflowInput:automatic-config-driven-retention` (no GitHub issue URL/number).
- Codex agent: `/root`, Step 6 implementation owner for `ar-02-core-planners`.
- Branch: `feat/automatic-retention` in `tmp/automatic-retention-worktree`.
- Plan: `impl-plans/completed/automatic-retention-02-core-planners.md`.
- Design: `design-docs/specs/design-automatic-retention.md`, §§4.1 and 4.4.
- Dependency decision: `dependsOn: []`; ready to implement.

## Implementation

- `Sources/RielaCore/TerminalRetentionPlan.swift`: added `workflows` and `allExcept` scopes; `results` and `messages` byte selection; separate family message byte totals; optional age/cap; eligible families; bounded family selection and `keptWorkflow` protection. The legacy API keeps its original validation limits and delegates to the new planner.
- `Sources/RielaCore/RielaLogRetentionPlan.swift`: added a filesystem-independent planner with age/cap selection, 24-hour grace, oldest-first ordering, stable name ties, protected entry counts, and removal bounds.
- `Tests/RielaCoreTests/TerminalRetentionPlanTests.swift`: added nine behavioral cases covering scope, age, cap, safety protections, byte kind, zero-message skipping, work limits, eligible ordering, validation, and legacy parity.
- `Tests/RielaCoreTests/RielaLogRetentionPlanTests.swift`: added six behavioral cases covering age, cap, grace, protected kinds, work limits, stable ties, and validation.
- No executor or CLI wiring was pulled into this plan.

## Verification

Final source verification:

| Command | Exit | Tests run | Failures | Complete log |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetentionPlanTests\|RielaLogRetentionPlanTests" > tmp/automatic-retention/ar-02-core-planners/test-rerun-001.log 2>&1'` | 0 | 20 | 0 | `tmp/automatic-retention/ar-02-core-planners/test-rerun-001.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/automatic-retention/ar-02-core-planners/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-02-core-planners/changed-swift-files.nul; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | 0 | n/a | n/a | `tmp/automatic-retention/ar-02-core-planners/swiftlint-rerun.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter TerminalRetentionTests > tmp/automatic-retention/ar-02-core-planners/cli-regression.log 2>&1'` | 0 | 11 | 0 | `tmp/automatic-retention/ar-02-core-planners/cli-regression.log` |
| `git diff --check` | 0 | n/a | n/a | command output empty |

The original focused planner run is preserved at `tmp/automatic-retention/ar-02-core-planners/test.log` (exit 1, 20 tests, 6 failures caused by fixture expectations). The fixtures were corrected and the final source-matched rerun above passes all 20 tests.

## Completion and handoff

- Assigned planner implementation and behavioral verification are complete.
- No implementation blockers or unresolved findings in this plan.
- Formal test-integrity and adversarial review, integration updates, staging, and local commit are downstream workflow steps and remain pending.

Final source hashes:

- `Sources/RielaCore/TerminalRetentionPlan.swift`: `62ee29ca937fc3e24695c09a76ff542f2c87d54442795a688406d22a2662e756`
- `Sources/RielaCore/RielaLogRetentionPlan.swift`: `798f42a42da1acf56445c9070580b0befb9cfe1df95fb82fa0182b5090ba3147`
- `Tests/RielaCoreTests/TerminalRetentionPlanTests.swift`: `4a53c1e6038507dcd7467700e53e1a3936e74c68ad437b8f75ca85a7e303766a`
- `Tests/RielaCoreTests/RielaLogRetentionPlanTests.swift`: `83fe3cd2c5aaf639c7c4bcc0ac1dd374c1d213ff95132c80b35d8b9261572c85`
