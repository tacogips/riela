# Web Workflow Observability and Management

## Status and issue contract

This is the proposed design for one issue-resolution work package. The latest
Step 3 revision findings are addressed below and await independent re-review.

- Workflow mode: `issue-resolution`
- Issue title: **Web workflow observability & management UX: run detail +
  step logs, auto-refresh polling, config UX fixes, workflow definition
  inspector + mutable registry management**
- GitHub issue URL, repository, and issue number: not supplied
- Local issue reference:
  `docs/briefs/web-workflow-ui-2026-07-29.md`
- Workflow execution:
  `codex-design-and-implement-review-loop-session-19`
- Branch: `feat/web-workflow-ui-improvements`
- Review mode: `standard`
- Risk level: `normal`
- Required review: adversarial because registry deletion and activation mutate
  executable workflow state
- Codex-agent references: none

The brief is binding. Run detail, polling, configuration fixes, and workflow
definition/registry management remain one cohesive feature. They do not fan
out into independent design or implementation packages.

## Code-verified findings

The brief's current-state facts were spot-checked against the current branch.

1. `web/src/App.tsx` uses a view signal and hides every non-Notes view in
   `cli-serve` mode.
2. `web/src/views/LogsView.tsx` reads execution summaries from
   `GET /api/v1/instances/{id}/executions`; it has no detail selection or
   polling.
3. `Sources/RielaApp/RielaAppWebAPI.swift` already loads those summaries from
   the authoritative runtime persistence store through `WorkflowViewerLoader`.
4. `GraphQLWorkflowSessionDTO` contains step executions, logs, messages, loop
   evidence, gates, and recovery data, but RielaApp does not currently execute
   `workflowSession` GraphQL documents.
5. `Sources/RielaApp/RielaAppWebNoteGraphQL.swift` executes Notes documents
   only. Its fallback returns a delegated placeholder, so the web cannot use
   the registry operations merely by adding a frontend client.
6. `Sources/RielaGraphQL/WorkflowRegistryGraphQL.swift` defines the existing
   `workflows`, `workflow`, `registerMutableWorkflow`,
   `updateMutableWorkflow`, `deleteMutableWorkflow`, `activateWorkflow`, and
   `deactivateWorkflow` operations. The current entry projection is metadata
   only, and mutation inputs accept bundle references rather than pasted
   workflow JSON.
7. `RielaAppDaemonWorkflowPreference.nodePatches` already contains typed
   `executionBackend`, `model`, and `effort` values. The web projection emits
   only `nodePatchCount`.
8. RielaApp's displayed `daemonWorkflowSources` can include configured
   directories and repositories that are not guaranteed to be represented by
   the CLI registry catalog. The existing web projection exposes the daemon
   source `id` but no registry `originId`, so workflow-id-only GraphQL lookup
   cannot safely identify the displayed source when candidates are shadowed.

## Scope

The work adds:

- run-detail navigation and a real persisted-session projection;
- visibility-aware polling for Instances, Run logs, and run detail;
- inline workflow-variable JSON validation and read-only node-patch details;
- read-only inspection for every discovered workflow definition;
- mutable-registry list, paste-register, edit, activate/deactivate, and
  confirmed delete behavior.

The work does not add run control, `consolidateWorkflows`, WebSocket/SSE
transport, package management, native-app behavior, a router, a visual workflow
builder, or new frontend dependencies. It does not modify
`.riela/workflows` fixtures.

## Transport decisions

### Run detail: one REST projection

Run detail uses one new REST projection under the existing instance execution
resource:

```text
GET /api/v1/instances/{encoded-instance-id}/executions/{encoded-session-id}
```

This is preferred over `workflowSession` GraphQL for this surface because:

- the session list is already REST and already resolves the correct
  instance-specific workflow directory and runtime store;
- RielaApp does not currently expose a workflow-session GraphQL document
  executor;
- a nested instance route lets the server prove that the requested session
  belongs to the selected instance's workflow before returning details; and
- it avoids building two competing run-data paths.

The endpoint loads the persisted snapshot used by the existing viewer and
projects bounded, display-safe data. It returns:

- session id, workflow id, status, current/last-completed step, failure
  information, and update time;
- step execution id, step/node id, attempt, backend, status, start/end time,
  duration, redacted failure reason, and bounded recent backend-event
  summaries;
- redacted session diagnostics and bounded persisted log summaries;
- communication routing metadata needed to associate step inbox/outbox
  evidence, without exposing unrelated filesystem paths or credentials;
- loop evidence summary, gate decisions/findings, and recovery lineage when
  present; and
- explicit truncation flags for every bounded collection.

Raw LLM transcript content is not returned by this web projection. It is not
required by the brief and can contain secrets. Step logs and gate/loop evidence
remain available as structured, redacted summaries without expanding the
dashboard's data-exposure boundary. Missing sessions, workflow mismatches, and
unsafe encoded identifiers fail closed with the existing REST error envelope.

#### Web projection bounds and redaction

Run detail, discovered definitions, and registry definitions share one
server-side bounds-and-redaction policy, but they use distinct schema-aware
projection modes. No mode directly encodes a persisted runtime object or raw
`workflow.json`. The policy applies these limits before JSON encoding:

| Value | Limit |
| --- | ---: |
| Serialized run-detail response | 1 MiB |
| Serialized definition JSON | 512 KiB |
| Step executions | 256 |
| Recent backend events per step | 50 |
| Session log entries | 200 |
| Session diagnostics | 100 |
| Communication routing records | 200 |
| Loop gates | 100 |
| Findings or evidence references per gate | 50 |
| Recovery child-session ids | 100 |
| Definition steps, nodes, or transitions | 500 each |
| Identifier, enum, tool name, or relative-path string | 256 Unicode scalars |
| Log, diagnostic, failure, or finding summary | 2,048 Unicode scalars |

Collections are sorted by their persisted order, keep the newest entries where
recency is meaningful, and expose `totalCount` and `truncated` beside every
bounded collection. Strings expose a field-level `truncated` marker when cut.
If the 1 MiB response cap would still be exceeded, the projector removes oldest
log/event summaries first, then evidence references, and returns a top-level
`truncated: true`; it never falls back to raw content.

Backend events are an allowlist projection, not direct encoding of
`WorkflowViewerBackendEvent`:

- every included event may expose only sequence, timestamp, event type, channel,
  and tool name;
- `assistant` and `thinking` content is never returned;
- `tool` content, arguments, output, metadata, and environment values are never
  returned;
- `usage` exposes only numeric token/count fields; and
- `lifecycle` may expose a summary only when it is synthesized from status,
  event type, and timestamps. Persisted free-form `content` is never copied.

Persisted log messages, diagnostics, failure reasons, validation findings, and
gate findings pass through the same fail-closed redactor. It replaces absolute
paths outside the selected workflow with `<path>`, converts contained paths to
workflow-relative paths, removes bearer/authorization values, private-key
blocks, URL user-info, and values assigned to case-insensitive credential keys
such as `token`, `secret`, `password`, `apiKey`, and `accessKey`. A string that
cannot be parsed or safely redacted is replaced with `<redacted>` rather than
returned verbatim. Communication payloads, artifact contents, environment
objects, instance variables, raw command lines, and raw LLM messages are never
part of the run-detail DTO.

Definition responses never return raw `workflow.json`. They are limited to the
validated `workflow.json` object and never inline node files, prompt files,
environment files, or other bundle content, but they additionally apply one of
these schema-aware modes:

- The discovered-definition display projection exposes structural metadata
  needed by the read-only inspector: workflow identity and description,
  step/node/transition ids and relationships, roles, source references,
  policy enums, numeric limits, and validation state. Sensitive leaves are
  replaced with the fixed JSON string `<redacted>`. No retain handle is issued
  because this surface cannot update the definition.
- The mutable-definition edit projection exposes the same structure, but each
  sensitive persisted leaf is replaced with
  `{"$rielaRetain":"<opaque-handle>"}`. The authenticated handle is bound to
  the exact user mutable `originId`, definition revision, JSON Pointer,
  persisted-value digest, and verified principal. It contains no reversible
  value and cannot be moved to another field, origin, revision, or caller.
- Sensitive leaves include literal environment binding values,
  credential-named values, prompt/instruction/system/user content, command
  argv or shell text, webhook addresses or credentials, and free-form add-on
  inputs/configuration not explicitly classified as display-safe. Unknown
  definition fields and unknown add-on configuration fail closed as sensitive.
- Identifiers, enum names, booleans, numeric limits, relative bundle
  references, node/step relationships, and other explicitly allowlisted
  structural values remain visible. A field that cannot be classified is
  redacted rather than copied.
- Every allowlisted free-form display string, including a description, still
  passes through the path and credential redactor. If it cannot be safely
  redacted, the projector emits `<redacted>`.

For a mutable update, the server first checks
`expectedDefinitionRevision` under the coordinated registry locks. It then
resolves every unchanged retain handle from the current persisted definition
at its bound JSON Pointer before staging. An unknown, moved, replayed, or
wrong-principal handle fails with `INVALID_WORKFLOW`; a revision mismatch fails
with `REGISTRY_CONFLICT` before handle resolution or staging. Replacing a
placeholder with a new literal intentionally replaces that value. The server
validates the reconstituted definition, but its mutation response contains a
fresh edit projection and never echoes submitted or persisted sensitive
values. Paste-registration accepts the user's local JSON but rejects retain
handles and likewise never echoes sensitive input.

Definition and registry diagnostics follow the same path and credential
redaction rules.

### Discovered definition inspector: one source-scoped REST projection

Read-only inspection for the workflows already displayed by RielaApp uses one
new REST projection:

```text
GET /api/v1/workflows/sources/{encoded-source-id}/definition
```

The server percent-decodes the source id exactly once and resolves it by exact
match against the active profile's `daemonWorkflowSources`. It does not
reinterpret the id as a path and does not fall back to workflow-id lookup.
This guarantees that a configured directory/repository candidate and a
shadowed candidate with the same workflow id cannot be confused.

The server loads and validates `workflow.json` from the matched candidate's
internally held workflow directory and returns:

- source id, workflow id, display name, scope, and source kind;
- the bounded discovered-definition display projection, never raw definition
  JSON;
- a step/node/transition summary;
- a content-derived definition revision; and
- bounded, path-redacted validation diagnostics.

The source list remains `GET /api/v1/workflows/sources`; the definition
projection is fetched only when a row is selected. No filesystem location is
returned. Missing or stale source ids return the existing REST 404 envelope
and offer Refresh in the inspector.

This REST projection is the sole definition source for the discovered-workflow
inspector. It deliberately does not list or mutate the mutable registry.

### Mutable registry: existing GraphQL operation names

Mutable-registry listing, definition editing, and state management use the
existing GraphQL `workflows`/`workflow` queries and the five existing registry
mutation names.
The RielaApp `/graphql` composition must route these operations to a real local
registry provider alongside Notes. It must not return the current delegated
placeholder for the registry operations.

#### Registry root, scope, and provider lifetime

The web mutable-registry surface is the existing user-scoped mutable registry,
whose current persisted root is the canonical home-owned
`~/.riela/temporary-workflows` managed by `WorkflowMutableRegistry`. It is
user-global by the accepted mutable-registry contract; switching the active
RielaApp profile does not create or select another mutable-registry root.
Active-profile workflow and package roots remain discovered-source inputs only
and are never substituted for the mutable-registry root.

RielaApp constructs a request-scoped registry provider only after the web
security gate succeeds. The provider captures:

- the canonical home-owned mutable-registry root resolved by the shared
  registry service;
- the active profile name for response-generation/stale-profile guards, not for
  filesystem-root selection; and
- a fixed policy permitting only user-scope, mutable-provenance operations.

The provider does not use `FileManager.default.currentDirectoryPath`, an
instance working directory, a daemon source directory, or any browser-supplied
path. `workflows` requires `provenance: MUTABLE` (or `mutable: true`) and returns
only user-scope mutable entries. `workflow` and every mutation require
`scope: USER` plus an exact `originId`; `AUTO`, `PROJECT`, missing origins, and
immutable origins fail with `INVALID_ORIGIN` or `IMMUTABLE_WORKFLOW` before
filesystem mutation. Registration always creates a user-scope mutable entry.
The discovered-definition REST inspector remains the only web path for
profile-scoped immutable definitions.

If the shared service cannot resolve and pin the canonical home registry root,
the root escapes the expected home-owned `.riela` container, or the active
profile changes before a response is committed, the request fails closed with
`WORKFLOW_REGISTRY_UNAVAILABLE` or is discarded by the client generation
guard. No provider instance or verified principal is cached across requests.

#### RielaApp local-web authorization bridge

Registry GraphQL remains protected by the existing
`WorkflowRegistryGraphQLAuthorizing` capability model. A browser request is not
locally trusted merely because it reaches loopback or carries a client-supplied
header. The authorization flow is:

1. `RielaAppWebRouter` applies `securityRejection(for:)` before any GraphQL
   parsing or provider access. A GraphQL POST must have the exact configured
   loopback Host, same-origin Origin, current `X-Riela-CSRF` token, and JSON
   content type.
2. Only after that gate succeeds, a RielaApp-owned adapter attaches a
   server-created verified principal to the internal GraphQL request. The
   principal id identifies the local RielaApp web session and its capability set
   is exactly `readRegistry` and `mutateRegistry`.
3. `CompositeGraphQLDocumentExecutor` performs its existing per-operation
   preflight. `workflows` and `workflow` require `readRegistry`; the five
   registry mutations require `mutateRegistry`. The selected operation must
   have a capability subset of the verified principal before the provider is
   invoked.
4. The verified principal is an in-process value. It cannot be supplied through
   an HTTP header, GraphQL variable, cookie, or bearer value. The generic
   RielaServer GraphQL route, rejected RielaApp requests, and executor calls
   without this server-owned provenance remain untrusted and follow the existing
   bearer-authorizer path or fail closed.
5. Notes roots retain their current RielaApp behavior. Mixed Notes/registry
   documents retain composite preflight, so no root executes unless every
   selected domain passes its own authorization.

This bridge is narrowly scoped to the already validated RielaApp `/graphql`
handoff. It must not globally set every `GraphQLDocumentRequest` to locally
trusted and must not add a browser-visible credential or a second registry
authorization system.

The filesystem registry service must have one shared implementation importable
by both CLI and RielaApp. If its current ownership under `Sources/RielaCLI`
prevents reuse, extract the smallest provider/service boundary into an
importable target; do not duplicate registry locking, staging, validation,
activation, or publication behavior in RielaApp.

The GraphQL result contract is extended additively:

- `workflow(target:)` returns a bounded mutable-definition edit projection in
  its `definition` JSON object and a `definitionRevision` for the exact
  `originId`; it never returns raw definition JSON;
- `workflows(filter:)` remains a metadata list and does not duplicate full
  definitions;
- mutation errors include a stable conflict code when the selected definition
  changed after it was loaded.

The register and update input contracts use explicit one-of semantics:

```text
RegisterMutableWorkflowInput:
  bundle: WorkflowBundleReferenceInput       # now nullable
  definition: JSONObject                     # new, nullable
  overwrite: Boolean
  activationState: WorkflowActivationState

UpdateMutableWorkflowInput:
  target: WorkflowTargetInput!
  bundle: WorkflowBundleReferenceInput       # now nullable
  definition: JSONObject                     # new, nullable
  expectedDefinitionRevision: String         # required with definition

DeleteMutableWorkflowInput:
  target: WorkflowTargetInput!
  expectedDefinitionRevision: String         # new, nullable for compatibility

SetWorkflowActivationInput:
  target: WorkflowTargetInput!
  expectedDefinitionRevision: String         # new, nullable for compatibility
  expectedActivationState: WorkflowActivationState # new, nullable for compatibility
```

- Register and update require exactly one of `bundle` or `definition`.
- Supplying both or neither fails with `INVALID_WORKFLOW` before staging.
- A `definition` must be a JSON object and must satisfy the existing request
  size/depth limits plus the workflow-definition size limit.
- Register rejects every `$rielaRetain` object. Update accepts only valid retain
  handles issued for the same exact target, revision, JSON Pointer, and
  verified principal; reserved-shape objects with invalid handles fail with
  `INVALID_WORKFLOW`.
- Request limits apply before handle expansion and workflow-definition limits
  apply again after expansion, so placeholders cannot bypass size or depth
  validation.
- `expectedDefinitionRevision` is required for a definition update and is
  rejected when `bundle` is selected.
- The RielaApp web provider requires `expectedDefinitionRevision` for delete,
  activate, and deactivate, and additionally requires
  `expectedActivationState` for activate/deactivate. Their SDL fields remain
  nullable so existing non-web GraphQL clients retain their target-only
  behavior.
- Existing clients that provide `bundle` retain their behavior; making the
  schema field nullable only permits the new alternative and does not change
  bundle-reference validation.
- The revision is the SHA-256 digest of the exact persisted `workflow.json`
  bytes. It is checked while the coordinated registry locks are held. A
  mismatch returns `REGISTRY_CONFLICT` without staging or publication.

The existing mutation names remain the only registry mutation surface used by
the web.

For an update, the server acquires the coordinated registry locks, loads the
selected mutable origin, and compares `expectedDefinitionRevision` with the
digest of the currently persisted `workflow.json`. A mismatch returns
`REGISTRY_CONFLICT` before creating staging state. On a match, while retaining
the locks, it copies the complete registry-owned mutable bundle to staging,
replaces only `workflow.json`, validates the complete staged bundle, and
publishes through the existing `updateMutableWorkflow` transaction. Referenced
node/prompt files are therefore preserved. Paste-registration stages a
workflow-json-only bundle and succeeds only when normal server validation finds
it complete; missing referenced files are reported as validation errors.

Delete, activate, and deactivate use the same coordinated registry lock order.
After exact mutable-origin resolution and while the locks remain held, the
provider compares the current persisted `workflow.json` digest with
`expectedDefinitionRevision`. Delete returns `REGISTRY_CONFLICT` before removal
when it differs. Activation changes also compare the current activation state
with `expectedActivationState`; either mismatch returns `REGISTRY_CONFLICT`
before writing the activation store. This prevents a browser confirmation from
deleting replaced content and prevents stale opposite activation writes. A
request whose expected values still match is committed under the same locks.
The operations are idempotent only after those web-required comparisons pass.

GraphQL normally reports domain conflicts in a typed mutation payload rather
than HTTP 409. The UI maps that conflict to the same `MutationMessage` plus
Refresh recovery used for REST 409 responses. Existing REST configuration and
source-directory mutations continue to use integer `expectedRevision` and HTTP
409. The design does not turn GraphQL domain errors into nonstandard transport
status codes.

## Data flow and UI behavior

### Navigation

`web/src/App.tsx` retains signal-based navigation and no router. App state owns
the selected `{instanceId, sessionId, workflowId}`. Selecting a semantic
session-row button opens a run-detail view; Back returns to Run logs with the
instance selection retained. The run-detail state is unreachable from
`cli-serve` mode because that mode continues to force Notes and filters all
other navigation.

Every added surface has loading, error, empty, and success states built from
`web/src/components/Primitives.tsx`. Refresh actions remain visible.

### Shared polling and stale-result ownership

`web/src/App.tsx` owns a monotonically increasing profile-context generation.
It increments whenever a bootstrap refresh selects a different active profile
or host mode and passes the current profile identity and generation to every
non-Notes view. A profile-context change clears profile-owned selections and
content before new requests start.

A small shared SolidJS polling helper is used by Instances, Run logs, and run
detail. Every helper instance receives an immutable request-context key and a
monotonically increasing request generation. The keys are:

- Instances: profile identity and profile-context generation;
- Run logs: profile identity, profile-context generation, and selected
  instance id; and
- run detail: profile identity, profile-context generation, instance id,
  workflow id, and session id.

Every request captures both values. A completion may update content, loading
state, or error state only when its context key and generation still match the
current owner. Profile changes, selection changes, and unmount increment or
invalidate the generation before timers restart. Cancellation is an
optimization only; an uncancellable stale completion is still discarded.

The remaining polling contract is:

- default interval: five seconds;
- do not start another request while one is in flight;
- preserve the last successful content during background refetch within an
  unchanged context;
- stop the timer while `document.hidden` is true;
- on return to visibility, perform one immediate refresh and restart the
  interval;
- dispose the timer and `visibilitychange` listener on unmount;
- manual Refresh always requests a refresh, while still respecting the
  single-in-flight guard; and
- polling failures retain stale content, show an error/status message, and try
  again on the next eligible interval or manual refresh.

The UI exposes an accessible `Auto-refresh on`, `Auto-refresh paused`, or
`Refreshing` status so behavior is observable and testable. Polling does not
mutate data and does not create WebSocket/SSE connections.

### Run detail

The detail header shows the session identity, workflow, status, last update,
and manual Refresh. Step executions are ordered by persisted start time and
then execution id. Each step shows timing, attempt, backend, status, failure
reason, bounded events/logs, and related routing evidence. Session diagnostics
and gate/loop evidence render in separate sections and have explicit empty
states.

The run-detail key above prevents a stale response for a previously selected
session from replacing a newer selection. The same commit rule applies to
session-list responses for a previously selected instance.

### Variables validation

`web/src/views/InstancesView.tsx` validates on every textarea edit:

- empty text is invalid;
- parsing is guarded;
- the root must be a JSON object, not `null`, an array, or a scalar;
- invalid content shows an inline error associated with the textarea and
  disables Save; and
- valid content follows the existing PUT contract unchanged.

The save handler revalidates immediately before mutation so a programmatic or
race-driven submission cannot bypass the guard. Other configuration fields
remain editable while the JSON error is visible.

### Node-patch inspection

The instances REST projection additively returns `nodePatches` as a map keyed
by node id. Each value contains only the typed, non-secret fields currently
supported by `WorkflowInstanceNodePatch`: execution backend, model, and effort.
The count remains for compatibility but is derived from the visible non-empty
map. Instances render a read-only empty state or a node-sorted list of patch
fields; the dashboard does not edit patches in this work package.

### Workflow definitions and mutable registry

The Workflows view keeps configured sources and discovered workflows, then
adds:

- a read-only inspector for the selected discovered definition, showing the
  source-scoped redacted REST display projection plus
  step/node/transition summary;
- a mutable-registry section sourced from
  `workflows(filter: {provenance: MUTABLE})`;
- a minimal paste-register editor with guarded object validation;
- an edit mode initialized from the selected mutable edit projection, with
  retain-handle placeholders preserved unless the user intentionally replaces
  them;
- activate/deactivate actions;
- delete confirmation naming the exact workflow; and
- server validation diagnostics and conflict-refresh recovery through
  `MutationMessage`.

Immutable definitions never expose edit or delete controls. Mutable updates do
not infer a target from workflow name alone: the client sends `workflowId`,
`scope: USER`, and `originId`. Delete and activation controls remain disabled
until the exact selected definition and its revision have loaded; activation
also captures the displayed activation state. The confirmation names the exact
workflow and revision. After every accepted mutation, and after a conflict
Refresh action, the client refetches both list and selected definition.
`consolidateWorkflows` is not rendered or called.

Source-list, discovered-definition, mutable-list, and mutable-definition loads
use the same profile-context generation rule as polling. Their context keys
also include, where applicable, the selected source id or exact mutable
`{workflowId, scope, originId}`. A result for a prior profile, source, mutable
origin, or definition revision cannot update selection, editor text, loading
state, or errors. Profile changes clear every workflow selection before
refetch.

## Validation, security, and rollout constraints

- RielaApp keeps its existing Host, Origin, JSON content-type, and
  `X-Riela-CSRF` checks for REST and GraphQL requests.
- Passing those checks is necessary but is not represented as client trust. The
  RielaApp-only GraphQL adapter creates the in-process verified principal after
  the checks, and the registry executor still enforces `readRegistry` or
  `mutateRegistry` before provider access.
- Tests must prove that invalid Host, Origin, CSRF, or content type never reaches
  the registry provider; that a read-only test principal cannot invoke a
  mutation; that a principal with both required capabilities can use the
  intended UI operations; and that a browser-supplied trust-like header or an
  executor call without server-owned provenance remains unauthorized.
- The web GraphQL client reuses the Notes same-origin request pattern and app
  headers, but lives in a workflow-domain module rather than coupling workflow
  operations to `web/src/notes/client.ts`.
- The discovered-definition REST route resolves only an exact daemon source
  id and never accepts or returns a filesystem path.
- Definition inputs and projections are bounded by the existing HTTP/GraphQL
  request limit and an explicit server-side workflow-definition size limit.
  Excess size and depth fail before staging.
- Discovered definitions use fixed redaction; mutable definitions use
  principal-, target-, revision-, and path-bound retain handles. Raw literal
  environment values, prompts, command text, credentials, and unclassified
  add-on content never appear in a response.
- Registry diagnostics returned to the browser redact absolute paths and
  credentials.
- Run-detail event content, log summaries, failure text, definition
  projections, and gate/loop evidence obey the shared web-display bounds and
  applicable redaction rules above; tests use secret canaries and oversize
  fixtures to prove omission and truncation.
- Definition revisions are content-derived and checked inside the same
  coordinated registry mutation that validates and publishes the bundle.
- Temporary staging uses the server's registry transaction area and existing
  containment/symlink rules. Browser input never chooses a server filesystem
  path.
- Delete requires an explicit browser confirmation and the server independently
  verifies mutable provenance.
- New schema fields are additive. Existing REST and GraphQL clients continue to
  decode their current fields.
- No frontend view is enabled in `cli-serve`; Notes authentication and behavior
  remain unchanged.

## Issue-to-design mapping

| Acceptance signal | Design contract |
| --- | --- |
| Session row opens real run detail | Nested REST projection plus App signal navigation |
| Step logs, diagnostics, gate/loop evidence | Bounded persisted-session detail DTO |
| Visible-only automatic refresh | Shared five-second visibility-aware, context-generation-safe polling helper |
| Manual Refresh remains | Polling helper exposes manual single-in-flight refresh |
| Invalid variables JSON blocks Save | Parse-and-object validation on input and submit |
| Node patches are viewable | Additive typed `nodePatches` instances projection |
| Discovered definitions are inspectable | Exact daemon-source redacted REST projection and read-only inspector |
| Mutable workflows are manageable | Existing registry query/mutation names, safe edit projections with retain handles, and real app provider |
| Profile and selection changes reject stale results | Context keys and commit-time generation checks cover all polling and definition loads |
| Conflict and validation feedback | Typed GraphQL mutation errors or existing REST 409 mapped to `MutationMessage` |
| Registry web access is authorized | Validated RielaApp route creates a server-owned principal; capability preflight precedes provider access |
| Host mode remains Notes-only | Existing navigation filter and forced Notes state remain authoritative |

## Verification contract

Implementation must run:

```bash
cd web && bun run build
cd web && bun test src
swift build
swift test --filter RielaGraphQLTests
swift test --filter RielaAppSupportTests
git diff --check
```

If server changes land outside those two suites, add the smallest directly
relevant filtered Swift suite. New Playwright coverage under `web/e2e/` must
cover run-detail navigation and real response rendering, polling/visibility
state, invalid JSON save blocking, definition inspection, registry update and
conflict feedback, activation, and confirmed deletion. Role selectors use
`exact: true`. The operator owns the full Playwright run and browser QA.
Focused RielaApp/GraphQL tests must additionally cover the authorization-bridge
allow/deny matrix described above and assert that rejected requests never call
the registry provider. They must also prove that the RielaApp provider never
uses process cwd or browser paths, exposes only user mutable origins, rejects
`AUTO`/`PROJECT`/missing-origin targets, captures request-local profile
generation, conflicts stale delete/activation requests before mutation, omits
assistant/thinking/tool content, redacts secret canaries, and emits every
specified truncation marker at the declared bounds. Definition-projection
tests place canaries in literal environment values, credential-named fields,
prompts, add-on inputs/configuration, and command argv; no response may contain
them. Mutable-update tests prove that an unchanged bound retain handle
preserves the current value, a replacement literal changes it without being
echoed, and moved, cross-origin, cross-revision, cross-principal, or forged
handles fail before staging. Web tests change profiles, instances, sessions,
discovered sources, and mutable origins with old requests in flight and prove
that no stale content, loading state, or error commits.

## Review risks

- High: exposing the registry executor through RielaApp could bypass existing
  registry authorization, locking, or path-redaction rules if implemented as
  a second registry service.
- High: inline update could discard referenced bundle files unless it stages a
  complete existing bundle before replacing `workflow.json`.
- Medium: definition revision checks that occur before, rather than inside,
  the coordinated mutation can still lose concurrent CLI edits.
- Medium: polling or definition loads can commit stale results after profile or
  selection changes, or polling can continue while hidden, if ownership,
  disposal, and generation guards are incomplete.
- Medium: run-detail logs or persisted definitions may contain sensitive
  values; every response must use the bounded redacted display or edit
  projection rather than the raw persisted object.
- Low: a five-second interval can briefly show stale status; manual Refresh is
  retained as the explicit recovery.

No unresolved user decision blocks implementation.

## Addressed self-review feedback

- The discovered inspector is now bound to the exact RielaApp
  `daemonWorkflowSources` id through a source-scoped REST projection; it no
  longer assumes the CLI registry catalog contains or uniquely resolves every
  displayed source.
- Inline registry inputs now define nullable legacy bundle fields, new
  definition fields, exact-one validation, definition-update revision
  requirements, compatibility behavior, size validation, digest semantics, and
  the `REGISTRY_CONFLICT` result.
- Step 3 authorization feedback is addressed by defining an RielaApp-only,
  server-owned verified-principal handoff after the existing web security gate,
  retaining per-operation `readRegistry`/`mutateRegistry` preflight and
  fail-closed behavior for all other callers.
- Step 3 transaction-order feedback is addressed by checking the persisted
  definition revision under coordinated locks before any staging, then staging,
  validating, and publishing only after the revision matches.
- The latest registry-root feedback is addressed by fixing RielaApp GraphQL to
  the existing user-global mutable root, prohibiting ambient/request paths,
  requiring user mutable exact-origin targets, and making providers
  request-scoped and fail-closed.
- The latest destructive-concurrency feedback is addressed by requiring
  definition revisions for web delete/activation and the displayed activation
  state for activation changes, all checked under coordinated locks.
- The latest exposure-boundary feedback is addressed by explicit collection,
  string, definition, and response caps plus an allowlist projector that never
  returns raw assistant, thinking, tool, communication, environment, command,
  or LLM content.
- The latest definition-exposure feedback is addressed by separating
  discovered display projections from mutable edit projections and defining
  path-bound opaque retain handles that preserve sensitive values without
  returning or echoing them.
- The latest stale-result feedback is addressed by making profile identity,
  profile-context generation, and surface selection part of every polling and
  definition-load context key, with commit-time generation checks for content,
  loading state, and errors.
