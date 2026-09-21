# Execution Environment Consolidation Implementation Plan

**Status**: Planning
**Workflow Mode**: feature
**Feature Fanout**: true — eight internal milestones, not releasable states; every removed field ships in the milestone that ships its replacement (design §15); E0 and E1 first, then E3 before E2's bootstrap goals, E4 and E5 in parallel with E2/E3, then E6, E7
**Design Reference**: `design-docs/specs/design-execution-environment-consolidation.md` (all sections); intake `design-docs/specs/design-ax-substrate-inspired-capabilities.md` §5 A, C, D, F, G
**Created**: 2026-09-21
**Last Updated**: 2026-09-21 (revised after the Codex `gpt-6-astra` review; design §21 lists the accepted findings; no code written)

## Accepted Design

- Source of truth: `design-docs/specs/design-execution-environment-consolidation.md`.
  Decisions 1–12 are fixed: definitions in the runtime records database with
  versions, lineage, proposals, and a validate → normalize → digest → store
  write path; six concepts resolved into one `ResolvedExecutionEnvironment`;
  one workspace instance root per execution with relative paths; template
  → instance with worktrees and copy-on-write clones; binding-level
  isolation with change snapshots for every instance; a real policy engine
  with four renderers and `enforced`/`advisory` labels; model profiles with
  credential sources; placement by capability; the runner contract; typed
  conditions; no compatibility.
- Layering: models, validators, normalizer, store in `RielaCore`
  (definition store) and `RielaCore` (environment types); materializer,
  instance store, clone, renderers that need git or vendor CLIs in
  `RielaCLI`/`RielaAdapters`; Work Runtime binding in `RielaWork`.
  `RielaCore` never imports `RielaWork`; `RielaWork` never imports
  `RielaCLI` (instance provider injected through a `RielaCore` protocol).
- Ordering relative to the Work Runtime: E0's store, writer, search, and
  import/export are independent of P1; E0's planner integration and
  `task promote-plan` depend on P1; E2's task binding lands with P4, which
  co-specifies branch creation and publication; E3 ceilings serve P7.
- Agent CLI processes are spawned by the gateway package's
  `POSIXGatewayProcessRunner` (`AgentGatewayNodeAdapter.swift:41` →
  `ProductionGatewayExecutor`), not by `LocalProcess.swift`; E3 injects a
  policy-aware `GatewayProcessRunning` there and tests through the
  production adapter. `WorkflowStepExecution.environment` and session `conditions` are
  additive fields; the schema generation is bumped once in E0 for the
  definition tables.

## Task Checklist

Check a box only after its task's completion evidence is recorded in the
progress log with the exact command and result.

- [ ] E0 Definition store (tables, assets, writer, pins and cross-store closure snapshot, integer head revision, explicit activation, retention graph, submissions, import/export/history/activate/fork/consolidate, search and similarity, ephemeral run, package install as import, quarantine on generation mismatch, file registry deleted; user store and project store stay two databases — user decision 2026-09-21)
- [ ] E1 Environment model and validation (types, node/workflow fields, resolved environment with `DefinitionPin` list, ad-hoc local workspace, definition-assets mount, removal of the location fields only, workflow-level `policy` defaults added to every example, skills rewritten)
- [ ] E2 Workspace runtime (materializer, templates, instances, clone, change snapshots, fanout and task bindings)
- [ ] E3 Policy engine (policy-aware gateway process runner + Seatbelt for command nodes, `auto` default — user decision 2026-09-21, intersection invariants and reserved-key rejection, `policy.environment`, container mounts and resources, egress enforcement point, capability requirements; removes `agentSandbox`, `AgentToolPolicy`, `<vendor>AdditionalArgs`, `RIELA_SANDBOX_SEATBELT` here)
- [ ] E4 Model profiles (deterministic literal/profile rule, insert-if-absent `default/<backend>`, `trusted` flag via `riela model trust`, credential sources, adapter wiring, redactor; removes node `baseURL`/`apiKeyEnvironment`/`provider`/`providerProxy` here)
- [ ] E5 Placement and workers (bindings, ceilings with `environment.forbid` for the transport token, capability table, resolver, artifact return, controller-side finalization of remote change sets; removes `placement.workspace/exports`, `allowedAddons`, `allowedEnvironment`, `controllerPath` here)
- [ ] E6 Runner contract and conditions (metadata file, system mounts incl. `RIELA_DEFINITION_ROOT`, `riela-runner`, `session exec` with verified host-principal authorization and denial tests, hook events, conditions)
- [ ] E7 Surfaces and packages (remaining CLI/GraphQL rows, doctor, Studio rows, skill docs, `riela-packages` follow-up)

## Applicable Prior Knowledge

- Run every Swift command through `arch -arm64 /bin/zsh -lc '...'`; keep
  complete logs under `tmp/execution-environment-consolidation/`.
- `SurfaceCatalog` rows ripple into `Tests/RielaCoreTests/SurfaceCatalogTests.swift`
  and the `SurfaceParity*Tests` in `RielaCLITests` and `RielaGraphQLTests`;
  register every new command family in `RielaClientCommandRouter.swift` and
  `CLISurfaceEnumeration.swift` in the same task as its rows; regenerate the
  SDL with `scripts/surface-parity/generate-sdl.sh`.
- Session store root: `CLIWorkflowSessionStore.resolveRootDirectory`
  (`--session-store`, `RIELA_SESSION_STORE`, `<cwd>/.riela/sessions`);
  the runtime records database is its `runtime-records/` subdirectory; a
  schema generation bump discards existing stores (no migration).
- Examples must stay in `rielaExampleWorkflowNames()` with the mock-scenario
  counts (`Tests/RielaCLITests/RielaExampleCatalog.swift`); after E0 the
  parity test imports each example into a temporary store.
- Vendor CLI flags verified 2026-09-21: Claude Code `--mcp-config`,
  `--add-dir`, `--permission-mode`; Codex `-c key=value`, `--sandbox`, `-C`;
  Cursor `mcp`, `--approve-mcps`, `--sandbox`.
- Seatbelt derivation (`localSandboxPolicy`) exists but has no caller; E3
  wires it rather than rewriting it.
- Re-read syntax-critical files before authoring against them; line numbers
  in this plan move.

## Scope

### Included

Everything in design §4–§13 and the removal table §11. The external
`riela-packages` registry bundles are a follow-up package (E7) that must
land before the next release.

### Excluded

`ChangeRuntime` commit/diff/finalize (Work Runtime P4); the agent-gateway
package (`mcpServers` is populated but not relied upon); web/desktop UI
beyond declared `blocked` rows; riela memory and kaiba; registries with
provider queries; process snapshots.

## Task Breakdown

| Task | Deliverables | Primary write scope | Dependencies | Parallelizable |
| --- | --- | --- | --- | --- |
| E0 Definition store | `DefinitionVersion`, `DefinitionHead`, `DefinitionOrigin`, blob refs; `DefinitionStore` (tables, CRUD, history, activate, fork, consolidate, ephemeral GC); `DefinitionWriter` (lenient parse → strict validate → normalize → digest → store); bundle import/export in today's layout; `riela workflow run <dir|->` ephemeral import; package install as import with `mutable: false`; `WorkflowRegistryBundleLoader` reads from the store; file registry, activation overlay, history tree, `--workflow-definition-dir`, `--workflow-json*`, `workflow checkout` mechanism deleted; GraphQL registry provider on rows; tests import examples | `Sources/RielaCore/Definition*.swift` (new), `Sources/RielaCore/JSONCanonical.swift` (new), `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` (generation + tables), `Sources/RielaWorkflowRegistry/**` (most files rewritten or deleted), `Sources/RielaCLI/Workflow*Commands*.swift`, `Sources/RielaCLI/WorkflowPackageCommandRunner+Install.swift`, `Sources/RielaGraphQL/WorkflowRegistryGraphQL*.swift`, `Sources/RielaCore/SurfaceCatalog+Rows*.swift`, `Tests/RielaCoreTests/Definition*Tests.swift`, `Tests/RielaCLITests/Workflow*Tests.swift`, `Tests/RielaCLITests/RielaExampleParityTests.swift`, `Tests/RielaGraphQLTests/**` | none | No; first compatibility break |
| E1 Environment model and validation | `WorkspaceDefinition`, `WorkspaceBinding`, `ExecutionPolicy`, `ModelProfile`, `PlacementRequest`, `ResolvedExecutionEnvironment`, `ExecutionCondition`; node fields `workspace`, `cwd`, `policy`, `placement`; workflow defaults; fanout binding; run-configuration fields; `validateExecutionEnvironment`; every removal in design §11 with `"<x> was removed; use <y>"` diagnostics; ad-hoc local workspace resolution (`WorkspaceSource.path`) wired so every execution has an instance root and relative `cwd`; add-ons, git, mock scenarios, artifacts resolve against it; examples and packaged skills rewritten | `Sources/RielaCore/ExecutionEnvironment*.swift` (new), `Sources/RielaCore/WorkflowModel.swift`, `WorkflowNodeValidation.swift`, `WorkflowRawValidation.swift`, `WorkflowValidation.swift`, `AdapterContracts.swift`, `RuntimeSession.swift`, `WorkflowInstanceModel.swift`, `WorkflowInstanceResolver.swift`, `Sources/RielaCLI/ParsedWorkflowOptions.swift`, `RielaClientFamilyArguments.swift`, `RielaCommand.swift`, `WorkflowRunCommand*.swift`, `SessionCommands+KaibaPreflight.swift`, `ProductionNodeAdapter*.swift`, `ContainerWorkflowAddonResolver.swift` (scope anchoring), `Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift`, `AgentGatewayNodeAdapter.swift`, `AdapterUtilities.swift`, `Sources/RielaWork/WorkContext.swift`, `WorkModels.swift`, `examples/**`, packaged skills, tests listed in the inventory §15 | E0 | No; second compatibility break |
| E2 Workspace runtime | `WorkspaceStoreLayout`, `WorkspaceMaterializer` (steps, lock, marker, failure record, relocatability scan), `WorkspaceInstanceStore` (worktree + clone, verify-on-first-use, remove, list, gc), `FileClone`, `WorkspaceChangeSnapshot` (renamed from `WorkflowFanoutChangeEvidence`, run for every instance), fanout branch instances, `RepositoryContextAdapter` prepare/discard with `taskGeneration` owner, `riela gc` awareness, `riela workspace prepare|gc|validate` | `Sources/RielaCLI/Workspace*.swift` (new), `Sources/RielaCLI/FileClone.swift`, `Sources/RielaCore/WorkspaceChangeSnapshot.swift` (renamed), `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`, `Sources/RielaCore/RielaDataGarbageCollector.swift`, `Sources/RielaWork/RepositoryContextAdapter.swift` (new), `Sources/RielaCore/WorkspaceInstanceProviding.swift` (protocol), tests | E1 | Yes with E3, E4 |
| E3 Policy engine | `PolicyResolver` (intersection of ceilings), renderers: local (wires `localSandboxPolicy` into `LocalProcessConfiguration.sandboxPolicy`, SBPL localhost exemption, `auto` default), codex (advisory flags), container (mounts from bindings, `--read-only`, `--tmpfs`, `--cpus/--memory/--pids-limit`, `--network none` or internal network + proxy), worker (forwarded); `EgressEnforcementPoint` (loopback CONNECT proxy, per-attempt bearer, allowlist, `egress` evidence); capability requirements from add-on manifests; `policy render` | `Sources/RielaCore/ExecutionPolicy*.swift`, `Sources/RielaAdapters/SeatbeltSandbox.swift`, `LocalProcess.swift`, `AgentGatewayNodeAdapter.swift`, `WorkflowStdioNodeExecutor.swift`, `Sources/RielaAdapters/EgressEnforcementPoint.swift` (new), `Sources/RielaCLI/ContainerRuntimeDriver.swift`, `ContainerWorkflowAddonResolver.swift`, `Sources/RielaCLI/PolicyCommands.swift`, tests | E1 | Yes with E2, E4 |
| E4 Model profiles | `ModelProfileResolver` (store scopes, `default/<backend>` synthesis labeled `implicit`), credential sources (`env`, `file`, `command` user-scope only), adapter wiring replacing `apiKeyEnvironment`/`baseURL`/`provider`/`providerProxy` consumers, redactor `credential`, `riela model *`, doctor rows | `Sources/RielaCore/ModelProfile*.swift`, `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`, `AgentEnvironment.swift`, `Sources/RielaObservability/RielaObservability.swift` (redactor pattern), `Sources/RielaCLI/ModelCommands.swift`, `DoctorCommand.swift`, tests | E1 | Yes with E2, E3 |
| E5 Placement and workers | worker `workspaces.<k>.definition|path`, worker `policy` ceiling and `models`, capability table (backends probe + declared, enforcement levels, template digests, profiles) in `DistributedWorkerRegistration.capabilities` and `work_hosts`, resolver (explicit host never falls back), job payload = resolved environment minus secrets/paths, `artifacts` return as `artifact` evidence, `controllerPath`/`allowedAddons`/`allowedEnvironment`/git denial deleted, `hostCapabilities` GraphQL | `Sources/RielaCLI/DistributedWorkerCommand.swift`, `Sources/RielaCore/DistributedWorkerModels.swift`, `DistributedNodeExecution.swift`, `DistributedPlacementValidation.swift`, `DistributedWorkerNodeExecutor.swift`, `DistributedJobController.swift`, `Sources/RielaServer/DistributedWorkerProtocol.swift`, `docs/distributed-workers.md`, tests | E2, E3, E4 | Yes with E6 |
| E6 Runner contract and conditions | `node-metadata.json` writer + `RIELA_NODE_METADATA_PATH`, system mounts (`RIELA_WORKSPACE_ROOT`, `RIELA_ARTIFACT_ROOT`, `RIELA_MEMORY_ROOT` declared, special case removed), container mount of the file, `riela-node-runner` static entrypoint (linux amd64/arm64 via linux-release CI) with readiness, process group, `SIGTERM` grace, exit code, `debug` keep-alive, `riela session exec` + `execInSession`, `ExecutionCondition` on sessions and attempts read by the inactivity guard | `Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift`, `Sources/RielaAdapters/NodeMetadataWriter.swift` (new), `Sources/RielaNodeRunner/**` (new executable target), `.github/workflows/linux-release.yml`, `Sources/RielaCLI/SessionCommands.swift`, `Sources/RielaGraphQL/GraphQLSessionControlContracts.swift`, `Sources/RielaCore/SessionObservability.swift`, tests | E2, E3 | Yes with E5 |
| E7 Surfaces and packages | remaining catalog rows and CLI/GraphQL (`apply`, `get`, `describe`, definition history/diff/fork on GraphQL, `workspaces|policies|models` views), doctor sections, Studio rows declared `blocked`, skill docs (`riela-workflow`, `riela-workflow-run`, `riela-node-addons`, `riela-package`; delete `riela-temporary-workflow` and `riela-workflow-checkout`), `impl-plans/README.md`, design status line, `riela-packages` follow-up package brief | `Sources/RielaCLI/*Commands.swift`, `Sources/RielaGraphQL/*GraphQL.swift`, `Sources/RielaCore/SurfaceCatalog+Rows*.swift`, packaged skills, `README.md`, docs | E0–E6 | No; final gate |

## Task Details

### E0 Definition Store

**Deliverables**:

- Types from design §4.1 in `Sources/RielaCore/DefinitionModels.swift`;
  strict `Codable` with `rejectUnsupportedKeys`; identifiers `defv-<uuid>`;
  `DefinitionScope = global | project | workspace(name)` (design §4.2) with
  the physical placement rule (global → user store; project and workspace
  rows → the owning project store, or the user store for a global
  workspace) and the resolution order embedded-in-version →
  workspace(bound) → project → global; `--scope global|project|workspace:<name>|auto`
  on every definition command (`user` is no longer accepted).
- `DefinitionStore` over the runtime records database: tables
  `definition_heads(kind, name, scope, active_version_id, mutable, updated_at, PRIMARY KEY(scope, kind, name))`,
  `definition_versions(version_id PK, kind, name, scope, digest, record JSONB, parent_version_id, origin_kind, state, created_at)`,
  `definition_blobs(digest PK, bytes BLOB, size)`; indexes on
  `(kind, name, scope)`, `digest`, `parent_version_id`; schema generation
  bumped once; `discardIncompatibleStoreIfNeeded` handles old stores.
- `DefinitionWriter` (design §4.4): lenient JSON parser (comments, trailing
  commas, BOM), strict validation through the existing validators plus
  `validateExecutionEnvironment` (E1 supplies it; E0 wires a hook),
  meaning-preserving normalizer (`JSONCanonical.swift`: sorted keys,
  compact, shortest numbers, default-valued fields dropped per a table in
  the same file, **string values byte-preserved**; text assets CRLF→LF,
  BOM, single trailing newline, trailing-whitespace strip only for
  non-executable, non-fenced text; scripts and binaries byte-preserved
  with `AssetRef { digest, size, executable, kind }`), versioned
  length-prefixed digest framing, dedupe (`unchanged` against
  `latestVersion`, `duplicateOf` otherwise, never activation), explicit
  activation with `expectedRevision` (integer, `WorkStore` pattern),
  `DefinitionSubmission` rows for rejected writes, one transaction.
- Pins: `WorkflowSession.pins: [DefinitionPin]`; before session creation
  the resolver snapshots the dependency closure of user-store and
  bundle-embedded definitions into the session-owning store (no local
  heads); retention GC honors head pointers, pins, task plans, proposals,
  `parent` links, dependency pins.
- Run configurations (design §22): `RunConfiguration`, `NodeOverlay`,
  `OverlaySelector`, `OverlayFields` as a stored definition kind with the
  same writer; `FileWorkflowInstanceStore`, `instances.json`,
  `WorkflowInstanceDefinition/Configuration/NodePatch` deleted; package
  install may import packaged run configurations.
- Quarantine: on schema-generation mismatch the store is renamed
  `runtime-records.incompatible-<generation>/`; `riela store reset
  --confirm` and `riela store export-definitions <dir>` added; the
  discard helper is no longer used for stores that hold definitions.
- Bundle import in today's directory layout (`workflow.json`, `nodes/`,
  `prompts/`, scripts, embedded `workspaces/`, `policies/`, `models/`);
  export in three formats (directory bundle, single-file JSON with inlined
  blobs, `.rielapkg` via the existing packer) with `--version`,
  `--with-definitions`, `--history`, secrets never resolved, canonical
  pretty-printed text, and a round-trip test (`export` → `import` →
  `unchanged`) over every example; `riela session export` embeds the
  workflow version; GraphQL `exportDefinition`;
  `riela workflow validate <dir> [--print-normalized]`;
  `riela workflow fmt <dir>`.
- `riela workflow import|export|list|show|history|diff|activate|rollback|fork|delete|consolidate`;
  `riela workflow run <name|dir|-> [--version <id>]` (directory or stdin →
  ephemeral version pinned by the session; GC with the session).
- Package install imports each packaged workflow as an immutable head
  (`origin: package(id, version)`, `mutable: false`); `fork` creates a
  mutable head with `parent`.
- Proposals: `workflow self-improve` and the Work Runtime's
  `proposeWorkflowChange` write `state: proposed` versions; `accept` moves
  the head; `reject` keeps the row.
- Search and similarity (design §4.5): FTS5 `definition_search` and the
  `structure_digest` + MinHash `text_sketch` columns written in the same
  transaction as the version; `riela workflow search` with scope, backend,
  add-on, tag, workspace, `--similar-to`, `--unused-since`, `--sort`;
  `searchDefinitions` GraphQL; `workflow usage` and `workflow list` as
  views over the index (the usage-discovery contract kept as the `usage`
  block); `DefinitionWriter` returns `similar` hits and honors `onSimilar:
  warn | requireFork | reject` (default `warn` for CLI humans,
  `requireFork` for agent and planner callers, `--force` override);
  `workflow consolidate --similar`; `workflow gc --unused-since`;
  `riela task promote-plan` promoting a generated ephemeral version to a
  workspace-local head through the gate; `riela workflow find --for
  <instruction>` / `recommendDefinitions` ranking by FTS + structure +
  usage counts and success rate, returning `usage` blocks; the planner
  variable and `reuse | fork | new` decision recording; `find` documented
  as the first step in the `riela` and `riela-workflow` skills with a
  parity check. The temporary-workflow registry,
  `--workflow-json`, `--workflow-json-file`, and the
  `riela-temporary-workflow` skill are deleted; one-shot runs are
  ephemeral versions, environment helpers are `scope: workspace(name)`.
- Deleted: `.riela/workflows`, `~/.riela/workflows`,
  `~/.riela/temporary-workflows`, `.registry-state`, activation overlay,
  `.riela/workflow-history`, `.riela/workflow-checkouts*`;
  `WorkflowMutableRegistry*`, `WorkflowHistory*`, `WorkflowActivationStore`,
  `WorkflowDetachedOwnership*`, `WorkflowRegistryCatalog` directory scan;
  `--workflow-definition-dir`, `--workflow-json`, `--workflow-json-file`,
  `workflow checkout` (now `import <github-dir-url>`); GraphQL
  `registerMutableWorkflow|updateMutableWorkflow|deleteMutableWorkflow|
  activateWorkflow|deactivateWorkflow`, replaced by `importDefinition`,
  `activateDefinition`, `forkDefinition`, `deleteDefinition`,
  `consolidateWorkflows`, `definitions`, `definition`, `definitionHistory`.
- `RielaExampleParityTests` imports every example into a temporary store
  and asserts `unchanged` on a second import (normalization idempotence).

**Completion evidence**: store tests (schema, CRUD, history, activate,
rollback-by-digest, fork, consolidate, ephemeral GC, blob dedupe); writer
tests (lenient parse fixtures, rejection with diagnostics, canonical bytes
fixture, idempotence, similarity hits for a renamed copy of an example and
`requireFork` refusal); search tests (FTS over prompt text, structural
match between two examples that share a graph, `--unused-since` over a
fixture session set); CLI parsing/rendering tests; GraphQL round trip;
example parity green; `grep -rn "temporary-workflows\|workflow-history\|\.registry-state" Sources` → 0.

### E1 Environment Model And Validation

**Deliverables**:

- Types from design §5 in `Sources/RielaCore/ExecutionEnvironment*.swift`.
- `AgentNodePayload`: add `workspace` (one binding), `cwd`, `policy`;
  remove `workingDirectory` and the legacy decode keys with replacement
  messages; payload documents reject unknown keys. Placement stays on
  `WorkflowStepRef`. (`agentSandbox`, `agentToolPolicy`, provider fields,
  and the `<vendor>AdditionalArgs` variables are removed in E3/E4.)
- Overlay resolver (design §22): `RunConfigurationResolver` computes the
  effective node payloads from workflow version ⊕ run configuration ⊕
  command-line overlay with the fixed precedence, `modelFreeze` skips
  recorded as diagnostics (`--strict-overlay` errors), selector
  validation, host/profile/policy checks before session creation,
  `EffectiveNodeModel` on `WorkflowStepExecution.environment.model`, the
  session pin of an ephemeral `origin: cli` run-configuration version,
  the effective payload digest feeding `_rielaHistoryContract`; run flags
  `--config`, `--model`, `--model-for`, `--backend-for`, `--effort-for`,
  `--policy-for`, `--overlay-json`, `--dry-run`, `--strict-overlay`;
  `--node-patch` deleted; node payload `tags: [String]` added.
- Definition-assets mount: `RIELA_DEFINITION_ROOT` materialized read-only
  from the pinned version and `nodeRef` closure with executable bits;
  `definition://` typed references for scripts; containment checks.
- `WorkflowCommandExecution` / `WorkflowContainerExecution` lose
  `workingDirectory` and legacy keys; container gains `debug`.
- `workflow.json` top-level `workspace`, `policy`, `model`; fanout
  `workspace` replaces `writeOwnership` and `changeTracking`;
  `defaults.fanoutConcurrency` removed.
- `WorkflowInstanceConfiguration`: `workingDirectory` removed; `workspace`,
  `policy`, `model` added; `.env` and variables unchanged.
- Work Runtime: `ContextBinding.workspace(WorkspaceBinding)` replaces
  `.repository`; `Attempt.environment` replaces `isolation`;
  `IntentConstraints.policyCeiling`, `.workspace`.
- `validateExecutionEnvironment(workflow:payloads:resolver:)` and the
  policy requirement for agent nodes (error when no policy resolves).
- Run options: `--workspace`, `--workspace-path`, `--keep-workspace`,
  `--policy`, `--model`, `--placement` added; `--working-dir`,
  `--working-directory`, `--artifact-root` removed; `RIELA_ARTIFACT_DIR`
  removed.
- Ad-hoc local workspace: `WorkspaceSource.path` resolution creates an
  `adHoc` instance ref; the node adapter, stdio executor, add-on resolver
  (`repo` scope), mock-scenario resolution, fanout root, git repo-root
  rule, and artifact root all read `ResolvedExecutionEnvironment`; the
  `LocalProcess` child cwd is the resolved `cwd`; `WorkflowStepExecution.environment`
  persisted.
- Examples: the 7 `workingDirectory` files → `cwd` (the two container
  workers → `workspace.mount: "/workspace"`); every example `workflow.json`
  gains a top-level `policy` default (153 CLI-backend node payloads exist,
  149 without `agentSandbox`, so the policy requirement is satisfied at the
  workflow level, with per-node overrides only where the 4 `agentSandbox`
  declarations differ); 4 `<vendor>AdditionalArgs` →
  `policy.agent.extraArguments`; 1 `providerProxy` → a `models/` document
  in the bundle; 2 step `placement` files keep `placement.host`; 1
  `writeOwnership` → fanout `workspace`; `EXPECTED_RESULTS.md` updated
  where evidence changes. The field *removals* for sandbox, tool policy,
  provider, and placement happen in E3/E4/E5 (design §15); E1 only adds
  the replacements and removes the location fields.
- Packaged skills rewritten for the new fields.

**Completion evidence**: model round-trip and rejection tests for every
removed and added field; validation tests; runner tests proving the child
process cwd equals the resolved `cwd` for agent, command, and container
nodes; example parity green; `grep -rn "workingDirectory\|agentSandbox\|AdditionalArgs" examples Sources` limited to the allowed remnants listed in the progress log.

### E2 Workspace Runtime

**Deliverables**: as design §6 — layout, materializer (eight steps, lock,
marker, failure record, relocatability scan, bootstrap goal as an internal
agent execution under `policy.filesystem: workspace`), instance store
(worktree add/remove, copy-on-write clone with `copyfile`/`FICLONE`/copy
fallback and method recording, verify-on-first-use, owners `session |
taskGeneration | fanoutBranch`, gc), `WorkspaceChangeSnapshot` for every
instance (`changedFile` evidence; fanout conflict check reads it),
`RepositoryContextAdapter.prepare/discard` through
`WorkspaceInstanceProviding`, `riela workspace prepare|gc|validate`,
`riela gc` learns `workspaces`.

**Completion evidence**: materializer tests over a `git init` fixture
(layout, marker, lock contention, failing verify, relocatability
downgrade); instance tests (round trip, clone method, first-use verify
fallback, gc ordering); a fanout example with `isolation: isolated`
asserting one instance per branch and change evidence at the join; a
Work Runtime adapter test with `taskGeneration` reuse across two attempts.

### E3 Policy Engine

**Deliverables**: `PolicyResolver` (per-field intersection per design §7,
`policy.environment`, reserved renderer-owned argv/env keys rejected at
validation, capability requirements from add-on manifests); agent CLI
renderer as a policy-aware `GatewayProcessRunning` injected into
`ProductionGatewayExecutor` (Seatbelt wrap of the vendor executable,
proxy env, labels per constraint); command-node renderer wiring
`localSandboxPolicy` into `LocalProcessConfiguration.sandboxPolicy` at
`LocalProcess.swift:669` with the SBPL localhost exemption for the
enforcement point and `auto` default; in-process add-ons and SDK backends
labeled `advisory` for filesystem; codex renderer (`--sandbox`, `-c sandbox_permissions`,
proxy env, `advisory`); container renderer (bind mounts from bindings and
`extraWrite`, `--read-only`, `--tmpfs`, `--cpus`, `--memory`,
`--pids-limit`, `--network none` / internal network + proxy); worker
forwarding; `EgressEnforcementPoint` (loopback CONNECT proxy, random port,
per-attempt bearer, allowlist by CONNECT authority, `egress` evidence,
`onDenied`); `finalization` capability gating `riela/git-commit|push`;
`riela policy list|show|validate|render`; enforcement labels on the
resolved environment.

**Completion evidence**: renderer fixture tests per class (argv, SBPL text,
container args); a live Seatbelt test on macOS **through the production
gateway adapter with a stub vendor executable** asserting a write outside
the instance root fails under `workspace` and succeeds under
`unrestricted`, plus the same for a command node; rejection tests for
reserved keys in `extraArguments`, `agentEnvironment`, and MCP `env`; proxy tests (allowed host dials, denied host 403 with
evidence, missing bearer 407); add-on requirement rejection at validation.

### E4 Model Profiles

**Deliverables**: `ModelProfileResolver` over the definition store with the
deterministic rule (exact head name → profile, else literal + `default/
<backend>`; profile backend must equal the node backend; `effort`
overrides parameters; workers use the pinned profile version); implicit
creation of a missing `default/<backend>` as a real `global` head with
insert-if-absent semantics (`origin: implicit`, literal model, conventional
credential env var or `nil`, `implicitProfileCreated` recorded on the
session — design §8, user decision 2026-09-21); credential sources with
`trusted` set only by `riela model trust` and cleared on import/fork/
copy/install; adapter wiring (the per-call environment
carries the resolved secret exactly where `apiKeyEnvironment` used to),
`RielaTelemetryRedactor` gains `credential`, `riela model list|show|
validate`, doctor rows, `placement` evidence records the profile name.

**Completion evidence**: resolver tests (scopes; a literal model with no
profile creates exactly one `default/<backend>` row and a second run
reuses it; a narrower explicit profile shadows it; command refused from
project scope); adapter tests asserting the secret
never appears in argv, evidence, or telemetry fixtures.

### E5 Placement And Workers

**Deliverables**: as design §9 — worker bindings (`definition | path`),
worker `policy` ceiling and `models`, capability table registration and
`work_hosts`, resolver with `waiting(.capacity)` and
`backend-unavailable` reasons (Work Runtime §5a), job payload without
secrets or host paths, `artifacts` return as bounded `artifact` evidence,
`hostCapabilities(host:)` GraphQL, `docs/distributed-workers.md`
rewritten; workers keep `capabilities.finalization: false` and the
finalization-token exclusion, and the controller finalizes a returned
change set against its own instance of the same template through the
existing journaled store (design §9).

**Completion evidence**: worker configuration tests; controller/worker
round trip over the HTTP protocol with a `definition` workspace prepared
once; a placement test choosing the warm host; a mismatch test.

### E6 Runner Contract And Conditions

**Deliverables**: metadata writer and `RIELA_NODE_METADATA_PATH`; system
mounts declared and the memory-root special case removed;
`riela-node-runner` executable target and the linux-release CI job
producing static binaries; container `runnerKind: riela-runner` mounting
and using it (readiness marker, process group, 10 s grace, exit code in
the result envelope, `debug` keep-alive with TTL); `riela session exec`
and `execInSession` (verified host principal owning the session's store,
session-ownership check, denial tests, `command` evidence with
`producedBy: human(principal)` and the policy digest; the catalog row stays
`blocked` until these exist); `hook_events` persistence joined to
executions; `ExecutionCondition` on sessions and attempts
(`DefinitionResolved`, `WorkspaceReady`, `PolicyReady`, `BackendReady`,
`Ready`) and the inactivity guard reading `Ready`.

**Completion evidence**: stdio executor tests asserting the metadata file
content and mounts; a container test with a fixture image running the
runner (skipped when no runtime); exec tests (policy applied, evidence
recorded, auth required); conditions tests.

### E7 Surfaces And Packages

**Deliverables**: every remaining catalog row, `riela apply|get|describe`
for the three environment kinds, GraphQL views and history/diff/fork,
run configuration surfaces (design §22.4: `riela config
list|show|create|update|diff|delete|import|export|create --from-session|
compare`, `riela workflow models`, GraphQL `runConfigurations`,
`runConfiguration`, `effectiveNodeModels`, `upsertRunConfiguration`,
`compareRunConfigurations`; the `riela instance` family deleted and the
app daemon preference referencing a run configuration name; Studio
matrix editor `blocked`),
doctor sections for definitions, workspaces, policies, models, hosts,
Studio rows declared `blocked`, skill documents rewritten (two deleted),
`README.md` and `impl-plans/README.md`, design status line, and a
`riela-packages` follow-up brief listing every packaged workflow field
that changes.

**Completion evidence**: catalog and parity gates green; skill parity
tests green; full `swift test` from the repository root with zero failures
beyond the accepted environmental set and the known interleaved-submit
timing flake.

## Alignment Map (design §20)

Existing features that change, by phase; each is a deliverable of the phase
named and a row in that phase's completion evidence.

| Phase | Existing feature changes |
| --- | --- |
| E0 | specialist dispatch pins a version id instead of copying a snapshot directory; package install = import of immutable heads and the catalog scan is deleted; `extends` resolves through the store and stores the derived version with `parent`; session export embeds the version, preserved-history import matches head + `structure_digest`; mock scenarios are version blobs; Studio editor updates go through `DefinitionWriter`; `workflow create|consolidate|self-improve` on the store, `historyRoot` and `WorkflowDirectoryTransaction` deleted; run configurations become a stored definition kind |
| E1 | event bindings carry `workflow: { name, scope?, version? }` + environment overrides; server workflow manifest entries reference store heads; `riela instance` and the app daemon use `--workspace`; `node run` binds a workspace; cross-workflow callees resolve through the store; memory root moves to the project store `memory/`; the agent-node policy requirement replaces mandatory `agentSandbox` |
| E2 | `riela gc` sweeps `workspaces/`, ephemeral versions, blobs; cross-workflow callee instance rule |
| E3 | attachments and image paths must fall inside a declared mount; `node run` capability requirements |
| E4 | hardcoded provider credential table becomes the implicit default profile's `credential` |
| E5 | daemon and instance placement flags; worker memory-root rule deleted |
| E6 | hook events persisted and joined to executions; memory root as a system mount |
| E7 | surface catalog rows lose `--workflow-definition-dir`, `--working-dir`, `--artifact-root`; web run controls and `InstancesView` on workspace pickers (`blocked` rows) |

## Module Status

| Module | File Path | Status | Tests |
| --- | --- | --- | --- |
| Definition models, store, writer, canonicalizer | `Sources/RielaCore/Definition*.swift`, `JSONCanonical.swift` | NOT_STARTED | - |
| Registry rewrite | `Sources/RielaWorkflowRegistry/**` | NOT_STARTED | - |
| Environment types and validation | `Sources/RielaCore/ExecutionEnvironment*.swift`, `WorkflowModel.swift`, validators | NOT_STARTED | - |
| Run options and resolution | `Sources/RielaCLI/ParsedWorkflowOptions.swift`, `RielaCommand.swift`, `WorkflowRunCommand*.swift` | NOT_STARTED | - |
| Workspace runtime | `Sources/RielaCLI/Workspace*.swift`, `FileClone.swift`, `Sources/RielaCore/WorkspaceChangeSnapshot.swift` | NOT_STARTED | - |
| Policy engine | `Sources/RielaCore/ExecutionPolicy*.swift`, `Sources/RielaAdapters/SeatbeltSandbox.swift`, `EgressEnforcementPoint.swift`, `Sources/RielaCLI/ContainerRuntimeDriver.swift` | NOT_STARTED | - |
| Model profiles | `Sources/RielaCore/ModelProfile*.swift`, adapters | NOT_STARTED | - |
| Placement and workers | `Sources/RielaCLI/DistributedWorkerCommand.swift`, `Sources/RielaCore/Distributed*.swift`, `Sources/RielaServer/Distributed*.swift` | NOT_STARTED | - |
| Runner contract | `Sources/RielaAdapters/NodeMetadataWriter.swift`, `Sources/RielaNodeRunner/**`, `SessionCommands.swift` | NOT_STARTED | - |
| Surfaces | `Sources/RielaCLI/*Commands.swift`, `Sources/RielaGraphQL/*GraphQL.swift`, catalog rows, skills | NOT_STARTED | - |

## Dependencies

| Feature | Depends On | Status |
| --- | --- | --- |
| E0 | runtime records store, `SQLiteSchemaMigrator` discard path | Available |
| E1 | E0 | Planned |
| E2–E4 | E1 | Planned |
| E2 task binding beyond prepare/discard | Work Runtime P4 | Not started |
| E5 | E2, E3, E4; Work Runtime §5a resolver | Planned |
| E6 | E2, E3; linux-release CI | Available (CI) |
| E7 | E0–E6; web package for Studio | Studio rows `blocked` |

## Verification

- Build and tests through an arm64 shell; SwiftLint on changed Swift
  sources; complete logs under `tmp/execution-environment-consolidation/`.
- Per phase, `git diff --stat` stays within that phase's write scope plus
  the catalog/parity test files, generated SDL, this plan, the design doc,
  READMEs, and skill documents; anything else is a logged delta.
- No `import RielaWork` under `Sources/RielaCore`; no `import RielaCLI`
  under `Sources/RielaWork`.
- After E0: `grep -rn "temporary-workflows\|workflow-history\|workflow-state\|\.registry-state" Sources` → 0.
- After E1: `grep -rn "workingDirectory" Sources/RielaCore/WorkflowModel.swift` → 0;
  `grep -rn "agentSandbox\|AdditionalArgs\|apiKeyEnvironment" examples` → 0.
- After E3: `grep -rn "RIELA_SANDBOX_SEATBELT" Sources docs` → 0 and
  `localSandboxPolicy` has a production caller.
- Live checks per phase recorded in the progress log on a fresh temporary
  `--session-store`.
- Enforcement, resolution, and materialization are verified through the
  production adapters and executors (stub vendor executables, real
  Seatbelt on macOS, real container driver where available), never only
  through mock-scenario parity, because the scenario factory substitutes
  adapters (`ProductionNodeAdapter.swift:35`).

## Completion Criteria

- [ ] Every E box checked with evidence
- [ ] Full `swift test` green beyond the accepted environmental set
- [ ] Catalog, CLI, GraphQL, skill parity gates green
- [ ] `riela-packages` follow-up brief written and linked
- [ ] Design status line updated; `impl-plans/README.md` row updated

## Progress Log

- 2026-09-21: plan created from the zero-based design. Seam facts verified
  by two inventory passes (see the design's §2 and the intake document);
  load-bearing ones re-read directly: `AgentNodePayload`
  (`WorkflowModel.swift:764`), `ACPNewSessionRequest(mcpServers: [])`
  (`AgentGatewayNodeAdapter.swift:263-270`), `gatewayVendorArguments`
  (`:579-624`), `containerArguments` (`WorkflowStdioNodeExecutor.swift:124-138`),
  `localSandboxPolicy` without callers (`SeatbeltSandbox.swift:109-134`,
  `LocalProcess.swift:669`), `writeOwnership` runtime switch
  (`DeterministicWorkflowRunner+Fanout.swift:420-470`), `--working-dir`
  never reaching the adapter factory (`WorkflowRunCommand.swift:444-453`,
  `ProductionNodeAdapter.swift:35-46`), mutable registry storage
  (`design-mutable-workflow-registry.md` §Storage,
  `WorkflowHistoryIdentity.swift:169`), `WorkflowInstanceConfiguration`
  (`WorkflowInstanceModel.swift:168-173`), `RepositoryContext` /
  `IsolationRef` (`WorkContext.swift:14-31, 67-77`), closed `EvidenceKind`
  (`WorkEvidence.swift:10-22`), `surfaceRow`
  (`SurfaceCatalog+RowSupport.swift:88-105`), `TaskRoute`
  (`RielaClientCommandRouter.swift:105-108`), `RoutineGraphQL.swift` pattern
  and the SDL script, `DoctorCommandResult` (`DoctorCommand.swift:19-27`),
  no copyfile/clonefile use, `rielaExampleWorkflowNames()`, vendor CLI
  flags on the installed binaries. No code written.

- 2026-09-21 (review): Codex `gpt-6-astra` reviewed the design and plan
  (report under `tmp/astra-review/`, not committed); 18 findings verified
  against the tree and folded into design §21 and this plan: gateway
  process-runner seam for agent CLIs, `managerSessionId` not an
  authenticator, preserved-history checks retained, named instance
  branches, cross-store pins, `DefinitionPin`/`latestVersion`/`revision`/
  `DefinitionSubmission`, meaning-preserving normalization with
  `AssetRef.executable`, definition-assets mount, template branch and
  produced paths, tracked-set snapshot contract, policy invariants,
  deterministic model resolution and `trusted`, controller-side remote
  finalization, 153/149 example scope with workflow-level policy defaults,
  quarantine on generation mismatch, removals moved beside replacements.
  No code written.
- 2026-09-21 (model patching): design §22 added on user request; run
  configurations become a stored definition kind with selector overlays,
  layered resolution, per-step `EffectiveNodeModel`, `riela config` and
  `workflow models`, `--model-for` flags, A/B compare; E0/E1/E7 tasks
  extended accordingly. No code written.

## Related Plans

- **Depends On**: `impl-plans/active/work-runtime-p0-model-and-store.md`
  (types), Work Runtime P4 (task binding beyond prepare/discard), P7
  (ceilings).
- **Supersedes**: `impl-plans/active/workspace-provisioning.md` (deleted
  2026-09-21, never implemented).
- **Next**: intake adoptions B (failure domains), E (suspend/fork), H
  (threat model) in
  `design-docs/specs/design-ax-substrate-inspired-capabilities.md`.
