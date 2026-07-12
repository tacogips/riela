# Workflow Instance Unification Implementation Plan

**Status**: Completed and archived 2026-07-12. All 49 boxes checked; latest session records "Tasks In Progress: None / Blockers: None" with live CLI run/export and remote CLI HTTP transport verification. The App profile-scope listing and daemon-start preflight follow-ups were completed in the final slice. The only residual item is packaged-skill (`riela-workflow-run`) guidance, which lives in the sibling `riela-packages` registry (out of this repo) — routed there, not tracked as open work here.
**Design Reference**: design-docs/specs/design-workflow-instance-unification.md
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Source**: design-docs/specs/design-workflow-instance-unification.md

### Summary

Make "instance" the canonical execution-configuration unit across CLI, GraphQL,
runtime, and RielaApp. Promote the RielaApp instance model (generalized) into
RielaCore, add a shared effective-instance resolver (single precedence +
`modelFreeze` enforcement path), add `riela instance` CLI verbs and
`workflow run --instance/--save-instance`, persist project/user-scope instances,
record instance provenance in sessions, and expose instances over GraphQL.

### Scope

**Included** (design sections):
- Canonical model + resolver in RielaCore (design: "Canonical model",
  "Effective-instance resolution")
- Project/user instance stores (design: "Instance storage and scopes")
- CLI command surface (design: "CLI command surface")
- Session provenance fields (design: "Session provenance")
- GraphQL queries/mutations + `ExecuteWorkflowInput.instanceIdentity`
  (design: "GraphQL surface")
- RielaApp type unification + shared resolver adoption (design: "RielaApp alignment")

**Excluded**:
- CLI write access to RielaApp profile-scope instances (read/list only)
- Instance-level secrets, cross-machine sync
- Concurrency/timeout settings inside instances

---

## Modules

### 1. Canonical Model and Resolver (RielaCore)

#### Sources/RielaCore/WorkflowInstanceModel.swift (new)

**Status**: IMPLEMENTED

```swift
public struct WorkflowInstanceNodePatch: Codable, Equatable, Sendable {
  public var executionBackend: NodeExecutionBackend?
  public var model: String?
  public var effort: NodeReasoningEffort?
}

public struct WorkflowInstanceConfiguration: Codable, Equatable, Sendable {
  public var workingDirectory: String?
  public var environmentFilePath: String?
  public var environmentVariables: [String: String]
  public var defaultVariables: JSONObject
  public var nodePatches: [String: WorkflowInstanceNodePatch]
}

public struct WorkflowInstanceDefinition: Codable, Equatable, Sendable {
  public var identity: String
  public var workflowId: String
  public var sourceIdentity: String?
  public var displayName: String?
  public var configuration: WorkflowInstanceConfiguration
}

public enum WorkflowInstanceKind: String, Codable, Sendable {
  case `default`, named, temporary
}
```

**Checklist**:
- [x] Types above with lenient decoding (all-optional container fields default to empty)
- [x] `WorkflowInstanceDefinition.defaultInstance(workflowId:)` factory
- [x] Unit tests: round-trip codec, empty-configuration defaults

#### Sources/RielaCore/WorkflowInstanceResolver.swift (new)

**Status**: IMPLEMENTED

```swift
public struct EffectiveWorkflowInstance: Sendable {
  public var identity: String
  public var kind: WorkflowInstanceKind
  public var baseIdentity: String?
  public var configuration: WorkflowInstanceConfiguration
}

public enum WorkflowInstanceResolver {
  public static func resolve(
    base: WorkflowInstanceDefinition?,
    runVariables: JSONObject,
    runNodePatch: [String: WorkflowInstanceNodePatch],
    nodePayloads: [String: AgentNodePayload]
  ) throws -> (instance: EffectiveWorkflowInstance,
               nodePayloads: [String: AgentNodePayload])
}
```

**Checklist**:
- [x] Move node-patch application logic from
      `Sources/RielaCLI/WorkflowResolution.swift` (`DefaultWorkflowNodePatchApplier`,
      lines ~331–386) into the resolver; keep `NodePatchError` cases and messages
      (`unknownNodeId`, `unsupportedField`, `invalidFieldValue`, `modelChangeFrozen`)
- [x] Merge order: node defaults → instance configuration → run overrides
- [x] `modelFreeze` enforced on both instance nodePatches and run nodePatch layers
- [x] Instance `defaultVariables` merged below run variables in
      `promptVariables` flow (extend `DeterministicWorkflowRunRequest.variables`
      construction; runner internals unchanged)
- [x] Unit tests: precedence matrix (default/named/temporary × variables/patches),
      frozen-model rejection from the instance layer, unknown node id

### 2. Instance Stores

#### Sources/RielaCore/WorkflowInstanceStore.swift (new)

**Status**: IMPLEMENTED

```swift
public protocol WorkflowInstanceStoring: Sendable {
  func list(workflowId: String?) throws -> [WorkflowInstanceDefinition]
  func find(identity: String, workflowId: String?) throws -> WorkflowInstanceDefinition?
  func save(_ instance: WorkflowInstanceDefinition) throws
  func remove(identity: String, workflowId: String?) throws
}
```

**Checklist**:
- [x] Protocol + `WorkflowInstanceStoreError` (duplicate identity, not found, io)
- [x] Versioned JSON envelope type `WorkflowInstanceStoreFile` (`version: 1`)

#### Sources/RielaCLI/FileWorkflowInstanceStore.swift (new)

**Status**: IMPLEMENTED

**Checklist**:
- [x] Project scope: `instances.json` under the existing project data-root
      resolution (same root as session store); user scope: `~/.riela/instances.json`
- [x] Atomic write (temp file + rename), quarantine-on-corrupt pattern matching
      `RielaAppDaemonWorkflowStore`
- [x] Scoped lookup helper: project → user precedence, explicit
      `--instance-scope` override, ambiguity error naming both scopes
- [x] Read-only adapter over RielaApp profile store for `list --scope all`
      (loads profile `daemon-workflows.json` files without writes)
- [x] Tests: scope precedence, corrupt-file quarantine, atomic save

### 3. CLI Commands

#### Sources/RielaCLI/InstanceCommands.swift (new)

**Status**: IMPLEMENTED

**Checklist**:
- [x] `riela instance list [--workflow <id>] [--scope project|user|all] [--output ...]`
- [x] `riela instance show <identity> [--workflow <id>]`
- [x] `riela instance create <identity> --workflow <id>` with
      `--variables/--node-patch/--working-dir/--env-file/--env/--display-name/--scope`
- [x] `riela instance update <identity>` (same setters, partial update)
- [x] `riela instance remove <identity> [--scope ...]`
- [x] Validation: workflow id resolvable via existing bundle resolver; node ids in
      `--node-patch` validated against the workflow's node payloads at create time
- [x] Behavior tests in `Tests/RielaCLITests/WorkflowInstanceCommandTests.swift`

#### Sources/RielaCLI/ParsedWorkflowOptions.swift, RielaCommand.swift, WorkflowRunCommand.swift (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] `WorkflowRunOptions` gains `instance: String?`, `instanceScope: String?`,
      `saveInstance: String?`
- [x] Run flow: resolve base instance from stores → build
      `[String: WorkflowInstanceNodePatch]` from `--node-patch` JSON → call
      `WorkflowInstanceResolver.resolve` → construct
      `DeterministicWorkflowRunRequest` (replaces direct
      `patchApplier.applyNodePatch` call at `WorkflowRunCommand.swift:43-48`)
- [x] Instance `workingDirectory` / env layering applied to run context
      (run-level flags still win)
- [x] `--save-instance` persists the materialized temporary instance (base +
      overrides) to the selected scope after successful validation, before the run
- [x] `session rerun`: re-resolve recorded `instanceIdentity`; fall back to recorded
      `instanceConfiguration` snapshot with a warning when missing/changed
- [x] No-flag runs produce identical behavior to current (regression-guard test)

### 4. Session Provenance (RielaCore + stores)

#### Sources/RielaCore/RuntimeSession.swift (modify)

**Status**: IMPLEMENTED

```swift
// WorkflowSession additions (all optional; kind as String for tolerant decode)
public var instanceIdentity: String?
public var instanceKind: String?
public var instanceBaseIdentity: String?
public var instanceConfiguration: JSONObject?
```

**Checklist**:
- [x] Fields threaded from `EffectiveWorkflowInstance` at session creation
- [x] Old snapshots (fields absent) decode unchanged — add fixture test with a
      pre-change `session_json` blob
- [x] `session status` / `session export` output includes instance fields
- [x] GraphQL session/run queries expose the fields

### 5. GraphQL Surface

#### Sources/RielaGraphQL (modify), Sources/RielaCLI/WorkflowCommands.swift (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] Schema: `WorkflowInstance` type; `workflowInstances` / `workflowInstance`
      queries; `createWorkflowInstance` / `updateWorkflowInstance` /
      `deleteWorkflowInstance` mutations
- [x] `ExecuteWorkflowInput.instanceIdentity: String` (optional); server resolves
      through `WorkflowInstanceResolver` with existing `runtimeVariables`/`nodePatch`
      as temporary overrides
- [x] `WorkflowRemoteRunRequest.instanceIdentity: String?` + transport pass-through;
      `riela workflow run --endpoint --instance <name>` works end to end
- [x] Schema SDL snapshot/tests updated for session provenance fields
      mutations

### 6. RielaApp Alignment

#### Sources/RielaAppSupport/RielaAppDaemonWorkflowPreference.swift (modify)

**Status**: IMPLEMENTED

**Checklist**:
- [x] `RielaAppDaemonWorkflowConfiguration` re-expressed over
      `WorkflowInstanceConfiguration`; `RielaAppDaemonWorkflowNodePatch` replaced by
      `WorkflowInstanceNodePatch` (typealias or wrapper; on-disk JSON unchanged)
- [x] Fixture test: existing v1 `daemon-workflows.json` sample loads losslessly

#### Sources/RielaApp/EntryPoint+DaemonInstances.swift (modify)

**Status**: PARTIAL

**Checklist**:
- [x] Daemon start validates node patches through `WorkflowInstanceResolver.resolve`
      inside the serve resolver before listener/event-source startup
- [x] `modelFreeze` violation surfaces as instance start failure (UI error state),
      with test coverage in `Tests/RielaAppSupportTests`
- [x] Verify (G5): confirm and remove any pre-existing App-side patch path that
      bypassed freeze enforcement

### 7. Docs, Examples, and Skills Follow-Up

**Status**: PARTIAL

**Checklist**:
- [x] Command-surface help updated for `riela instance` and new run flags
- [x] One example under `examples/` demonstrating two named instances of one
      workflow (e.g. cheap-model vs high-effort) + EXPECTED_RESULTS update
- [x] Note for packaged-skill updates (riela-workflow-run guidance) filed as
      follow-up here; skills live in the riela-packages registry outside this repo,
      so the package registry update is intentionally not part of this source change

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Canonical model | `Sources/RielaCore/WorkflowInstanceModel.swift` | IMPLEMENTED | `WorkflowInstanceResolverTests` |
| Resolver | `Sources/RielaCore/WorkflowInstanceResolver.swift` | IMPLEMENTED | precedence matrix, freeze |
| Store protocol | `Sources/RielaCore/WorkflowInstanceStore.swift` | IMPLEMENTED | build + CLI behavior |
| File store | `Sources/RielaCLI/FileWorkflowInstanceStore.swift` | IMPLEMENTED | CLI behavior; corrupt/quarantine tests; App profile list |
| Instance commands | `Sources/RielaCLI/InstanceCommands.swift` | IMPLEMENTED | `WorkflowInstanceCommandTests` |
| Run integration | `Sources/RielaCLI/WorkflowRunCommand.swift` et al. | IMPLEMENTED | no-flag, named instance, cwd, rerun snapshot fallback |
| Session provenance | `Sources/RielaCore/RuntimeSession.swift` | IMPLEMENTED | old-snapshot decode fixture |
| GraphQL | `Sources/RielaGraphQL`, `Sources/RielaCLI/WorkflowCommands.swift` | IMPLEMENTED | SDL/session/query/mutation service + remote pass-through |
| App alignment | `Sources/RielaAppSupport`, `Sources/RielaServer` | IMPLEMENTED | type unification + v1 fixture; daemon preflight |
| Docs/examples | `examples/`, command docs | IMPLEMENTED | CLI help + named-instance example covered; package-skill follow-up noted |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Resolver (module 1) | — | Implemented |
| Stores (module 2) | Model types (module 1) | Implemented for project/user plus read-only App profiles |
| CLI commands (module 3) | Modules 1–2 | Implemented for project/user |
| Session provenance (module 4) | Module 1; coordinate with loop-engineering-application-gap-closure session changes | Implemented |
| GraphQL (module 5) | Modules 1–2, 4 | Implemented contract/service; local server document execution follow-up may wire it into a GraphQL document executor |
| App alignment (module 6) | Module 1 (resolver) | Implemented; serve start preflights through shared resolver |
| Docs/examples (module 7) | Modules 3, 5 | Example updated; packaged-skill guidance follow-up noted |

Modules 3, 4, 6 can proceed concurrently once modules 1–2 land.

## Completion Criteria

- [x] All design-doc completion criteria satisfied
      (design-workflow-instance-unification#completion-criteria)
- [x] `swift build` and full `swift test` pass
- [x] No-flag `riela workflow run` regression guard proves unchanged behavior and
      records `instanceIdentity == "default"`
- [x] Live verification: create two instances of one example workflow, run each,
      confirm per-node model differences in `session export` adapterOutput and
      instance provenance fields
- [x] Remote verification: `riela workflow run --endpoint ... --instance <name>`
      against a local HTTP GraphQL fixture. Current `riela serve` exposes
      deterministic routes/note API rather than a live `executeWorkflow` endpoint,
      so this verifies the production CLI HTTP transport and request/summary
      round-trip without claiming a non-existent serve mode.

## Progress Log

### Session: 2026-07-07
**Tasks Completed**: Codebase verification (CLI override path, RielaApp instance
model, storage), design doc authored, this plan authored, README index updated.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: RielaApp `nodePatches` field set already equals the CLI patch contract,
so module 6 is a type unification, not a data migration. Session snapshot decoding
in RielaCore is strict on enums — instance kind is persisted as a raw string.

### Session: 2026-07-07 implementation slice
**Tasks Completed**: Added shared `WorkflowInstance*` model/resolver/store protocol;
converted CLI node-patch application to the shared resolver; added project/user
file stores and `riela instance` commands; integrated `workflow run --instance`,
`--instance-scope`, and `--save-instance`; recorded instance provenance in
`WorkflowSession`; exposed session provenance through CLI status/export DTOs and
GraphQL session DTO/SDL; passed remote `instanceIdentity` through the CLI GraphQL
transport; re-expressed RielaApp daemon configuration/node patch types over the
shared Core types; updated CLI help.
**Tasks In Progress**: App profile-scope read-only listing; App daemon-start
preflight/UI surfacing; packaged-skill guidance follow-up; full/live/remote
verification.
**Blockers**: None.
**Verification**: `swift build`; `swiftlint`; focused tests
`WorkflowInstanceResolverTests|RuntimeSessionTests|WorkflowInstanceCommandTests|GraphQLContractsTests`.

### Session: 2026-07-07 follow-up implementation slice
**Tasks Completed**: Added run-context cwd/env layering for instances; threaded
instance snapshot fallback into `session rerun`; added file-store precedence,
quarantine, and save tests; added GraphQL `WorkflowInstance` DTO/input/result
contracts and store-backed query/mutation service; added AppSupport v1
`daemon-workflows.json` fixture round-trip; documented two named instances for
`worker-only-single-step`.
**Tasks In Progress**: App profile-scope read-only listing; App daemon-start
preflight/UI surfacing; packaged-skill guidance follow-up; full/live/remote
verification.
**Blockers**: None.
**Verification**: `swift build`; `swift test` (1380 tests);
`swift build --target RielaGraphQL`;
`swift test --filter GraphQLContractsTests`;
`swift test --filter WorkflowInstanceCommandTests`;
`swift test --filter DaemonWorkflowNodePatchTests`.

### Session: 2026-07-07 completion slice
**Tasks Completed**: Added read-only CLI listing of RielaApp profile instances
from `~/.riela/rielaapp/profiles/*/daemon-workflows.json`; added serve-time node
patch preflight through `WorkflowInstanceResolver` so RielaApp daemon starts fail
before listener/event-source startup when `modelFreeze` would be violated; added
coverage for both paths; filed the packaged-skill update as an out-of-repo
follow-up note.
**Tasks In Progress**: None.
**Blockers**: None.
**Verification**: `swift test --filter 'WorkflowInstanceCommandTests|DaemonWorkflowNodePatchTests'`;
live CLI run/export in `tmp/workflow-instance-live-verification`; remote CLI
HTTP transport run in `tmp/workflow-instance-remote-verification`.

## Related Plans

- **Depends On**: design-docs/specs/design-workflow-instance-unification.md
- **Coordinates with**: `impl-plans/active/loop-engineering-application-gap-closure.md`
  (RuntimeSession schema additions)
- **Feeds**: `impl-plans/active/rielaapp-instance-execution-timeline.md`
  (session ↔ instance binding)
