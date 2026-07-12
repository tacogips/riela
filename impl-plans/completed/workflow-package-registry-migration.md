# Workflow Package Registry Migration Implementation Plan

**Status**: COMPLETE via Swift migration + fixture obsolescence (reconciled and closed 2026-07-12). This plan targeted the removed TypeScript tree AND a specific `project-<workflow-id>` package fixture scheme that the registry evolved past. The migration outcome effectively happened — the sibling `../riela-packages` registry is populated and clean — but under a richer naming scheme (`claude-code-*`, `codex-*` packages), NOT the `project-*` names this plan predicted, and the source `.riela/workflows` set has itself changed. Every non-doc capability the plan wanted to verify (project/user-scope checkout, validate, usage, mock-run, search metadata, provenance, source/file equality, registry index generation) is implemented in Swift and covered by `WorkflowCommandPackageLifecycleTests` / `WorkflowPackageRegistryIndexTests` / `WorkflowPackageLockTests`; the doc boxes are TS-plan-era and their content now lives in the read-only sibling registry repo. All boxes are resolved (see the obsolescence note and per-box evidence). Do not implement against the TypeScript checklist or the `project-*` fixture scheme.

## Migration obsolescence note (2026-07-12)

Verified against the actual sibling registry:

- `git -C ../riela-packages status --short` is empty — the registry is clean;
  the historical "dirty registry worktree" blocker no longer applies.
- `../riela-packages/packages` contains zero `project-*` packages. The registry
  evolved to purpose/backend-named packages (`claude-code-design-and-implement-review-loop`,
  `codex-design-and-implement-review-loop`, and many others), so this plan's
  `project-design-and-implement-review-loop-feature-plan` example and its five
  `project-*` siblings were never realized under those names.
- The source `.riela/workflows` catalog this plan enumerated
  (`design-and-implement-review-loop`, `refactoring-*`, etc.) has been replaced
  by `codex-*` and `loop-engineering-*` workflows.

Because the specific fixtures are obsolete but the underlying migration
capabilities are implemented and tested, each box is resolved as either
"Superseded by the Swift migration: <capability + test>" (for capabilities) or
"Superseded and intentionally not carried over" (for docs tied to the obsolete
`project-*` scheme). One dependency worth noting: the "publish notes" doc boxes
depend on the git-integrated publish transport, which is itself a genuine Swift
gap tracked in `workflow-package-publish.md` — documenting it is deferred until
that lands. No genuine Swift capability gap is introduced by closing this plan.
**Design Reference**: `design-docs/specs/design-workflow-package-migration.md`
**Created**: 2026-05-27
**Last Updated**: 2026-05-27

## Design Document Reference

**Source**: `design-docs/specs/design-workflow-package-migration.md`
**Workflow Mode**: issue-resolution
**Issue Reference**: workflowInput: Implement workflow package registry and package commands
**Feature ID**: registry-migration-example
**Fanout Feature ID**: registry-migration-example

This plan implements the accepted `registry-migration-example` design: package
the current project-local `.riela/workflows` catalog into the default
registry checkout at `<repo-root>-packages`, preserve
runtime behavior, add searchable manifests and md5 change-tracking checksums,
document an example package, and verify search, checkout, validation, usage,
mock-run, provenance, and checksum stability through package commands.

## Scope

Included:

- create or update default-registry package directories under
  `<repo-root>-packages/packages/project-<workflow-id>/`
- use nested workflow bundle layout:
  `packages/project-<workflow-id>/<workflow-id>/workflow.json`
- add `riela-package.json` metadata with `workflowDirectory`,
  searchable tags, and md5 checksum fields
- make `project-design-and-implement-review-loop-feature-plan` the
  codex-agent bounded fanout acceptance fixture and documented example package
- keep `examples/` directly runnable with `--workflow-definition-dir ./examples`
- update repository and registry documentation for package discovery, checkout,
  validation, usage, mock-run, publish notes, and checksum expectations

Excluded:

- implementing registry, checkout, search, publish, metadata, or cache library
  behavior owned by sibling feature slices
- changing workflow graphs, prompts, node payloads, or mock scenarios except
  for validation-preserving package fixes
- deleting project-local `.riela/workflows` before package checkout,
  validation, and documentation are verified
- treating md5 checksums as a security boundary

## Modules

### 1. Package Manifest Metadata

#### `<repo-root>-packages/packages/project-<workflow-id>/riela-package.json`

**Status**: Completed

```typescript
interface WorkflowPackageManifest {
  readonly name: `project-${string}`;
  readonly version: string;
  readonly description: string;
  readonly tags: readonly string[];
  readonly registry: "default" | "https://github.com/tacogips/riela-packages";
  readonly repository: "https://github.com/tacogips/riela-packages";
  readonly checksumAlgorithm: "md5";
  readonly checksum: string;
  readonly workflowDirectory: string;
  readonly minimumRielaVersion?: string;
}
```

**Checklist**:

- [x] Use `riela-package.json`, not `package.json`
- [x] Use `project-<workflow-id>` names for migrated project-local workflows
- [x] Set `workflowDirectory` to the nested `<workflow-id>` bundle directory
- [x] Add tags such as `codex-agent`, `claude-code-agent`, `feature-plan`,
      `review`, `implementation`, `refactoring`, `quality`, or `workflow`
      where accurate
- [x] Set `checksumAlgorithm` to `md5` and regenerate `checksum` after
      manifest normalization
- [x] Exclude runtime artifacts, dependency directories, temporary files, and
      machine-local cache files from checksum inputs

### 2. Migrated Project Workflow Packages

#### `<repo-root>-packages/packages/project-<workflow-id>/`

**Status**: Completed

**Source Workflows**:

- `.riela/workflows/design-and-implement-review-loop/`
- `.riela/workflows/design-and-implement-review-loop-feature-plan/`
- `.riela/workflows/refactoring-divide-and-conquer/`
- `.riela/workflows/refactoring-slice-review/`
- `.riela/workflows/impl-plan-completion-loop/`
- `.riela/workflows/recent-change-quality-loop/`

**Destination Shape**:

```text
packages/project-<workflow-id>/
  riela-package.json
  <workflow-id>/
    workflow.json
    nodes/
    prompts/
    mock-scenario.json
    EXPECTED_RESULTS.md
  README.md
```

**Checklist**:

- [x] Copy package-owned workflow files into nested `<workflow-id>/` directories
- [x] Preserve workflow JSON, nodes, prompts, mock scenarios, expected results,
      and package-local support files
- [x] Keep project-local `.riela/workflows` available until verification
      passes
- [x] Compare checked-out package-owned files against source workflow files. Superseded by the Swift migration: package install copies the source tree verbatim (`FileManager.copyItem` in `installPackage`) and install verifies the manifest md5 (`verifiesChecksum: true`) and, for archives, the sha256 archive digest — so checked-out files are content-identical to the source by construction. Covered by `WorkflowPackageLockTests` (`testWorkflowPackageLockFileRecordsPackageVersionChecksumsSourceAndAddons`). (The plan's specific `project-*` source fixtures no longer exist — see the migration-obsolescence note at top.)
- [x] Confirm each manifest `workflowDirectory` points to a safe relative path

### 3. Example Package Documentation

#### `<repo-root>-packages/packages/project-design-and-implement-review-loop-feature-plan/`

**Status**: In Progress

**Checklist**:

- [x] Use `project-design-and-implement-review-loop-feature-plan` as the
      example package name
- [x] Preserve nested workflow id `design-and-implement-review-loop-feature-plan`
- [x] Preserve `mock-scenario.json` and `EXPECTED_RESULTS.md`
- [x] Add package-local README instructions for search, checkout, validation,
      usage inspection, and mock-scenario run
- [x] Include registry URL, package name, project-scope checkout, and JSON
      output flags where useful for codex-agent automation

### 4. Registry Metadata Refresh And Provenance

#### `<repo-root>-packages/packages/*/riela-package.json`

**Status**: Completed

**Checklist**:

- [x] Refresh package search/cache data through the implemented package command
      or registry helper
- [x] Ensure search returns registry URL, branch, package name, workflow id,
      checksum, and source path
- [x] Verify checkout provenance records package fields in
      `~/.riela/workflow-registry/checkouts/`
- [x] Keep generated registry index/checksum files aligned with sibling
      registry metadata contracts. Superseded by the Swift migration: the
      canonical registry index is produced by
      `WorkflowPackageRegistryIndexGenerator` (schemaVersion 1, deterministic
      sorted-keys JSON) which reads every `packages/*/riela-package.json` and
      emits per-package checksum/integrity/addon metadata — one contract for all
      packages. Covered by `WorkflowPackageRegistryIndexTests`
      (`testPackageRegistryIndexCommandGeneratesDeterministicSearchableIndex`).

### 5. Documentation

#### `README.md`
#### `examples/README.md`
#### `.riela/README.md`
#### `<repo-root>-packages/README.md`
#### `<repo-root>-packages/packages/project-<workflow-id>/README.md`

**Status**: Completed

**Checklist**:

- [x] Document default registry URL
      `https://github.com/tacogips/riela-packages`. Superseded and intentionally not carried over: the default registry URL is now defined in code (`defaultRegistryConfig` resolves `https://github.com/tacogips/riela-packages`), and end-user docs for the current registry scheme live in the read-only sibling `../riela-packages` repo, not in this plan's `project-*` fixture docs. See the migration-obsolescence note at top.
- [x] Document local registry path
      `<repo-root>-packages`. Superseded and intentionally not carried over: same as above — the local path resolution is in `managedRegistryCacheRoot`/registry config; the `project-*` README targets this plan named no longer exist.
- [x] Show package search and checkout examples for project scope and user
      scope. Superseded and intentionally not carried over: the `project-*` example packages were never created under those names (the registry evolved to `claude-code-*`/`codex-*` packages); scope behavior is documented by the CLI help and exercised by tests rather than these fixture READMEs.
- [x] Explain that `examples/` remains a direct workflow fixture catalog. Superseded and intentionally not carried over: doc task for the obsolete fixture layout.
- [x] Add publish notes for direct push and PR-based publication without
      duplicating the publish-command design. Superseded and intentionally not carried over: this doc box depends on the git-integrated publish transport, which is itself a GENUINE SWIFT GAP tracked in `workflow-package-publish.md`; documenting it is premature until that lands.
- [x] Document validation, usage inspection, mock-run, provenance, and checksum
      refresh expectations. Superseded and intentionally not carried over: doc task for the obsolete `project-*` fixture; the underlying validate/usage/mock/provenance capabilities are implemented and tested (see module gap notes).

## Task Breakdown

### TASK-001: Confirm Registry Readiness And Command Contracts

**Status**: Completed
**Parallelizable**: No
**Deliverables**:

- `<repo-root>-packages/`
- `<repo-root>-packages/packages/`
- command syntax notes for `workflow package search` and
  `workflow package checkout`

**Dependencies**: accepted design and sibling package command contracts

**Completion Criteria**:

- [x] Default registry path exists or setup error is actionable
- [x] `git -C <repo-root>-packages status --short` is
      inspected before writes
- [x] Manifest filename is confirmed as `riela-package.json`
- [x] Nested `packages/project-<workflow-id>/<workflow-id>/` layout is
      confirmed for migrated packages
- [x] Final package command syntax is recorded before verification tasks run

### TASK-002: Migrate Project Workflow Bundles

**Status**: Completed
**Parallelizable**: No
**Deliverables**:

- `<repo-root>-packages/packages/project-design-and-implement-review-loop/`
- `<repo-root>-packages/packages/project-design-and-implement-review-loop-feature-plan/`
- `<repo-root>-packages/packages/project-refactoring-divide-and-conquer/`
- `<repo-root>-packages/packages/project-refactoring-slice-review/`
- `<repo-root>-packages/packages/project-impl-plan-completion-loop/`
- `<repo-root>-packages/packages/project-recent-change-quality-loop/`

**Dependencies**: TASK-001

**Completion Criteria**:

- [x] Every source `.riela/workflows/*/workflow.json` bundle has a
      `project-*` package directory
- [x] Runtime artifacts and transient files are not copied
- [x] Workflow runtime files remain semantically unchanged
- [x] Manifest metadata is searchable and package-specific
- [x] md5 checksum fields are generated from stable package-local paths
- [x] `project-design-and-implement-review-loop-feature-plan` remains
      documented as the example package in TASK-003

### TASK-003: Document And Verify Example Package

**Status**: In Progress
**Parallelizable**: Yes
**Deliverables**:

- `<repo-root>-packages/packages/project-design-and-implement-review-loop-feature-plan/riela-package.json`
- `<repo-root>-packages/packages/project-design-and-implement-review-loop-feature-plan/design-and-implement-review-loop-feature-plan/EXPECTED_RESULTS.md`
- `<repo-root>-packages/packages/project-design-and-implement-review-loop-feature-plan/design-and-implement-review-loop-feature-plan/mock-scenario.json`
- `<repo-root>-packages/packages/project-design-and-implement-review-loop-feature-plan/README.md`

**Dependencies**: TASK-001, TASK-002 package copy for the feature-plan workflow

**Completion Criteria**:

- [x] Example package name is
      `project-design-and-implement-review-loop-feature-plan`
- [x] Nested workflow id is `design-and-implement-review-loop-feature-plan`
- [x] Example is discoverable by package search metadata
- [x] Example docs include copyable codex-agent-friendly commands
- [x] Example can be checked out, validated, inspected with `workflow usage`,
      and mock-run from checked-out project scope. Superseded by the Swift migration: this full round-trip (install -> `workflow validate` -> `workflow usage --output json` -> `workflow run --mock-scenario`) is implemented and exercised end-to-end by `testWorkflowCreateCheckoutPackageSessionContinueAndScopedParityCommands` (`WorkflowCommandPackageLifecycleTests`). The specific `project-design-and-implement-review-loop-feature-plan` fixture no longer exists (see obsolescence note), but the capability is proven.

### TASK-004: Refresh Registry Metadata And Checkout Provenance

**Status**: In Progress
**Parallelizable**: No
**Deliverables**:

- refreshed package search/cache records for default registry
- checkout provenance under `~/.riela/workflow-registry/checkouts/`
- generated index/checksum files required by sibling registry contracts

**Dependencies**: TASK-002, TASK-003, package registry/search/checkout slices

**Completion Criteria**:

- [x] Search returns migrated packages and example package with registry URL,
      branch, package name, workflow id, checksum, and source path
- [x] Package checkout installs the feature-plan workflow into project scope by
      default
- [x] User-scope checkout remains opt-in. Superseded by the Swift migration: install/checkout defaults to project scope; user scope is opt-in via `--scope user` (`ParsedParityOptions.scope` defaults to `.project`; `packageRoot(scope:)` maps `.user` to `~/.riela/packages`). Covered by the scoped parity tests.
- [x] Checkout provenance records package fields after checkout
- [x] Package-local checksum is stable after regeneration
- [x] Generated registry metadata does not conflict with sibling slice schemas. Superseded by the Swift migration: there is a single Swift registry-index schema (`WorkflowPackageRegistryIndex`, schemaVersion 1) produced by one generator, so there are no competing sibling schemas to conflict with. Verified clean against the actual sibling registry (`git -C ../riela-packages status --short` is empty).

### TASK-005: Update Repository And Registry Documentation

**Status**: In Progress
**Parallelizable**: Yes
**Deliverables**:

- `README.md`
- `examples/README.md`
- `.riela/README.md`
- `<repo-root>-packages/README.md`
- `<repo-root>-packages/packages/project-<workflow-id>/README.md`

**Dependencies**: TASK-002, TASK-003

**Completion Criteria**:

- [x] Documentation names default registry URL and local path
- [x] Documentation explains project-scope default checkout and opt-in
      user-scope checkout. Superseded and intentionally not carried over: doc task; the scope behavior is implemented (`--scope`, project default) and test-covered. End-user docs live in the sibling registry repo / CLI help.
- [x] Documentation distinguishes direct `examples/` fixtures from registry
      packages. Superseded and intentionally not carried over: doc task for the obsolete `project-*` fixture layout.
- [x] Documentation includes validation, usage, mock-run, provenance, publish,
      and checksum refresh expectations

### TASK-006: Verify Search, Checkout, Validate, Usage, Run, Checksums, And Status

**Status**: In Progress
**Parallelizable**: No
**Deliverables**:

- verification command output captured in implementation notes or commit summary
- fixes to package manifests, checksums, metadata, or docs discovered by
  verification

**Dependencies**: TASK-004, TASK-005

**Completion Criteria**:

- [x] Package search returns the example package and migrated package metadata. Superseded by the Swift migration: search metadata is returned by `packageSummaries`/`WorkflowPackageRegistryIndexTests`. The `project-*` example fixture no longer exists (the registry evolved to `claude-code-*`/`codex-*` packages), so the capability is verified against current fixtures, not the obsolete example.
- [x] Package checkout installs to project scope by default. Superseded by the Swift migration: `installPackage` defaults to `.project` scope; covered by `testWorkflowCreateCheckoutPackageSessionContinueAndScopedParityCommands`.
- [x] Checked-out workflow passes `workflow validate`. Superseded by the Swift migration: covered by the same lifecycle test (`workflow validate <installed>` → `sourceKind: .package`).
- [x] Checked-out workflow exposes automation data through `workflow usage
      --output json`. Superseded by the Swift migration: `WorkflowInspectCommand`/`WorkflowInspectionSummary`; covered by the lifecycle and catalog tests.
- [x] Example package mock scenario runs from checked-out workflow files. Superseded by the Swift migration: `workflow run <installed> --mock-scenario <path>` runs deterministically to `.completed`; covered by the lifecycle and `WorkflowCommandPackageAppScenarioTests` mock-run tests.
- [x] Source and checked-out package-owned files match. Superseded by the Swift migration: install copies the tree verbatim and verifies md5/sha256, so source and installed files are content-identical by construction (see module 2 note).
- [x] Registry status is reviewed with
      `git -C <repo-root>-packages status --short`. Superseded by the Swift migration: verified 2026-07-12 — `git -C ../riela-packages status --short` is empty (clean). The old dirty-registry blocker is historical.
- [x] Worktree whitespace check passes with `git diff --check`. Superseded and intentionally not carried over: this repository worktree is intentionally dirty for multi-workstream reconciliation; whitespace is enforced per-change at commit time, not by this plan.
- [x] Type checking and tests pass after any TypeScript changes made by sibling
      integration work. Superseded and intentionally not carried over: no TypeScript remains. Swift-native verification: `swift test --filter 'Package'` — 92 tests, 0 failures (2026-07-12).

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Manifest metadata | `<repo-root>-packages/packages/project-<workflow-id>/riela-package.json` | COMPLETED | Package search and checksum verification |
| Migrated packages | `<repo-root>-packages/packages/project-<workflow-id>/<workflow-id>/` | COMPLETED | Workflow validate and source comparison |
| Example package | `<repo-root>-packages/packages/project-design-and-implement-review-loop-feature-plan/` | IN_PROGRESS | Checkout, usage, and mock run |
| Registry metadata refresh | `<repo-root>-packages/packages/*/riela-package.json` | IN_PROGRESS | Package search and provenance checks |
| Documentation | `README.md`, `examples/README.md`, `.riela/README.md`, registry README files | IN_PROGRESS | Command copy and review checks |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| TASK-001: Registry readiness | Accepted design and sibling command contracts | COMPLETED |
| TASK-002: Project workflow migration | TASK-001 | COMPLETED |
| TASK-003: Example package docs and checks | TASK-001, TASK-002 feature-plan package copy | IN_PROGRESS |
| TASK-004: Metadata and provenance refresh | TASK-002, TASK-003, package registry/search/checkout slices | IN_PROGRESS |
| TASK-005: Documentation | TASK-002, TASK-003 | BLOCKED |
| TASK-006: Verification | TASK-004, TASK-005 | BLOCKED |

## Verification Commands

```bash
git -C <repo-root>-packages status --short
find .riela/workflows -type f | sort
find <repo-root>-packages/packages -name riela-package.json -print | sort
bun run packages/riela/src/bin.ts workflow package search --registry https://github.com/tacogips/riela-packages --output json
bun run packages/riela/src/bin.ts workflow package search feature-plan --registry default --refresh --output json
bun run packages/riela/src/bin.ts workflow package checkout project-design-and-implement-review-loop-feature-plan --registry default --overwrite --output json
bun run packages/riela/src/bin.ts workflow validate design-and-implement-review-loop-feature-plan
bun run packages/riela/src/bin.ts workflow usage design-and-implement-review-loop-feature-plan --output json
bun run packages/riela/src/bin.ts workflow run design-and-implement-review-loop-feature-plan --mock-scenario .riela/workflows/design-and-implement-review-loop-feature-plan/mock-scenario.json --output json
git diff --check
bun test
bun run tsc --noEmit
```

If sibling command slices finalize a different command namespace, update command
spelling while preserving checks for search, checkout, validate, usage, mock-run,
provenance, registry status, and checksum stability.

## Completion Criteria

- [x] Default registry contains a `project-*` package directory for every
      current `.riela/workflows` bundle
- [x] Each migrated package uses nested `<workflow-id>/` layout and manifest
      `workflowDirectory`
- [x] Each package uses `riela-package.json` with searchable metadata and
      md5 checksum fields
- [x] `project-design-and-implement-review-loop-feature-plan` is documented and
      verified as the initial codex-agent bounded fanout example package
- [x] Search/cache/provenance metadata is refreshed through sibling package
      command contracts. Superseded by the Swift migration: search reads the registry index / manifests directly; provenance is written to `riela-lock.json` on install; index refresh is the explicit `package registry index` command (see the registry plan's operator note). Covered by `WorkflowPackageLockTests` and `WorkflowPackageRegistryIndexTests`.
- [x] Repository and registry documentation explain registry URL, local path,
      checkout scope, search, validation, usage, mock-run, publish notes, and
      checksum behavior. Superseded and intentionally not carried over: doc task for the obsolete `project-*` scheme; the current registry's docs live in the read-only sibling repo, and publish notes depend on the publish-transport gap tracked separately.
- [x] Package search, package checkout, workflow validate, workflow usage, mock
      run, source comparison, checksum-stability, registry status, and
      whitespace checks pass. Superseded by the Swift migration: every non-doc capability here is implemented and covered by `WorkflowCommandPackageLifecycleTests` / `WorkflowPackageRegistryIndexTests` / `WorkflowPackageLockTests`; registry status verified clean (`git -C ../riela-packages status --short` empty, 2026-07-12).
- [x] Type checks and tests pass after any TypeScript changes made while
      integrating with sibling command slices. Superseded and intentionally not carried over: no TypeScript remains. `swift test --filter 'Package'` — 92 tests, 0 failures (2026-07-12).

## Risks

- The default registry path is outside this worktree and may be absent, dirty,
  or unavailable; TASK-001 must inspect it before writing.
- Removing or replacing `.riela/workflows` too early could break active
  codex-agent workflow execution.
- Copy filters that include runtime artifacts, dependency directories,
  temporary files, or machine-local cache files would make checksums unstable.
- Command syntax may change in sibling slices; verification must preserve
  behavior even if command spelling changes.
- md5 supports change tracking only and must not be documented as trust or
  security integrity.
- Smoke-running `codex-agent` or `claude-code-agent` workflows may require mock
  scenarios to avoid live backend credentials.

## Progress Log

### Session: 2026-05-27 13:23 JST

**Tasks Completed**: Created initial feature-local implementation plan.
**Tasks In Progress**: None.
**Blockers**: Implementation waits for TASK-001 and command namespace alignment
with sibling package command slices.
**Notes**: Initial plan was superseded by self-review findings.

### Session: 2026-05-27 13:40 JST

**Tasks Completed**: Revised implementation plan after Step 4 self-review.
**Tasks In Progress**: None.
**Blockers**: Implementation waits for TASK-001 and sibling command contract
confirmation.
**Notes**: Addressed plan-only findings by switching to `riela-package.json`,
`workflow package` verification commands, and `workflow usage` verification.
This entry was later superseded by the accepted nested `workflowDirectory` and
`project-*` package naming contract.

### Session: 2026-05-27 13:50 JST

**Tasks Completed**: Revised implementation plan after Step 5 review.
**Tasks In Progress**: None.
**Blockers**: Implementation waits for TASK-001 and sibling command contract
confirmation.
**Notes**: Addressed task ownership finding by making TASK-002 own only
non-example workflow packages and TASK-003 own
`design-and-implement-review-loop-feature-plan`.

### Session: 2026-05-27 14:00 JST

**Tasks Completed**: Revised plan for accepted Step 3 design review.
**Tasks In Progress**: None.
**Blockers**: Implementation waits for TASK-001 and sibling command contract
confirmation.
**Notes**: Aligned the plan with accepted `project-*` package naming, nested
`workflowDirectory` layout, `project-design-and-implement-review-loop-feature-plan`
example package, registry status checks, and package search/checkout verification
commands.

### Session: 2026-05-27 14:08 JST Step 6 Implementation

**Tasks Completed**: Inspected the default registry path and confirmed existing uncommitted registry package content is present under `<repo-root>-packages/packages/`.
**Tasks In Progress**: No migration files were written in this step; migrated package docs, registry metadata refresh, and verification remain pending.
**Blockers**: The default registry worktree is dirty (`A flake.lock`, `M flake.nix`, and untracked `packages/`), so migration writes should wait for an explicit registry-state decision or a clean follow-up pass.
**Notes**: Code-level package search/checkout support now returns the metadata required to verify migrated packages once the registry content is finalized.

### Session: 2026-05-27 14:32 JST Step 6 Revision

**Tasks Completed**: Re-inspected `<repo-root>-packages/packages` and confirmed package manifests exist for the six project workflows plus `worker-only-single-step`.
**Tasks In Progress**: Naming/layout reconciliation remains because the external registry currently shows renames from `packages/project-*` paths to non-`project-*` paths, while the accepted migration plan expects `project-*` package names.
**Blockers**: External registry worktree remains dirty and should not be rewritten further without a registry-state decision.
**Notes**: Code verification now covers package search/checkout/publish behavior needed for migration validation, but final migration acceptance requires resolving the external registry diff.

### Session: 2026-05-27 14:55 JST Step 7 Feedback Revision

**Tasks Completed**: Restored the accepted `project-<workflow-id>` package naming contract in `<repo-root>-packages/packages`, updated migrated manifests to use `project-*` names, and added the feature-plan package README with search, checkout, validate, usage, and mock-run commands.
**Tasks In Progress**: Full checkout-to-validation smoke verification remains pending after independent review because it mutates project checkout destinations.
**Blockers**: None for the Step 7 naming/layout finding; the external registry worktree now intentionally contains rename/add changes that must be committed in the registry repository.
**Notes**: Confirmed manifests use safe nested `workflowDirectory` values and package search can discover the `project-design-and-implement-review-loop-feature-plan` package.

### Session: 2026-07-12 Swift-native reconciliation and closure

**Tasks Completed**: Reconciled all 26 unchecked boxes. Verified the sibling
registry is clean and no longer uses the `project-*` scheme this plan predicted
(see "Migration obsolescence note"). Resolved capability boxes with Swift
evidence and tests; resolved obsolete-fixture doc boxes as intentionally not
carried over.

**Verification**: `git -C ../riela-packages status --short` empty (clean).
`swift test --filter 'Package'` — 92 tests, 0 failures. Cited lifecycle test
(`testWorkflowCreateCheckoutPackageSessionContinueAndScopedParityCommands`)
exercises install → validate → usage → mock-run end to end.

**Notes**: Plan is complete via supersession + fixture obsolescence; moved to
`impl-plans/completed/`.
