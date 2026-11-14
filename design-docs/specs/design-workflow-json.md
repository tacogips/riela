# Workflow JSON Design

This document defines the authored workflow bundle format. It is the authoritative schema direction for workflow definitions saved and executed by riela.

Supporting design:
`design-docs/specs/design-workflow-steps-and-node-reuse.md`.

Implementation references:

- `Sources/RielaCore/WorkflowModel.swift` for authored and normalized workflow
  models, node payload decoding, and core validation DTOs
- `Sources/RielaCLI/WorkflowResolution.swift` for runtime node patch
  enforcement, including model-freeze checks
- `Sources/RielaAddons/` for built-in add-on names, versions, and package
  manifest handling
- `Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift` for command and
  container node execution behavior

## Overview

A workflow bundle is a directory containing:

- `workflow.json`
- zero or more `steps/step-*.json` files when steps are file-backed
- one reusable node payload file per file-backed node registry entry
- optional prompt files referenced by node payloads

The runtime validates the authored bundle, resolves prompt files into effective prompt text, and executes the workflow.

## Directory Layout

Typical managed layout:

```text
<workflow-definition-dir>/
  <workflow-name>/
    workflow.json
    steps/
      step-manager.json
      step-implement.json
    nodes/
      node-manager.json
      node-coder.json
    prompts/
      coder.md
      coder-self-review.md
```

Notes:

- in scoped workflow lookup, `<workflow-definition-dir>` is `<scope-root>/workflows`;
  user scope defaults to `~/.riela/workflows` and project scope defaults to
  `<project>/.riela/workflows`
- `workflow.json.steps[]` order is canonical for editor presentation, while step transitions define legal routing.
- runtime execution artifacts are written outside the workflow-definition directory under the configured artifact root.
- the workflow keeps an explicit reusable node registry in `workflow.json.nodes[]`; node files are not inferred by filename convention.
- inline and file-backed steps are both valid; managed templates often use inline steps while larger workflows may keep step definitions under `steps/`.
- worker-only workflows are valid and omit `managerStepId`.

## `node-{id}.json`

Node payload files may now include a canonical node-level description:

- `id: string`
- optional `description: string`
- other node payload fields described below

`description` is intended to capture the node's authored purpose in a short human-readable sentence. It is distinct from:

- workflow-level `description`
- `output.description`, which describes the expected output contract rather than the node's overall role

Validation rules:

- when provided, `description` must be a non-empty string

## `workflow.json`

Authored shape:

```json
{
  "workflowId": "example",
  "description": "Example workflow definition showing the authored top-level fields.",
  "defaults": {
    "maxLoopIterations": 3,
    "nodeTimeoutMs": 120000,
    "fanoutConcurrency": 20,
    "timeoutPolicy": {
      "onTimeout": "fail"
    }
  },
  "managerStepId": "manager",
  "entryStepId": "manager",
  "nodes": [
    {
      "id": "manager-runtime",
      "nodeFile": "nodes/node-manager.json"
    },
    {
      "id": "coder",
      "nodeFile": "nodes/node-coder.json"
    }
  ],
  "steps": [
    {
      "id": "manager",
      "nodeId": "manager-runtime",
      "role": "manager",
      "transitions": [{ "toStepId": "implement" }]
    },
    {
      "id": "implement",
      "nodeId": "coder"
    }
  ]
}
```

Minimal worker-only authored shape:

```json
{
  "workflowId": "worker-only-example",
  "description": "One worker starts directly from an explicit entry step.",
  "defaults": {
    "maxLoopIterations": 3,
    "nodeTimeoutMs": 120000
  },
  "entryStepId": "main-worker",
  "nodes": [
    {
      "id": "coder",
      "nodeFile": "nodes/node-main-worker.json"
    }
  ],
  "steps": [
    {
      "id": "main-worker",
      "nodeId": "coder"
    }
  ]
}
```

### Top-Level Fields

Required for ordinary workflows without `extends`:

- `workflowId: string`
- `defaults.nodeTimeoutMs: number`
- `entryStepId: string`
- `nodes: WorkflowNodeRef[]`
- `steps: WorkflowStepRef[]`

Required for derived workflows with `extends`:

- `workflowId: string`
- `extends.workflowId: string`

For derived workflows, `defaults`, `entryStepId`, `nodes`, and `steps` are
inherited from the loaded base workflow and validated on the resolved derived
bundle after inheritance transformations are applied.

Optional:

- `description: string`
- `extends`
- `managerStepId: string`
- `prompts.rielaPromptTemplate: string`
- `prompts.workerSystemPromptTemplate: string`
- `defaults.maxLoopIterations` (defaults to the runtime default when omitted)
- `defaults.fanoutConcurrency` (legacy/static authoring default only; local
  live fanout execution uses the `StepTransitionFanout.concurrency` precedence
  documented below)
- `defaults.timeoutPolicy`
- `defaults.containerRuntime` (defaults to the runtime container runner default when omitted)
- `defaults.selfImprove` (dedicated retrospective self-improve defaults; see
  below)

Validation rules:

- `workflowId` is a filesystem namespace key for runtime artifacts and attachments, so it must start with an alphanumeric character and then contain only letters, digits, hyphens, or underscores
- when provided, `description` must be a non-empty string
- ordinary workflows must author `defaults.nodeTimeoutMs`, `entryStepId`,
  `nodes`, and `steps`; derived workflows with `extends` inherit those fields
  from the base workflow before final validation
- `entryStepId` must resolve to a step in the ordinary authored workflow or the
  resolved derived bundle
- `managerStepId`, when present, must resolve to a step in the ordinary authored
  workflow or the resolved derived bundle
- at most one step may declare `role: "manager"`
- if `managerStepId` is omitted and exactly one step declares `role: "manager"`, the validator infers that step as the manager step
- every step must reference a node registry entry through `nodeId`
- `nodes[]` must contain at least one node registry entry
- `steps[]` must be non-empty
- node registry ids must be unique
- step ids must be unique
- dedicated legacy top-level fields are rejected by key set in
  `Sources/RielaCore/WorkflowRawValidation.swift` (includes
  `managerRuntimeId`, `managerNodeId`, `entryNodeId`, `subWorkflows`,
  `workflowCalls`, `subWorkflowConversations`, `edges`, `loops`, and
  `branching`)
- dedicated legacy top-level field lists, rejection strings, canonical issue
  construction, and save-time authored-boundary stripping are centralized in the
  Swift workflow raw-validation and resolution paths
- `defaults.selfImprove`, when present, may contain only `enabled`, `mode`, and
  `defaultLogLimit`
- `defaults.selfImprove.enabled`, when present, must be boolean
- `defaults.selfImprove.mode`, when present, must be
  `report-only` or `report-and-auto-improve`
- `defaults.selfImprove.defaultLogLimit`, when present, must be a positive
  integer
- the save path may strip only normalized in-memory `hasManagerNode` and redundant node `kind` fields from workflow input before writing; it does not strip `managerRuntimeId`, `managerNodeId`, `entryNodeId`, `subWorkflows`, or other disallowed keys (validation rejects them, same as for on-disk `workflow.json`)
- the validator rejects top-level `workflow.workflowCalls` whenever the bundle is treated as step-addressed (`entryStepId` with `steps[]`); use step transitions instead
- cross-workflow invocation uses the same execution-address model as ordinary step calls rather than a dedicated top-level `workflowCalls` section
- calling another workflow means targeting an explicit step in that workflow; the canonical workflow-level entry is the callee workflow's `managerStepId`, or `entryStepId` when the callee is worker-only
- derived runtime cross-workflow dispatch rows and new `workflow-calls/*.json` metadata are step-addressed (`callerStepId`, `resumeStepId`) because the authored source of truth is `steps[].transitions`

Not part of the schema:

- `workflowType`
- `nodeGroups`
- `workflow-ref` sub-workflow definitions

Older documents mentioned those concepts, but they are not current authored fields.

### `extends`

`extends` lets a derived workflow inherit another workflow bundle by
`workflowId` and then apply bounded in-memory transformations. It is intended
for same-family workflow variants, such as Cursor CLI or Claude Code packages
that track a Codex workflow while changing agent backends/models and rewriting
same-family workflow references.

Minimal derived shape:

```json
{
  "workflowId": "cursor-cli-example",
  "description": "Cursor CLI variant of the Codex workflow.",
  "extends": {
    "workflowId": "codex-example",
    "stringReplacements": {
      "codex-example": "cursor-cli-example",
      "codex-agent": "cursor-cli-agent"
    },
    "agentNodePatch": {
      "executionBackend": "cursor-cli-agent",
      "model": "claude-sonnet-4-5"
    }
  }
}
```

Fields:

- `workflowId: string` is required and names the base workflow to load through
  the normal workflow-id discovery path
- optional `agentNodePatch` applies one node patch to inherited file-backed
  agent node payloads only
- optional `nodePatch` applies explicit node-id patches using the same field
  allowlist and validation rules as `--node-patch`
- optional `stringReplacements` maps non-empty source strings to replacement
  strings

Load-time behavior:

- workflows without `extends` keep the ordinary authored workflow load path
- the base workflow is loaded and validated first, including its file-backed
  steps, node payloads, prompt files, and add-on resolution
- inheritance transformations are in-memory only; the derived workflow directory
  and the base workflow directory are not rewritten
- the derived `workflowId` and optional `description` override the inherited
  values after the base bundle is materialized
- `stringReplacements` are for same-family workflow identifiers, backend labels,
  and related authored strings that need to point from the base family to the
  derived family
- workflow-local file references such as `nodeFile`, `stepFile`, and prompt
  template file paths are load provenance as well as authored strings. If a
  string replacement changes one of those paths, validation must either resolve
  an actual replacement file supplied by the derived bundle or keep the inherited
  base file path for lookup; it must not fail by looking only for a synthesized
  missing path such as `nodes/node-adhoc-claude-code.json`.
- `agentNodePatch` is convenience syntax for backend/model family variants; it
  must not patch add-on-backed nodes or non-agent execution nodes
- explicit `nodePatch` may override or complement `agentNodePatch` for named
  inherited node registry entries
- any run-time `LoadOptions.nodePatch` remains a caller-supplied non-persistent
  patch and must still apply after the inherited bundle is resolved
- final validation must describe the resolved derived bundle, not just the base
  bundle
- direct validation/inspection and cross-workflow callee validation share the
  same resolved derived bundle semantics. A transition targeting a derived
  callee must validate against the callee's effective `managerStepId` or
  `entryStepId` after `extends` has loaded.
- inheritance cycles fail validation

Boundaries:

- `extends` does not introduce template inheritance, partial authored overlays,
  or arbitrary deep merge semantics for `workflow.json`
- derived workflows should not redefine `nodes[]`, `steps[]`, `defaults`, or
  prompt files in the first implementation; such edits belong in the base
  workflow or a future explicit overlay design
- backend-specific behavior remains in existing agent adapters such as
  `codex-agent`, `cursor-cli-agent`, and `claude-code-agent`; the loader only
  rewrites data and applies validated node patches

### `defaults.selfImprove`

`defaults.selfImprove` configures the dedicated retrospective self-improve
service. It is not part of `defaults.supervision` and must not alter
`workflow run --auto-improve` behavior.

Example:

```json
{
  "defaults": {
    "selfImprove": {
      "enabled": true,
      "mode": "report-only",
      "defaultLogLimit": 10
    }
  }
}
```

Behavior:

- `enabled: false` disables automatic or scheduled self-improve for the
  workflow, while explicit operator calls may override with
  `workflow self-improve --enable-disabled`
- `mode: "report-only"` writes analysis reports without editing workflow files
- `mode: "report-and-auto-improve"` allows canonical workflow edits only after
  backup, validation, and policy checks
- `defaultLogLimit` overrides the global latest-run fallback limit for this
  workflow

Detailed design:
`design-docs/specs/design-self-improve.md`.

## `WorkflowNodeRef`

`workflow.json.nodes[]` entries form the reusable node registry:

- `id: string`
- `nodeFile: string` when the node uses a workflow-local payload
- optional `addon` when the node uses a built-in, scoped local, or
  host-provided add-on payload
- optional `execution` for registry-level required/optional scheduling policy
- optional `kind` for graph semantics such as `task`, `branch-judge`,
  `loop-judge`, `input`, or `output`
- optional `repeat` for loop policy (`while`, optional `restartAt`, optional
  `maxIterations`)

Validation rules:

- a node reference must provide exactly one of `nodeFile` or `addon`
- `id` must match `^[a-z0-9][a-z0-9-]{1,63}$`
- only `id`, `nodeFile`, `addon`, `execution`, `kind`, and `repeat` are accepted on authored node registry entries
- `execution.mode`, when present, must be `required` or `optional`
- `execution.decisionBy`, when present, must be `owning-manager`
- `repeat.while` is required when `repeat` is present; `repeat.maxIterations`, when present, must be a positive integer
- `riela/*` `addon` references are resolved from the built-in node add-on
  catalog into an effective node payload during load/validation
- non-`riela/` add-on references may resolve from scoped local add-on roots
  under `<scope-root>/addons`, or through explicit host-provided resolver
  functions passed through the library/server load, validation, save, and
  execution options
- workflow loading does not fetch third-party packages or registry metadata
- manager steps must currently reference file-backed node definitions; the
  current add-on contract is worker-only until manager-capable add-ons are
  designed explicitly
- manager/worker semantics are authored at the step or node payload level rather than through structural `kind` metadata

### `addon`

`addon` lets an authored node reference a reusable payload instead of a
workflow-local `nodeFile`. The source may be the built-in runtime catalog, a
scoped local add-on under `<scope-root>/addons`, or an explicitly registered
host resolver.

Object form:

```json
{
  "id": "reply",
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
```

Rules:

- saved workflows should prefer object form with explicit `version`
- string shorthand may be accepted for built-in add-ons, but should normalize to
  explicit object form in authoring tools
- unknown add-on names or unsupported versions fail validation
- `riela/` names are reserved for built-in add-ons and are not loaded from
  scoped local add-on roots
- local add-on lookup uses `(name, version)` and searches the caller workflow's
  owning scope, then project scope, then user scope, before falling back to
  host-provided resolvers
- `addon.config` is validated by the selected add-on descriptor
- `addon.env`, when present, maps add-on environment variable names to riela
  runtime environment variable names for add-ons whose descriptors support
  explicit environment bindings; no ambient environment variables are forwarded
  implicitly. Required source variables are reported by runtime readiness before
  execution, and empty required values are treated as unavailable; optional
  bindings set `required: false`
- `addon.inputs`, when present, is copied into the resolved node payload
  `variables`
- add-on node references participate in the same explicit registry as file-backed nodes
- save/edit surfaces preserve the authored `addon` reference rather than writing
  generated node payload JSON

### Built-in Add-on Package Boundary

The `riela/*` add-on catalog is runtime-owned. The Swift CLI resolves built-in
add-ons through `BuiltinWorkflowAddonResolver` in
`Sources/RielaCLI/ProductionNodeAdapter.swift`; native package add-ons are
resolved separately through `NativeBundleAddonResolver` in `Sources/RielaAddons`.

Rules:

- `riela/` names are reserved for runtime built-ins and are not loadable as
  third-party native-bundle registrations
- non-`riela/` add-ons may resolve from scoped local add-on roots or
  host-provided native-bundle registrations
- scenario-backed runs may intercept add-on execution for deterministic tests,
  then fall back to the production resolver
- built-in resolver validation is implementation-local and must reject
  unsupported versions, missing required config fields, and missing required
  `addon.env` sources before calling the provider adapter

Initial built-in add-ons:

- `riela/chat-reply-worker`: worker node that replies to the chat event target
  in `runtimeVariables.event` through the event reply adapter registry
- `riela/codex-sdk-worker`: worker node that dispatches through the official
  OpenAI SDK backend
- `riela/claude-sdk-worker`: worker node that dispatches through the official
  Anthropic SDK backend
- `riela/cursor-sdk-worker`: worker node that dispatches through the Cursor SDK
  adapter boundary
- `riela/gemini-sdk-worker`: worker node that resolves to an `agent` payload
  using `executionBackend: "official/gemini-sdk"` and explicit Gemini API key
  environment binding
- `riela/chat-persona-router`: worker node that chooses chat persona routing
- `riela/chat-memory-raw-daily-summary`: worker node that maintains raw and
  daily-summary chat memory
- `riela/chat-persona-memory-read` and `riela/chat-persona-memory-write`:
  worker nodes that read and write persona-scoped chat memory
- `riela/memory-save`, `riela/memory-update`, `riela/memory-load`, and
  `riela/memory-search`: worker nodes for file-backed workflow memory records
- `riela/x-digest`: worker node that summarizes X/Twitter data through the
  production X digest adapter
- `riela/gmail-digest`: worker node that summarizes Gmail/mail-gateway data
  through the production Gmail digest adapter
- `riela/time-signal`: worker node for scheduled time-signal payloads
- `riela/x-gateway-read`: worker node that runs the read-only
  `x-gateway-reader graphql query` surface in a Docker-compatible container
- `riela/x-gateway`: worker node that runs the full `x-gateway graphql query`
  surface for intentional query or mutation documents in a Docker-compatible
  container
- `riela/mail-gateway-read`: worker node that runs the read-only
  `mail-gateway-reader graphql --query` surface in a Docker-compatible
  container
- `riela/mail-gateway`: worker node that runs the full
  `mail-gateway graphql --query` surface for intentional query or send-mutation
  documents in a Docker-compatible container

Detailed design:
`design-docs/specs/design-node-addon-catalog-and-chat-reply-worker.md`.

## `WorkflowStepRef`

`workflow.json.steps[]` entries declare the executable addresses of the workflow.

Each step entry is authored in exactly one of two forms:

- file-backed: `id` plus `stepFile`
- inline: `id`, `nodeId`, and any optional inline step fields in `workflow.json`

File-backed example:

```json
{
  "id": "implement",
  "stepFile": "steps/step-implement.json"
}
```

Inline example:

```json
{
  "id": "self-review",
  "nodeId": "coder",
  "promptVariant": "self-review",
  "sessionPolicy": {
    "mode": "reuse",
    "inheritFromStepId": "implement"
  },
  "transitions": [
    { "toStepId": "finish", "label": "accepted" },
    { "toStepId": "implement", "label": "needs-fix" }
  ]
}
```

Required after step-file resolution:

- `id: string`
- `nodeId: string`

Optional inline step fields:

- `description: string`
- `role: "manager" | "worker"`
- `promptVariant: string`
- `timeoutMs: number`
- `sessionPolicy`
- `transitions`

Validation rules:

- `id` values are unique within the workflow
- a file-backed authored step contains `id` and `stepFile`; an inline authored step contains `id`, `nodeId`, and optional inline fields
- only `id`, `stepFile`, `nodeId`, `description`, `role`, `promptVariant`, `timeoutMs`, `sessionPolicy`, and `transitions` are accepted on authored step entries
- when `stepFile` is used in source authoring, the inline step fields `nodeId`, `description`, `role`, `promptVariant`, `timeoutMs`, `sessionPolicy`, and `transitions` must not be authored on the same entry; loading resolves the file into a complete step before validation
- when `stepFile` is used, the loaded step definition must resolve to the same `id`
- `nodeId` must resolve through `workflow.json.nodes[]`
- when `role` is omitted, the step named by `managerStepId` is treated as the manager execution site and all other steps default to worker execution sites
- manager-role steps must reference file-backed nodes; add-on-backed registry entries are worker-only
- `transitions[]` target step ids, not node ids
- `sessionPolicy.inheritFromStepId`, when present, must reference an authored step in the same workflow
- step-local `timeoutMs`, prompt, and session settings override node defaults for that step usage site only

## `StepTransition`

`transitions[]` define the legal next execution addresses for one step.

Shape:

- `toStepId: string`
- optional `toWorkflowId: string`
- optional `resumeStepId: string` (required when `toWorkflowId` is present)
- optional `label: string`
- optional `fanout: StepTransitionFanout`

Rules:

- when `toWorkflowId` is omitted, the transition stays inside the current workflow
- when `toWorkflowId` is present, the transition targets another workflow using the same execution-address contract as any other step call
- when `toWorkflowId` is present, `resumeStepId` must name a step in the **current** workflow to queue after the callee workflow completes (same handoff role historically associated with removed top-level `workflowCalls[].resultNodeId` authoring)
- `resumeStepId` must be omitted for local in-workflow transitions (`toWorkflowId` absent)
- a step may have at most one cross-workflow transition
- cross-workflow transitions must target the callee workflow's callable entry step, which is normally its `managerStepId`, or `entryStepId` for a worker-only workflow
- transitions always target steps, never raw node ids
- optional `label` uses the same expression grammar as the `when` field on
  step-derived routing edges; `WorkflowBranchEvaluator` treats an omitted label
  as unconditional. For cross-workflow transitions, omitted `label` means the
  derived cross-workflow dispatch is unconditional. When set, `label` gates both
  local transition selection and cross-workflow dispatch matching.
  Step-authored cross-workflow transitions are **not** copied onto
  `workflow.workflowCalls` during normalization; the engine and inspection
  surfaces derive the effective dispatch list from `steps[]`

### `StepTransitionFanout`

`fanout` defines bounded parallel branch execution from one selected transition
and an explicit join back into the current workflow.

Initial dynamic shape:

```json
{
  "groupId": "feature-design",
  "itemsFrom": "/payload/features",
  "itemVariable": "feature",
  "concurrency": 20,
  "joinStepId": "join-feature-design",
  "failurePolicy": "fail-fast",
  "resultOrder": "input"
}
```

Fields:

- `groupId: string`
- `itemsFrom: string`
- optional `itemVariable: string`
- optional `concurrency: number`
- `joinStepId: string`
- optional `failurePolicy: "fail-fast" | "collect-all"`
- optional `resultOrder: "input"`

Rules:

- `itemsFrom` is a JSON Pointer into the source step output payload and must resolve to an array at runtime
- each source item creates a distinct branch work item, so the same target step may execute once per item without queue dedupe collapsing the branches
- `concurrency` defaults to the source item count when omitted; a run-level
  `maxConcurrency` value is an optional command-level cap when present and
  lower than the per-transition-or-item-count bound.
  `defaults.fanoutConcurrency` is not the local live fanout default for this
  execution path.
- `joinStepId` must reference a current-workflow step and is queued once after all required branch work succeeds
- for cross-workflow fanout, authored `resumeStepId` remains required and must equal `fanout.joinStepId`
- branch outputs are aggregated in source item order and delivered to the join step through runtime-owned communication artifacts
- partial-success joins are out of scope for the initial schema; `fail-fast` stops on first branch failure, while `collect-all` waits for terminal branch states and then fails if any branch failed

Detailed design:
`design-docs/specs/design-bounded-fanout-join-workflow-execution.md`.

## Removed Fields

The authored workflow schema does not include:

- `CompletionRule`
- `workflowCalls[]`
- top-level `edges[]`
- `LoopRule`
- `subWorkflows[]`
- `subWorkflowConversations[]`
- branch/loop judge metadata

Routing is step-addressed through `transitions[]`. Branching, repetition, and cross-workflow manager calls are all expressed through ordinary transitions between explicit execution addresses.

## `node-{id}.json`

Nodes referenced with `addon` do not author a `node-{id}.json` file. The loader
materializes their effective payload from the selected add-on descriptor,
scoped local add-on manifest, or host resolver during validation. Save/edit
surfaces preserve the `addon` reference in `workflow.json`.

Authored shape:

```json
{
  "id": "implement",
  "executionBackend": "codex-agent",
  "model": "gpt-5.5",
  "modelFreeze": false,
  "promptTemplateFile": "prompts/implement.md",
  "variables": {},
  "sessionPolicy": {
    "mode": "reuse"
  },
  "output": {
    "description": "Return the implementation result."
  }
}
```

### Core Fields

Required:

- `id`
- `variables`

Optional:

- `description`
- `nodeType`
- `managerType`
- `workingDirectory`
- `executionBackend`
- `model`
- `modelFreeze`
- `sessionPolicy`
- `systemPromptTemplate`
- `systemPromptTemplateFile`
- `promptTemplate`
- `promptTemplateFile`
- `sessionStartPromptTemplate`
- `sessionStartPromptTemplateFile`
- `promptVariants`
- `command`
- `container`
- `durability`
- `userAction`
- `sleep`
- `argumentsTemplate`
- `argumentBindings`
- `templateEngine`
- `timeoutMs`
- `output`

Important rules:

- omitted `nodeType` defaults to `agent`
- `agent` nodes require `executionBackend`, `model`, and `promptTemplate` unless a manager code-path default is explicitly allowed by the loader
- authored node payloads should include `modelFreeze` as a boolean for an
  explicit patching contract; omitted `modelFreeze` is accepted for
  compatibility and defaults to `false`
- manager-role nodes must stay on the agent execution path; `command`,
  `container`, `user-action`, `sleep`, and runtime-owned `addon` payloads are
  worker execution paths
- `managerType` is valid only for manager-role nodes; worker steps must not
  reference payloads that declare `managerType`
- `systemPromptTemplateFile` is resolved into `systemPromptTemplate` during load
- `promptTemplateFile` is resolved into `promptTemplate` during load
- `sessionStartPromptTemplateFile` is resolved into `sessionStartPromptTemplate` during load
- authored JSON must use the canonical field names

### `nodeType`

Supported authored values, including the scheduled sleep runtime target:

- `agent`
- `command`
- `container`
- `sleep`
- `user-action`

Target execution behavior for this schema:

- `agent`, `command`, `container`, `sleep`, and `user-action` nodes are
  accepted by the validator
- in full workflow execution, `sleep` nodes pause the node executor for the
  declared `sleep.durationMs` (cancellation-cooperative, bounded by the step's
  node timeout) and complete with a deterministic
  `{provider: "sleep", status: "completed", durationMs}` payload; migrating
  long pauses to a non-blocking scheduled continuation event through the
  shared scheduled event manager remains a future target
- in full workflow execution, `user-action` nodes persist a request artifact,
  mark the session `paused`, and wait for external/user input rather than
  running an agent, command, or container
- direct step execution rejects `user-action` nodes; they require the full
  workflow session lifecycle
- `nodeType: "addon"` is runtime-owned and must not be authored in node payload files; author add-ons through `workflow.json.nodes[].addon`

### `sleep`

`sleep` is required when `nodeType` is `sleep` and invalid for other node types.
Sleep nodes pause the current workflow execution for `durationMs` inside the
node executor (implemented behavior; see `examples/scheduled-sleep` and
`examples/loop-concurrency-lease`). A missing `sleep` object degrades to a 0ms
no-op pause. Registering the continuation in a shared scheduled event pool
instead of blocking is a future runtime target.

Rules:

- exactly one wake condition is required for the first implementation
- `durationMs` must be a positive integer when present
- the pause runs inside the step attempt, so `durationMs` must stay below the
  effective node timeout or the step fails on timeout
- `until`, if supported, must be a timestamp with an explicit timezone or UTC
  offset
- `promptTemplate`, `promptTemplateFile`, `model`, `executionBackend`,
  `sessionPolicy`, `command`, `container`, `userAction`, and `durability` must
  be omitted
- `variables` remains required, as with other node payloads

Shape:

```json
{
  "durationMs": 30000
}
```

### `executionBackend`

Current backend values:

- `codex-agent`
- `claude-code-agent`
- `cursor-cli-agent`
- `official/openai-sdk`
- `official/anthropic-sdk`

`model` is backend-specific model naming. It is required for executable `agent` nodes.

For `agent` nodes, `model` must be a provider or backend-specific model name. Do not put CLI-wrapper identifiers such as `codex-agent`, `claude-code-agent`, `tacogips/codex-agent`, or `tacogips/claude-code-agent` in `model`.

Codex-specific node variables:

- `codexAdditionalArgs`: array of strings appended to the generated `codex exec`
  argv for advanced backend flags
- `codexUnifiedExec`: optional boolean; omitted or `false` appends
  `--disable unified_exec` so codex-agent records completed command events
  reliably. `true` opts back in to Codex unified exec for workflows that
  explicitly need shell-state persistence across commands.
- `codexToolRecovery`: optional string, `off` (default) | `observe` |
  `recover`. Enables terminal tool-child stall handling for codex-agent
  nodes: a started `command_execution` whose child process is terminal
  (zombie/vanished) while the codex host stays alive and never publishes the
  completion is classified as an incident. `observe` records redacted
  incident diagnostics in the backend event stream; `recover` additionally
  requests host-side completion, then performs a bounded ownership-validated
  process-group SIGTERM → grace → SIGKILL cleanup so supervision
  (`--auto-improve`) can retry within existing budgets. Generic wait/status
  heartbeats and agent-silence warnings never create terminal-child evidence.
- `codexToolRecoveryGraceMs`: optional positive integer (default `30000`);
  how long a correlated terminal child may miss its host completion before
  it classifies as an incident.
- `codexToolRecoveryCleanupGraceMs`: optional positive integer (default
  `5000`); grace between the cleanup SIGTERM and SIGKILL escalation.
- `codexToolRecoveryAllowContinuation`: optional boolean (default `false`);
  same-attempt continuation opt-in. Even when `true`, continuation requires
  an acknowledged terminal tool result and an intact stream — which the
  current codex host protocol cannot prove — so recovery stays fail-closed
  and routes confirmed incidents through supervised retry/rerun.

### `modelFreeze`

`modelFreeze` is an optional boolean on authored node payloads. Omitted values
default to `false` for compatibility with older packages. Authors should still
write it explicitly so the model patching contract is visible in serialized
workflow files.

Rules:

- `false` allows explicit run-time node patches to replace `model`
- `true` allows the node to keep its authored model even when other node patch
  fields are applied; a patch that changes `model` fails validation for that
  node
- omitted `modelFreeze` has the same patching semantics as explicit `false`,
  including for non-agent payload shapes such as `command`, `container`,
  `sleep`, and `user-action` because they share the same node payload envelope

### `userAction`

`userAction` is required when `nodeType` is `user-action` and invalid for other node types.

Rules:

- `messageToolIds` is required and must contain at least one tool id
- `notificationToolIds`, when present, is additive and does not replace
  `messageToolIds`
- `messageToolIds` and `notificationToolIds` entries must be non-empty strings
- only `messageToolIds`, `notificationToolIds`, `replyPolicy`,
  `allowStructuredReply`, and `allowFreeTextReply` are accepted on
  `userAction`
- `allowStructuredReply` and `allowFreeTextReply`, when present, must be
  booleans
- `promptTemplate` or `promptTemplateFile` must describe the user-facing action request
- `model`, `executionBackend`, `sessionPolicy`, `command`, `container`, and `durability` must be omitted
- `variables` remains required, as with other node payloads

Shape:

```json
{
  "messageToolIds": ["chat"],
  "notificationToolIds": ["desktop"],
  "replyPolicy": "first-valid-reply-wins",
  "allowStructuredReply": true,
  "allowFreeTextReply": true
}
```

Supported values:

- `replyPolicy: "first-valid-reply-wins"`

### `sessionPolicy`

Shape:

```json
{
  "mode": "reuse",
  "inheritFromStepId": "plan"
}
```

Supported modes:

- `new`
- `reuse`

Omitted `sessionPolicy`, an omitted `mode`, and explicit `new` start a fresh
backend session. `reuse` asks the backend adapter to resume a session inside
the current workflow-session boundary. With `inheritFromStepId`, resolution
targets that exact workflow step; without it, resolution uses the latest
backend session known to the current workflow session. If no session can be
resolved, execution falls back to a fresh session. Fanout branches have
distinct workflow-session identities and cannot inherit one another's backend
sessions. `inheritFromStepId` is invalid unless `mode` is `reuse`.

Codex-specific capture, fallback, and readiness behavior is detailed in
`design-docs/specs/design-riela-52-codex-session-reuse.md`.

When a node also declares `sessionStartPromptTemplate`, the runtime renders a
fresh prompt containing that template plus the ordinary prompt and a resumed
prompt containing only the ordinary prompt. The adapter selects the fresh
form for `new`, absent policy, or unresolved-reuse fallback, and selects the
resumed form only after resolving a prior backend session. Output-validation
retries repeat that resolution: a successful fresh fallback that captured a
session id resumes without the session-start text, while explicit `new` or an
id-less fallback creates another fresh session and includes the text again.

## Structured Arguments

`argumentsTemplate` and `argumentBindings` let the runtime build structured arguments separately from prompt text.

`ArgumentBinding` fields:

- `targetPath`
- `source`
- optional `sourceRef`
- optional `sourcePath`
- optional `required`

Supported `source` values:

- `variables`
- `node-output`
- `workflow-output`
- `human-input`
- `conversation-transcript`

## Output Contracts

`output` shape:

- optional `description`
- optional `jsonSchema`
- optional `maxValidationAttempts`

Rules:

- at least one of `description` or `jsonSchema` must be present when `output` exists
- the runtime validates candidate payloads before writing final `output.json`
- candidate-file submission is only allowed when `output` is configured

## Runtime Input Provenance

Worker prompt variables include the merged payload from direct workflow
messages for backward compatibility. They also include `_rielaInput`, a
runtime-owned object that preserves the source of those messages without
requiring authors to infer it from merged top-level keys.

Shape:

```json
{
  "_rielaInput": {
    "workflowExecutionId": "workflow-session-id",
    "stepId": "current-step-id",
    "communicationIds": ["comm-000001"],
    "sourceStepIds": ["previous-step-id"],
    "messages": [
      {
        "communicationId": "comm-000001",
        "workflowExecutionId": "workflow-session-id",
        "fromStepId": "previous-step-id",
        "toStepId": "current-step-id",
        "sourceStepExecutionId": "previous-step-attempt-1-exec-1",
        "deliveryKind": "direct",
        "routingScope": "workflow",
        "lifecycleStatus": "delivered",
        "createdOrder": 1,
        "payload": {}
      }
    ],
    "latest": {
      "communicationId": "comm-000001",
      "payload": {}
    }
  }
}
```

Rules:

- `_rielaInput.latest.payload` is the authoritative direct input for finalizer
  or review-output nodes that must use the immediately preceding step result
- `messages` preserves ordered resolvable inputs after lifecycle filtering
- `_rielaInput` is runtime-owned and may overwrite a same-named key from a
  worker payload
- top-level merged keys remain for compatibility but should not be used when
  provenance or same-key conflict resolution matters

## Node Order

Presentation ordering is defined directly by the array order of `workflow.json.steps[]`.
The runtime and editor derive indent/color from workflow graph structure rather than persisted visualization metadata.

## Validation Notes

- `executionBackend` is required for agent nodes; backend identifiers encoded in `model` are rejected

## Non-Goals

These are not part of the authored workflow format:

- concurrent `nodeGroups`
- `workflowType`
- workflow-ref child workflow execution

## References

- `design-docs/specs/architecture.md`
- `design-docs/specs/design-data-model.md`
