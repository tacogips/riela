# Installed Package Workflow Resolution

## Overview

Installed workflow packages are local workflow sources. After `riela package
install`, a package-provided workflow must be usable through ordinary
`riela workflow` commands without requiring `--from-registry`.

Packages remain distribution units that may include workflows, skills, scripts,
and metadata. The package wrapper is still important because package-owned
contents should be treated as immutable installed artifacts by default, but the
user-facing workflow command surface should not force users to remember a
separate execution path for already-installed packages.

## Command Semantics

- `riela workflow list --scope <scope>` lists normal workflow catalog entries
  and installed package workflow entries.
- `riela workflow validate <name>`, `inspect <name>`, `status <name>`, and
  `run <name>` resolve installed package workflows as normal local workflows.
- `riela workflow package ...` remains the package management and package
  inspection command surface.
- `--from-registry` is not the installed-package path. It is reserved for
  registry-backed resolution of package/workflow content that is not already
  installed locally.

## Resolution Rules

The resolver preserves existing precedence:

1. direct `--workflow-definition-dir`
2. project/user workflow catalog roots under `.riela/workflows`
3. project/user installed package roots under `.riela/packages`

For package resolution, the command target is the package name. Scoped package
names such as `@scope/name` are valid workflow targets when a matching package
is installed. The resolver loads the package's `riela-package.json`, validates
the manifest and declared workflow bundle, normalizes `workflowDirectory`, and
then resolves the workflow from that package-owned directory.

Package `workflowDirectory` values must stay package-relative and must not
escape the package root after symlink resolution.

## Provenance

Commands that surface workflow metadata include package provenance:

- `sourceKind`: `workflow` or `package`
- `packageName`
- `packageVersion`
- `packageDirectory`
- `mutable`

`sourceKind` is a typed Swift enum with stable string raw values for JSON and
table/text rendering. Package-derived workflows report `mutable: false` so
users and tools know not to edit the installed package contents directly.

## Safety

Normal workflow names continue to use the scoped workflow-name validator.
Installed package workflow targets use the package-name validator because
scoped package names include `/`. Path traversal and absolute package workflow
directories remain rejected during manifest validation and resolver containment
checks.

## Testing

Coverage must prove:

- installed package workflows appear in `workflow list`
- `workflow validate`, `inspect`, and `run` work without `--from-registry`
- scoped packages such as `@scope/scoped-flow` resolve as local workflows
- provenance fields show `sourceKind: package`, package identity, and
  `mutable: false`
- dry-run package commands do not create runtime records even when other tests
  have already run an installed package workflow

## Issue #117: Preserve Locked Add-on Metadata During Validate/Inspect

Status: branch implementation and behavioral verification complete; branch
test-integrity and adversarial rereview accepted in `comm-000017`, with combined-tree
integration acceptance and final commit/push pending. Workflow mode: `issue-resolution`. Issue:
<https://github.com/tacogips/riela/issues/117>. Source of scope: Step 1 intake
`comm-000002` and effective `workflowInput` for
`codex-design-and-implement-review-loop-session-1`. The issue body was unavailable
at intake; the supplied problem statement and acceptance criteria govern this
addendum. No Codex-agent reference or Cursor CLI mapping is requested.

### Problem and boundary

An installed workflow can reach validate/inspect without the owning package's
external add-on dependency metadata, producing `unresolvedAddonExecutable` for
locked native/container add-ons. In
`Sources/RielaCLI/WorkflowValidateInspectCommands.swift`,
`addonHostRequirements` already recognizes dependency locks when supplied in
`ResolvedWorkflowBundle.packageManifest`. In
`Sources/RielaCore/WorkflowRequirements.swift`, the absence of a projected
requirement correctly rejects an add-on node. Preserve that guard.

The current test
`testDependencyNativeAddonRemainsInspectableWithoutHostExecutable` in
`Tests/RielaCLITests/WorkflowHostCapabilityTests.swift` supplies a manifest in a
stub bundle. It does not prove the installed filesystem resolution path retains
the manifest. The regression must cover that path, including workflow-name
selection and explicit selection of the installed workflow directory.

### Required resolution and projection behavior

1. Resolve the selected workflow using existing scope and candidate precedence.
   Associate metadata only with its verified owning installed package: the
   canonical workflow directory must match the package's declared workflow
   directory, remain contained in that package, and retain its full package ID
   (including scoped IDs), version, and integrity identity. Never infer ownership
   from a workflow name, add-on vendor prefix, or a similarly named installation.
   Direct selection of a proven package-owned workflow may retain that metadata;
   unrelated direct workflows must not acquire installed dependency metadata.
2. Carry the owning manifest and package directory together through the existing
   `ResolvedWorkflowBundle` boundary. The relevant source boundaries are
   `Sources/RielaCLI/WorkflowResolution.swift` and
   `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`. Prefer
   repairing the metadata loss there over introducing a second host-only lookup.
   Do not change source scope, activation, package mutability, or precedence as a
   side effect of retaining metadata.
3. Resolve a referenced external add-on against that package's dependency locks
   and installed dependency metadata. Require a unique permitted match with the
   exact package identity, locked package/add-on versions and declared digests,
   execution kind, and existing scope rules. Preserve all native bundle and
   dependency closure integrity checks. Qualified references retain the complete
   package ID; an unqualified reference succeeds only when unambiguous. An omitted
   node version still uses the lock's version, never an arbitrary installed one.
   Missing, ambiguous, or mismatched evidence must not create a host requirement
   that marks the node resolved. Reuse existing package/add-on verification;
   do not invent a parallel trust mechanism or silently repair locks.
4. Project verified native/container dependencies as known add-ons without
   fabricating a host executable. Preserve package-required and node-required
   environment bindings. Existing built-in, declarative, and local-command
   behavior remains intact; local-command executable availability checks still
   apply. A host-neutral projection is not proof that a native bundle can load
   or a container can run: existing readiness and executable-preflight diagnostics
   remain authoritative.
5. Apply the same rules to each reachable callee using its own resolved bundle;
   metadata from the caller must not authorize unrelated callee add-ons.
   Validate and inspect must agree about dependency resolution. Preserve existing
   JSON/exit conventions and expose unresolved or integrity diagnostics through
   their existing result fields rather than converting failures to success.

### Verification and acceptance

Create synthetic installed workflow and native/container dependency fixtures
under repository-root `tmp/issue-117/` only. Use the real filesystem bundle
resolver in CLI tests, with isolated project and test home roots. Do not modify
the package repository or its existing isolated-project evidence. Use a
YouTube-style external add-on reference without making provider/model/network
calls or launching native/container payloads.

The regression matrix must include: valid native and container locks; scoped
package IDs; installed workflow-name and direct-directory selection; unrelated
direct workflows with the same add-on names; unknown and ambiguous references;
wrong package identity, version, digest, and execution kind; existing scope
precedence; required environment propagation; and a callee whose dependency
metadata differs from its caller. Negative cases must assert diagnostic content,
not merely command completion. Positive cases must assert preserved package
identity/locks and absence of false `unresolvedAddonExecutable` in both validate
and inspect, without suppressing independent readiness failures.

Implementation verification commands (not executed by this design-only step):

```bash
swift test --filter WorkflowHostCapabilityTests
swiftlint
swift build
# Run from the synthetic project using the freshly built source executable:
<source-riela> workflow validate <installed-workflow> --scope project --output json
<source-riela> workflow inspect <installed-workflow> --scope project --output json
<source-riela> workflow validate <installed-workflow> --workflow-definition-dir <installed-workflow-directory> --output json
<source-riela> workflow inspect <installed-workflow> --workflow-definition-dir <installed-workflow-directory> --output json
# For each of the 75 example directories containing workflow.json:
<source-riela> workflow validate <example-name> --workflow-definition-dir examples --output json
git diff --check
```

The implementation plan must replace placeholders with exact fixture/binary
paths and enumerate all 75 examples. Retain complete foreground logs, final exit
statuses, per-example JSON, and a count/diagnostic summary under `tmp/issue-117/`
until downstream verification consumes them. Classify any remaining failures
by command, diagnostic, and relation to this change; incomplete logs are not
passing evidence. Remove scratch after final handoff consumption.

### Decisions, risks, and rollout

This is a narrow resolution/projection correction, with no schema migration,
new registry protocol, generalized resolver framework, or provider integration.
Core remains package-independent. Independent review must accept the fix before
final source commit/push on `fix/example-contract-migration`; no release or merge
is authorized. Preserve unrelated worktrees and the existing #116 correction.

The material risks are incorrectly authorizing an unrelated add-on and changing
scope/lock selection. The ownership, mismatch, ambiguity, and precedence cases
above are mandatory acceptance evidence. No unresolved user decision is needed;
therefore no user-QA document is added. The exact metadata-loss branch must be
confirmed by the synthetic reproduction during implementation, before selecting
the smallest source change. The baseline reproduction and final verification are
recorded in `impl-plans/progress/issue-117-installed-addon-metadata.md`; this did
not broaden the accepted design. No Step 3/5 feedback was supplied for this initial
authoring pass.
