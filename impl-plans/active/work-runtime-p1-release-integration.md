# p1-release-integration

Status: authored; Step 5 review pending; implementation not started.

```json
{
  "planId": "p1-release-integration",
  "planPath": "impl-plans/active/work-runtime-p1-release-integration.md",
  "dependsOn": [
    "p1-release-cli",
    "p1-release-runtime"
  ],
  "writePaths": [
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/README.md",
    "impl-plans/progress/p1-dispatch.md",
    "impl-plans/progress/p1-release-integration.md",
    "impl-plans/active/work-runtime-p1-release-cli.md",
    "impl-plans/active/work-runtime-p1-release-runtime.md",
    "impl-plans/active/work-runtime-p1-release-integration.md",
    "impl-plans/completed/work-runtime-p1-release-cli.md",
    "impl-plans/completed/work-runtime-p1-release-runtime.md",
    "impl-plans/completed/work-runtime-p1-release-integration.md"
  ],
  "sharedPaths": [
    "Tests/RielaCLITests/DoctorCommandTests.swift",
    "Tests/RielaCLITests/WorkflowCommandCatalogTests+Temporary.swift",
    "Tests/RielaCLITests/ScopedParityCallStepFanoutTests.swift",
    "Tests/RielaCLITests/WorkflowCommandCatalogTests.swift",
    "Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift",
    "Tests/RielaCLITests/WorkflowCommandInspectionTests.swift",
    "Tests/RielaCLITests/WorkflowCommandTests.swift",
    "Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift",
    "Tests/RielaWorkTests/WorkGuardDispatcherTests.swift",
    "Tests/RielaCoreTests/DeterministicWorkflowRunnerAdmissionTests.swift"
  ],
  "progressLogPath": "impl-plans/progress/p1-release-integration.md"
}
```

## Intent, authority and non-goals

Make the accepted P1 runtime release-ready by resolving the 21 historical
assertions in 19 cases, without weakening the tested contracts. Mode:
`issue-resolution`. Issue: local request for `tacogips/riela`, Draft PR #113,
no GitHub issue number supplied. Branch: `fix/work-runtime-p1-release`;
original checkpoint: `a026356eeddcff94eaa82db2cfec09090620c81f`.
Source of truth: `design-docs/specs/design-work-runtime-consolidation.md`
§17.13, accepted by Step 3 `comm-000004`, decision `accept`, no findings,
in `codex-design-and-implement-review-loop-session-1`. Codex-agent references:
`[]`; Cursor behavior mapping: not applicable. No Step 5 feedback supplied.

Do not touch PRs #109/#112, T2–T6 WIP, Monja, archived rielflow or another
session's work. No extra worktrees/private branches, main merge, release,
new abstractions, broad formatting, deleted tests, assertion muting, broad
skips or unsupported expectation changes. Do not rediscover the executing
workflow's registry/provenance. No package/workflow/prompt/skill changes are
planned. The ARM64 Homebrew release path is future work.

Read the historical assertion arrays and complete logs under
`tmp/work-runtime-p1-7a-native-a2-a5/plans/p1-dispatch/attempt-6/`:
`V5-comparison.json`, `full-comparison.json`, `V5-work-cli-core.log`,
`full-suite-no-parallel.log`, and `impl-plans/progress/p1-dispatch.md`.
The old 2,061-test aggregate and 2,717-case full suite (two skips) exited 1;
baseline equality is not a pass. Ledger IDs below are §17.13 IDs.

## Ownership, execution and evidence protocol

Before native implementation dispatch, the serial workflow owner must obtain
Step 5 acceptance, commit the accepted design and all three plans as an exact
allowlist, and non-force push that checkpoint on this same branch. Record the
hash and clean source/test diff against the original P1 checkpoint. A failed
checkpoint push stops dispatch. This Step 4 authors plans only, without
premature publication. Workers never perform Git writes.

Before each edit, freshly read the file; capture its SHA-256 and immutable
preimage plus a separate intent snapshot under
`tmp/p1-release-remediation/<planId>/edits/<unique-edit-id>/`. Record the
specific assertion IDs, intended change and contract evidence. Check the hash
again immediately before writing; on drift, re-read and reconcile instead of
restoring an older whole file. Save postimage/hash and exact diff. Never
replace another worker's changes from memory. At join, the serial owner audits
all pre/post hashes, intents and runtime change evidence, repairs any lost
intent, and re-verifies the combined tree. Disjoint paths alone do not prove
that overwrites did not occur.

Each worker writes only its listed test paths and its own progress log. New
paths or production repairs require a recorded ownership amendment with exact
paths, cause and contract proof, followed by serial scheduling and focused
review; do not silently expand scope or stop at a fixture-only workaround.
Shared indexes, lockfiles, formatting, global archiving and shared docs belong
to the serial owner. No speculative file splitting; retain files below 1,000
lines by keeping new regressions focused, and use meaningful responsibility
files only if actually necessary and added to the ownership amendment.

Run shell commands in the foreground. Record argv, cwd, toolchain, source
revision and working-tree diff hash, start/end, complete stdout/stderr log,
terminal exit status, test totals/failures and each named skip. Evidence lives
only under `tmp/p1-release-remediation/`; retain evidence for review, remove
throwaway intermediates when done, and never stage tmp files. Poll any tool
session through exit; incomplete logs never pass. Use a foreground wrapper
that preserves the command status (for example Python subprocess.run with
stdout/stderr directed to a log), not a pipeline that masks it.

Set this environment before every Swift command:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
export PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
swift --version
```

Use one serial verification owner for the shared scratch build; never run
concurrent SwiftPM or lint processes against it. Independent edits may run in
parallel, but each focused gate uses a quiescent source snapshot and records
its hash. A source edit during a test invalidates that receipt and requires
rerunning that gate. Swift build/tests provide typechecking; there is no web
or UI change requiring browser verification.

Progress log entries must include plan ID, actual execution/agent reference,
assertion IDs, completed/pending tasks, file hashes/intents, command/log/exit
records, exact counts/skips, findings and residual risk. Check off a task only
with evidence; do not count future reviews or publication as already complete.

The serial owner may edit `sharedPaths` only after both predecessors finish,
solely to reconcile accepted intents or reviewed repairs. `writePaths` holds
its exclusive docs/progress/archival ownership. It must not overwrite workers
while they are active. Wave 1 contains `p1-release-cli` and `p1-release-runtime`;
wave 2 contains `p1-release-integration`. No other historical active plan is
part of this dispatch.

## Tasks, deliverables and dependencies

- [ ] I1 / serial join: Wait for both accepted predecessor plan outcomes.
  Audit runtime change evidence, every pre/post hash and immutable intent.
  Re-read all ten test paths; reconcile any overwritten or omitted intent.
  Consolidate a 21-row ledger under this plan's evidence directory mapping
  IDs to causes, contract proof, changed paths, regression test and command.
  Do not treat the worker's status alone as evidence. No row may be unclassified.
- [ ] I2 / bounded production repair, only if needed: Resolve any cause
  escalated by a predecessor. For each proven production violation, append an
  exact source/test write-path amendment and rationale to this plan before
  editing, obtain the affected contract review if the accepted decision changes,
  make only that correction, and rerun its regression. Expected initial edits
  are test-only; do not pre-author a usage redesign or grant a broad source
  allowlist. A repair remaining unresolved keeps implementation incomplete.
- [ ] I3 / current combined-source gates: Run the commands below serially on
  a stable combined tree. Require every gate to exit 0 and report actual test
  totals, failures, named skips and reasons. Historical matching failures are
  not acceptable. Rerun affected gates after any source/test repair; seal the
  final source/test/config inputs and diff. Do not reuse logs from a changing
  tree. Verify selected suites include native remote dispatch/receiving paths
  in TaskDispatcherIntegrationTests and adapter/server/GraphQL coverage.
- [ ] I4 / downstream formal review: Obtain independent test-integrity
  acceptance of all fixture/expectation changes and the 21-row ledger, one
  independent Sol adversarial acceptance and Astra combined-tree integration
  acceptance. Record real execution references, reviewed hash/diff, decisions,
  findings and evidence paths. Earlier P1 approvals do not satisfy this gate.
  Reconcile findings serially and reverify/review material changes.
- [ ] I5 / downstream docs: After acceptance, update `README.md`,
  `design-docs/specs/design-work-runtime-consolidation.md` §17.13 and
  `impl-plans/progress/p1-dispatch.md` with current evidence and remaining release
  constraints. Update `impl-plans/README.md` with these plans' actual status.
  Read `.codex/skills/riela-impl-workflow/SKILL.md`; no change is anticipated.
  Archive only these three plans under `impl-plans/completed/` once the workflow
  reaches its documentation/finalization gate; leave unrelated plans/indexes
  untouched. Maintain links and exact publication status, not premature claims.
- [ ] I6 / downstream publication: Prepare a Draft PR #113 description with
  contract repairs, exact test counts/skips, commands/log references, three
  review decisions, residual risks and no-merge/no-release gates. Use a body
  file under tmp. Commit only the exact accepted source/test/docs/progress
  allowlist through workflow finalization, then non-force push the accepted
  hash on `fix/work-runtime-p1-release`. Verify local/remote/PR head equality
  and `isDraft: true`; edit only PR #113. Never stage all files indiscriminately.

I1–I3 and this plan's progress log define Step 6 implementation completeness.
I4–I6 are explicitly later workflow gates and do not cause Step 6 to self-block
once its assigned repairs and behavioral checks pass. Overall completion still
requires I4–I6. Workers cannot self-certify independent review or publication.

## Exact verification commands

Use the common Xcode environment and foreground log/status protocol. Run:

```sh
swift build --scratch-path tmp/p1-release-remediation/build --product riela
swift test --scratch-path tmp/p1-release-remediation/build --filter 'DoctorCommandTests|WorkGuardDispatcherTests|WorkflowCommandCatalogTests|WorkflowCommandTests|WorkflowTemporaryRegistrationTests|WorkflowRunnerAdmissionTests'
swift test --scratch-path tmp/p1-release-remediation/build --filter 'TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskDispatcherTests|WorkGuardDispatcherTests|AgentDirectorTests|AgentDirectorStoreTests|DeterministicDirectorTests'
swift test --scratch-path tmp/p1-release-remediation/build --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests'
swift test --scratch-path tmp/p1-release-remediation/build --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'
swift test --scratch-path tmp/p1-release-remediation/build --no-parallel
```

Run the combined strict lint gate:

```sh
/usr/bin/xcrun swiftlint lint --strict --no-cache Tests/RielaCLITests/DoctorCommandTests.swift Tests/RielaCLITests/WorkflowCommandCatalogTests+Temporary.swift Tests/RielaCLITests/ScopedParityCallStepFanoutTests.swift Tests/RielaCLITests/WorkflowCommandCatalogTests.swift Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift Tests/RielaCLITests/WorkflowCommandInspectionTests.swift Tests/RielaCLITests/WorkflowCommandTests.swift Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift Tests/RielaWorkTests/WorkGuardDispatcherTests.swift Tests/RielaCoreTests/DeterministicWorkflowRunnerAdmissionTests.swift
```

Append any changed Swift paths from an accepted amendment. Preserve the concrete argv in evidence; this is the
strict changed-file gate, not a repository-baseline waiver. Run
`git diff --check` before acceptance and `git diff --cached --check` on the
exact publication allowlist. Both must exit 0. Missing SwiftLint or an
incomplete test run is an unresolved verification gate, not success.

After authorized publication, use read-only commands:

```sh
git branch --show-current
git rev-parse HEAD
git ls-remote --heads origin fix/work-runtime-p1-release
gh pr view 113 --repo tacogips/riela --json number,isDraft,headRefName,headRefOid,baseRefName
```

Require branch/head equality, base `main` and Draft status. Capture full logs
and exit statuses. If remote publication cannot complete, report exact pending
state; do not claim release readiness has been published.

## Acceptance and residual risks

All 21 rows are classified, repaired at the intended boundary and covered;
all focused, native integration and both broad gates pass on current source;
strict changed-file lint and diff checks pass. No failed assertion becomes
successful by baseline attribution or a broad skip. Explain the historical
opt-in provider and SDL-regeneration skips if they recur; any new skip requires
specific justification and cannot conceal these 21 assertions. Record exact
current counts rather than assuming historical totals. The usage cause remains
an investigation item until C6 supplies diagnostic proof. Fixture-only repairs
still require independent integrity review. There is no new user decision,
external reference mapping or architecture task.
