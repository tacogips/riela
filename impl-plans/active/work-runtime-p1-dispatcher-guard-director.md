# Work Runtime P1: P1-6c final-source review and conditional finalization

**Status:** Step 3 accepted the post-SIGINT design with no findings
(`comm-000004`, `step3-design-review-attempt-1-exec-4`). The prior formal
integrity finding prompted a real EntryPoint SIGINT subprocess regression.
Post-regression source-matched operator-host logs now exist; renewed independent
Sol integrity/adversarial review and Astra combined-tree acceptance remain
pending. Historical Step 6 read-only audits are advisory. Documentation
finalization, implementation commit and push remain gated. The broad aggregate
remains FAILED.
**Workflow mode:** `issue-resolution`.
**Issue:** Local request: Finalize P1-6c after real SIGINT regression and source-matched
host verification; no issue URL or number supplied.
**Design:** `design-docs/specs/design-work-runtime-consolidation.md`, P1-6c
bounded amendment, especially “Final-source capable-host evidence”, “Failure
disposition and bounded review” and “Acceptance and rollout boundary”.
**Design SHA-256:** `0c5ee8f2617550eee382dc0c12d0e31cb4ad02195330efaafe70c4c791c1f592`.
**Codex-agent references:** single Astra design/plan author, independent Sol
test-integrity reviewer, independent Sol adversarial reviewer, Astra exact
combined-tree reviewer; one Sol serial implementation/reconciliation owner.
**Execution:** `codex-design-and-implement-review-loop-session-1`.

## Current executable contract — final-source review

Only this section and its first JSON metadata block schedule current work.
Everything beneath “Historical preserved plan” is retained verbatim as history,
not an instruction to rebuild implemented seams, repeat obsolete failures or
execute historical verification commands. The stable plan ID remains
`p1-dispatch`; one coupled contract needs one implementation owner, not extra
implementation plans. Separate read-only review roles may work in parallel.

### Intent, context and non-goals

Decide whether preserved P1-6c WIP merits evidence-backed slice-only acceptance
on `feat/remaining-impl-plans`, starting at intake HEAD
`133fdf94fe7ab249afc24884471b3d182892d42e`. Preserve all 22 tracked intake
modifications, three untracked Swift files and the accepted design refresh.
The supplied post-SIGINT manifest contains 973 source/test/build-input entries.
The focused host log reports 99/99, exit 0; the separate serial 2,049-test
aggregate reports 19 assertion failures (7 unexpected), exit 1. Step 2 verified
all manifest hashes and membership, both log digests and the exact 19-assertion
inventory match. These structural checks do not substitute for formal semantic
review. Host process exit statuses are runtime-reported; log summaries confirm
counts. Review acceptance remains open; no new production change is assumed.

Non-goals: P1-6d, P1-7a/b, parent P1 completion; unrelated baseline repair;
new abstraction, transport, scheduler or decision store; direct decision-row
mutation; broad cleanup/formatting; package edits; main merge, release, force
push, worktrees, private branches, concurrent Git operations or changes to Monja.
Runtime-resolved provenance and effective workflowInput are authoritative;
registry discovery or repair is never a task. Codex references identify roles;
there is no Cursor behavior mapping or reference-repository divergence.

### Scheduler metadata and file ownership

Every writePath is a bounded candidate, not a request to edit it. Shared paths
are exclusively serial-owned. Existing Swift WIP is reviewed as-is; a change
requires a concrete material finding tied to the accepted design. Paths outside
this list need a recorded scope decision; do not broaden the plan silently.

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/EntryPoint.swift",
    "Sources/RielaCLI/CLISignalCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/DistributedNodeExecution.swift",
    "Sources/RielaCore/DistributedJobController.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaServer/DistributedWorkerLoop.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/DistributedProcessCancellationTests.swift",
    "Tests/RielaCoreTests/DistributedJobControllerTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/EntryPoint.swift",
    "Sources/RielaCLI/CLISignalCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/DistributedNodeExecution.swift",
    "Sources/RielaCore/DistributedJobController.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaServer/DistributedWorkerLoop.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/DistributedProcessCancellationTests.swift",
    "Tests/RielaCoreTests/DistributedJobControllerTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift"
  ],
  "progressLog": "impl-plans/progress/p1-dispatch.md",
  "taskIds": [
    "P1-6c-evidence",
    "P1-6c-integrity",
    "P1-6c-adversarial",
    "P1-6c-reconcile",
    "P1-6c-integration",
    "P1-6c-finalize"
  ],
  "taskDependencies": {
    "P1-6c-evidence": [],
    "P1-6c-integrity": [
      "P1-6c-evidence"
    ],
    "P1-6c-adversarial": [
      "P1-6c-evidence"
    ],
    "P1-6c-reconcile": [
      "P1-6c-integrity",
      "P1-6c-adversarial"
    ],
    "P1-6c-integration": [
      "P1-6c-reconcile"
    ],
    "P1-6c-finalize": [
      "P1-6c-integration"
    ]
  },
  "dependencyMode": "single-plan-ordered-internal-gates",
  "acceptedPrerequisites": {
    "P1-6a": "2f10916a14501af68fd7e7f63cb91f244a343f8c",
    "P1-6b": "7d8fc121a4f4469de7a40495282b53c9d813b8d4"
  },
  "verificationCommands": [
    "shasum -a 256 tmp/work-runtime-p1-6c-final-review-20260924-c16e975-comm000006/final-source-after-sigint.sha256",
    "shasum -a 256 -c tmp/work-runtime-p1-6c-final-review-20260924-c16e975-comm000006/final-source-after-sigint.sha256",
    "git ls-files --cached --others --exclude-standard -z Sources Tests Package.swift Package.resolved",
    "shasum -a 256 tmp/work-runtime-p1-6c-final-host/focused.log tmp/work-runtime-p1-6c-final-host/aggregate.log",
    "cat tmp/work-runtime-p1-6c-final-host/focused.log",
    "cat tmp/work-runtime-p1-6c-final-host/aggregate.log",
    "cat tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/reviews/evidence/failures.json",
    "git diff 133fdf94fe7ab249afc24884471b3d182892d42e -- Sources Tests",
    "git diff --check",
    "git diff --cached --check"
],
  "evidenceDirectory": "tmp/work-runtime-p1-6c-final-review/"
}
```

### Invariants and exact file-level deliverables

- `TaskCommands.swift`, `EntryPoint.swift`, `TaskRunCancellation.swift`,
  `TaskDispatch.swift` and listed workflow-run persistence files: durable shared
  decision/request before interruption; bounded run-owned observer joined on
  exit; exact reserved cancelled snapshot before acknowledgment; retain plain
  non-task behavior. Successful CLI request acceptance is not terminal proof.
- `WorkStore+Decisions.swift`, `WorkStore+Reservation.swift`: current identity,
  version and causal validation; prelaunch authorization guard; uncertain live
  work fenced; atomic exact acknowledgment and lease/task/attempt transition;
  generic reconciliation rejects pending cancellation; one replacement consumes
  one pending request. Reopen/replay cannot duplicate decisions, usage or evidence.
- Listed Core controller/node/model and Server loop/router/protocol files:
  authenticated selected-host execution, no local fallback; worker/process join
  and durable correctly bound stop proof precede terminal acknowledgment. HTTP
  acceptance, lease expiry, heartbeat loss and lost transport are not stop proof.
- Listed CLI/Core/Server/Work tests: preserve identity/causality assertions,
  actual local/selected-host process stop, delayed/lost proof fencing, prelaunch
  and Ctrl-C ordering, terminal persistence/acknowledgment loss, reopen/replay,
  stale proof rejection and once-only replacement/accounting. Map each row of
  the preserved “Required regression matrix” to exact test names and matched
  evidence before requesting any additional test. Fabricated snapshots prove
  only store behavior. Add tests only for a demonstrated material gap.
- `CLISurfaceEnumeration.swift`, `SurfaceCatalog+RowsCLI.swift`, catalog/parity
  tests and `TaskProjectionProofTests.swift`: preserve the completed catalog
  repair, actual task-run/decide mutation/audit semantics and canonical failed-
  session `acceptanceNotMet` reason. Do not weaken assertions to remove failures.
- `README.md`: inspect current task decision/cancellation wording and change
  only a demonstrated mismatch. Design document, this plan and
  `impl-plans/progress/p1-dispatch.md`: record evidence-backed slice disposition,
  all 19 failure owners, pending later slices and failed broad gate. No global
  plan archive/index regeneration or lockfile change is needed for this slice.

### Ordered tasks and acceptance

1. **P1-6c-evidence:** Recheck every one of the 973 current manifest entries
   and read both complete logs with the metadata commands. Manifest digest must
   equal `d2b675f1bd3fded858997d8345bccaa70e6c19cae8d72b09f977422fb5259140`.
   Focused log digest must equal
   `05bdb645a4b8c3fc95b1389eb5528ef87728cb33ae47417288a8bd6ec1d37dd1`;
   aggregate digest must equal
   `49d18fb95b91f96e889f97089172b1a25e66e83cb47654b6fe9c6f647b8ba115`.
   Compare manifest membership with all tracked/untracked Sources/Tests and
   Package.swift/Package.resolved; reject missing, extra or duplicate entries.
   Preserve immutable originals. Step 2's
   `tmp/p1-6c-step2-post-sigint/source-match.log` is a cross-check, not independent
   acceptance. Parse every aggregate assertion into exact test identity and
   assertion source path/line; require multiset equality with inventory IDs
   1–8 and 14–24, zero new/missing records. Do not compare historical log lines.
   Deliver current source identity, requirement-to-test/evidence matrix and
   assertion-to-owner map with complete command logs and terminal exit status.
   Exclude pre-SIGINT and incomplete host logs from current-source acceptance.
2. **P1-6c-integrity** and **P1-6c-adversarial**, after evidence: independent
   read-only Sol reviews may run concurrently on frozen bytes. Integrity checks
   complete logs, terminal exits, positive suite counts, test selection,
   assertions, hashes and every disposition. Both reviews explicitly cover durable
   request before interruption, owned stop proof, exact cancelled reserved
   session, acknowledgment, fence/replay, real EntryPoint SIGINT and selected-
   host behavior. Inspect
   `Tests/RielaCLITests/TaskCancellationIntegrationTests.swift::testTaskRunSubprocessSIGINTCommitsAndAcknowledgesCancellation`
   and its passing entries in both logs; helper-only coverage is insufficient.
   Adversarial review also checks material races and source/dependency history.
   Each emits explicit accept/reject for slice-only disposition, exact reviewed
   manifest, findings by severity/path, commands/logs/exits, unresolved coverage
   and all 19 failure owners. No style nits or speculative architecture.
3. **P1-6c-reconcile**, after both reviews: one owner resolves every high/mid
   finding or records a precise material rejection. No finding means no source
   repair. Any necessary repair uses the file map above, regression coverage
   and affected verification below. Renew affected independent review before
   proceeding. Prepare a proposed documentation disposition for review without declaring
   acceptance or finalizing progress before Astra decides. Deliver reconciled complete
   tree manifest including docs, accepted review receipts and exact proposed
   final file allowlist. Classification alone cannot waive a failure.
4. **P1-6c-integration**, after reconciliation: Astra independently reviews the
   exact combined tree and evidence, including docs and repaired bytes; accepts
   or rejects slice-only disposition with no unresolved material finding.
   Source changes require a new reconciliation/review attempt before acceptance.
5. **P1-6c-finalize**, only after explicit slice acceptance: serially refresh
   README where affected, design, plan and progress to distinguish P1-6c from
   P1-6d, P1-7a/b, parent P1 and the failed broad gate with all 19 owners. Astra
   verifies the exact final documentation/source tree and reaffirms acceptance
   before publication; a documentation edit is not automatically covered by an
   earlier tree review. Record final allowlist, hashes and whitespace outcomes.
   Serial workflow finalization then commits exact files and non-force pushes to
   `origin/feat/remaining-impl-plans`, recording matching commit/push receipts.
   Any substantive post-review edit returns to affected verification/review.
   Keep this parent plan active and P1-6d/P1-7a/b/parent P1 open.

The failure inventory retains 24 historical records: IDs 9–13 are the five
repaired catalog/projection assertions absent from the current aggregate.
Current failed IDs and owners are 1–7 CLI doctor/backend-capability; 8 P1-7b
examples; 14–21 workflow-command/host-readiness outside P1-6c; 22 workflow
runner admission; 23–24 temporary workflow/host-requirements. Match current
assertions by test and source line, not historical aggregate line number.
IDs 16–21 have limited historical root-cause detail; reviewers must assess the
recorded dependency/history evidence. Unknown relevance or missing material
coverage blocks acceptance. The aggregate remains FAILED, exit 1, even if
all reviewers accept the slice.

### Checkpoint, edit integrity and progress

Step 4 does not commit an unreviewed plan. After Step 5 accepts, the runtime's
serial design/plan checkpoint commits only the accepted design and this plan
before native implementation/review fanout. This is plan acceptance, not P1-6c
implementation acceptance. Preserve unstaged Swift/progress WIP; never stage it
as part of that checkpoint. Final implementation commit/push requires the
independent slice acceptance above. No concurrent Git operations.

Before every edit, fresh-read and hash the file; store immutable preimage,
requirement, owner and intended hunk under
`tmp/work-runtime-p1-6c-final-review/intents/<unique-edit-id>/`. Check the hash
again immediately before writing; drift stops that edit for serial reconciliation.
Record postimage/hash; record nonexistence for a new file. At review join compare
all actual bytes with accepted intents and reviewer manifests, serially repair
any overwrite, and renew affected verification/review. Never reset unrelated WIP.
Shared indexes, lockfiles, broad formatting and global archiving are reserved
for serial finalization and are not requested here.

Only the implementation owner appends `impl-plans/progress/p1-dispatch.md`;
reviewers write separate `tmp/work-runtime-p1-6c-final-review/reviews/<role>/`
artifacts. Record task/communication IDs, changed paths, pre/post hashes,
complete command/env/log/exit/count evidence, review decisions/findings,
follow-up owners, remaining gates and next action. Preserve historical entries.
Build/test processes use one serial owner and frozen source, with foreground
logs and terminal exits; poll yielded sessions to completion. Incomplete,
zero-test or interrupted runs are not passing evidence. No shell orphans.

### Verification contract

First execute the metadata inspection commands; save full outputs and exits in
new immutable attempt directories under `tmp/work-runtime-p1-6c-final-review/`.
Retain the supplied host command/environment evidence when available and record
any missing provenance precisely; do not invent process receipts from XCTest
summaries. Focused terminal summary must show 99/99 and aggregate 2,049/19/7;
runtime-reported terminal exits remain respectively 0 and 1. Both complete logs
must contain the named real SIGINT regression passing. Inspect policy-start and
human-cancel identities and causal linkage in
`Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift`, exact
acknowledgment and stable replay. The failed broad gate retains all 19 owners.

Assess existing V0/build, V2/store, decisions, live, compatibility and strict
changed-file lint receipts against current bytes and dependencies. Preserve
these obligations, but do not rerun passing checks without a concrete gap.
The commands below are conditional: run the affected command when a material
coverage gap or source/test repair invalidates evidence, not as a new broad audit.
Use an owned capable host for listener-dependent cases. Do not rerun the broad
aggregate inside a listener-denied sandbox to reinterpret known failures.

**V0** — Compile/typecheck exit 0 on final repaired source.

```bash
swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
```

**Catalog** — All three suites, positive counts, unchanged parity/verdict assertions.

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'SurfaceCatalogTests|SurfaceParityCLITests|TaskProjectionProofTests'
```

**V1** — Task behavior and cancellation integration; each suite positive.

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskCancellationIntegrationTests'
```

**V2** — Authorization, held fence, exact acknowledgment, budgets, replacement and replay.

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionDecisionApplierStoreTests'
```

**V11** — Actual selected-host stop/acknowledgment, exact decision identities and causal replay; each suite positive.

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof'
```

**Decisions** — Input rejection, identity/version/causality, conflicting and identical replay.

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandParsingTests|DecisionApplierStoreTests'
```

**Live** — Real owned process interruption, Ctrl-C, delayed proof and teardown.

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCancellationIntegrationTests|DistributedProcessCancellationTests'
```

**Compatibility** — Preserved result and read-only dry-run behavior.

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'
```

For any new source/test bytes, create a new sorted manifest of all tracked and
untracked Sources/Tests files and Package.swift/Package.resolved; record HEAD,
path membership and manifest digest before/after affected runs. Do not overwrite
the supplied final-source manifest or claim its receipts apply to repaired bytes.
The exact conditional strict lint command is:

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1-6c-final-review/changed-swift-files.nul
```

Generate that NUL list from the exact task-owned Swift change allowlist including
untracked files; reject empty/missing paths. Preserve complete lint diagnostics
and require strict exit 0. Reuse prior lint only with matched bytes and coverage.
No UI/web changes require browser/AppKit checks. Package digests are untouched.
For broad regression after a material repair, determine dependency relevance
with independent review; if a new broad run is necessary, run serially on a
capable host with the receipt's filter `RielaCLITests|RielaWorkTests|RielaCoreTests|RielaServerTests`,
using `swift test --disable-sandbox --skip-update --filter` and that quoted
filter, recording exact env/argv, complete log and terminal exit. Preserve all
failures and update classification; never reinterpret an old manifest as current.

### Completion and author check

Completion requires matched final-source evidence and every material matrix row
accounted for; independent integrity/adversarial and Astra slice-only acceptance;
no high/mid finding; documented 19 follow-ups and failed broad gate; accurate
README/design/plan/progress; exact accepted-file commit and matching non-force
push receipt. Design/plan readiness alone completes none of those later gates.
A precise material rejection is a valid review outcome, not implementation
completion or authorization to publish.

Step 3 supplied no revision findings. Step 4 self-check records accepted design
hash, metadata DAG/task/path validation, unchanged historical-tail hash and
whitespace outcome under `tmp/p1-6c-step4-post-sigint/`. No Swift tests, semantic
host-log review or implementation acceptance are claimed by this plan-author
check. Downstream reviewers independently verify preserved WIP and final bytes.

---

## Historical preserved plan — not executable in this invocation

The following prior plan text and WIP history are preserved. Its statuses,
commands, metadata and checkbox states do not supersede the current contract.

# Work Runtime P1: P1-6c durable decisions and live cancellation

**Status**: Historical design/plan checkpoint `0a74a070670a5cb73f6cd18e035adf61732a0b07` retained. Step 3 accepted the host-evidence/classification refresh; runtime dispatch is at Step 6 implementation. P1-6c implementation and publication remain incomplete.
**Workflow mode**: issue-resolution
**Issue reference**: Work Runtime P1-6c; no GitHub issue URL or number supplied.
**Accepted design**: `design-docs/specs/design-work-runtime-consolidation.md` §17.2 and §17.5 “P1-6c bounded amendment (2026-09-24)”.
**Design SHA256**: `f1ea157a0547fc3df77be2c1c510654539f4368e373be47d3e062098fc0cf9a0`.
**Review decision**: Step 3 accepted the host-evidence/classification design with no findings, `comm-000004`, `step3-design-review-attempt-1-exec-4`. This Step 6 dispatch has no Step 5 communication ID in its input; independent implementation and combined-tree acceptance remain pending.
**Codex-agent references**: `gpt-6-astra` single design/plan author and final integration reviewer; `gpt-6-sol` implementation, serial reconciliation, independent test-integrity and adversarial review. Execution `codex-design-and-implement-review-loop-session-1`.
**Updated**: 2026-09-24

**Current Step 6 handoff**: Host receipt and original source manifest were rechecked before the five-file catalog/projection repair. The 24 original broad assertions are classified in `tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/reviews/evidence/failures.json`; five direct P1 assertions are repaired, and the catalog/parity/projection focused gate passes 17/17 with a writable repository-`tmp/` HOME. The original capable-host broad gate remains failed at 24/2,048. Final-source selected-host and affected capable-host aggregate acceptance, independent reviews, docs acceptance, exact-file commit and push remain open. P1-6d, P1-7a/b and parent P1 remain active.

The prior host's cancellation/worker dependencies are unchanged, but its manifest differs in five Swift files and cannot count as an exact final-source pass. Pre-P1 capable-host logs and a final-source focused run now establish the eight workflow-command assertion failures predate P1-6c; exact causes for six historical assertions remain unspecified and are a separate workflow-command follow-up. With writable `tmp/` HOME, the final-source sandbox broad aggregate reached terminal exit 1 after 2,048 tests and 240 failures (90 unexpected), including listener denials. Its complete log is `tmp/work-runtime-p1-6c-host-classification-20260924-076f8c6b4184/aggregate-home-final-source.log`; source recheck after the run exited 0. This broad gate is failed, not slice acceptance.

This is the only current executable contract in this file. The historical
P1-6b and parent material below is reference-only and does not authorize work.
Preserve P1-6b publication `7d8fc121a4f4469de7a40495282b53c9d813b8d4` and receipt
baseline `ae7cafe7577fda5037dee105e894804c88626f43`. P1-6d, P1-7a/b and parent P1
remain active. One implementation owner is necessary because store, runner,
signal and selected-host acknowledgment form one coupled safety contract;
there is no independent implementation plan to fan out.
The accepted design/plan checkpoint is
`0a74a070670a5cb73f6cd18e035adf61732a0b07`; the current implementation baseline
is intake HEAD `30601aa89485436440728bf417b0156ea477f25d` plus all 20
intake WIP files (17 modified tracked and three untracked), as enumerated in
`comm-000002`. Preserve the accepted Step 2 design update as well. The five-file
checkpoint is historical, not the current preservation allowlist. Step 3
accepted the refreshed design via `comm-000004`; no Step 5 revision feedback
is supplied. Prior read-only agents `failure_matrix_audit` and
`remote_evidence_audit` supply history, not final review acceptance.


The runner-resolved immutable user-scope workflow package and effective
workflow input are authoritative. No registry or package rediscovery belongs
to this node. Within this run, at most two productive incomplete Step 6
continuations may retain this accepted design/plan without reopening them.
Each requires concrete new changes, plan-progress evidence and passing
behavioral tests. Repeated evidence, external blockers, missing material
verification or a third consecutive incomplete attempt ends with an accurate
handoff; incomplete implementation never enters review or finalization.

### Current continuation and historical progress

Current status follows accepted Step 3 `comm-000004`, execution
`step3-design-review-attempt-1-exec-4`. The complete receipt
`tmp/work-runtime-p1-6c-host-failure/evidence.json` records capable-host
selected-live 1/1, V11 plus live 55/55 and V1 plus cancellation 50/50, all exit 0.
The fixture proves one policy start and one human cancel with causal evidence
and unchanged replay history. The prior two-row failure is resolved by this
source-matched evidence; do not rebuild the implemented cancellation seams or
repeat obsolete listener diagnosis. The manifest SHA-256 is
`6d3ef8ee373d32a7ed1deac12a969a5366b71117c9019031869a3759debf5e96`;
Step 3 independently matched its 962 entries. Evidence verification remains an
explicit task; these results alone do not accept P1-6c.

The complete `tmp/work-runtime-p1-6c-host-failure/capable-host-aggregate-current.log`
is failed: 2,048 tests, 24 assertions (7 unexpected), exit 1. Assertion counts:
Doctor 7, surface parity 4, projection 1, example parity 1, workflow commands 8,
temporary workflow registration 2 and runner admission 1. The separate
`capable-host-projection-current.log` is failed: 2 tests, 1 assertion, exit 1.
Classify every assertion, repair only demonstrated slice defects, rerun affected
final-source gates and obtain independent disposition of remaining unrelated
failures. Earlier continuation observations below are historical, not current
missing-feature claims or substitutes for these receipts.

The owner audited the accepted store, runner, signal and selected-host seams.
`WorkStore+Reservation.swift` now exposes an exact task/attempt/session scoped
read of a durable cancellation request and its acknowledgment state. The
reopened-store regression in `WorkStoreCancellationTests.swift` passes, along
with the selected 23-case reservation/cancellation suite and strict two-file
SwiftLint. Complete logs and source hashes are under
`tmp/work-runtime-p1-6c-2c7cf9334b26/`.

The live request observer, prelaunch cancelled snapshot, task-backed Ctrl-C,
selected-host worker-stop proof, dispatch acknowledgment route and full matrix
remain open. This seam does not establish P1-6c completion or authorize a
fence release. The completion criteria below remain unchecked pending those
paths, final-source V1/V2/V11 and aggregate evidence, and independent reviews.

Continuation `nested-v1-f637160bee4a0e57484a92a8400c09a6a58ec7ccbb82ac72bb5ebee0ca2d68ae`
added a fail-closed exact cancellation check in `TaskDispatch.swift` before
terminal evidence projection and generic reconciliation. An unacknowledged
request remains fenced; an already acknowledged request is accepted only when
the durable attempt outcome matches the reserved terminal snapshot, then its
evidence projection can replay without reapplying the transition. This is an
intermediate guard, not the live acknowledgment route: the run-owned observer,
worker-stop proof, cancellation-safe terminal persistence and exact first
acknowledgment remain open. Read-only Codex audits `audit_dispatch`,
`audit_runner` and `audit_store` identified these coupled gaps. The build and
selected V2/decisions suites passed with plan-local module caches; V1 selected
41 tests and failed 16 listener-dependent assertions because this host denies
local network listeners. Complete logs and exits are under
`tmp/work-runtime-p1/p1-6c/continuation/`. No completion criterion advances.

This Step 6 continuation added `TaskRunCancellation.swift` to poll exact durable
requests during the owned run and join observation on exit. A separate-process
decision now interrupts local execution, and `TaskDispatch.swift` acknowledges
only its exact cancelled terminal snapshot after the local runner returns. The
selected-host worker now records a durable lease-bound stop receipt after its
executor joins; the controller rejects foreign or stale receipts. Dispatch still
holds selected-host cancellation pending because it does not yet consume that
receipt as end-to-end proof. Prelaunch cancelled persistence and task-backed
Ctrl-C remain open. The controller retains a cancelled claimed job until its
stop receipt is durable, including under zero terminal-retention configuration;
receipt replay survives archival and reopen. The final-source safe filter
passed 92/92 and strict
changed-file SwiftLint passed; the real process test could not start a local
listener on this sandbox host. Evidence and per-edit intents are under
`tmp/work-runtime-p1/p1-6c/continuation-2/`. No independent review or P1-6c
completion is claimed.

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/EntryPoint.swift",
    "Sources/RielaCLI/CLISignalCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/DistributedNodeExecution.swift",
    "Sources/RielaCore/DistributedJobController.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaServer/DistributedWorkerLoop.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/DistributedProcessCancellationTests.swift",
    "Tests/RielaCoreTests/DistributedJobControllerTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+Finalization.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/EntryPoint.swift",
    "Sources/RielaCLI/CLISignalCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/WorkflowRunCommand+SupervisionPersistence.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaCore/DistributedNodeExecution.swift",
    "Sources/RielaCore/DistributedJobController.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaServer/DistributedWorkerLoop.swift",
    "Sources/RielaServer/DistributedWorkerHTTPRouter.swift",
    "Sources/RielaServer/DistributedWorkerProtocol.swift",
    "Tests/RielaWorkTests/WorkStoreCancellationTests.swift",
    "Tests/RielaWorkTests/WorkStoreReservationTests.swift",
    "Tests/RielaWorkTests/DecisionApplierStoreTests.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaCLITests/TaskCommandParsingTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests+SelectedHostFixtures.swift",
    "Tests/RielaCLITests/DistributedProcessCancellationTests.swift",
    "Tests/RielaCoreTests/DistributedJobControllerTests.swift",
    "Tests/RielaServerTests/DistributedWorkerHTTPTests.swift",
    "Sources/RielaCLI/TaskRunCancellation.swift",
    "Sources/RielaCLI/WorkflowRunCommand+Finalization.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests.swift",
    "Tests/RielaCLITests/TaskCancellationIntegrationTests+Fixtures.swift",
    "Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "README.md",
    "design-docs/specs/design-work-runtime-consolidation.md",
    "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
    "impl-plans/progress/p1-dispatch.md",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "Tests/RielaCoreTests/SurfaceCatalogTests.swift",
    "Tests/RielaCLITests/SurfaceParityCLITests.swift"
  ],
  "progressLog": "impl-plans/progress/p1-dispatch.md",
  "taskIds": [
    "P1-6c-audit",
    "P1-6c-decision-diagnosis",
    "P1-6c-decision-repair",
    "P1-6c-evidence",
    "P1-6c-catalog-projection",
    "P1-6c-store",
    "P1-6c-remote",
    "P1-6c-live",
    "P1-6c-regressions",
    "P1-6c-integrity",
    "P1-6c-adversarial",
    "P1-6c-reconcile",
    "P1-6c-integration",
    "P1-6c-finalize"
  ],
  "taskDependencies": {
    "P1-6c-audit": [],
    "P1-6c-store": [
      "P1-6c-catalog-projection"
    ],
    "P1-6c-remote": [
      "P1-6c-store"
    ],
    "P1-6c-live": [
      "P1-6c-remote"
    ],
    "P1-6c-regressions": [
      "P1-6c-live",
      "P1-6c-evidence"
    ],
    "P1-6c-integrity": [
      "P1-6c-regressions"
    ],
    "P1-6c-adversarial": [
      "P1-6c-regressions"
    ],
    "P1-6c-reconcile": [
      "P1-6c-integrity",
      "P1-6c-adversarial"
    ],
    "P1-6c-integration": [
      "P1-6c-reconcile"
    ],
    "P1-6c-finalize": [
      "P1-6c-integration"
    ],
    "P1-6c-evidence": [
      "P1-6c-audit"
    ],
    "P1-6c-decision-diagnosis": [
      "P1-6c-audit"
    ],
    "P1-6c-decision-repair": [
      "P1-6c-decision-diagnosis"
    ],
    "P1-6c-catalog-projection": [
      "P1-6c-evidence",
      "P1-6c-decision-repair"
    ]
  },
  "dependencyMode": "single-plan-ordered-internal-gates",
  "acceptedPrerequisites": {
    "P1-6a": "2f10916a14501af68fd7e7f63cb91f244a343f8c",
    "P1-6b": "7d8fc121a4f4469de7a40495282b53c9d813b8d4"
  },
  "verificationCommands": [
    "shasum -a 256 -c tmp/work-runtime-p1-6c-decision-20260924-c07910f-comm000006/continuation-2/source-test.sha256",
    "rg -n 'Test Case .* failed \\(| error: ' tmp/work-runtime-p1-6c-host-failure/capable-host-aggregate-current.log",
    "swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'SurfaceCatalogTests|SurfaceParityCLITests|TaskProjectionProofTests'",
    "swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'DoctorCommandTests|RielaExampleParityTests|WorkflowCommandTests|WorkflowTemporaryRegistrationTests|WorkflowRunnerAdmissionTests'",
    "git log -n 12 --format=oneline -- Sources/RielaCore/SurfaceCatalog+RowsCLI.swift Sources/RielaWork/CompletionEvaluator.swift Tests/RielaCLITests/TaskProjectionProofTests.swift",
    "git diff 30601aa89485436440728bf417b0156ea477f25d -- Sources Tests",
    "CLANG_MODULE_CACHE_PATH=tmp/work-runtime-p1/p1-6c/module-cache SWIFTPM_MODULECACHE_OVERRIDE=tmp/work-runtime-p1/p1-6c/module-cache swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskCancellationIntegrationTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|BudgetAdmissionDecisionApplierStoreTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandParsingTests|DecisionApplierStoreTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCancellationIntegrationTests|DistributedProcessCancellationTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskProjectionProofTests",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaCLITests|RielaWorkTests|RielaCoreTests|RielaServerTests'",
    "xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6c/changed-swift-files.nul",
    "git diff --check",
    "git diff --cached --check"
  ],
  "evidenceDirectory": "tmp/work-runtime-p1/p1-6c/"
}
```

## Current P1-6c executable contract

### Intent, boundaries and invariants

Complete P1-6c using verified host evidence, repair confirmed catalog/projection
defects and classify the failed aggregate while preserving accepted behavior. Complete actual task
cancellation, not just request storage: human cancel/reject,
guard stop/replacement and Ctrl-C must commit the shared decision before
interrupting the exact local or selected-host execution. Reuse the WorkStore
applier, reservation fence, workflow persistence and authenticated worker path.
Requests from another CLI process must reach the running owner without output
or heartbeat dependence. The runtime-supplied workflow input and provenance
are authoritative; registry rediscovery is not a task.

Non-goals: director execution, legacy auto-improve removal, later examples,
new decision storage or scheduler, new dependencies, generalized signaling or
persistence frameworks, broad formatting, unrelated baseline repair, main merge,
release, worktrees or private branches. Preserve Monja and unrelated work.
Codex references map to agent roles, not product behavior; no Cursor adapter or
reference-repository comparison is required.

Invariant sequence: durable request -> interruption -> proven owned execution
stop -> exact reserved cancelled snapshot -> atomic store acknowledgment ->
optional one-time replacement reservation. Generic reconcile, caller outcomes,
HTTP cancellation acceptance, expired leases and missing heartbeats cannot
substitute for any boundary. Pre-authorization cancellation prevents launch;
authorized uncertainty remains fenced. Matching success or non-cancelled failure
cannot acknowledge cancellation and must remain an explicit fenced conflict.
No stale token, duplicated evidence/usage, replacement or decision application is
permitted. A task may contain distinct legitimate decisions; one cancellation
intent must not be mistaken for a universal one-row task history.

### Ownership and evidence safety

Step 5 acceptance precedes the workflow's serial exact-file design/plan checkpoint
commit, which must occur before native implementation/review fanout. Step 4
itself does not commit an unreviewed plan. Record checkpoint hash and changed
file list; retain baseline and accepted P1-6b evidence separately. Checkpoint
only the accepted design and plan documents; do not stage the preserved partial
Swift implementation or its progress log as completed implementation. Preserve
all 20 intake WIP files through checkpointing and later edits; the existing plan WIP
is retained within this revised plan, not reverted to the old committed version.

All writePaths are exclusive to the single implementation owner; listed files
are candidates, not a requirement to edit every file. Shared docs, README,
indexes, lockfile generation and finalization are serial-only. Do not change a
lockfile or index unless necessary and explicitly recorded by reconciliation.
No concurrent Git operations. Reviewers are read-only and write evidence only
under their own `tmp/work-runtime-p1/p1-6c/reviews/<role>/` directory.
Read-only log/source investigation may run in parallel with the owner. Serialize
Swift build/test commands using the shared scratch path and freeze source while
capturing accepted runs; never attribute a run across concurrent source edits.

Before each edit, fresh-read the file, hash its current bytes and save an
immutable preimage plus intended change, requirement and owner under
`tmp/work-runtime-p1/p1-6c/intents/<unique-edit-id>/`. Recheck the pre-hash just
before writing; drift means stop that edit and reconcile, never overwrite.
Record postimage/hash immediately. For new files record nonexistence first.
At the review join compare current files to owner/reviewer manifests and all
accepted intents; serially restore missing behavior, then rerun affected checks
and reviews against repaired hashes. Never reset unrelated changes.

Only this plan's owner appends `impl-plans/progress/p1-dispatch.md`, recording
workflow/communication IDs, task IDs, exact edited paths, hashes, complete log
paths, exit codes, counts, review decisions, blockers and next work. Preserve
historical entries and P1-6b hashes. Do not mark parent/later slices complete.

### Tasks, file-level deliverables and dependencies

- [x] **P1-6c-audit**: Accepted seam audit is complete. Fresh-read only files
  being edited and reconcile current hashes with the terminal handoff;
  do not restart a broad audit. `/root` remains the sole source/test editor.
- [x] **P1-6c-decision-diagnosis** after audit: Reconcile the supplied receipt
  against each complete host log and the unchanged manifest. Fresh-read
  `TaskCancellationIntegrationTests.swift` and `+Fixtures.swift`; map exact
  policy-start/human-cancel IDs, kinds, producer, task/attempt, causal evidence,
  reserved session and application/replay assertions to the passing selected-live
  test. Record this mapping and source-match exit/count under this attempt's
  evidence directory. Reuse valid evidence; only an actual inconsistency requires
  new diagnostics. Never infer causality merely from a row count or producer.
- [x] **P1-6c-decision-repair** after diagnosis: Record the evidence-supported
  no-new-repair decision for the now-passing fixture, unless diagnosis exposes
  an actual contradiction. If one exists, only the serial owner may repair the
  demonstrated fixture/producer seam in the already listed CLI/Work files and
  rerun selected-live. Preserve exact identity, cancellation, process-stop,
  proof, lease, outcome, replay and accounting assertions. No direct decision-row
  mutation, unexplained filtering or bare count substitution.
- [x] **P1-6c-evidence** after audit: Independent read-only investigation may run
  alongside receipt reconciliation. Write `reviews/evidence/failures.json` under
  this attempt's evidence root with exactly 24 assertion records, each containing
  suite/test, original log line, expected/actual, source and dependency history,
  focused reproduction command/log/exit/count, relevance and disposition.
  Multiple assertions in one test retain separate records. Reconcile the seven
  suite-group counts above and explicitly retain the seven unexpected failures.
  Use the history, diff and classification commands below; trace fixtures and
  affected production dependencies, not just whether a test file changed.
  Classify as slice defect, evidenced baseline/unrelated, environment, or unknown;
  unknown blocks acceptance. This task delivers the initial classification and
  pre-repair reproduction; regressions updates the same records with final-source
  results before calling an earlier failure resolved. Baseline claims need concrete historical semantics or
  reproduction evidence; do not reset this shared tree or create worktrees.
  Read-only `git show <commit>:<path>` may inspect the identified history.
  Each unresolved unrelated failure gets an explicit follow-up owner (parent P1
  maintainer or the evidenced later slice), affected paths and reproduction.
  The implementation owner records proposed slice-only disposition in progress;
  independent reviewers must accept it. Classification never makes aggregate green.
- [x] **P1-6c-catalog-projection** after evidence and decision-repair: The serial
  owner confirms catalog schema/parity from `SurfaceCatalog.swift`,
  `SurfaceCatalog+RowSupport.swift`, `SurfaceCatalog+RowsCLI.swift`, registered
  `TaskCommands.swift` and existing catalog/parity tests. Add only missing task
  run/decide rows in `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`, matching
  actual command capabilities, mutation and audit behavior. Retain full parity
  assertions; extend `Tests/RielaCoreTests/SurfaceCatalogTests.swift` or
  `Tests/RielaCLITests/SurfaceParityCLITests.swift` only if existing coverage cannot
  detect the demonstrated omission. No registration removal to hide a mismatch.
  Verify failed-session semantics in read-only
  `Sources/RielaWork/CompletionEvaluator.swift` and the fixture, then add the
  required `acceptanceNotMet` reason in canonical order to
  `Tests/RielaCLITests/TaskProjectionProofTests.swift`; retain all gate/finding
  reasons and task-state assertions. Do not weaken the evaluator or example.
  Deliver before/after intent hashes, focused failing/passing evidence and the
  exact repair rationale. Run catalog-projection below with positive counts for
  all three suites. Other failures authorize no unrelated edits; a material
  issue beyond listed scope needs a documented scope decision before repair.
- [ ] **P1-6c-store** after catalog-projection: Verify the preserved implementation, repairing
  only demonstrated gaps. In `WorkStore+Decisions.swift` and
  `WorkStore+Reservation.swift`, preserve and consume the existing
  `attemptCancellation(taskId:attemptId:sessionId:)` read and
  `AttemptCancellationRecord`; do not recreate the verified seam. Repair only
  demonstrated transaction/replay gaps. Preserve decision/version validation, request-before-signal ordering,
  authorization/node-start guards and generic-reconcile rejection. Acknowledge
  only canonical exact cancelled snapshots; atomically update attempt, lease,
  task and acknowledgment. Reopen recognizes already committed acknowledgment
  without applying it twice. Keep pending replacement consumption in the existing
  reservation transaction. Extend the three Work test files listed above only
  for demonstrated missing coverage.
- [ ] **P1-6c-remote** after store: Preserve implemented receipts and proof
  consumption; repair only defects exposed by the required live/race tests. In `DistributedNodeExecution.swift`,
  `DistributedJobController.swift`, `DistributedWorkerModels.swift`,
  `DistributedWorkerLoop.swift`, `DistributedWorkerHTTPRouter.swift` and only
  if needed `DistributedWorkerProtocol.swift`, carry proof of worker stop using
  the existing authenticated worker completion route and durable job record.
  Controller cancellation intent/status alone is insufficient. Retain the exact
  job, lease token, worker incarnation and task-session attachment binding;
  acknowledge only after the worker has cancelled and joined its executor/process
  tree. A queued job proven never claimed may establish nonexecution atomically.
  A leased job needs worker acknowledgment, including after lease expiry; expired
  or missing heartbeat alone cannot establish it. Reject foreign/stale worker
  proof and late successful results. Preserve cancelled-job result semantics;
  use a minimal additive optional acknowledgment field if required, with absent
  legacy data meaning unacknowledged. Do not add a parallel transport or store.
  The task-backed caller awaits that proof before canonical cancellation
  persistence; failed/lost transport keeps the attempt fenced. Bound individual
  waits and surface uncertainty without releasing the fence. Preserve plain
  distributed cancellation and worker reuse; reuse Core controller, Server HTTP
  and distributed process regressions, extending only demonstrated coverage gaps.
- [ ] **P1-6c-live** after remote: Verify and complete the preserved connection of `TaskDispatch.swift` and
  `WorkflowRunCommand+TaskReservation.swift` to a run-owned bounded poll of exact
  durable pending requests. Use `TaskRunCancellation.swift` only as a cohesive
  helper for this lifetime, not a general service. Observe before admission and
  throughout running, interrupt once per request while allowing safe retry,
  and cancel/join the observer on every exit. In `TaskCommands.swift` preserve
  exactly-one-action and required identity/version parsing; distinguish request
  acceptance from task completion in existing output (`TaskCommandModels.swift`
  only if necessary). Route guard actions through the same applier. In
  `EntryPoint.swift`/`CLISignalCancellation.swift`, route task-backed Ctrl-C to
  the owner so the stable decision commits before cancelling execution; handle
  signals before reservation and repeated signals without a stale launch or
  duplicate decision. Other command cancellation remains compatible. Do not
  propagate parent cancellation to execution before the durable write finishes.
  In `WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift` and
  `WorkflowRunCommand+SupervisionPersistence.swift`, preserve reserved identity
  and await cancellation-safe terminal persistence. A prelaunch-cancelled
  reservation records its own cancelled snapshot without launching work.
  `TaskDispatch.swift` checks pending/acknowledged cancellation before generic
  reconciliation or completion/guard evaluation, projects evidence idempotently,
  and reserves a pending replacement once only after acknowledgment. Return
  explicit pending/error for persistence/stop uncertainty, retaining IDs/fence.
  `WorkflowRunCommand.swift` is already 998 lines: keep new cancellation logic
  in the cohesive helper; if the file exceeds 1000, move only existing finalization
  responsibility to `WorkflowRunCommand+Finalization.swift`, preserving access
  boundaries. No broad file splitting is authorized.
- [ ] **P1-6c-regressions** after live and evidence: Verify the preserved matrix below. Keep new live
  tests in `TaskCancellationIntegrationTests.swift` and its fixtures file to
  avoid enlarging the existing integration suite unnecessarily. Extend existing
  selected-host fixtures only where needed. Run all commands below on final
  implementation source, produce a source/test manifest, and record every
  failure honestly. Store-only tests cannot close this gate.

  Preserve the existing end-to-end selected-host test in
  `Tests/RielaCLITests/TaskCancellationIntegrationTests.swift` and
  `TaskCancellationIntegrationTests+Fixtures.swift`, including bounded process
  exit polling and Linux zombie handling. Repair only demonstrated gaps. Drive a
  real task reservation/dispatch to the authenticated selected worker, hold a
  real process at a deterministic readiness barrier, and invoke `task decide`
  from a separately owned CLI process against the same store. Assert selected
  host/job/reserved-session linkage and no local fallback. Observe the durable
  request before interruption, delay worker-stop proof to assert the request
  and lease remain fenced, then prove executor/process-tree exit and exact
  cancelled persistence before acknowledgment. Reopen/replay and compare
  decision, terminal evidence, usage and replacement counts. Do not replace
  this with a controller-only test or fabricated cancelled snapshot. The live
  command must select this test and record a positive count on a capable host.

  Match each matrix row to existing test names and final-source evidence first.
  The terminal handoff already records lost-response/reopen and independent
  replacement-contender tests; rerun those rather than duplicate their bodies.
  Extend only proven missing cases: terminal persistence failure before any
  canonical snapshot; lost acknowledgment response after commit (distinct from
  the existing transaction-failure test); lease/heartbeat loss with owned work
  still unproven; and two independent reservation contenders after acknowledged
  replacement, with exactly one request consumption/new session. Use barriers,
  shared-applier decisions and owned teardown; no direct decision-row mutation.
  Existing passing cases need final-source reruns, not duplicate test bodies.

  Historical context only: Step 6 continuation 3 added exact prelaunch cancelled snapshot persistence,
  task-run request-before-signal decision application and selected-host controller
  stop-proof consumption. Focused local and controller tests pass. Keep store,
  remote, live and regression boxes open. Continuation 4 adds passing focused
  acknowledgment-loss, terminal-projection failure, empty-controller proof and
  once-only replacement tests. Real selected-host dispatch, complete race and
  failure matrix, final-source V1/V11 and aggregate acceptance, reviews and
  publication remained pending then; current host evidence supersedes those
  historical listener failures. At this gate require all 24 assertions classified,
  material slice defects repaired and affected gates rerun on final source.
  Unrelated failed broad tests may proceed only as an explicit proposed slice-only
  disposition for independent review; unknown or material failures cannot.
- [ ] **P1-6c-integrity** and **P1-6c-adversarial** after regressions: Independent
  Sol read-only reviews may run concurrently. Integrity verifies test selection,
  positive counts, meaningful ordering/process assertions, final-source hashes,
  actual terminal exits, complete logs and every aggregate disposition. Both
  reviews explicitly accept or reject slice-only treatment of unrelated failures.
  Adversarial review exercises material
  races/failure cases against design; no style-only or speculative scope.
- [ ] **P1-6c-reconcile** after both reviews: Single Sol owner repairs all high/mid
  findings and shared-file drift, preserves accepted changes, reruns affected
  focused/aggregate/lint gates and obtains renewed independent acceptance where
  repairs invalidate review. Refresh design, plan, owner progress and directly
  affected README usage here, before final combined-tree review. Record unresolved
  broad failures and owners separately from P1-6c and active later slices. Shared
  indexes and documentation edits are serial; no unrelated README changes.
- [ ] **P1-6c-integration** after reconciliation: Independent Astra review accepts
  the exact combined tree, evidence and accepted design with no material open
  finding. Any repair repeats affected verification/review before acceptance.
- [ ] **P1-6c-finalize** after integration: Verify the reviewed docs and unchanged
  accepted source tree; any substantive new edit repeats affected review.
  Record exact changed-file allowlist and accepted hashes; workflow finalization
  commits and non-force pushes that exact accepted result to
  `origin/feat/remaining-impl-plans`. Record commit/push receipts. Keep parent
  plan active; do not archive it or close P1-6d/P1-7a/b. No main merge or release.

### Required regression matrix

| Requirement | Files and observable proof |
| --- | --- |
| Selected-host decision identities | Existing CLI fixture: record every reservation/acknowledgment/replay decision ID, kind and causality; exactly one human cancel, stable complete history/application and accounting on replay; explain both observed rows and pass capable-host rerun. |
| CLI validation/replay | `TaskCommandParsingTests.swift`, `TaskCommandMutationTests.swift`, `DecisionApplierStoreTests.swift`: absent/conflicting actions, blank principal/ID/reason, negative/missing version, step without rerun, valid actions; rejected inputs leave rows/version unchanged; identical replay returns original result; conflicting replay/stale new decision rejects. |
| Prelaunch and authorization race | Work reservation/cancellation tests plus `TaskCancellationIntegrationTests.swift`: deterministic barriers before authorization and node start; no worker/process launch if request wins; exact reserved cancellation snapshot; authorized uncertainty stays fenced. |
| Live local and separate-process decisions | Preserved CLI live tests: real owned command/process blocked at a deterministic fixture barrier, request from another store connection/process using CLI decision path, durable row observed before signal, process exit observed before acknowledgment, IDs match reservation. Cover cancel, reject, guard stop and replacement. |
| Ctrl-C | Preserved CLI live tests drive the actual EntryPoint signal path in an owned subprocess; prove durable request before interruption, repeated signals stable, pre-reservation signal does not launch work, ordinary non-task command cancellation unchanged. |
| Live selected host | CLI selected-host fixtures, `DistributedProcessCancellationTests.swift`, `DistributedWorkerHTTPTests.swift`, `DistributedJobControllerTests.swift`: authenticated chosen worker actually runs/stops, exact session/job linkage, no local fallback, no acknowledgment merely on HTTP acceptance, delayed worker-stop proof holds fence, stale lease/incarnation proof rejected. |
| Persistence and acknowledgment loss | Work and CLI live tests inject failure at terminal persistence and after snapshot/before acknowledgment; reopen store and reconcile exact snapshot; after committed acknowledgment simulate lost response and prove no duplicate transition, evidence, usage or replacement. |
| Negative terminal evidence | Wrong session, created/nonterminal snapshot, success and non-cancelled failure cannot release pending fence; generic reconcile blocked. No rewriting an unrelated outcome as cancellation. |
| Replacement and failure uncertainty | Pause between acknowledgment and reservation, reopen/replay twice, assert one consumed request/new session, no stale token launch or duplicate accounting; lease expiry, missing heartbeat, transport loss and inaccessible runner retain fence. |

Use deterministic readiness/barrier signals and bounded deadlines, not timing-only
sleep assertions. Every process/worker/server fixture is owned and awaited in
teardown even after failure. Capture live execution counts and exact session IDs;
mock DTOs or fabricated snapshots establish only store-level invariants.

### Verification commands and required evidence

Run commands in the foreground. Record each exact argv/environment, complete log,
terminal exit code, selected suites/counts and before/after source/test SHA256
under `tmp/work-runtime-p1/p1-6c/`; retain/poll any tool session to terminal exit.
If a named log already exists, use a new attempt subdirectory and record its
actual path; never overwrite prior evidence. Hash the complete source/test
manifest, including new files, not merely the two previously verified store files.
Do not use detached shell jobs. A logging wrapper under that directory must
propagate the child exit status, never just tee's status. Planning checks do not
substitute for these implementation gates.

**selected-live** — log `tmp/work-runtime-p1/p1-6c/<attempt>/selected-live.log`

```bash
CLANG_MODULE_CACHE_PATH=tmp/work-runtime-p1/p1-6c/module-cache SWIFTPM_MODULECACHE_OVERRIDE=tmp/work-runtime-p1/p1-6c/module-cache swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof
```

This retained planned command selects the same test as the passing host receipt;
it is not a claim about the operator's exact argv. Recover actual argv/environment
from `evidence.json` and its logs (the supplied host prefix has no scratch-path
flag). Reuse matching capable-host evidence only with explicit dependency/source
justification. Any changed cancellation or worker dependency requires a new host
run; never treat listener refusal as a behavioral failure or passing coverage.

**source-match, failure inventory and history** — complete logs under the new
attempt directory (`source-match.log`, `failure-inventory.log`, `history.log`,
`source-diff.log` respectively):

```bash
shasum -a 256 -c tmp/work-runtime-p1-6c-decision-20260924-c07910f-comm000006/continuation-2/source-test.sha256
rg -n 'Test Case .* failed \(| error: ' tmp/work-runtime-p1-6c-host-failure/capable-host-aggregate-current.log
git log -n 12 --format=oneline -- Sources/RielaCore/SurfaceCatalog+RowsCLI.swift Sources/RielaWork/CompletionEvaluator.swift Tests/RielaCLITests/TaskProjectionProofTests.swift
git diff 30601aa89485436440728bf417b0156ea477f25d -- Sources Tests
```

The original manifest is immutable baseline evidence: do not overwrite it after
repairs. Produce a new sorted manifest of every tracked/untracked `Sources/` and
`Tests/` file, `Package.swift`, `Package.resolved` when present and the HEAD ID;
record SHA-256 for each path and the manifest, then check it before/after every
accepted run. Compare its path set too, so newly added files are not omitted.
Record the diff from the host manifest and gate dependency relevance when reusing
historical evidence; unchanged cancellation sources alone do not prove unchanged
build inputs. A mismatching old manifest after authorized repairs is expected,
not permission to claim the old run used final source.

**catalog-projection** — log `<attempt>/catalog-projection.log`:

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'SurfaceCatalogTests|SurfaceParityCLITests|TaskProjectionProofTests'
```

Must pass all three suites with positive counts, preserving full catalog parity
and failed-session completion requirements.

**classification** — log `<attempt>/classification.log`:

```bash
swift test --disable-sandbox --skip-update --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'DoctorCommandTests|RielaExampleParityTests|WorkflowCommandTests|WorkflowTemporaryRegistrationTests|WorkflowRunnerAdmissionTests'
```

Capture all selected suite counts and each failed assertion. This can remain
failed for evidenced unrelated defects; it cannot silently skip tests or serve
as passing P1-6c evidence. History command paths above cover proposed repairs;
repeat `git log -n 12 --format=oneline -- <exact-affected-paths>` and
`git show <identified-commit>:<exact-path>` for every other failure's fixture and
production dependency, recording resolved commands/commits in its record.

**V0** — log `tmp/work-runtime-p1/p1-6c/V0.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
```

**V1** — log `tmp/work-runtime-p1/p1-6c/V1.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests|TaskCancellationIntegrationTests'
```

**V2** — log `tmp/work-runtime-p1/p1-6c/V2.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|BudgetAdmissionDecisionApplierStoreTests'
```

**V11** — log `tmp/work-runtime-p1/p1-6c/V11.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests|TaskCancellationIntegrationTests/testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof'
```

**decisions** — log `tmp/work-runtime-p1/p1-6c/decisions.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandParsingTests|DecisionApplierStoreTests'
```

**live** — log `tmp/work-runtime-p1/p1-6c/live.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCancellationIntegrationTests|DistributedProcessCancellationTests'
```

**compatibility** — log `tmp/work-runtime-p1/p1-6c/compatibility.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'
```

**projection classification** — log `tmp/work-runtime-p1/p1-6c/projection.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter TaskProjectionProofTests
```

This focused reproduction classifies the observed `acceptanceNotMet` mismatch;
it does not replace the affected aggregate or justify weakening its assertion.

**aggregate** — log `tmp/work-runtime-p1/p1-6c/aggregate.log`

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaCLITests|RielaWorkTests|RielaCoreTests|RielaServerTests'
```

**lint** — log `tmp/work-runtime-p1/p1-6c/lint.log`

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6c/changed-swift-files.nul
```

**diff** — log `tmp/work-runtime-p1/p1-6c/diff.log`

```bash
git diff --check
```

**staged-diff** — log `tmp/work-runtime-p1/p1-6c/staged-diff.log`

```bash
git diff --cached --check
```

V0 is compile/typecheck. V1 proves task behavior; V2 covers reservation,
cancellation and budgets; V11 covers selected-host/controller/HTTP behavior.
The decisions and live commands explicitly select suites omitted by V1/V2/V11.
Compatibility protects accepted read-only dry-run and result behavior. Aggregate
covers affected CLI, Work, Core and Server targets including plain workflows.
Require positive counts for every named suite; absence is a failure. Add exact
filters for any extra suite introduced by a necessary seam before claiming
coverage. No web/UI changed, so browser/AppKit checks are not required.

Before lint generate `changed-swift-files.nul` from the exact task-owned changed
Swift allowlist, including new untracked Swift files; validate every path exists
and reject an empty list. Do not select only `git diff` tracked files or include
unrelated changes. Record that list in the evidence manifest. Strict changed-file
SwiftLint must pass; retain repository baseline exceptions separately.

If the exact scratch command fails due to module-cache permissions, record its
failure and retry with absolute repo-local `CLANG_MODULE_CACHE_PATH` and
`SWIFTPM_MODULECACHE_OVERRIDE` under the evidence directory, recording full env.
If listeners cannot run, retain the failed log and identify the exact bounded
environment cause. Run the same filters on a capable host against matching full
source/test manifests before and after execution; record the actual host argv,
environment, logs and exits. Do not treat P1-6b host evidence or a reduced filter
as P1-6c acceptance. Unavailable host evidence remains an explicit verification
gap. No blanket test skipping or unrelated baseline repair. Packaged workflow,
prompt, script and skill files are outside this plan, so package digest refresh
is unnecessary unless a
subsequently accepted edit actually changes a packaged workflow/prompt/skill.

### Completion criteria

Both live-test decisions retain verified ID, kind and causal evidence; any
new justified production or expectation correction passes an affected capable-host rerun
without weakening replay/accounting assertions. All matrix behaviors have
passing final-source evidence, or bounded environment
failures are recorded alongside passing source-matched capable-host evidence.
Catalog/projection gates pass. All 24 original assertions and any new failures
have explicit evidence-backed dispositions; no unknown or material slice failure
remains. Broad failures stay failed with follow-up ownership, and unrelated
residuals require independent slice-only acceptance.
Strict lint and compile pass; independent integrity/adversarial/Astra decisions
accept the exact tree without high/mid findings. Documentation accurately reports
request acceptance versus terminal acknowledgment. Progress records review/log/
hash evidence and exact committed/pushed files. Only then mark P1-6c complete;
P1-6d, P1-7a/b and parent P1 remain open. Do not reuse the historical P1-6b task
checkboxes, hash comparison or host receipt as new-slice completion evidence.

**Current status:** Source-matched capable-host cancellation selections pass;
catalog/projection repairs, complete assertion classification, final-source
affected gates, reviews and publication are pending. No implementation task is
marked complete solely by this planning refresh.

### Current planning author self-check

Step 3 `comm-000004` accepted the host-evidence/classification design with empty
findings/feedback. Step 5 has not reviewed these revised plan bytes. One plan
`p1-dispatch` retains `dependsOn: []`; its internal DAG orders receipt checks and
classification, serial conditional repair, preserved seam verification, final
gates, independent reviews, serial reconciliation/docs and Astra acceptance
before publication. No user decision, new architecture or branch is introduced.

Run `python3 tmp/p1-6c-step4-host-refresh/self-check.py`; complete log:
`tmp/p1-6c-step4-host-refresh/self-check.log`. It checks design hash, metadata/DAG,
write paths, task and command coverage, preservation of every other tracked and
untracked input file, unchanged index and whitespace. Planning checks do not
claim Swift, lint, implementation-review or publication acceptance.

---

## Historical P1-6b completed contract

### Intent, context, and non-goals

Independently review and conditionally finalize the existing task-run result and
allocation-free dry-run WIP on `feat/remaining-impl-plans`, planning checkpoint
`788d45a44f1da19ea2a85f311ace19a8eec31202`, retaining accepted P1-6a dispatch.
The eight Swift changes, unchanged SQLite helper and plan/progress/design edits already exist; preserve
them. Recheck actual status before review; never reset changes. Coding may be
re-dispatched only for an independently proven material defect.
The supplied effective workflow input and runtime provenance are authoritative.
Do not inspect the executing package or scoped registries.

No director, human-decision/cancellation redesign, legacy removal, new examples,
new schema, general persistence framework, new dependency, broad formatting,
main merge, worktree creation or unrelated baseline repair is authorized.
P1-6c/d, P1-7a/b and parent P1 remain open. Existing examples are regression
fixtures only. Preserve other sessions/worktrees, including Monja tenant-sharding-d48.
Codex references are workflow identities; no Cursor adapter or source-parity task applies.

### Ownership, dependencies, and safe edits

`dependsOn: []` means no newly scheduled external plan; P1-6a is an accepted
prerequisite at the commit above, not work to rerun or reopen. The metadata DAG
orders evidence audit → result/read-only reviews → combined verification →
conditional finalization. Native Riela owns dependency-ready review waves;
this node creates no implementation fanout.
All listed paths are exclusively owned by this single implementation owner;
reviewers inspect without edits. The write set is a ceiling, not a demand to
change every file. All code/test edits are conditional on an independently proven material defect.
The two focused test files already exist and are included in host evidence. No other path is implicitly writable: a needed
path expansion requires a concrete finding, exact path and bounded plan/review
amendment before editing, not a blanket new abstraction or unrelated repair.

Current reviewed repair: the live zero-byte-WAL immutable amendment was
withdrawn. `Sources/RielaSQLite/SQLiteDatabase.swift` has no diff and must retain
its baseline behavior. Confirm canonical first-match store selection, private
preview copies, rejection of nonempty WAL, and original main/WAL/SHM byte and
inventory comparisons after copying and before ready/wait output. Confirm
live WorkStore/TaskDispatcher reads retain their prior SQLite mode. Read the
original test-integrity, adversarial and Astra reports under
`tmp/work-runtime-p1-6b-review-20260924-f8c9188-comm000008/`; record each actual
artifact path, reviewer identity, final hashes, findings and decision. Progress
summaries alone are not independent acceptance. If an original decision cannot
be substantiated, report that specific evidence gap and obtain the required
independent review; do not infer a code defect or rerun passing tests by default.

Before each edit, fresh-read the file and capture SHA256 plus an immutable
intent snapshot under `tmp/work-runtime-p1/p1-6b/attempt-N/` recording intended
hunks and accepted requirement. Record post-edit hashes. Compare predecessor
hashes at every handoff; preserve unexpected changes, invalidate affected
verification, and reconcile serially instead of restoring whole files. No
concurrent Git operations or private implementation branches. Before native implementation/review fanout, Step 5 must accept this plan
and the serial checkpoint gate must commit the accepted design and plan with
an exact documentation-only allowlist, preserving all existing Swift and
progress WIP. This author node does not commit or preempt Step 5. No coding
fanout is requested: the default work is evidence confirmation. Any conditional
material repair follows accepted plan/checkpoint gates. Final implementation
commit/push remain downstream of independent acceptance. Reconcile checkpoint
publication serially before final commit so native push gates do not receive
an unexpected stack of unpublished commits.

Workers append only to `impl-plans/progress/p1-dispatch.md`. Shared indexes,
lockfile generation, formatting and global archiving are reserved for serial
finalization and are unnecessary for this slice. Never archive this parent plan.
If native join supplies change evidence, the serial integration owner compares
all intended hunks and hashes and repairs overwritten accepted behavior before
independent combined-tree review.

### Tasks and exact deliverables

All boxes below are current evidence-confirmation/finalization gates, not
instructions to redo prior coding or discard prior reviews. Result/read-only
review tasks first confirm the existing independent decisions on final hashes;
new review is required only where evidence is missing or a material concern remains. Historical completed implementation remains recorded in progress.

- [x] **P1-6b-audit** (wave 1, single owner): Fresh-read accepted §17.5, the nine
  Swift files in `writePaths`, both exact manifests and complete host log.
  Recompute nine hashes, inventory current diff/untracked files and record
  source identity plus the host command/exit 0/198 tests. Preserve the earlier
  sandbox aggregate as failed, exit 1, including 24 listener/dependent failures.
  Deliver an evidence inventory and review inputs in repository-root `tmp/`.
- [x] **P1-6b-results** (wave 2, independent test-integrity review, read-only):
  Inspect `Sources/RielaCLI/TaskDispatch.swift`,
  `Tests/RielaCLITests/TaskCommandParsingTests.swift`,
  `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`, and
  `Tests/RielaCLITests/TaskRunResultTests.swift`. Trace text/JSON placement,
  ready/wait without allocation, typed reasons, nonzero failure exits,
  pre-admission failure envelopes and exact durable reserved attempt/session
  IDs after admitted errors. Inspect read-only fixtures and snapshots in
  `Tests/RielaCLITests/TaskDryRunReadOnlyTests.swift` for real APIs, complete
  row values and nonmutating observation. Deliver findings with severity,
  paths, concrete evidence and an explicit private-copy repair accept/reject
  decision; no edits or inferred pass from row counts alone.
- [x] **P1-6b-readonly** (wave 2, independent adversarial review, read-only):
  Trace `Sources/RielaCLI/TaskDispatch.swift`,
  `Sources/RielaCLI/HostCapabilityResolver.swift`,
  `Sources/RielaWork/TaskDispatcher.swift`, `Sources/RielaWork/WorkStore.swift`
  and `Sources/RielaSQLite/SQLiteDatabase.swift`. Verify no writable fallback,
  initialization, migration, checkpoint, quarantine, profile persistence,
  reservation, pending-request consumption or launch on preview. Assess
  absent/corrupt/incompatible stores, profiles and sidecars; byte/inventory and
  row-value invariance includes `work_hosts`. Corrupt undecodable data requires
  diagnostic and byte invariance, with row comparison explicitly inapplicable.
  Assess zero-byte/absent WAL handling, rejection of nonempty WAL before either
  store opens, shared-reader compatibility and concurrent-writer races. Deliver
  a separate explicit private-copy repair accept/reject decision and material
  findings supported by evidence, not hypothetical hardening requests.
- [x] **P1-6b-verification** (wave 3, serial join and independent Astra
  combined-tree integration review): Join both reports and recheck all hashes.
  Astra explicitly decides the private-copy repair and combined result/placement/
  reservation contract against accepted §17.5 and P1-6a regression evidence.
  All three reviews must have no unresolved material correctness, data-loss,
  security or verification defect. Only an independently demonstrated defect
  authorizes a serial repair: record finding, exact affected paths, pre/post
  hashes and intent; change the smallest required behavior/test in the allowlist,
  rerun affected compile/tests/lint below, then repeat affected independent
  reviews on the repaired tree. If another path is necessary, obtain a bounded
  plan/review amendment first. Preserve unexpected drift and reconcile serially.
  Unchanged bytes reuse completed host gates; never rerun solely because this
  is a new workflow. Deliver final hash manifest and all three review decisions.
- [x] **P1-6b-finalization** (wave 4, downstream serial workflow gates): After
  acceptance, align §17.5 and P1-6b plan/progress evidence. The README Work
  Runtime section lacked the accepted read-only preview and result contract;
  include its bounded Step 8 amendment in publication.
  Append commands, terminal exits, positive suite counts, complete logs, hashes,
  retained-code attribution and independent decisions to
  `impl-plans/progress/p1-dispatch.md`. Step 9 explicitly records P1-6c/d,
  P1-7a/b and parent P1 open and retains this active plan. Emit the exact reviewed
  file allowlist (the eight changed Swift files plus README and directly affected
  design/plan/progress; exclude reverted `SQLiteDatabase.swift` and already
  committed checkpoint-only docs from a later commit).
  Native commit/push gates publish only accepted files, non-force to
  `origin/feat/remaining-impl-plans`, verifying matching accepted commit/push
  evidence. No broad staging, tmp files, force push, main merge or unrelated
  worktree changes. No workflow/prompt/script/skill change or digest refresh.

### Invariants and acceptance matrix

| Accepted requirement | Passing evidence |
| --- | --- |
| CLI parsing and typed text/JSON | Valid and invalid parsing; shared option precedence; text placement; typed diagnostics; correct nonzero failure exits |
| Exact identity and wait reason | Output IDs equal reserved durable rows on successful and failed admitted runs; ready/wait allocate nothing; wait reason matches dispatcher |
| Read-only dry-run | Same resolution/prospective placement, all byte/inventory/row-value checks unchanged across the matrix above; no misleading stale WAL read |
| P1-6a preserved | Final-source reservation and selected-worker/callee execution regression gates pass |
| Bounded publication | Independent test-integrity/adversarial/Astra integration acceptance, including the private-copy repair, without unresolved material finding, exact file allowlist, matching committed/pushed hash; later slices open |

A preview is not a launch promise: real admission still rechecks dependency,
version, budget and capacity races. Do not add a second direct-mutation path or
weaken authentication, placement pinning, reservation tokens or uncertainty fences.

### Exact verification and evidence

All commands run in the foreground from repository root. Capture full stdout
and stderr, exact argv/environment, start/end timestamps, terminal exit code,
per-suite positive test counts and final relevant source SHA256 inventory in
`tmp/work-runtime-p1/p1-6b/attempt-N/verification-evidence.json`. Use immutable
numbered attempts, the log names below and the existing shared scratch path;
never run SwiftPM gates concurrently against it. Poll every yielded session
through terminal exit. Incomplete logs, timeouts and zero/absent selected suites
are failed/blocked checks, never passes. Reuse only evidence matching final
relevant sources and fixtures; unrelated documentation edits alone do not
invalidate Swift tests. The recorded host pass is reused evidence, not a fresh run by this plan author.
The commands below are conditional rerun gates; do not execute them all by
default on unchanged source bytes. The host aggregate in metadata includes
`SQLiteDatabaseTests`, both focused files, V1/V2/V4/V11 and parsing; use its
exact command for a full affected aggregate rerun on a listener-capable host.
A listener-denied run remains failed; retain its complete log and exit.

**Always-run source identity — hash-check.log**

Run this command before reviews and again before finalization. Capture its full
output and exit; any mismatch invalidates affected evidence and requires drift
reconciliation before acceptance. A documentation-only change does not invalidate
these nine Swift hashes.

```bash
python3 - <<'HASHCHECK'
import hashlib, json
from pathlib import Path
host = json.loads(Path("tmp/work-runtime-p1-6b-host-final/evidence.json").read_text())
prior = json.loads(Path("tmp/work-runtime-p1-6b-review-20260924-f8c9188-comm000008/plans/p1-dispatch/attempt-1/verification-evidence-final-source-v2.json").read_text())
assert len(host["sourceHashes"]) == 9
for path, expected in host["sourceHashes"].items():
    actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    print(path, actual, flush=True)
    assert actual == expected == prior["sourceHashes"][path], path
print("PASS: 9/9 hashes match both manifests")
HASHCHECK
git diff --check
git diff --cached --check
```

Record each command's own exit code, not only the last shell command. Inspect
`tmp/work-runtime-p1-6b-host-final/aggregate.log` and the prior manifest's complete
logs; record the host aggregate's exact metadata command, exit 0, 198/198 and
per-suite counts separately from the failed sandbox run. The hash comparison
alone is not behavioral acceptance. Repaired bytes require a new manifest;
never overwrite the original evidence or claim old hashes match new code.

**V0 compile/typecheck — build.log**

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
```

**Parsing — parsing-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandParsingTests'
```

**V1 focused behavior — focused-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
```

**V2 reservation regression — reservation-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests'
```

**V4 capabilities/profile regression — capability-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
```

**V11 selected-host regression — selected-host-tests.log**

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
```

V1 retains each named suite, including existing task examples; it does not
certify later slices. Require positive counts for each selected suite. V2 proves
reservation/cancellation/budget compatibility. V4 proves placement and profile
read compatibility. V11 proves real selected-host and exact-session behavior.
The two focused test files are already present. If their evidence is invalidated,
run their gate and require a
positive count for each created suite (adjust the filter to the created names
and record exact argv; never report a missing suite as passing):

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskRunResultTests|TaskDryRunReadOnlyTests'
```

If store evidence is invalidated, also run:

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreTests|TaskCommandTests|SQLiteDatabaseTests'
```

Before lint, build `tmp/work-runtime-p1/p1-6b/changed-swift-files.nul` from the
reviewed exact changed/new Swift paths relative to the accepted implementation
baseline; include newly created files, exclude unrelated changes, record the
list in evidence and require it nonempty. Never invoke xargs with an empty list.
**Strict changed-file lint — swiftlint.log**:

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-6b/changed-swift-files.nul
git diff --check
git diff --cached --check
```

Capture diff checks as `diff-check.log` and `cached-diff-check.log` respectively;
the cached check is repeated by finalization after accepted staging. Inspect
changed Swift file sizes and keep files within the skill's 1000-line rule using
the named focused test files, without broad unrelated extraction. Build/tests
must compile touched modules. Broaden only for a concrete shared-path risk or
new failure; record exact additional command and reason. Pre-existing failures
remain failures: require an explicit independent bounded disposition, never
suppress them, count a failed gate as passing or repair unrelated baseline work.

### Completion and progress state

| Item | Current slice state |
| --- | --- |
| P1-6a | Accepted prerequisite at 2f10916; preserve |
| P1-6b | Nine final Swift hashes match both manifests; host aggregate passed 198/198, including listener-backed selected-host/HTTP cases. Independent test-integrity, adversarial and Astra combined-tree reviews accepted with no material finding. Commit `7d8fc12` was non-force pushed; the resumed workflow completed. |
| P1-6c/d, P1-7a/b | Deferred/open |
| Parent P1 | Open; no global certification or archiving |

No unresolved user decision or design defect was identified. Progress entries
must distinguish source inspection, actual verification and independent
acceptance; record exact retained files, concrete repairs, hash drift and
invalidated/reused evidence. Design/plan acceptance is not implementation
acceptance. Finalization requires all scoped acceptance rows and reviewer
findings resolved, matching final-source evidence and exact accepted publication.

Current final-source follow-up (2026-09-24): Step 3 accepted §17.5 via
`comm-000004`, with no findings. All nine current hashes match the final host
and Step 6 v2 manifests. The host complete log confirms 198/198, recorded exit
0; prior safe suites are 169/169 and 15/15, and strict changed-file SwiftLint
records exit 0. Preserve their exact commands/log paths from the manifests.
The sandbox aggregate remains failed, exit 1 with 24 failures. The preserved
Step 6 runtime payload records the original test-integrity and adversarial
acceptances and Astra's source acceptance with verification withheld. Its
verbatim reviewer transcripts are unavailable; fresh read-only test-integrity,
read-only behavior, and Astra combined-tree reviews accepted the same nine-hash
tree with no material finding. The host 198/198 closes the recorded verification
condition. Serial commit/push evidence remains pending; no user decision is required.

### Historical evidence chronology (superseded by current follow-up)

Operator-host follow-up after Step 6 terminal (2026-09-24): the nine Swift
source/test hashes in `tmp/work-runtime-p1-6b-host/evidence.json` match Step 6's
`verification-evidence-exact.json` before and after the host run. Using the
already resolved SwiftPM scratch path, the full P1-6b selected aggregate,
including listener-backed `TaskDispatcherIntegrationTests` and
`DistributedWorkerHTTPTests`, passed 194/194 with exit 0. The complete command,
log and exit are in `tmp/work-runtime-p1-6b-host/evidence.json` and
`aggregate.log`; `git diff --check` passed. This replaces the sandbox-only V11
verification gap for these unchanged source bytes, but it is not independent
review or publication acceptance. The SQLite shared-path amendment, remaining
P1 slices and parent P1 still require their own decisions.

Step 6 review continuation (2026-09-24): independent test-integrity and
adversarial reviews rejected the live zero-byte-WAL immutable amendment after
identifying a concurrent-writer race. `SQLiteDatabase.swift` is restored to
the checkpoint bytes. Preview now resolves stores in canonical first-match
order using private database copies, rejects nonempty WAL, and checks original
main/WAL/SHM bytes before returning ready or waiting. Live WorkStore and
TaskDispatcher reads retain their baseline SQLite mode; only private copies
use immutable reads. New tests cover an intervening writer, first-match scope,
and text/JSON admitted failure identities. Test-integrity, adversarial, and
Astra combined-tree source reviews accept this repair with no remaining
material code finding. Current-source safe suites passed 169/169 and 15/15;
strict selected-file SwiftLint passed. The final-source sandbox aggregate ran
198 tests and failed with 16 listener denials and eight dependent expectation
failures (exit 1). The prior
host 194/194 pass has six mismatched Swift hashes and cannot certify the
repair. Final-source listener-capable aggregate, publication review, exact
commit and non-force push remain pending. Complete logs and hashes are under
`tmp/work-runtime-p1-6b-review-20260924-f8c9188-comm000008/plans/p1-dispatch/attempt-1/`.

## Historical parent-plan reference — not executable in this invocation

The following pre-P1-6b parent narrative is retained to preserve later work and
historical evidence. Its former scope, unchecked P1-6a status, predecessor
inventories and broad gates are superseded for this invocation by the current
contract above. Do not schedule, certify, update indexes for, or execute its
later tasks as part of P1-6b. Historical metadata is available in Git at
`2f10916a14501af68fd7e7f63cb91f244a343f8c` under this same plan path.

## Intent, authority and repository context

Complete every unchecked P1-6a–d and P1-7a–b requirement by reconciling retained
implementation, including necessary reservation, guard, capability and shared
applier repairs. Accepted design §17.7 governs this single plan; older six-plan
scheduler metadata is historical. The complete effective implementation input
is this file alone. `dependsOn: []` means no external scheduler predecessors;
it does not waive the internal prerequisite gates below. Supporting reservation,
guard/director, capability and finalization plans supply reference detail only;
do not launch or implement them as additional work packages.

Inspected HEAD is `f46ff788d522b6e53631862253fdcbcf17adfb1a` on
`feat/remaining-impl-plans`, also the deliberate base branch; supplied upstream
is `origin/feat/remaining-impl-plans`. Preserve the intake’s 93 retained files
(49 tracked, 44 untracked, zero staged) and the accepted Step 2 design edit.
Step 4 therefore starts with 50 tracked changes and 44 untracked files; its
plan edit adds one tracked change. The older 50/44 inventory predates the
f46ff788 checkpoint; reconcile exact paths/hunks rather than using counts
as ownership evidence. These include
dispatch, capability and example code. The CLI still rejects
`.director` dispatch in `Sources/RielaCLI/TaskDispatch.swift`; the retained
`AgentDirector.validate` escalates all accept output. Reconcile these concrete
P1-6d gaps; do not replace retained code wholesale or certify it from inventory.
Step 4 edits only this plan and preserves all prior source/design/progress work.

Runtime provenance is authoritative. Effective input requires the immutable
user-scope workflow package and supplies no minimum or exact version.
No contradiction exists; do not inspect, repair or validate registries or the
executing package from this node. No worktrees, private branches, concurrent
Git mutations, or changes to other directories/sessions. Preserve all unrelated
work and Monja tenant-sharding-d48. Commit/push of accepted P1 and necessary
documentation are authorized; finalization remains gated below.

Non-goals: P2–P7, loop-engineering, agent-node-output-contract, workflow defect
detection, Tauri, Note, gateway SDK, Monja implementations, task serve, new task-create CLI, remote
authentication, planner frameworks, compatibility/migration for removed
auto-improve state, recursive director repair, proposals, specialist classifiers,
optional hardening, style-only changes, broad cleanup or formatting. Preserve
accepted workflow-defect documents. Record external dependencies rather than
absorbing them. The supplied local Codex reference root
`../../codex-agent` is absent in accepted design evidence. Agent references are
execution provenance, not parity claims. Cursor-specific invocation/auth/probe/
heartbeat behavior stays in existing adapters; no cross-backend equivalence.

## Internal dependency gates and ownership

One implementation integration owner executes this plan. The DAG in metadata
orders tasks within this package; it is not a list of missing external plans.

| Wave | Tasks | Deliverable / gate |
| --- | --- | --- |
| 0 | P1-AUDIT | Fresh retained-diff attribution, source hashes, lint baseline, existing interface inventory; run canonical sandbox regression without editing workflow/package artifacts. |
| 1 | P1-PREREQ-R | Verify/repair only reservation primitives needed by §17.2: atomic rollback, dependency/version race, unique exact session, single-use digest token, uncertain launch fence, pending request consumption and durable cancellation acknowledgment. V2 and relevant store tests pass. |
| 2 | P1-PREREQ-L | Verify/repair §17.2–17.3 guard, deterministic ordering, causality, replay, store completion and budget enforcement. V3 passes against accepted reservation hashes. |
| 2 | P1-PREREQ-C | Verify/repair §17.4 reachable requirements, bounded probes, declarations, freshness, placement and host/planner inputs. V4 passes against accepted reservation hashes. |
| 3 | P1-6a, then P1-6b/c | Wire real exact-session dispatch, preview and human decisions; prerequisite checks must already pass. |
| 4 | P1-6d | Bounded child execution and authoritative judged-work acceptance; focused store, director and CLI integration checks pass. |
| 5 | P1-7b, then P1-7a | Task-backed examples and before-removal replacement evidence, then legacy removal and after-removal evidence. |
| 6 | P1-FINAL | Serial join/repair, aggregate tests/lint, author self-review, single adversarial implementation review, combined-tree review, docs/index reconciliation and final publication handoff. |

Independent investigation of lifecycle and capabilities may run in parallel
only after reservation interfaces are stable. Implementation overlap in schema,
store, CLI and tests is serialized, even within the same wave. P1-6b/c may use
parallel read-only investigations; the integration owner writes their shared
files. Child investigators return evidence to this plan's owner, who alone
appends `impl-plans/progress/p1-dispatch.md`. Do not edit another worker's log.
No additional executable plan files are created for tightly coupled repairs.

Each prerequisite handoff records source hashes, concrete interface signatures,
owner, exact passing command/log/final exit, positive suite counts and review
status. Inspect current code before deciding repair is needed. Unchanged code
can pass with fresh behavioral evidence; never invent changes or accepted IDs.
Failure blocks dependent tasks, while independent investigation may continue.
The canonical sandbox check concerns checked-in real payloads only; a failure
outside accepted P1 scope is reported as a dependency with command/log/exit,
not repaired through package rediscovery or unrelated workflow implementation.

After Step 5 accepts, the serial workflow checkpoint gate commits exactly the
accepted design and this plan before any native implementation/review fanout.
It preserves the existing index and excludes retained source, tests, progress
and scratch. Push that checkpoint before final git-push so exactly one
unpublished final commit remains. Record the checkpoint hash and publication
evidence; do not leave checkpoint commits stacked below an unpublished final
commit. This Step 4 neither commits nor certifies implementation. Later
final commit/push contains only accepted P1 implementation and necessary docs.

## Edit integrity and evidence ownership

Before EVERY edit, including deletion and retry, fresh-read the file and
contract; record pre-edit SHA-256 (or absent sentinel), original bytes, exact
paths, accepted requirement and intended behavior under immutable numbered
`tmp/work-runtime-p1/p1-dispatch/intents/` directories. Recheck hash immediately
before writing. On drift, stop, reread and create a new intent; never overwrite
from stale buffers. Record post-hash, exact diff and preserved behaviors.
After join, compare semantic changes to intents, repair serially and rerun
invalidated gates. Hashing alone cannot eliminate races; runtime change evidence
and independent combined-tree review remain required if work fans out.

Materialize exact paths from metadata globs before edits; metadata is a scope
ceiling, not permission to modify unrelated hunks. Necessary helper extractions
require exact-path ownership and accepted-requirement evidence first. Keep
builds/source verification stable: serialize commands against a stable source
snapshot and compare relevant source hashes before/after each run. A source
change during testing invalidates certification. Lockfile changes, all shared
indexes, final commit allowlist and any archiving are serial-only. No broad
formatting; no global archive or unrelated lockfile update is needed here.

## Prerequisite file-level repair map

The exact paths below belong to this plan's serial integration owner only for
necessary P1-6/7 prerequisite repair. Prefer proving retained code correct.

### P1-PREREQ-R

Atomic attempt/session/lease/decision placement commit, rollback, launch token, pending request and cancellation fencing. Preserve schema generation policy and P0 reads; use task-owned scratch stores, never reset user databases.

Exact repair/test paths:

- `Package.swift`
- `Sources/RielaWork/WorkModels.swift`
- `Sources/RielaWork/WorkStore.swift`
- `Sources/RielaWork/WorkStore+Schema.swift`
- `Sources/RielaWork/WorkStore+Reservation.swift`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
- `Tests/RielaWorkTests/WorkStoreTests.swift`
- `Tests/RielaWorkTests/WorkStoreReservationTests.swift`
- `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`
- `Sources/RielaWork/DecisionApplier.swift`
- `Sources/RielaWork/WorkStore+Decisions.swift`

### P1-PREREQ-L

Persist complete guard batch before action; stable priority/tie order, exact equality boundaries, last-admitted-attempt completion, budget admission, scoped causality, original replay and store-reconstructed completion. Human acceptance waives only requiresHumanAccept.

Exact repair/test paths:

- `Sources/RielaWork/WorkGuard.swift`
- `Sources/RielaWork/TaskGuardCoordinator.swift`
- `Sources/RielaWork/DeterministicDirector.swift`
- `Sources/RielaWork/DecisionApplier.swift`
- `Sources/RielaWork/CompletionEvaluator.swift`
- `Sources/RielaWork/WorkStore+Decisions.swift`
- `Sources/RielaWork/WorkDecision.swift`
- `Sources/RielaWork/WorkEvidence.swift`
- `Tests/RielaWorkTests/WorkGuardTests.swift`
- `Tests/RielaWorkTests/WorkGuardDispatcherTests.swift`
- `Tests/RielaWorkTests/DeterministicDirectorTests.swift`
- `Tests/RielaWorkTests/DecisionApplierTests.swift`
- `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`
- `Tests/RielaWorkTests/CompletionEvaluatorTests.swift`

### P1-PREREQ-C

One reachable/called-node requirement set and merged finite-freshness snapshot; disable wins, explicit unprobed enable stays unverified, failed refresh is not stale success, pin never falls back, declared capacity/liveness and required executables/environment are enforced. Host/profile reads stay nonmutating for dry-run.

Exact repair/test paths:

- `Sources/RielaCore/BackendCapability.swift`
- `Sources/RielaCore/WorkflowBackendPolicy.swift`
- `Sources/RielaCore/WorkflowRequirements.swift`
- `Sources/RielaCore/WorkflowModel.swift`
- `Sources/RielaCore/WorkflowNodeValidation.swift`
- `Sources/RielaCore/WorkflowValidationHelpers.swift`
- `Sources/RielaCore/DistributedWorkerModels.swift`
- `Sources/RielaAdapters/BackendCapabilityProbe.swift`
- `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`
- `Sources/RielaWork/BackendCapabilityPlacement.swift`
- `Sources/RielaWork/WorkStore+Hosts.swift`
- `Sources/RielaWork/WorkStore+Schema.swift`
- `Sources/RielaCLI/DoctorCommand.swift`
- `Sources/RielaCLI/DistributedWorkerCommand.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift`
- `Sources/RielaCLI/HostCapabilityResolver.swift`
- `Sources/RielaServer/DistributedWorkerProtocol.swift`
- `Sources/RielaServer/DistributedWorkerHTTPRouter.swift`
- `Sources/RielaServer/DistributedWorkerHTTPClient.swift`
- `Tests/RielaWorkTests/BackendCapabilityPlacementTests.swift`
- `Tests/RielaCLITests/DoctorBackendCapabilityTests.swift`
- `Tests/RielaCLITests/WorkflowHostCapabilityTests.swift`
- `Tests/RielaCLITests/DistributedWorkerConfigurationTests.swift`
- `Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift`
- `Tests/RielaAdaptersTests/BackendCapabilityProbeTests.swift`
- `Sources/RielaAppSupport/DaemonWorkflowSupport.swift`
- `Sources/RielaAppSupport/RielaAppDaemonWorkflowStore.swift`
- `Tests/RielaAppSupportTests/HostCapabilityConfigurationTests.swift`

Additional retained integration paths are `Sources/RielaCLI/WorkflowValidationOptions.swift`,
`WorkflowCalleeResolution.swift`, `ServeHTTPCommand.swift` (all RielaCLI),
`Sources/RielaCore/WorkflowValidation.swift`, `DistributedJobController.swift`
(RielaCore), `Sources/RielaServer/DistributedControllerHost.swift`,
`DistributedWorkerLoop.swift` (RielaServer), and
`Sources/RielaApp/EntryPoint+DistributedController.swift`. Verify only capability
snapshot registration/forwarding and selected host/backend execution in those
paths; no UI redesign or distributed subsystem redesign. Required matching
regressions include `Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`.
Add retained `WorkStoreCancellationTests`, `BudgetAdmissionStoreTests` and
`DecisionApplierCausalityStoreTests` under `Tests/RielaWorkTests` to prerequisite
gates so aggregate filters cannot hide these new regressions.

## Intended changes and acceptance (§17.2–17.5)

- [ ] **P1-6a** Compose TaskDispatcher with canonical stored plan/definition and
  runtime store resolution. Resolve selected entry, dependencies and placement
  before reservation. Missing plan/entry/dependency or invalid policy errors;
  unmet dependencies/capacity records its wait without attempt/session/lease.
  Atomically reserve and authorize, then run EXACT reserved session ID through
  the existing runner. Project terminal evidence before guard/completion and
  apply decisions through the shared applier. Refresh real dispatch placement
  once before reservation and use the chosen per-node backend/host in execution.
- [ ] **P1-6b** Ship task run <task-id> [--dry-run] with attempt/session IDs or
  wait reason. Dry-run follows identical resolution but opens state read-only:
  no create, migration, generation reset, checkpoint, host-cache, task, attempt,
  session, decision, lease or evidence writes. Missing/incompatible stores are
  diagnostics; fresh probes remain in memory. Prove byte AND row equivalence
  including work_hosts, SQLite sidecars and host profile configuration; an
  absent store stays absent and corrupt profile config is not quarantined.
- [ ] **P1-6c** task decide requires exactly one --accept, --reject <reason>,
  --rerun [step], --cancel plus --principal, --expected-version, --decision-id.
  Human principal is audit identity under existing local access, not new remote
  authentication. Validate action combinations and stable replay; call the
  applier, never direct row mutation. Ctrl-C uses this same durable cancellation
  path; terminal acknowledgment precedes fence release. Cover interruption
  during authorization, running, acknowledgment and pending rerun consumption.
  Existing authenticated remote manager paths keep their protections.
- [ ] **P1-6d** Wire one bounded optional agent-director child through ordinary
  workflow execution. Reconcile work attempt before entry: .director reservation;
  retain judged work TaskView, record child session/cost/attempt exactly once.
  Validate allowed P1 decision kinds and apply through the same causal/version/
  completion/budget checks. Invalid/forbidden/failed/budget-blocked output records
  evidence and needs human decision. No recursive director repair, replan,
  proposals or specialist classifier. Finish planner-variable host snapshot
  wiring through dispatcher workflow input variables using capability contracts.
- [ ] **P1-7a** FIRST establish replacement dispatcher behavioral tests for
  auto-improve inactivity, bounded retry, gate/failure recovery, cancellation
  and replay. Record passing exit/log before deleting the old implementation.
  THEN remove WorkflowRunCommand+AutoImprove.swift, WorkflowAutoImprovePolicy,
  WorkflowMutationMode, SupervisedScenarioNodeAdapter, supervision state/result,
  remote input.autoImprove/input.nestedSuperviser and removed flags. Discover
  exact references with rg; changes outside scoped files are serialized and
  assigned to this integration owner before edit. Preserve specialist/event
  supervisor dispatch, existing loop/routine behavior and plain workflow runs.
- [ ] **P1-7b** Replace examples/auto-improve, examples/default-superviser and
  examples/supervised-mock-retry with examples/task-repair-loop and
  examples/task-agent-director, each with mock-scenario.json and
  EXPECTED_RESULTS.md. TaskRuntimeExampleTests must drive real task lifecycle
  using deterministic fixtures: acceptance, gate recovery, guard stop, capacity
  wait; allowed director output, child accounting and invalid-output escalation.
  Workflow-only mock runs supplement these tests; they do not prove dispatch.

Deliverables: dispatcher/CLI composition, bounded director child, both example
bundles, removal of obsolete implementation and equivalent regressions. Keep
CLI addition and auto-improve removal in the same delivery cut; no publication
between them. Test real reserved-session execution, dependency/version races,
guard persistence failure, cancellation acknowledgment loss, replay crashes,
last-attempt completion, dry-run effects, and task-free plain workflow run.

## File-level implementation map and preserved invariants

Every row is limited to the accepted requirement named. New file names below
identify retained code or intended repair destinations; fresh-read actual APIs. Fresh-read existing
neighbors and accepted predecessor signatures before implementation; reuse
existing functions and avoid a generic framework. Extra helpers are allowed
only for necessary responsibility splits, with an exact-path serial assignment
and intent record first. The JSON writePaths list never authorizes unrelated
changes to a matched file. Prerequisite repair paths are assigned above; ownership transfers remain serial.

| Task / files | Intended change / required evidence |
| --- | --- |
| P1-6a: retained `Sources/RielaWork/TaskDispatcher.swift`; retained `Sources/RielaCLI/TaskDispatch.swift`; existing `WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift` in Sources/RielaCLI | Work coordinates accepted requirement/placement/reservation/decision contracts; CLI resolves canonical definition/store and bridges to existing runner using the reserved session ID and per-node host/backend. Project terminal evidence before completion/guard evaluation. Reuse runner execution; no RielaCore import of RielaWork. TaskDispatcherTests and TaskDispatcherIntegrationTests prove exact reserved ID, version/dependency races, wait without attempt/session/lease, stale launch rejection and projection-before-decision. |
| P1-6b/c: `Sources/RielaCLI/TaskCommands.swift`, `TaskCommandModels.swift`, `RielaCommand.swift`, `RielaArgumentParser+WorkflowAndMemory.swift`, retained `TaskDispatch.swift` | Add run/dry-run/decide parsing, typed result DTOs and text/JSON output. Preserve show/list and store-root precedence. Dry-run must select read-only dependency APIs before any loader that initializes/migrates/quarantines. Decide validates exactly one action, principal, expected version and stable ID. Route Ctrl-C through durable applier/runner cancellation, including pending-launch and acknowledgment windows. No second direct-mutation path. TaskCommandMutationTests and TaskCommandParsingTests assert parsing, replay and filesystem/row invariance. |
| P1-6a/c/d shared serial handoff: `Sources/RielaWork/WorkStore+Decisions.swift`, `TaskGuardCoordinator.swift`; `Tests/RielaWorkTests/DecisionApplierStoreTests.swift`, `WorkGuardDispatcherTests.swift` | Consume and regression-test the accepted lifecycle implementation of scoped causality, reconstructed completion, original replay, atomic pending requests and live cancellation fencing. Only add narrowly necessary real-runner coordination after ownership transfer; complete lifecycle prerequisite repairs before dispatch integration. Coordinator must preserve complete guard-batch persistence before decisions. If durable outcome storage needs schema/model changes, assign the existing store/schema files to the serial integration owner and use existing storage; do not invent parallel storage. Add negative/rollback/crash/replay tests, not CLI-only checks. |
| P1-6d: retained `Sources/RielaWork/AgentDirector.swift`; `TaskDispatcher.swift`, `Sources/RielaCLI/TaskDispatch.swift` | One ordinary child workflow only when configured escalation needs it. Reconcile judged work before .director reservation; retain its TaskView; charge child attempt/session/cost once and use the same applier. Forward the accepted capability snapshot through planner workflow variables; no new planner. TaskDispatcherTests/TaskDispatcherIntegrationTests prove host input and selected backend delivery, last-admitted-attempt completion, invalid/forbidden/failed/budget-blocked child escalation and no recursion. Deterministic ordering is certified in P1-PREREQ-L. |
| P1-7a: `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift` (delete after barrier), `RielaCommand.swift`, `ParsedWorkflowOptions.swift`, `RielaArgumentParser+WorkflowAndMemory.swift`, `WorkflowCommands.swift`, `WorkflowRunCommand.swift`, `ProductionNodeAdapter.swift`, `RielaCLIApplication.swift` | Remove actual policy/mutation types in RielaCommand, flags, option plumbing, execution branch, remote serialization and scenario wrapper. SupervisedScenarioNodeAdapter actually lives in RielaCLIApplication.swift (not an Adapters file). Reject removed autoImprove/nestedSuperviser remote fields rather than ignoring or forwarding them. Keep normal run, mock scenario and authenticated remote paths intact. Rewrite legacy tests as rejection/preservation regressions only after replacement coverage passes. |
| P1-7a conditional retained call sites: `Sources/RielaCLI/SessionCommands.swift`, `SessionCommandModels.swift`, `RielaCommand+SessionParsing.swift`, `LoopCommands.swift`; `Sources/RielaCore/DeterministicWorkflowRunner.swift` | Remove only obsolete supervision plumbing/result fields tied to the deleted workflow path. Preserve loop/routine and specialist/event behavior and their stores; do not delete symbols merely for containing supervisor. Inspect callers/consumers before removal; contradictory retained behavior is a dependency blocker, not permission to redesign another plan. A newly discovered remote decoder outside listed paths requires exact serial ownership assignment before its narrow removed-input rejection edit and tests. |
| P1-7a regressions: `Tests/RielaCLITests/CommandParsingTests.swift`, `WorkflowCommandAutoImproveTests.swift`, `WorkflowCommandInspectionTests.swift`, `WorkflowCommandPackageLifecycleTests.swift`, `RielaExampleParityTests.swift`, `WorkflowRunHelpTests.swift` | Preserve equivalent scenarios in the four new dispatcher suites before deleting old tests. Assert removed flags/remote fields fail, plain runs create no task, help and package examples match; keep specialist supervisor, events, routines and loops green in V5. |
| P1-7b: `examples/task-repair-loop/` and `examples/task-agent-director/` each with `workflow.json`, required referenced `nodes/` and `prompts/`, `mock-scenario.json`, `EXPECTED_RESULTS.md`, `README.md`; `Tests/RielaCLITests/TaskRuntimeExampleTests.swift` | Minimal deterministic bundles; tests create task fixtures through existing store APIs then drive actual task run/decision lifecycle with mock node execution, not merely workflow run or string assertions. Document acceptance, gate recovery, guard stop, capacity wait, bounded child output/accounting/escalation. Remove only the three legacy directories after V1 before-removal passes. No new task-create CLI. |

The four required suites are exactly
`Tests/RielaWorkTests/TaskDispatcherTests.swift`,
`Tests/RielaCLITests/TaskCommandMutationTests.swift`,
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` and
`Tests/RielaCLITests/TaskRuntimeExampleTests.swift`. Integration tests use
real reservation/store/runner paths and deterministic injected node/probe/clock
boundaries; test doubles must not bypass the contract under test.

Invariant checklist for tests and independent review:

- Reservation atomically binds task version/dependencies, attempt, unique
  session, lease, placement and decision. Token is single-use and digest-only;
  no relaunch on uncertain authorization, lease expiry or heartbeat loss.
- Dry-run changes neither bytes nor rows across main DB, WAL/SHM, work_hosts,
  runtime/host cache and host-profile files; absent stores stay absent; corrupt
  profile input is neither rewritten nor quarantined. Compare inventories and
  content before/after with connections closed; include missing/incompatible state.
- Store causality cannot reference missing, foreign or stale attempt evidence.
  Latest-work verification/gates (with only the persisted bounded-child exception below) and applicable blocking findings govern
  acceptance; human accept waives only requiresHumanAccept. Identical replay
  returns original outcome even after later task changes; conflicting payload
  or fresh stale-version decisions fail without side effects.
- Guard batch persistence failure prevents all dependent action. Replay does
  not duplicate evidence or cumulative tokens. Gate visits use > limit; other
  used limits use >=; attempt budget limits the next admission and allows the
  last admitted attempt to finish. SDK heartbeat exemptions are preserved.
- Cancellation is durable before runner cancellation; fence release follows
  durable terminal acknowledgment. Test interruption before authorization,
  while running, during acknowledgment and during pending-request consumption.
- Placement consumes the dependency's one fresh merged snapshot. No pin
  fallback, implicit authentication, invented capacity, unreachable-node
  requirement or stale success after failed refresh. Chosen per-node backend/
  host and planner snapshot reach execution; capability validation is not a token.


## Resumption execution detail from accepted §17.7

These tasks complete the retained implementation; they do not restart it or
certify existing checkmarks. Step 3 accepted this revision with empty findings
and feedback; no Step 5 revision request was delivered. Preserve the prior
attempt evidence in `impl-plans/progress/p1-dispatch.md`, including attempt 3
from `nested-v1-f637160bee4a0e57484a92a8400c09a6a58ec7ccbb82ac72bb5ebee0ca2d68ae`
and its logs under `tmp/p1-dispatch-step6-attempt3/`. The second workflow run
ended at `implementation-blocked-output`; neither its findings nor partial
passing suites certify the implementation or exhaust the remaining paths.
Use new numbered evidence directories; never overwrite prior logs.

Retained source now resolves reachable workflow/add-on requirements and sums
wall-clock durations from exact durable attempt sessions. Preserve these changes
and reverify them rather than reimplementing from the older gap inventory.
`Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` already supplies
`agentSandbox: .readOnly` in the previously failing callee fixture. V1 must
rerun that case and the cumulative wall-clock case on final source; a historical
passing rerun is not final acceptance.

### P1-AUDIT and P1-PREREQ-L: data flow beyond the reported gaps

Fresh-read `Sources/RielaCLI/TaskDispatch.swift`,
`Sources/RielaWork/TaskGuardCoordinator.swift`, `WorkGuard.swift`,
`DeterministicDirector.swift`, `WorkEvidence.swift` and `WorkStore+Decisions.swift`
(the last five under RielaWork). Trace cumulative wall-clock, token accounting,
repeated findings, gate visits and live heartbeat input from actual attempts
into guard evaluation. Inventory every unchecked criterion, its current test
and missing behavior. Reconcile the progress log's older claims against source.
Repair only broken accepted contracts. Extend `Tests/RielaWorkTests/WorkGuardDispatcherTests.swift`
and `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift` to prove cumulative
multi-attempt budgets, repeated findings, stable simultaneous-violation order,
inactivity and successful completion of the last admitted attempt. No new
attempt may evade budget through human, agent or warning paths. V1/V3 must
exercise these cases; helper-only guard tests cannot certify dispatch input.
For repeated findings, use the existing fingerprint identity across real task
attempts; assert the configured equality threshold persists the violation and
applies the ordered decision, while replay neither duplicates evidence nor
counts the same observation again. For inactivity, drive a configured
heartbeat-capable backend through the live runner with a deterministic clock;
assert threshold-triggered cancellation is durably acknowledged before any
replacement admission. Include below-threshold and SDK-exemption cases, and
assert heartbeat loss alone cannot release the one-live-attempt fence. Route
signals through existing runner/guard seams; do not add a monitoring service.


### P1-6a: called workflow and selected-host delivery

1. In `Sources/RielaCLI/TaskDispatch.swift`, use existing
   `WorkflowCalleeResolution.swift` to supply reachable called bundles to
   `Sources/RielaCore/WorkflowRequirements.swift`, including add-on/environment
   requirements. Resolve from the actual entry; preserve returns/joins and
   workflow/step/node provenance, exclude reused prefixes/unreachable nodes,
   visit cycles once and diagnose unresolved executable targets before reserve.
2. In `Sources/RielaCLI/HostCapabilityResolver.swift` and TaskDispatch, replace
   the local-only/no-workers composition with the existing configured topology.
   Preserve explicit worker/group assignments and one fresh merged evaluation.
   Use `Sources/RielaWork/BackendCapabilityPlacement.swift` and existing host
   storage; no new capability registry. Waits create no attempt/session/lease.
3. In `Sources/RielaCLI/WorkflowRunCommand+TaskReservation.swift`,
   `WorkflowRunCommand.swift` and `WorkflowCalleeResolution.swift`, carry chosen
   host/backend/model into root and callee execution rather than rejecting all
   nonlocal/callee choices or filtering them out. Reuse configured distributed
   execution and existing authentication. Retain exact reserved session identity
   and single-use launch admission; deliver the snapshot through planner inputs.
4. Inspect and narrowly repair the existing distributed paths already listed:
   `Sources/RielaCore/DistributedJobController.swift`,
   `Sources/RielaServer/DistributedWorkerProtocol.swift`,
   `DistributedWorkerHTTPClient.swift`, `DistributedWorkerHTTPRouter.swift`,
   `DistributedWorkerLoop.swift` and `DistributedControllerHost.swift` (Server).
   Record an exact serial ownership intent before any additional seam is edited.
   Worker loss after admission cannot authorize local fallback or duplicate
   launch; preserve uncertainty fencing and durable session evidence.
5. Extend `Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift`,
   `WorkflowHostCapabilityTests.swift` (CLI),
   `Tests/RielaCoreTests/WorkflowBackendPolicyTests.swift`,
   `DistributedJobControllerTests.swift` (Core), and
   `Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`. Use deterministic
   owned worker fixtures through the actual handoff/worker completion path.
   Observe which worker executed, selected backend/model and exact reserved
   session evidence. Cover callee-only requirements, cycle/return/join/reused
   prefix, explicit assignments, missing target, unavailable capacity and
   post-admission worker loss. DTO-only placement assertions are insufficient.
   V1/V4/V11 pass before P1-6a closes; V5 certifies preserved distributed behavior.

### P1-6c: durable request to live execution to acknowledgment

In `Sources/RielaCLI/TaskCommands.swift`, `TaskDispatch.swift`,
`WorkflowRunCommand.swift`, `WorkflowRunLivePersistence.swift` and
`WorkflowRunCommand+SupervisionPersistence.swift`, connect the shared durable
cancellation request to the active runner and existing selected-host cancellation
path. Reuse `Sources/RielaWork/WorkStore+Decisions.swift` and
`WorkStore+Reservation.swift`; do not add another decision store or bypass them.
Human cancel/reject, guard stop/replacement and Ctrl-C persist before signalling.
Pending cancellation takes the acknowledgment path, never generic reconcile.
Require the exact cancelled terminal snapshot before fence release and task
terminal state; consume any replacement request once after acknowledgment.
Pre-launch cancel forbids authorization. Lost acknowledgment, write failure,
lease expiry or heartbeat loss retains the fence until explicit reconciliation.

Extend `Tests/RielaWorkTests/WorkStoreCancellationTests.swift`,
`WorkStoreReservationTests.swift`, `DecisionApplierStoreTests.swift` (Work),
`Tests/RielaCLITests/TaskCommandMutationTests.swift`,
`TaskDispatcherIntegrationTests.swift` (CLI), and
`Tests/RielaServerTests/DistributedWorkerHTTPTests.swift`. Exercise real running
cancellation locally and on the selected worker, authorization races, terminal
persistence failure, acknowledgment loss, reopen/replay and pending replacement
consumption. Assert no premature terminal task, stale launch or duplicate
accounting. V1/V2/V11 must pass; store-only acknowledgment tests are insufficient.

### P1-7b/P1-7a and final evidence investigation

Complete task-backed gate recovery and real bounded director child cases in
`Tests/RielaCLITests/TaskRuntimeExampleTests.swift` and both example bundles.
The retained recommendation-only director test is not child lifecycle evidence.
Use the P1-6d linked-work cases below and prove exactly-once accounting on replay.
Record each scenario, test name and observed persisted outcome against
`EXPECTED_RESULTS.md`. Run V1 before any legacy deletion; only then perform
P1-7a and run V1 again. Preserve unrelated supervisor/event/loop/routine paths.

Investigate prior broad failures and the truncated XCTest aggregate as test
execution issues. For a truncated aggregate, retain the whole log and final
process exit, reproduce the last unfinished suite in the foreground, identify
premature process termination or harness behavior, then rerun the affected full
gate. A targeted success does not replace V5. Supply fixture-owned paths under
this worktree's tmp for tests requiring writable runtime state; do not inspect
or repair the executing workflow's scoped registry. Never weaken assertions,
skip required suites or classify incomplete zero exits as passing. Compare
unchanged-baseline failures without broadening product scope; record any
unresolved gate explicitly. Final acceptance requires complete passing evidence.

## P1-6d judged-work acceptance and child execution

Apply accepted §17.7 in `Sources/RielaWork/AgentDirector.swift`,
`WorkStore+Decisions.swift`, `WorkStore+Reservation.swift`, `WorkModels.swift`,
`WorkStore+Schema.swift`, `TaskGuardCoordinator.swift` (all RielaWork), and
`Sources/RielaCLI/TaskDispatch.swift`, `WorkflowRunCommand+TaskReservation.swift`
and `WorkflowRunCommand+SupervisionPersistence.swift` (RielaCLI), as required.
Reuse existing reservation/evidence persistence, not a second task store.

1. Replace the explicit director-dispatch rejection with one ordinary bounded
   child run after work reconciliation. Persist its relation to the judged work
   at child reservation in the same store transaction, using the existing
   durable record model or the smallest required typed extension. Record both
   attempt identities, child session and task identity; caller TaskView alone
   is not authority. Schema/model edits, if necessary, are serialized and
   covered by fresh/reopened store and rollback tests under existing policy.
2. Keep work TaskView stable across child execution, charge child attempt/cost
   once, and validate successful child output against configured allowed P1
   kinds. Invalid/forbidden/failed/budget-blocked output persists escalation and
   requires a human; never recursively invoke the director.
3. At shared application, validate persisted linkage, producer child session,
   same task, current version and child terminal state. Only that linked child
   may intervene after judged work; reject newer work or foreign/stale linkage.
   Reconstruct completion from the judged work's durable gates, verification,
   acceptance criteria and applicable blocking findings. Child success alone
   cannot accept work. Preserve latest-attempt enforcement for unrelated paths.
4. Remove the validator's unconditional accept escalation only once shared
   application can enforce those rules. Agent acceptance cannot waive human
   acceptance. Replays return the original result; neither replay nor child
   completion duplicates accounting or changes judged work evidence.
5. Extend `Tests/RielaWorkTests/AgentDirectorTests.swift`,
   `DecisionApplierStoreTests.swift`, `DecisionApplierCausalityStoreTests.swift`,
   `WorkStoreReservationTests.swift` and, for any storage-shape change,
   `WorkStoreTests.swift`; extend CLI `TaskDispatcherIntegrationTests.swift`
   and `TaskRuntimeExampleTests.swift`. Prove a valid allowed accept, child-only
   success rejection, newer-work rejection, foreign/missing linkage rejection,
   requiresHumanAccept rejection, current-version conflict, restart/replay,
   exact child session/cost/attempt accounting, and nonrecursive escalation.
   Test real shared store and runner paths; validator-only assertions do not
   establish this contract. Include passing last-admitted work and budget-blocked
   child admission independently.

## Common lint and validation contract

swift build is the Swift compile/typecheck gate. Swift edits follow the local
Swift skill: keep touched code responsibility-based, avoid speculative
abstraction, and split touched non-generated files over 1000 lines by actual
responsibility without unrelated cleanup. Include necessary extracted paths in
serial ownership records. Do not weaken tests or lint to accept retained WIP.

Before any implementation edit, the integration owner captures repository lint
baseline; the integration owner records that immutable log/hash. After edits,
materialize exact existing changed/new Swift paths from its intent records in
`tmp/work-runtime-p1/<planId>/changed-swift-files.nul`; do not rely on git diff
alone because it omits untracked files and predecessor commits. The plan ID below is fixed for this package.
The metadata above contains the exact p1-dispatch commands.

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-dispatch/changed-swift-files.nul
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
```

Skip xargs only for an explicitly empty Swift write set; strict touched-file
lint gates acceptance. Repository-wide output is a recorded baseline check:
fail new diagnostics attributable to this work, report existing unrelated ones,
and do not broaden edits to clear them. If a tool is unavailable, record a
blocked gate and environment error, not success. Run required focused tests,
then the broader V5 gate once on the joined tree; repeat only after
new changes/failures. No web code is planned, so browser E2E is not a P1 gate.

## Verification contract

All commands run in the foreground from repository root. Create
`tmp/work-runtime-p1/p1-dispatch/` first. Capture full stdout/stderr, command,
start/end, final exit status, and positive executed test count in
`verification-evidence.json` there and in the progress log. Poll yielded handles
through terminal exit. Timeouts, incomplete logs, absent suites and zero tests
are failures/blocked checks, never passes. Log basenames below are mandatory;
use immutable numbered attempt subdirectories on retries and distinct
`before-removal/` and `after-removal/` directories for V1. Build caches remain
`tmp/work-runtime-p1/build/p1-dispatch`. Never use shell orphaning or detached
processes. No implementation commands below have run during Step 4; these are downstream requirements.

### Commands and evidence

**V0 compile/typecheck**, log `build.log`:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
```

**V1 required focused behavior**, log `focused-tests.log`. Run once before any
legacy deletion and again on the final removal tree. All four named suites
must exist and execute positive counts; an aggregate count alone cannot hide
an absent suite. It establishes every P1-6/7 acceptance row above, including
real task-backed examples and dry-run file/row comparisons.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
```

**V2 reservation readiness/regression**, log `reservation-tests.log`. Require
atomic rollback, duplicate IDs, concurrent independent connections, stale
version/dependency, token replay, uncertainty fence, pending request consumption
and durable cancellation tests from the stable P1-PREREQ-R revision.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkStoreReservationTests|WorkStoreCancellationTests|BudgetAdmissionStoreTests'
```

**V3 lifecycle readiness and shared-applier regression**, log
`lifecycle-tests.log`. Require positive counts for each suite and behavioral
proof of the shared file map and invariant checklist, stable simultaneous
violation ordering, gate recovery budget and latest-attempt completion.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'WorkGuardTests|WorkGuardDispatcherTests|DeterministicDirectorTests|DecisionApplierTests|DecisionApplierStoreTests|DecisionApplierCausalityStoreTests|AgentDirectorTests|CompletionEvaluatorTests'
```

**V4 capability readiness**, log `capability-tests.log`. These suites/interfaces
are certified by this plan’s P1-PREREQ-C gate, not a separate scheduled plan. Require
selected-entry/called-workflow resolution, deterministic placement, finite
freshness and failed-refresh handling, host declarations, read-only profile
loading, probe redaction and planner snapshot contract; every suite must run.
Absent suites make readiness blocked even if the test command exits 0.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'BackendCapabilityPlacementTests|DoctorBackendCapabilityTests|WorkflowHostCapabilityTests|DistributedWorkerConfigurationTests|WorkflowBackendPolicyTests|BackendCapabilityProbeTests|HostCapabilityConfigurationTests'
```

**V5 joined-tree regression**, logs `work-cli-core-tests.log` and
`adapter-server-graphql-tests.log`. Work/CLI/Core are mandatory for the planned
shared changes, retaining P0 read/projection/store, plain runner, parser/help,
loop/routine/specialist/events, surface catalog and remote forwarding behavior.
Both commands are required for the retained capability/profile and planned
shared runtime changes. Do not
weaken unrelated failing tests: classify baseline versus caused failures and
report blocked verification explicitly.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaWorkTests|RielaCLITests|RielaCoreTests'
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'RielaAdaptersTests|RielaServerTests|RielaGraphQLTests|RielaAppSupportTests'
```

**V6 strict touched-file lint**, log `swiftlint-changed.log`. The NUL manifest
contains all surviving new/modified Swift paths from intent/change evidence,
including untracked files, with no deleted paths. Require no strict diagnostics.

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/p1-dispatch/changed-swift-files.nul
```

**V7 repository lint baseline/comparison**, logs `swiftlint-baseline.log` before
edits and `swiftlint-repository.log` after. Record each exit and compare full
diagnostics; do not fix unrelated baseline issues or call unavailable lint a pass.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
```

**V8 bundle validation/supplemental workflow mocks**, logs respectively
`repair-validate.log`, `repair-mock.log`, `director-validate.log`,
`director-mock.log`. All four exit 0; compare results with each bundle's
EXPECTED_RESULTS.md. These checks do not replace V1's actual task lifecycle.
Only run on the newly built executable after V0. No real credentials required.

```bash
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-repair-loop --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-repair-loop --workflow-definition-dir examples --mock-scenario examples/task-repair-loop/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/examples/task-repair-loop --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow validate task-agent-director --workflow-definition-dir examples --output json
tmp/work-runtime-p1/build/p1-dispatch/debug/riela workflow run task-agent-director --workflow-definition-dir examples --mock-scenario examples/task-agent-director/mock-scenario.json --session-store tmp/work-runtime-p1/p1-dispatch/examples/task-agent-director --output json
```

**V9 removal inventory and diff**, logs `legacy-reference-audit.log`,
`git-diff-check.log`, `git-diff-cached-check.log`. For rg, exit 1 means no
matches, 0 requires classification of every retained match (rejection tests,
historical docs or unrelated specialist/event behavior), and >1 is an error.
Never delete all supervisor-name matches. Diff checks require exit 0; cached
check runs at the serial plan/final commit gate after the exact allowlist is staged.

```bash
rg -n 'autoImprove|nestedSuperviser|WorkflowAutoImprovePolicy|WorkflowMutationMode|SupervisedScenarioNodeAdapter|--auto-improve|--nested-superviser' Sources Tests README.md examples
git diff --check
git diff --cached --check
```

**V10 canonical payload prerequisite**, log `sandbox-tests.log`. Require positive
executed counts and real checked-in payload checks. Do not inspect the executing
workflow package or registries, and do not expand this plan into workflow repairs.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter ImplementationWorkflowSandboxTests
```

**V11 selected-host execution and cancellation**, log `selected-host-tests.log`.
Require positive counts for each suite and the P1-6a/c integration cases above:
actual worker execution with root/callee choice delivery, exact reserved session,
worker loss fencing and live cancellation/acknowledgment. In-memory transport
fixtures may control scheduling, but cannot bypass the worker execution and
shared store boundaries under test. Every fixture stops before the test exits.

```bash
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskDispatcherIntegrationTests|DistributedJobControllerTests|DistributedWorkerHTTPTests'
```

At the P1-PREREQ-L gate, V3 certifies the existing lifecycle requirements;
record bounded-director cases as pending P1-6d, never passing by omission.
After P1-6d and at final acceptance, V3 must also prove reopened-store
judged-work linkage and all P1-6d cases above. For V5 the AppSupport suite is required because host declarations touch
profile/daemon loading. SurfaceCatalog, help, doctor and plain workflow behavior
must remain covered by positive suites; classify unrelated baseline failures,
never suppress them or report the affected gate passing. V2 also needs positive
counts for cancellation and budget suites; V3 for causality and agent-director.

## P1-FINAL documentation, review and publication

- [ ] Serially reconcile source against immutable intents and prerequisite
  handoffs; run affected checks after repairs, then V0–V11 on the final stable
  tree. No unresolved material high/mid finding or incomplete required evidence.
- [ ] Perform author self-review, independent test-integrity review and the workflow's single adversarial
  implementation review, followed by required combined-tree acceptance. Review
  material behavior/data-loss/security/regression/test gaps, not style nits or
  speculative abstraction. Record actual review IDs, decisions and findings.
- [ ] Refresh `README.md`, affected example READMEs/EXPECTED_RESULTS, and P1
  status in `design-docs/specs/design-work-runtime-consolidation.md`. Update
  `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`, `SurfaceCatalog+Rows.swift`,
  `SurfaceCatalog+RowSupport.swift`, `Sources/RielaCLI/CLISurfaceEnumeration.swift`
  and `Tests/RielaCoreTests/SurfaceCatalogTests.swift` only where task CLI/removal
  requires it. Task GraphQL/UI counterparts stay explicitly deferred.
- [ ] Reconcile this plan, `impl-plans/README.md`, `impl-plans/PROGRESS.json`,
  `impl-plans/progress/plans-index.json`, `meta.json`, `phases.json` and
  `plans/work-runtime-p1-dispatcher-guard-director.json` under that progress
  directory only where the existing index format requires it. Preserve all
  non-P1 entries and other plans' unchecked status unless their acceptance is
  explicitly evidenced; do not claim completion of separate work packages.
- [ ] Append this session's status/evidence only to
  `impl-plans/progress/p1-dispatch.md`: task state, exact changed paths/hashes,
  retained-hunk attribution, interface ownership, commands/start/end/final exits,
  complete log paths, positive per-suite counts, review findings/decisions,
  invalidated evidence and deferred/external dependencies. No checkboxes close
  on source inspection, planning acceptance or historical logs alone.
- [ ] Audit applicable repository-owned `riela-package.json` manifests only
  for modified workflow/prompt/script/skill artifacts; refresh actual owning
  digests with established tooling and record exact paths serially before edit.
  Do not invent a manifest, modify an immutable installation or inspect scoped
  registries. Review `.codex/skills/riela-impl-workflow/SKILL.md` for directly
  affected documentation; update only a necessary P1 contract with explicit
  owner/path and digest audit, not unrelated workflow material. No skill edit
  is necessary merely because this plan was authored.
- [ ] Lockfile generation is conditional on a necessary dependency change;
  do not opportunistically update `Package.resolved`. No archiving is necessary
  before execution completes. Exclude tmp evidence from staging.
- [ ] Prepare the exact accepted P1 file/hunk allowlist; retain unrelated hunks
  even in shared files. The authorized workflow finalization gate commits and
  pushes non-force to `origin` / `feat/remaining-impl-plans`, verifies the final
  accepted hash remotely and records matching commit/push evidence. Freshly
  check publication readiness at that gate; missing upstream is not a design
  blocker. Do not fabricate tracking state, change other worktrees or integrate
  a base branch. No broad `git add` and no concurrent Git operations.

Shared-file documentation changes invalidate affected test/lint gates; rerun
those gates before the final allowlist is accepted. Existing untracked files
must be included in evidence and strict lint, not omitted by git diff. If
commit tooling can stage only whole files, unrelated mixed hunks require an
isolated accepted-content preparation that preserves the worktree/index; do
not silently include them. Actual inability to publish is reported with its
concrete failed command/log/exit, not claimed as success.

## Planning author check and remaining gates

Step 3 accepted §17.7 in the runtime-delivered review with no findings. Step 5
plan acceptance, implementation, behavioral tests, lint, adversarial review,
documentation completion and final commit/push remain downstream. No Swift
build/test/lint result is claimed in Step 4. No unresolved user decision or
known design defect remains. The current concrete director integration gap is
an implementation task, not a reason to reopen accepted design.

Author check: `python3 tmp/work-runtime-p1/step4-f46ff788/self-check.py`.
Complete logs/final exits and source-preservation evidence are recorded in
`tmp/work-runtime-p1/step4-f46ff788/verification-evidence.json`.
This plan's source inspections are not behavioral acceptance. The author
checks the single-plan DAG, exact scope, file-level tasks, accepted §17.7 mapping,
evidence commands, review/finalization gates and preservation of all prior work.
