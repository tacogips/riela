# Issue 117 installed local-command implementation progress

- Plan: `impl-plans/active/issue-117-installed-local-command.md`; workflow mode `issue-resolution`.
- Issue: https://github.com/tacogips/riela/issues/117.
- Branch: `fix/example-contract-migration`; Step 6 owner; no Codex-agent references.
- Status: **blocked and incomplete** at LC-04. The plan's exact direct package-root CLI selection requires a change to read-only `Sources/RielaCLI/WorkflowResolution.swift`. No commit, push, release, or merge was performed.

## Implemented in this attempt

- `Sources/RielaCLI/WorkflowInstalledAddonRequirements.swift`: count name/version dependency candidates before execution-kind eligibility; accept explicit local-command only after existing identity, registry, checksum, digest, scope, summary checks; require canonical contained regular executable entrypoint and return its path.
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`: project that verified path into host requirements and local availability, retaining environment union and native/container behavior. The file is 982 lines.
- `Tests/RielaCLITests/WorkflowInstalledAddonMetadataTests.swift`: use a real three-add-on installed fixture, test three working selection modes, exact paths, local/remote host capabilities and environment, plus missing-kind/mismatch/path rejection. The file is 640 lines.
- `tmp/issue-117-local-command/verify.py`: foreground fixture/CLI driver. It recorded 75/75 example validations, 4/6 exact installed commands, and 16/16 negative CLI commands in attempt 2.
- Per-edit immutable before files, intent, pre/post hashes and diffs are under `tmp/issue-117-local-command/issue-117-installed-local-command/snapshots/attempt-1/`.

## Verification

| Command | Status | Complete log |
| --- | ---: | --- |
| `swift test --filter 'WorkflowInstalledAddonMetadataTests\|WorkflowInstalledLocalCommandTests'` (Xcode binary) | 0; 12 passed, 0 failed | `tmp/issue-117-local-command/issue-117-installed-local-command/attempt-1/test-focused-4.log` |
| `swift test --filter WorkflowHostCapabilityTests` (Xcode binary) | 0; 22 passed, 0 failed | `tmp/issue-117-local-command/issue-117-installed-local-command/attempt-2/test-host.log` |
| `swift build` (Xcode binary) | 0 | `tmp/issue-117-local-command/issue-117-installed-local-command/attempt-1/build.log` |
| Selected-file strict SwiftLint via NUL manifest | 0 | `tmp/issue-117-local-command/issue-117-installed-local-command/attempt-2/lint-selected.log` |
| Repository-wide `/usr/bin/xcrun swiftlint` | 0; 24 baseline warnings outside changed files | `tmp/issue-117-local-command/issue-117-installed-local-command/attempt-2/lint-repository.log` |
| `python3 tmp/issue-117-local-command/verify.py` | 1; 79/81 positives, 16/16 negatives | `tmp/issue-117-local-command/issue-117-installed-local-command/attempt-2/cli-driver.log`; detailed `attempt-2/cli/verification.json` |
| `git diff --check` | 0 | `tmp/issue-117-local-command/issue-117-installed-local-command/attempt-2/diff-check.log` |

The prior driver attempt at `attempt-1/cli/verification.json` failed because the scratch fixture omitted the required `tags` manifest field. Attempt 2 corrected the fixture; it is the current CLI evidence. Two package-root direct-selection commands still fail with `notFound("youtube-flow", [.../youtube-flow/workflow.json not found, .../workflow.json not found])`. `WorkflowResolution.swift:479-488` considers only `<--workflow-definition-dir>/<workflowName>` and the root itself; neither is the package manifest's `workflows/youtube-flow` directory. In-process tests using that declared workflow directory pass. Supporting the exact committed command requires a resolver change outside this plan's `writePaths`.

## Completion criteria and handoff

- LC-01: fixture and regression coverage implemented; planned pre-production failing baseline was not recorded because production edits preceded the new regression run. This remains a plan evidence gap.
- LC-02: verifier and host projection implemented and focused tests pass. The verified value carries the canonical executable path but not the matched descriptor as an explicit property; reconcile this with the plan before completion.
- LC-03: partial adversarial matrix and host coverage pass. Remaining cases in the committed plan need explicit coverage and source-matched final verification after the ownership revision.
- LC-04: blocked by the exact direct package-root selection command; 75 examples and 16 negatives pass, 4 of 6 exact positives pass.
- LC-05: serial reconciliation, independent review, documentation refresh, exact-file staging, commit and non-force push remain downstream. They have not been claimed as Step 6 results.

Resume criterion: revise dispatch/plan ownership to allow `Sources/RielaCLI/WorkflowResolution.swift` or change the accepted exact CLI command to the declared installed workflow directory after design review. Then finish missing assigned test cases, rerun all gates on the final source, and reconcile snapshot intent before review.
