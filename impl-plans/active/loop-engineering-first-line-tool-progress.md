# Loop Engineering First-Line Tool Progress Log

## Progress Log

### Session: 2026-07-11 23:30

**Tasks Completed**: Reopened every prior Section 8 claim for round seven and
implemented all three reported medium findings. Transaction generations now
make canonical payloads and digest sidecars non-writable before exclusive
publication, make each published generation directory non-writable, and verify
type/mode on every read. Generation transitions preserve immutable fields and
allow verification evidence and diagnostics to evolve only through explicit
append-only rules, rejecting rewrite or removal. Snapshot, proposal, and
finalized change-set reads now descriptor-enumerate the entire topology and
require exactly the canonical directory/file layout, rejecting unexpected
directories, FIFOs, Unix sockets, links, and every other special type. Apply
and restore directory transactions publish a durable canonical preflight
attempt before mutability, digest, lock, existing-transaction,
snapshot-authority, and locked-inventory checks; failed preflight records state
`mutationOccurred=false`, exact retries are idempotent, and either initial or
failure-audit persistence failure stops before mutation.

**Files Changed**: Production changes are confined to Section 8 history,
generation, topology, preflight-audit, snapshot/proposal/change-set, and
transaction coordinator files under `Sources/RielaCLI`; deterministic round
seven and adjusted prior adversarial coverage under `Tests/RielaCLITests`; and
the governing design, plan, progress, README, and incomplete-work inventory.
All unrelated dirty changes, including `codex-unified-exec-stall-followup`,
remain preserved. Scratch and redirected logs are under
`tmp/section8-round7/` only.

**Verification**: The new round-seven adversarial suite passed 21 tests with 0
failures, including generation rewrite/mode/evidence-transition, independent
snapshot/proposal/change-set FIFO/socket/unexpected-directory, all named
preflight failure, and audit-write failure cases. The first focused Section 8
re-audit passed 71 of 73 tests and exposed two intentionally stale adversarial
expectations (direct rewriting now requires an explicit chmod; a lock failure
now creates a failed attempt audit); both fixtures were updated to the new
contract. The exact final-tree Section 8 aggregate then passed 74 tests with 0
failures. Strict scoped Xcode-toolchain SwiftLint passed 9 touched files with 0
violations. The transaction coordinator is 967 lines and every touched Swift
file remains below 1,000 lines. `git --no-optional-locks diff --no-ext-diff
--no-textconv --check` passed. Final Xcode-toolchain `swift test` passed 1,714
tests with 4 skipped and 0 failures in 218.573 seconds. All command output was
redirected under `tmp/section8-round7/`; the known post-summary wait did not
alter any XCTest or lint result.

**Tasks In Progress**: None for the round-seven Section 8 findings.

**Blockers**: None.

### Session: 2026-07-11 21:47

**Tasks Completed**: Reopened the Section 8 claims for round six and resolved
all reported findings. Mutable transaction record/sidecar replacement is now a
gap-free chain of immutable canonical generations published by one exclusive
directory rename; recovery removes only private interrupted construction,
selects only complete digest-valid monotonic generations, and fails closed on
missing, extra, ambiguous, or tampered generations. Fault injection now occurs
between payload and sidecar construction for every durable phase and recovers
through public validation, including the live-absent first-rename window. The
advisory lock is derived only from canonical ownership target, lives in an
owner-only system lock namespace, and is acquired through a pinned no-follow
parent descriptor before
transaction-state resolution or mutation, independent of working directory or
history root. History record traversal/writes and immutable snapshot/proposal/
change-set publication use a pinned canonical history-root descriptor with
descriptor-relative no-follow operations. Deterministic ancestor exchanges
prove records, snapshots, proposals, and target locks cannot be redirected.
The prior exact-file enumeration, shared-node drift, leaf-swap, recovery-matrix,
audit-retry, and public recovery assertions were re-audited and remain passing.

**Files Changed**: Round-six production work is concentrated in the transaction
coordinator/durability, new generation store, new pinned-history-root helper,
secure persistence, immutable publication, history/proposal stores, and shared
workflow resolution under `Sources/RielaCLI`; adversarial and transaction tests
under `Tests/RielaCLITests`; and the Section 8 design, plan, progress, and
incomplete-work inventory. Existing unrelated dirty-worktree changes,
including the expanded `codex-unified-exec-stall-followup` plan, were preserved.

**Verification**: The focused Section 8 aggregate passed 48 tests with 0
failures; the new adversarial class passed 7 tests; the restore regression
suite passed 4 tests; and the three package/resolution regression tests passed.
Final Xcode-toolchain `swift test` passed 1,693 tests with 4 skipped and 0
failures in 214.579 seconds. Strict scoped Xcode-toolchain SwiftLint passed 12
files with 0 violations. Every touched Swift file remains below 1,000 lines
(maximum 853), and final `git diff --check` passed. Intermediate full-suite
runs exposed and drove fixes for canonical Date comparison across generations
and absent discovery-candidate parents before the final passing tree.

**Tasks In Progress**: None for the round-six Section 8 findings.

**Blockers**: None.

### Session: 2026-07-11 20:12

**Tasks Completed**: Reopened the Section 8 design and implementation claims
for round five and resolved every reported medium/low finding. Transaction
recovery now acquires the target lock before securely enumerating and
canonically validating every durable record, discovers a lone nonterminal
record without `active.json`, and fails closed on multiple or pointer-ambiguous
records. Auto-scope resolution treats recovery failure as terminal. Supported
transitive `nodeRef` declarations, payloads, and referenced prompt/script/source
files are pinned into inventory, bundle digests, snapshot objects, drift checks,
and an isolated staged resolution layout. Immutable directories and
non-overwriting records use filesystem no-replace publication. Proposal
generation descriptor-rereads `workflow.json` and verifies bytes, size, digest,
and mode against inventory. Transaction, mutation, and restore audit retries
require complete deterministic canonical equality. Every-boundary assertions
now verify terminal records, both audits, marker cleanup, and second-transaction
refusal while unresolved. Independent canonical fixtures cover required-field,
enum, Unicode ordering, and digest-input rules.

**Files Changed**: Round-five work is concentrated in the Section 8 history,
transaction, identity/inventory, secure persistence, proposal, staging,
resolution, and version command files under `Sources/RielaCLI`; the history
model under `Sources/RielaCore`; focused transaction-boundary, history,
shared-node, secure-read, staged, audit-retry, and canonical-model tests; this
design/plan/progress set; and the incomplete-work inventory. Existing unrelated
dirty-worktree changes were preserved.

**Verification**: Focused Xcode-toolchain runs passed 53 tests with 0 failures:
41 in the aggregate transaction/history/shared/canonical run plus 12 secure
read, staged verification, and audit-retry tests. Full Xcode-toolchain `swift
test` passed 1,689 tests with 4 skipped and 0 failures in 223.326 seconds; the
wrapper reached its 420-second bound only after the successful XCTest summary.
Strict scoped Xcode-toolchain SwiftLint reported 0 violations over 24 files;
its process similarly remained alive after the successful summary until the
120-second bound. Every modified/untracked Swift file is below 1,000 lines
(maximum 998), and `git diff --check` passed.

**Tasks In Progress**: None for the round-five Section 8 findings.

**Blockers**: None in production code. The known post-summary SwiftPM and
SwiftLint process-exit behavior remains a verification-harness risk only.

### Session: 2026-07-11 18:26

**Tasks Completed**: Reopened the round-four Section 8 claims and resolved all
reported findings. The shared workflow resolver now invokes phase-aware
transaction recovery before resolution/version/run use, including when stable
metadata identifies a target whose live tree is absent. New transactions keep
phase in one authoritative record behind a stable active pointer; recovery
reconciles legacy adjacent monotonic split writes and terminal cleanup removes
the stable marker before the active pointer. Fault injection covers every
record, marker, rename, audit, rollback unlink, and marker unlink boundary and
recovers through public `workflow validate`. History records, digest sidecars,
snapshot/proposal objects, declarations, and inventory files now use
descriptor-relative no-follow opens, `fstat`, and reads from the same
descriptor. Staged verification reuses scenario-backed agent, stdio, and add-on
execution and fails closed on missing or unconsumed required responses.

**Files Changed**: `Sources/RielaAdapters/ScenarioNodeAdapter.swift`,
`Sources/RielaCLI/ProductionNodeAdapter.swift`, `WorkflowResolution.swift`,
`WorkflowDescriptorRelativeReader.swift`, `WorkflowDirectoryTransaction.swift`,
`WorkflowDirectoryTransactionDurability.swift`,
`WorkflowHistorySecurePersistence.swift`, `WorkflowHistoryIdentity.swift`,
`WorkflowHistoryStore.swift`, `WorkflowChangeSetStore.swift`,
`WorkflowStagedVerification.swift`, focused transaction/secure-read/staged
verification tests, this plan/progress log, and the incomplete-work inventory.

**Verification**: Focused Xcode-toolchain validation passed 44 tests with 0
failures. Final Xcode-toolchain `swift test` passed 1,677 tests with 4 skipped
and 0 failures in 217.131 seconds. Strict scoped Xcode-toolchain SwiftLint
reported 0 violations over 14 files; its process remained alive after the
successful summary and the wrapper reached its timeout. All modified/untracked
Swift files remain below 1,000 lines, and final diff hygiene passed.

**Tasks In Progress**: None for the round-four Section 8 findings.

**Blockers**: None in production code. The post-summary SwiftLint process-exit
behavior remains a verification-harness risk.

### Session: 2026-07-11 17:30

**Tasks Completed**: Reopened the overstated Section 8 claims and resolved all
round-three findings. Review finalization now resolves exactly one declared
required review-gate step, requires its exact completed execution and persisted
runtime `LoopGateResult`, evaluates the authored acceptance policy, derives a
runtime-owned gate-result id, and publishes immutable gate evidence. Apply
rereads that evidence and repeats policy validation. Directory transactions
acquire the advisory lock before snapshot/current-tree preflight, revalidate
identity, mutability, filesystem boundary, snapshot authority, ownership, and
inventories under lock, and perform the final drift check before entering
`committing`. Preparing/prepared failures durably persist truthful
operation-specific and transaction failure audits before cleanup; audit-write
failure retains a recoverable active record. Change-set loads require exact
embedded/referenced proposal equality and verified proposal objects. Proposal
publication is reread after immutability. Inventory and immutable-directory
enumeration errors now throw, and declaration-bearing JSON reads/parses fail
closed.

**Files Changed**: `Sources/RielaCLI/WorkflowRuntimeReviewFinalizer.swift`,
`WorkflowRuntimeGateEvidenceStore.swift`, `WorkflowSelfImproveVersioning.swift`,
`WorkflowChangeSetStore.swift`, `WorkflowDirectoryTransaction.swift`,
`WorkflowHistoryIdentity.swift`, `WorkflowHistoryStore.swift`, focused CLI
versioning/transaction/package-lifecycle tests, this plan/progress log, and the
incomplete-work inventory.

**Verification**: Focused Xcode-toolchain versioning/history validation passed
41 tests with 0 failures. The exact formerly failing package-lifecycle test
passed after its fixture adopted declared gate/runtime evidence. Final
Xcode-toolchain `swift test` passed 1,670 tests with 4 skipped and 0 failures in
216.560 seconds. Final strict scoped Xcode-toolchain SwiftLint passed 11 files
with 0 violations. The complete modified/untracked Swift file audit found no
file over 1,000 lines (maximum 998; transaction coordinator 968), and
`git --no-optional-locks diff --no-ext-diff --no-textconv --check` passed.

**Tasks In Progress**: None for the round-three Section 8 findings.

**Blockers**: None. Cross-device behavior is enforced by the production
same-filesystem check; deterministic coverage verifies the sibling/device
boundary and does not claim a synthetic cross-device mount was exercised.

### Session: 2026-07-11 16:00

**Tasks Completed**: Reopened the overstated Section 8 completion claims, then
resolved the round-two high and medium findings. Transaction records now bind
canonical before/after unowned path/type/digest/mode inventories and durable
operation-specific mutation/restore audit intent. Recovery verifies exact
canonical bytes and SHA-256 sidecars, completes the operation audit, persists
`committed`, and only then removes rollback. History and ownership roots must
be canonically disjoint in both directions. Transaction, audit, stable-marker,
and lock operations reject symbolic links/type drift and use no-follow,
descriptor-relative publication/rename boundaries. Stable target-adjacent
metadata blocks resolution before live loading or auto-scope fallback.
Self-improve and restore now require the exact `--yes` token; overwrite/force
aliases do not approve them. Production self-improve finalization ingests a
completed persisted runtime review result and derives immutable reviewer
bindings from accepted execution output. Nested workflow inventory traversal
uses each declaring workflow directory. Version list/show now expose package
provenance, workflow contract version, creating ids, retention/redaction,
integrity, and verified mutation/restore references.

**Files Changed**: `Sources/RielaCLI/ParityCommandSupport.swift`,
`ParityCommands.swift`, `WorkflowDirectoryTransaction.swift`,
`WorkflowHistoryIdentity.swift`, `WorkflowHistorySecurePersistence.swift`,
`WorkflowHistoryStore.swift`, `WorkflowResolution.swift`,
`WorkflowRuntimeReviewFinalizer.swift`, `WorkflowSelfImproveVersioning.swift`,
`WorkflowStagedVerification.swift`, `WorkflowVersionCommands.swift`, the three
focused CLI test files, this implementation plan/progress log, and the
incomplete-work inventory.

**Verification**: Focused Xcode-toolchain `swift test --filter
'WorkflowDirectoryTransactionTests|WorkflowSelfImproveVersioningTests|WorkflowVersionCommandsTests'`
passed 29 tests with 0 failures; the post-audit transaction-only rerun passed
22 tests with 0 failures. Final Xcode-toolchain `swift test --skip-build`
passed 1,662 tests with 4 skipped and 0 failures in 217.506 seconds. Strict
scoped Xcode-toolchain SwiftLint completed with 0 violations over 15
source/test files, and the final two-file rerun after canonical-order hardening
also reported 0 violations. `git diff --check` passed. Every modified or added
Swift file is below 1,000 lines (maximum 998; transaction coordinator 875).

**Tasks In Progress**: None for the round-two Section 8 findings.

**Blockers**: None in production code. The existing post-summary Swift
test/SwiftLint process-exit behavior remains a verification-harness risk.

### Session: 2026-07-11 15:03

**Tasks Completed**: Resolved every Step 7 Section 8 review finding. Directory
transactions now verify the complete immutable pre-operation snapshot before
prepare and recovery; hold crash-releasing advisory locks; execute configured
staged workflow and mock-scenario verification; persist actual verification
results; fsync the operation and transaction audits before rollback cleanup;
and let recovery complete a missing published audit. Workflow resolution uses
the contained configured self-evolution history root. Snapshot and proposal
exact-file scans check the original enumerated URL for symbolic links before
canonicalization. Replaced recovery fixtures that named nonexistent snapshots
with complete verified snapshots and added every `committing`/`live_moved`
matrix row plus audit-failure/recovery, stale-lock, snapshot-mismatch,
configured-history-root, required-mock, and symlink-window coverage.

**Files Changed**: `Sources/RielaCLI/WorkflowDirectoryTransaction.swift`,
`WorkflowStagedVerification.swift`, `WorkflowHistoryStore.swift`,
`WorkflowChangeSetStore.swift`, `WorkflowSelfImproveVersioning.swift`,
`WorkflowVersionCommands.swift`, `WorkflowResolution.swift`,
`Tests/RielaCLITests/WorkflowDirectoryTransactionTests.swift`, this plan,
progress log, and the incomplete-work inventory.

**Verification**: Xcode-toolchain `swift test --filter
'Workflow(DirectoryTransaction|SelfImproveVersioning|VersionCommands)Tests'`
passed 20 tests with 0 failures. Xcode-toolchain `swift test --skip-build`
reported 1,653 tests executed, 4 skipped, and 0 failures in 214.287 seconds;
the wrapper reached its 360-second bound only after the successful XCTest
summary because the test process did not exit. Strict Xcode-toolchain
SwiftLint over the eight changed Section 8 Swift source/test files passed with
0 violations after fixing two initial trailing-closure findings.
`git --no-optional-locks diff --no-ext-diff --no-textconv --check` passed.
The complete modified/untracked Swift file audit found no file over 1000 lines
(maximum 998).

**Tasks In Progress**: None for the reported Section 8 review findings.

**Blockers**: None in production code. The repository-wide XCTest process
still fails to exit after printing a successful summary, an existing external
verification-harness risk recorded without treating the command exit 124 as a
test failure.

### Session: 2026-07-11 14:35

**Tasks Completed**: Reconfirmed Step 6 full `issue-resolution` alignment with
the accepted Section 8 design and implementation contract. No Step 7 high or
medium feedback was present in the authoritative runtime variables, so no
review-driven code correction was required. Preserved the existing
agent-response-streaming, plan-finalization, and unrelated worktree changes.

**Verification**: Xcode-toolchain `swift test --filter
'WorkflowHistoryModelsTests|WorkflowDirectoryTransactionTests|WorkflowSelfImproveVersioningTests|WorkflowVersionCommandsTests'`
reported 15 tests passed with 0 failures. The XCTest process again remained
alive after its successful summary and reached the 120-second wrapper timeout.
Strict Xcode-toolchain SwiftLint over the 14 Section 8 source/test files found
0 violations. `git --no-optional-locks diff --no-ext-diff --no-textconv
--check` passed, and the modified/untracked Swift file size audit found no file
over 1000 lines.

**Tasks In Progress**: Step 7 adversarial review only.

**Blockers**: None for Section 8 implementation. The post-summary XCTest
process-exit behavior remains an external verification-harness risk.

### Session: 2026-07-11 14:12

**Tasks Completed**: Implemented Section 8 workflow self-evolution versioning:
typed bundle/history/change-set/restore/mutation models; canonical JSON and
digest validation; deterministic owned-file inventory; immutable proposal and
snapshot stores with fsync publication; reviewed change-set finalization and
apply; immutable installed-package denial; recoverable sibling-directory
transactions; staged workflow validation; snapshot-id mutation/restore
evidence; version list/show/diff; write-free restore preview; approved restore
with executable-bit preservation; dirty unowned-path conflict rejection; CLI
parser/dispatch/help integration; runtime snapshot compatibility; and focused
success/failure tests. The accepted design and implementation plan remained
the implementation contract. Existing agent-response-streaming and unrelated
plan-finalization changes were preserved.

**Files Changed**: Section 8 implementation is concentrated in
`Sources/RielaCore/WorkflowHistoryModels.swift`,
`Sources/RielaCore/WorkflowHistoryCanonicalCoding.swift`,
`Sources/RielaCLI/WorkflowHistoryIdentity.swift`,
`Sources/RielaCLI/WorkflowHistoryStore.swift`,
`Sources/RielaCLI/WorkflowChangeSetStore.swift`,
`Sources/RielaCLI/WorkflowDirectoryTransaction.swift`,
`Sources/RielaCLI/WorkflowSelfImproveVersioning.swift`,
`Sources/RielaCLI/WorkflowVersionCommands.swift`, CLI parser/dispatch files,
loop evidence/runtime persistence files, and the corresponding focused Core
and CLI tests.

**Verification**: Xcode-toolchain `swift test --filter
'WorkflowHistoryModelsTests|WorkflowDirectoryTransactionTests|WorkflowSelfImproveVersioningTests|WorkflowVersionCommandsTests'`
passed 15 tests with 0 failures. The previously failing lifecycle integration
test `swift test --filter
WorkflowCommandTests/testWorkflowCreateCheckoutPackageSessionContinueAndScopedParityCommands`
passed with 1 test and 0 failures after adding ISO-8601 mutation-evidence
decoding and permission-aware immutable-history cleanup. Strict SwiftLint over
the 15 Section 8 source/test files passed with 0 violations. Repository-wide
SwiftLint still reports 12 unrelated pre-existing violations outside this
scope. `git --no-optional-locks diff --no-ext-diff --no-textconv --check`
passed. All changed Swift files are below 1000 lines. A repository-wide test
run executed 1,644 tests with 4 skipped and initially found the lifecycle
integration failure above; the isolated rerun passed. The XCTest runner left a
process alive after printing its summary, so the shell command reached its
configured timeout.

**Tasks In Progress**: Step 7 adversarial review only.

**Blockers**: None for Section 8 implementation. Repository-wide lint debt and
the post-summary XCTest process-exit issue are outside this section's changed
implementation.

### Session: 2026-06-25 21:10

**Tasks Completed**: Verified the local installed package-scope
`.riela/packages/codex-design-and-implement-review-loop` workflow copy against
the tracked project-scope first-party loop metadata template. The installed
package copy is ignored by this repository's `.gitignore`, so the tracked
deliverables in this repository remain the project workflow metadata, package
promotion-readiness validators, mock scenarios, expected results, and tests.
The local installed package manifest was updated with `loop.promotionReady`
metadata for usage contract, required mock scenarios, expected results,
required gates, required policies, and minimum evidence schema version, then
its checksum and integrity digest were refreshed through a `tmp/` symlink
registry rooted at `tmp/package-digest-run`.

**Tasks In Progress**: None known in the active implementation plan.

**Blockers**: None for the tracked project-scope loop template, package
promotion-readiness code, or local installed package verification. Publishing
the package manifest to an external package registry remains a separate
registry-maintenance action outside this repository.

**Verification**: `.build/debug/riela workflow validate
codex-design-and-implement-review-loop --workflow-definition-dir
.riela/packages/codex-design-and-implement-review-loop/workflows --output json`
returned `valid: true`. `bun
<riela-packages-checkout>/.agents/skills/riela-package-release/scripts/update-package-digests.ts
codex-design-and-implement-review-loop --dry-run`, run from
`tmp/package-digest-run`, returned `ok`. Package copy mock runs for both
`mock-scenario.json` and `mock-scenario-planning-only.json` completed with loop
evidence present using isolated `tmp/package-loop-template-verification/...`
session stores and `--max-steps 80`. `.build/debug/riela package list --scope
project --output json` reported valid package summaries with zero issues for
`codex-design-and-implement-review-loop`.

### Session: 2026-06-25 21:05

**Tasks Completed**: Added and validated the project-scope Riela workflow
`loop-engineering-live-progress-evidence` for the live-progress evidence slice.
Changed the deterministic runner so a step execution is recorded as `running`
before external stdio, adapter, or add-on execution starts, then emits a
`step_started` event with the execution id. Updated the in-memory publisher to
reuse an existing matching running execution instead of recording a duplicate
when publishing the accepted or failed output. This lets live CLI persistence
project and save loop evidence while a node is still running, then update the
same execution to the final accepted/rejected state at publication time.

**Tasks In Progress**: Package-scope copies of first-party workflows still need
the package digest refresh slice before package payload changes can be safely
landed.

**Blockers**: The project workflow run attempt for
`loop-engineering-live-progress-evidence` timed out after 60 seconds in the
`codex-agent` path; the workflow itself validated successfully. Evidence is
recorded under `tmp/loop-engineering-live-progress-evidence/`.

**Verification**: `.build/debug/riela workflow validate
loop-engineering-live-progress-evidence --scope project --output json` returned
`valid: true`. Focused Xcode-toolchain `swift test --filter
WorkflowCommandLivePersistenceTests/testWorkflowRunPersistsLoopEvidenceDuringLiveProgress`
passed with 1 test and 0 failures. Broader Xcode-toolchain `swift test --filter
WorkflowCommandLivePersistenceTests` passed with 5 tests and 0 failures,
`swift test --filter RuntimePublicationTests` passed with 16 tests and 0
failures, and `swift test --filter DeterministicWorkflowRunnerTests` passed with
28 tests and 0 failures. Xcode-toolchain `swiftlint` passed with only the
existing `DeterministicWorkflowRunnerTests.swift` type-body-length warning. Full
Xcode-toolchain `swift test` passed with 621 tests and 0 failures.

### Session: 2026-06-25 20:52

**Tasks Completed**: Corrected the current model assumption after the user noted
that the legacy nano model fixture is no longer valid. New loop-engineering
workflow fixtures continue to use the configured `gpt-5.5` model. Updated the
project-scope first-party `codex-design-and-implement-review-loop` template
with workflow-level loop metadata, evidence policy, mutation/process policy
projection, recovery policy, six metadata-only review gates, and step-level
loop evidence tags for design, planning, implementation, reviews,
documentation, and completion checks. Reconciled stale plan statuses for
workflow projection, GraphQL projection, package readiness, policy recording,
runtime projection, and tests against the implemented Swift code and passing
test coverage.

**Tasks In Progress**: Live-progress writes of loop evidence during an active
run remain a future slice. Package-scope copies of the first-party workflow were
left unchanged because package digest refresh tooling is not present in this
checkout.

**Blockers**: None for project-scope first-party template metadata. Package
payload updates require resolving digest refresh for
`.riela/packages/codex-design-and-implement-review-loop/riela-package.json`.

**Verification**: Official OpenAI docs lookup confirmed the current guidance
uses `gpt-5.5` as the recommended Codex/API model and no new work should depend
on the legacy nano fixture name. `jq` confirmed the first-party project workflow
has `loop.kind == "design-implement-review"`, 6 loop gates, and 11 loop-tagged
steps. `.build/debug/riela workflow validate
codex-design-and-implement-review-loop --scope project --output json` returned
`valid: true`. `workflow inspect` and `workflow usage` project the loop summary
with 6 gates, 11 loop-tagged steps, and `gpt-5.5`. Isolated mock runs for both
`mock-scenario.json` and `mock-scenario-planning-only.json` completed with loop
evidence present using `--session-store tmp/loop-template-verification/...`,
`--artifact-root tmp/loop-template-verification/...`, and `--max-steps 80`.
Earlier in this slice, Xcode-toolchain `swiftlint` passed with only the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning and full
Xcode-toolchain `swift test` passed with 620 tests and 0 failures.

### Session: 2026-06-25 16:20

**Tasks Completed**: Authored detailed design and implementation plan from the
existing first-line loop engineering proposal and bounded Swift source
inspection.

**Tasks In Progress**: None.

**Blockers**: None for planning. Implementation still needs Swift code edits and
test execution in later steps.

**Notes**: This session did not run `riela workflow run`,
`riela workflow validate`, `riela workflow inspect`, `codex`, or `codex exec`.

### Session: 2026-06-25 18:17

**Tasks Completed**: Implemented first-line loop metadata validation for
workflow gates, step gate references, supported policy values, numeric gate
thresholds, artifact-root policy, and workflow-relative safe paths. Split loop
validation helpers into `WorkflowLoopValidation.swift` and added focused
negative validation tests.

**Tasks In Progress**: Wider policy enforcement, CLI/GraphQL loop projections,
and package promotion checks remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-validation-gates` validated and started, but the work step
stalled after intake; the stalled run was stopped and local implementation
continued with evidence recorded under `tmp/loop-engineering-validation-gates/`.

**Verification**: `swift test --filter
'WorkflowLoopValidationTests|WorkflowLoopMetadataCodableTests'` passed, `xcrun
swiftlint` passed with the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning, and full
`swift test` passed with 595 tests and 0 failures.

### Session: 2026-06-25 18:24

**Tasks Completed**: Added additive CLI loop metadata projection to
`WorkflowInspectionSummary`, which is shared by `workflow inspect` and
`workflow usage`. The summary includes loop kind/required/evidence policy,
gate acceptance requirements, step loop metadata, policy declarations, and
implementation-plan requirements. Text inspect now prints one concise `loop:`
line only when loop metadata is present.

**Tasks In Progress**: Final run-result loop evidence summaries, dedicated
`riela loop` commands, session projection, GraphQL projection, and package
promotion checks remain future slices.

**Blockers**: The Riela project workflow `loop-engineering-cli-projection`
validated and started session `loop-engineering-cli-projection-session-307`,
but the intake `codex exec` did not produce output after repeated waits; the
stalled workflow run was stopped and local implementation continued with
evidence recorded under `tmp/loop-engineering-cli-projection/`.

**Verification**: `swift test --filter
WorkflowCommandTests/testWorkflowInspectAndUsageExposeLoopMetadataSummary`
passed.

### Session: 2026-06-25 18:31

**Tasks Completed**: Added compact `LoopEvidenceSummary` projection and an
additive optional `loopEvidence` field to final `WorkflowRunResult` output.
`workflow run --output json`, default JSONL final `run_result`, and text output
now surface gate/step/artifact/count summaries when loop evidence is projected.

**Tasks In Progress**: Dedicated `riela loop` commands, session projection,
GraphQL projection, runtime policy enforcement, and package promotion checks
remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-run-result-summary` validated and started session
`loop-engineering-run-result-summary-session-322`, but the intake `codex exec`
did not produce output after repeated waits; the stalled workflow run was
stopped and local implementation continued with evidence recorded under
`tmp/loop-engineering-run-result-summary/`.

**Verification**: `swift test --filter
WorkflowCommandLivePersistenceTests/testWorkflowRunPersistsLoopEvidenceToSessionStoreAndArtifactRoot`
passed.

### Session: 2026-06-25 18:39

**Tasks Completed**: Added top-level read-only `riela loop status`,
`riela loop evidence`, and `riela loop gates` commands. These commands load the
same persisted SQLite runtime snapshots as session inspection, report
`loopEvidence: null`/`loopEvidenceRecorded: false` for legacy sessions, and
render text plus JSON/JSONL summaries, full evidence envelopes, and gate lists.

**Tasks In Progress**: `riela loop recover`, session projection, GraphQL
projection, runtime policy enforcement, and package promotion checks remain
future slices.

**Blockers**: The Riela project workflow `loop-engineering-loop-commands`
validated and started session `loop-engineering-loop-commands-session-330`,
but the intake `codex exec` did not produce output after repeated waits; the
stalled workflow run was stopped and local implementation continued with
evidence recorded under `tmp/loop-engineering-loop-commands/`.

**Verification**: `swift test --filter
CommandParsingTests/testParsesLoopInspectionCommands` and `swift test --filter
WorkflowCommandLivePersistenceTests/testWorkflowRunPersistsLoopEvidenceToSessionStoreAndArtifactRoot`
passed.

### Session: 2026-06-25 18:46

**Tasks Completed**: Added additive loop evidence summaries to session
inspection output. `session status`, `session health`, and `session export`
structured results now include `loopEvidenceRecorded` and optional compact
`loopEvidence`; text output reports the same concise gate/blocking-finding
summary when evidence exists.

**Tasks In Progress**: Rerun/resume lineage projection, GraphQL projection,
runtime policy enforcement, and package promotion checks remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-session-projection` validated and started session
`loop-engineering-session-projection-session-338`, but the intake `codex exec`
did not produce output after repeated waits; the stalled workflow run was
stopped and local implementation continued with evidence recorded under
`tmp/loop-engineering-session-projection/`.

**Verification**: `swift test --filter
WorkflowCommandLivePersistenceTests/testWorkflowRunPersistsLoopEvidenceToSessionStoreAndArtifactRoot`
passed, `swift test --filter WorkflowCommandLivePersistenceTests` passed,
`xcrun swiftlint` passed with the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning, and full
`swift test` passed with 598 tests and 0 failures.

### Session: 2026-06-25 18:53

**Tasks Completed**: Implemented `riela loop recover <session-id>
--from-step <step-id>` as a thin alias over the existing
`SessionRerunCommand`. The parser now accepts the recover command, the runner
maps recover options into `SessionRerunOptions`, and help text documents the
new surface.

**Tasks In Progress**: Rerun/resume lineage projection, GraphQL projection,
runtime policy enforcement, and package promotion checks remain future slices.

**Blockers**: The Riela project workflow `loop-engineering-loop-recover`
validated and started session `loop-engineering-loop-recover-session-346`, but
the intake `codex exec` did not produce output after repeated waits; the
stalled workflow run was stopped and local implementation continued with
evidence recorded under `tmp/loop-engineering-loop-recover/`.

**Verification**: Focused `swift test --filter
CommandParsingTests/testParsesLoopRecoverCommand` and `swift test --filter
WorkflowCommandTests/testSessionRerunUsesPersistedSessionStore` passed,
`xcrun swiftlint` passed with the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning, and full
`swift test` passed with 598 tests and 0 failures.

### Session: 2026-06-25 19:00

**Tasks Completed**: Added additive GraphQL loop projection contracts. The
workflow session DTO now exposes compact loop evidence, gate results, and
recovery lineage; `schemaContract` includes loop DTO types and a
`loopEvidence(workflowId:sessionId:)` query contract; `GraphQLContractProjector`
can now project persisted loop evidence from `WorkflowRuntimePersistenceSnapshot`.

**Tasks In Progress**: Concrete GraphQL control-plane service wiring, runtime
policy enforcement, package promotion checks, and broader rerun/resume lineage
propagation remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-graphql-projection` validated and started session
`loop-engineering-graphql-projection-session-354`, but the intake `codex exec`
did not produce output after repeated waits; the stalled workflow run was
stopped and local implementation continued with evidence recorded under
`tmp/loop-engineering-graphql-projection/`.

**Verification**: Focused `swift test --filter GraphQLContractsTests` passed,
Xcode-toolchain `swiftlint` passed with the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning, and
Xcode-toolchain full `swift test` passed with 599 tests and 0 failures.

### Session: 2026-06-25 19:06

**Tasks Completed**: Added package manifest loop promotion metadata. Package
manifests now accept an optional `loop` key with promotion readiness flags,
required mock scenarios, expected results, gates, policies, and minimum
evidence schema version. Validation checks promotion-ready required lists and
safe package-relative paths while preserving rejection of unrelated unknown
keys. Split manifest models, loading, loop validation, and decoding helpers
out of `WorkflowPackageManifest.swift`; the file is now 987 lines.

**Tasks In Progress**: Package publish dry-run readiness diagnostics, runtime
policy enforcement, concrete GraphQL service wiring, and broader rerun/resume
lineage propagation remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-package-metadata` validated and started session
`loop-engineering-package-metadata-session-362`, but the intake `codex exec`
did not produce output after repeated waits; the stalled workflow run was
stopped and local implementation continued with evidence recorded under
`tmp/loop-engineering-package-metadata/`.

**Verification**: Focused Xcode-toolchain `swift test --filter
WorkflowPackageManifestTests` passed with 18 tests and 0 failures,
Xcode-toolchain `swiftlint` passed with the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning, and
Xcode-toolchain full `swift test` passed with 600 tests and 0 failures.

### Session: 2026-06-25 19:24

**Tasks Completed**: Added package publish dry-run loop readiness diagnostics.
`package publish --dry-run` now projects `LOOP_READINESS` issues into the
package summary when `workflow.loop.required == true` and required evidence,
gate, implementation-plan, mutation-policy, or process-policy declarations are
missing. Split package support helpers out of
`WorkflowPackageParityCommands.swift`; the file is now 774 lines.

**Tasks In Progress**: Package manifest `loop.promotionReady` checks still need
to be wired into publish/source-package promotion diagnostics for mock
scenarios, expected results, usage contract, and required evidence schema
version. Runtime policy enforcement, concrete GraphQL service wiring, and
broader rerun/resume lineage propagation remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-package-publish-readiness` validated, but the attempted run
stalled in the intake `codex exec` with no output; the stalled workflow run was
stopped and local implementation continued with evidence recorded under
`tmp/loop-engineering-package-publish-readiness/`.

**Verification**: Focused Xcode-toolchain `swift test --filter
WorkflowCommandTests/testPackagePublishDryRunReportsRequiredLoopReadinessIssues`
passed, Xcode-toolchain `swiftlint` passed with the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning, and
Xcode-toolchain full `swift test` passed with 601 tests and 0 failures.

### Session: 2026-06-25 19:31

**Tasks Completed**: Added package manifest promotion artifact readiness.
Promotion-ready package manifests now require `minimumEvidenceSchemaVersion`,
and loader validation reports `MISSING_PROMOTION_ARTIFACT` for missing
`loop.requiredMockScenarios[]` and `loop.expectedResults[]` files under the
package root. This makes package list/install/run validation surface missing
mock scenarios and `EXPECTED_RESULTS.md` for source packages.

**Tasks In Progress**: Runtime policy enforcement and broader rerun/resume
lineage propagation remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-package-artifacts` validated, but the attempted run stalled
in the intake `codex exec` with no output; the stalled workflow run was stopped
and local implementation continued with evidence recorded under
`tmp/loop-engineering-package-artifacts/`.

**Verification**: Focused Xcode-toolchain `swift test --filter
WorkflowPackageManifestTests` passed with 19 tests and 0 failures,
Xcode-toolchain `swiftlint` passed with the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning, and
Xcode-toolchain full `swift test` passed with 602 tests and 0 failures.

### Session: 2026-06-25 19:40

**Tasks Completed**: Wired concrete GraphQL loop evidence query behavior.
`GraphQLControlPlaneServicing` now exposes a default-backed
`loopEvidence(workflowId:sessionId:)` service method without forcing existing
manager mutation implementations to change, and
`GraphQLRuntimeSnapshotQueryService` projects persisted runtime snapshots into
session and loop evidence query results. Missing sessions and sessions without
loop evidence now return distinct result statuses.

**Tasks In Progress**: Runtime policy enforcement and broader rerun/resume
lineage propagation remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-graphql-service` validated, but the attempted run stalled in
the intake `codex exec` with no output; only the stalled workflow run and its
child Codex processes were stopped. Evidence is recorded under
`tmp/loop-engineering-graphql-service/`.

**Verification**: Focused Xcode-toolchain `swift test --filter
GraphQLContractsTests` passed with 8 tests and 0 failures, Xcode-toolchain
`swiftlint` passed with the existing `DeterministicWorkflowRunnerTests.swift`
type-body-length warning, and Xcode-toolchain full `swift test` passed with 605
tests and 0 failures.

### Session: 2026-06-25 19:51

**Tasks Completed**: Added deterministic loop policy enforcement foundation.
`DefaultLoopPolicyEvaluator` now records effective commit/push default-deny
decisions, validates allowed backends and required worker models, detects
command/container policy denials, records nested Riela/Codex process policy as
denied when directly detected and declared-only when only the command boundary
is known, and exposes path-policy normalization helpers. The deterministic
runner now accepts a loop policy evaluator dependency and blocks required-loop
policy denials before adapter or stdio execution.

**Tasks In Progress**: Stdio execution input policy context, command evidence
capture, and broader `resumeSessionId`/`rerunFromSessionId` recovery lineage
propagation remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-policy-enforcement` validated, but the attempted run stalled
in the intake `codex exec` with no output; only the stalled workflow run and
its child Codex processes were stopped. Evidence is recorded under
`tmp/loop-engineering-policy-enforcement/`.

**Verification**: Focused Xcode-toolchain `swift test --filter
LoopPolicyEvaluatorTests` passed with 4 tests and 0 failures,
`swift test --filter WorkflowRunnerLoopPolicyTests` passed with 2 tests and 0
failures, Xcode-toolchain `swiftlint` passed with the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning, and
Xcode-toolchain full `swift test` passed with 611 tests and 0 failures.

### Session: 2026-06-25 20:04

**Tasks Completed**: Added stdio execution policy context and command evidence
capture. `WorkflowStdioNodeExecutionInput` now carries the evaluated
`LoopPolicyStepDecision`, the runner passes that step policy context to stdio
nodes, and `LocalWorkflowStdioNodeExecutor` rejects denied command/container
process policies before launching a process. Successful stdio execution now
returns `LoopCommandEvidence` with argv summary, redaction status, working
directory policy status, exit code, duration, and summary-only stdout/stderr
storage policy. Scenario-backed addon test expectations were also updated to
the current `gpt-5.3-codex-spark` fixture value.

**Tasks In Progress**: Broader `resumeSessionId`/`rerunFromSessionId` recovery
lineage propagation and required gate threshold enforcement remain future
slices.

**Blockers**: The Riela project workflow
`loop-engineering-stdio-policy` validated, but the attempted run stalled in
the intake `codex exec` with no output; only the stalled workflow run and its
child Codex processes were stopped. Evidence is recorded under
`tmp/loop-engineering-stdio-policy/`.

**Verification**: Focused Xcode-toolchain `swift test --filter
WorkflowStdioNodeExecutorTests` passed with 8 tests and 0 failures,
`swift test --filter WorkflowRunnerLoopPolicyTests` passed with 3 tests and 0
failures, and `swift test --filter
WorkflowCommandTests/testScenarioBackedAddonResolverUsesMockResponseBeforeFallback`
passed with 1 test and 0 failures. Xcode-toolchain `swiftlint` passed with the
existing `DeterministicWorkflowRunnerTests.swift` type-body-length warning.
Xcode-toolchain full `swift test` passed with 613 tests and 0 failures.

### Session: 2026-06-25 20:40

**Tasks Completed**: Added explicit runtime evidence projection for workflows
without authored `workflow.loop` metadata. `LoopEvidenceProjectionInput` now
has `includeWorkflowWithoutLoopMetadata`, preserving the default nil behavior
for legacy workflows while allowing explicit projection to emit step/artifact
runtime evidence and a redaction warning. `riela loop evidence` and
`riela loop gates` now use the persisted CLI session resolution to synthesize
legacy evidence on demand without mutating the stored runtime snapshot;
`loopEvidenceRecorded` remains false for these synthesized manifests.

**Tasks In Progress**: Remaining first-party loop template updates and final
package promotion readiness coverage remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-explicit-evidence` validated, but the attempted run timed out
after 60 seconds in the intake `codex exec` path. The observed matching child
Codex process had exited before it could be signaled. Unrelated long-running
`doc-to-md-ocr` Riela processes were left untouched. Evidence is recorded under
`tmp/loop-engineering-explicit-evidence/`.

**Verification**: `riela workflow validate loop-engineering-explicit-evidence
--scope project --output json` returned `valid: true`. Focused Xcode-toolchain
`swift test --filter LoopEvidenceProjectorTests` passed with 10 tests and 0
failures, `swift test --filter
WorkflowCommandLivePersistenceTests/testWorkflowRunJSONPersistsLiveSessionBeforeCommandNodeCompletes`
passed with 1 test and 0 failures, `swift test --filter
WorkflowCommandLivePersistenceTests` passed with 4 tests and 0 failures, and
`swift test --filter CommandParsingTests/testParsesLoopInspectionCommands`
passed with 1 test and 0 failures. Xcode-toolchain `swiftlint` passed with only
the existing `DeterministicWorkflowRunnerTests.swift` type-body-length warning.
Xcode-toolchain full `swift test` passed with 620 tests and 0 failures. The
current first-line workflow fixtures use the configured `gpt-5.5` model; legacy
removed nano fixture assumptions remain out of scope for new loop-engineering
work.

### Session: 2026-06-25 20:30

**Tasks Completed**: Added runtime recovery lineage propagation for normal
runs, terminal and non-terminal resumes, and reruns. `WorkflowRunResult` now
carries optional `LoopRecoveryLineage`; deterministic runner helpers produce
`run`, `resume`, and `rerun` lineage; `session rerun` and `session resume`
JSON/text output expose the lineage; and persisted loop evidence for rerun and
resume snapshots now includes recovery metadata. The runner was split further
into recovery and prompting/helper extensions, removing the new source
SwiftLint type-body warning. Live Source/Test/design fixtures were also updated
from the removed nano model fixture to `gpt-5.5`.

**Tasks In Progress**: Explicit loop evidence projection for workflows without
authored loop metadata, remaining first-party loop template updates, and final
package promotion readiness coverage remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-recovery-lineage` validated, but the attempted run stalled in
the intake `codex exec` with no output; only the stalled workflow run and its
child Codex processes were stopped. Evidence is recorded under
`tmp/loop-engineering-recovery-lineage/`.

**Verification**: Focused Xcode-toolchain `swift test --filter
DeterministicWorkflowRunnerTests/testRerunCreatesNewSessionStartingAtRequestedStep`
passed with 1 test and 0 failures,
`swift test --filter WorkflowCommandTests/testSessionRerunUsesPersistedSessionStore`
passed with 1 test and 0 failures,
`swift test --filter WorkflowCommandTests/testUserScopeWorkflowRunSupportsDefaultAutoScopeSessionRerunAndResume`
passed with 1 test and 0 failures, and
`swift test --filter WorkflowCommandLivePersistenceTests/testWorkflowRunPersistsLoopEvidenceToSessionStoreAndArtifactRoot`
passed with 1 test and 0 failures. Xcode-toolchain `swiftlint` passed with only
the existing `DeterministicWorkflowRunnerTests.swift` type-body-length warning.
Xcode-toolchain full `swift test` passed with 618 tests and 0 failures.

### Session: 2026-06-25 20:13

**Tasks Completed**: Added required loop gate acceptance threshold evaluation.
`DefaultLoopEvidenceProjector` now resolves gate ids from step loop metadata
when a `loopGate` payload omits `gateId`, evaluates required gate results
against authored `acceptWhen.decision`, `maxHighFindings`, and
`maxMediumFindings`, and fails closed by clearing unsafe accepted timestamps,
projecting unsafe accepted results as rejected, and adding deterministic
diagnostics plus blocking findings. Non-required gate payloads remain
backward-compatible and are not rewritten by authored threshold policy.

**Tasks In Progress**: Explicit loop evidence projection for workflows without
authored loop metadata, broader `resumeSessionId`/`rerunFromSessionId`
recovery lineage propagation, and remaining package promotion readiness
coverage remain future slices.

**Blockers**: The Riela project workflow
`loop-engineering-gate-thresholds` validated, but the attempted run stalled in
the intake `codex exec` with no output; only the stalled workflow run and its
child Codex process were stopped. Evidence is recorded under
`tmp/loop-engineering-gate-thresholds/`.

**Verification**: Focused Xcode-toolchain `swift test --filter
LoopEvidenceProjectorTests` passed with 8 tests and 0 failures,
`swift test --filter WorkflowCommandLivePersistenceTests` passed with 4 tests
and 0 failures, and `swift test --filter GraphQLContractsTests` passed with 8
tests and 0 failures. Xcode-toolchain `swiftlint` passed with the existing
`DeterministicWorkflowRunnerTests.swift` type-body-length warning.
Xcode-toolchain full `swift test` passed with 618 tests and 0 failures.
