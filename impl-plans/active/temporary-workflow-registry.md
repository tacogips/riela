# Temporary Workflow Registry Implementation Plan

**Status**: Implemented; awaiting independent implementation review  
**Workflow Mode**: `issue-resolution`  
**Branch**: `feat/temporary-workflow-registry`  
**Design Reference**: `design-docs/specs/design-temporary-workflow-registry.md`  
**Design Commit Reference**: `f1bd558`  
**Accepted Design Review**: `comm-000025`, `accepted-for-implementation-planning`  
**Created**: 2026-07-22  
**Last Updated**: 2026-07-23

---

## Objective

Implement one additive Swift CLI feature that registers validated workflow JSON
files or bundles as persistent user-scoped temporary workflows, lists them with
explicit provenance, and resolves them as the fifth and lowest-precedence local
workflow candidate.

The accepted design is the source of truth. This plan does not reopen the
command shape, storage path, provenance model, precedence, lock protocol, or
scope decisions.

## References and review input

- Issue title: **Add temporary (adhoc) workflow registration, listing, and run
  support to riela CLI**.
- Issue URL, repository, and number: not supplied.
- Design: `design-docs/specs/design-temporary-workflow-registry.md`.
- Codex-agent references: none.
- User-QA references: none; the accepted design records no unresolved user
  decisions.
- Accepted low finding: the condensed design data flow mentions only the
  per-workflow lock. Every task below treats the mandatory ordering as
  `catalog.lock` first, then `<workflowId>.lock`, before recovery or publication.
- Step 4 self-review `comm-000027` identified a plan-only gap for existing
  workflow mutation paths. T7 now owns temporary-aware coordination for version
  restore, self-improvement application, and any additional live-bundle writer
  found by T1, including mutation-versus-registration race verification.
- Design-section traceability: T2/T7/T8 implement **Storage and lifecycle**;
  T3/T5 implement **Catalog and provenance**; T4 implements **User contract**
  and **Validation and errors**; T6/T9 implement **Resolution and scope rules**;
  T10 implements **Rollout and verification gates**. This resolves the
  non-blocking Step 5 traceability feedback from `comm-000030`.
- Step 6 self-review findings `comm-000032` and `comm-000034` reopened T2 and
  T6-T9 for fail-closed recovery, lock-boundary, registry-key identity, and
  genuine next-invocation interruption coverage; the progress log records both
  correction passes and their verification evidence.
- Step 6 self-review `comm-000036` reopened T8-T9 for the remaining accepted
  input-hardening, deterministic concurrency, catalog, persistence, and exact
  five-candidate resolution matrix; focused companion test files keep every
  changed Swift file below the repository's 1000-line limit.
- Step 6 test-integrity review `comm-000039` reopened T8-T9 for exact
  four-format provenance assertions, deterministic lock-boundary probes, and
  registration renderer coverage. The correction adds injectable no-op lock
  hooks and replaces command-start timing assumptions with probes immediately
  before and after the actual advisory-lock acquisition.
- Step 7 review `comm-000047` reopened T2, T5, T6, T8, and T10 for read-only
  access to an absent registry and fail-closed preservation when in-call
  publication recovery itself fails. The correction keeps absent-registry
  catalog/resolution paths non-mutating and propagates combined publication and
  recovery diagnostics without deleting transaction staging evidence.
- Step 7 review `comm-000051` reopened T2, T5-T6, and T8-T10 for descriptor-
  pinned registry operations, fail-closed handling of a present registry with
  missing internal state, and direct empty-query coverage. The correction pins
  registry-owned creation, locking, reads, renames, and removal below the
  selected home with `openat`-family operations and distinguishes a wholly
  absent registry from an incomplete one.
- Step 7 adversarial review `comm-000056` reopened T2, T5, T7-T10 for a
  whole-operation pinned-root lifetime, stale resolved-bundle mutation, truthful
  post-commit results, the relative `--working-dir` and direct `packageName`
  query regressions, and refreshed isolated-home smoke evidence.
- Step 6 self-review `comm-000062` reopened T2, T7, and T8 for detached-root
  containment and the two unpersisted rename windows. The correction restricts
  physical ownership to a descriptor-validated UUID snapshot namespace, binds
  its container device/inode to stable metadata, and distinguishes first-rename
  rollback from post-second-rename publication rollback.
- Step 6 self-review `comm-000064` reopened T2, T7, and T8 because detached
  recovery released that validated descriptor before mutation. The correction
  retains it through recovery and fails closed on a deterministic
  post-validation ownership-container replacement.
- Step 6 self-review `comm-000066` reopened T2, T7, and T8 because detached
  commit retained only scalar ownership identity after validation. The
  correction retains the container descriptor through commit preflight,
  staging, verification, publication renames, cleanup, and fsync.

## Scope

### Included

- `riela workflow register <path> --temporary [--overwrite]` with
  `--working-dir` and `--output jsonl|json|text|table`.
- Secure file/bundle inventory, staging, full workflow validation, and
  lock-coordinated recoverable publication under
  `~/.riela/temporary-workflows/<workflowId>/`.
- Registry-wide and keyed advisory locks, versioned transaction records,
  bundle-inventory digests, two-rename overwrite publication, and recovery.
- Additive `temporary: Bool` provenance with decode-default `false`, without a
  new `WorkflowSourceKind` case.
- Default catalog inclusion, direct descriptor loading, invalid-entry
  visibility, list query behavior, and `--exclude-temporary`.
- Fifth-position temporary workflow resolution for run, validate, inspect,
  usage, and status.
- Focused tests, help text, user-facing documentation, and isolated-home smoke
  verification.

### Excluded

- Project-scoped temporary storage, registry downloads, package installation,
  expiry, removal, or a new workflow format.
- A `WorkflowSourceKind.temporary` enum case or changes to the first four
  resolution candidates.
- Changes outside the workflow CLI/catalog/resolver and directly affected docs.
- Codex-agent or Cursor adapter work; no reference input exists.

## Task breakdown

### T1. Baseline and contract audit

**Status**: COMPLETED  
**Write scope**: none, except scratch evidence under
`tmp/temporary-workflow-registry/`  
**Depends on**: accepted Step 3 design review

**Deliverables**:

- Confirm branch, dirty-worktree ownership, current CLI parser/dispatch flow,
  catalog rendering, resolver precedence, validator entry points, runtime home
  resolution, directory transaction helpers, and focused test conventions.
- Record the exact public Codable types that need additive `temporary` fields
  and prove their older-payload decode paths before changing them.
- Identify existing filesystem lock, canonical-path, `lstat`, digest, and
  atomic-write helpers that can be reused without weakening the accepted
  registry protocol.
- Record implementation-only discoveries in the progress log; stop for design
  revision only if a discovery conflicts with an accepted product contract.

**Verification**:

- `git status --short --branch`
- `rg -n "WorkflowSourceKind|ResolvedWorkflowBundle|WorkflowCatalog|CLIRuntimeEnvironment|DefaultWorkflowValidator|WorkflowDirectoryTransaction" Sources/RielaCLI Tests/RielaCLITests`

### T2. Secure temporary-registry storage and recovery foundation

**Status**: COMPLETED  
**Write scope**: new focused registry support under `Sources/RielaCLI/` (prefer
`WorkflowTemporaryRegistry.swift`); reuse or extend
`Sources/RielaCLI/WorkflowDirectoryTransaction.swift` only where its existing
contracts remain compatible; focused support tests in
`Tests/RielaCLITests/WorkflowTemporaryRegistrationTests.swift`  
**Depends on**: T1

**Deliverables**:

- Resolve the user registry root through `CLIRuntimeEnvironment` and define the
  reserved `.registry-state` layout for catalog lock, keyed locks, active
  records, record staging, bundle staging, and backups.
- Enforce containment without following symlinks for the registry root, every
  internal directory/file, destination, lock, record, staging, and backup path;
  reject special files and unsafe workflow identifiers.
- Implement advisory regular-file locks on Darwin/Linux with the fixed order
  `catalog.lock` then `<workflowId>.lock`; no code path may acquire the catalog
  lock while retaining a keyed lock.
- Define schema-version-1 transaction records and durable phase updates for
  `prepared`, `movingOriginal`, `originalBackedUp`,
  `publishingReplacement`, and `replacementPublished`.
- Compute deterministic SHA-256 bundle-inventory digests over sorted relative
  paths, entry types, and regular-file contents.
- Implement keyed recovery and stable-order sweep recovery that restore a
  provable prior entry or retain a verified replacement, fail closed on
  ambiguous/malformed/linked state, and preserve forensic artifacts.
- Restrict detached physical ownership roots to process-created UUID containers
  below the canonical temporary namespace, validate every existing component
  with `O_NOFOLLOW`, and bind the container device/inode in durable metadata
  before commit or recovery can rename or remove a detached tree. Retain that
  descriptor through commit and recovery inventory, staging, cleanup, removal,
  rename, and fsync; a changed configured container identity must fail closed
  before mutation.
- Provide deterministic boundary hooks for failure, interruption, race, and
  reader-blocking tests without production timing sleeps.

**Verification**:

- Focused tests for path/symlink/special-file rejection, lock ordering, durable
  records, every phase boundary, recovery decisions, and fail-closed state.
- `swift test --filter WorkflowTemporaryRegistrationTests`

### T3. Temporary provenance contracts

**Status**: COMPLETED  
**Write scope**: provenance/result models in
`Sources/RielaCLI/WorkflowCatalogCommands.swift`,
`Sources/RielaCLI/WorkflowResolution.swift`, and directly associated Codable
result definitions; compatibility tests in
`Tests/RielaCLITests/WorkflowCommandCatalogTests.swift` and
`Tests/RielaCLITests/WorkflowCommandScopedResolutionTests.swift`  
**Depends on**: T1

**Deliverables**:

- Add explicit `temporary: Bool` provenance to `ResolvedWorkflowBundle` and
  catalog, validation, inspection/usage, and status results.
- Preserve `WorkflowSourceKind` as `workflow|package` and existing field
  meanings.
- Decode missing `temporary` as `false` for all previously decodable payloads;
  always encode the field in JSON and JSONL.
- Ensure origin descriptors carry scope, source kind, temporary, mutable, root,
  directory, and package metadata so catalog loading never reconstructs
  provenance from a path or name.

**Verification**:

- Codable compatibility tests for payloads with and without `temporary`.
- Focused catalog/result model tests.

### T4. Registration command, typed parsing, dispatch, and rendering

**Status**: COMPLETED  
**Write scope**:
`Sources/RielaCLI/WorkflowTemporaryRegistrationCommand.swift` (new),
`Sources/RielaCLI/ParsedWorkflowOptions.swift`,
`Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift`,
`Sources/RielaCLI/RielaClientFamilyArguments.swift`,
`Sources/RielaCLI/RielaCommand.swift`, and
`Sources/RielaCLI/RielaCLIApplication.swift`  
**Depends on**: T2, T3

**Deliverables**:

- Parse and dispatch `workflow register <path> --temporary [--overwrite]
  [--working-dir <dir>] [--output jsonl|json|text|table]`, with JSONL default.
- Parse the list positional query and `--exclude-temporary`; leave their catalog
  behavior to T5 so parser/help ownership does not overlap catalog logic.
- Require `--temporary`, reject extra/empty inputs through typed usage errors,
  and resolve relative input only against `--working-dir`.
- Accept only a regular JSON file or a real bundle directory with root
  `workflow.json`; copy a file as `workflow.json` and inventory a directory
  recursively without accepting symlinks, special files, or escapes.
- Stage and load the copy, decode the registry key from `workflowId`, run the
  same bundle and `DefaultWorkflowValidator` validation as `workflow validate`,
  then publish under catalog-lock-before-workflow-lock ordering.
- Reject duplicates without mutation and suggest `--overwrite`; on overwrite,
  never expose a backup-only result to registry-owned readers.
- Render the accepted structured success fields and a literal `temporary`
  marker in text/table output; keep requested structured errors machine
  readable.
- Document the new command and flags in command help.

**Verification**:

- Parser/help tests for required and optional flags and all output modes.
- Registration tests for file and bundle inputs, duplicates, overwrite,
  invalid JSON/schema/assets, and no-mutation failure behavior.
- `.build/debug/riela workflow register --help`

### T5. Catalog discovery, list filtering, query, and rendering

**Status**: COMPLETED  
**Write scope**: `Sources/RielaCLI/WorkflowCatalogCommands.swift`; focused changes in
`Tests/RielaCLITests/WorkflowCommandCatalogTests.swift`  
**Depends on**: T2, T3

**Deliverables**:

- When temporary entries are scope-eligible, hold `catalog.lock` from recovery
  sweep through immediate-child snapshot, excluding `.registry-state`, then
  load each snapshot descriptor under its keyed lock.
- Direct-load each descriptor so duplicate names retain their true origin and
  invalid temporary directories remain visible as `valid: false` and
  `temporary: true`.
- Add `--exclude-temporary` and apply filters in the fixed order: scope,
  exclusion, optional query, existing sort, rendering.
- Consume the optional positional target as a nonempty case-insensitive
  substring query over `workflowName` and optional `packageName` only.
- Always render `temporary` in JSON/JSONL and a `temporary`/`standard` token in
  text/table.

**Verification**:

- Catalog tests for all four formats, default inclusion, exclusion of valid and
  invalid temporary entries, `.registry-state` exclusion, query fields and
  case behavior, exclusion-before-query, duplicate-name provenance, and the
  overwrite no-omission race.
- `swift test --filter WorkflowCommandCatalogTests`

### T6. Fifth-position resolution and command propagation

**Status**: COMPLETED  
**Write scope**: `Sources/RielaCLI/WorkflowResolution.swift`,
`Sources/RielaCLI/WorkflowRunCommand.swift`,
`Sources/RielaCLI/WorkflowValidateInspectCommands.swift`, and status/usage
surfaces that consume shared resolution; focused changes in
`Tests/RielaCLITests/WorkflowCommandScopedResolutionTests.swift`  
**Depends on**: T2, T3

**Deliverables**:

- Preserve direct definition-directory short-circuiting and append the user
  temporary candidate after project workflow, user workflow, project package,
  and user package.
- Include the candidate for `auto` and `user`, never for `project`.
- Before checking a temporary destination, acquire `catalog.lock`, then the
  keyed workflow lock, run keyed recovery, and keep the keyed lock through
  existence checking and bundle loading.
- Require the decoded `workflowId` of a published temporary bundle to equal its
  registry directory key before returning a resolved bundle; mismatches fail
  closed before any mutation path can derive or acquire another keyed lock.
- Preserve current missing-candidate, automatic-scope fallback, explicit-scope
  fail-fast, and package-error behavior.
- Propagate explicit temporary provenance through run, validate, inspect/usage,
  and status without inferring it from the destination path.

**Verification**:

- Resolution tests for exact precedence, scope eligibility, missing and invalid
  fallback semantics, symlink containment, run-by-name, validate provenance,
  and second-process persistence.
- `swift test --filter WorkflowCommandScopedResolutionTests`

### T7. Existing mutation-path lock coordination

**Status**: COMPLETED  
**Write scope**: `Sources/RielaCLI/WorkflowVersionCommands.swift`,
`Sources/RielaCLI/WorkflowSelfImproveVersioning.swift`, temporary-aware
coordination hooks in `Sources/RielaCLI/WorkflowTemporaryRegistry.swift` or
`Sources/RielaCLI/WorkflowDirectoryTransaction.swift`, and focused tests in
`Tests/RielaCLITests/WorkflowVersionCommandsTests.swift`,
`Tests/RielaCLITests/WorkflowSelfImproveVersioningTests.swift`, and
`Tests/RielaCLITests/WorkflowDirectoryTransactionTests.swift` or the existing
boundary-test companion  
**Depends on**: T2, T3, T6

**Deliverables**:

- Audit every authored-workflow path that writes a resolved live bundle,
  starting with version restore through
  `WorkflowDirectoryTransactionCoordinator.commit` and self-improvement apply
  through `WorkflowSelfImproveVersioning`; record any additional writer found
  by T1 in the progress log and bring it into this task.
- For `ResolvedWorkflowBundle.temporary == true`, acquire the registry-wide
  catalog lock and then the keyed workflow lock before invoking the existing
  mutation transaction; retain the locks through publication and visible-state
  verification.
- Ensure the existing transaction coordinator cannot acquire a conflicting
  lock in reverse order or release the registry locks before its live-directory
  rename and recovery state are durable.
- Preserve current behavior for standard authored workflows and keep installed
  package workflows immutable; temporary provenance changes coordination, not
  mutation eligibility or history semantics.
- Route temporary mutation recovery through the same keyed registry recovery
  boundary so registration, restore, and self-improvement cannot race or
  misclassify each other's visible state.
- Model both detached `liveMoved` layouts: first rename retains staging and
  follows ordinary rollback, while second rename before phase persistence has
  published detached live state and rolls back when the registry digest remains
  authoritative at the before value. Recovery retains the validated detached
  container descriptor throughout those decisions and mutations. Detached
  commit retains the same descriptor from initial validation through preflight,
  staging mutation, publication, verification, and cleanup.
- Add deterministic tests for registration-versus-restore and
  registration-versus-self-improvement races, lock release after failure,
  deadlock-free ordering, and unchanged standard-workflow behavior.

**Verification**:

- `swift test --filter WorkflowVersionCommandsTests`
- `swift test --filter WorkflowSelfImproveVersioningTests`
- `swift test --filter WorkflowDirectoryTransactionTests`

### T8. Registration transaction and recovery matrix

**Status**: COMPLETED  
**Write scope**: `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests.swift`,
focused same-suite companion files, and test-only fixtures/helpers under
existing test conventions  
**Depends on**: T2, T4

**Deliverables**:

- Cover file versus bundle input, unsafe identifiers, input and registry
  symlinks, special files, malformed JSON, missing workflow JSON, missing and
  escaping assets, duplicate rejection, overwrite success, and structured
  results/errors.
- Inject ordinary failure and process-style interruption after every durable
  transaction boundary; assert ordinary in-call recovery and durable recovery
  by a separate later catalog invocation, overwrite visibility, cleanup,
  digest verification, and forensic preservation for ambiguous state.
- Cover the detached first-rename and second-rename-before-phase-persist windows,
  plus forged external `physicalOwnershipRoot` rejection with external content
  preservation and post-validation ownership-container replacement during both
  commit and recovery with original evidence and replacement content preserved.
- Exercise lock order and deterministic concurrency: record creation/removal,
  benign disappearance, reader blocking, and listing during overwrite without
  omission.

**Verification**:

- `swift test --filter WorkflowTemporaryRegistrationTests`

### T9. Catalog and resolution regression matrix

**Status**: COMPLETED  
**Write scope**:
`Tests/RielaCLITests/WorkflowCommandCatalogTests.swift`,
`Tests/RielaCLITests/WorkflowCommandScopedResolutionTests.swift`, and focused
same-suite companion files required to remain below the 1000-line limit  
**Depends on**: T5, T6

**Deliverables**:

- Complete the accepted catalog marker/query/exclusion/direct-provenance matrix.
- Complete the exact five-candidate precedence, scope, fail-fast/fallback,
  validate, run-by-name, and persistence matrix.
- Preserve all existing authored-workflow and installed-package behavior.

**Verification**:

- `swift test --filter WorkflowCommandCatalogTests`
- `swift test --filter WorkflowCommandScopedResolutionTests`

### T10. Documentation, smoke verification, and handoff

**Status**: COMPLETED  
**Write scope**: directly affected sections of `README.md`,
`examples/temporary-workflow/README.md`,
`examples/temporary-workflow/EXPECTED_RESULTS.md`, this plan's progress log,
and the accepted design only for factual consistency corrections  
**Depends on**: T4, T5, T6, T7, T8, T9

**Deliverables**:

- Refresh user-facing CLI examples for registration, overwrite, list markers,
  exclusion, validation, query, and run-by-name; review
  `.codex/skills/riela-impl-workflow/SKILL.md` and change it only if its generic
  workflow contract is factually affected.
- Run the isolated-home, separate-process smoke under
  `tmp/temporary-workflow-registry-smoke/`; keep all scratch inputs, outputs,
  and logs under `tmp/` and remove them after evidence is recorded.
- Record exact command outcomes, test counts where available, unrelated flakes,
  and any verification gaps in the progress log.
- Confirm the diff contains only the accepted work package and no scratch
  artifacts; leave commit/push behavior to its owning workflow step and never
  target `main`.

**Verification**:

- `git diff --check`
- `swift build`
- `swift test --filter WorkflowTemporaryRegistrationTests`
- `swift test --filter WorkflowCommandCatalogTests`
- `swift test --filter WorkflowCommandScopedResolutionTests`
- `swift test --filter WorkflowVersionCommandsTests`
- `swift test --filter WorkflowSelfImproveVersioningTests`
- `swift test --filter WorkflowDirectoryTransactionTests`
- Isolated-home commands listed in the accepted design: register; list in
  jsonl/json/text/table; exclude; validate; mock-scenario run; query; invalid
  registration; workflow help; register help.
- `git status --short --branch`

## Dependencies

| Dependency | Required by | State |
| --- | --- | --- |
| Accepted design review `comm-000025` | Entire plan | Available |
| Existing typed workflow parser and dispatcher | T4 | Available |
| `CLIRuntimeEnvironment` user-home isolation | T2, T4-T6 | Available |
| Existing bundle loader and `DefaultWorkflowValidator` | T4 | Available |
| Existing catalog origin/result models and renderers | T3, T5 | Available |
| Existing four-candidate resolver | T3, T6 | Available |
| Existing version restore, self-improvement apply, and directory transaction writers | T7 | Available; audit in T1 |
| Secure filesystem/transaction helpers | T2 | Audit and adapt in T1 |
| Registry and provenance foundations | T4-T9 | Completed by T2-T3 |
| Implementation-complete CLI and mutation coordination | T10 smoke/docs | Completed by T4-T9 |

## Parallelizable tasks

- T2 and T3 may run in parallel after T1 because their primary write scopes are
  disjoint; coordinate any shared type needed by both before editing it.
- T4, T5, and T6 may run in parallel only after T2 and T3 stabilize their
  contracts. Their declared production write scopes are disjoint.
- T7 begins after T6 establishes temporary-aware resolution. T7 and T8 may then
  proceed in parallel because mutation command/tests and registration tests have
  disjoint write scopes.
- T8 may proceed with T5/T6 after T4 is usable because it writes the dedicated
  registration test file; T9 must wait for T5 and T6.
- Within T9, catalog and scoped-resolution test edits are parallelizable because
  they are separate files.
- T10 is serial and begins only after implementation and focused tests converge.

## Completion criteria

- [x] One feature and one work package are implemented on
      `feat/temporary-workflow-registry`; no unrelated files are changed.
- [x] Registration accepts regular JSON files and contained bundle directories,
      performs full validation before publication, persists across CLI
      invocations, and never mutates the catalog on invalid input.
- [x] Published temporary bundles must decode the same `workflowId` as their
      registry directory key; mismatches remain visible as invalid catalog
      entries and fail resolution before any alternate keyed lock is acquired.
- [x] All registry-owned recovery and publication paths enforce
      catalog-lock-before-workflow-lock ordering, canonical transaction IDs,
      normalized subtree paths, and component-wise non-symlink containment.
      Bundle bytes and digest inventory are captured through retained directory
      descriptors. Temporary mutation runs in a detached descriptor-captured
      workspace and publishes through descriptor-relative registry staging and
      rename operations, without converting the descriptor back to the
      configured registry pathname. Detached ownership is restricted to a
      canonical UUID snapshot namespace and its container device/inode is bound
      into stable durable metadata before any commit or recovery mutation.
      Commit and recovery keep the validated container descriptor through
      inventory, staging, marker cleanup, removal, rename, and fsync, and fail
      closed if its configured identity is replaced after validation.
- [x] Version restore, self-improvement apply, and every other existing
      authored-workflow writer identified by T1 use the same lock order for
      temporary bundles; resolver-triggered history recovery stays inside that
      boundary, with deterministic mutation-versus-registration race coverage
      and unchanged standard-workflow behavior. A retained registry digest
      rejects a mutation if registration replaced the resolved bundle before
      the mutation acquired its locks. Detached transaction recovery consults
      the authoritative registry digest and records failure when registry
      publication did not reach its durable commit point. Recovery distinguishes
      the first-rename `liveMoved` state from the second-rename/pre-phase-persist
      state and deterministically restores the prior detached tree in both.
- [x] Overwrite publication and every recovery phase are ordinary-failure and
      process-interruption tested, including durable recovery by a separate
      later invocation; catalog readers return the prior or replacement entry
      without an overwrite omission window. Once a verified replacement reaches
      the durable commit point, successful recovery returns success instead of
      reporting a false failed registration.
- [x] `temporary: Bool` is additive, decodes absent values as `false`, and is
      explicit across catalog, resolution, validate, inspect/usage, and status.
- [x] A colocated `riela-package.json` remains ordinary content in a registered
      temporary bundle and cannot change its authored-workflow provenance,
      mutability, history identity, restore eligibility, or self-improvement
      eligibility.
- [x] Default list output includes temporary entries in all four formats;
      `--exclude-temporary` and the positional query follow the accepted filter
      and match rules.
- [x] Resolution order is unchanged for the first four candidates and appends
      the temporary candidate as position five; scope and fallback semantics are
      regression-tested.
- [x] Run-by-name, validate-by-name, and separate-process persistence succeed.
- [x] Workflow and register help document the command and accepted flags.
- [x] `swift build`, all three acceptance-focused suites, and the mutation-path
      focused suites pass; isolated-home smoke assertions pass or every gap is
      explicitly recorded with evidence.
- [x] User-facing docs match shipped behavior; no scratch artifacts exist
      outside `tmp/`, and the final diff passes `git diff --check`.

## Risks and controls

| Risk | Control |
| --- | --- |
| Lock inversion or overwrite omission | Centralize acquisition order across registration, readers, restore, and self-improvement; deterministic reader/writer and mutation/writer race tests |
| Symlink/path traversal into or out of registry | Component-wise `lstat`, canonical containment, safe identifier checks, adversarial fixtures |
| Partial or malformed recovery state | Durable versioned records, bundle digest proof, fail-closed preservation |
| Public Codable breakage | Decode-default compatibility tests and always-encoded additive field |
| Temporary candidate shadows existing sources | Fixed candidate-five construction and precedence regression matrix |
| Catalog provenance resolved from wrong duplicate | Direct descriptor loading with explicit origin metadata |
| Invalid input mutates visible catalog | Validate staged copy before lock-coordinated publication and assert no mutation |
| Timing-dependent concurrency tests | Test-only boundary hooks and synchronization, never sleep-based assertions |
| Unrelated local test flake | Record exact evidence; ignore `DaemonWorkflowNodePatchTests` restart flake only when unconnected |

## Progress log expectations

Update this section after every completed or materially blocked task. Each entry
must include date, task ID, status, changed files, exact verification commands
and results, findings or deviations, and the next dependency. Do not mark a task
complete with planned-only verification. Put verbose logs under
`tmp/temporary-workflow-registry/`, summarize durable evidence here, and move
this plan to `impl-plans/completed/` only after every completion criterion is
resolved.

| Date | Task | Status | Files / evidence | Verification | Next |
| --- | --- | --- | --- | --- | --- |
| 2026-07-22 | Plan creation | READY | `design-docs/specs/design-temporary-workflow-registry.md`; Step 3 `comm-000025` | `git diff --check` passed after plan creation; implementation commands planned | T1 |
| 2026-07-22 | Plan self-review revision | READY | Step 4 `comm-000027`; T7 mutation coordination and T8-T10 renumbering | `git diff --check -- design-docs/specs/design-temporary-workflow-registry.md impl-plans/active/temporary-workflow-registry.md` passed | T1 |
| 2026-07-22 | T1-T7 implementation | COMPLETED | `Sources/RielaCLI/CodableDefaults.swift`; `WorkflowTemporaryRegistry.swift`; `WorkflowTemporaryRegistrationCommand.swift`; parser, app, catalog, resolver, validate/inspect, version restore, and self-improve integration files | Xcode-toolchain `swift build` passed; additive decode compatibility covered | T8-T9 |
| 2026-07-22 | T8-T9 focused tests | COMPLETED | `WorkflowTemporaryRegistrationTests.swift`; `WorkflowCommandCatalogTests.swift`; `WorkflowCommandScopedResolutionTests.swift` | registration 10/0; catalog 1/0; scoped resolution 1/0; version 4/0; self-improve 6/0; directory transaction 28/0 | T10 |
| 2026-07-22 | T10 docs and smoke | COMPLETED | `README.md`; `examples/temporary-workflow/README.md`; `examples/temporary-workflow/EXPECTED_RESULTS.md`; isolated `tmp/temporary-workflow-registry-smoke/` | separate-process register/list four formats/exclude/validate/run/query/invalid/help passed; SwiftLint passed with unrelated pre-existing warnings only; `git diff --check` passed | Independent implementation review |
| 2026-07-22 | Step 6 self-review correction (`comm-000032`), T2/T6-T9 reopened | REVISION REQUIRED | High findings in `WorkflowTemporaryRegistry.swift`; mid finding in `WorkflowResolution.swift` | Missing canonical transaction-path checks, linked-artifact rejection, and resolver-history-recovery lock retention reproduced by source review | T2/T6-T9 correction |
| 2026-07-22 | T2/T6-T9 adversarial recovery and lock correction | COMPLETED | `Sources/RielaCLI/WorkflowTemporaryRegistry.swift`; `Sources/RielaCLI/WorkflowResolution.swift`; `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests.swift` | Xcode-toolchain `swift build` passed; registration 13/0; catalog 1/0; scoped resolution 1/0; version 4/0; self-improve 6/0; directory transaction 28/0; SwiftLint passed with unrelated pre-existing warnings only; `git diff --check` passed | Step 6 self-review rerun |
| 2026-07-22 | Step 6 self-review correction (`comm-000034`), T2/T6-T8 reopened | REVISION REQUIRED | Mid findings in `WorkflowCatalogCommands.swift` and `WorkflowTemporaryRegistrationTests.swift` | Missing registry-key identity enforcement and genuine next-invocation recovery coverage reproduced by source review | T2/T6-T8 correction |
| 2026-07-22 | T2/T6-T8 identity and interruption correction | COMPLETED | `Sources/RielaCLI/WorkflowTemporaryRegistry.swift`; `Sources/RielaCLI/WorkflowResolution.swift`; `Sources/RielaCLI/WorkflowCatalogCommands.swift`; `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests.swift` | Xcode-toolchain `swift build` passed; registration 15/0 with mismatch and separate-invocation phase recovery regressions; catalog 1/0; scoped resolution 1/0; version 4/0; self-improve 6/0; directory transaction 28/0; isolated-HOME smoke passed; SwiftLint reported unrelated pre-existing warnings only; `git diff --check` passed | Step 6 self-review rerun |
| 2026-07-22 | Step 6 self-review correction (`comm-000036`), T8-T9 reopened | REVISION REQUIRED | Mid findings in the registration, catalog, and scoped-resolution test matrix | Missing special/missing-input, record/catalog concurrency, direct-provenance/query, separate-process, exact precedence, and fallback/fail-fast coverage reproduced by source and test-count review | T8-T9 correction |
| 2026-07-22 | T8-T9 accepted matrix completion | COMPLETED | `Sources/RielaCLI/WorkflowTemporaryRegistry.swift`; `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift`; `Tests/RielaCLITests/WorkflowCommandCatalogTests+Temporary.swift`; `Tests/RielaCLITests/WorkflowCommandScopedResolutionTests+Temporary.swift` | Xcode-toolchain build passed; registration 19/0, catalog 3/0, scoped resolution 3/0, and combined mutation suites 38/0 passed; deterministic record disappearance, reader/catalog blocking, overwrite visibility, direct provenance, separate-process listing, all five candidates, automatic fallback, and explicit fail-fast are covered; SwiftLint reports only seven pre-existing unrelated warnings; `git diff --check` passed | Step 6 self-review rerun |
| 2026-07-22 | Step 6 test-integrity correction (`comm-000039`), T8-T9 reopened | REVISION REQUIRED | `WorkflowTemporaryRegistrationTests.swift`; `WorkflowTemporaryRegistrationTests+Matrix.swift`; lock-owning command seams | Marker assertions were contaminated by the workflow id, five lock tests used command-start 50 ms checks, and registration renderers lacked all-format coverage | T8-T9 correction |
| 2026-07-22 | T8-T9 test-integrity correction | COMPLETED | `WorkflowTemporaryRegistry.swift`; catalog/resolver/version/self-improve registry injection seams; registration and matrix tests | Xcode-toolchain `swift build` passed; rebuilt combined acceptance suites passed 26/0 (registration 20/0, catalog 3/0, scoped resolution 3/0); mutation suites passed 38/0; SwiftLint reported only seven pre-existing unrelated warnings; changed files remain below 1000 lines | Step 6 self-review rerun |
| 2026-07-22 | Step 7 implementation review correction (`comm-000043`), T3/T6-T7 reopened | REVISION REQUIRED | `Sources/RielaCLI/WorkflowResolution.swift:431`; package-manifest provenance reproduction | A colocated `riela-package.json` made registration/list report authored mutable provenance while validate/status and mutation identity reported an immutable package | T3/T6-T7 correction |
| 2026-07-22 | T3/T6-T7 temporary authored-provenance correction | COMPLETED | `Sources/RielaCLI/WorkflowResolution.swift`; `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift` | Xcode-toolchain `swift build` passed; registration suite 21/0, catalog/scoped-resolution suites 6/0, and mutation suites 38/0 passed; regression covers register/list/validate/inspect/status/restore/self-improve; SwiftLint reached only the same seven unrelated warnings before the command timeout; `git diff --check` passed | Step 7 implementation re-review |
| 2026-07-22 | Step 7 implementation review correction (`comm-000047`), T2/T5-T6/T8/T10 reopened | REVISION REQUIRED | `Sources/RielaCLI/WorkflowTemporaryRegistry.swift:166,189`; read-only-home reproduction | Catalog access created the absent registry and failed under a read-only `~/.riela`; failed in-call recovery was suppressed before unconditional staging cleanup | T2/T5-T6/T8/T10 correction |
| 2026-07-22 | T2/T5-T6/T8/T10 read-only and recovery-preservation correction | COMPLETED | `Sources/RielaCLI/WorkflowTemporaryRegistry.swift`; `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests.swift`; `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift` | Xcode-toolchain build and test build passed; acceptance suites passed 29/0 including absent read-only registry and malformed-record recovery-preservation regressions; mutation suites passed 38/0; changed-file SwiftLint produced no findings; `git diff --check` passed | Step 7 implementation re-review |
| 2026-07-22 | Step 7 implementation review correction (`comm-000051`), T2/T5-T6/T8-T10 reopened | REVISION REQUIRED | `Sources/RielaCLI/WorkflowTemporaryRegistry.swift:263,302`; missing-state and ancestor-link-swap source review | Path-based registry mutations could follow a swapped linked ancestor; a present registry with missing `.registry-state` was treated as absent; empty positional query lacked a direct regression | T2/T5-T6/T8-T10 correction |
| 2026-07-22 | T2/T5-T6/T8-T10 descriptor-pinning and fail-closed correction | COMPLETED | `Sources/RielaCLI/WorkflowTemporaryRegistryPinnedRoot.swift`; `Sources/RielaCLI/WorkflowTemporaryRegistry.swift`; `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift`; `Tests/RielaCLITests/WorkflowCommandCatalogTests.swift` | Xcode-toolchain `swift build` passed; acceptance suites passed 32/0; mutation suites passed 38/0; deterministic ancestor-symlink swap preserves external staging and fails publication; missing internal state fails catalog and resolution closed; empty positional query returns usage | Step 7 implementation re-review |
| 2026-07-22 | Step 7 adversarial correction (`comm-000056`), T2/T5/T7-T10 reopened | REVISION REQUIRED | `WorkflowTemporaryRegistry.swift:165,445`; `WorkflowVersionCommands.swift:84`; missing relative/query/smoke evidence | Stale mutation could overwrite a concurrent registration, pinned-root objects did not span whole operations, and post-commit recovery could report failure after committing | T2/T5/T7-T10 correction |
| 2026-07-22 | T2/T5/T7-T10 adversarial correction | COMPLETED | `WorkflowTemporaryRegistry.swift`; `WorkflowTemporaryRegistryPinnedRoot.swift`; `WorkflowResolution.swift`; `WorkflowVersionCommands.swift`; `WorkflowSelfImproveVersioning.swift`; focused registration/catalog tests | Xcode-toolchain `swift build` passed; acceptance suites passed 35/0 and final registration rebuild passed 27/0; mutation suites passed 38/0; whole-root swap fails closed; stale restore/self-improvement reject replacement drift; post-commit recovery reports success; relative `--working-dir` and direct `packageName` query regressions pass; isolated-home separate-process register/list-four-formats/exclude/validate/run/query/invalid/help smoke passed and scratch was removed; targeted SwiftLint and `git diff --check` passed | Step 7 implementation re-review |
| 2026-07-23 | Step 6 self-review correction (`comm-000058`), T2/T5-T8 reopened | REVISION REQUIRED | `Sources/RielaCLI/WorkflowTemporaryRegistry.swift:451`; descriptor/lexical split source review | Bundle loading, digest inventory, and mutation bodies could dereference the configured lexical root after its lock-time identity check | T2/T5-T8 correction |
| 2026-07-23 | T2/T5-T8 descriptor-relative access correction | COMPLETED | `Sources/RielaCLI/WorkflowTemporaryRegistryPinnedRoot.swift`; `Sources/RielaCLI/WorkflowTemporaryRegistry.swift`; `Sources/RielaCLI/WorkflowCatalogCommands.swift`; `Sources/RielaCLI/WorkflowResolution.swift`; `Sources/RielaCLI/WorkflowVersionCommands.swift`; `Sources/RielaCLI/WorkflowSelfImproveVersioning.swift`; `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift` | Xcode-toolchain `swift build` completed successfully; acceptance suites passed 36/0 including a deterministic root swap during `beforeRecordRead` with record/staging preservation; mutation suites passed 38/0; descriptor-relative digest inventory and descriptor-held stable paths now cover registration, catalog, resolution, restore, and self-improvement; split targeted SwiftLint passed without findings; the complete isolated-HOME smoke passed and scratch was removed; `git diff --check` passed | Step 6 self-review rerun |
| 2026-07-23 | Step 6 self-review correction (`comm-000060`), T2/T5-T8 reopened | REVISION REQUIRED | `Sources/RielaCLI/WorkflowTemporaryRegistryPinnedRoot.swift:99`; URL bridge source review | `withStableDirectoryURL` converted a retained descriptor back to the configured pathname, leaving resolution and mutation redirectable after its identity check | T2/T5-T8 correction |
| 2026-07-23 | T2/T5-T8 post-capture root-swap correction | COMPLETED | `Sources/RielaCLI/WorkflowTemporaryRegistryDetached.swift`; `WorkflowTemporaryRegistryPinnedRoot.swift`; `WorkflowTemporaryRegistry.swift`; `WorkflowResolution.swift`; `WorkflowCatalogCommands.swift`; `WorkflowDirectoryTransaction.swift`; `WorkflowDirectoryTransactionDurability.swift`; `WorkflowVersionCommands.swift`; `WorkflowSelfImproveVersioning.swift`; `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift` | Xcode-toolchain `swift build` passed; final rebuilt direct XCTest acceptance and mutation selection passed 77/0; deterministic swaps after descriptor capture leave replacement trees unchanged for resolution, restore, and self-improvement; detached recovery compares the authoritative registry digest before finalizing audits; isolated-HOME register/list-four-formats/exclude/validate/run/query/invalid/help smoke passed; targeted SwiftLint emitted no findings; `git diff --check` passed; corrected Swift files remain below 1000 lines | Step 6 self-review rerun |
| 2026-07-23 | Step 6 self-review correction (`comm-000062`), T2/T7/T8 reopened | REVISION REQUIRED | `WorkflowDirectoryTransactionDurability.swift:303`; `WorkflowDirectoryTransaction.swift:650`; missing detached recovery matrix | A forged absolute physical root could target external state, and valid first-rename `liveMoved` recovery was intercepted by the post-publication rollback helper | T2/T7/T8 correction |
| 2026-07-23 | T2/T7/T8 detached containment and recovery correction | COMPLETED | `Sources/RielaCLI/WorkflowDirectoryTransactionDurability.swift`; `Sources/RielaCLI/WorkflowDirectoryTransaction.swift`; `Sources/RielaCLI/WorkflowHistoryIdentity.swift`; `Sources/RielaCLI/WorkflowTemporaryRegistryDetached.swift`; `Tests/RielaCLITests/WorkflowDirectoryTransactionTests+DetachedRecovery.swift` | Xcode-toolchain build and test build completed successfully; rebuilt direct acceptance/mutation selection passed 79/0, including forged-root preservation and both detached rename windows; targeted SwiftLint and `git diff --check` passed; corrected Swift files remain below 1000 lines; detached roots are UUID-scoped, component-validated, and device/inode-bound; root-override nested artifact resolution is ownership-relative | Step 6 self-review rerun |
| 2026-07-23 | Step 6 self-review correction (`comm-000064`), T2/T7/T8 reopened | REVISION REQUIRED | `Sources/RielaCLI/WorkflowDirectoryTransaction.swift:473`; post-validation ownership-container swap review | Stable metadata validation closed the detached container descriptor before lexical recovery checks and mutation | T2/T7/T8 correction |
| 2026-07-23 | T2/T7/T8 descriptor-pinned detached recovery correction | COMPLETED | `Sources/RielaCLI/WorkflowDetachedOwnershipPinnedRoot.swift`; `Sources/RielaCLI/WorkflowDirectoryRecoveryFileSystem.swift`; `Sources/RielaCLI/WorkflowDirectoryTransactionFileSystem.swift`; `Sources/RielaCLI/WorkflowDirectoryTransactionRecoveryPreparation.swift`; `Sources/RielaCLI/WorkflowDirectoryTransaction.swift`; `Sources/RielaCLI/WorkflowDirectoryTransactionDurability.swift`; `Tests/RielaCLITests/WorkflowDirectoryTransactionTests+DetachedRecovery.swift` | Xcode-toolchain build and test build completed before wrapper timeout; rebuilt direct acceptance/mutation selection passed 80/0, including post-validation container replacement with original/replacement preservation; targeted SwiftLint emitted no findings; `git diff --check` passed; corrected Swift files remain below 1000 lines; scratch was removed | Step 6 self-review rerun |
| 2026-07-23 | Step 6 self-review correction (`comm-000066`), T2/T7/T8 reopened | REVISION REQUIRED | `Sources/RielaCLI/WorkflowDirectoryTransaction.swift:252`; detached commit descriptor-lifetime review | Detached commit closed its validated container descriptor before lexical preflight, staging, rename, cleanup, and fsync operations | T2/T7/T8 correction |
| 2026-07-23 | T2/T7/T8 descriptor-pinned detached commit correction | COMPLETED | `Sources/RielaCLI/WorkflowDetachedOwnershipPinnedRoot.swift`; `Sources/RielaCLI/WorkflowDirectoryTransactionFileSystem.swift`; `Sources/RielaCLI/WorkflowDirectoryTransaction.swift`; `Sources/RielaCLI/WorkflowTemporaryRegistryDetached.swift`; `Tests/RielaCLITests/WorkflowDirectoryTransactionTests+DetachedRecovery.swift` | Xcode-toolchain build and test build passed; rebuilt direct acceptance/mutation selection passed 81/0, including deterministic post-validation commit replacement with original/replacement preservation; targeted SwiftLint, `git diff --check`, file-size, and scratch-cleanup checks passed | Step 6 self-review rerun |
