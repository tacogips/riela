# Execution environment consolidation: definition store, Workspace, Policy, Model, Placement, and the runner contract

Status: proposed 2026-09-21, zero-based; revised the same day after an
adversarial review by Codex `gpt-6-astra` (verdict "not ready for
implementation"; every accepted finding is listed in §21 and folded into
the sections it names). No backward compatibility: removed fields, flags,
directories, and files are gone, validation rejects them, and no example,
package, or store is migrated. Plan:
`impl-plans/active/execution-environment-consolidation.md`. This document
supersedes `design-workspace-provisioning.md` (deleted) and adoptions A, C,
D, F, and G of `design-ax-substrate-inspired-capabilities.md`. It is the
environment-axis sibling of `design-work-runtime-consolidation.md`: that
design answers *what work is done and when it is done*; this one answers
*where definitions live, where a node runs, what it may touch, which model
and credentials it uses, on which host, and how the process learns all of
that*.

Requirements source: user direction 2026-09-21 — back compatibility is not
required; the meaning of "workspace" may be redesigned from zero; list the
features to add, delete, merge, and strengthen, beyond workspace as well;
and, later the same day: workflow bodies should live in a database with
history rather than in files, since workflows and tasks will be created and
updated continuously, with import from files kept.

## 1. Purpose

Riela today has several partial answers to each of six questions:

| Question | Today's answers | Where |
| --- | --- | --- |
| Where do definitions live | project `.riela/workflows/<id>/` and user `~/.riela/workflows/`, mutable bundles under `~/.riela/temporary-workflows/` with a `.registry-state` transaction layout, activation overlay `~/.riela/workflow-state/activation.json`, history under `.riela/workflow-history`, packages under `.riela/packages`, ad-hoc `--workflow-json` / `--workflow-definition-dir`; 27 distinct hard-coded `.riela/<sub>` paths in `Sources` | `design-mutable-workflow-registry.md` §Storage, `WorkflowHistoryIdentity.swift:169`, `WorkflowRegistryCatalog.swift:352` |
| Working directory | node `workingDirectory` (a raw string resolved against the riela **process** cwd by the vendor, never validated), `command.workingDirectory`, `container.workingDirectory`; run `--working-dir` (which never reaches an agent process but anchors add-on resolution, fanout evidence, artifact root, env-file, the git repo-root rule, and bundle lookup); `WorkflowInstanceConfiguration.workingDirectory`; worker `workspaces.<k>.path` + `controllerPath` re-basing; container add-on `repo` scope = run dir | `WorkflowModel.swift:773`, `AgentGatewayNodeAdapter.swift:108, 265`, `WorkflowRunCommand.swift:57-73, 444-453`, `ContainerWorkflowAddonResolver.swift:378-398`, `DistributedWorkerNodeExecutor.swift:12-27` |
| Isolation between parallel or repeated executions | fanout `writeOwnership: read-only | disjoint-paths | isolated-workspace | shared-workspace` (runner: `read-only`/`shared-workspace` are `return`, `isolated-workspace` throws, `disjoint-paths` is a static overlap check); opt-in `changeTracking` content-hash drift observer; Work Runtime `RepositoryIsolation.worktree` (P4); `loop start --isolate` (throws) | `DeterministicWorkflowRunner+Fanout.swift:420-470`, `WorkflowFanoutChangeEvidence.swift`, `WorkContext.swift:4-10`, `LoopStartCommand.swift:151-153` |
| Environment contents | none; operators provision directories; package skills are projected into the current directory at install | `docs/distributed-workers.md`, `WorkflowPackageSupport.swift:180-250` |
| Filesystem and network constraint | `agentSandbox` (three strings → vendor flags only); riela's own Seatbelt derivation `localSandboxPolicy` **has no caller** (dead path behind `RIELA_SANDBOX_SEATBELT`, default `off`); container add-on capability scopes; boolean `network.egress`; container nodes unconstrained; no resource limits | `SeatbeltSandbox.swift:65-134`, `LocalProcess.swift:15-30, 669`, `ContainerWorkflowAddonResolver.swift:292-510` |
| Vendor arguments, model, credentials | `AgentToolPolicy { mode, additionalArguments, codexArguments, claudeArguments, cursorArguments }` **and** variables `codexAdditionalArgs` / `claudeAdditionalArgs` / `cursorAdditionalArgs`; node `baseURL`, `apiKeyEnvironment`, `provider`, `providerProxy`; instance node patches guarded by `modelFreeze`; `.env` files | `WorkflowModel.swift:77-125, 764-790`, `AgentGatewayNodeAdapter.swift:583-624`, `WorkflowInstanceResolver.swift:147` |
| Host selection and what the process is told | step `placement { target, workspace, exports }`; worker probes nothing (§5a designed); `RIELA_WORKFLOW_ID`, `RIELA_WORKFLOW_EXECUTION_ID`, `RIELA_NODE_ID`, `RIELA_NODE_EXEC_ID`, `RIELA_MEMORY_ROOT` (the only host→container mount) | `DistributedNodeExecution.swift:3-13`, `WorkflowStdioNodeExecutor.swift:107-136` |

Every row is a place where two runs of the same workflow can differ for a
reason nobody declared, or where a declared constraint is not enforced.
This design replaces all of them with one definition store, five
environment concepts, and one resolution rule.

## 2. Verified current state (2026-09-21)

Facts were read from the tree; line numbers move.

- **Definitions.** Bundles are directories (`workflow.json`, `nodes/`,
  `prompts/`, scripts) in project/user scopes; the mutable registry keeps
  its bundles under `~/.riela/temporary-workflows/` with a `.registry-state`
  transaction layout, two-level locks, staging, digest verification, and
  rollback (`design-mutable-workflow-registry.md` §Storage); activation is
  a JSON overlay with its own lock; history is a separate directory tree
  (`WorkflowHistoryIdentity.swift`); `workflow versions|restore|consolidate`
  and GraphQL `registerMutableWorkflow|updateMutableWorkflow|
  deleteMutableWorkflow|activateWorkflow|deactivateWorkflow|
  consolidateWorkflows` operate on those files. Packages install bundles as
  immutable directories with checksums. Temporary workflows
  (`--workflow-json`) are one-off bundles. `--workflow-root` does not exist
  in `Sources`; the options are `--scope` and `--workflow-definition-dir`
  (`WorkflowRegistryBundleLoader.swift:47-66`). Runs do **not** pin a bundle: a session records per-execution invocation
  compatibility digests (`_rielaHistoryContract`: workflow, variables,
  accepted-node payload, target input, communication) that preserved-history
  reuse checks (`DeterministicWorkflowRunner+History.swift:52-103`).
- **Node payload.** `AgentNodePayload` (`WorkflowModel.swift:764`) fields
  as listed in §1; payload files are decoded without unknown-key rejection
  (`WorkflowRegistryBundleLoader.swift:146`); `workingDirectory` has no
  validator; the script-path normalizer strips a `workingDirectory` prefix
  (`WorkflowModel.swift:675-684`).
- **Examples.** `workingDirectory` in 7 files (4 relative `scripts`, 2
  absolute `/workspace` in container workers, 1 mock scenario);
  `agentSandbox` in 4; `codexAdditionalArgs` 3; `cursorAdditionalArgs` 1;
  `providerProxy` 1; `placement` 2; `writeOwnership` 1; `modelFreeze` 192.
- **Run working directory.** `--working-dir` defaults to the process cwd,
  an instance overrides it only when the flag was not explicit
  (`WorkflowRunCommand.swift:444-453`); it is never passed to the node
  adapter factory and nothing calls `changeCurrentDirectoryPath`; it anchors
  mock-scenario paths, the add-on resolver, `fanoutWorkspaceRoot`, artifact
  root, `.env` resolution, git repo-root checks, and bundle lookup.
- **Command and container nodes.** `WorkflowCommandExecution { executable,
  arguments, environment, workingDirectory }` plus legacy `scriptPath` /
  `argvTemplate` / `envTemplate` decode keys; `WorkflowContainerExecution
  { image, runnerKind, runnerPath, command, environment, workingDirectory }`
  plus `build`, `entrypoint`, `argsTemplate`, `envTemplate`.
  `WorkflowStdioNodeExecutor` sets exactly `RIELA_WORKFLOW_ID`,
  `RIELA_WORKFLOW_EXECUTION_ID`, `RIELA_NODE_ID`, `RIELA_NODE_EXEC_ID`,
  `RIELA_MEMORY_ROOT`, strips three reserved keys, emits `run --rm -i`,
  `-e` per key, one `-v` (memory root), no `-w`, no resource flags; the
  evidence field `workingDirectoryPolicyStatus` is hard-coded `"allowed"`
  (`:285`). Container add-ons use `ContainerRuntimeDriver` with mounts,
  `--read-only`, `--tmpfs`, `--network none`.
- **Seatbelt.** `LocalProcessSandboxPolicy` and the SBPL generator exist;
  `resolveSeatbeltSandboxPolicy` / `localSandboxPolicy` have no callers;
  `LocalProcessConfiguration.sandboxPolicy` is never set, so
  `seatbeltInvocation` (`LocalProcess.swift:669`) always returns nil in
  production. `agentSandbox` reaches vendors as `--sandbox` /
  `--permission-mode` only. **Agent CLI processes do not go through
  `LocalProcess.swift` at all**: `AgentGatewayNodeAdapter.swift:41` builds
  `ProductionGatewayExecutor(environment:)`, whose default
  `processRunner` is the gateway package's `POSIXGatewayProcessRunner`
  (`GatewayExecution.swift:64-73, 128`); only command nodes, add-ons, and
  git run through Riela's `LocalProcessRunning`. The gateway exposes
  `processRunner` injection.
- **Fanout.** Four `writeOwnership` modes; only `disjoint-paths` has a
  runtime effect (static validation); `changeTracking` snapshots
  (sha256 + content, 1…512 paths, 8 MB/file, 64 MB total) run only when
  declared and report drift for "semantic review", never a lock;
  `defaults.fanoutConcurrency` has no runtime consumer (the bound is the
  transition `concurrency` and `--max-concurrency`).
- **Distributed.** `placement { target, workspace, exports }`; the
  controller does not resolve `agentEnvironment` for placed steps; the
  worker re-bases controller-absolute paths through `controllerPath`,
  forces memory root to `<workspace>/.riela/memory`, allowlists add-ons,
  and hard-denies `riela/git-commit|push` and
  `riela/workflow-create-register-run`; exports are ≤16 files / 512 KiB.
- **Git.** `riela/git-commit|push` require the run working directory to be
  the repository toplevel; `GitFinalizationStore` journals under
  `~/Library/Application Support/riela/git-finalization-v1`, outside the
  repository, with an empty HOME/hooks transport.
- **Skills, Work Runtime, session store, vendor CLIs, layering**: as in the
  intake document and unchanged: `WorkflowPackageSkill { vendor, name,
  sourcePath }` projected by `installSkillProjections`; `RepositoryContext`
  / `IsolationRef` with no production consumer of `writeScopes`; session
  store root from `resolveRootDirectory` with `runtime-records/` beneath;
  Claude Code `--mcp-config`/`--add-dir`/`--permission-mode`, Codex
  `-c`/`--sandbox`/`-C`, Cursor `mcp`/`--approve-mcps`/`--sandbox`;
  `RielaCLI → RielaAdapters → RielaCore`, `RielaWork → RielaCore`.

## 3. Design decisions

1. **Definitions live in a database with history; files are import and
   export formats.** Workflows (with their node payloads, prompts, and
   scripts), workspaces, policies, and models are *definitions*: named,
   versioned records in the runtime records database, each version
   immutable and content-addressed, with an active pointer and lineage.
   Creating, updating, activating, rolling back, consolidating, proposing,
   and accepting a definition are row operations in one transaction
   **within one store**. Sessions and tasks pin definitions from their own
   store; before a session is created, resolution snapshots the immutable
   dependency closure of every definition it resolved from another store
   (the user store, or a bundle-embedded document) into the session-owning
   store as pinned copies that keep the source store identity, version id,
   digest, and trust provenance and create no local head. Session creation
   and those pins commit together. No cross-database atomicity is
   promised, and consolidation across physical stores is rejected. A directory bundle, a
   `.rielapkg`, a JSON document on stdin, or a `--workflow-json` payload is
   an **import source** that yields a version; `export` writes a version
   back to a directory. The repository's `examples/` stay directories
   because they are fixtures, and tests import them.
2. **Six concepts, one resolution.** Definition store (what runs),
   `Workspace` (where, and what is in it), `Policy` (what the process may
   touch), `Model` (which model, whose credentials), `Placement` (which
   host), and the runner contract (how the process is told). Every
   execution resolves the last five into one `ResolvedExecutionEnvironment`
   before spawn; the record is persisted on the step execution and written
   into the node metadata file. No adapter decides location, constraint,
   model, or host on its own.
3. **Every execution has exactly one workspace instance root, and every
   path is relative to it.** Absolute paths leave node payloads, commands,
   containers, run configurations, and worker configuration. A run without
   a declared workspace binds the *ad-hoc local workspace*: the caller's
   directory, shared, never materialized. The run working directory stops
   being an anchor for anything else: bundle lookup is a definition-store
   scope question, add-ons and git resolve against the instance root,
   artifacts and evidence live under the session store.
4. **Workspace is definition → template → instance.** A definition
   declares git repositories, files, MCP servers, skills, bootstrap, warm
   policy, and tracked paths. A template is the definition materialized
   once under the session store, content-addressed, with a readiness marker
   written only after a check. An instance is a private tree derived from
   the template for one owner (session, task generation, fanout branch),
   attached as git worktrees plus copy-on-write clones. The ad-hoc local
   workspace has no template and one shared instance.
5. **Isolation is a property of a binding.** `isolation: shared |
   isolated` replaces the four `writeOwnership` modes,
   `RepositoryIsolation`, and `--isolate`. `shared` is one instance for the
   owner tree; `isolated` is one instance per branch or task generation,
   joined by the Work Runtime's `ChangeRuntime`. `disjoint-paths` becomes
   per-branch `policy.filesystem` write paths validated for overlap;
   `read-only` becomes `policy.filesystem.write: read-only`. Change
   snapshots over `track` paths are taken for **every** instance at
   creation and after each execution, on the one snapshot path that today's
   fanout drift observer and the P4 `ChangeRuntime.snapshot` sketch both
   describe.
6. **Policy is one object with four sections, rendered per execution
   class, and the rendering is real.** `filesystem` (`read-only |
   workspace | unrestricted`, `extraWrite`, `extraRead`), `network`
   (`deny | unrestricted | allowlist`), `resources` (cpus, memory, pids,
   wall clock), `agent` (`permission`, one `extraArguments` map). The dead
   Seatbelt derivation becomes the local renderer and is wired at the spawn
   choke point; the container renderer emits mounts and resource flags for
   nodes and add-ons alike; the vendor renderer emits `--permission-mode` /
   `--sandbox`; the worker renders locally. Each rendering records
   `enforced` or `advisory`. `agentSandbox`, `AgentToolPolicy`, the three
   `<vendor>AdditionalArgs` variables, `RIELA_SANDBOX_SEATBELT`, and
   `ContainerAddonSandboxPolicy` as a separate path are deleted. Add-on
   capability declarations stay as requirements checked against the
   effective policy at validation.
7. **Model is a profile with a credential source.** A node's `model` is a
   profile name or a literal model id; a literal resolves to
   `default/<backend>`. Profiles carry backend, model, parameters, base
   URL, proxy, and `credential: env | file | command` (command only from
   user scope). `baseURL`, `apiKeyEnvironment`, `provider`, `providerProxy`
   leave the node; `effort` and `modelFreeze` stay.
8. **Placement is capability matching.** A step or task names a host or
   leaves it to the resolver, which picks the first host whose capability
   table (Work Runtime §5a) covers the backend, can enforce the policy at
   the required level, and preferably holds the workspace template digest.
   `placement.workspace` and `controllerPath` disappear; `exports` becomes
   `artifacts` on the binding, returned as `artifact` evidence with the
   same bounds; the git add-on denial on workers is replaced by the policy
   (`finalization` is a capability the worker declares or not).
9. **The runner contract is a file plus a container entrypoint.**
   `RIELA_NODE_METADATA_PATH` (resolved environment, ids, evidence sink)
   and the three system mounts `RIELA_WORKSPACE_ROOT`,
   `RIELA_ARTIFACT_ROOT`, `RIELA_MEMORY_ROOT`, all listed in the record;
   container nodes mount the file read-only and may use the static
   `riela-runner` entrypoint (materialize bindings, readiness, own process
   group, bounded `SIGTERM`, exit code returned, `debug` keep-alive for
   `session exec`).
10. **Typed conditions replace ad-hoc readiness.** Sessions and attempts
    carry `conditions` (`DefinitionResolved`, `WorkspaceReady`,
    `PolicyReady`, `BackendReady`, `Ready`); the inactivity guard reads
    `Ready` so preparation never counts as a stall.
11. **Riela's seams, no new executor.** Materialization runs through the
    hardened git invocation and the local process runner in `RielaCLI`; the
    bootstrap goal is an ordinary agent execution; renderers extend the
    existing Seatbelt generator, container driver, and
    `gatewayVendorArguments`; the definition store extends the runtime
    records database; the workflow runner stays the only executor.
12. **No compatibility.** Removed fields fail validation with a message
    naming the replacement; removed directories are not read; examples and
    packaged skills are rewritten in the same change; the external
    `riela-packages` bundles are a follow-up package that must land before
    the next release.

## 4. Definition store

### 4.1 Model

```swift
public enum DefinitionKind: String { case workflow, workspace, policy, model, runConfiguration, addon }

public struct DefinitionVersion: Codable, Sendable {
  public var id: DefinitionVersionID                 // "defv-<uuid>"
  public var kind: DefinitionKind
  public var name: String?                           // unique per (scope, kind); nil only for ephemeral versions
  public var scope: DefinitionScope                  // global | project | workspace(name) — see §4.2
  public var digest: String                          // sha256 over the canonical document tree
  public var document: JSONObject                    // workflow.json / workspace / policy / model body
  public var files: [String: AssetRef]               // relative path → { digest, size, executable, kind: json | text | binary }
  public var parent: DefinitionVersionID?            // lineage
  public var origin: DefinitionOrigin                // authored | imported(path|url) | package(id, version) | proposal(attemptId) | generated(taskId) | consolidated([ids]) | ephemeral
  public var state: DefinitionVersionState           // proposed | accepted | rejected
  public var note: String?
  public var createdAt: Date
  public var createdBy: Principal                    // human | agent(sessionId) | system
}

public struct DefinitionHead: Codable, Sendable {    // one row per (scope, kind, name)
  public var kind: DefinitionKind
  public var name: String
  public var scope: DefinitionScope
  public var activeVersion: DefinitionVersionID?     // nil = deactivated
  public var latestVersion: DefinitionVersionID      // newest accepted version, independent of activation
  public var revision: Int                           // integer optimistic-concurrency token, as WorkStore uses (WorkStore.swift:118)
  public var mutable: Bool                           // false for package-installed heads
  public var updatedAt: Date
}

public struct DefinitionSubmission: Codable, Sendable {   // a rejected write; never an executable version
  public var id: String; public var kind: DefinitionKind; public var name: String?; public var scope: DefinitionScope
  public var origin: DefinitionOrigin; public var diagnostics: [WorkflowValidationDiagnostic]; public var createdAt: Date
}

public struct DefinitionPin: Codable, Sendable {      // a session's or task's reference to a resolved definition
  public var kind: DefinitionKind; public var name: String?; public var versionId: DefinitionVersionID
  public var digest: String; public var sourceStore: DefinitionStoreIdentity   // local | user | bundle(versionId)
  public var trusted: Bool                            // credential-command authority, never conferred by import
}
```

Tables in the runtime records database (the project store under the session
store root; the user store under `~/.riela/sessions/runtime-records`; §4.2
says which logical scopes live where):
`definition_heads`, `definition_versions` (JSONB document, generated
columns for kind/name/scope/digest/state/created_at), `definition_blobs`
(digest, bytes, size), with indexes on `(kind, name, scope)`, `digest`, and
`parent`. Blobs are content-addressed and shared across versions, so a
prompt edit stores one new blob and one new version row. A session pins
`definitionVersionId` for the workflow it ran and for every workspace,
policy, and model it resolved; the run trace shows them.

### 4.2 Scopes

Today's two scopes are directories: *project* (`<cwd>/.riela/...`) and
*user* (`~/.riela/...`). They survive as the two physical stores, and the
logical scope of a definition gains the workspace axis:

```swift
public enum DefinitionScope: Codable, Sendable {
  case global                        // the user store; today's "user scope", visible everywhere for this user
  case project                       // the store of the directory riela runs in; today's "project scope" = the ad-hoc workspace of that directory
  case workspace(name: String)       // attached to a named Workspace; visible only to executions that bind it
}
```

- **Physical placement.** `global` rows live in the user store
  (`~/.riela/sessions/runtime-records`); `project` and `workspace(name)`
  rows live in the project store of the directory that owns them. A
  `workspace(name)` row may also live in the user store when the workspace
  definition itself is global, so a personal workspace can carry its own
  workflows to any project.
- **Resolution order** for `(kind, name)` at run time: definitions
  embedded in the running workflow version → `workspace(<bound name>)` for
  each bound workspace, first binding first → `project` of the current
  directory → `global`. First active head wins; the winning scope and
  store are recorded on the session. A workspace that is bound by path
  (ad-hoc) contributes nothing beyond `project`, which is exactly today's
  behavior for a run in a repository.
- **Membership.** A `Workspace` definition may list `workflows`,
  `policies`, and `models` it expects (`expects: { workflows: [...] }`);
  `workspace validate` warns when an expected definition is missing in any
  visible scope, and `workspace prepare` can import them from a directory
  or package with `--with-definitions`. Membership is advisory; visibility
  is decided by the scope rows, so a workflow can be registered into a
  workspace scope without editing the workspace.
- **Tasks and intents** inherit the scope of their workspace binding:
  `riela task list --workspace riela-main` is the task board of that
  environment; an intent without a workspace is `project` scoped.
- **CLI and GraphQL.** `--scope global | project | workspace:<name>` on
  every definition command (`import`, `list`, `show`, `activate`, `fork`,
  `delete`, `consolidate`); `riela workflow run <name> --workspace <ws>`
  resolves through the workspace scope first. `definitions(scope:)` takes
  the same value. Today's `--scope user` is spelled `global`; `--scope
  project` keeps its meaning; `--scope auto` is the resolution order above.
- **Packages** install into the scope the user names (`global` by default,
  `project` or `workspace:<name>` on request); package heads stay
  immutable in every scope.
- **Workers** hold a user store (their `global`) and receive the pinned
  workflow version in the job payload, so workspace- and project-scoped
  definitions never need to be replicated to a worker; a worker's own
  `global` definitions (policies, models) are what its ceiling and
  profiles resolve from.
- **Served riela.** `riela serve` exposes the store of the directory it
  serves as `project` and its user store as `global`; a remote client's
  `--scope` names those. A shared team store is out of scope; the seam is
  the store URL, not the scope enum.

### 4.3 Operations

- **Resolve** by `(kind, name)` in the order of §4.2; bundle-embedded
  definitions are imported as part of their workflow version (a workflow
  version may carry `workspaces/`, `policies/`, `models/` documents in
  `files`).
- **Import**: `riela <kind> import <dir | file.json | - >` and
  `riela apply -f` create a version (`origin: imported`) and, unless
  `--no-activate`, move the head. `riela workflow run <dir>` on a directory
  imports an `ephemeral` version (not a head) and runs it, replacing
  `--workflow-definition-dir` and `--workflow-json`. Package install
  imports each packaged workflow as an immutable head (`origin: package`,
  `mutable: false`); "edit a package workflow" is `fork`, which creates a
  mutable head with `parent` set.
- **Update** creates a version with `parent = latestVersion`, bumps
  `revision` (a stale `expectedRevision` is a conflict, as in `WorkStore`),
  and activates only when the caller's activation policy says so;
  **activate** moves the head to any accepted version and is always an
  explicit operation; **rollback** is activate to an older version;
  **history** lists the chain; **diff** compares two versions' documents and files;
  **consolidate** creates one version from several heads and deactivates
  the sources (today's consolidation flow, on rows); **delete** removes the
  head and its exclusively owned versions; **export** writes a version to
  a directory in today's bundle layout.
- **Proposals**: Work Runtime `proposeWorkflowChange`, `workflow
  self-improve`, and `plan.generate` write versions with `state: proposed`
  and `origin: proposal | generated`; `accept` moves the head, `reject`
  keeps the row for the ledger. A task's `TaskPlan.workflow` references a
  head or a pinned version id.
- **Export** is a first-class operation, the inverse of import, in three
  formats: a directory bundle in today's layout (`workflow.json`, `nodes/`,
  `prompts/`, scripts, embedded `workspaces/`, `policies/`, `models/`),
  a single self-contained JSON document with blobs inlined (text as
  strings, binary base64) for pasting, review, or sending to another riela,
  and a `.rielapkg` archive through the existing packer. `riela <kind>
  export <name>[@<versionId>] --to <dir | file.json | archive.rielapkg>
  [--with-definitions] [--history]` exports the active version by default,
  a named version on request, the referenced workspace/policy/model
  definitions with `--with-definitions`, and the whole version chain as
  `history/<versionId>/` with `--history`. Exported text is the canonical
  form pretty-printed; re-importing an export yields `unchanged`
  (round-trip is a test on every example). Secrets never appear in an
  export: a model profile exports its `credential` descriptor (`env`
  name, `file` path, `command`), never a resolved value, and workspace
  `env` bindings export as bindings. `riela session export` keeps
  carrying the pinned version digest and now embeds the exported workflow
  version so a session archive is self-describing. GraphQL exposes
  `exportDefinition(name:, version:, format:)` returning the single-file
  form.
- **Ephemeral versions** are garbage-collected with the sessions that pin
  them; `riela gc` learns the table.
- **Locking** is the database's: one transaction per operation, optimistic
  `updatedAt` check on heads; the `.registry-state` layout, staging
  directories, advisory locks, and the activation overlay are deleted.

### 4.4 Write path: validate, normalize, digest, store

Every path that creates a version (`import`, `apply`, `update`, `fork`,
`consolidate`, proposals, `run <dir>`) goes through one function,
`DefinitionWriter.write(kind:name:scope:input:origin:)`, in this order;
nothing reaches a row that did not pass all four steps.

1. **Parse leniently.** Input may be a directory bundle or JSON text with
   comments (`//`, `/* */`), trailing commas, and a BOM; prompt and script
   files may have CRLF endings. The parser accepts these once, on the way
   in, so authors and agents can write sloppy JSON. Stored content never
   contains them.
2. **Validate strictly.** Unknown keys anywhere in a document are errors
   (`rejectUnsupportedKeys` on every type). `WorkflowValidation.validate`,
   `validateAgentNodePayload`, the workspace/policy/model validators, and
   the environment-aware pass (`validateExecutionEnvironment`: every
   `workspace`, `policy`, `model` reference resolves in the target scope or
   the same bundle; every `cwd` and `track` path is relative and contained;
   every prompt/script/blob reference exists in `files`) run on the
   candidate. Any error-severity diagnostic rejects the write and returns
   the diagnostics; warnings are stored on the version (`diagnostics`)
   and shown by `show`. There is no "save invalid as draft": a proposal
   from an agent that fails validation is recorded as a
   `DefinitionSubmission` (not a version) with the diagnostics so the
   ledger shows why; submissions are never executable and never heads.
3. **Normalize, without changing meaning.** Normalization applies to the
   structure Riela owns and never to bytes an agent or a shell will
   execute:
   - JSON documents (`workflow.json`, node payloads, workspace, policy,
     model, run configuration): keys sorted, insignificant whitespace
     removed, numbers in shortest round-trip form, no comments, no
     trailing commas, BOM removed, one trailing LF; fields equal to their
     documented default dropped (`modelFreeze: false`, empty `variables`,
     empty `agentEnvironment`). **String values are preserved byte for
     byte**: no Unicode normalization, no trimming, because a string may
     be a command argument or a literal an agent must reproduce.
   - Prompt and Markdown assets (`kind: text`): CRLF → LF, BOM removed, a
     single trailing newline. Trailing whitespace is stripped only when
     the asset is not referenced by a `command` or `container` node and
     is not fenced code; otherwise bytes are preserved. No NFC.
   - Scripts, containerfiles, and everything else (`kind: binary`): stored
     byte for byte, with `size` and the executable bit recorded so
     materialization restores `+x`. Symlinks are rejected on import, as the
     registry rejects them today.
   `riela workflow fmt` is the only operation that rewrites authored
   assets more aggressively (trailing whitespace in any text asset), and it
   is explicit, never an import side effect. `export` writes JSON
   pretty-printed with two-space indentation; the digest is computed over
   the canonical compact form, so export → import reports `unchanged`.
4. **Digest and dedupe.** `digest = sha256(v1 ∥ kind ∥ len(document) ∥
   canonical document ∥ for each sorted path: len(path) ∥ path ∥ asset
   digest ∥ executable bit)`, a versioned, length-prefixed framing so no
   two inputs share an encoding. A write whose digest equals the head's
   `latestVersion` creates no row and reports `unchanged`; a write whose
   digest equals an older version reports `duplicateOf(versionId)` and
   creates nothing, and **never activates anything by itself**. Content
   identity, activation, and retention are three separate concerns:
   activation is explicit (above), and retention is a graph: GC removes a
   version only when no head pointer, session pin, task plan, proposal,
   `parent` link of a retained version, or dependency pin references it.
   Assets are written by digest before the version row, in one transaction.

`riela workflow validate <dir|file>` keeps working on files by running
steps 1–3 without step 4 and printing the diagnostics and, with
`--print-normalized`, the canonical text, so an author can see what will be
stored. `riela workflow fmt <dir>` rewrites a bundle in place to the
normalized form (the only command that edits authored files).

### 4.5 Search, similarity, and the end of "temporary" workflows

Workflows will be created and revised continuously, by people and by
agents (`plan.generate`, self-improve, forks). Two things follow: search
has to be good enough that reuse is easier than re-creation, and the store
has to notice when a new workflow is a near-copy of an existing one.

**Index.** Every version write updates two derived indexes in the same
transaction:

- an FTS5 table `definition_search(version_id, kind, name, description,
  tags, purpose, step_ids, node_ids, prompt_text, backends, models, addons,
  workspace_refs, policy_refs)` built from the canonical document and its
  text blobs, so a query matches prompts and step names, not only titles;
- a **structural fingerprint**: a canonical serialization of the graph
  shape (ordered steps with node types, backends, add-on names, transition
  kinds including fanout and cross-workflow calls, gate declarations,
  output-contract schemas with values stripped) hashed to
  `structure_digest`, plus a MinHash sketch over prompt-text shingles
  (`text_sketch`). Two versions with equal `structure_digest` are the same
  workflow with different prompts; two with a high sketch overlap are the
  same prompts on a different graph.

**Search.** `riela workflow search <query> [--scope …] [--backend X]
[--addon Y] [--tag T] [--uses-workspace W] [--similar-to <name|dir|file>]
[--unused-since <duration>] [--sort relevance|recent|runs]` and GraphQL
`searchDefinitions(kind:, query:, filters:, similarTo:)`. Results carry
the head, scope, active version, purpose (from `design-workflow-usage-discovery.md`,
whose usage surface folds into search output as the `usage` block: entry
contract, expected output, step overview), lineage (`parent`, forks,
consolidations), and usage counts (sessions and tasks that pinned any
version of the head, from the runtime records). `--similar-to` ranks by
`structure_digest` equality first, then sketch similarity, then FTS score.
Similarity is discovery metadata: it ranks candidates and gates *creation*
(below); it never authorizes reusing a workflow for execution or reusing
preserved history on its own, because two single-agent graphs with equal
shape can carry opposite instructions.
`workflow usage` and `workflow list` become views over the same index.

**Finding a workflow to use, before making one.** Search is also the
entry point for *choosing*, not only for browsing. `riela workflow find
--for "<instruction>" [--workspace W] [--limit 5]` (GraphQL
`recommendDefinitions(instruction:, workspace:)`) tokenizes the
instruction, queries the FTS index over purpose, prompts, and step names,
boosts heads that have succeeded in the same workspace or with the same
add-ons and backends, and returns ranked candidates with their `usage`
block (entry contract, expected output, step overview) and recent success
rate from the runtime records. Every agent-facing path uses it first:

- the Work Runtime planner receives the top hits as a variable and must
  answer `reuse(head@version)`, `fork(head)`, or `new` with a reason; the
  runtime records the answer as a `Decision` with the hits as `causedBy`
  evidence, and when a hit is above the similarity threshold `new` is refused by the
  writer in favour of `fork(hit)` unless the planner passes `--force`
  with its reason, which the runtime records; the writer does not judge
  the reason, the ledger shows it;
- the `riela` routing skill and the `riela-workflow` authoring skill call
  `find` before `import` or `create`, and their parity gates check that
  the instruction is documented;
- Studio's "new workflow" action shows the candidates before an empty
  editor.

Ranking is lexical plus structural plus usage; there is no vector index
and no extra model call in the deterministic path. When the planner is an
agent, it is the judge of the candidates it is shown, which is where
semantic matching belongs.

**Similarity gate at write time.** `DefinitionWriter` computes the
fingerprint before storing and returns `similar: [{ name, scope, versionId,
structureMatch: Bool, textSimilarity: 0…1 }]` for every head above a
threshold (default: structure equal, or text similarity ≥ 0.8). The
caller's `onSimilar` policy decides: `warn` (store, report; default for
humans), `requireFork` (refuse a new head; the caller must `fork` the
closest match so lineage is explicit, or pass `--force`; default for
agents and for `plan.generate`), `reject`. Work Runtime planners search
before generating: `plan.generate` first runs `--similar-to` on the
intent's instruction and the candidate graph, reuses an existing head at a
pinned version when a match clears the threshold, and only otherwise
writes a new version, recording the choice as a `Decision` with the search
hits as `causedBy` evidence. `riela workflow consolidate` accepts
`--similar` to propose merges from the index, and `riela workflow gc
--unused-since 90d --dry-run` lists heads no session or task has pinned.

**Ephemeral versus workspace-local.** The temporary-workflow registry
(`--workflow-json`, `--workflow-json-file`, `~/.riela/temporary-workflows`,
the `riela-temporary-workflow` skill) is deleted, and its two uses split:

- a **one-shot run** (`riela workflow run <dir | file.json | ->`) imports
  an *ephemeral* version: no head, no name, pinned by the session, garbage
  collected with it, searchable only through the session it ran in. This
  is what "temporary" meant for fixture checks and one-off automation.
- a **workflow that belongs to an environment** is a *workspace-local*
  head: `scope: workspace(<name>)`, persistent, versioned, searchable,
  visible only to executions that bind that workspace. This is what
  "temporary" meant for project-specific helpers that outgrew a single run.
- a **task-generated plan** starts ephemeral (`origin: generated(taskId)`)
  and is promoted to a workspace-local head by `riela task promote-plan`
  (or the director's `promote` decision) when the task succeeds and the
  similarity gate passes; otherwise it dies with the task's sessions.

The rule of thumb: named and expected to run again → workspace-local
(or project/global); unnamed and one-shot → ephemeral. Nothing is
"temporary" in the store; things are either pinned by a session or
attached to a scope.

### 4.6 What this replaces

`.riela/workflows`, `~/.riela/workflows`, `~/.riela/temporary-workflows`,
`~/.riela/workflow-state/activation.json`, `.riela/workflow-history`,
`.riela/workflow-checkouts`, `.riela/workflow-checkout-sources`, and the
per-workflow directory scanning in `WorkflowRegistryCatalog`;
`WorkflowMutableRegistry*` filesystem transactions; `--scope` as a bundle
lookup axis (it remains as a definition-store scope filter);
`--workflow-definition-dir` and `--workflow-json` (import instead);
`workflow checkout` (import from a GitHub directory URL, same verb). Package
archives, checksums, and the registry index are unchanged as *import
sources*.

## 5. Environment domain model

```swift
public struct WorkspaceDefinition: Codable, Sendable {      // kind: workspace
  public var name: String
  public var description: String?
  public var git: [WorkspaceGitSource]                       // name, repo, revision, path, depth, submodules
  public var files: [WorkspaceFileSource]                    // name, blob or path → copied under files/
  public var mcp: [WorkspaceMCPServer]                       // ACPMCPServer shape; env values are AgentEnvironmentBinding
  public var skills: [WorkspaceSkillSource]                  // vendor, name, source: package | path | git | blob
  public var bootstrap: WorkspaceBootstrap?                  // command, goal, backend, model, timeoutMs, verify
  public var warm: WorkspaceWarmPolicy                       // enabled, relocatable, maxTemplates
  public var track: [String]                                 // relative paths whose change digests become evidence
}

public enum WorkspaceSource: Codable, Sendable {
  case definition(name: String)
  case path(String)                                          // ad-hoc: shared, never materialized
}

public struct WorkspaceBinding: Codable, Sendable {
  public var source: WorkspaceSource
  public var mount: String?                                  // container mount point; default = instance root path
  public var isolation: WorkspaceIsolation                   // shared | isolated
  public var goal: String?                                   // bootstrap goal override → distinct template digest
  public var track: [String]?                                // overrides the definition's track
  public var artifacts: [String]                             // relative paths collected after execution (replaces placement.exports)
  public var keep: Bool
}

public struct WorkspaceInstanceRef: Codable, Sendable {
  public var definition: String?; public var scope: DefinitionScope?; public var versionId: DefinitionVersionID?
  public var templateDigest: String?
  public var root: String
  public var owner: WorkspaceInstanceOwner                   // session(id) | taskGeneration(taskId, generation) | fanoutBranch(executionId)
  public var repositories: [WorkspaceRepositoryRef]          // name, path, revision
  public var method: WorkspaceInstanceMethod                 // adHoc | worktreeClone | worktreeCopy | inPlaceBootstrap
}

public struct ExecutionPolicy: Codable, Sendable {           // kind: policy
  public var name: String
  public var filesystem: FilesystemPolicy                    // write: readOnly | workspace | unrestricted; extraWrite; extraRead
  public var network: NetworkPolicy                          // egress: deny | unrestricted | allowlist([HostRule]); allowLocalhost; onDenied: record | fail
  public var resources: ResourcePolicy?                      // cpus, memoryBytes, pids, wallClockMs
  public var agent: AgentPolicy                              // permission: readOnly | workspaceWrite | bypass; extraArguments: [Vendor: [String]]
  public var capabilities: CapabilityPolicy                  // addons: allow | deny lists; finalization: Bool (git commit/push)
  public var enforcement: EnforcementLevel                   // off | auto | required
}

public struct ModelProfile: Codable, Sendable {              // kind: model
  public var name: String
  public var backend: NodeExecutionBackend
  public var model: String
  public var parameters: JSONObject
  public var baseURL: String?
  public var proxy: AgentProviderProxy?
  public var credential: CredentialSource?                   // env(name) | file(path) | command([String]) (user scope only)
}

public struct PlacementRequest: Codable, Sendable {
  public var host: PlacementHost?                            // local | worker(id) | group(name); nil = resolver
  public var require: PlacementRequirements                  // enforcement level, warm template preferred
}

public struct ResolvedExecutionEnvironment: Codable, Sendable {   // owned by RielaCore; on WorkflowStepExecution; projected onto Attempt by RielaWork
  public var definitions: [DefinitionPin]                     // one pin per resolved definition, keyed by (kind, binding id); several policies (ceilings) and several workspaces are representable
  public var workspace: WorkspaceInstanceRef                  // the cwd binding's instance (first release: the only binding, §19)
  public var cwd: String                                     // absolute, inside the instance
  public var mounts: [ResolvedMount]                         // bindings + system mounts
  public var policy: ResolvedPolicy                          // effective sections + per-rendering enforcement labels
  public var model: ResolvedModel                            // profile name, backend, model id (never the secret)
  public var host: ResolvedHost
  public var conditions: [ExecutionCondition]
}
```

Node payload after the change:

- kept: `id`, `description`, `nodeType`, `executionBackend`, `model`,
  `modelFreeze`, `effort`, `command`, `container`, `sleep`,
  `agentEnvironment`, prompts, `sessionPolicy`, `promptVariants`,
  `memories`, `variables`, `input`, `output`;
- added: `workspace: WorkspaceBinding` (one binding per node in the first
  release; the array form with binding ids is a §19 decision), `cwd:
  String?` (relative), `policy: String | ExecutionPolicy`. Placement stays
  a **step** property (`WorkflowStepRef.placement`, as today) and is not
  added to node payloads;
- removed: `workingDirectory`, `agentSandbox`, `agentToolPolicy`,
  `baseURL`, `apiKeyEnvironment`, `provider`, `providerProxy`; variables
  `codexAdditionalArgs`, `claudeAdditionalArgs`, `cursorAdditionalArgs`;
  legacy decode keys `scriptPath`, `argvTemplate`, `envTemplate`,
  `entrypoint`, `argsTemplate`, `build` (a container image is built by
  `riela workspace prepare` or the package pipeline, never by a node).
  Payload documents reject unknown keys.

`WorkflowCommandExecution` and `WorkflowContainerExecution` lose
`workingDirectory`; the container gains `debug`, `resources` come from the
policy, mounts from bindings. `workflow.json` gains top-level `workspace`,
`policy`, and `model` defaults. The fanout transition loses
`writeOwnership` and `changeTracking`, gains `workspace: WorkspaceBinding`,
and `defaults.fanoutConcurrency` is deleted (dead). `WorkflowInstanceConfiguration`
(run configuration) loses `workingDirectory` and gains `workspace`,
`policy`, and `model` overrides beside its `.env` and variables. Work
Runtime: `ContextBinding.repository` → `ContextBinding.workspace(WorkspaceBinding)`;
`Attempt.isolation: IsolationRef?` → `Attempt.environment:
ResolvedExecutionEnvironment?`; `IntentConstraints` gains `policyCeiling`
and a default `workspace`.

## 6. Workspace lifecycle

### 6.1 Resolution

`workflow run` binds, in order: `--workspace <name>`, `--workspace-path
<dir>`, the run configuration's binding, the workflow's top-level
`workspace`, then the ad-hoc local workspace at the caller's directory. A
node's own `workspace` overrides for that node; a fanout transition's
binding applies to each branch; a task's comes from `ContextBinding`,
defaulting to the intent's.

### 6.2 Template and instance

```
<session-store-root>/workspaces/<name>/<digest>/   spec.json resolved.json repos/ files/ bootstrap/ prepared.json|failed.json prepare.lock
<session-store-root>/workspaces/<name>/instances/<owner-id>/
```

`digest = sha256(definition version digest ∥ resolved shas ∥ goal override
∥ materializer version)`. Steps, each logged and recorded: clone (hardened
`runGitResult`, readiness = `HEAD` resolves and tree non-empty), copy
files and blobs, write `.riela/mcp.json` and `.cursor/mcp.json`
(placeholders for secrets), project skills with `installSkillProjections`
into `files/`, run `bootstrap.command`, run `bootstrap.goal` as an internal
agent execution under `policy.filesystem: workspace` with the template as
cwd, run `bootstrap.verify`, write `prepared.json` atomically; any failure
writes `failed.json` and the template is never reused silently; a
relocatability scan downgrades `relocatable`; `prepare.lock` serializes.

Instances: for each repository the materializer, after bootstrap, commits
any tracked changes bootstrap made onto a template-local branch
`riela/template/<digest>` and records the untracked and ignored paths
bootstrap produced (`resolved.json: producedPaths`); an instance is `git
worktree add -b riela/<owner-id> <path> riela/template/<digest>` (a
**named** branch, because `riela/git-commit` requires `symbolic-ref HEAD`
to resolve, `ProductionNodeAdapter+GitCommit.swift:413`), plus a
copy-on-write clone of every produced path and of `files/` (`copyfile(3)`
`COPYFILE_CLONE`, `FICLONE`, plain copy fallback; method recorded; symlinks
and submodule checkouts reproduced explicitly). Two instances of one
template therefore start with identical content while their writes stay
independent. Every execution also receives a read-only **definition-assets
mount** (`RIELA_DEFINITION_ROOT`) materialized from its pinned workflow
version and pinned `nodeRef` dependencies, with executable bits restored,
so bundle scripts run from there while `cwd` stays workspace-relative;
asset references (`definition://scripts/foo.sh`) and workspace paths are
distinct typed references. Verify-on-first-use with the in-place fallback
as above.
Owner ids: session id; `<taskId>-g<generation>` shared by every attempt of
a generation (rerun and recover continue on the edited tree; replan bumps
it); fanout branch execution id. Removal on owner completion unless
`keep`; task instances on terminal state or supersession; `riela workspace
gc` and `riela gc` enforce `maxTemplates` and reconcile orphans. The ad-hoc
local workspace is `method: adHoc`, no template, never removed.

### 6.3 Isolation and change evidence

`shared`: one instance per owner tree. `isolated`: one per branch or task
generation, merged by the join step or `ChangeRuntime`. For every instance
the runtime snapshots the tracked set at creation and after each
execution: `track` entries are exact regular-file paths or directory
globs that expand to at most 512 regular files and 64 MB in total (the
existing engine's bounds, `WorkflowFanoutChangeEvidence.swift:58`); when
`track` is empty the snapshot is `git status --porcelain` plus content
digests of changed tracked files, which needs no bound. New files under a
tracked directory are included by the glob expansion; concurrent writers
are not serialized (this is observation, not a lock). Diffs are
`changedFile` evidence and feed the fanout join's conflict *report*; merge
and conflict *resolution* belong to P4's `ChangeRuntime`, which consumes
the recorded base revision and change set. The ad-hoc workspace
snapshots only when `track` is given.

### 6.4 Projections at spawn

| Vendor | MCP | Skills | Policy |
| --- | --- | --- | --- |
| Claude Code | `--mcp-config <0600 temp copy with secrets>`, deleted after the turn | `<instance>/.claude/skills` | `--permission-mode`; Seatbelt (filesystem, network); `--add-dir` for extra paths |
| Codex | `-c mcp_servers.<name>.<key>=<value>` | `<instance>/.codex/skills` | `--sandbox`, `-c sandbox_permissions=[…]`; network via proxy env (`advisory`) |
| Cursor | `<instance>/.cursor/mcp.json` + `--approve-mcps` | `<instance>/.cursor/rules` | `--sandbox`; Seatbelt |
| official SDKs | none (validation warning) | `AGENTS.md` / `GEMINI.md` | network via proxy env (`advisory`) |

The ACP request carries `mcpServers` as well, for the day `agent-gateway`
reads it.

## 7. Policy resolution and enforcement

Effective policy = intersection of the intent ceiling, the worker ceiling,
the workflow default, and the node policy; lower levels narrow, never
widen. Add-on capability declarations are requirements: a required
capability the effective policy denies fails validation.

| Section | Local agent CLI (Seatbelt) | Codex | Container node / add-on | Distributed worker |
| --- | --- | --- | --- | --- |
| `filesystem.write` | SBPL writable subpaths = instance root (+`extraWrite`), artifact root, temp; applied by the policy-aware gateway process runner for agent CLIs and at `LocalProcess.swift:669` for command nodes | `--sandbox` mapping (`advisory`) | RW bind mounts only for bindings and `extraWrite`; `--read-only`, `--tmpfs /tmp` | rendered locally |
| `network` | `(deny network*)` + loopback allow for the per-session enforcement point (CONNECT proxy, per-attempt bearer, allowlist by CONNECT authority, `egress` evidence); `HTTPS_PROXY` set | proxy env (`advisory`) | `--network none` for `deny`; internal network + proxy for allowlists where the driver allows, else `advisory` | worker-local enforcement point |
| `resources` | diagnostic only (no cgroups on macOS) | same | `--cpus`, `--memory`, `--pids-limit` | as local |
| `agent` | `--permission-mode`, `extraArguments[claude]` | `--sandbox`, `extraArguments[codex]` | n/a | forwarded |
| `capabilities` | add-on allow/deny; `finalization` gates `riela/git-commit|push` | same | same | replaces `allowedAddons` and the hard-coded denials |

`enforcement: off | auto | required` (default `auto`); `required` fails
loudly where a rendering would be `advisory`. Labels live on the resolved
environment record, **per constraint and per execution path**: in-process
add-ons and official SDK calls run inside the riela process and are never
described as Seatbelt-enforced; their filesystem and network sections are
`advisory` unless the egress point applies (network) and are reported as
such.

Invariants of intersection and rendering:

- Intersection is defined per field: an omitted section means "no
  constraint from this level", `enforcement` takes the strictest level,
  `filesystem.write` takes the narrowest mode and the intersection of
  `extraWrite`, `network` takes `deny` over `allowlist` over
  `unrestricted` and intersects allowlists, `resources` takes the minimum,
  `capabilities` intersects allow lists and unions deny lists,
  `agent.permission` takes the narrowest. A ceiling can never be widened
  by a workflow default, a node, a run configuration, workflow input, or a
  variable.
- `policy.environment { inherit: [names], forbid: [names] }` replaces the
  worker's `allowedEnvironment`; the worker transport token variable is
  always forbidden (`DistributedWorkerCommand.swift:20` survives as the
  worker ceiling's `forbid`).
- Renderer-owned argv and environment keys (`--sandbox`,
  `--permission-mode`, `-c sandbox_permissions`, `--mcp-config`,
  `--approve-mcps`, `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY`/`NO_PROXY`,
  credential variables, `RIELA_*`) cannot be set by `extraArguments`,
  `agentEnvironment`, or workspace MCP `env`; validation rejects them.
- Agent CLIs are rendered through a policy-aware `GatewayProcessRunning`
  injected into `ProductionGatewayExecutor` (the gateway's own runner
  seam), not through `LocalProcess.swift`; command nodes, add-ons, and git
  use Riela's `LocalProcessRunning`. A renderer is labeled `enforced`
  only after its actual launch path applied the policy, and E3's tests
  exercise the production gateway adapter, not only shell commands.

## 8. Model profiles

`credential.kind`: `env`, `file` (under
`${XDG_STATE_HOME:-~/.local/state}/riela/credentials`), `command`. A
`command` credential executes only when the head carries `trusted: true`,
which is set solely by `riela model trust <name>` on the host (an
explicit operator action recorded with the principal) and is cleared by
any import, fork, copy, or package install; scope alone never confers it. Secrets are resolved at spawn, never persisted, never in
evidence or telemetry; the redactor gains `credential`. Workers resolve
profiles from their own store by name; the controller ships names.
Resolution of a node's `model` is deterministic: if a `Model` head named
exactly that string is visible in the scope chain it is a profile
reference; otherwise the string is a literal model id, the node's
`executionBackend` is required, and credentials and routing come from
`default/<backend>` while the literal stays the selected model (so literal
B after literal A runs B). Profile `backend` must equal the node's
`executionBackend` or validation fails; profile `parameters` are defaults
the node's `effort` overrides; `modelFreeze` continues to block run-
configuration patches. Workers execute the controller-pinned profile
version (sent in the job's pins) and resolve only its credential locally.
When a node names a literal model and no `default/<backend>` head exists in
any visible scope, riela **creates** one with insert-if-absent semantics
(concurrent creators reload the winning row): a `global` head in the user
store with `origin: implicit`, `backend`, `model` set to the literal, no
`parameters`, and `credential` set to the backend's conventional
environment variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `CURSOR_API_KEY`,
`GEMINI_API_KEY`) or `nil` for CLI backends that carry their own login.
The row is a real definition: `riela model list` shows it with its origin,
`show` prints it, `update` edits it like any other, and the session records
`implicitProfileCreated` so the run trace explains where the profile came
from. A later explicit `default/<backend>` in a narrower scope shadows it
by the normal resolution order. `riela doctor` and the §5a capability table
report which profiles resolve; `placement` evidence records the profile
name and origin.

## 9. Placement and workers

```json
{ "controllerURL": "…", "tokenFile": "worker.token", "capacity": 2,
  "workspaces": { "project": { "definition": "riela-main" }, "scratch": { "path": "/srv/scratch" } },
  "policy": "worker-ceiling", "models": ["opus-review", "default/codex-agent"] }
```

A worker prepares `definition` workspaces under its own session store on
first use and registers backends, enforcement levels, template digests, and
resolvable profiles. The resolver (Work Runtime §5a extended) picks the
host; explicit `placement.host` never falls back. The job payload carries
the resolved environment minus secrets and host paths; results return as
`artifact` evidence and change snapshots. **Finalization never runs on a
worker**: the worker's ceiling has `capabilities.finalization: false`
permanently, finalization tokens stay excluded from serialized adapter
output (`AdapterContracts.swift:244`), and a remote change set is
finalized by the controller through the existing journaled store against
the controller's own instance of the same template (base revision + change
set from the snapshot), so the trust protocol of
`design-distributed-workers.md` is unchanged. `controllerPath` is gone
because no authored path is absolute; `agentEnvironment` resolution stays
on the worker.

## 10. Runner contract

- `RIELA_NODE_METADATA_PATH` → `<session>/<execution>/node-metadata.json`
  (resolved environment, ids, evidence sink); mounted read-only at
  `/riela/metadata/node.json` in containers.
- `RIELA_WORKSPACE_ROOT`, `RIELA_ARTIFACT_ROOT`, `RIELA_MEMORY_ROOT`: the
  three system mounts; the existing `RIELA_WORKFLOW_ID`,
  `RIELA_WORKFLOW_EXECUTION_ID`, `RIELA_NODE_ID`, `RIELA_NODE_EXEC_ID` stay.
- `runnerKind: riela-runner`: static entrypoint (linux amd64/arm64 from the
  linux-release CI), applies binding mounts, readiness, own process group,
  10 s `SIGTERM` grace, exit code in the result envelope, `debug`
  keep-alive.
- `riela session exec <id> [--step <id>] -- <cmd>`: same effective policy,
  recorded as `command` evidence with `producedBy: human(principal)` and
  the policy digest. Authorization is a **verified host principal** that
  owns the session's store (local trust plus the host's Passkey gate for
  remote callers); `managerSessionId` is not an authenticator and is not
  used (`GraphQLSessionControlContracts.swift:46`). The surface stays
  `blocked` in the catalog until E6 ships the ownership check and denial
  tests.

## 11. What is removed

| Today | Verdict | Replaced by | Blast radius |
| --- | --- | --- | --- |
| File-based workflow storage: `.riela/workflows`, `~/.riela/workflows`, `~/.riela/temporary-workflows` + `.registry-state`, `~/.riela/workflow-state/activation.json`, `.riela/workflow-history`, `.riela/workflow-checkouts*`; `WorkflowMutableRegistry*` filesystem transactions; `--workflow-definition-dir`, `--workflow-json`, `--workflow-json-file`; `workflow checkout` as a separate mechanism | delete | definition store (§4); `import`, `export`, `run <dir>` ephemeral import, `fork` | `RielaWorkflowRegistry` (most files), catalog/resolution commands, GraphQL registry provider, web registry views, package installer, temporary-workflow skill, ~15 test files |
| Node `workingDirectory`, `command.workingDirectory`, `container.workingDirectory`, legacy decode keys (`scriptPath`, `argvTemplate`, `envTemplate`, `entrypoint`, `argsTemplate`, `build`) | delete | `workspace` binding + relative `cwd` | 7 example node files, `WorkflowStdioNodeExecutor`, adapters, tests |
| `--working-dir`, `WorkflowRunOptions.workingDirectory` / `explicitWorkingDirectory`, `effectiveRunWorkingDirectory`, `KaibaPreflightedRunContext.workingDirectory`, `fanoutWorkspaceRoot` | delete | `--workspace`, `--workspace-path`, run-configuration binding; add-ons, fanout, git resolve against the instance root | `ParsedWorkflowOptions`, `RielaClientFamilyArguments`, `WorkflowRunCommand*`, `SessionCommands+KaibaPreflight`, CLI tests |
| `WorkflowInstanceConfiguration.workingDirectory` | delete | `workspace` / `policy` / `model` on the run configuration | instance model, resolver, app/web forms, tests |
| Worker `workspaces.<k>.path` + `controllerPath`, `allowedAddons`, `allowedEnvironment`, hard-coded git denial | delete / merge | `definition | path` bindings; worker `policy` ceiling (`capabilities`, environment allowlist) | `DistributedWorkerCommand`, `DistributedWorkerNodeExecutor`, docs, tests |
| `placement.workspace`, `placement.exports` | delete | binding decides; `artifacts` on the binding | `DistributedNodeExecution`, `DistributedPlacementValidation`, 2 examples |
| Fanout `writeOwnership` (4 modes), `changeTracking`, `defaults.fanoutConcurrency` | delete | binding `isolation` + `track`; per-branch policy write paths; snapshots for every instance | `WorkflowModel`, `+Fanout`, `WorkflowFanoutChangeEvidence` (kept as the snapshot engine, renamed), capability gap, 1 example |
| Work Runtime `RepositoryContext`, `RepositoryIsolation`, `IsolationRef` | delete | `ContextBinding.workspace`, `WorkspaceInstanceRef`, `Attempt.environment` | `RielaWork` P0 types, one codable test |
| `loop start --isolate` | delete | binding `isolation` | `LoopStartCommand` |
| `agentSandbox` / `AgentSandboxMode` | delete | `policy.filesystem.write` + `policy.agent.permission` (agent nodes must resolve a policy at validation, preserving the output-contract design's intent) | 4 examples, adapters, `WorkflowNodeValidation`, tests |
| `AgentToolPolicy`, `<vendor>AdditionalArgs` variables | delete | `policy.agent.extraArguments` | 4 examples, `gatewayVendorArguments`, `AdapterUtilities`, tests |
| `RIELA_SANDBOX_SEATBELT`; the unwired `localSandboxPolicy` path | delete / wire | `policy.enforcement` (default `auto`) and the local renderer actually called at spawn | `SeatbeltSandbox`, `LocalProcess`, docs |
| `ContainerAddonSandboxPolicy` as a separate enforcement path; `repo` scope = run dir | merge | container renderer; `repo` = instance root | `ContainerWorkflowAddonResolver`, tests |
| Node `baseURL`, `apiKeyEnvironment`, `provider`, `providerProxy` | delete | `Model` profiles | 1 example, adapters, `AgentEnvironment` |
| Special-cased memory-root mount; `workingDirectoryPolicyStatus: "allowed"` | merge / delete | declared system mount; policy labels on the resolved environment | `WorkflowStdioNodeExecutor` |
| Project-scope skill projection into the cwd at package install | delete | workspace `skills`; user-scope projection stays | `WorkflowPackageSupport`, install commands |
| `--artifact-root`, `RIELA_ARTIFACT_DIR` as user-facing knobs | delete | artifacts always under the session store, exposed as `RIELA_ARTIFACT_ROOT` | run command, container resolver, tests |
| `design-workflow-configuration-workspace.md` naming | rename | "run configuration" | UI copy |

Removed fields, flags, and directories fail with `"<x> was removed; use
<replacement>"`.

## 12. What is added, merged, or strengthened

| Feature | Kind | Notes |
| --- | --- | --- |
| Definition store with versions, lineage, proposals, import/export | add + merge | replaces five file layouts and their locks; proposals from self-improve and the Work Runtime become first-class rows |
| Workflow search (FTS + structural fingerprint + usage counts) and the similarity gate | add | reuse beats re-creation; agents must fork instead of duplicating; `usage`/`list` become views over the index |
| Ephemeral versions and workspace-local heads | merge | the temporary-workflow registry's two uses, separated |
| `Workspace` definition, template, instance, warm cache, MCP and skills per run | add | the environment declaration Riela never had |
| Ad-hoc local workspace | add | today's implicit behavior made explicit and recorded |
| One isolation model + change snapshots for every instance | merge + strengthen | fanout, Work Runtime, loop |
| `Policy` (filesystem, network, resources, agent, capabilities) rendered for real | merge + add | Seatbelt wired and on by default; egress allowlists, resource limits, add-on allow/deny and finalization gate |
| Local egress enforcement point | add | loopback CONNECT proxy with evidence |
| Container mounts, resource flags, `debug`, `riela-runner` | add | container nodes get the driver features add-ons already have |
| `Model` profiles with credential sources | add | rotation in one place; workers never see secrets |
| Placement by capability incl. warm templates and enforcement | strengthen | Work Runtime §5a extended |
| Node metadata file, `session exec`, typed conditions | add | runner contract |
| Validation and `doctor` for definitions, workspaces, policies, models, hosts | strengthen | unresolved references, missing projections, template state, profile resolution |

## 13. Surfaces

Catalog rows first; CLI and GraphQL ship together or declare `blocked`.

- Definitions: `riela workflow|workspace|policy|model import|export|list|
  show|history|diff|activate|rollback|fork|delete`, `riela workflow
  search|usage|consolidate [--similar]|gc --unused-since`, `riela task
  promote-plan`, `riela apply -f`, `riela get|describe <kind> [name]`;
  `riela workflow run <name | dir | file.json | -> [--version <id>]`.
- Environment: `riela workspace prepare|gc|validate`, `riela policy render
  <name> --class <local|codex|container|worker>`, `riela workflow run
  --workspace | --workspace-path | --keep-workspace | --policy | --model |
  --placement`, `riela session exec`, `riela doctor` sections.
- GraphQL: `definitions(kind:, scope:)`, `definition`,
  `definitionHistory`, `searchDefinitions`, `exportDefinition`,
  `importDefinition`, `activateDefinition`,
  `forkDefinition`, `deleteDefinition`, `consolidateWorkflows`,
  `workspaces|policies|models` as kind-filtered views, `prepareWorkspace`,
  `gcWorkspaces`, `hostCapabilities`, `execInSession`; sessions and tasks
  expose `conditions` and the resolved environment. The
  `registerMutableWorkflow|updateMutableWorkflow|deleteMutableWorkflow|
  activateWorkflow|deactivateWorkflow` mutations are deleted.
- Studio: definition history and diff, workspace/policy/model pickers,
  resolved environment on the run trace. Declared `blocked` until the web
  package picks it up.
- Skills: `riela-workflow`, `riela-workflow-run`, `riela-node-addons`,
  `riela-package`, `riela-temporary-workflow` (deleted; folded into
  `riela-workflow-run` import), `riela-workflow-checkout` (folded into
  import).

## 14. Storage and layout

Session store root: `runtime-records/` (sessions, work tables, definition
tables), `workspaces/` (templates, instances), `artifacts/`, `logs/`.
`WorkflowStepExecution.environment: ResolvedExecutionEnvironment?`,
`WorkflowSession.pins: [DefinitionPin]`, and `WorkflowSession.conditions`
are `RielaCore`-owned execution records written for every run, task or
not; `RielaWork` projects them into task evidence when a task exists
(`contextSnapshot` for the environment, `changedFile` for snapshots,
`command` for bootstrap and exec) and adds the closed kinds `egress` and
`placement` to its own enum; `RielaCore` does not import `RielaWork`. The
runtime store schema generation is bumped once for the definition tables
and the new session fields. Because the database now holds authored
definitions, the "regenerable history, discard on mismatch" rule
(`SQLiteWorkflowRuntimePersistenceStore.swift:160-170`) no longer applies
to it: on a generation mismatch the store is **quarantined** (renamed
`runtime-records.incompatible-<generation>/`), riela refuses to run until
`riela store reset --confirm` or `riela store export-definitions
<quarantined>` (best-effort export of the definition tables to bundles)
has been run, and nothing is deleted silently. This is still no migration
path. `.riela/` in a project keeps `sessions/`, `packages/`,
`package-cache/`, `package-locks/`, `events/`, `kaiba/`, `note/`, `memory/`,
`profiles/`, `config.json`; every other subpath in §1's list is deleted
with its feature.

## 15. Phases

Each phase ends with `swift test` green, every example's mock run matching
`EXPECTED_RESULTS.md`, and a status update here.

- **E0 Definition store.** Tables, blobs, import/export/history/activate/
  fork/consolidate, ephemeral run-from-directory, package install as
  import, registry file layouts and their commands deleted, examples
  imported by tests, GraphQL and web on rows. The first compatibility break.
- **E1 Environment model and validation.** New types, node and workflow
  fields, resource loaders over the store, `ResolvedExecutionEnvironment`,
  the ad-hoc local workspace as the runtime behavior, the definition-asset
  mount, and the removal of the *location* fields (`workingDirectory`,
  `--working-dir`, `--artifact-root`, run-configuration
  `workingDirectory`, `controllerPath`) with replacement diagnostics. The
  second compatibility break. Every other removal in §11 ships **in the
  phase that ships its replacement**, never earlier: `agentSandbox`,
  `AgentToolPolicy`, `<vendor>AdditionalArgs`, `RIELA_SANDBOX_SEATBELT` go
  in E3; node credential fields in E4; `placement.workspace/exports`,
  worker `allowedAddons/allowedEnvironment` in E5. E0–E7 are internal
  milestones, not releasable states; a release cut between them must
  contain no field that was removed without its replacement.
- **E2 Workspace runtime.** Materializer, templates, instances,
  copy-on-write clone, change snapshots for every instance, fanout and
  Work Runtime bindings.
- **E3 Policy engine.** Renderers for the four classes, Seatbelt wired and
  `auto`, container mounts and resource flags, egress enforcement point,
  capability requirements.
- **E4 Model profiles.** Loader, credential sources, `default/<backend>`,
  adapter wiring, redactor.
- **E5 Placement and workers.** Worker bindings and ceilings, capability
  table with templates and enforcement, resolver, artifact return.
- **E6 Runner contract and conditions.** Metadata file, system mounts,
  `riela-runner`, `session exec`, typed conditions.
- **E7 Surfaces and packages.** Remaining CLI/GraphQL rows, doctor, Studio,
  skill docs, `riela-packages` follow-up.

E0's store, writer, search, and import/export are independent of Work
Runtime P1; E0's planner integration and `task promote-plan` depend on P1
and are listed under it; E2's task binding lands with P4 and hands it the
base tree (branch creation and publication are specified jointly by E2 and
P4); E3's ceilings serve P7. Bootstrap goals (E2) run only after E3's
policy renderer exists, so E2 and E3 land in that order or together.

## 16. Rejected alternatives

- **Keep files as the source of truth and add a database index.**
  Rejected: two sources of truth need reconciliation, which is what the
  `.registry-state` layout, the activation overlay, and the history tree
  already are.
- **A separate definitions database.** Rejected: a run must pin the
  definition version in the same transaction that creates the session, and
  the Work Runtime already chose one database for the same reason.
- **Keep `workingDirectory` beside `workspace`; keep `agentSandbox` as a
  shorthand; rename the concept to dodge the worker `workspaces` name.**
  Rejected: each keeps a second answer to a question this design closes.
- **A policy DSL; process snapshots; registries; YAML; Kubernetes.**
  Rejected as in the intake document.

## 17. Risks

- **Blast radius of E0 and E1.** The registry module, every example with a
  removed field, the packaged skills, and the external `riela-packages`
  bundles change. The plan lists files; parity tests catch drift; the
  registry package must land before the next release.
- **Enforcement flips on.** `auto` makes Seatbelt active by default on
  macOS; workflows that wrote outside their workspace fail with
  `policyBlocked`. Intended; `unrestricted` remains available.
- **Container images that assumed `/workspace`** set `mount: "/workspace"`.
- **Vendor flag drift; secrets transiting files** (Claude Code, Cursor MCP
  config): temp 0600 copies, per-vendor renderers with fixture tests.
- **Codex stays advisory** for filesystem and network; labeled, not hidden.
- **Worktrees and agents that run git**: an instance is a worktree on a
  named branch (§6.2), so `riela/git-commit`'s `symbolic-ref HEAD` rule
  and the repository-root rule both hold; a detached instance would not.
- **Blob growth**: content addressing dedupes prompts; `gc` removes blobs
  no version references.

## 18. Resolved questions

Decided by the user on 2026-09-21; the reason is recorded so later work does
not reopen it without new facts.

- **`policy.enforcement` defaults to `auto`.** Constraints that exist only
  as advisory flags are the defect this design closes; `auto` enforces
  wherever a renderer can and labels the rest `advisory`, and
  `unrestricted` remains one field away for workflows that need it.
- **A missing `default/<backend>` profile is created implicitly, as a
  real row** (§8), not synthesized in memory. A fresh checkout runs
  without ceremony, and the created profile is visible, editable, and
  attributed in the run trace, so "where did this credential come from"
  always has an answer in `riela model list`.

- **The user store and the project store stay separate.** Two physical
  databases mirror today's two scopes; a project never depends on the user
  store for anything but fallback resolution of `global` definitions, a
  project directory stays self-contained for `--session-store` isolation
  and for copying between machines, and a `global` workspace's
  definitions live with the user, as §4.2 already places them.

## 19. Open questions (with recommendations)

- Should a plain `workflow run` with no placement ever leave the local
  machine? Options: local by default; automatic placement only for tasks;
  automatic for every run. Recommendation: local by default for plain
  runs, automatic placement only when a task or an explicit
  `--placement auto` asks for it; this decides where workspace content and
  prompts may travel.
- One workspace binding per node in the first release, or several from
  the start? Recommendation: one; if several are required, commit now to
  binding ids, one designated cwd binding, per-binding policy roots, and
  binding-keyed pins (the `DefinitionPin` list already allows it).
- What happens to authored definitions on a schema-generation mismatch?
  Options: discard (today's rule); refuse to open; quarantine and require
  an explicit reset. §14 specifies quarantine; confirm.

- Several workspaces per node? Recommendation: yes (array), first is cwd.
- Refuse file-backed MCP secrets under `required`? Recommendation: allow,
  show the file lifetime in `policy render`.
- Ad-hoc workspace snapshots? Recommendation: only with `track`.
- Should package-installed workflows be forkable in place or only by
  `fork`? Recommendation: only by `fork`, so package heads stay
  reproducible and the lineage is explicit.

## 20. Existing features to align

Facts verified 2026-09-21 by a subsystem survey; each row names what the
feature references today, what changes, and the phase that owns it. No
compatibility shims anywhere: removed flags and files fail with the
replacement named.

| Feature | Today (evidence) | Change | Phase |
| --- | --- | --- | --- |
| Event bindings and `events serve` | `EventBindingContract.workflowName` is a bare string; scope and definition dir come from `events serve` flags and cwd (`EventContracts.swift:627-657`, `EventLiveServe.swift:705-722`); attachments are written under the event root as absolute paths and injected as `attachments` / `imagePaths` (`EventLiveServe.swift:560-577`) | `workflow: { name, scope?, version? }` plus optional `workspace`, `policy`, `model` overrides on the binding; `events serve` resolves through the store; inbound attachments land under the session store `artifacts/inbound/<sourceId>/…` and are exposed as the read-only `attachments` system mount, so Seatbelt and containers can read them and paths are inside a declared mount | E1, E3 |
| Routines | `RoutineRecord.workflowName`, `eventRoot` path, `.riela/routines` store (`RoutineStore.swift:13-153`) | Already folded into Work Runtime P3 as scheduled tasks; the task carries a `workspace` binding; `eventRoot` becomes the event source id | Work Runtime P3 |
| Specialist dispatch | Copies the bundle into `<stateRoot>/workflow-snapshots/<dispatchId>/` and launches with `--scope direct --workflow-definition-dir … --working-dir …` (`SpecialistCommands.swift:406-486, 647-651`) | Pins a definition version id; no directory copy; launches with `--version` and a workspace binding; the fold into `task serve` (Work Runtime P3) inherits this | E0, then P3 |
| Run configurations (workflow instances) | `instances.json` per scope root, `WorkflowInstanceConfiguration.workingDirectory`, node patches limited to `executionBackend`, `model`, `effort`, `kaibaInstanceId` by exact node id (`WorkflowInstanceModel.swift:95, 168-273`, `FileWorkflowInstanceStore.swift:18-34`); app daemon preferences mirror the same fields | Redesigned in §22: a `runConfiguration` definition kind with selector-based node overlays, layered resolution recorded per step, `riela config` and `workflow models`, `--model-for` flags, A/B compare; `workingDirectory` → `workspace` binding; the app daemon preference stores a run-configuration name | E0, E1, E7 |
| Package manager | Install copies a directory into `.riela/packages/<name>`, resolution is a scan for `riela-package.json` (`WorkflowResolution.swift:522-576`, `WorkflowPackageCommandRunner+Install.swift:208-275`); lockfile keyed by package name; skills projected into `~`/cwd vendor dirs (`WorkflowPackageSupport.swift:186-215`); `requiredEnvironment` checked by doctor and `node run` | Install = import of immutable heads (`origin: package`) for workflows, workspaces, policies, models, and add-on manifests; `.riela/packages` keeps only the archive cache and the lockfile; the catalog scan is deleted; `requiredEnvironment` is checked against Model profiles and the policy environment section; skill projection is user-scope only, project skills come from workspaces; native add-on digests unchanged | E0 |
| `extends` inheritance | Base resolved by `baseWorkflowId` through a user-scope-only directory probe (`WorkflowResolution.swift:275-346`, commit `0a9042e`); derived bundle computed at load | Base resolved through the store by `(workflow, name)` in the normal scope order or by a pinned version id; the derived workflow is a stored version with `parent` = the base version and `origin: derived(base)`, so lineage is explicit; a base update produces a `proposed` re-derivation instead of silent drift; `installedUserWorkflowName` and the hardcoded search roots are deleted | E0 |
| Cross-workflow transitions | Callee resolved with the caller's `(scope, definitionDir, workingDirectory)` then `scope: .auto` (`WorkflowCalleeResolution.swift:40-57`); nested request inherits the parent's memory root | Callee resolved through the store in the caller's scope chain; the callee runs in the caller's workspace instance unless its own workflow default binding names a different workspace, in which case it gets its own instance; recorded on the nested session's environment | E1, E2 |
| Session export and preserved history | Export renders executions; import requires equal `workflowId` and clears `backendWorkingDirectory` (`RuntimeHistoryImport.swift:29-60`); no definition digest or bundle in the archive | Export embeds the pinned definitions and their dependency closure (single-file form) and the resolved environment; preserved-history reuse keeps every existing check (workflow, variables, accepted-node payload, target input, communication) and extends the accepted-node digest to executable assets and the resolved environment definitions; `structure_digest` is discovery metadata only | E0 |
| Hooks | `riela hook` parses vendor payloads (`agentSessionId`, `cwd`, `transcriptPath`) and echoes them; nothing persists or joins them to sessions (`RielaHook.swift:9-48`, `ScopedParityCommands.swift:91-107`) | Hook events are persisted in `hook_events` and joined to executions by `backendSessionId` and by `cwd` falling under an instance root; the inactivity guard and typed conditions read them as liveness evidence | E6 |
| Riela memory root | `<workingDirectory>/.riela/memory/<memoryId>.sqlite`, cwd-relative default (`RielaMemory.swift:11-20`, `+Memory.swift:78-91`); workers force `<workspace>/.riela/memory` (`DistributedWorkerNodeExecutor.swift:104`) | Memory never lives inside a workspace instance (instances are transient); the root is the project store's `memory/` directory, delivered as the `RIELA_MEMORY_ROOT` system mount; the worker rule is deleted with `controllerPath` | E1, E6 |
| Kaiba and note add-ons | Instances by name and endpoint under `~/.riela/kaiba/instances.json`; local path inputs already rejected as legacy (`KaibaLegacyInputCompatibility.swift:12-34`) | Unchanged; `kaibaInstanceId` remains a run-configuration patch field. Optional later: move the instance list into the user definition store as a kind | none |
| `riela gc` | Sweeps `sessions/runtime-records/runtime-message-log.sqlite`, `workflow-history/`, `events/receipts/`, `artifacts/`, `logs/` (`RielaDataGarbageCollector.swift:186-221`) | Adds `workspaces/` (orphan instances, templates beyond `maxTemplates`), ephemeral versions with no live session, unreferenced blobs, and `hook_events` by age; drops `workflow-history/` | E2 |
| Mock scenarios and staged verification | Scenario path resolved against the run working directory (`ProductionNodeAdapter.swift:40-56`); staged verification copies the bundle to a staging root and discovers `mock-scenario*.json` by filename (`WorkflowStagedVerification.swift:57-110`) | Scenario files are blobs of the workflow version (`files/mock-scenario*.json`); `--mock-scenario <name>` selects a blob, `--mock-scenario <path>` imports one ad hoc; a scenario's `workingDirectory` field is removed; staged verification runs the version in an ephemeral instance instead of copying a directory | E0, E1 |
| Attachments and images | Paths harvested verbatim from merged variables and arguments (`AdapterUtilities.swift:33-50`) | Every path must fall inside a declared mount (instance, attachments, artifacts) or the step fails `policyBlocked`; the container renderer mounts only those | E3 |
| Workflow Studio and editor | `updateEditorNodeSettings` writes copy-on-write `editor-node-<sha256>.json` files into the mutable bundle (`WorkflowEditorNodeSettings.swift:25-59`); editable fields are `prompt` and `model` only; web run controls gate on an absolute directory string (`WorkflowRunControls.tsx:46-62`) | Editor updates go through `DefinitionWriter` and create versions; editable fields gain `policy`, `workspace`, `model` pickers; the run control selects a workspace or a run configuration; `InstancesView` loses the free-text path | E0, E7 (web rows `blocked` until the web package lands) |
| Server workflow manifest | Entries `{ id, workflowDirectory, cwd, autoImprove, defaultVariables }` with `RIELA_WORKFLOW_MANIFEST_ROOT` (`design-server-workflow-manifest.md:24-79`, `WorkflowServingContracts.swift:62-63`) | Entries `{ id, workflow: { name, scope, version? }, runConfiguration?, workspace?, policy?, model? }`; `workflowDirectory`, `cwd`, `autoImprove`, and the root variable are deleted; `manifest validate` resolves through the store | E1 |
| `workflow create`, `consolidate`, `self-improve`, `loop.selfEvolution.historyRoot`, directory transactions | Scaffold writes files under the scoped root (`ParityCommands.swift:234-257`); consolidate takes `--replacement <path>`; self-improve resolves a bundle by directory and writes audits and transactions under `historyRoot` (`WorkflowDirectoryTransaction.swift:155, 267`, `LoopEngineeringModels.swift:131-148`) | `create` writes a head through the writer (optionally `--export-to <dir>`); `consolidate --replacement <name | dir>`; self-improve writes `proposed` versions and the review gate accepts them; `historyRoot`, `WorkflowDirectoryTransaction`, and the audit/transaction directories are deleted | E0 |
| `riela node run` and the add-on catalog | Working directory from `--working-dir`; preflight scans package roots for manifests (`NodeCommandRunner.swift:106-299`); capability vocabulary `network.egress`, `filesystem.*`, `process.spawn`, `container.*`, `device.gpu`, `env.read`, `attachment.read` | `--workspace` / ad-hoc binding; preflight reads add-on manifests from the store; the vocabulary is kept as requirements matched against the effective policy (`capabilities` section); mounts derive from bindings | E1, E3 |
| `riela instance` CLI and the app daemon | `--cwd` plus a working-directory override; daemon argv `events serve --workflow-definition-dir … --working-directory … --artifact-root …` with `workflow.id` taken from the directory name (`DaemonWorkflowEventServeProcess.swift:109-144, 233`); candidate discovery scans `.riela/workflows` and `.riela/packages` | `--workspace` replaces both directory flags; the daemon launches `events serve --workflow <name>@<version> --scope … --workspace …`; workflow identity comes from the store; discovery lists heads | E1, E5 |
| Surface catalog rows | `workflow.validate|inspect|usage|run|register`, `session.rerun|resume|continue`, `serve.host`, and the console shared options declare `--workflow-definition-dir`, `--working-dir`, `--artifact-root`, `--scope` (`SurfaceCatalog+Rows.swift:34-232`, `+RowsCLI.swift:341`, `+RowsConsole.swift:346`) | Options become `--scope global|project|workspace:<name>|auto`, `--version`, `--workspace`, `--workspace-path`, `--policy`, `--model`, `--placement`; the three removed flags disappear from every row in the same task as the code | E7 |
| Agent-node output contract (`design-agent-node-output-contract.md`) | Makes `agentSandbox` mandatory at validation for sandbox-consuming backends | The requirement survives as "an agent node must resolve a policy"; the rest of that design (output contracts, retry, template errors) is untouched | E1 |
| Provider default credentials | `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` / `CURSOR_API_KEY` hardcoded in `ProductionNodeAdapter.swift:620-636`; `apiKeyEnvironment` requires `baseURL` (`WorkflowNodeValidation.swift:11-23`) | The hardcoded table becomes the `credential` of the implicitly created `default/<backend>` profile (§8); the validation rule is deleted with the fields | E4 |

## 21. Revisions after review (2026-09-21, Codex `gpt-6-astra`)

The review (kept under `tmp/astra-review/`, not committed) found the design
"not ready for implementation". Each finding below was checked against the
tree before being accepted; the section it changed is named.

| # | Finding (severity) | Verified | Change |
| --- | --- | --- | --- |
| 1 | Wiring `LocalProcess.swift:669` does not sandbox agent CLIs; they are spawned by the gateway's `POSIXGatewayProcessRunner` (blocker) | `AgentGatewayNodeAdapter.swift:41`, `GatewayExecution.swift:64-73, 128` | §2, §7: policy-aware `GatewayProcessRunning` injected into `ProductionGatewayExecutor`; tests on the production adapter |
| 2 | "Manager-authenticated" is not an authentication mechanism; `managerSessionId` is unverified (blocker) | `GraphQLSessionControlContracts.swift:46` | §10: verified host principal owning the store; surface `blocked` until E6 ships checks |
| 3 | Preserved-history reuse already checks variables, accepted node, target input, communication; `structure_digest` cannot replace them; sessions do not pin a bundle (major) | `DeterministicWorkflowRunner+History.swift:52-103`, `RuntimeSession.swift:325` | §2, §4.5, §20: fingerprint is discovery only; export embeds closure; history checks kept and extended |
| 4 | Detached worktrees break `riela/git-commit` (`symbolic-ref HEAD`) (major) | `ProductionNodeAdapter+GitCommit.swift:413` | §6.2, §17: instances on named branches `riela/<owner-id>` from `riela/template/<digest>` |
| 5 | Two stores versus "one transaction" promise; cross-store pins undefined (blocker) | `CLIWorkflowSessionStore.swift:147` | §3.1, §4.1: `DefinitionPin` closure snapshot into the session-owning store; no cross-db atomicity claimed |
| 6 | Schema cannot represent multiple workspaces/policies; missing kinds; ephemeral needs no name; node-level placement conflicts with step placement (major) | `WorkflowStepRef.swift:3` | §4.1, §5, §19: `DefinitionPin` list, kinds `runConfiguration`/`addon`, `name?`, placement stays on steps, one binding per node pending decision |
| 7 | "E2–E7 additive" is false; removals precede replacements; E0 depends on P1 for planner work (major) | `AgentGatewayNodeAdapter.swift:73, 601` | §15: removals move to the phase that ships the replacement; E2 after E3; P1 dependency named |
| 8 | Instance ownership per task generation versus Work Runtime per attempt; evidence enum closed; evidence needs a task (major) | `WorkModels.swift:82`, `WorkEvidence.swift:10` | §14: RielaCore-owned execution records, RielaWork projection; §6.2 ownership stated; Work Runtime §9 to be amended in P4 |
| 9 | Lifetime, proposal state, dedupe-reactivation, deactivated heads, `updatedAt` concurrency underspecified (blocker) | `WorkStore.swift:118` | §4.1, §4.3, §4.4: `latestVersion`, integer `revision`, explicit activation, retention graph, `DefinitionSubmission` |
| 10 | Canonicalization (NFC, whitespace) changes executable content; executable bit lost (major) | `WorkflowMutableRegistry.swift:246` | §4.4: string values byte-preserved, scripts/binaries untouched, `AssetRef.executable`, versioned digest framing, `fmt` explicit |
| 11 | No bridge from database to executable files during a run (major) | `WorkflowRegistryBundleLoader.swift:135, 205` | §6.2: read-only definition-assets mount with `+x` restored; typed asset references; `nodeRef` closure pinned |
| 12 | Warm template does not imply warm instance; snapshot engine takes exact paths (major) | `WorkflowFanoutChangeEvidence.swift:58` | §6.2, §6.3: template branch + produced paths; tracked-set contract with bounds; merge left to P4 |
| 13 | Policy intersection rules, environment section, reserved keys, `extraArguments` bypass, in-process labeling missing (blocker) | `AgentGatewayNodeAdapter.swift:99, 617`, `DistributedWorkerCommand.swift:20` | §7: invariants list |
| 14 | Literal versus profile ambiguity, default inheritance, concurrent creation, worker profile source, `command` trust by scope (major) | — | §8: deterministic rule, insert-if-absent, pinned profile on workers, `trusted` flag by explicit host action |
| 15 | Remote finalization needs a protocol, not a capability bit (major) | `DistributedWorkerNodeExecutor.swift:108`, `AdapterContracts.swift:244` | §9: workers never finalize; controller finalizes the returned change set |
| 16 | Example scope understated: 153 CLI-backend payloads, 149 without `agentSandbox` (major) | counted 2026-09-21 | plan E1/E3: workflow-level `policy` default for every example plus per-node overrides; production-path enforcement tests beside mock parity |
| 17 | Database becomes authoritative user data; discard-on-mismatch is wrong (major) | `SQLiteWorkflowRuntimePersistenceStore.swift:160-170` | §14, §19: quarantine + explicit reset |
| 18 | Three product questions (placement default, multi-workspace, mismatch handling) | — | §19 |

Not accepted: none. Deferred to Work Runtime P4: the joint branch/publication
specification (finding 8) and merge semantics (finding 12).

## 22. Run configurations and node overlays (model patching)

Requirements source: user direction 2026-09-21 — make it easy to patch each
node's model on a workflow and run it; the mechanism exists today but must
be redesigned for the SQLite-stored workflow.

### 22.1 Today

`WorkflowInstanceNodePatch { executionBackend, model, effort,
kaibaInstanceId }` keyed by exact node id (`WorkflowInstanceModel.swift:3-95`,
`supportedFields`), sourced from a scoped `instances.json`
(`FileWorkflowInstanceStore.swift:18-34`) or from `--node-patch <json>`
(`ParsedWorkflowOptions.swift:12`, `WorkflowRunCommand.swift:302, 384-402`).
`WorkflowInstanceResolver.resolve` mutates the payload dictionary in place
(`WorkflowInstanceResolver.swift:53-107`), throws on an unknown node id or a
`modelFreeze` conflict (`:147`), and names the result
`<instance>+overrides` (`:160`). Nothing records per node which source set
its model, there is no selector other than the exact id, no listing of the
effective model matrix, and the patch cannot name a policy or a profile.

### 22.2 Decisions

1. **Overlays never create workflow versions.** A model change is a run
   configuration change, not a workflow edit; the workflow version stays
   shared and search-visible, which is the anti-duplication rule of §4.5
   applied to models. Resolution is a layered view computed when a run is
   prepared: workflow version ⊕ run configuration version ⊕ command-line
   overlay → effective node payloads. The per-node effective payload digest
   is what `_rielaHistoryContract` hashes, so preserved history stays
   correct across overlays.
2. **A run configuration is a definition** (`DefinitionKind.runConfiguration`,
   §4.1): named, versioned, scoped, searchable, importable, exportable,
   subject to the same writer. It replaces `WorkflowInstanceDefinition`,
   `WorkflowInstanceConfiguration`, `instances.json`, and the app daemon
   preference fields (the preference stores a run configuration name).
3. **Selectors, not only ids.** An overlay targets `node(id)`, `step(id)`,
   `tag(name)` (node payload `tags: [String]`, new), `backend(<backend>)`,
   `nodeType(agent | addon)`, or `all`. Precedence is fixed and total:
   command line > run configuration > workflow, and within a layer node >
   step > tag > backend > nodeType > all. Two overlays of equal specificity
   setting the same field on one node are a validation error, so
   resolution is deterministic.
4. **Fields.** `model` (profile name or literal, §8), `executionBackend`,
   `effort`, `policy` (name or inline; intersected, never widened, §7),
   `kaibaInstanceId` (nullable, projected into the add-on config exactly as
   today's `applyKaibaInstancePatches`), and `agentEnvironment` (add-only
   bindings, reserved keys rejected). Nothing else: prompts, contracts,
   transitions, and workspaces are workflow or environment concerns.
5. **`modelFreeze` is authored intent and wins.** A frozen node ignores
   `model` and `executionBackend` overlays; the resolver records the skip
   as a `frozen` diagnostic on the effective matrix and `--strict-overlay`
   turns it into an error. No overlay flag can override a freeze.
6. **Every run records its matrix.** The session pins the run
   configuration version (a command-line overlay becomes an ephemeral
   `runConfiguration` version with `origin: cli`, no head, GC'd with the
   session); each step execution's `environment.model` carries
   `{ profile, model, backend, effort, source: workflow | config(name@v) |
   cli }`. `riela session show` and the run trace render the matrix.
7. **Validation at resolution, not at first failure.** Before the session
   is created the resolver checks every effective node: backend available
   on the target host (§5a), profile resolvable and backend-compatible
   (§8), policy intersection non-empty, `node`/`step` selectors naming
   existing targets (error) and `tag`/`backend` selectors matching at
   least one node (warning). `--dry-run` prints the matrix and stops.

### 22.3 Model

```swift
public struct RunConfiguration: Codable, Sendable {           // kind: runConfiguration
  public var name: String
  public var workflow: DefinitionRef?                          // { name, scope?, version? }; nil = usable with any workflow
  public var workspace: WorkspaceBinding?
  public var policy: PolicyRef?
  public var model: String?                                    // workflow-wide default profile; same as an `all` overlay on `model`
  public var environmentFile: String?                          // relative to the instance root
  public var environmentVariables: [String: String]
  public var defaultVariables: JSONObject
  public var overlays: [NodeOverlay]
}

public struct NodeOverlay: Codable, Sendable {
  public var select: OverlaySelector                           // node(id) | step(id) | tag(name) | backend(b) | nodeType(t) | all
  public var set: OverlayFields                                // model?, executionBackend?, effort?, policy?, kaibaInstanceId? (null clears), agentEnvironment?
  public var note: String?
}

public struct EffectiveNodeModel: Codable, Sendable {         // on WorkflowStepExecution.environment.model and in the matrix
  public var nodeId: String; public var stepId: String?
  public var backend: NodeExecutionBackend; public var model: String; public var profile: String?
  public var effort: NodeReasoningEffort?; public var policy: String?
  public var source: OverlaySource                             // workflow | config(name, versionId) | cli
  public var diagnostics: [String]                             // e.g. "frozen: model overlay skipped"
}
```

### 22.4 Surfaces

- `riela workflow run <wf> [--config <name>[@<version>]] [--model <profile>]
  [--model-for <selector>=<profile>] [--backend-for <selector>=<backend>]
  [--effort-for <selector>=<effort>] [--policy-for <selector>=<policy>]
  [--overlay-json <file|json|->] [--dry-run] [--strict-overlay]`.
  Selector syntax: `node:<id>`, `step:<id>`, `tag:<name>`,
  `backend:<backend>`, `type:agent|addon`, `all`. Repeated flags compose;
  the whole command line is one ephemeral run configuration version.
- `riela workflow models <wf> [--config <name>] [--output table|json]`:
  the effective matrix (node, step, backend, model, profile, effort,
  policy, source, diagnostics) without running.
- `riela config list|show|create|update|diff|delete|import|export`,
  `riela config create <name> --from-session <id>` (persist the effective
  overlay of a run that worked), `riela config compare <a> <b> --workflow
  <wf>` (sessions and tasks that ran each, success rate, tokens, wall
  clock, from the runtime records) for A/B between model matrices.
- GraphQL: `runConfigurations`, `runConfiguration`, `effectiveNodeModels
  (workflow:, config:, overlay:)`, `upsertRunConfiguration`,
  `compareRunConfigurations`; sessions expose `pins` and the matrix.
- Studio: a matrix editor over `effectiveNodeModels` with per-cell source
  badges, "save as run configuration", and "run with this matrix"; declared
  `blocked` until the web package lands.
- Work Runtime: `TaskPlan` gains `runConfiguration: DefinitionRef?`; a
  director's model-only improvement is `proposeRunConfigurationChange`
  (a `proposed` run-configuration version), cheaper than a workflow
  proposal and visible in `config compare`; the planner may pick the
  best-performing configuration from usage statistics.
- Search: `workflow find` and `search` results list the run configurations
  a head has run with and their success rates, so "use workflow X with the
  Opus review matrix" is one selection.

### 22.5 What this replaces

`WorkflowInstanceDefinition`, `WorkflowInstanceConfiguration`,
`WorkflowInstanceNodePatch`, `WorkflowInstanceResolver` (payload mutation,
`+overrides` identity), `FileWorkflowInstanceStore` and `instances.json`,
`--node-patch`, `riela instance` as a separate family (its always-on daemon
semantics move to the app preference referencing a run configuration; the
CLI family becomes `riela config`), the `InstancesView` free-text fields.
Kaiba instance ids stay a field; `modelFreeze` stays a node field.
