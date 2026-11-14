# Workflow Instance Unification (CLI × RielaApp)

## Summary

Riela currently has two disjoint mechanisms for customizing how a workflow runs:

1. The `riela workflow run` CLI overrides node models/backends/effort through ad-hoc
   per-run flags (`--node-patch`, `--variables`) that leave no persistent record.
2. RielaApp has a first-class **instance** concept
   (`WorkflowInstance` / `RielaAppDaemonWorkflowPreference`): a named, persisted,
   profile-scoped configuration of a workflow source that carries working directory,
   environment, default variables, and per-node patches — but it is invisible to the
   CLI, GraphQL, and the core runtime.

This design makes **instance the canonical execution-configuration unit** across the
whole product. Every workflow execution — CLI, GraphQL, event-triggered, and RielaApp
daemon — runs *an instance* of a workflow:

- A bare `riela workflow run <workflow>` runs the workflow's implicit **default
  instance** (no overrides).
- One workflow can have **multiple named instances**, persisted per scope
  (project / user / RielaApp profile), selectable at run time with `--instance`.
- Per-run override flags (`--variables`, `--node-patch`) no longer exist as a separate
  mechanism: they construct a **temporary instance** layered on top of the selected
  base instance, recorded in the session for provenance and optionally savable as a
  named instance.

The RielaApp instance model is treated as the semantic source of truth; its data
structures are promoted (in generalized form) into `RielaCore` so that CLI, GraphQL,
runtime, and RielaApp all share one model, one precedence rule, and one enforcement
path (e.g. `modelFreeze`).

## Current Architecture (verified 2026-07-07)

### CLI per-run override path

- `riela workflow run` parses `--variables <json|@file>` and `--node-patch <json|@file>`
  (`Sources/RielaCLI/ParsedWorkflowOptions.swift:123-127`).
- `DefaultWorkflowNodePatchApplier` (`Sources/RielaCLI/WorkflowResolution.swift:331-386`)
  mutates `bundle.nodePayloads` before the run. Supported patch fields per node id:
  `executionBackend`, `model`, `effort`. It enforces `AgentNodePayload.modelFreeze`
  (`NodePatchError.modelChangeFrozen`).
- Variable precedence at prompt render time
  (`Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift:39-73`), lowest to
  highest: node `variables` defaults → CLI `--variables` → resolved step input payload.
- Remote execution carries the same shape: `WorkflowRemoteRunRequest.runtimeVariables`
  and `.nodePatch` flow into the `ExecuteWorkflow` GraphQL mutation
  (`Sources/RielaCLI/WorkflowCommands.swift:253-401`).
- Execution provenance: `WorkflowStepExecution.adapterOutput.model` records the model
  actually used (`Sources/RielaCore/RuntimeSession.swift:127-149`), but the *session*
  records nothing about which overrides produced the run.

### RielaApp instance model

- `WorkflowInstance` (`Sources/RielaAppSupport/WorkflowInstance.swift:4-62`):
  identity + source candidate + preference; `configured` vs `unconfigured` factory
  distinction.
- `RielaAppDaemonWorkflowPreference` / `RielaAppDaemonWorkflowConfiguration` /
  `RielaAppDaemonWorkflowNodePatch`
  (`Sources/RielaAppSupport/RielaAppDaemonWorkflowPreference.swift:6-232`):
  per-instance `workingDirectory`, `environmentFilePath`, `environmentVariables`,
  `defaultVariables` (JSONObject), and `nodePatches: [String: NodePatch]` with exactly
  the same three override fields as the CLI patch applier (`executionBackend`,
  `model`, `effort`).
- Persistence: `RielaAppDaemonWorkflowState` (version 1) in
  `~/.riela/rielaapp/profiles/<profile>/daemon-workflows.json` via
  `RielaAppDaemonWorkflowStore`; instances keyed by local identity, profile-scoped
  via `RielaAppProfileInstanceIdentity`
  (`Sources/RielaAppSupport/RielaAppProfiledWorkflowInstance.swift:4-72`).
- One workflow source can have many instances (`preference.sourceIdentity` →
  `candidate.id`); workflow definitions do not know about their instances.
- Lifecycle is app/UI-only: `EntryPoint+DaemonInstances.swift` (add/start/stop/
  restart/remove); no `riela instance …` CLI verbs, no GraphQL instance surface.

### Gaps

- **G1 — Two disjoint override mechanisms.** The CLI's `--node-patch`/`--variables`
  and RielaApp's instance configuration express the same intent with duplicated,
  unshared types (`RielaAppDaemonWorkflowNodePatch` vs the CLI patch applier's inline
  JSON contract). Nothing guarantees they stay in sync.
- **G2 — Instances invisible outside RielaApp.** No CLI or GraphQL operation can
  list, create, inspect, or run an instance. An operator who configured an instance
  in the App cannot reproduce that exact run from the terminal.
- **G3 — No default-instance semantics.** A bare CLI run has no instance identity,
  so sessions cannot be correlated to a configuration and "the same run as before"
  is not expressible.
- **G4 — No provenance for per-run overrides.** A run patched via `--node-patch`
  records only the final per-step model; the session does not record which base
  configuration + overrides produced it, so reruns/audits cannot reconstruct intent.
- **G5 — Inconsistent enforcement.** `modelFreeze` is enforced only in the CLI patch
  applier. RielaApp `nodePatches` are applied by a separate path with no shared
  enforcement (must be verified and unified during implementation).
- **G6 — Storage fragmentation.** Instance persistence exists only in RielaApp
  profile files. There is no project- or user-scope instance storage aligned with the
  existing workflow scope model (project workflows, user workflows, packages).

## Design

### Canonical model (new, in RielaCore)

New file `Sources/RielaCore/WorkflowInstanceModel.swift`:

```swift
/// One override entry for a node; identical field set for CLI, GraphQL, and App.
public struct WorkflowInstanceNodePatch: Codable, Equatable, Sendable {
  public var executionBackend: NodeExecutionBackend?
  public var model: String?
  public var effort: NodeReasoningEffort?
}

/// The full execution configuration an instance carries.
public struct WorkflowInstanceConfiguration: Codable, Equatable, Sendable {
  public var workingDirectory: String?
  public var environmentFilePath: String?
  public var environmentVariables: [String: String]
  public var defaultVariables: JSONObject
  public var nodePatches: [String: WorkflowInstanceNodePatch]
}

/// A persisted, named instance of a workflow.
public struct WorkflowInstanceDefinition: Codable, Equatable, Sendable {
  public var identity: String            // unique within its scope
  public var workflowId: String          // workflow definition id
  public var sourceIdentity: String?     // resolved source (package/project/user)
  public var displayName: String?
  public var configuration: WorkflowInstanceConfiguration
}

/// How the instance used by a run came to be.
public enum WorkflowInstanceKind: String, Codable, Sendable {
  case `default`    // implicit, zero-override instance of the workflow itself
  case named        // persisted instance selected by identity
  case temporary    // named/default base + per-run overrides (not persisted)
}
```

Semantics:

- **Default instance.** Every workflow implicitly has exactly one default instance:
  `identity == "default"`, empty configuration. `riela workflow run <wf>` with no
  instance flags resolves to it. No storage entry is required or created.
- **Named instance.** Persisted `WorkflowInstanceDefinition`. Multiple named
  instances may reference the same `workflowId`. Identity is unique per (scope,
  workflowId); display collisions across scopes resolve with the same precedence as
  workflow sources (project > user).
- **Temporary instance.** Constructed at run time from a base instance (default or
  named) plus per-run overrides. It exists only in the run request and in session
  provenance. `--save-instance <name>` persists the materialized temporary instance
  as a named instance.

### Effective-instance resolution (single shared path)

New `Sources/RielaCore/WorkflowInstanceResolver.swift`:

```swift
public struct EffectiveWorkflowInstance: Sendable {
  public var identity: String
  public var kind: WorkflowInstanceKind
  public var baseIdentity: String?            // for temporary: the base instance
  public var configuration: WorkflowInstanceConfiguration  // fully merged
}

public enum WorkflowInstanceResolver {
  /// Merge base instance + run overrides; apply nodePatches to payloads.
  /// Enforces modelFreeze for ALL callers (CLI, GraphQL, App daemon).
  public static func resolve(
    base: WorkflowInstanceDefinition?,        // nil => default instance
    runVariables: JSONObject,
    runNodePatch: [String: WorkflowInstanceNodePatch],
    nodePayloads: [String: AgentNodePayload]
  ) throws -> (instance: EffectiveWorkflowInstance,
               nodePayloads: [String: AgentNodePayload])
}
```

- The node-patch application logic moves from
  `Sources/RielaCLI/WorkflowResolution.swift` (`DefaultWorkflowNodePatchApplier`)
  into this resolver; the CLI applier becomes a thin adapter so existing callers and
  `NodePatchError` behavior (including `modelChangeFrozen`) are preserved. RielaApp's
  daemon start path is switched to the same resolver, closing G5.
- Merge precedence (lowest → highest):
  1. node payload defaults (`AgentNodePayload.variables`, `.model`, …)
  2. instance `configuration` (defaultVariables, nodePatches, env, workingDirectory)
  3. per-run overrides (`--variables`, `--node-patch`)
  4. resolved step input payloads (unchanged, applied at prompt render time)
  This preserves today's CLI behavior exactly when no instance is selected (layers
  2 is empty for the default instance).
- Environment layering: instance `environmentFilePath` is loaded first, then
  `environmentVariables` override it, then process environment of the runner applies
  per existing backend rules. Working directory: run-level `--working-dir` (where it
  exists today) beats instance `workingDirectory`, which beats workflow default.

### Instance storage and scopes

New `Sources/RielaCore/WorkflowInstanceStore.swift` (protocol) +
`Sources/RielaCLI/FileWorkflowInstanceStore.swift`:

```swift
public protocol WorkflowInstanceStoring: Sendable {
  func list(workflowId: String?) throws -> [WorkflowInstanceDefinition]
  func find(identity: String, workflowId: String?) throws -> WorkflowInstanceDefinition?
  func save(_ instance: WorkflowInstanceDefinition) throws
  func remove(identity: String, workflowId: String?) throws
}
```

- **Project scope**: `<project data root>/instances.json` next to the existing
  project-scope riela data (same root resolution as project workflows / session
  store; exact directory reuses the current project data-dir resolution, no new
  root). Version-tagged envelope: `{ "version": 1, "instances": { ... } }`.
- **User scope**: `~/.riela/instances.json`, same envelope.
- **RielaApp profile scope**: remains `daemon-workflows.json`, but its
  `RielaAppDaemonWorkflowConfiguration`/`NodePatch` payloads are re-expressed as the
  shared `WorkflowInstanceConfiguration`/`WorkflowInstanceNodePatch` (see App
  alignment below). The App store gains a `WorkflowInstanceStoring` conformance so
  GraphQL/CLI listing can include profile instances when running on the same machine
  (read-only from CLI in this phase).
- Lookup precedence for `--instance <name>`: project → user. Ambiguity across scopes
  is reported with the winning scope named; `--instance-scope project|user` breaks
  ties explicitly.

### CLI command surface

New `riela instance` command group (`Sources/RielaCLI/InstanceCommands.swift`):

```bash
riela instance list [--workflow <id>] [--scope project|user|all] [--output table|json|jsonl]
riela instance show <identity> [--workflow <id>]
riela instance create <identity> --workflow <id> \
    [--variables <json|@file>] [--node-patch <json|@file>] \
    [--working-dir <path>] [--env-file <path>] [--env KEY=VALUE ...] \
    [--display-name <name>] [--scope project|user]
riela instance update <identity> [... same setters ...]
riela instance remove <identity> [--scope project|user]
```

`riela workflow run` changes (`ParsedWorkflowOptions`):

```bash
# default instance (today's behavior, unchanged)
riela workflow run my-workflow

# run a named instance
riela workflow run my-workflow --instance prod

# temporary instance = named base + per-run overrides
riela workflow run my-workflow --instance prod --node-patch '{"analyzer":{"model":"..."}}'

# persist the temporary instance for reuse
riela workflow run my-workflow --instance prod --variables @vars.json --save-instance prod-hotfix
```

- `--variables` / `--node-patch` keep their exact syntax and semantics; their
  *specification* changes to "temporary-instance overrides on top of the selected
  base instance". With no `--instance`, base = default instance ⇒ byte-for-byte
  today's behavior. No deprecation.
- `--instance` is also honored by `workflow serve` / event-triggered runs where the
  run request is constructed by the CLI, and by `session rerun` (rerun re-resolves
  the recorded instance identity; if the instance changed or was removed, the
  recorded configuration snapshot is used with a warning).

### Session provenance

`WorkflowSession` (`Sources/RielaCore/RuntimeSession.swift`) gains optional fields
(all optional ⇒ old snapshots keep decoding; kind stored as `String` to avoid the
strict-enum decode failure mode that exists elsewhere in RielaCore):

```swift
public var instanceIdentity: String?          // "default", "prod", "prod+overrides"
public var instanceKind: String?              // WorkflowInstanceKind.rawValue
public var instanceBaseIdentity: String?      // temporary runs: the base instance
public var instanceConfiguration: JSONObject? // merged snapshot actually used
```

- `riela session status` / `session export` / GraphQL session queries surface these
  fields so any run can answer "which instance, with what configuration".
- The RielaApp execution timeline (design-rielaapp-instance-execution-timeline) can
  bind sessions to instances through `instanceIdentity` instead of inferring from
  the daemon runtime identity.

### GraphQL surface

`Sources/RielaGraphQL` additions:

- Queries: `workflowInstances(workflowId: String): [WorkflowInstance!]!`,
  `workflowInstance(identity: String!, workflowId: String): WorkflowInstance`
- Mutations: `createWorkflowInstance`, `updateWorkflowInstance`,
  `deleteWorkflowInstance` (input mirrors `WorkflowInstanceDefinition`)
- `ExecuteWorkflowInput` gains `instanceIdentity: String` and keeps
  `runtimeVariables` / `nodePatch` as temporary-instance overrides — the server
  resolves through the same `WorkflowInstanceResolver`, so remote and local runs
  share one precedence rule.
- `WorkflowRemoteRunRequest` (`Sources/RielaCLI/WorkflowCommands.swift`) gains
  `instanceIdentity: String?` and passes it through.

### RielaApp alignment

- `RielaAppDaemonWorkflowConfiguration` becomes a thin wrapper around (or typealias
  of) `WorkflowInstanceConfiguration`; `RielaAppDaemonWorkflowNodePatch` is replaced
  by `WorkflowInstanceNodePatch`. Field sets are already identical, so the JSON
  on-disk shape of `daemon-workflows.json` does not change; only the Swift types
  move. `RielaAppDaemonWorkflowState.version` stays at 1 unless a field diverges.
- Daemon start (`EntryPoint+DaemonInstances.swift`) builds its run request through
  `WorkflowInstanceResolver.resolve`, gaining `modelFreeze` enforcement (G5) and
  identical variable precedence. A frozen-model violation surfaces as an instance
  start failure in the UI rather than being silently applied.
- The App's "Add Instance" flow is unchanged UX-wise; it now produces the shared
  definition type. App instances remain profile-scoped and daemon-oriented
  (`active`/`available` lifecycle stays App-local and is NOT promoted into the
  canonical model — the canonical model describes *configuration*, not daemon
  lifecycle).

### Out of scope

- Cross-machine instance sync, instance-level secrets management.
- CLI management (create/update/remove) of RielaApp *profile*-scope instances
  (read/list only in this phase).
- Fanout/concurrency or timeout settings inside instances (stay per-run flags).

## Dependencies

- Builds on the resolved-bundle pipeline (`WorkflowBundleResolver`,
  `DefaultWorkflowNodePatchApplier`) and `DeterministicWorkflowRunRequest`.
- Touches `RuntimeSession` persistence — coordinate with
  `impl-plans/active/loop-engineering-application-gap-closure.md` (session schema
  additions) to avoid conflicting snapshot changes.
- Feeds `design-rielaapp-instance-execution-timeline` (session ↔ instance binding).

## Completion Criteria

- [x] Shared `WorkflowInstance*` types + `WorkflowInstanceResolver` live in RielaCore;
      CLI patch applier and RielaApp daemon start both route through the resolver.
- [x] `riela instance list/show/create/update/remove` work against project and user
      scopes; `list --scope all` includes read-only RielaApp profile instances.
- [x] `riela workflow run <wf>` (no flags) behaves byte-for-byte as today and records
      `instanceIdentity == "default"` in the session.
- [x] `riela workflow run <wf> --instance <name>` applies persisted configuration;
      adding `--variables`/`--node-patch` produces a temporary instance with correct
      precedence; `--save-instance` persists it.
- [x] `modelFreeze` violations fail from the shared resolver path used by CLI,
      GraphQL services, and App/serve startup.
- [x] Sessions expose instance provenance via CLI (`session status/export`) and
      GraphQL; old session snapshots still decode.
- [x] GraphQL instance queries/mutations and `ExecuteWorkflowInput.instanceIdentity`
      round-trip from `riela workflow run --endpoint` through the CLI HTTP transport.
- [x] RielaApp builds and daemon instances start/stop with the shared types; existing
      `daemon-workflows.json` files load without migration loss.
- [x] `swift build` and full `swift test` pass.

## Progress Log

### Session: 2026-07-07
**Tasks Completed**: Verified current CLI override path, RielaApp instance model,
and storage layout; authored this design and the implementation plan.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: RielaApp nodePatch field set already matches the CLI patch contract
exactly (executionBackend/model/effort), which makes type unification a rename
rather than a schema migration.

## Related Plans

- **Feeds**: `impl-plans/active/workflow-instance-unification.md` (implementation)
- **Feeds**: `impl-plans/active/rielaapp-instance-execution-timeline.md`
  (session ↔ instance binding for the timeline)
- **Coordinates with**: `impl-plans/active/loop-engineering-application-gap-closure.md`
  (RuntimeSession schema additions)
