# Temporary Workflow Registry

## Status and scope

This design covers one issue-resolution work package: persistent registration,
catalog discovery, validation, and local execution of temporary (also described
as adhoc) workflows in the Swift CLI. No GitHub URL, repository, or issue number
was supplied; the authoritative issue title is **Add temporary (adhoc) workflow
registration, listing, and run support to riela CLI**.

The implementation is limited to the `riela workflow` command family and its
local catalog/resolver. It does not add remote registry behavior, package
installation, automatic expiry, project-scoped temporary storage, or a new
workflow format. There are no codex-agent behavioral references for this work.

## User contract

The primary product term is **temporary workflow**. Help text may say “temporary
(adhoc)” for discoverability, but `adhoc` is not a second source kind or command
alias.

Registration uses this explicit command shape:

```text
riela workflow register <path> --temporary [--overwrite]
  [--working-dir <dir>] [--output jsonl|json|text|table]
```

`--temporary` is required so `register` can gain other destinations later
without silently changing existing scripts. `--output` defaults to `jsonl`,
matching other workflow commands. A successful structured result includes at
least `workflowId`, `scope: "user"`, `sourceKind: "workflow"`,
`temporary: true`, `mutable: true`, `workflowDirectory`, `inputPath`, and
`overwritten`.
Text and table output include the literal marker `temporary`.

The source may be either:

- a regular JSON file, which is copied as the destination `workflow.json`; or
- a bundle directory whose root contains a regular `workflow.json`, in which
  case the complete contained bundle is copied.

A file registration copies only that file. A workflow that references node,
prompt, script, or other relative files must therefore be supplied as a bundle
directory. Missing referenced files are validation errors; the CLI does not
guess at or copy siblings of a JSON file.

The decoded `workflowId` is the registry key and destination directory name.
It must satisfy the existing safe scoped-workflow-name rule. The CLI never
rewrites, truncates, or derives an alternate name from the input filename.

## Storage and lifecycle

Temporary workflows are user-scoped managed copies stored at:

```text
~/.riela/temporary-workflows/
  <workflowId>/workflow.json
  .registry-state/
    catalog.lock
    locks/<workflowId>.lock
    transactions/<workflowId>.json
    record-staging/<transactionId>.json
    staging/<transactionId>/
    backups/<workflowId>/<transactionId>/
```

`.registry-state` is a reserved internal subtree, never a workflow candidate.
Registration rejects that identifier even if the general safe-name rule later
changes to permit it. Catalog discovery enumerates visible workflow directories
only from immediate children of `temporary-workflows`, always excludes
`.registry-state`, and continues to render other unexpected immediate
directories as invalid temporary entries. Locks, staging copies, backups, and
transaction records therefore cannot appear in list or query output.

The home directory is resolved through `CLIRuntimeEnvironment` so tests and
embedded callers can isolate the registry. Registration does not accept
`--scope`: temporary storage is always user-scoped. `--working-dir` affects only
resolution of a relative input path.

Registration is transactional from the catalog's perspective. The registry
uses two lock levels: the registry-wide `catalog.lock` is the discovery and
publication barrier, while `locks/<workflowId>.lock` coordinates access to one
published workflow. Registration, recovery, and existing mutation paths acquire
the registry-wide barrier before the per-workflow lock whenever they may change
visible registry state. Catalog discovery holds the same barrier from the start
of its recovery sweep through its visible-directory snapshot. It then releases
the barrier and loads each snapshotted descriptor under its per-workflow lock.
This closes the sweep/enumeration race without holding a global lock during
bundle decoding and validation. A fresh registration that begins after the
snapshot is normally absent from that snapshot; an overwrite cannot make an
entry that was present at snapshot time disappear from the current result.

The lock order is always registry-wide barrier, then per-workflow lock; recovery
of multiple workflows takes per-workflow locks one at a time in stable
identifier order. No operation may wait for `catalog.lock` while retaining a
per-workflow lock. Catalog descriptor loading and direct resolution retain the
per-workflow lock through the candidate existence check and bundle load, so
publication beginning after a catalog snapshot cannot invalidate a snapshotted
descriptor during loading.
On Darwin and Linux CLI builds, both levels are advisory filesystem locks on
regular, non-symlink lock files beneath the registry root. The internal subtree
and each artifact it uses must be a real directory or regular file rather than
a symlink. Staging, backup, and transaction records remain beneath the same
registry root as the destination so directory renames never cross a filesystem
boundary.

Each transaction record is versioned and contains `schemaVersion: 1`, the safe
`workflowId`, a unique `transactionId`, `phase`, `hadOriginal`, a SHA-256 digest
of the validated replacement bundle inventory, and normalized relative paths to
its destination, staging directory, and optional backup. The bundle digest
covers sorted relative paths, entry types, and regular-file contents so recovery
can distinguish the replacement from an untouched prior entry. Every recorded
path must match its identifiers, remain within its declared registry-state
subtree, and resolve without symlinks.

Transaction phases are `prepared`, `movingOriginal`, `originalBackedUp`,
`publishingReplacement`, and `replacementPublished`. Record creation and every
phase transition occur while holding the registry-wide barrier and per-workflow
lock. A complete next record is written and synced as a regular file under
`record-staging`, renamed atomically over
`transactions/<workflowId>.json`, and followed by a sync of the transactions
directory before the corresponding directory rename begins.
Record-staging files are never scanned as active transactions. This ordering
means recovery observes either the prior complete phase or the next complete
phase, never partial JSON.

The publication protocol is:

1. Resolve and inspect the input without modifying the registry.
2. Reject non-regular JSON inputs, symlinks, special files, and bundle entries
   that resolve outside the input root.
3. Copy into a private staging directory below the temporary-workflow root.
4. Resolve the staged bundle and run the same authored-workflow and node-payload
   validation used by `riela workflow validate`.
5. Acquire the registry-wide discovery/publication barrier and then the
   per-workflow publication lock. Recover any earlier incomplete transaction for
   the same identifier before changing the visible entry.
6. Publish the `prepared` record. For overwrite, publish `movingOriginal`, rename
   the old entry to its private backup, then publish `originalBackedUp`.
7. Publish `publishingReplacement`, rename the validated staging directory to
   `<workflowId>`, verify its recorded digest, then publish
   `replacementPublished`. Each directory rename is atomic, but the design does
   not assume a portable atomic exchange of two nonempty directories.
8. Remove the backup and transaction record, sync their parent directories, and
   release the per-workflow lock and registry-wide barrier. A fresh registration
   follows the same protocol with `hadOriginal: false` and without an old-entry
   backup.

If `<workflowId>` already exists, the default is a usage error that names the
workflow and destination and suggests `--overwrite`. With `--overwrite`, the old
entry remains the result returned to readers until the validated replacement is
ready. Readers wait while the two renames are in progress and therefore never
observe the transient backup-only state. Before releasing the lock, an ordinary
publication error restores the backup and removes staging state. If the process
is interrupted, the next catalog, resolution, or registration access recovers
under the same lock: it restores the backup when no verified new destination is
present, or keeps the verified new destination and removes the backup when
promotion completed. Ambiguous, linked, or malformed recovery state fails
closed with a diagnostic and preserves every available artifact for adversarial
review. Tests inject failure and interruption after each state transition.

Recovery happens before discovery. When temporary entries are eligible for a
catalog request, the catalog first acquires `catalog.lock`, scans transaction
filenames in stable identifier order, and recovers each record under its
per-workflow lock. It derives and validates the safe workflow identifier from
each `<workflowId>.json` filename, acquires that workflow's lock, and only then
uses `lstat` and a fresh read to validate the regular non-symlink record, its
matching identifier, phase, digest, and contained paths. A record that
disappears between enumeration and the locked fresh read is skipped only when a
fresh `lstat` confirms absence; linked, special, or malformed state fails closed
without deletion. Registry-owned publishers cannot cause that disappearance
because they also require the barrier.

Under the lock, recovery combines the last durable phase with actual staging,
backup, and destination state. Before replacement publication, it aborts the
attempt and restores or retains the prior destination. Once the destination
matches the recorded replacement digest, it finishes publication and removes
the backup. A missing destination with a backup restores the backup; a fresh
registration with only staging state is abandoned; a destination matching the
replacement digest with no staging state is retained. Any combination that
cannot be proven to be the untouched prior entry or the recorded replacement
fails closed and preserves all artifacts. Recovery removes the transaction
record only after syncing the recovered visible state.

After recovering every scanned record, the catalog snapshots visible workflow
directories before releasing `catalog.lock`. Because every publisher must hold
that barrier before creating an active transaction or moving a visible entry,
no backup-only interval can begin between the sweep and snapshot. The catalog
then loads each descriptor under its per-workflow lock, so it returns either the
prior or replacement entry for an overwrite rather than silently omitting it.
Direct name resolution and registration do not depend on visible-directory
discovery: they acquire the barrier and per-workflow lock in that order, run the
same keyed recovery for the requested or decoded workflow identifier, and test
destination existence while the per-workflow lock remains held.

Registered copies are local authored workflows and report `mutable: true`, just
like entries under `~/.riela/workflows`. The registry owns registration and
overwrite publication, but it does not introduce a new immutability boundary:
existing versioning, self-improvement, and workflow mutation paths may update a
resolved temporary bundle under their existing authored-workflow rules while
coordinating through the same barrier-then-per-workflow lock order. `temporary`
records provenance independently from mutability. Entries persist until
explicitly overwritten,
changed through an existing authored-workflow mutation path, or manually
removed. This work package does not add a remove or expiry command.

## Catalog and provenance

`riela workflow list` includes temporary entries by default. Its command shape
is explicitly:

```text
riela workflow list [query] [--scope project|user|auto]
  [--working-dir <dir>] [--exclude-temporary]
  [--output jsonl|json|text|table]
```

The parser already retains the optional positional value as the generic command
target, but catalog listing does not currently consume it. This work defines
that value as a case-insensitive substring query. It matches `workflowName` and,
when present, `packageName`; temporary entries participate through their
`workflowName`. It does not search workflow contents, filesystem paths,
descriptions, scope names, source-kind labels, or diagnostics. An omitted query
returns every eligible entry, and an empty positional value is rejected by the
typed parser rather than treated as a match-all query. Extra positional values
remain usage errors.

The filtering order is fixed: enumerate entries allowed by `--scope`, remove
temporary entries when `--exclude-temporary` is present, apply the optional
query, sort with the existing catalog ordering, then render. `workflow status
<name>` remains an exact name-resolution command and does not inherit substring
query behavior.

The list command adds `--exclude-temporary`. It may be combined with the
positional query, scope, working-directory, and output options. It removes
temporary entries before rendering and does not alter resolver behavior.

Temporary provenance is additive:

- Keep `WorkflowSourceKind` as `workflow|package`; a temporary workflow remains
  an authored workflow, not a third distribution type.
- Add `temporary: Bool` to catalog, validation, and inspection/status results,
  defaulting to `false` when decoding older payloads that omit the field.
- Carry the same provenance on `ResolvedWorkflowBundle` so every command derives
  the marker from an explicit candidate origin rather than reconstructing it
  from a path.
- JSON and JSONL always encode `temporary` as `true` or `false`. Text and table
  renderers include a `temporary`/`standard` kind column or token, so the marker
  is never structured-output-only.

This avoids adding a new case to the public `WorkflowSourceKind` enum, which
could break exhaustive downstream switches. Existing fields retain their
meaning; `sourceKind: "workflow"`, `temporary: true`, and `mutable: true`
together identify a mutable, registered temporary workflow. Existing consumers
that infer authored-workflow mutability from the absence of a package manifest
remain correct; no versioning or self-improvement mutation gate changes for
this feature. Temporary provenance changes only their lock/ownership routing so
Riela-managed mutation cannot race registration publication.

Invalid entries found during listing remain visible as `valid: false` with a
diagnostic and `temporary: true`, consistent with authored catalog behavior.
`--exclude-temporary` hides valid and invalid temporary entries alike.

Catalog discovery and name resolution share bundle loading and validation but
not candidate selection. Catalog enumeration produces an origin descriptor for
each discovered directory containing its root, directory, scope, source kind,
temporary marker, mutability, and package metadata. The catalog loads each
descriptor directly and carries that origin onto the resolved bundle and
rendered entry. It never resolves an enumerated entry by its name. Consequently,
a temporary workflow whose identifier duplicates a higher-precedence authored
workflow or package is still validated and rendered from the temporary
directory with `scope: "user"`, `sourceKind: "workflow"`, `temporary: true`, and
`mutable: true`. Invalid direct loads retain the same descriptor provenance in
their diagnostic catalog entry.

## Resolution and scope rules

An explicit `--workflow-definition-dir` continues to short-circuit catalog
resolution. Otherwise the exact automatic precedence is:

1. project authored workflow: `<working-dir>/.riela/workflows/<name>`
2. user authored workflow: `~/.riela/workflows/<name>`
3. project installed package: `<working-dir>/.riela/packages/<name>`
4. user installed package: `~/.riela/packages/<name>`
5. user temporary workflow: `~/.riela/temporary-workflows/<name>`

Temporary workflows therefore cannot shadow an existing project workflow, user
workflow, or installed package. Duplicate catalog entries may all be listed;
name resolution appends the temporary candidate without changing the existing
candidate-selection or error rules.

Scope behavior preserves current boundaries:

- `--scope auto` includes all five candidates and lists temporary entries.
- `--scope user` includes the user authored workflow, user package, and user
  temporary candidates, in that order.
- `--scope project` includes only the project authored workflow and project
  package; it neither lists nor resolves the user temporary registry.
- direct definition-directory resolution never falls through to temporary
  storage.

Missing candidates continue to the next eligible candidate in every scope. For
an existing candidate that fails bundle loading or validation, current behavior
is preserved: `--scope auto` may continue to a later candidate while collecting
the earlier diagnostic, whereas explicit `--scope project` or `--scope user`
fails at that candidate instead of falling through. Existing package discovery
and manifest-validation failures retain their current behavior. The new user
temporary candidate follows these same rules, so it is reached only when the
higher candidates are absent or when existing automatic-scope fallback permits
continuation. This feature changes ordering only by appending temporary after
all existing candidates.

The shared resolver supplies these rules to `workflow run`, `validate`,
`inspect`/`usage`, and `status`. A target absent from higher-precedence sources
is runnable as `riela workflow run <workflowId>` without a definition-directory
or registry flag. Session and artifact storage rules remain unchanged.

## Validation and errors

Registration must finish full bundle loading and `DefaultWorkflowValidator`
validation before publishing. Errors use the same diagnostic paths as
`workflow validate` and additionally identify the registration input. At
minimum, failures distinguish malformed JSON, a non-object document, decode or
schema errors, unsafe `workflowId`, missing `workflow.json`, missing referenced
assets, escaping references, duplicate destination, and filesystem publication
failure.

Structured parser and command failures remain machine-readable when a
structured output was requested. Invalid registration returns a nonzero exit and
does not create or replace a catalog entry. After registration, ordinary
`riela workflow validate <workflowId>` must report `temporary: true` and the
temporary workflow directory.

## Boundaries and data flow

```text
input file/bundle
  -> typed register options
  -> safe input inventory and private staging copy
  -> existing bundle resolver and validators
  -> per-workflow lock and recoverable two-rename publication
  -> verified temporary-workflows/<workflowId>
  -> registration renderer

workflow list/query
  -> authored roots + package roots + eligible temporary root
  -> temporary transaction recovery sweep
  -> immediate visible directories, excluding .registry-state
  -> one origin descriptor per enumerated directory
  -> direct candidate load with descriptor provenance (no name lookup)
  -> scope eligibility, --exclude-temporary, optional query, existing sort
  -> jsonl/json/text/table renderer

run/validate/inspect/status <name>
  -> shared ordered candidate resolver
  -> existing absence/error/fallback rules
  -> candidate-origin-aware bundle loader
  -> resolved bundle with temporary provenance
  -> existing command behavior
```

Likely implementation surfaces are:

- `Sources/RielaCLI/WorkflowTemporaryRegistrationCommand.swift` (new)
- `Sources/RielaCLI/WorkflowCatalogCommands.swift`
- `Sources/RielaCLI/WorkflowResolution.swift`
- `Sources/RielaCLI/WorkflowCommands.swift`
- `Sources/RielaCLI/WorkflowRunCommand.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Sources/RielaCLI/WorkflowDirectoryTransaction.swift`
- `Sources/RielaCLI/ParsedWorkflowOptions.swift`
- `Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift`
- `Sources/RielaCLI/RielaClientFamilyArguments.swift`
- `Sources/RielaCLI/RielaCommand.swift`
- `Sources/RielaCLI/RielaCLIApplication.swift`
- `Tests/RielaCLITests/WorkflowCommandCatalogTests.swift`
- `Tests/RielaCLITests/WorkflowCommandScopedResolutionTests.swift`
- `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests.swift` (new)

## Rollout and verification gates

This is an additive local CLI feature with no migration. Existing homes without
the new directory behave exactly as before; registration creates the directory
on demand. Existing public Codable payloads must decode records missing
`temporary` as `false`.

Automated verification:

```bash
swift build
swift test --filter WorkflowTemporaryRegistrationTests
swift test --filter WorkflowCommandCatalogTests
swift test --filter WorkflowCommandScopedResolutionTests
```

End-to-end verification must use an isolated home and scratch bundle under the
repository-root `tmp/` directory, then run `.build/debug/riela` in separate
processes to prove persistence:

```bash
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow register "$PWD/tmp/temporary-workflow-registry-smoke/workflow" --temporary --output jsonl
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow list --output jsonl
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow list --output json
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow list --output text
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow list --output table
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow list --exclude-temporary --output jsonl
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow validate temporary-smoke --output jsonl
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow run temporary-smoke --mock-scenario "$PWD/tmp/temporary-workflow-registry-smoke/mock.json" --output jsonl
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow list temporary-smoke --output jsonl
HOME="$PWD/tmp/temporary-workflow-registry-smoke/home" .build/debug/riela workflow register "$PWD/tmp/temporary-workflow-registry-smoke/invalid.json" --temporary --output jsonl
.build/debug/riela workflow --help
.build/debug/riela workflow register --help
```

Focused tests and smoke assertions must cover file and directory inputs,
duplicate rejection, overwrite preservation, publication failure injection,
interruption before the original move, after backup creation, and after
replacement promotion, backup-only recovery through `workflow list`, concurrent
catalog scans during record creation and removal, benign record disappearance,
fail-closed linked or partial records, reader blocking, and a deterministic
overwrite race in which listing begins after the active transaction is durable
but before the original moves and must return the prior or replacement entry
without omission. They must also cover exclusion of every `.registry-state`
artifact from catalog output, unsafe identifiers, malformed
JSON, missing and escaping assets, all four marker renderers, query discovery,
case-insensitive query matching and nonmatching fields, exclusion-before-query,
duplicate-name direct catalog provenance, explicit-scope fail-fast behavior,
automatic-scope fallback, exact precedence, run-by-name, and a second-process
list. The known unrelated
`DaemonWorkflowNodePatchTests` event-source-restart flakiness is not a blocker
without evidence connecting it to these changes.

## Review decision and risks

Design decision: **revised after independent design review and ready for
re-review, with adversarial implementation review required**. The revision adds
the registry-wide discovery/publication barrier and fixed lock ordering so a
catalog request cannot omit an entry during the overwrite backup-only interval.
The declared review mode is `standard` and declared risk is `normal`, but the
feature copies user-selected filesystem content and makes it executable through
normal workflow resolution. Review must explicitly examine symlink and
containment checks, special files, staging cleanup, overwrite
failure behavior, transaction recovery, lock coordination, name validation,
precedence, and structured error output.

Remaining implementation risks are accidental contract breakage in public
Codable results, malformed recovery state, lock bypass by non-Riela filesystem
access, corruption of the reserved internal namespace, unintended path
traversal, temporary shadowing caused by candidate reordering, and divergence
between catalog and resolver provenance. The decisions above resolve all
product questions from intake; there are no unresolved user decisions for
`design-docs/user-qa/`.
