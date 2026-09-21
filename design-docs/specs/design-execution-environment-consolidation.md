# Execution environment consolidation: definition store, Workspace, Policy, Model, Placement, and the runner contract

Status: proposed 2026-09-21, zero-based. No backward compatibility: removed
fields, flags, directories, and files are gone, validation rejects them, and
no example, package, or store is migrated. Plan:
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
  (`WorkflowRegistryBundleLoader.swift:47-66`). Runs pin a bundle digest in
  the session snapshot.
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
  `--permission-mode` only.
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
   and accepting a definition are row operations in one transaction with
   the sessions and tasks that reference them. A directory bundle, a
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
public enum DefinitionKind: String { case workflow, workspace, policy, model }

public struct DefinitionVersion: Codable, Sendable {
  public var id: DefinitionVersionID                 // "defv-<uuid>"
  public var kind: DefinitionKind
  public var name: String                            // unique per (scope, kind)
  public var scope: DefinitionScope                  // global | project | workspace(name) — see §4.2
  public var digest: String                          // sha256 over the canonical document tree
  public var document: JSONObject                    // workflow.json / workspace / policy / model body
  public var files: [String: BlobRef]                // relative path → blob digest (node payloads, prompts, scripts, containerfiles)
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
  public var mutable: Bool                           // false for package-installed heads
  public var updatedAt: Date
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
- **Update** creates a version with `parent = active`; **activate** moves
  the head; **rollback** is activate to an older version; **history** lists
  the chain; **diff** compares two versions' documents and files;
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
   from an agent that fails validation is recorded as a `rejected` version
   with the diagnostics so the ledger shows why, and never becomes a head.
3. **Normalize.** JSON documents are re-serialized canonically: keys
   sorted, no insignificant whitespace, numbers in shortest round-trip
   form, strings NFC-normalized, no comments, no trailing commas, one
   trailing LF. Fields equal to their documented default are dropped
   (for example `modelFreeze: false`, empty `variables`, empty
   `agentEnvironment`), so two authors writing the same workflow produce
   the same bytes. Text blobs (prompts, scripts, markdown) get LF line
   endings, trailing whitespace stripped per line, a single trailing
   newline, BOM removed, NFC. Binary blobs (images, containerfiles
   declared binary) are stored as-is. `export` writes the canonical form
   pretty-printed with two-space indentation for humans; the digest is
   always computed over the canonical compact form, so exporting and
   re-importing is a no-op version-wise.
4. **Digest and dedupe.** `digest = sha256(kind ∥ canonical document ∥
   sorted (path, blob digest) pairs)`. A write whose digest equals the
   head's active version creates no row and reports `unchanged`; a write
   whose digest equals an older version in the same head re-activates that
   version instead of duplicating it (recorded as `rollback`). Blobs are
   written by digest before the version row, in one transaction.

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
  evidence, and `new` is rejected by the writer when a hit is above the
  similarity threshold unless the reason names a concrete difference the
  fork mechanism cannot express;
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

public struct ResolvedExecutionEnvironment: Codable, Sendable {   // on WorkflowStepExecution and Attempt; written to the metadata file
  public var definitions: [DefinitionKind: DefinitionVersionID]
  public var workspace: WorkspaceInstanceRef
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
- added: `workspace: WorkspaceBinding | [WorkspaceBinding]` (first = cwd
  root), `cwd: String?` (relative), `policy: String | ExecutionPolicy`,
  `placement: PlacementRequest?`;
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

Instances: `git worktree add --detach` per repository, `files/` cloned
copy-on-write (`copyfile(3)` `COPYFILE_CLONE`, `FICLONE`, plain copy
fallback; method recorded), verify-on-first-use with in-place fallback.
Owner ids: session id; `<taskId>-g<generation>` shared by every attempt of
a generation (rerun and recover continue on the edited tree; replan bumps
it); fanout branch execution id. Removal on owner completion unless
`keep`; task instances on terminal state or supersession; `riela workspace
gc` and `riela gc` enforce `maxTemplates` and reconcile orphans. The ad-hoc
local workspace is `method: adHoc`, no template, never removed.

### 6.3 Isolation and change evidence

`shared`: one instance per owner tree. `isolated`: one per branch or task
generation, merged by the join step or `ChangeRuntime`. For every instance
the runtime snapshots `track` paths (or the whole tree when `track` is
empty and the tree is under the existing 64 MB bound) at creation and
after each execution; diffs are `changedFile` evidence, feed the fanout
conflict check, and are the base P4 finalizes from. The ad-hoc workspace
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
| `filesystem.write` | SBPL writable subpaths = instance root (+`extraWrite`), artifact root, temp; wired at `LocalProcess.swift:669` | `--sandbox` mapping (`advisory`) | RW bind mounts only for bindings and `extraWrite`; `--read-only`, `--tmpfs /tmp` | rendered locally |
| `network` | `(deny network*)` + loopback allow for the per-session enforcement point (CONNECT proxy, per-attempt bearer, allowlist by CONNECT authority, `egress` evidence); `HTTPS_PROXY` set | proxy env (`advisory`) | `--network none` for `deny`; internal network + proxy for allowlists where the driver allows, else `advisory` | worker-local enforcement point |
| `resources` | diagnostic only (no cgroups on macOS) | same | `--cpus`, `--memory`, `--pids-limit` | as local |
| `agent` | `--permission-mode`, `extraArguments[claude]` | `--sandbox`, `extraArguments[codex]` | n/a | forwarded |
| `capabilities` | add-on allow/deny; `finalization` gates `riela/git-commit|push` | same | same | replaces `allowedAddons` and the hard-coded denials |

`enforcement: off | auto | required` (default `auto`); `required` fails
loudly where a rendering would be `advisory`. Labels live on the resolved
environment record.

## 8. Model profiles

`credential.kind`: `env`, `file` (under
`${XDG_STATE_HOME:-~/.local/state}/riela/credentials`), `command` (user
scope only). Secrets are resolved at spawn, never persisted, never in
evidence or telemetry; the redactor gains `credential`. Workers resolve
profiles from their own store by name; the controller ships names.
When a node names a literal model and no `default/<backend>` head exists in
any visible scope, riela **creates** one: a `global` head in the user
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
`artifact` evidence and change snapshots. `controllerPath` is gone because
no authored path is absolute; `agentEnvironment` resolution stays on the
worker.

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
  recorded as `command` evidence with `producedBy: human`,
  manager-authenticated.

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
tables), `workspaces/` (templates, instances), `artifacts/`, `logs/`. The
runtime store schema generation is bumped once for the definition tables
and the new session fields; per repository convention, a mismatched store
is discarded. `.riela/` in a project keeps `sessions/`, `packages/`,
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
  every removal in §11 with replacement diagnostics, examples and skills
  rewritten, ad-hoc local workspace as the only runtime behavior. The
  second compatibility break; everything after is additive.
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

E0 and E1 are independent of Work Runtime P1; E2's task binding lands with
P4 and hands it the base tree; E3's ceilings serve P7.

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
- **Worktrees and agents that run git**: the instance repository path is a
  repository root, so `riela/git-commit|push` keep their rule.
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

- Several workspaces per node? Recommendation: yes (array), first is cwd.
- Refuse file-backed MCP secrets under `required`? Recommendation: allow,
  show the file lifetime in `policy render`.
- Ad-hoc workspace snapshots? Recommendation: only with `track`.
- Should package-installed workflows be forkable in place or only by
  `fork`? Recommendation: only by `fork`, so package heads stay
  reproducible and the lineage is explicit.
