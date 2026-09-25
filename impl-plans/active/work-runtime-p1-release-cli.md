# p1-release-cli

Status: continuation pending; C1–C5/C7 retained; C6/C8 pending; amended ownership awaits Step 5.

```json
{
  "planId": "p1-release-cli",
  "planPath": "impl-plans/active/work-runtime-p1-release-cli.md",
  "dependsOn": [],
  "writePaths": [
    "Tests/RielaCLITests/DoctorCommandTests.swift",
    "Tests/RielaCLITests/WorkflowCommandCatalogTests+Temporary.swift",
    "Tests/RielaCLITests/ScopedParityCallStepFanoutTests.swift",
    "Tests/RielaCLITests/WorkflowCommandCatalogTests.swift",
    "Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift",
    "Tests/RielaCLITests/WorkflowCommandInspectionTests.swift",
    "Tests/RielaCLITests/WorkflowCommandTests.swift",
    "Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift",
    "impl-plans/progress/p1-release-cli.md",
    "Sources/RielaAddons/RielaAddons.swift",
    "Tests/RielaAddonsTests/AddonExecutionContractsTests.swift"
  ],
  "sharedPaths": [],
  "progressLogPath": "impl-plans/progress/p1-release-cli.md"
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

C1–C5 and C7 below describe retained completed edits. Confirm their intent and
rerun their tests; do not rewrite them unless current evidence proves a defect.
C6 and C8 are the remaining implementation tasks.

- [x] C1 / IDs 01–07: In `Tests/RielaCLITests/DoctorCommandTests.swift`, make
  its JSON consumer decode the canonical ISO-8601 date format. Confirm against
  `Sources/RielaCLI/RielaCLIApplication.swift`. Assert a present valid observedAt
  and retain all seven backend/readiness checks. Do not accept numeric and
  string date formats interchangeably or change production wire output.
- [x] C2 / IDs 09–10: In `Tests/RielaCLITests/WorkflowCommandCatalogTests+Temporary.swift`,
  replace the root `.build/debug/riela` assumption with discovery of the riela
  executable from the current test build location (including scratch-path).
  Use existing test-executable discovery conventions where available. Require
  an executable before launching; keep a genuine separate CLI process and
  isolated test HOME, registration and persisted catalog checks. No stale
  binary fallback, skip or in-process substitution. Build the product in the
  same scratch path before running the test.
- [x] C3 / ID 11: In `Tests/RielaCLITests/ScopedParityCallStepFanoutTests.swift`,
  set explicit sandbox permission appropriate to branch write/change tracking.
  Keep fanout effects/completion and call-step stopping assertions. Reference
  the existing missing-sandbox rejection regression in the ledger, or add a
  focused negative case in the same file if no such coverage exists.
- [x] C4 / IDs 12,15–18: In `Tests/RielaCLITests/WorkflowCommandCatalogTests.swift`
  (invalid session policy) and
  `Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift`
  (four runtime/cross-workflow errors), require failure for error-severity
  capability gaps and assert the specific expected diagnostic path and meaning,
  while decoding and checking the structured summary. Read
  `Sources/RielaCLI/WorkflowValidateInspectCommands.swift` before changing
  expectations. Preserve validation assertions and provide/reference a valid
  success control; arbitrary nonzero exits are insufficient.
- [x] C5 / ID 13: In `Tests/RielaCLITests/WorkflowCommandInspectionTests.swift`,
  replace the project-installed orchestration workflow dependency with a
  self-contained valid authored fixture carrying manager input/output
  descriptions. Assert callable step, manager role and both descriptions.
  Do not inspect or modify the executing workflow installation.
- [ ] C6 / ID 14: Freshly read `Sources/RielaCLI/ProductionNodeAdapter.swift`
  (`executeChatReplyWorker` accepts version `1` or nil),
  `Sources/RielaCLI/WorkflowValidateInspectCommands.swift` (catalog projection),
  and `Sources/RielaCore/WorkflowRequirements.swift` (unresolved rejection).
  In `Sources/RielaAddons/RielaAddons.swift`, add exactly the existing built-in
  name `riela/chat-reply-worker` with version `1` to the catalog. Preserve all
  lookup semantics and existing descriptors. No adapter or resolver edit.
  In `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`, add focused
  catalog assertions for exact descriptor name/version, supported version `1`,
  omitted-version support, unsupported-version rejection and unknown-name
  rejection. Retain the existing unknown-resolver regression. Keep the real
  `examples/matrix-chat-reply/workflow.json` and ID 14 success/source-metadata
  assertions in `Tests/RielaCLITests/WorkflowCommandTests.swift`; no substitute
  add-on, skip, relaxed diagnostic or unrelated fixture rewrite. The accepted
  design now supplies the production contract proof and exact path amendment;
  Step 5 acceptance is required before edits. Show the new catalog regression
  failing before the descriptor addition, then passing after it. Store both
  complete logs/statuses under a new attempt directory without overwriting
  attempt-1 evidence. The expected red receipt is not a passing gate.
- [x] C7 / IDs 20–21: In
  `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift`, supply
  a resolvable add-on specifically for the package-metadata-ignore test rather
  than changing unrelated helper users blindly. Retain validation/inspection
  success, mutable authored provenance, absent package identity, mutation and
  history assertions. Preserve or add an unresolved-addon negative control;
  do not make ignored package metadata resolve an otherwise missing executable.
- [ ] C8: Complete all 19 owned assertion rows with cause, contract anchor,
  exact changed path and focused regression result. Add positive/negative
  regressions above only where existing tests do not already establish them.

## Invariants and acceptance

Canonical dates, sandbox validation and error-severity exit behavior remain
strict. Metadata tests are independent of user/project installation state.
Subprocess tests execute the current build. Add-on availability is real rather
than hidden behind suppressed diagnostics. All existing intended assertions
remain effective and all 19 owned assertion rows pass with contract evidence.

## Verification commands and completion

After edits and with exclusive build ownership, capture complete logs for:

```sh
swift build --scratch-path tmp/p1-release-remediation/build --product riela
swift test --scratch-path tmp/p1-release-remediation/build --filter AddonExecutionContractsTests
swift test --scratch-path tmp/p1-release-remediation/build --filter WorkflowHostCapabilityTests
swift test --scratch-path tmp/p1-release-remediation/build --filter 'DoctorCommandTests|WorkflowCommandCatalogTests|WorkflowCommandTests|WorkflowTemporaryRegistrationTests'
/usr/bin/xcrun swiftlint lint --strict --no-cache Tests/RielaCLITests/DoctorCommandTests.swift Tests/RielaCLITests/WorkflowCommandCatalogTests+Temporary.swift Tests/RielaCLITests/ScopedParityCallStepFanoutTests.swift Tests/RielaCLITests/WorkflowCommandCatalogTests.swift Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift Tests/RielaCLITests/WorkflowCommandInspectionTests.swift Tests/RielaCLITests/WorkflowCommandTests.swift Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift Sources/RielaAddons/RielaAddons.swift Tests/RielaAddonsTests/AddonExecutionContractsTests.swift
git diff --check
```

Require exit 0, positive selected-test totals, zero failures and no skips
masking owned rows. Log the actual executed command and file list. C1–C8,
regressions, lint and the worker progress log complete this branch's Step 6
assignment. Final broad tests, independent reviews, shared docs and publication
belong to the dependent serial plan and later workflow gates.

Catalog and host-capability gates must select positive test counts and exit 0.
`WorkflowHostCapabilityTests.testInspectProjectionFailureIsVisibleAndUsageAliasIsEquivalent`
preserves unknown-add-on rejection for inspect and usage. Catalog regression
proves version matching without injecting an allowlist. The CLI ID 14 gate
proves real Matrix usage resolution and source metadata without network sends.
For strict lint, also save the exact changed Swift path list as NUL-delimited
`tmp/p1-release-remediation/p1-release-cli/catalog-continuation/changed-swift.nul`, then run
`xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/p1-release-remediation/p1-release-cli/catalog-continuation/changed-swift.nul`. Include every
changed retained Swift path and both new paths; exclude no changed file by
baseline attribution. The explicit positional lint command above covers the
full owned/shared Swift allowlist, including unchanged contract anchors.
