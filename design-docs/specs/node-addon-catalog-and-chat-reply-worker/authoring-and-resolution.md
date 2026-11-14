# Node Add-on Catalog and Built-in Workers: Authoring and Resolution

This document defines an authored workflow add-on mechanism and the current
built-in worker add-ons: chat reply, agent worker, workflow package sandbox
review, x-gateway worker nodes, and mail-gateway worker nodes.

## Overview

Workflow authors often need common nodes whose behavior is operational rather
than business-specific. Examples include replying to a triggering chat event,
running a standard agent-backed implementation worker, querying/posting through
x-gateway, or reading/sending mail through mail-gateway without copying
container and credential plumbing into every workflow bundle.

Authors should be able to reference these nodes as built-in add-ons from
`workflow.json` without writing a `nodes/node-*.json` payload or maintaining
provider-specific operational code in each workflow.

The add-on mechanism is an authoring and resolution layer. It does not replace
node roles, `nodeType`, output contracts, or the runtime-owned SQLite message
model.

## Goals

- let `workflow.json.nodes[]` reference reusable built-in and third-party
  worker nodes
- keep add-on resolution deterministic, inspectable, and validation-friendly
- ship a small deterministic built-in catalog under the `riela/` namespace
- keep `riela/` reserved for runtime-provided add-ons while allowing
  non-`riela/` add-ons to be resolved by host-provided extension code
- allow non-`riela/` add-ons to be installed in project and user scope
  add-on roots under `<scope-root>/addons`
- keep provider SDKs and credentials outside workflow bundles
- make chat replies runtime-owned and idempotent
- preserve authored workflow round-trips; save/edit surfaces should keep the
  add-on reference rather than expanding it into generated node JSON
- allow future external add-on distribution without designing network fetching
  into workflow load or validation

## Non-Goals

- turning workflow bundles into package manifests
- downloading third-party add-ons at workflow load time
- allowing arbitrary add-on code execution from a workflow definition
- loading arbitrary executable add-on packages directly from a workflow bundle
- adding Slack, Discord, Telegram, or web-chat fields to `workflow.json`
- replacing `user-action` nodes, which remain the mechanism for mid-run human
  replies and approvals
- replacing ordinary `nodeFile` payloads for custom business workers

## Authoring Model

`workflow.json.nodes[]` gains an alternative to `nodeFile`: `addon`.

```json
{
  "workflowId": "chat-answer",
  "description": "Answer a chat message and post the answer back to the thread.",
  "defaults": {
    "maxLoopIterations": 3,
    "nodeTimeoutMs": 120000
  },
  "entryStepId": "step-answer",
  "nodes": [
    {
      "id": "answer",
      "role": "worker",
      "nodeFile": "nodes/node-answer.json"
    },
    {
      "id": "reply",
      "role": "worker",
      "addon": {
        "name": "riela/chat-reply-worker",
        "version": "1",
        "config": {
          "textTemplate": "{{inbox.latest.output.payload.text}}",
          "visibility": "public"
        },
        "inputs": {
          "replyPrefix": "Answer"
        }
      }
    }
  ],
  "steps": [
    {
      "id": "step-answer",
      "nodeId": "answer",
      "role": "worker",
      "transitions": [{ "toStepId": "step-reply" }]
    },
    {
      "id": "step-reply",
      "nodeId": "reply",
      "role": "worker",
      "transitions": []
    }
  ]
}
```

Rules:

- a node reference must provide exactly one of `nodeFile` or `addon`
- `addon` may be a string shorthand for the latest compatible built-in major
  version, but saved workflows should use the object form with an explicit
  `version`
- add-on nodes still participate in normal node ordering, step transitions,
  repeat metadata on registry nodes, completion rules, and role validation
- add-on nodes must declare `role: "worker"` unless a future add-on descriptor
  explicitly allows manager resolution; inferred worker role from `kind`,
  `control`, or `repeat` is not sufficient for add-on authoring
- `nodeType: "addon"` is a resolved runtime payload type produced by add-on
  resolution; workflow-local `nodes/node-*.json` files must not author it
- manager nodes must not use add-ons in the first iteration
- an add-on reference is part of authored workflow JSON; it is not copied into a
  `nodes/node-*.json` file during normal save/edit round-trips
- `addon.env` is an optional explicit mapping from add-on environment variable
  names to riela runtime environment variable names; ambient host environment
  variables are not forwarded implicitly
- `addon.inputs` is an optional invocation-specific variable map; resolved
  add-on inputs become the effective node payload `variables`
- `riela/` is a reserved namespace for built-ins; third-party references
  should use a distinct namespace such as `vendor/addon-name`

## Scoped Local Add-on Roots

Local add-ons can be installed under the same project/user scope model used for
workflows:

```text
<scope-root>/
  addons/
    <namespace>/
      <addon-name>/
        <version>/
          addon.json
          templates/
```

Examples:

```text
~/.riela/addons/acme/reviewer/1/addon.json
<project>/.riela/addons/team/release-note/1/addon.json
```

Rules:

- user-scope add-ons live under `~/.riela/addons` by default
- project-scope add-ons live under `<project>/.riela/addons` by default
- scope roots, including `addons`, are configurable through the scoped root
  resolver described in `design-docs/specs/design-user-scope-workflows.md`
- `RIELA_ADDON_ROOT` and `--addon-root` are direct add-on-root overrides,
  parallel to `RIELA_WORKFLOW_DEFINITION_DIR`; they point at the directory containing
  `<namespace>/<addon-name>/<version>/addon.json`
- `riela/` remains reserved for built-in runtime add-ons and must not be
  loaded from the filesystem add-on roots
- local filesystem add-ons are manifest/template add-ons in the first
  iteration; they must not execute arbitrary JavaScript, TypeScript, shell, or
  package lifecycle code during workflow load or validation

### Local Add-on Manifest

Each local add-on version has an `addon.json` manifest:

```json
{
  "name": "team/release-note",
  "version": "1",
  "description": "Generate a release note from upstream workflow output.",
  "allowedRoles": ["worker"],
  "resolution": {
    "kind": "node-payload-template",
    "nodeType": "agent",
    "executionBackend": "codex-agent",
    "model": "gpt-5.5",
    "promptTemplateFile": "templates/prompt.md"
  },
  "inputSchema": {
    "type": "object"
  },
  "configSchema": {
    "type": "object"
  }
}
```

First-iteration local manifest fields:

- `name`: must match the path-derived add-on name
- `version`: must match the path-derived version
- `description`: non-empty human-readable summary
- `allowedRoles`: only `["worker"]` initially
- `resolution.kind`: `node-payload-template`
- `resolution.nodeType`: one ordinary node execution type such as `agent`,
  `command`, `container`, or `user-action`
- template fields such as `promptTemplateFile` are resolved relative to the
  add-on version directory, not the workflow directory
- `configSchema`, `envSchema`, and `inputSchema` validate authored
  `addon.config`, `addon.env`, and `addon.inputs`

`resolution` is a node payload template, not executable code. Resolution rules:

- overlay the authored workflow node id onto the resolved payload id
- render string template fields with a small context containing `addon.config`,
  `addon.inputs`, and the authored `nodeId`
- resolve `*TemplateFile` paths from the add-on version directory
- merge `addon.inputs` into the resolved payload `variables` after manifest
  defaults, so workflow-authored inputs can override add-on defaults
- never copy `addon.env` into the payload except through descriptor-approved
  explicit environment binding fields

The resolved payload must be an ordinary node payload after template expansion.
Local manifests cannot produce runtime-owned native `nodeType: "addon"` payloads
or internal executor bindings. Those remain reserved for built-in runtime
descriptors until a separate trusted executor-registration design exists.

### Local Add-on Resolution

For a workflow loaded from the scoped workflow catalog, add-on lookup order is:

1. built-in runtime catalog for `riela/*`
2. explicit direct add-on root override, when supplied
3. project scope add-on root, when present
4. user scope add-on root
5. host-provided resolver functions

For direct workflow definition directory mode, scoped add-on roots are not
inferred from the direct workflow definition directory. The host may still pass explicit
resolver functions, or the caller may supply `--addon-root` /
`RIELA_ADDON_ROOT`.

When scoped catalog loading receives an explicit direct add-on root override,
that root is prepended to the scoped candidates. It does not suppress project or
user fallback when the direct root does not contain the requested
`(name, version)`.

Shadowing rules:

- add-on lookup is by `(name, version)`, not only by name
- if a higher-priority scope has the requested name but not the requested
  version, lookup continues to lower-priority scopes
- if more than one candidate exists for the exact `(name, version)`, the
  highest-priority scope wins and inspection output must show the resolved
  source path
- omitted versions may resolve only when exactly one compatible version exists
  in the selected source; otherwise validation fails and asks for an explicit
  version

The normalized runtime bundle should expose local add-on provenance:

```json
{
  "nodeId": "release-note",
  "source": {
    "kind": "local-addon",
    "scope": "project",
    "name": "team/release-note",
    "version": "1",
    "manifestPath": "<project>/.riela/addons/team/release-note/1/addon.json"
  }
}
```

## Add-on Descriptor

Each built-in add-on is defined by a descriptor owned by the runtime build.

```typescript
interface BuiltinNodeAddonDescriptor {
  readonly name: string;
  readonly version: string;
  readonly description: string;
  readonly allowedRoles: readonly ["worker"];
  readonly configSchema: JsonSchemaObject;
  readonly envSchema?: JsonSchemaObject;
  readonly inputSchema?: JsonSchemaObject;
  readonly execution:
    | { readonly kind: "node-payload-template" }
    | { readonly kind: "native-addon-executor"; readonly executor: string };
  readonly output: NodeOutputContract;
}
```

The descriptor may also contain an internal payload template, prompt template,
or native executor binding. Those implementation details are not authored in
workflow bundles.

Descriptor rules:

- `name` is namespaced; built-ins use the `riela/` prefix
- `version` is a catalog version, not a provider model version
- major versions are compatibility boundaries
- `configSchema` validates `addon.config` before the workflow can execute
- `envSchema`, when present, can restrict or describe `addon.env` bindings for
  runtime-owned add-ons that execute external tools
- descriptors without `envSchema` must reject `addon.env` rather than preserve a
  no-op mapping
- `inputSchema`, when present, validates `addon.inputs`; resolved add-on inputs
  become the effective node payload `variables`
- descriptor resolution must produce one effective node payload with the
  authored node id overlaid onto the descriptor template
- descriptor templates must not be allowed to change graph structure; they
  produce only the payload for the single referenced node
- native add-on executors may appear in the normalized runtime shape as
  add-on execution metadata, but authored node payloads should not write that
  internal executor binding directly in the first iteration

## Third-party Resolver Boundary

Third-party add-ons can be integrated through scoped local manifests or through
host code. Host-code integration is for add-ons that cannot be expressed as a
manifest/template add-on. A host application may provide resolver functions to
validation, load, save, and execution entry points. Each resolver receives the
authored add-on reference and either:

- returns `undefined`, or no payload and no issues, to indicate "not handled"
- returns validation issues for a handled but invalid add-on reference
- returns one effective `NodePayload` for the authored node id

```typescript
interface NodeAddonResolveInput {
  readonly nodeId: string;
  readonly addon: WorkflowNodeAddonRef;
  readonly path: string;
}

type NodeAddonPayloadResolver = (
  input: NodeAddonResolveInput,
) => NodeAddonResolveResult | undefined;
```

Resolver rules:

- built-in `riela/*` references are resolved by the runtime catalog and are
  not overrideable by third-party resolvers
- resolver-facing types such as `NodeAddonPayloadResolver`,
  `NodeAddonResolveInput`, `NodeAddonResolveResult`, `WorkflowNodeAddonRef`,
  `NodePayload`, and `ValidationIssue` are part of the package-root public API
  so host applications and third-party add-on packages can type their resolver
  exports without relying on private deep imports
- the package root must resolve to the side-effect-free library entry
  (`src/lib.ts` / built `dist/lib.js`), while the CLI entry remains separate, so
  importing resolver types or helpers does not execute the command-line program
- third-party resolvers should be registered explicitly by the host process
  through API options; CLI package discovery, executable local add-ons, and
  lockfile-backed loading are future work
- resolver composition should be forgiving for package authors: `undefined`
  means the resolver did not handle the reference and validation should continue
  to the next registered resolver
- handled resolver results may omit `issues`; omitted `issues` is normalized to
  an empty list so simple add-on packages can return only a `payload`
- public execution helpers must preserve resolver options when they delegate to
  the workflow runtime; otherwise add-ons would validate through low-level load
  paths but fail during normal host-driven execution
- GraphQL schema validation and save mutations are host validation entry points;
  when invoked in-process they must pass the request context's resolver options
  into workflow validation so editor validation behaves like save and execution
  and the typed request context must expose the same resolver options as
  `LoadOptions`
- editor-facing revision and inspection metadata must ignore synthetic
  `nodeFile` values on add-on nodes; only authored workflow-local node payload
  files are hashed or reported as editable node files
- resolver output is an ordinary node payload, so third-party add-ons can start
  by targeting existing `agent`, `command`, `container`, or `user-action`
  execution paths
- resolver output is treated as untrusted runtime input and is normalized
  through the same node payload validation used for workflow-local node files
  before it is accepted into the runtime bundle
- custom native `nodeType: "addon"` execution for third parties is not part of
  this phase; it requires a separate executor registration and provenance model
- resolver output must not return runtime add-on metadata; the host resolver
  boundary maps third-party references to ordinary node execution only
- resolver errors and malformed resolver results are converted into
  `ValidationIssue` records rather than crashing workflow validation
- synchronous and asynchronous third-party resolver entry points must use the
  same package-boundary normalization contract; async resolver callbacks must
  not be invoked in a pre-normalization loop that lets thrown errors or malformed
  results escape `validateWorkflowBundleDetailedAsync`
- resolver-provided `nodeValidationResults` are additive metadata on a handled
  result and must be preserved exactly when resolver errors, malformed outputs,
  or payload validation failures are converted to structural validation issues

### Add-on Executability Validation

Add-on descriptors and host resolvers may contribute node executability results
through the shared validation model in
`design-docs/specs/design-workflow-node-executability-validation.md`.

Rules:

- add-on validation returns `NodeValidationResult(status,message)` records
  rather than transport-specific CLI or GraphQL payloads
- built-in `riela/*` descriptors may provide bounded, side-effect-free
  `validate` hooks
- host-code resolvers may return validation results with the resolved payload
  when the host owns the add-on implementation
- local manifest/template add-ons remain schema-only in this phase; manifest
  validation may produce node results, but loading a manifest must not execute
  arbitrary JavaScript, TypeScript, shell, or package lifecycle code
- validation results must be attributed to the authored add-on node id and the
  step ids that use that registry node
- add-on validation must feed the same detailed validation output used by CLI,
  GraphQL, library callers, and runtime readiness

This keeps add-on executability DRY: the add-on descriptor owns its reusable
validation logic, while workflow validation owns result aggregation and
transport formatting.

## Loader and Validation Flow

Add-on resolution belongs between workflow JSON validation and runtime bundle
normalization:

1. Load authored `workflow.json`.
2. Validate each `WorkflowNodeRef` has exactly one source: `nodeFile` or
   `addon`.
3. Resolve `addon.name` and `addon.version` from the built-in catalog for
   `riela/*`, from scoped local add-on roots for manifest/template add-ons, or
   from host-provided third-party resolvers for other namespaces.
4. Validate `addon.config`, `addon.env`, and `addon.inputs` through the
   descriptor or resolver. Resolver invocation is a validation boundary:
   thrown resolver errors, rejected async resolver promises, and malformed
   resolver return values become `ValidationIssue` records with the authored
   add-on path; they do not escape library, CLI, GraphQL, or readiness
   validation calls as uncaught exceptions.
5. For local manifests and third-party resolvers, normalize the returned payload
   through ordinary node payload validation and reject runtime-owned add-on
   execution metadata.
6. Materialize an effective node payload in memory for execution,
   inspection, and validation.
7. Mark the payload provenance as add-on resolved metadata.

The normalized runtime bundle should expose enough metadata for inspection:

```json
{
  "nodeId": "reply",
  "source": {
    "kind": "builtin-addon",
    "name": "riela/chat-reply-worker",
    "version": "1"
  }
}
```

For local filesystem add-ons, `source.kind` is `local-addon` and includes the
resolved scope plus manifest path.

Persistence rules:

- runtime execution artifacts should include the resolved descriptor identity in
  `meta.json`
- final `output.json` publication and downstream `workflow_messages` insertion
  stay ordinary runtime-owned node output behavior
- workflow save/edit APIs preserve `addon` references and do not write generated
  `nodeFile` payloads unless an explicit future `workflow vendor-addon` command
  asks for that
