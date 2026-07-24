# Mutable Workflow Registry

## Status and issue contract

This design is the accepted behavior for one issue-resolution work package on
`feat/mutable-workflow-registry`, based on `main` commit `6d27ff6`.

- Issue title: **Mutable workflow registry: rename temporary→mutable/immutable,
  GraphQL CRUD control plane, uniform activation state, and consolidation flow**
- GitHub issue URL, repository, and issue number: not supplied
- Workflow mode: `issue-resolution`
- Review mode: `standard`
- Declared risk: `normal`
- Required implementation review: adversarial, because the change controls
  executable filesystem content, persistent state, migration compatibility,
  and multi-workflow destructive mutations
- Codex-agent references: none

The work remains one feature. Registry naming, activation, GraphQL control,
and consolidation share one source model and transaction boundary and must not
be split into independently implemented feature branches.

## Existing-system findings

The merged temporary registry already provides hardened bundle staging,
validation, filesystem containment, advisory locking, recoverable publication,
and automatic resolution after project workflows, user workflows, and
packages. The implementation currently exposes `temporary` separately from
`mutable`; ordinary project and user workflow directories are reported as
mutable, while packages are immutable. Catalog search only matches workflow or
package names. GraphQL publishes session and instance contracts but has no
workflow-registry service. `RielaGraphQL` depends on `RielaCore`, not
`RielaCLI`, while the filesystem registry is currently implemented in
`RielaCLI`. The `riela graphql execute|document` path currently delegates only
to the note document executor, and the server route accepts an injected
`GraphQLDocumentExecuting` implementation.

The new design preserves the existing registry's publication and recovery
security properties. Naming changes do not authorize a simpler overwrite,
delete, or consolidation path.

Two existing surfaces require explicit compatibility treatment. First,
`Sources/RielaCLI/WorkflowSelfImproveVersioning.swift` and
`Sources/RielaCLI/WorkflowVersionCommands.swift` currently treat every authored
workflow directory as mutable and can rewrite it through
`WorkflowDirectoryTransactionCoordinator`. Second,
`Sources/RielaCore/WorkflowInstanceModel.swift` and
`Sources/RielaCore/WorkflowInstanceResolver.swift` use `temporary` for the
lifetime of an effective per-run instance, independently of registry
provenance. The contracts below resolve both instead of leaving parallel
definitions of mutability or temporary lifetime in the public model.

## Domain model

Every catalog entry has two independent attributes:

- `provenance`: `mutable` for a runtime-registered, registry-owned workflow;
  `immutable` for a project workflow, user workflow, or installed package.
- `activationState`: `active` or `deactivated`.

`mutable: Bool` remains the compact structured projection of provenance.
`temporary` and `adhoc` are not public registry-provenance terms. Existing
persisted or decoded `temporary: true` registry values are compatibility input
only and map to `provenance: mutable`; new registry output does not emit a
`temporary` field.

All workflow kinds retain the existing source facts: `scope`, `sourceKind`,
package metadata, workflow directory, diagnostics, and validity. Mutability is
not inferred from `sourceKind`: a mutable registry entry is still an authored
`workflow`, while project and user authored bundles are immutable because they
are externally owned.

A workflow origin identity is the canonical key for activation and mutation
checks. It includes normalized scope, source kind, provenance, catalog lookup
name, decoded workflow id when available, and canonical source locator. This
prevents a deactivation for one `foo` candidate from disabling a different
project, user, package, or mutable `foo`.
User-facing exact lookup may accept a workflow id and, when `originId` is
omitted, resolves one origin using the normal precedence and scope rules. An
`originId` addresses a shadowed lower-precedence origin. Mismatched or
non-unique canonical identity fails rather than mutating more than one origin.

Catalog projections expose at least:

```text
id/name, description, scope, sourceKind, provenance, mutable,
activationState, valid, workflowDirectory, package metadata, diagnostics
```

`name` is the nonempty lookup name from the catalog origin descriptor.
`workflowId` is the decoded definition id when available; an invalid entry that
cannot be decoded uses its descriptor lookup name as the stable fallback
`workflowId`. Valid entries normally have equal `name` and `workflowId`, but the
two fields remain explicit so filtering and diagnostics do not infer one from
the other. Description comes from the decoded workflow definition. Invalid
entries may have no description and remain listable with diagnostics.

GraphQL exposes the same behavioral fields but replaces filesystem locations
with an opaque `originId`. A local CLI renderer may include
`workflowDirectory`; the remote GraphQL projection never returns canonical
paths or unredacted path diagnostics.

### Effective instance lifetime compatibility

Effective instances created by per-run variable or node-patch overrides are an
instance-lifetime concept, not mutable workflow provenance. Their canonical
term becomes `ephemeral`:

- `WorkflowInstanceKind.temporary` becomes `WorkflowInstanceKind.ephemeral`;
- `temporaryIdentity(_:)` becomes `ephemeralIdentity(_:)`, retaining the
  existing stable `<base>+overrides` identity value;
- new runtime sessions, CLI/session projections, and GraphQL `instanceKind`
  values emit `ephemeral`, never `temporary`;
- decoding a historical Codable enum value or persisted session
  `instanceKind: "temporary"` maps to `.ephemeral`, and subsequent projections
  normalize it to `ephemeral`;
- the existing GraphQL field remains a `String` and is not removed or renamed,
  so existing query documents remain structurally compatible.

This compatibility decoder is limited to historical instance/session input and
does not make an ephemeral effective instance a mutable registry workflow.

## Storage and compatibility

The physical directory `~/.riela/temporary-workflows/` remains the canonical
mutable-workflow bundle root in this release. Keeping the legacy path avoids a
split-brain migration and guarantees that existing registered workflows remain
readable. It is an intentionally retained storage compatibility detail, not a
user-facing provenance term. New Swift types, help, output, errors, tests, and
documentation use mutable/immutable naming.

The existing `.registry-state` transaction layout, two-level lock ordering,
staging validation, digest verification, rollback, interruption recovery,
symlink rejection, and containment rules remain authoritative. Mutable
register, update, and delete operations preserve those mechanics while using
the expanded global order below.

Uniform activation is a non-invasive user-local overlay stored under:

```text
~/.riela/workflow-state/
  activation.json
  activation.lock
```

The versioned activation document maps origin identities to deactivated
records. Active is the default, so existing homes require no migration.
Records include the origin identity fields and update time; they never rewrite
immutable bundles. Updates take `activation.lock`, write and sync a complete
staged document under the same directory, then atomically replace the prior
document. A malformed or linked state file fails closed for mutation and
produces a catalog diagnostic rather than silently reactivating entries.
Records for missing origins may be retained for audit but do not create
catalog entries.

### Global coordination and lock order

Every Riela-owned registry read or mutation follows one global order:

```text
1. mutable-registry catalog.lock
2. workflow-state activation.lock
3. per-workflow locks in ascending canonical origin-id order
4. transaction or consolidation journal write/sync (data, never another lock)
```

The catalog and activation lock files are created through the same pinned-root,
non-symlink checks as existing registry state. No code may acquire an earlier
lock while retaining a later lock. Registration, update, delete, activation,
deactivation, and consolidation all enter through a coordinator that owns this
ordering; lower-level publication functions require a coordinator token and
must not reacquire locks. This prevents nested provider calls from deadlocking.
Per-workflow lock filenames use a SHA-256 digest of the canonical origin
identity, so equal workflow ids from different origins cannot share a lock and
untrusted identity text never becomes a path component.

Mutations retain all acquired locks from their final precondition check until
the journal is removed after commit or rollback. Consolidation acquires every
source lock plus the replacement-id lock in sorted order before publishing its
journal. Journal recovery runs at the start of a coordinated read or mutation.
After acquiring both global locks, recovery enumerates and validates journal
metadata, derives the sorted workflow-lock set, acquires it, then rereads the
journal and requires identical content before recovery. A changed, linked, or
malformed journal fails closed without mutating artifacts.

Registry-aware readers acquire `catalog.lock` and `activation.lock` while they
select origins and snapshot activation state. A reader that will load a mutable
bundle also takes its per-workflow lock before releasing either global lock and
creates the existing detached bundle snapshot. Catalog listing takes required
mutable-workflow locks in sorted order while constructing its descriptor
snapshot, then releases all locks before decoding and rendering. Consequently,
a read observes either the complete state before a consolidation or the
complete committed state after it; it cannot observe the replacement together
with unretired originals. Riela cannot serialize direct external edits to
project/user/package directories, which remain subject to existing validation
and digest checks.

Tests and embedded callers continue to resolve both roots through the injected
runtime home rather than the process `HOME` directly.

### Existing authored-workflow mutation boundary

The provenance change also governs existing write-capable workflow commands;
it is not limited to the new GraphQL CRUD surface. Project workflows, user
workflows, and installed packages are externally owned immutable origins.
Riela may read, validate, inspect, diff, snapshot, and prepare a proposed
change for them, but it must not rewrite or delete their bundle directories.

The concrete command behavior is:

- `workflow self-improve` may produce and review a proposal for an immutable
  origin, but applying that proposal fails with `IMMUTABLE_WORKFLOW` and directs
  the user to register a mutable copy;
- `workflow version` read-only history, snapshot, and diff operations remain
  available, while restore to an immutable origin fails with
  `IMMUTABLE_WORKFLOW`;
- self-improve apply and version restore for a mutable registry origin enter
  the same global coordinator as update/delete, validate the expected origin
  and digest while locked, mutate a detached bundle, and publish through the
  registry transaction path before releasing locks;
- every other Riela-owned path that can rewrite or remove a resolved workflow
  must use the shared provenance gate and coordinator. It may not infer
  mutability from `packageManifest == nil`, `sourceKind`, or a writable path.

Accordingly, the `sourceMutable` and `mutable` projections used by
`WorkflowSelfImproveVersioning.swift`, `WorkflowVersionCommands.swift`,
`WorkflowDirectoryTransaction.swift`, `LoopCommands.swift`,
`SessionCommands.swift`, and validation/inspection results derive from the
resolved origin provenance. Read-only operations do not acquire mutation
authority merely because an external directory is writable. There is no
automatic conversion of an immutable origin; registration creates the
separate mutable copy under the registry-owned root.

## Resolution and activation rules

Automatic precedence remains:

1. project workflow
2. user workflow
3. project package
4. user package
5. user mutable workflow from the legacy physical root

Catalog listing and exact inspection include active and deactivated entries.
Resolution for execution, continuation, event triggering, GraphQL execution,
workflow calls, and every other runnable path skips deactivated candidates.
A higher-precedence deactivated candidate does not shadow the next active
candidate. An exact execution request with no active candidate returns a typed
`WORKFLOW_DEACTIVATED` error that identifies the deactivated origin(s), rather
than a generic not-found result.

Validation, status, inspect, usage, and catalog operations resolve with an
explicit `includeDeactivated` read policy and therefore remain available.
Activation/deactivation also uses this read policy so a deactivated workflow
can be reactivated. Direct `--workflow-definition-dir` and inline inputs are
not catalog entries and cannot be persisted activation targets. When a direct
directory canonicalizes to an existing project, user, package, or mutable
catalog origin, execution reuses that origin identity and honors its activation
state. Otherwise the direct input is an explicit one-off immutable execution
that is active only for that invocation. This prevents a direct path from
bypassing deactivation of a known catalog origin without inventing an
unsupported `DIRECT` activation scope.

## CLI contract

The canonical registration command is:

```text
riela workflow register <path> --mutable [--overwrite]
  [--working-dir <dir>] [--output jsonl|json|text|table]
```

`--temporary` remains a deprecated alias for `--mutable` until the next major
CLI release. Removing it is a breaking-change milestone outside this work
package. Supplying both is a usage error. Help leads with `--mutable`, labels
the legacy alias deprecated until the next major release, and all results use
mutable terminology.

Catalog filtering uses:

```text
riela workflow list [query] [--scope project|user|auto]
  [--exclude-mutable] [--activation active|deactivated]
  [--provenance mutable|immutable]
  [--working-dir <dir>] [--output jsonl|json|text|table]
```

`--exclude-temporary` remains a deprecated alias for `--exclude-mutable` until
the same next-major-release milestone. Supplying both is a usage error. The
positional query becomes a case-insensitive partial match on workflow id/name
and description. Filters are conjunctive and apply before stable sorting.

Mutation commands are:

```text
riela workflow update <workflow-id> <path> [--scope auto|project|user]
  [--origin-id <opaque-id>] [--output ...]
riela workflow delete <workflow-id> [--scope auto|project|user]
  [--origin-id <opaque-id>] [--output ...]
riela workflow activate <workflow-id> [--scope auto|project|user]
  [--origin-id <opaque-id>] [--output ...]
riela workflow deactivate <workflow-id> [--scope auto|project|user]
  [--origin-id <opaque-id>] [--output ...]
riela workflow consolidate --source <workflow-id> --source <workflow-id>...
  [--scope auto|project|user]
  [--source-origin <workflow-id>=<opaque-id>]...
  --replacement <path> --retire deactivate|delete [--output ...]
```

`update` and `delete` reject immutable origins with the same typed error code
used by GraphQL. `activate` and `deactivate` accept either provenance.
Text/table columns are `PROVENANCE`, `MUTABLE`, and `ACTIVATION`; they never
render `temporary`, `adhoc`, or `standard`. JSON/JSONL use `provenance`,
`mutable`, and `activationState`.

## Shared service boundary

Registry semantics must have one implementation used by CLI and GraphQL. The
module dependency remains acyclic:

- `RielaCore` owns public domain DTOs, provenance/activation enums, origin
  identity, filters, and typed registry error codes.
- `RielaCLI` owns the filesystem-backed catalog/registry implementation and
  supplies a provider adapter.
- `RielaGraphQL` owns additive GraphQL DTOs, provider protocols, schema, and a
  registry document executor; it does not import `RielaCLI`.
- CLI composition and an enabled embedding-server composition inject the same
  filesystem provider implementation into the GraphQL executor.
  `DeterministicServerRouteHandler` continues to depend only on the generic
  `GraphQLDocumentExecuting` boundary and never accepts a
  workflow-registry-specific configuration.

The provider supports list, fetch, register, update, delete, set activation,
and consolidate. CLI commands invoke the provider rather than duplicating
filesystem behavior. One authorizing composite document executor implements
the server's generic protocol. It owns the shared document parser and routes
parsed root fields to workflow-registry, note, or existing control-plane
handlers. Those domain handlers consume the resolved operation representation;
they do not implement the raw-document protocol or parse the document again.
Duplicate or unsupported routing is rejected deterministically.

Local `riela graphql document` composition marks its request as locally trusted
through an in-process transport context that cannot be supplied by GraphQL
JSON input. It is authorized by the invoking OS user and may use local bundle
paths. Remote server execution is a separate, default-disabled capability
governed by the server policy below.

## Server enablement and authorization

Workflow-registry GraphQL execution is disabled by default even though the SDL
is always published. This work package does not add a
`--workflow-registry-api` serve flag or a new credential store. The application
composition root always injects the authorizing composite executor into the
generic server handler. All shipped Riela CLI serving paths construct that
executor without registry configuration. A selected operation containing any
registry root then returns `WORKFLOW_REGISTRY_UNAVAILABLE` before any note,
control-plane, or registry root field executes.

An embedding host may opt in by constructing the composite executor with one
`WorkflowRegistryGraphQLServerConfiguration`. Its initializer requires three
non-optional dependencies: a workflow-registry provider, a
`WorkflowRegistryGraphQLAuthorizing` implementation, and a managed-reference
resolver. This configuration belongs to the composition/executor layer, not
the server handler. There is no partially enabled state; provider or authorizer
injection alone does not enable registry fields.

Credential issuance, secure storage, rotation, revocation, and capability
assignment belong to the embedding host's existing identity system. This
package neither accepts a raw configured bearer secret nor persists registry
credentials. The injected authorizer is the sole credential-validation
boundary and must return `readRegistry`/`mutateRegistry` capabilities for the
validated principal. Integration tests use an injected deterministic
authorizer; production hosts must supply their own before enabling the remote
surface. A future user-facing serve flag requires a separate credential-system
design and is intentionally outside this work package.

For a server request, the handler extracts the bearer credential into a
request-only transport credential on `GraphQLDocumentRequest`; it does not
authenticate or interpret registry capabilities. The credential is not
Codable, is never copied into the request environment, and is excluded from
telemetry, diagnostics, errors, and debug rendering. Only the authorizing
composite executor may read it. The raw credential is passed to the configured
domain authorizers and is never forwarded to a domain executor or provider.

The composite resolves the selected GraphQL operation and its root fields once
using the shared document parser, honoring `operationName`, aliases, fragments,
and multi-operation documents. From that representation it derives every
required domain authorization before dispatch. The registry authorizer
validates the credential and returns an ephemeral verified principal with
explicit `readRegistry` and `mutateRegistry` capabilities. Registry queries
require `readRegistry`; every registry mutation requires `mutateRegistry`.
Missing or invalid credentials return `UNAUTHENTICATED`, and insufficient
capability returns `FORBIDDEN`. The existing note authenticator is adapted into
the same pre-dispatch gate but does not grant registry capability. Note REST
routes retain their existing handler-level authentication.

After every required gate succeeds, the composite creates an internal resolved
authorization context containing only verified principal identifiers and
capabilities, discards access to the raw credential for the remainder of
execution, and dispatches the already parsed fields. A document mixing note and
registry roots must satisfy both gates; no field executes when either gate
rejects or registry configuration is absent. Tests must prove query/mutation
separation, default denial, invalid-token denial, insufficient-capability
denial, mixed-domain denial, credential non-propagation, and operation-name
selection without authentication bypass.

## GraphQL contract

The schema extension is additive. Existing session, manager, instance, and
note fields remain source-compatible.

The complete registry SDL is:

```graphql
enum WorkflowRegistryScope { AUTO PROJECT USER }
enum WorkflowSourceKind { WORKFLOW PACKAGE }
enum WorkflowProvenance { MUTABLE IMMUTABLE }
enum WorkflowActivationState { ACTIVE DEACTIVATED }
enum WorkflowRetireMode { DEACTIVATE DELETE }
enum WorkflowBundleReferenceKind { LOCAL_PATH MANAGED_REFERENCE }
enum WorkflowRegistryErrorCode {
  WORKFLOW_NOT_FOUND
  WORKFLOW_DEACTIVATED
  IMMUTABLE_WORKFLOW
  DUPLICATE_WORKFLOW
  INVALID_WORKFLOW
  INVALID_ORIGIN
  INVALID_FILTER
  INVALID_RETIRE_MODE
  UNSUPPORTED_BUNDLE_REFERENCE
  WORKFLOW_REGISTRY_UNAVAILABLE
  UNAUTHENTICATED
  FORBIDDEN
  REGISTRY_CONFLICT
  REGISTRY_IO_FAILURE
}

input WorkflowFilter {
  query: String
  description: String
  scope: WorkflowRegistryScope
  sourceKind: WorkflowSourceKind
  provenance: WorkflowProvenance
  mutable: Boolean
  activationState: WorkflowActivationState
}

input WorkflowTargetInput {
  workflowId: String!
  scope: WorkflowRegistryScope = AUTO
  originId: String
}

input WorkflowBundleReferenceInput {
  kind: WorkflowBundleReferenceKind!
  value: String!
}

input RegisterMutableWorkflowInput {
  bundle: WorkflowBundleReferenceInput!
  overwrite: Boolean = false
  activationState: WorkflowActivationState
}

input UpdateMutableWorkflowInput {
  target: WorkflowTargetInput!
  bundle: WorkflowBundleReferenceInput!
}

input DeleteMutableWorkflowInput { target: WorkflowTargetInput! }
input SetWorkflowActivationInput { target: WorkflowTargetInput! }

input ConsolidateWorkflowsInput {
  sources: [WorkflowTargetInput!]!
  replacement: WorkflowBundleReferenceInput!
  retireMode: WorkflowRetireMode!
  activateReplacement: Boolean = true
}

type WorkflowRegistryDiagnostic {
  severity: String!
  # Relative logical bundle field/path only; never a canonical server path.
  path: String
  message: String!
}

type WorkflowRegistryEntry {
  originId: String!
  workflowId: String!
  name: String!
  description: String
  scope: WorkflowRegistryScope!
  sourceKind: WorkflowSourceKind!
  provenance: WorkflowProvenance!
  mutable: Boolean!
  activationState: WorkflowActivationState!
  valid: Boolean!
  packageName: String
  packageVersion: String
  diagnostics: [WorkflowRegistryDiagnostic!]!
}

type WorkflowRegistryError {
  code: WorkflowRegistryErrorCode!
  message: String!
  workflowId: String
  originId: String
}

type WorkflowListPayload {
  workflows: [WorkflowRegistryEntry!]!
  errors: [WorkflowRegistryError!]!
}

type WorkflowQueryPayload {
  workflow: WorkflowRegistryEntry
  errors: [WorkflowRegistryError!]!
}

type WorkflowMutationPayload {
  accepted: Boolean!
  overwritten: Boolean!
  workflow: WorkflowRegistryEntry
  retiredWorkflows: [WorkflowRegistryEntry!]!
  errors: [WorkflowRegistryError!]!
}

extend type Query {
  workflows(filter: WorkflowFilter): WorkflowListPayload!
  workflow(target: WorkflowTargetInput!): WorkflowQueryPayload!
}

extend type Mutation {
  registerMutableWorkflow(input: RegisterMutableWorkflowInput!): WorkflowMutationPayload!
  updateMutableWorkflow(input: UpdateMutableWorkflowInput!): WorkflowMutationPayload!
  deleteMutableWorkflow(input: DeleteMutableWorkflowInput!): WorkflowMutationPayload!
  activateWorkflow(input: SetWorkflowActivationInput!): WorkflowMutationPayload!
  deactivateWorkflow(input: SetWorkflowActivationInput!): WorkflowMutationPayload!
  consolidateWorkflows(input: ConsolidateWorkflowsInput!): WorkflowMutationPayload!
}
```

`WorkflowFilter` supports `query`, `description`, `provenance`, `mutable`,
`activationState`, and `scope`. `query` partially matches id/name;
`description` partially matches description. Both are case-insensitive and,
when both are supplied, both must match. `workflows(filter:)` enumerates every
eligible origin and never collapses results by resolution precedence. Thus an
`AUTO` list is the union of project workflows, user workflows, project
packages, user packages, and mutable-registry entries for the current working
directory, including every same-id origin. `PROJECT` and `USER` constrain that
enumeration to their eligible roots. Listing returns invalid and deactivated
entries unless filters exclude them.

`WorkflowRegistryEntry.name` is the catalog descriptor lookup name and
`workflowId` follows the decoded-id-or-descriptor-fallback rule from the domain
model. `description` is nullable and is `null` when no definition description
can be decoded. A `description` filter matches only non-null descriptions;
invalid entries with `description: null` remain in unfiltered results but do
not match a nonempty description filter. The id/name `query` still evaluates
against their stable descriptor-derived fields.

Precedence applies only to an exact `workflow(target:)`, execution, or mutation
target when `originId` is omitted. That lookup selects the normal highest-
precedence exact origin; a caller uses an `originId` returned by listing to
address a shadowed lower-precedence origin. A supplied `originId` must match the
requested workflow id and scope. A mismatched, missing, malformed, or
non-unique canonical origin returns `INVALID_ORIGIN`; positional catalog order
never chooses a target. Fetch remains inspectable regardless of activation. If
both `provenance` and `mutable` filters are supplied they must agree, otherwise
the query returns `INVALID_FILTER`.

`WorkflowBundleReferenceInput` has exactly one interpretation selected by
`kind`. The local CLI executor accepts `LOCAL_PATH`, resolves `value` relative
to `--working-dir`, and applies the existing pinned-root inventory rules. A
remote server rejects `LOCAL_PATH`. It accepts `MANAGED_REFERENCE` only when
its provider resolves the opaque value inside an implementation-controlled
ingress root using the same containment and non-symlink checks. The local CLI
rejects `MANAGED_REFERENCE` unless a managed-reference resolver was explicitly
injected. Empty values and unsupported kinds return
`UNSUPPORTED_BUNDLE_REFERENCE`.

Mutation payloads contain `accepted`, `overwritten`, `workflow`,
`retiredWorkflows`, and `errors: [WorkflowRegistryError!]!`. `overwritten` is
meaningful for registration and is `false` for other mutations. Errors contain
stable `code`, `message`, and optional `workflowId`/`originId`; the SDL enum
above is authoritative.

Expected domain failures return a typed payload with `accepted: false`; syntax,
or malformed GraphQL requests use standard GraphQL errors. Authentication and
authorization failures use GraphQL errors whose `extensions.code` is
`UNAUTHENTICATED` or `FORBIDDEN`.
The CLI maps the same codes to nonzero usage/failure exits without discarding
the code in structured output.

CLI-to-GraphQL/provider mapping is fixed:

| CLI operation | Provider/GraphQL input |
| --- | --- |
| `workflow register PATH --mutable [--overwrite]` | `RegisterMutableWorkflowInput(bundle: LOCAL_PATH(PATH), overwrite, activationState: null)` |
| `workflow update ID PATH [--scope S] [--origin-id O]` | `UpdateMutableWorkflowInput(target: ID/S/O, bundle: LOCAL_PATH(PATH))` |
| `workflow delete ID [--scope S] [--origin-id O]` | `DeleteMutableWorkflowInput(target: ID/S/O)` |
| `workflow activate/deactivate ID [--scope S] [--origin-id O]` | `SetWorkflowActivationInput(target: ID/S/O)` |
| `workflow consolidate --source ID... --replacement PATH --retire MODE [--source-origin ID=O]...` | `ConsolidateWorkflowsInput(sources, replacement: LOCAL_PATH(PATH), retireMode, activateReplacement: true)` |

`--scope auto|project|user` maps to the corresponding registry enum.
Ambiguous CLI targets report `INVALID_ORIGIN` and direct the user to list
`originId` values and retry with `--origin-id`; positional order never selects
an origin implicitly.

## CRUD and consolidation transactions

Register and update fully inventory, copy, resolve, and validate a private
staging bundle before publication. The staged definition's `workflowId` is the
registry key; it is never inferred from the input path.

Registration collision rules apply to the canonical mutable registry origin,
not every immutable origin visible from the current working directory:

- no mutable entry with the staged id: create it; `overwrite: true` is allowed
  but reports `overwritten: false`;
- mutable entry exists and `overwrite: false`: reject with
  `DUPLICATE_WORKFLOW` without changing either entry;
- mutable entry exists and `overwrite: true`: replace that exact mutable entry
  transactionally and report `overwritten: true`;
- malformed state implying more than one canonical mutable entry: fail with
  `REGISTRY_CONFLICT` and preserve artifacts.

For a fresh registration, omitted `activationState` means `ACTIVE`. For an
overwrite, omission preserves the existing activation state; an explicitly
supplied value applies atomically with publication. The CLI does not expose an
activation option on register, so it creates active entries and preserves state
on overwrite.

An immutable project, user, or package origin with the same id never becomes an
overwrite target and is never changed. The mutable registration may coexist
because the registry is user-global while project catalogs vary by working
directory. When the current catalog contains a higher-precedence same-id
origin, successful registration returns a non-error diagnostic that the new
mutable entry is shadowed for automatic resolution; exact `originId` reads
remain available. `IMMUTABLE_WORKFLOW` is used whenever a write-capable command
actually resolves an immutable target, including update, delete, self-improve
apply, and version restore.

Update resolves its target with `includeDeactivated`, verifies mutable
provenance, and requires the staged definition's `workflowId` to equal both the
target `workflowId` and resolved origin id component. A mismatch returns
`INVALID_WORKFLOW` before publication; update never renames a registry entry.
It preserves the target's activation state. Delete resolves the target the same
way, rejects immutable provenance, and uses a recoverable registry transaction
rather than direct recursive removal. Successful mutable deletion removes any
activation record for that exact origin.

Consolidation input contains at least two unique source origin identities, one
replacement bundle/reference, and explicit `retireMode: DEACTIVATE|DELETE`.
The operation holds the catalog barrier, activation lock, source locks, and
replacement lock in the global order through commit or rollback. It proceeds
as follows:

1. Resolve all sources including deactivated entries; reject duplicates or
   missing/ambiguous origins.
2. For `DELETE`, reject the entire request if any source is immutable. For
   `DEACTIVATE`, either provenance is allowed.
3. Stage, load, and validate the replacement with the existing full workflow
   and node-payload validation. Require a new workflow id distinct from every
   source and every existing catalog entry.
4. Persist one versioned consolidation journal containing source snapshots,
   replacement digest, retire mode, and phase.
5. Publish the replacement as an active mutable workflow.
6. Deactivate sources atomically in one activation-overlay replacement, or move
   mutable source directories into transaction-owned backups.
7. Verify the final catalog state, then remove backups and the journal.

Before step 5, failure changes nothing. After step 5, any failure rolls back
the activation overlay or source backups and removes the replacement. Process
interruption is recovered from the journal under the same locks. Recovery must
prove either the complete prior state or complete consolidated state; ambiguous
state fails closed and preserves artifacts. Thus callers never observe a
successful replacement with unretired originals as the committed result.

## Validation and security boundaries

All existing input inventory, regular-file, symlink, special-file, path
containment, safe identifier, referenced asset, digest, fsync, and recovery
checks remain required. New operations also enforce:

- mutation identity is resolved before checking provenance;
- update replacement ids must match the resolved mutable target;
- registration overwrite can address only the canonical mutable-registry
  origin with the staged id;
- immutable bundles are never rewritten or deleted;
- activation records cannot escape or redirect the state root;
- filters are bounded, deterministic, and do not scan file contents;
- GraphQL inputs reject unknown enum values, missing required fields,
  duplicate source ids, and invalid selection sets;
- server authentication and authorization gates apply to registry mutations;
- diagnostics do not expose untrusted server filesystem paths to remote clients;
- no user-controlled path is recursively removed without a canonical,
  registry-owned target and matching transaction record.

## Rollout and documentation constraints

The rollout is read-compatible with existing `~/.riela/temporary-workflows/`
contents and active-by-default for every existing origin. Deprecated CLI
aliases are accepted but never rendered and remain supported until the next
major CLI release; their removal is explicitly outside this work package.
There is no compatibility promise for the old Swift
`WorkflowTemporaryRegistry*` API or `temporary` output field; this feature
explicitly replaces that internal and public terminology. GraphQL additions do
not rename or remove existing fields. Historical effective-instance and
session values containing `instanceKind: "temporary"` remain decodable but are
rendered as `ephemeral` after decoding.

Update CLI help and user documentation to name mutable/immutable provenance,
explain the retained legacy storage path, document aliases and their deprecation
window, list typed error codes, and state that deactivation blocks execution
but not inspection.

## Acceptance mapping and verification

| Issue requirement | Design sections |
| --- | --- |
| Mutable/immutable naming and legacy storage readability | Domain model; Storage and compatibility; CLI contract |
| Uniform activation and execution exclusion | Resolution and activation rules; Shared service boundary |
| GraphQL CRUD, fetch, and filters | GraphQL contract; CRUD and consolidation transactions |
| Typed immutable mutation rejection | CLI contract; GraphQL contract; Validation and security boundaries |
| Atomic consolidation with deactivate/delete | CRUD and consolidation transactions |
| Existing authored mutation paths honor provenance | Existing authored-workflow mutation boundary |
| Internal effective-instance terminology compatibility | Effective instance lifetime compatibility |
| Tests and non-regression | This section |

Required automated verification:

```bash
swift build
swift test --filter WorkflowMutableRegistryTests
swift test --filter WorkflowCommandCatalogTests
swift test --filter WorkflowCommandScopedResolutionTests
swift test --filter WorkflowActivationTests
swift test --filter WorkflowConsolidationTests
swift test --filter GraphQLWorkflowRegistryTests
swift test --filter ServerContractsTests
```

Required isolated smoke coverage under repository-root `tmp/`:

```bash
HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow register "$PWD/tmp/mutable-workflow-registry-smoke/workflow" --mutable --output jsonl
HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow list partial-description --output jsonl
HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela graphql document --query-file "$PWD/tmp/mutable-workflow-registry-smoke/update.graphql" --variables "$PWD/tmp/mutable-workflow-registry-smoke/update-variables.json" --output jsonl
HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow deactivate mutable-smoke --output jsonl
HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow inspect mutable-smoke --output jsonl
HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela workflow run mutable-smoke --mock-scenario "$PWD/tmp/mutable-workflow-registry-smoke/mock.json" --output jsonl
HOME="$PWD/tmp/mutable-workflow-registry-smoke/home" .build/debug/riela graphql document --query-file "$PWD/tmp/mutable-workflow-registry-smoke/delete.graphql" --variables "$PWD/tmp/mutable-workflow-registry-smoke/delete-variables.json" --output jsonl
```

Tests must cover CRUD, partial name/id and description filters, every
provenance/activation filter, immutable rejection through CLI and GraphQL,
activation of both provenances, execution exclusion across every resolver entry
point, inspection of deactivated entries, legacy-root discovery, deprecated
flag aliases, consolidation validation failure, both retirement modes,
interruption recovery, and existing transaction security cases. Catalog and
GraphQL list tests must include same-id entries at multiple precedence levels
and assert that every eligible origin is returned. Self-improve apply and
version restore tests must reject project/user/package origins, continue to
support read-only proposal/history operations, and coordinate mutable-registry
publication. Instance/session tests must decode historical `temporary`, emit
`ephemeral`, and preserve the `<base>+overrides` identity.

The documented unrelated baseline failures remain excluded unless evidence
connects them to this change: two `SourceDeletionReadinessTests` failures, the
`DaemonWorkflowNodePatchTests` event-source-restart flake, and the occasional
agent-VM interleaved-submit flake.

## Review decision and residual risks

The author self-review findings are closed in this revision:

- **H1 closed:** remote registry GraphQL is default-disabled, requires one
  complete configuration at the composite-executor composition boundary,
  separates read/mutate capabilities, and gates the fully resolved operation
  before any field executes.
- **M1 closed:** catalog, activation, sorted origin locks, and journal I/O now
  have one mandatory order and defined reader/mutator holding periods.
- **M2 closed:** the registry SDL now defines every enum, input, output, error,
  bundle-reference rule, target-disambiguation rule, and CLI mapping.
- **M3 closed:** no unusable serve flag is added; remote enablement is limited
  to a complete host-injected provider/authorizer/reference-resolver
  configuration, with credential lifecycle owned by that host.
- **M4 closed:** direct inputs are not persisted activation targets, but a
  direct path matching a catalog origin reuses that origin's activation state.
- **M5 closed:** register/overwrite collisions and update workflow-id equality
  now have deterministic outcomes and typed failures.
- **M6 closed:** local GraphQL smoke verification uses the existing
  `--query-file` and `--variables` parser contract; it does not misuse the
  unrelated `--message-file` option.
- **Independent M1 closed:** self-improve apply, version restore, and every
  other bundle-writing path now use provenance-based immutable rejection and
  the shared mutable-registry coordinator.
- **Independent M2 closed:** effective per-run instances use `ephemeral`; legacy
  Codable/session `temporary` input remains readable and normalizes on output.
- **Independent M3 closed:** list queries enumerate all eligible origins,
  including same-id duplicates; precedence is confined to exact target lookup
  without an `originId`.
- **Independent H4 closed:** the server handler retains only the generic
  document-executor dependency. The authorizing composite owns the complete
  optional registry configuration, parses once, validates every required
  domain gate, passes only verified capability context to domain handlers, and
  returns `WORKFLOW_REGISTRY_UNAVAILABLE` before dispatch when configuration is
  absent.
- **Independent M4 closed:** `name` is the stable catalog lookup name,
  `workflowId` has a descriptor fallback for invalid entries, and GraphQL
  `description` is nullable with deterministic filtering behavior.
- **Independent L1 closed:** deprecated temporary-named flags remain aliases
  until the next major CLI release; removal is not part of this work package.

Design decision: **revised after independent design review and ready for
re-review, with adversarial implementation review required**. There are no
unresolved user decisions and no `design-docs/user-qa/` artifact is needed.

Review must verify that all execution paths honor activation, GraphQL remains
additive, module dependencies stay acyclic, immutable checks occur after exact
origin resolution, consolidation rollback is provable, legacy storage is read
without duplicate discovery, and deprecated terms do not leak into new output.
Residual risks are incomplete resolver coverage, partial consolidation after
process interruption, activation-key drift after a bundle moves, schema/executor
divergence, compatibility regressions for scripted CLI callers, and accidental
weakening of the existing registry's filesystem defenses.
