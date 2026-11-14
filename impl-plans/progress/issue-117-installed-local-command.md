# Issue 117 installed local-command implementation progress

- Plan: `impl-plans/completed/issue-117-installed-local-command.md`; workflow mode `issue-resolution`.
- Issue: https://github.com/tacogips/riela/issues/117.
- Branch: `fix/example-contract-migration`; Step 6 owner; no Codex-agent references.
- Status: **implementation and Step 8 documentation complete**; the former package-root blocker below is historical. Independent and integration reviews accepted the repaired scope evidence with no blocking finding. Exact-file commit and non-force push remain downstream. No release or merge was performed.

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

## Resumption from checkpoint `ab17d843` (attempt 3)

The accepted design and revised plan resolve the historical blocker: direct
selection names the declared `workflows/youtube-flow` directory, not the package
root. The earlier 79/81 CLI run remains failed historical evidence. No production
Swift file was changed in this resumption. `WorkflowResolution.swift` remains
untouched. The WIP verifier counts candidates before kind filtering, checks owner,
registry, lock, checksum, digest, scope, summary and executable containment, and
projects the canonical executable into both requirement and local availability.

| Task | Status | Current evidence |
| --- | --- | --- |
| LC-01 | completed | Fresh design/plan/source/fixture audit; attempt-3 focused baseline 12/12. Historical pre-production baseline remains unavailable and is not claimed. |
| LC-02 | completed | Retained WIP verifier/projection after code audit and passing focused tests; no production repair needed. |
| LC-03 | completed | Unit tests cover three selection modes, host environment/executable/remote isolation, callee ownership, native/container behavior; CLI driver now exercises the full isolated negative matrix below with both validate and inspect. |
| LC-04 | completed | `attempt-3/cli/verification.json`: 81/81 positives (six installed, 75 examples), 52/52 expected negative exits with `unresolvedAddonExecutable` diagnostics. Complete command logs and numeric exits are in each record. |
| LC-05 | completed for implementation handoff | Compared retained WIP intent/snapshots with current source and accepted plan; no drift or lost production behavior found. Current resumption intent and hashes are in `snapshots/attempt-3/`. Formal review, documentation finalization, commit and push remain downstream. |

LC-03 rejection coverage: existing local-command unit assertions cover missing
kind, owner registry/digest, summary kind, missing/non-executable/directory/
absolute/traversal/symlink entrypoints, unknown reference and missing-kind
ambiguity. The attempt-3 CLI driver additionally covers descriptor kind,
node/lock/package version, package identity, dependency/package-lock registry,
content digest, package checksum/integrity, summary digest/kind/source path,
ordinary ambiguity, unrelated authored copy, explicit scope conflict and
project-to-user scope substitution. Each mutation rebuilds the fixture, and
dependency file/path mutations refresh the unrelated package checksum and lock
checksum. Host-injected unit coverage supplies environment, distinct executable
keys and remote-host rows without network probes or payload execution.

Attempt-3 exact gate log and exit files are under
`tmp/issue-117-local-command/issue-117-installed-local-command/attempt-3/`:

| Gate | Numeric exit | Result | Complete log |
| --- | ---: | --- | --- |
| Xcode Swift `test --filter 'WorkflowInstalledAddonMetadataTests\|WorkflowInstalledLocalCommandTests'` | 0 | 12 passed, 0 failed | `test-focused.log` |
| Xcode Swift `test --filter WorkflowHostCapabilityTests` | 0 | 22 passed, 0 failed | `test-host.log` |
| Xcode Swift `build` | 0 | compilation passed | `build.log` |
| Selected-file strict SwiftLint | 0 | empty NUL manifest; no Swift edits this attempt | `lint-selected.log` |
| Xcode-environment `/usr/bin/xcrun swiftlint` | 0 | 24 pre-existing warnings, 0 serious, 976 files | `lint-repository.log` |
| `python3 tmp/issue-117-local-command/verify.py` | 0 | 81/81 positives, 52/52 negatives | `cli-driver.log`; `cli/verification.json` and per-command stdout/stderr |
| `git diff --check` | 0 | whitespace check passed | `diff-check.log` |

The CLI driver records checkpoint HEAD `ab17d8438930d07b44c81db764b27653e1c62fea`,
binary SHA-256 and its then-current tracked diff SHA-256. The source binary hash
was unchanged by the subsequent build. `attempt-3/identity.json` records the
final source/configuration identities and gate exits. The earlier WIP source
changes and progress log remain preserved. No package registry or sibling
worktree was modified; no release or merge is authorized.

## Review feedback repair (attempt 4)

The mid-severity LC-03 finding was valid: the former scope-substitution
fixtures copied a user dependency without `home/.riela/riela-lock.json`, so
project-scope rejection did not prove isolation from a usable user install.
`Tests/RielaCLITests/WorkflowInstalledAddonMetadataTests.swift` now builds a
user-scope owner and dependency with a matching user lock, changes the copied
owner's add-on locks to `sourceScope: user`, and proves user-scope validate and
inspect succeed before removing the project dependency and asserting both
project-scope commands reject it. `tmp/issue-117-local-command/verify.py` uses
the same construction and records all four CLI commands independently. No
production Swift, design, plan, dispatch, or package manifest was changed.

LC-01 through LC-05 remain complete for implementation handoff. The attempt-4
matrix has 81/81 required positives, two additional user-scope precondition
positives, and 52/52 expected negative exits, including both project-scope
substitution rejections with `unresolvedAddonExecutable`. Its 135 records each
have a numeric exit, complete stdout/stderr paths, and no assertion errors.
The historical pre-production failing baseline remains unavailable.

| Gate | Exit | Result | Complete attempt-4 log |
| --- | ---: | --- | --- |
| Xcode Swift focused `test --filter 'WorkflowInstalledAddonMetadataTests\|WorkflowInstalledLocalCommandTests'` | 0 | 12 passed, 0 failed | `test-focused-final.log` |
| Xcode Swift `test --filter WorkflowHostCapabilityTests` | 0 | 22 passed, 0 failed | `test-host.log` |
| Xcode Swift `build` | 0 | compilation passed | `build.log` |
| Selected-file `swiftlint lint --strict --quiet --no-cache` | 0 | changed Swift test file, zero diagnostics | `lint-selected.log` |
| Xcode-environment `/usr/bin/xcrun swiftlint` | 0 | 24 unchanged baseline warnings, zero serious | `lint-repository.log` |
| `python3 tmp/issue-117-local-command/verify.py` | 0 | 83 positive exits, 52 negative exits | `cli-driver.log`; `cli/verification.json` and per-command logs |

The attempt-4 before-file snapshots and edit intent are in
`snapshots/attempt-4/`. Final source, binary, configuration, and gate exit
identities are recorded in `attempt-4/identity.json`. Formal independent review,
shared documentation/index reconciliation, exact-file staging, commit, and
non-force push remain downstream workflow work.

## Step 8 documentation and archive

The accepted review followed the attempt-4 repair; `/root/coverage_audit` and
`/root/evidence_audit` supplied read-only audits. Integration review accepted
the final source without blocking findings. `README.md` now describes installed
local-command validation and host requirements. This plan was moved to
`impl-plans/completed/issue-117-installed-local-command.md`; the plan index,
dispatch paths, and design status were refreshed. The implementation workflow
skill was reviewed and its existing documentation-refresh contract remains
accurate. Browser E2E was skipped because no browser-facing file changed.
The missing historical pre-production baseline remains a residual evidence gap.
