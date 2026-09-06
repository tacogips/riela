# Named Kaiba API Instances And KaibaClient Migration

**Status**: Proposed for adversarial review
**Workflow**: `codex-design-and-implement-review-loop-session-111`
**Issue**: `local-request:/Users/taco/gits/tacogips/riela:Add named Kaiba API instances and migrate every kaiba node to KaibaClient`

## Purpose

Give the CLI, RielaApp, and every `kaiba/*` node one named-instance contract for
calling a running Kaiba server over HTTP(S). An operator configures an endpoint
and an authentication mode once, may bind a node to the instance's stable ID,
and otherwise uses the single configured default. Every Kaiba add-on then uses
the dependency-free first-party `KaibaClient`; no add-on opens a Kaiba store or
falls back to `NoteService`, SQLite, `AppGraphQL`, or another in-process path.

The intake used `tmp/kaiba-api-instances/ideal-spec.md` as non-normative scratch
evidence. This committed document fully restates and supersedes every accepted
requirement needed by this work package; implementation and later review must
not depend on the scratch file remaining present. Package enablement, package
update status, package manifest additions, workflow-level defaults,
environment-management redesign, and Web Config changes are not part of this
issue.

## Source Contracts

- `AGENTS.md` supplies scratch-file and digest rules.
- `.codex/skills/riela-impl-workflow/SKILL.md` supplies the issue-resolution
  handoff and accepted Kaiba-side review record.
- `.codex/skills/riela-usability-improvement-loop/SKILL.md` supplies the
  cross-surface CLI/App usability and evidence requirements.
- `.codex/skills/swift-coding-agent/SKILL.md` supplies Swift boundaries,
  SwiftLint, test, and 1,000-line limits.
- `.agents/skills/rielaapp-ui-verification/SKILL.md` requires the current direct
  debug executable and window-ID screenshots.
- `tmp/kaiba-api-instances/ideal-spec.md` records intake provenance only. It is
  gitignored, non-normative, may be removed with scratch cleanup, and is fully
  superseded by this design for the accepted work package.
- `/Users/taco/gits/tacogips/kaiba/design-docs/specs/kaiba-client-sdk.md`,
  `/Users/taco/gits/tacogips/kaiba/design-docs/specs/graphql-schema-discovery-cli.md`,
  and `/Users/taco/gits/tacogips/kaiba/Sources/KaibaClient` define the accepted
  endpoint, authentication, readiness, redaction, arbitrary GraphQL, typed
  operation, and idempotency behavior.
- `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`,
  `Sources/RielaCore/DeterministicWorkflowRunner+ExecutionEvents.swift`, and
  `Tests/RielaCoreTests/WorkflowAddonExecutionIdentityTests.swift` define the
  runtime-owned execution and retry lineage from which mutation operation
  identity is derived.

The Kaiba-side contract was accepted in
`codex-design-and-implement-review-loop-session-6`. Riela consumes that contract
and does not create a second HTTP client.

## Current State And Required Cutover

`Sources/RielaKaibaAddons/KaibaAddonCatalog.swift` currently divides local
`NoteService` add-ons from one remote add-on.
`Sources/RielaKaibaAddons/KaibaNoteGraphQLDocument.swift` runs GraphQL through
`AppGraphQL` in process, while
`Sources/RielaKaibaAddons/KaibaRemoteGraphQLAddon.swift` uses
`GraphQLHTTPDocumentClient` with node-local endpoint and authentication fields.
`Package.swift` consequently links `AppCore` and `AppGraphQL` into
`RielaKaibaAddons`.

The cutover is complete only when all registered add-ons in
`Sources/RielaAddons/RielaAddons.swift` use `KaibaClient` and the Kaiba add-on
target contains no `AppCore`, `AppGraphQL`, `NoteService`, SQLite driver,
`GraphQLHTTPDocumentClient`, note-root, database-path, or local-store execution
path. Localhost is an HTTP endpoint, not a synonym for direct database access.

## Boundary And Ownership

Add a focused `RielaKaibaSupport` target rather than putting SDK concepts in
provider-neutral `RielaCore`:

```text
KaibaClient
    ^
    |
RielaKaibaSupport  -> RielaCore
    ^       ^
    |       +--------- RielaAppSupport -> RielaApp
    +----------------- RielaKaibaAddons <- RielaCLI
```

`RielaKaibaSupport` owns the persisted model, strict file store, selector and
binding resolution, binding-source enumeration/reference scanning, safe result
DTOs, client construction, readiness mapping, and transport injection.
`RielaKaibaAddons` owns add-on input/output projection and operation selection.
`RielaCLI` owns command parsing and rendering.
`RielaAppSupport` owns testable view models and use-case coordination;
`RielaApp` owns AppKit views and actions.

Only `RielaKaibaSupport` and `RielaKaibaAddons` import `KaibaClient`.
`RielaKaibaAddons` replaces its `AppCore` and `AppGraphQL` products with
`KaibaClient` and `RielaKaibaSupport`. Document conversion that must happen on
the caller side is extracted into Riela-owned support code; it must not preserve
a dependency on Kaiba service or store modules.

The committed SwiftPM dependency remains a pinned Kaiba repository revision
that exports `KaibaClient`. The local checkout
`/Users/taco/gits/tacogips/kaiba` is the development/reference source and may be
used for local verification, but an absolute path must not be committed in
`Package.swift`.

Cursor-specific CLI behavior is unaffected. No Kaiba model, readiness rule, or
authentication option enters `CursorCLIAgent`; provider-specific Cursor command
construction remains isolated behind its existing adapter.

## Persistent Instance Contract

### Scope and location

Kaiba instances are user-wide, not project- or RielaApp-profile-owned. CLI and
RielaApp use the same default file:

```text
<home>/.riela/kaiba/instances.json
```

`<home>` is resolved through the existing injectable home-directory boundary,
so `--home-root` RielaApp verification and CLI tests remain isolated. A profile
may contain node bindings, but removing a profile does not remove shared server
definitions. This release has one user-wide default instance. Project-specific
instance registries and workflow/package defaults are non-goals.

### Versioned schema

```json
{
  "version": 1,
  "instances": [
    {
      "id": "f2ea7b1e-90ce-459e-9c65-e608ab1a612c",
      "name": "Local",
      "endpoint": "http://localhost:4317/graphql",
      "authentication": {
        "mode": "bearer",
        "environmentVariable": "KAIBA_API_KEY"
      },
      "enabled": true,
      "isDefault": true,
      "allowInsecureHTTP": false,
      "allowRemoteUnauthenticated": false,
      "lastTest": {
        "status": "ready",
        "code": null,
        "checkedAt": "2026-09-05T12:00:00Z"
      }
    }
  ]
}
```

The authentication object is a closed tagged union:

- bearer mode contains exactly `mode: "bearer"` and one environment-variable
  name;
- unauthenticated mode contains exactly `mode: "unauthenticated"` and no
  environment-variable or credential field.

There is no field capable of containing a bearer value. Decoding is strict:
unknown schema versions, unknown fields, unknown enum values, duplicate keys,
or token-like fields such as `token`, `bearerToken`, or `apiKey` make the store
invalid rather than being ignored. The encoder always sorts keys and never has
access to a raw bearer value.

`lastTest` contains only the closed status, stable code, and UTC timestamp. It
does not persist SDK errors, response bodies, GraphQL messages, URLs copied from
errors, or arbitrary diagnostics.

Its lifecycle is deterministic:

- add initializes `lastTest` to `untested` with null code and timestamp;
- an effective endpoint, authentication mode, bearer environment-variable
  name, `allowInsecureHTTP`, or `allowRemoteUnauthenticated` change sets an
  enabled instance to `untested` with null code and timestamp;
- disabling a non-default instance sets `disabled`, code
  `disabled_kaiba_instance`, and the mutation timestamp; re-enabling always sets
  `untested` with null code and timestamp, regardless of its earlier result;
- rename and default selection do not invalidate transport evidence;
- `test` atomically replaces the value with `ready` or its stable failure status,
  code, and attempt timestamp; testing a disabled instance records `disabled`
  without transport; and
- removal deletes the record with the instance.

Only effective persisted configuration changes trigger invalidation. Riela
cannot observe a bearer value changing inside the environment, so `lastTest` is
historical display evidence, never authorization to skip runtime credential
resolution or readiness preflight. App test revisions and catalog transactions
ensure a result for older configuration cannot overwrite an invalidated state.
The test snapshots the instance ID, enabled state, endpoint, authentication,
and transport-policy flags before I/O. After I/O it reloads under the catalog
lock and writes the result only if those fields still match. A removed or
changed instance discards the result and returns `kaiba_instance_changed`; the
network call is never performed while holding the catalog lock. Tests inject
the clock so transition timestamps are exact.

### Invariants and validation

- IDs are generated lowercase UUID strings, immutable after creation, unique,
  and used by every persisted binding. Tests inject the ID generator.
- Display names are trimmed NFC strings from 1 through 80 characters without
  control characters. Their POSIX case-folded keys are unique. Rename preserves
  the ID and all bindings.
- CLI selectors first match an exact ID, then a unique case-folded display
  name. Persisted bindings never contain display names.
- Endpoints follow `KaibaEndpoint`: absolute `http` or `https`, non-empty host,
  no user information/query/fragment/control characters, valid port, lowercase
  scheme and host, and default ports removed. Version 1 accepts only an empty
  path, `/`, or `/graphql`, and persists all three as `/graphql`. Every custom
  path is rejected as `invalid_endpoint`, even when the SDK could transport it,
  because path segments can contain bearer material and therefore cannot meet
  Riela's absolute no-token-persistence contract.
- Environment-variable names match `[A-Za-z_][A-Za-z0-9_]*`. Values are read
  only when constructing `KaibaBearerToken` and never enter a Codable, logging,
  rendering, telemetry, or persisted value.
- Remote HTTP requires `allowInsecureHTTP: true`. Non-loopback unauthenticated
  access additionally requires `allowRemoteUnauthenticated: true`. These flags
  map directly to `KaibaClientConfiguration`; TLS validation cannot be disabled.
- A non-empty store has exactly one default. The default is enabled and valid.
  The empty store has no default.
- The first added instance becomes default. `--set-default` may replace it.
  Disabling the current default is always rejected, including when it is the
  sole instance. Removing the current default is rejected while another
  instance exists; the operator must set another enabled default first. Only
  removal of the sole instance may produce the valid empty state. `--force`
  never bypasses this invariant.
- Disabling an instance preserves it and every binding. It becomes unavailable
  immediately and never falls through to the default.
- Load validates the complete file before returning any row. Invalid state
  fails closed as `invalid_kaiba_instance_store`; it is not silently rewritten,
  quarantined, or treated as an empty catalog.
- An absent file is the one representation of an empty catalog and is created
  by the first successful mutation. An unreadable file or directory is
  `kaiba_instance_store_unavailable`, not an empty catalog.

Every mutation obtains the existing platform file-lock pattern, reloads and
validates under the lock, applies one transaction, revalidates, writes a
sorted-key temporary file in the same directory, synchronizes it, and atomically
renames it. The store rejects symlinks and non-regular targets. This prevents a
CLI write and an App write from silently losing each other.

## Binding And Runtime Resolution

The sole explicit node field is:

```json
{
  "addon": {
    "name": "kaiba/note-search",
    "version": "1",
    "config": {
      "kaibaInstanceId": "f2ea7b1e-90ce-459e-9c65-e608ab1a612c"
    }
  }
}
```

`kaibaInstanceId` is read only from the effective authored add-on config after
workflow-instance node patches have been applied. It is not template-expanded
and cannot come from workflow variables, upstream payloads, model output, or
environment values; data flowing through a workflow therefore cannot reroute a
node to another server.

Resolution is exactly:

1. If `kaibaInstanceId` is present, resolve that exact ID.
2. Otherwise resolve the catalog's single default.
3. Never fall back from an explicit binding to the default.

Before the scheduler starts a workflow, it snapshots the catalog and resolves
every declared `kaiba/*` node. It reads each referenced bearer environment value
from the workflow's already-resolved effective environment, constructs one
client per distinct instance, and performs one single-flight
`probeReadiness()` per distinct instance. A direct `riela node`/`rrun` execution
performs the same gate for its one node. No business GraphQL operation runs
until the gate succeeds. The immutable snapshot prevents a concurrent rename,
default change, disable, or removal from rerouting a running execution.

Generic readiness is necessary but not sufficient for long-term-memory nodes:
`probeReadiness()` exercises ordinary note access, while long-term-memory
operations require admin authorization. If an instance is referenced by
`kaiba/memory-consolidate` or `kaiba/memory-recall`, preflight additionally calls
the side-effect-free `longTermMemoryNotebook()` exactly once for that instance
before scheduling any node. The result must be accepted and contain the
notebook value. Authentication rejection maps to `auth_failed`; a rejected or
missing capability maps to `incompatible_kaiba_instance` with detail code
`long_term_memory_unavailable`. Connection and incompatible-response failures
retain their ordinary stable categories. No memory mutation is used as a probe.

The gate maps failures to stable Riela codes:

| Condition | Code | Transport attempted |
| --- | --- | --- |
| no explicit binding and no default | `missing_kaiba_instance` | no |
| explicit ID absent from snapshot | `unknown_kaiba_instance` | no |
| selected instance disabled | `disabled_kaiba_instance` | no |
| store/model/client configuration invalid | `invalid_kaiba_instance` | no |
| named bearer environment value missing/empty/invalid | `missing_kaiba_credential` | no |
| supplied legacy remote assertion differs from resolved instance | `legacy_kaiba_connection_mismatch` | no |
| readiness `authFailed` | `auth_failed` | yes |
| readiness `connectionFailed` | `connection_failed` | yes |
| readiness `serverRejected` | `incompatible_kaiba_instance` with detail code `server_rejected` | yes |
| readiness `incompatibleResponse` | `incompatible_kaiba_instance` with detail code `incompatible_response` | yes |
| memory capability authentication rejection | `auth_failed` | yes |
| memory capability rejected, absent, or malformed | `incompatible_kaiba_instance` with detail code `long_term_memory_unavailable` | yes |

Cancellation remains cancellation and is not relabeled as a connection failure.
All messages and next actions are fixed Riela-owned strings. SDK descriptions,
server diagnostics, response bodies, request documents/variables, headers,
token values, and `localizedDescription` are never copied to Riela errors.

The resolved add-on output may include `instanceId`, `instanceName`, the SDK's
redacted endpoint description, and `authenticationMode`. It never includes the
credential value. The former `noteRoot` and `databasePath` output fields are
removed because there is no local store.

### Binding reference discovery and removal consistency

The source of truth for instance usage is the persisted workflow definition or
workflow-instance node patch containing
`addon.config.kaibaInstanceId`; there is no separately persisted reverse index.
`RielaKaibaSupport` provides one binding-reference scanner that rebuilds a
read-only snapshot for CLI and App operations from these finite roots:

1. the selected project root: `.riela/instances.json`, `.riela/workflows`, and
   `.riela/packages`;
2. the user root: `<home>/.riela/instances.json`, `<home>/.riela/workflows`, and
   `<home>/.riela/packages`;
3. every profile below the resolved App root: `profiles/*/daemon-workflows.json`,
   `profiles/*/workflows`, and `profiles/*/packages`; and
4. every project directory and standalone workflow directory registered by
   those profile state files. A registered project contributes its
   `.riela/instances.json`, `.riela/workflows`, and `.riela/packages`; a
   standalone workflow contributes only its declared workflow directory.

The CLI selected project root is `--working-dir PATH`, defaulting to the current
directory. Its App root is `--app-root PATH`, defaulting to
`<home>/.riela/rielaapp`. RielaApp passes its actual launch project root and
`profileStore.appRootURL`, including test/debug overrides. Given the same roots,
CLI and App therefore scan identical files. The scanner uses existing workflow
and package discovery rules, does not follow root-escaping symlinks, reads only
supported workflow/profile/instance JSON, deduplicates canonical paths, and
sorts references by scope, profile, workflow ID, workflow-instance identity,
node ID, binding origin, and source path.

A reference record has exactly `scope`, nullable `profile`, `workflowId`,
nullable `workflowInstanceIdentity`, `nodeId`, `bindingOrigin` (`definition` or
`instance_patch`), `sourcePath`, and `kaibaInstanceId`. It contains no resolved
credential or workflow environment value. Unreadable, malformed, or
changed-during-scan state fails the operation as `kaiba_binding_scan_failed`;
an incomplete scan is never treated as zero references, and `--force` does not
bypass this failure.

`scope` is the closed set `project`, `user`, `profile`, or `external` and sorts
in that order. Remaining nullable fields sort null before non-null, and strings
sort by POSIX Unicode-scalar order. `sourcePath` is the standardized absolute
path of the persisted source. These rules make CLI JSON, CLI text, and App rows
sequence-equivalent for the same root snapshot.

The catalog lock is also the coordination lock for every Riela-managed write of
`kaibaInstanceId`. Remove holds that lock while reloading the catalog, scanning
references, and atomically replacing the catalog. Without force, any discovered
reference returns `kaiba_instance_in_use`. With force, removal succeeds, leaves
every binding unchanged, and returns the identical sorted `affectedReferences`
array in CLI JSON and the App result model; text and App confirmation use the
same count and records. RielaApp's `Remove Anyway` is exactly CLI `--force`.
Neither surface silently clears or rebinds nodes.

This scope intentionally does not crawl unrelated filesystem projects. An
externally edited or unregistered project can retain a now-dangling stable ID;
runtime resolution still fails closed as `unknown_kaiba_instance`. External
edits are not covered by the coordination lock, so the removal snapshot is
authoritative for the declared roots at transaction time, not a global
filesystem guarantee. This boundary follows existing project/user/profile root
semantics and requires no additional user decision.

## CLI Contract

The canonical commands are:

```text
riela kaiba instance list [--output text|json]
riela kaiba instance show NAME_OR_ID [--output text|json]
riela kaiba instance add NAME --endpoint URL
  (--api-key-env ENV | --allow-unauthenticated)
  [--allow-insecure-http] [--allow-remote-unauthenticated]
  [--set-default] [--output text|json]
riela kaiba instance update NAME_OR_ID
  [--name NAME] [--endpoint URL]
  [--api-key-env ENV | --allow-unauthenticated]
  [--allow-insecure-http true|false]
  [--allow-remote-unauthenticated true|false]
  [--enable|--disable] [--output text|json]
riela kaiba instance remove NAME_OR_ID [--force]
  [--working-dir PATH] [--app-root PATH] [--output text|json]
riela kaiba instance test NAME_OR_ID [--output text|json]
riela kaiba instance set-default NAME_OR_ID [--output text|json]
```

`set-default` is the only canonical spelling. The ideal-spec draft's
`instance default [NAME]` form was never shipped, so no compatibility alias is
added. `show` is the read operation and `set-default` is the mutation.

Rules:

- `--output` defaults to `text`. Success writes only stdout; failure writes only
  stderr. Success exits 0, usage/static configuration failures exit 2, and
  readiness/operational failures exit 1.
- `list` exits 0 when the validated store can be rendered, even when it is empty
  or rows are disabled/not ready. Rows sort by folded name and then ID.
- JSON uses sorted keys and one final newline. Every success has `status: "ok"`
  and `operation`; list adds `instances`, while other commands add `instance`.
  Every failure has `status: "error"`, `operation`, `code`, `message`,
  `nextAction`, and, when safely known, `instanceId` and `instanceName`.
- Instance JSON fields are `id`, `name`, `endpoint`, `authenticationMode`,
  `credentialEnvironmentVariable`, `enabled`, `isDefault`,
  `allowInsecureHTTP`, `allowRemoteUnauthenticated`, and `lastTest`. The
  credential field contains the variable name or `null`, never its value.
- `lastTest.status` is one of `untested`, `ready`, `disabled`,
  `missing_credential`, `auth_failed`, `connection_failed`, or `incompatible`.
  Its optional code is drawn only from the stable Riela failure-code table.
- Text list columns are exactly `DEFAULT`, `ENABLED`, `NAME`, `ENDPOINT`,
  `AUTH`, and `LAST TEST`. `show` renders the same fields one per line in that
  order. Mutation text begins with the stable verb `Added`, `Updated`,
  `Removed`, `Tested`, or `Default` followed by ID and name.
- `test` performs the same static checks and generic SDK readiness probe as
  runtime and atomically records only its safe `lastTest`. It exits 0 only for
  `ready`; workflow preflight separately performs the memory capability check
  when a workflow contains a long-term-memory node.
- `remove` invokes the shared binding-reference scan. Without `--force`, any
  reference fails as `kaiba_instance_in_use`. `--force` removes the instance but
  leaves those stable-ID bindings intact and reports the sorted
  `affectedReferences`; subsequent validation fails as
  `unknown_kaiba_instance` rather than silently using the default.

All command failures use this closed contract. The text form is exactly
`<code>: <message> Next: <nextAction>` followed by one newline. The JSON form
uses the failure object above. Messages and next actions are constants; user
input, URLs, environment values, SDK descriptions, and server bodies are never
interpolated. Validation order is command syntax; store load; selector; name,
endpoint, then authentication policy; default invariant; binding scan;
binding-in-use check; credential lookup; then transport. `--force` skips only
the binding-in-use check. One invocation therefore has a deterministic primary
failure.

| Code | Exit | Applies to | Fixed message | Fixed next action |
| --- | ---: | --- | --- | --- |
| `invalid_usage` | 2 | any | `The command arguments are invalid.` | `Run riela kaiba instance --help.` |
| `invalid_kaiba_instance_store` | 2 | any | `The Kaiba instance catalog is invalid.` | `Repair the catalog schema and default invariant.` |
| `kaiba_instance_store_unavailable` | 1 | any | `The Kaiba instance catalog could not be accessed.` | `Check the Riela home directory permissions and retry.` |
| `kaiba_instance_not_found` | 2 | show, update, remove, test, set-default | `No Kaiba instance matches the selector.` | `Run riela kaiba instance list and use an existing name or ID.` |
| `duplicate_kaiba_instance_name` | 2 | add, update | `A Kaiba instance already uses that name.` | `Choose a unique instance name.` |
| `invalid_kaiba_instance_name` | 2 | add, update | `The Kaiba instance name is invalid.` | `Use a 1 to 80 character name without control characters.` |
| `invalid_endpoint` | 2 | add, update | `The Kaiba endpoint is invalid.` | `Use an HTTP(S) server root or /graphql URL without credentials, query, or fragment.` |
| `invalid_authentication_policy` | 2 | add, update | `The Kaiba authentication policy is invalid.` | `Choose one authentication mode and its required explicit transport opt-ins.` |
| `default_replacement_required` | 2 | update, remove | `The current default cannot be disabled or removed.` | `Set another enabled instance as default first.` |
| `kaiba_binding_scan_failed` | 1 | remove | `Kaiba binding references could not be inspected safely.` | `Repair or remove the unreadable workflow state and retry.` |
| `kaiba_instance_in_use` | 2 | remove | `The Kaiba instance is still bound to workflow nodes.` | `Update the bindings or repeat remove with --force.` |
| `disabled_kaiba_instance` | 2 | test, set-default | `The Kaiba instance is disabled.` | `Enable the instance before testing or making it default.` |
| `missing_kaiba_credential` | 2 | test | `The configured bearer environment variable is unavailable.` | `Export the configured environment variable and retry.` |
| `kaiba_instance_changed` | 1 | test | `The Kaiba instance changed while the test was running.` | `Test the current instance configuration again.` |
| `auth_failed` | 1 | test | `Kaiba rejected authentication.` | `Verify the configured credential and server authorization.` |
| `connection_failed` | 1 | test | `The Kaiba endpoint could not be reached.` | `Verify the endpoint, network, and server availability.` |
| `incompatible_kaiba_instance` | 1 | test | `The endpoint did not provide a compatible Kaiba API.` | `Update Kaiba or select a compatible instance.` |

Disabling any current default returns `default_replacement_required`, even when
it is the sole row. Removing the sole row is the only operation that may leave
an empty catalog; removing a default while any other row exists returns
`default_replacement_required`. `--force` bypasses only the binding-in-use
check, never authentication, validation, enabled/default, or store invariants.
Adding the first row makes it enabled and default; `set-default` accepts only an
enabled row. A successful `update` with no mutating option is `invalid_usage`.
Successful forced-remove JSON includes `affectedReferences` even when empty;
non-forced successful removal includes the same empty array. Text prints the
stable mutation line followed by one deterministic line per affected reference.

Required fixed repair guidance names the next safe action, such as add an
instance, set another default, enable the selected instance, export the named
environment variable, verify endpoint/authentication, or update the Kaiba
server. It never recommends embedding a token in a workflow or command line.

## RielaApp Contract

Add `Kaiba` to the existing native settings sidebar. The list uses native
Settings-style rows with name, safe endpoint, auth mode/environment-variable
name, enabled state, default badge, and last-test state. Toolbar controls have
accessibility labels and tooltips.

The detail/editor supports:

- add and edit with the same validation and explicit auth choices as CLI;
- enable/disable, subject to the default invariant;
- set default;
- readiness test with one fixed status, fixed recovery copy, and timestamp;
- remove, with affected workflow/node references and explicit Cancel or Remove
  Anyway behavior; and
- remote HTTP and remote unauthenticated warnings beside their explicit opt-ins.

App removal uses the same scanner, root arguments, catalog lock, failure codes,
sorted reference DTOs, and force semantics as CLI. A scan failure disables both
ordinary removal and Remove Anyway. Ordinary removal is disabled when
references exist; Remove Anyway leaves every reference dangling and returns the
same `affectedReferences` records as CLI `--force`.

Secret fields never exist. The UI accepts and displays only the environment
variable name and presence state. The generic instance Test action resolves the
credential from the RielaApp process environment. Workflow preflight resolves
it from that workflow instance's effective environment, so an env-file-backed
workflow can be ready even when the generic process-level test reports the
credential missing.

Each configured workflow-instance detail adds a Kaiba Nodes section for every
registered `kaiba/*` node. Its popup contains `Use Default (<name>)` plus enabled
named instances. A disabled instance remains visible but unavailable. A stale ID
is shown as `Missing instance (<id>)` with an error badge; it is never replaced
by the default. Selecting an instance merges only
`addon.config.kaibaInstanceId` into the existing node patch. Reset removes only
that field and prunes empty wrapper objects without disturbing other node
configuration.

Start is disabled when static instance/credential validation or the explicit
readiness check fails. The detail presents exactly one primary recovery action:
`Add Kaiba Instance`, `Set Default`, `Choose Instance`, `Enable Instance`,
`Set Environment`, `Test Instance`, or `Update Kaiba`. CLI and App use the same
code-to-copy projector.

UI implementation keeps store/client work outside the main actor, cancels stale
tests when selection/profile changes, and commits a result only when the tested
instance ID and edit revision still match. No stale probe may overwrite a newer
edit.

## Add-On Migration Matrix

All existing version-1 names remain registered. Input aliases, bounds, and
output payload keys remain compatible except for the intentionally removed
connection/store fields described below.

| Add-on | KaibaClient path | Compatibility projection |
| --- | --- | --- |
| `kaiba/note-create` | `createNotebook` when `notebookKindTag` requires a new notebook, then `createNote`; otherwise `createNote` | Preserve `noteId`, `notebookId`, `note` |
| `kaiba/note-update` | `updateNote` | Preserve updated note payload |
| `kaiba/note-get` | `getNote`; for one note also `listNoteComments`, `noteLinks`, `listNoteAttachments`; bounded sequential `getNote` for batch IDs | Preserve single and batch shapes, comments, links, files, graph evidence |
| `kaiba/note-search` | `searchNotes` | Preserve filters, result order, result count, and note IDs |
| `kaiba/note-tag-search` | `listNotes` with `tagFilter` | Preserve pagination and tag-filter payload |
| `kaiba/note-graph-neighbors` | `noteGraphNeighbors` | Preserve capped seeds, evidence, and retrieval IDs |
| `kaiba/note-chain` | `noteGraphNeighbors` | Reproject neighbors as existing chain rows |
| `kaiba/note-tag-apply` | `applyNoteTags` | Preserve AI provenance and workflow actor attribution |
| `kaiba/note-attach-file` | caller-owned bounded attachment projection, then `attachNoteFile` | Preserve file and attachment payload; no server-local path is sent |
| `kaiba/note-attachments` | `listNoteAttachments` or `listNotebookAttachments` | Preserve note/notebook branches and file count |
| `kaiba/note-memos` | `listNoteComments`, then the existing bounded local author/agent filter | Preserve memo and agent-memo arrays |
| `kaiba/note-graphql-document` | arbitrary `execute` | Reconstruct the compatibility `body` from decoded `data`; preserve single-field flattening and variables |
| `kaiba/note-graphql-remote` | the same arbitrary `execute` path | Retain the name as a compatibility alias; connection comes only from binding/default |
| `kaiba/note-comment-add` | `addNoteComment` | Preserve author aliases and comment payload |
| `kaiba/notebook-ingest-pages` | `ingestNotebookPages` | Preserve notebook/notes/source/page-image results and requested read-only states |
| `kaiba/document-import` | Riela-owned local conversion/OCR, then `ingestDocument`; optional translation is prepared by Riela and sent as a second idempotent ingest | Preserve notebook/note/source-file/translation payloads without importing Kaiba services |
| `kaiba/note-conversation-save` | `saveConversation` | Preserve notebook, notes, and note IDs |
| `kaiba/memory-consolidate` | `longTermMemoryNotebook`, `appendLongTermMemory`, then optional `linkLongTermMemoryAssociations` | Preserve empty opt-in, replay flag, associations, and IDs |
| `kaiba/memory-recall` | `recallLongTermMemory` | Preserve bounds, evidence, results, note IDs, and recall text |

Typed methods are required where the matrix names one. Arbitrary `execute` is
used for the two GraphQL document nodes and only as a compatibility escape hatch
when a required server field exists but the installed SDK has not yet added a
typed convenience. It must never implement a local fallback.

Every control-plane payload must have `result.accepted == true`. A rejected
typed result becomes an actionable, sanitized add-on failure; arbitrary
GraphQL errors are mapped from `KaibaClientError.graphqlFailed` without copying
server text.

`KaibaGraphQLResponse` exposes decoded `data` but intentionally exposes neither
the raw response envelope nor HTTP status. On successful arbitrary execution,
both GraphQL add-ons therefore return the exact compatibility projection
`handled: true`, `statusCode: 200`, and `body: {"data": <decoded data>}`. The
`body` is a reconstructed semantic envelope, not raw transport evidence;
object keys use Riela's deterministic ordering when serialized. Single-field
flattening reads the sole member of decoded `data` exactly as today. Any HTTP
2xx accepted by the SDK is represented as compatibility status 200. Transport
or GraphQL failure produces the stable sanitized add-on error and no response
body. Preserving an upstream status or error envelope would require a future
accepted SDK metadata API and is not part of this work package.

### Required idempotency

`notebook-ingest-pages`, `document-import`, translated-document ingest, and
`memory-consolidate` require a stable key. A rendered, non-empty authored
`idempotencyKey` remains the exact wire key and is authoritative for intentional
cross-run replay, including period-keyed consolidation. For `document-import`,
that exact value keys the primary ingest and `<authored-key>:translation` keys
the optional translated ingest so the two request bodies cannot claim one key.
An authored field that renders empty is `invalid_request`, not a request for
automatic derivation. The key is ordinary add-on configuration, not a runtime
execution identity. When the field is absent, the mutation requires one
runtime-owned operation identity per logical mutation. The deterministic
workflow runner computes and supplies
`operationExecutionId` before invoking an add-on; authored config, input,
environment, and workflow variables cannot supply or override that identity.

For a first attempt, `operationExecutionId` is the current persisted
`stepExecutionId`. For a resumable retry, it is the oldest execution ID in the
current step/node's consecutive unaccepted retry lineage: the last member of
the runtime-owned `predecessorStepExecutionIds`, whose order is newest to
oldest. Thus attempts with lineages `[]`, `[first]`, and `[second, first]` all
use `first`. For derived-key operations, the runner validates that predecessor
IDs are non-empty and unique, do not contain the current execution ID, and that
the singular `predecessorStepExecutionId`, when present, equals the array's
first member. An invalid lineage fails before add-on transport as
`invalid_idempotency_identity`; no best-effort key is generated.

Only consecutive executions without accepted output belong to the same
operation. An accepted execution closes the retry lineage. A later accepted
loop iteration of the same step/node therefore starts with its new
`stepExecutionId`, and a new workflow run or explicit rerun has both a new
`workflowExecutionId` and operation identity. These cases must produce new
automatically derived keys, while any number of resumes after failures or a
committed mutation whose response was lost reuse the original derived key. An
explicit key intentionally keeps its authored cross-run semantics and therefore
is exempt from automatic-key uniqueness.

An automatically derived wire key is `riela-kaiba-v1-` plus the lowercase
SHA-256 hex digest of a length-prefixed UTF-8 encoding of, in order:
`workflowExecutionId`,
`operationExecutionId`, workflow ID, step ID, node ID, add-on name, operation
discriminator. Length prefixes make field boundaries unambiguous. The
discriminators are
`notebook-ingest-pages:primary`, `document-import:primary`,
`document-import:translation`, and `memory-consolidate:append`. This keeps a
translated ingest distinct from the source ingest while making both stable
across the same retry lineage.

When automatic derivation is required, absent or empty runtime execution
identity fails as `missing_idempotency_identity`; present but malformed or
internally inconsistent identity fails as `invalid_idempotency_identity`.
Riela must not fall back to workflow ID, attempt number, current retry
`stepExecutionId`, communication ID, or other authored data alone.

KaibaClient performs no automatic retry. A Riela resumable retry reuses the
same explicit or derived wire key and canonical request body; a derived retry
also reuses the same operation identity. If resume-time inputs change the body,
Kaiba returns `invalid_request` for the unchanged key; Riela does not generate a
new key to conceal the conflict.

### Legacy input compatibility without legacy routing

Obsolete local-store fields `noteRoot`, `configPath`, and `databasePath` are
accepted as inert compatibility inputs. `KAIBA_NOTE_ROOT` and `RIELA_NOTE_ROOT`
may likewise remain in an existing workflow environment. They are never read to
construct a store, endpoint, credential, client, or output; they are excluded
from resolved add-on payloads and produce only the fixed deprecation code
`legacy_kaiba_local_config_ignored`. Thus repository workflows that authored
these fields continue over the safely resolved named HTTP(S) instance once a
default exists, without creating a local or in-process fallback.

Legacy remote connection fields are assertions, never selectors. Resolution of
`kaibaInstanceId` or the default occurs first. When a node still contains
`endpoint`, `apiKeyEnv`, `allowUnauthenticated`, `allowInsecureHTTP`, or
`allowRemoteUnauthenticated`, all supplied values must describe the already
resolved instance exactly:

- the legacy endpoint must pass the version-1 root-or-`/graphql` validation and
  normalize to the persisted endpoint;
- `apiKeyEnv` requires bearer mode with the same environment-variable name;
- `allowUnauthenticated: true` requires unauthenticated mode, while `false`
  requires bearer mode;
- supplied transport policy flags must equal their persisted values; and
- contradictory authentication fields fail validation rather than selecting a
  precedence.

An exact match proceeds only through the named `KaibaClient` and emits the fixed
deprecation code `legacy_kaiba_connection_config_matched`. A mismatch fails
before readiness or node work as `legacy_kaiba_connection_mismatch`, with the
fixed next action to bind the intended named instance and remove legacy fields.
The diagnostic never includes the endpoint, environment value, or authored
field contents. No instance, binding, or bearer setting is auto-created or
migrated from legacy fields, environment values, or Kaiba configuration.

`document-import` keeps local file conversion because `KaibaClient` explicitly
makes conversion caller-owned. It rejects `s3ProfileName`, `verifyS3Read`, and
fallback-to-Kaiba-config OCR/translation settings as
`unsupported_kaiba_client_feature`; storage placement is server policy and the
SDK exposes no S3 migration operation. Explicit Riela-owned OCR/translation
provider settings may continue. This fail-closed divergence is preferable to
direct store access or silently dropping requested behavior.

## Redaction And Observability

The token may exist only in the effective environment lookup, a local
`KaibaBearerToken`, and the SDK-created Authorization header. It must not be
captured by closures that outlive the request. Riela's public DTOs and errors
contain only environment-variable names, auth mode, fixed codes/copy, and safe
endpoint descriptions.

Tests place unique sentinel tokens in environment values, GraphQL errors,
Authorization-like text, rejected custom endpoint paths, thrown transport
values, reflection, logs, CLI text/JSON/stderr/stdout, persisted files, add-on
payloads, App labels/alerts, and screenshots. Any occurrence is a release
blocker. A custom endpoint path must be rejected without echoing it and must
never reach encoded catalog bytes.

Logs record only operation name, workflow/step/node identity, instance ID,
readiness/error code, duration, and safe endpoint. They do not record add-on
documents, variables, response bodies, SDK error descriptions, environment
snapshots, or attachment bytes.

## Rollout And Compatibility

This is one atomic cutover. Do not ship named configuration while some add-ons
still use local stores. The release order is:

1. pin a Kaiba revision exporting the accepted `KaibaClient` contract;
2. add and test the strict shared store/resolver and CLI;
3. migrate every add-on and add the source/runtime no-fallback gates;
4. integrate workflow preflight and workflow-instance node patches;
5. add native App CRUD/test/default/binding UI; and
6. update README/examples to create a default instance and remove deprecated
   local-store inputs or replace match-only remote assertions with stable-ID
   bindings.

A configured default preserves existing local-style workflows, including those
that still author inert `noteRoot`, `configPath`, or `databasePath`. A legacy
remote workflow is compatible only when its connection assertions exactly match
the resolved named instance. With no default, every unbound Kaiba workflow is
visibly not ready. Unknown/disabled explicit bindings and mismatched legacy
remote assertions remain errors after a default is added. There is no migration
window with local fallback.

## Issue-To-Design Mapping

| Accepted signal | Design sections |
| --- | --- |
| Stable, normalized, enabled, exactly-one-default, secret-safe persistence | Persistent Instance Contract; Redaction And Observability |
| Stable text/JSON CLI CRUD, test, and default selection | CLI Contract |
| Explicit binding then default, reference discovery, and all pre-node failure categories | Binding And Runtime Resolution; Binding reference discovery and removal consistency |
| Every registered Kaiba add-on uses HTTP(S) with no direct/local fallback | Current State And Required Cutover; Add-On Migration Matrix |
| Arbitrary GraphQL, typed conveniences, and mutation idempotency | Add-On Migration Matrix; Required idempotency |
| Native App CRUD, readiness, enablement, default, and per-node selection | RielaApp Contract |
| Persistence, resolver, redaction, CLI, transport, add-on, compatibility, and UI evidence | Verification Contract |

## Verification Contract

Automated coverage must include:

- store version/schema validation, duplicate IDs/names, root-or-`/graphql`
  endpoint restrictions, auth policy, default invariants including rejection of
  disabling the sole default, locking/atomicity, corrupt-store fail-closed
  behavior, deterministic ordering, every `lastTest` invalidation/enablement
  transition, stale async-test suppression, and token absence from encoded bytes;
- selector rules, explicit-binding precedence, default fallback only when the
  binding is absent, stale/disabled/invalid bindings, immutable execution
  snapshots, single-flight readiness, and side-effect-free memory-admin
  capability preflight;
- binding scans across project, user, default and overridden App roots,
  registered project/standalone roots, definition and instance-patch origins,
  canonical deduplication/order, malformed or changed-state failure, managed
  write serialization, unregistered-project exclusion, and identical CLI/App
  ordinary/forced removal results;
- CLI help, CRUD, default replacement, forced removal with dangling bindings,
  the complete fixed error matrix, text/JSON golden output,
  stdout/stderr/exit behavior, every readiness failure, and sentinel redaction;
- every add-on name in `RielaBuiltinAddonCatalog`, expected typed/arbitrary SDK
  calls through injected transports, payload compatibility, rejected control
  results, transport failures, cancellation, attachment bounds, and required
  idempotency behavior, reconstructed GraphQL envelope/status semantics, inert
  legacy local fields, and exact-match-only legacy remote assertions;
- runtime identity tests proving the first attempt and multiple consecutive
  unaccepted retries expose one `operationExecutionId`, while a later accepted
  loop iteration, a new run, and an explicit rerun expose different identities
  and automatically derived keys;
- injected-transport lost-response and multi-retry tests proving
  `notebook-ingest-pages`, primary `document-import`, translated-document
  ingest, and `memory-consolidate` resend the exact original wire key and body
  after the server-side mutation commits; each test must cover at least two
  consecutive retries, and the document test must also prove its primary and
  translation keys differ;
- adversarial idempotency tests proving authored identity-like variables cannot
  override automatic runtime identity, changed retry bodies surface
  `invalid_request`, and accepted loop iterations/new workflow runs receive
  distinct automatically derived keys;
- explicit-key compatibility tests proving the rendered authored value is the
  exact primary wire key, the translation request uses the documented suffix,
  both survive lost-response and multi-retry resumes, and an identical
  period-keyed consolidation replays across separate workflow runs;
- a source gate proving no forbidden imports/symbols and no local fallback;
- App support CRUD/test/default/binding models, stale-probe suppression,
  affected-binding removal, recovery actions, and accessibility labels; and
- AppKit layout tests plus current-executable list/detail/editor/binding/error
  screenshots at normal and constrained widths, with sentinel inspection.

Run at minimum:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaSupportTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaKaibaAddonsTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaCLITests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaAppSupportTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache
rg -n 'import (AppCore|AppGraphQL)|NoteService|SQLiteNoteDatabaseDriver|GraphQLHTTPDocumentClient|KAIBA_NOTE_ROOT|RIELA_NOTE_ROOT' Sources/RielaKaibaAddons
rg --files Sources Tests -g '*.swift' | xargs wc -l | sort -nr | head -25
.build/debug/riela kaiba instance --help
.build/debug/riela kaiba instance list --output json
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp
.build/arm64-apple-macosx/debug/RielaApp --app-root tmp/rielaapp-ui-review/app-root --home-root tmp/rielaapp-ui-review/home-root --project-root "$PWD" --open-workflows --no-autostart-daemons
git diff --check
```

The source-gate command must return no matches. Every non-generated Swift file
must remain below 1,000 lines. UI evidence must identify the direct executable
and window IDs used; `.build/debug/RielaApp.app` is not accepted unless its
executable is proven current.

## Decisions And Non-Goals

- Use one user-wide catalog and default; do not add project/profile catalogs.
- Persist stable IDs and treat names only as selectors/display labels.
- Rebuild binding references from the explicitly scoped persisted sources for
  every removal; do not persist a reverse index or crawl unrelated projects.
- Use the catalog lock for Riela-managed binding writes and removal scans;
  external edits outside that lock remain fail-closed at runtime.
- Narrow persisted endpoints to the server root or `/graphql`; do not expose the
  SDK's custom-path capability because such paths cannot be proven token-free.
- Resolve only explicit node binding, otherwise global default; do not add
  workflow/package recommendation precedence in this issue.
- Treat legacy local-store fields as inert compatibility inputs and legacy
  remote connection fields as exact-match assertions against the resolved named
  instance; neither form can select a route or create a fallback.
- Retain both GraphQL add-on names, but route both through `KaibaClient.execute`.
- Reconstruct arbitrary GraphQL `body` from decoded `data` and report
  compatibility status 200 because the accepted SDK exposes no raw envelope or
  HTTP status.
- Keep caller-owned document preparation while rejecting features with no SDK
  operation; never restore direct store access.
- Preserve explicit authored mutation keys for intentional cross-run replay;
  otherwise derive from the runtime-owned retry-lineage operation identity and
  never hash the current retry execution ID by itself.
- Do not add `instance default`; use canonical `show` and `set-default`.
- Treat this committed design as the complete normative contract; the
  gitignored intake ideal spec is provenance only and may be deleted.
- Do not build a secret manager, persist test diagnostics, add retries, support
  non-HTTP(S), change non-Kaiba workflow behavior, or modify Cursor CLI behavior.

No unresolved user decision blocks implementation. If implementation discovers
that a currently advertised add-on payload cannot be reproduced through the
accepted SDK, it must return to design/adversarial review rather than adding a
local fallback.

## Risks

- A partial migration can retain hidden local access. Control: catalog inventory
  tests plus the forbidden-symbol source gate, with zero matches required.
- A token can leak through a secondary rendering path. Control: no raw-token
  model field, root-or-`/graphql` persisted endpoints, fixed Riela diagnostics,
  SDK redaction, and cross-surface sentinel tests including screenshots and
  reflection.
- A stale binding can silently route to the default. Control: stable-ID-only
  bindings and fallback only when the field is absent.
- Concurrent CLI/App edits can lose state or break the default invariant.
  Control: locked reload-mutate-validate-atomic-replace transactions.
- An incomplete or racing binding scan can hide affected nodes. Control: finite
  explicit roots, strict scan failure, one managed binding/catalog lock,
  identical CLI/App scanner inputs, and fail-closed unknown IDs for external or
  out-of-scope edits.
- Remote HTTP or unauthenticated operation can expose data. Control: separate
  persisted opt-ins mapped to the SDK's secure-by-default policies and visible
  App warnings.
- Readiness adds startup latency and endpoint flakiness. Control: one bounded
  generic probe per distinct instance per execution, one additional
  side-effect-free memory capability probe only where required, injected
  transports in tests, and no automatic retries.
- A mutation can commit before its response is lost, and a resume can otherwise
  duplicate data. Control: a runtime-owned operation ID rooted at the oldest
  consecutive unaccepted execution for automatic keys, authoritative explicit
  keys for cross-run replay, and lost-response/multi-retry transport tests for
  every ingest and memory path.
- Legacy fields can silently select the wrong server. Control: local-store
  fields are inert, remote connection fields are match-only assertions, and any
  mismatch fails before transport.
- Document conversion and translation extraction can drift from current output.
  Control: fixture-level payload parity and explicit fail-closed rejection for
  S3/config-derived behavior the SDK cannot express.
- The implementation overlaps dirty `Package.swift`, Kaiba add-on files, CLI
  tests, and examples. Control: preserve, integrate, and never revert or stage
  unrelated user changes; no commit or push is authorized.
