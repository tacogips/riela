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

Historical native/container baseline: implemented in `b75dcfb25b2c386550dfd947773cd138e621f689`.
The earlier branch review accepted that scope in `comm-000017`; it does not
constitute acceptance of the local-command extension below. Workflow mode: `issue-resolution`. Issue:
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

## Issue #117 follow-up: installed local-command dependencies

Status: resumption design updated from pushed WIP `7435d6ce735ebc0a02609d7dcf14e10205d6aba0`; final source verification and independent review accepted; commit and non-force push pending. This
section extends the native/container baseline above and governs the current
`issue-resolution` execution, `codex-design-and-implement-review-loop-session-1`,
Step 1 `comm-000002`, for <https://github.com/tacogips/riela/issues/117>.
The authoritative intake describes three YouTube local-command dependencies;
legacy locks without `executionKind` must remain rejected. The effective input
and intake govern scope. No Codex-agent reference, Cursor adapter, or reference
repository comparison applies. Latest issue comments were unavailable at intake;
there is no unresolved user decision and no user-QA document is needed.

### Observed gap and bounded change

`Sources/RielaCLI/WorkflowInstalledAddonRequirements.swift` at WIP `7435d6c`
already verifies explicit local-command locks and returns the canonical executable
path alongside dependency, lock, and scope evidence.
`Sources/RielaCLI/WorkflowValidateInspectCommands.swift` consumes that verified
path for dependency host requirements and local availability. Preserve this
narrow implementation while completing missing negative coverage and final
source-matched verification. The installed descriptor must be checked within the
verifier; carrying a duplicate descriptor in the returned value is not required
when consumers need only the verified identity and executable path. Keep
`Sources/RielaCLI/WorkflowResolution.swift` ownership and selection semantics,
and the unresolved-add-on guard in
`Sources/RielaCore/WorkflowRequirements.swift`. Core remains independent of
package metadata. No new resolver framework, schema, CLI option, execution
engine, automatic lock migration, or package-repository change is required.

### Verification contract and data flow

1. Resolve the owning installed workflow through the existing bundle resolver.
   Package ID, workflow name, and direct selection of the manifest-declared
   installed workflow directory must retain the same owning manifest and
   dependency identity. For the synthetic fixture, the manifest declares
   `workflows/youtube-flow`, so direct selection uses
   `.riela/packages/@issue117/youtube-flow/workflows/youtube-flow`. The package
   root is not a workflow bundle. Do not extend
   `Sources/RielaCLI/WorkflowResolution.swift` to accept that root. An unrelated
   authored copy must not inherit that identity, including when its name matches.
2. Match the complete qualified dependency reference, or exactly one unqualified
   reference, within the owner's declared node-addon dependencies. An explicit
   node version must match; an omitted version uses the lock. Count matching
   declarations before accepting one: an invalid or missing-kind competing lock
   must not be discarded to turn an ambiguous unqualified name into permission.
3. Require explicit `executionKind: local-command` in the dependency lock and
   agreement with the installed add-on descriptor and package-lock summary.
   Missing kind never defaults from the installed descriptor or vendor/name.
   Preserve existing owner containment/integrity, dependency package identity,
   versions, registry agreement, checksums/integrity, add-on content digest,
   source path, and lock-summary checks. Do not relax native/container checks.
4. Locate the dependency only in the owning installation's selected scope.
   Respect explicit lock scope and existing project/user precedence. Conflicting
   scope evidence fails; a missing or mismatched selected-scope dependency must
   not borrow a same-named valid dependency from a lower-priority scope. Ordinary
   project-over-user selection remains valid; ambiguous candidates in the
   selected scope fail instead of falling through.
5. Resolve the nonempty declared entrypoint beneath the installed dependency's
   add-on source directory. Preserve package-relative path validation and
   canonical containment; escaping paths or symlinks cannot authorize an external
   command. Require an existing executable file, not a directory. A missing or
   non-executable entrypoint fails verification even without `--host`. Never
   substitute a command found on PATH or execute the payload during validation.
6. Project a verified local-command dependency as a real `addonExecutable`
   requirement with package-required and node-required environment bindings.
   Use the verified canonical executable path as the dependency executable key
   in both requirement and local-availability maps, preventing two dependencies
   with the same entrypoint basename from sharing readiness. Preserve existing
   package-owned local-command and native/container projection semantics.
7. Each reachable workflow uses its own verified bundle and executable evidence.
   Local filesystem availability informs the local snapshot only; remote host
   snapshots must independently satisfy the projected requirement. Missing
   executable capability or required environment still fails strict host checks.
   Do not manufacture remote readiness from the local installation.
8. Validate and inspect agree on resolution and failure. Verification failure
   leaves the external node unresolved and produces existing failure diagnostics
   and nonzero status; do not suppress independent host/runtime diagnostics.
   This projection does not grant a new execution permission or bypass existing
   runtime execution checks.

### Acceptance matrix and evidence

Extend `Tests/RielaCLITests/WorkflowInstalledAddonMetadataTests.swift` with a
synthetic installed project workflow package and local-command dependency using
explicit registry values, execution-kind locks, matching package-lock metadata,
valid digests, and a harmless executable entrypoint. Keep test homes, fixtures,
and command evidence under `tmp/issue-117-local-command/`; never edit
`riela-packages`, sibling worktrees, or the real legacy YouTube locks.

Both validate and inspect must pass for package-ID, workflow-name, and direct
manifest-declared installed workflow-directory selection. Assert retained identity and the actual
executable requirement, not just absence of an error. Negative cases must assert
nonzero status and relevant diagnostics for missing kind, kind/version/identity/
registry/digest or lock-summary mismatch, missing/non-executable/directory or
escaping entrypoint, unknown reference, ambiguous reference (including a
missing-kind competing declaration), unrelated authored copy, and cross-scope
substitution. Preserve positive native/container and scope-precedence cases.

Extend `Tests/RielaCLITests/WorkflowHostCapabilityTests.swift` or the installed
fixture suite to assert required environment propagation, accurate executable
keys, local and remote capability rejection, same-basename dependency isolation,
and callee-owned context. All tests use deterministic fixtures without provider
calls or local-command execution.

Implementation gates (planned, not claimed as executed by Step 2):

```bash
swift test --filter 'WorkflowInstalledAddonMetadataTests|WorkflowInstalledLocalCommandTests'
swift test --filter WorkflowHostCapabilityTests
swift build
swiftlint
# From the synthetic project, repeat both commands for all three selections:
<source-riela> workflow validate <package-id-or-workflow-name> --scope project --output json
<source-riela> workflow inspect <package-id-or-workflow-name> --scope project --output json
<source-riela> workflow validate <workflow-name> --workflow-definition-dir <installed-workflow-directory> --output json
<source-riela> workflow inspect <workflow-name> --workflow-definition-dir <installed-workflow-directory> --output json
# Validate each of the 75 checked-in examples with the source-built executable:
<source-riela> workflow validate <example-name> --workflow-definition-dir <repository>/examples --output json
git diff --check
```

The implementation plan must supply concrete binary/fixture paths and a
foreground matrix driver enumerating all 75 examples. Record complete stdout,
stderr, numeric final status per command, and aggregate counts; expected negative
cases count as passing only when their failure diagnostics match. Retain evidence
until downstream review consumes it, then remove throwaway files. Prior
native/container test logs are historical and cannot establish this extension's
acceptance. No background processes or incomplete logs qualify as passing gates.

### Resumption evidence and planning handoff

Preserve WIP commit `7435d6c` and the historical evidence in
`impl-plans/progress/issue-117-installed-local-command.md`. That log reports
12 focused tests and 22 host tests passing, but the CLI driver exited 1 with
79/81 positives and 16/16 negatives. This is a failed gate, not completion.
The two failing package-root commands describe an incorrect acceptance command,
not a resolver defect requiring a broader implementation.

Step 4 reconciled `impl-plans/completed/issue-117-installed-local-command.md`
and `impl-plans/active/issue-117-dispatch.json` with this declared-directory
selection and WIP starting point before implementation resumes. Keep the resolver
outside the implementation write scope. Append the corrected interpretation and
new evidence to the progress log without erasing the failed attempt. Reconcile
the plan's descriptor-carriage wording with the verified-path contract above.

The final positive CLI gate requires all six installed commands (validate and
inspect for each of three selections) plus all 75 example validations: at least
81/81 positives with no failed command. Negative CLI cases must cover the
accepted rejection matrix above, each with a numeric nonzero exit and matching
diagnostic; the historical 16/16 does not waive missing cases. Isolate each
mutation so the intended rejection is exercised, rather than an incidental stale
checksum masking it. Record source revision and working-tree diff identity,
source-built executable identity, complete log paths, final numeric exits, and
aggregate counts for the final source. Any subsequent source change requires
rerunning affected gates; historical logs alone cannot accept the final tree.

The planned pre-production failing baseline was not captured. Preserve that
historical limitation explicitly; do not fabricate it or label it passing.
Final regression evidence and independent review must assess the resulting
coverage. This does not authorize restoring or rewriting the preserved WIP.

### Author decisions and rollout

Step 3 (`comm-000004`) and Step 5 (`comm-000006`) accepted the resumed design
and plan. The corrected direct-selection command uses the declared workflow
directory. Final source verification and independent adversarial review accepted
the implementation with no blocking findings. Attempt 4 recorded 12 focused
tests, 22 host tests, build, SwiftLint, 83 positive CLI commands (six required
installed selections, 75 examples, and two user-scope preconditions), and 52
expected rejections with complete logs and numeric exits. Browser E2E was
skipped because no browser-facing file changed. The historical pre-production
failing baseline remains unavailable. Commit and non-force push target
`fix/example-contract-migration`; release and merge remain outside scope.
Runtime-owned workflow provenance is authoritative for this execution.

The principal risks are granting command readiness from an incorrect dependency
match and accepting legacy missing-kind locks. Exact matching, entrypoint
readiness, and negative-case coverage above are required to close them. There are
no unresolved architectural or user decisions. This design introduces no package
migration: legacy packages remain rejected until separately updated with valid,
explicit lock metadata.
