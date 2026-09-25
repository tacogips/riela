# p1-release-runtime

Status: independently accepted predecessor; no implementation redispatch. Metadata amendment awaits Step 5.

```json
{
  "planId": "p1-release-runtime",
  "planPath": "impl-plans/active/work-runtime-p1-release-runtime.md",
  "dependsOn": [],
  "writePaths": [
    "Tests/RielaWorkTests/WorkGuardDispatcherTests.swift",
    "Tests/RielaCoreTests/DeterministicWorkflowRunnerAdmissionTests.swift",
    "impl-plans/progress/p1-release-runtime.md"
  ],
  "sharedPaths": [],
  "progressLogPath": "impl-plans/progress/p1-release-runtime.md"
}
```

## Intent, authority and non-goals

Make the accepted P1 runtime release-ready by resolving the 21 historical
assertions in 19 cases, without weakening the tested contracts. Mode:
`issue-resolution`. Issue: local request for `tacogips/riela`, Draft PR #113,
no GitHub issue number supplied. Branch: `fix/work-runtime-p1-release`;
continuation checkpoint: `32163111b6e9f31b91d1e95e535c115e9f798890`.
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

## Continuation state and dispatch contract

Step 3 `comm-000004` accepted the catalog amendment without findings. Step 5
review of this plan amendment is pending. Issue title: “Complete P1 release
remediation after chat reply catalog ownership finding”. Preserve all nine
dirty test files and both progress files from the intake; do not reset or
reimplement them. No x64 or App Store work is authorized. Diff minimization
against main is not a gate. Runtime acceptance is carried from the intake and
`impl-plans/progress/p1-release-runtime.md`: IDs 08/19, 16/16 focused tests,
zero skips, exit 0, plus independent test-integrity/Sol/Astra partial acceptance.
That acceptance is a predecessor result, not final-tree acceptance.
CLI retains 18 repaired assertions but its previous focused gate exited 1:
165 tests, 164 passed, ID 14 failed, zero skips. The complete prior logs are
`tmp/p1-release-remediation/p1-release-cli/attempt-1/focused.log` and
`tmp/p1-release-remediation/p1-release-cli/attempt-1/usage-diagnostic.log`.

Carry `p1-release-runtime` into native scheduling as already accepted; never
redispatch its implementation. Dispatch only pending `p1-release-cli`, then
`p1-release-integration` after CLI acceptance and the carried runtime acceptance.
The dispatch manifest's continuation fields document this handoff; the serial
owner must supply the accepted predecessor through the runtime's native
accepted-dependency mechanism, not treat metadata alone as runtime acceptance.
Keep actual execution references and prior evidence attached to that handoff.
No parallel source edits are useful in this bounded continuation. Read-only
investigation may overlap; build, lint, source changes and Git remain serial.

## Ownership, execution and evidence protocol

Before native implementation dispatch, the serial workflow owner must obtain
Step 5 acceptance, commit and non-force push only this reviewed checkpoint
allowlist on `fix/work-runtime-p1-release`:

- `design-docs/specs/design-work-runtime-consolidation.md`
- `impl-plans/active/work-runtime-p1-release-cli.md`
- `impl-plans/active/work-runtime-p1-release-runtime.md`
- `impl-plans/active/work-runtime-p1-release-integration.md`
- `impl-plans/active/p1-release-remediation-dispatch.json`

Record HEAD, the retained dirty source/test diff hash and untracked progress
hashes before and after checkpoint publication. Do not require a clean tree,
include retained implementation edits in this checkpoint, or run concurrent Git
operations. A failed checkpoint push stops dispatch. Step 4 authors only;
workers never perform Git writes. Final implementation publication follows
current-source tests and independent reviews.

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

Each worker writes only its exact listed source/test paths and its own progress log. New
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
concurrent SwiftPM or lint processes against it. This continuation uses serial edits; each focused gate uses a quiescent
source snapshot and records its hash. A source edit during a test invalidates that receipt and requires
rerunning that gate. Swift build/tests provide typechecking; there is no web
or UI change requiring browser verification.

Progress log entries must include plan ID, actual execution/agent reference,
assertion IDs, completed/pending tasks, file hashes/intents, command/log/exit
records, exact counts/skips, findings and residual risk. Check off a task only
with evidence; do not count future reviews or publication as already complete.

## Tasks and file-level deliverables

The following historical deliverables are accepted, as recorded in
`impl-plans/progress/p1-release-runtime.md`; preserve them without new edits.
Final-source runtime reruns belong to the integration owner.

- [x] R1 / ID 08: Read `Sources/RielaWork/TaskGuardCoordinator.swift` and
  `Sources/RielaWork/WorkStore+Decisions.swift`. In
  `Tests/RielaWorkTests/WorkGuardDispatcherTests.swift`, construct the failing
  fail-policy fixture with a persisted running task attempt, runtime session
  and execution, and the matching live inactivity observation. Use fixed
  dates and existing fixture helpers. Retain stop/failed semantics and verify
  no pending rerun is created. Preserve/add a stale heartbeat observation
  rejection regression and prove rejected application leaves task/attempt
  decisions unchanged at the transactional boundary; account for any guard
  evidence persisted before that boundary rather than asserting unsupported
  whole-operation rollback. Do not weaken production freshness checks.
- [x] R2 / ID 19: Read `Sources/RielaCore/DeterministicWorkflowRunner.swift`
  and its lifecycle validation. In
  `Tests/RielaCoreTests/DeterministicWorkflowRunnerAdmissionTests.swift`, supply
  a valid codex-agent payload with explicit sandbox. Assert the admission
  callback was actually reached and its specific rejection surfaced, a created
  session remains with no executions, and the adapter never ran. Use a small
  local counting/failing test adapter if necessary. Preserve a validation
  rejection control proving invalid input cannot masquerade as admission.
- [x] R3: Record both assertion rows, contract anchors, fixture state and
  focused outcomes in this plan's progress log. If valid state still exposes
  a production defect, produce a minimal failing regression and exact path
  ownership amendment for serial repair; never mute the failing assertion.

## Invariants and acceptance

Only an exact current running observation can authorize inactivity decisions.
Failure policy stops rather than reruns. Validation occurs before creation and
admission; admission rejection occurs before node side effects. Tests must
prove which boundary actually rejected, not only that something threw.
Both historical rows and relevant stale/no-effect negative controls pass.

## Verification commands and completion

For final-source regression only, the integration owner runs these commands;
this does not reopen the accepted runtime implementation:

```sh
swift test --scratch-path tmp/p1-release-remediation/build --filter 'WorkGuardDispatcherTests|WorkflowRunnerAdmissionTests'
/usr/bin/xcrun swiftlint lint --strict --no-cache Tests/RielaWorkTests/WorkGuardDispatcherTests.swift Tests/RielaCoreTests/DeterministicWorkflowRunnerAdmissionTests.swift
git diff --check
```

Require exit 0, positive test counts, zero failures and no skip masking either
row. R1–R3 plus regressions, lint and progress evidence complete this branch's
Step 6 work. Broad verification and formal review remain downstream.
