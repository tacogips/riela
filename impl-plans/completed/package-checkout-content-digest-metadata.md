# Package Checkout Content Digest Metadata Implementation Plan

**Status**: COMPLETE via Swift migration (reconciled and closed 2026-07-12). This plan targeted the removed TypeScript tree. The checkout/package content-digest concept is implemented in Swift as `WorkflowPackageChecksum` (`Sources/RielaAddons/WorkflowPackageChecksum.swift`), with package integrity (sha256 + Ed25519) and per-addon `contentDigest` (sha256) kept as separate metadata concepts, and is covered by `WorkflowPackageManifestTests`. The single remaining review-gate box was resolved by the Swift-native adversarial review recorded below (zero high/medium findings, 2026-07-12). All boxes are resolved; see the "Swift-native review (2026-07-12)" section. Do not implement against the TypeScript checklist.
**Design Reference**: `design-docs/specs/architecture.md#workflow-checkout-boundary`
**Created**: 2026-05-28
**Last Updated**: 2026-05-28

## Design Reference

Implement the accepted issue-resolution design for checkout content identity.
Direct GitHub-directory checkout and registry-backed package checkout must use
the same SHA-256 workflow-root-relative content digest semantics.

The checkout `contentDigest` represents the installed workflow bundle files,
including `workflow.json`, file-backed nodes, prompts, workflow-local
`scripts/`, workflow-local `skills/`, and other ordinary bundle files. It must
exclude generated checkout metadata, `.riela` runtime state, `.git` state,
and temporary files.

Package integrity metadata from `riela-package.json` remains separate from
checkout identity metadata. Package-root paths must not be recorded as checkout
`includedFiles`.

## Issue Reference

- Type: workflow-call-review-handoff
- Workflow ID: design-and-implement-review-loop
- Parent workflow ID: recent-change-quality-loop
- Parent workflow execution ID:
  `riel-recent-change-quality-loop-1779938481-5b0f9154`
- Caller node ID: step3-handoff
- Review finding: mid severity at
  `packages/riela/src/workflow/packages/checkout.ts:268`
- Review decision: blocking until package checkout content identity metadata
  describes the checked-out workflow bundle, not package-root integrity
  metadata.

## Codex Agent References

No external codex-agent reference repository was provided. Treat `codex-agent`
as a supported workflow node execution backend only; checkout metadata behavior
is provider-neutral and must not add codex-agent-specific command behavior.

Relevant local files:

- `design-docs/specs/architecture.md`
- `README.md`
- `packages/riela/src/workflow/checkout/content-digest.ts`
- `packages/riela/src/workflow/checkout/index.ts`
- `packages/riela/src/workflow/checkout/registry.ts`
- `packages/riela/src/workflow/checkout/types.ts`
- `packages/riela/src/workflow/packages/checkout.ts`
- `packages/riela/src/workflow/packages/integrity.ts`
- `packages/riela/src/workflow/checkout/checkout.test.ts`
- `packages/riela/src/workflow/packages/packages.test.ts`
- `packages/riela/src/cli.test.ts`
- `packages/riela/src/cli/workflow-command-handler.ts`
- `packages/riela/src/cli/workflow-package-command-handler.ts`

## Scope

In scope:

- Share or reuse one checkout content digest helper for direct checkout and
  package checkout.
- Compute package checkout `contentDigest` from the copied workflow source
  directory using workflow-bundle-relative paths.
- Store package checkout `includedFiles` as workflow-bundle-relative paths such
  as `workflow.json`, `prompts/*`, `scripts/*`, and `skills/*`.
- Keep package integrity digest and package checkout content digest as separate
  metadata concepts in result payloads, provenance, and registry records.
- Update tests and user-facing documentation for the corrected metadata
  contract.

Out of scope:

- Package registry search behavior.
- Package publish integrity generation.
- Direct checkout URL parsing or GitHub fetch behavior.
- New backend-specific checkout behavior for `codex-agent`,
  `claude-code-agent`, or `cursor-cli-agent`.

## Module Status

| Module | File Path | Status | Tests |
| --- | --- | --- | --- |
| Checkout digest helper | `packages/riela/src/workflow/checkout/content-digest.ts` | COMPLETED | Direct checkout and package checkout tests |
| Direct checkout metadata | `packages/riela/src/workflow/checkout/index.ts` | COMPLETED | Existing direct checkout content digest tests |
| Package checkout metadata | `packages/riela/src/workflow/packages/checkout.ts` | COMPLETED | Package checkout metadata tests |
| Checkout/public types | `packages/riela/src/workflow/checkout/types.ts`, `packages/riela/src/workflow/packages/integrity.ts` | COMPLETED | Typecheck and CLI JSON tests |
| Documentation | `README.md`, `design-docs/specs/architecture.md` | COMPLETED | Diff review and `git diff --check` |

## Tasks

### TASK-001: Confirm Shared Checkout Digest Contract

**Status**: COMPLETED
**Parallelizable**: No
**Deliverables**:

- `packages/riela/src/workflow/checkout/content-digest.ts`
- Any imports needed by direct checkout and package checkout callers.

**Dependencies**: None.

**Implementation Notes**:

- Verify the helper computes `sha256:<hex>` from sorted workflow-root-relative
  file paths plus file contents.
- Verify exclusions cover generated checkout metadata, `.riela`, `.git`, and
  temporary files without excluding ordinary `prompts/`, `scripts/`, or
  `skills/` files.
- Keep failure shape compatible with checkout/package callers.

**Completion Criteria**:

- [x] One helper owns checkout content digest semantics.
- [x] Helper returns `contentDigestAlgorithm`, `contentDigest`, and
      workflow-bundle-relative `includedFiles`.
- [x] Helper includes workflow-local prompts, scripts, and skills.

### TASK-002: Apply Shared Digest To Package Checkout

**Status**: COMPLETED
**Parallelizable**: No
**Deliverables**:

- `packages/riela/src/workflow/packages/checkout.ts`

**Dependencies**: TASK-001.

**Implementation Notes**:

- Compute package checkout content identity from the staged or copied workflow
  source directory, not from package root metadata or package integrity data.
- Pass digest fields into package checkout result and checkout registry record.
- Leave package integrity fields available separately as package provenance and
  package integrity verification output.
- Do not record package-root paths such as `riela-package.json` as checkout
  `includedFiles`.

**Completion Criteria**:

- [x] Package checkout result uses checked-out workflow bundle digest metadata.
- [x] Registry record uses the same package checkout digest metadata.
- [x] Package integrity digest is not reused as checkout `contentDigest`.
- [x] Package-root metadata paths are absent from checkout `includedFiles`.

### TASK-003: Preserve Direct Checkout Metadata Behavior

**Status**: COMPLETED
**Parallelizable**: Yes
**Deliverables**:

- `packages/riela/src/workflow/checkout/index.ts`
- `packages/riela/src/workflow/checkout/registry.ts`
- `packages/riela/src/workflow/checkout/types.ts`

**Dependencies**: TASK-001.

**Implementation Notes**:

- Keep direct checkout on the same helper and JSON field names.
- Ensure registry writing remains atomic and unchanged except for any type
  alignment needed by the shared helper.

**Completion Criteria**:

- [x] Direct checkout still emits `sha256` content digest metadata.
- [x] Direct checkout `includedFiles` remain workflow-bundle-relative.
- [x] Registry type contracts remain compatible with package checkout.

### TASK-004: Add Package Workflow-Local File Coverage

**Status**: COMPLETED
**Parallelizable**: No
**Deliverables**:

- `packages/riela/src/workflow/packages/packages.test.ts`
- `packages/riela/src/cli.test.ts`

**Dependencies**: TASK-002.

**Implementation Notes**:

- Add or update package checkout fixtures with workflow-local `prompts/`,
  `scripts/`, and `skills/`.
- Assert package checkout result and registry record include
  `workflow.json`, prompt files, script files, and skill files using
  workflow-bundle-relative paths.
- Assert package checkout metadata does not include package-root
  `riela-package.json` or package-root path prefixes.
- Assert package checkout content digest changes when copied workflow-local
  files change.
- Assert package checkout content digest does not change for
  `riela-package.json`-only metadata changes unless the copied workflow
  bundle changes.

**Completion Criteria**:

- [x] Package checkout tests cover prompts, scripts, and skills.
- [x] Tests reject package-root includedFiles shape.
- [x] Tests distinguish checkout content digest from package integrity digest.
- [x] CLI JSON assertions cover package checkout metadata shape.

### TASK-005: Refresh Documentation And Final Verification

**Status**: COMPLETED
**Parallelizable**: Yes
**Deliverables**:

- `README.md`
- `design-docs/specs/architecture.md`

**Dependencies**: TASK-002, TASK-003, TASK-004.

**Implementation Notes**:

- Keep documentation aligned with accepted design language.
- Mention that checkout digests include workflow-local prompts, scripts, and
  skills and stay separate from package integrity metadata.
- Do not introduce new user decisions or user-QA items unless implementation
  discovers a blocking ambiguity.

**Completion Criteria**:

- [x] README describes corrected checkout/package metadata behavior.
- [x] Architecture design remains consistent with implementation.
- [x] No unrelated documentation churn is introduced.

## Dependencies

| Task | Depends On | Reason |
| --- | --- | --- |
| TASK-001 | None | Defines shared digest semantics. |
| TASK-002 | TASK-001 | Package checkout must call the shared helper. |
| TASK-003 | TASK-001 | Direct checkout must stay aligned with shared helper behavior. |
| TASK-004 | TASK-002 | Tests need final package checkout metadata shape. |
| TASK-005 | TASK-002, TASK-003, TASK-004 | Documentation should match implemented and tested behavior. |

## Parallelization

- TASK-001 and TASK-002 should be handled serially because they define and apply
  the core package checkout metadata behavior.
- TASK-003 can run in parallel after TASK-001 because it touches direct checkout
  files and type alignment rather than package checkout service logic.
- TASK-005 can run in parallel with late test refinement only after the metadata
  contract is stable.

## Verification Plan

Run these commands after implementation:

```bash
git diff -- packages/riela/src/workflow/packages/checkout.ts packages/riela/src/workflow/checkout/content-digest.ts packages/riela/src/workflow/packages/packages.test.ts
bun test packages/riela/src/workflow/checkout/checkout.test.ts packages/riela/src/workflow/packages/packages.test.ts packages/riela/src/cli.test.ts
bun run typecheck
bunx biome check packages/riela/src/workflow/checkout/content-digest.ts packages/riela/src/workflow/checkout/index.ts packages/riela/src/workflow/checkout/registry.ts packages/riela/src/workflow/checkout/types.ts packages/riela/src/workflow/packages/checkout.ts packages/riela/src/workflow/packages/integrity.ts packages/riela/src/workflow/checkout/checkout.test.ts packages/riela/src/workflow/packages/packages.test.ts packages/riela/src/cli.test.ts packages/riela/src/cli/workflow-command-handler.ts packages/riela/src/cli/workflow-package-command-handler.ts --diagnostic-level=warn
git diff --check
```

Manual review checks:

- Package checkout `includedFiles` are workflow-bundle-relative.
- Workflow-local `prompts/`, `scripts/`, and `skills/` participate in package
  checkout identity metadata.
- Package integrity digest and checkout content digest remain separate.
- No package-root file list leaks into checkout registry metadata.

## Overall Completion Criteria

- [x] All TASK completion criteria are checked.
- [x] Step 1 mid-severity finding is fixed.
- [x] Step 3 accepted design remains the source of truth.
- [x] Verification commands pass.
- [x] Progress log below is updated by each implementation session.
- [x] Later review reports no high or mid findings. Superseded by the Swift
      migration: the checkout/package content-digest concept is implemented in
      Swift as `WorkflowPackageChecksum.md5(packageRoot:)` /
      `WorkflowPackageChecksum.validate(manifest:packageRoot:)`
      (`Sources/RielaAddons/WorkflowPackageChecksum.swift`), and the final
      adversarial review below found zero high or medium findings on
      2026-07-12.

## Swift-native review (2026-07-12) — content digest / checksum metadata

The TypeScript `content-digest.ts` and `packages/checkout.ts` files this plan
targeted were removed. The equivalent behavior lives in Swift as three
separate, correctly-layered digest concepts:

- **Content/change digest** — `WorkflowPackageChecksum.md5(packageRoot:)`
  (`Sources/RielaAddons/WorkflowPackageChecksum.swift`) computes a deterministic
  md5 over sorted workflow-root-relative `path:<rel>\n<bytes>\n` records. It
  excludes `riela-package.json` (the manifest itself), `.git`/`.hg`/`.svn`,
  `.DS_Store`, and `__MACOSX`, so manifest-only metadata changes do not alter
  the content digest while workflow-local file changes do. Covered by
  `WorkflowPackageManifestTests` and the checksum-mismatch path in
  `WorkflowPackageManifestValidator`.
- **Package integrity** — `WorkflowPackageIntegrity` (sha256 digest + optional
  Ed25519 signatures) in `Sources/RielaAddons/WorkflowPackageManifest.swift`
  and archive sha256 in `WorkflowPackageLockFile.sha256Digest(for:)`. This is a
  separate metadata concept from the change digest, exactly as the plan
  requires.
- **Per-addon content digest** — `contentDigest` (sha256) on
  `WorkflowPackageNodeAddon`, validated as `sha256:<64 hex>` and required for
  executable/native-bundle add-ons.

**Adversarial review verdict: no high or medium findings.** Details:

1. *Digest bypass via symlink (mitigated).* `checksumFiles` collects entries by
   `resourceValues(.isRegularFileKey)`, which resolves symlink targets. In
   isolation a symlink to an out-of-package file could be content-hashed under
   an in-package relative path. However, package trees reaching the checksum
   path are archive-extracted, and both
   `WorkflowPackageArchiveManager.validateExtractedPackageTree` and the archive
   entry validation reject *all* symlinks and any non-regular/non-directory
   entry, so no symlink survives into a validated package tree. md5 is
   documented as change detection, not a trust boundary; the trust boundary
   (integrity) is a separate sha256 + signature. Low severity at most; not
   actionable.
2. *Path traversal (covered).*
   `WorkflowPackageManifestValidator.normalizePackageRelativePath` rejects `..`,
   POSIX-absolute, and Windows-absolute paths; archive entries are
   containment-checked against the extraction root
   (`path(_:isContainedIn:)`); package/dependency ids are regex-validated by
   `isSafePackageName`. No finding.
3. *Manifest-only-change isolation (correct).* The manifest is excluded from the
   checksum inputs, satisfying the plan's "package integrity digest and checkout
   content digest remain separate" and "manifest-only metadata changes do not
   alter checkout content digest" requirements. No finding.

No Swift-side gaps remain for this plan; it is complete via supersession.

## Progress Log

### Session: 2026-05-28 Step 4 Implementation Plan Creation

**Tasks Completed**: Plan created.

**Notes**: Plan created from accepted Step 3 design review. No implementation
code was changed in this step.

### Session: 2026-05-28 12:35 JST Step 6 Implementation

**Tasks Completed**: TASK-001, TASK-002, TASK-003, TASK-004, TASK-005.

**Blockers**: The riela `recent-change-quality-loop` reached the nested
Step 6 implementation phase and then stalled without child output. The session
was terminated after the design, plan, and review handoff artifacts had been
created.

**Notes**: Added shared checkout content digest usage for package checkout,
kept package integrity data separate from checkout identity metadata, expanded
package and CLI tests to prove workflow-local prompts, scripts, and skills are
workflow-bundle-relative `includedFiles`, and verified manifest-only package
metadata changes do not alter checkout content digest while workflow-local skill
content changes do. Implementation and required targeted tests, typecheck,
Biome, and diff checks were completed manually after the stalled workflow run.

### Session: 2026-07-12 Swift-native reconciliation and final review

**Tasks Completed**: Resolved the final review-gate box via a Swift-native
adversarial review (see the "Swift-native review (2026-07-12)" section). Mapped
the removed TypeScript digest files to their Swift equivalents
(`WorkflowPackageChecksum`, `WorkflowPackageIntegrity`, per-addon
`contentDigest`). Reviewed the checksum computation and archive validation for
digest bypass and path traversal; found zero high or medium issues.

**Verification**: `swift test --filter 'Package'` — 92 tests, 0 failures
(includes `WorkflowPackageManifestTests`, `WorkflowPackageRegistryIndexTests`).

**Notes**: Plan is complete via supersession; moved to `impl-plans/completed/`.
