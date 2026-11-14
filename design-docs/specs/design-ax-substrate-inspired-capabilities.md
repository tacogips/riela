# AX / Agent Substrate-Inspired Capabilities Intake

Status: proposed 2026-09-21. This is a review request: the adoption set
(A–H in §5), the declines (§7), and the priority order are the decisions to
confirm before any plan work starts. No implementation is proposed beyond
design; the companion plan would be
`impl-plans/active/ax-substrate-inspired-capabilities.md`.

Requirements source: user goal 2026-09-21 — "google/ax や agent-substrate の
機能のうち、riela に足りないもの、あるとより riela が improve すると思われる
機能を考え design-docs に作成せよ".

## 1. Summary

Google's **AX** (`github.com/google/ax`, "Google's open agentic orchestrator",
Apache-2.0, API group `ax.io/v1alpha1`; under active redesign with external
contributions paused as of September 2026) is a declarative, `kubectl`-shaped
control plane that runs autonomous agent workloads as sandboxed **Tasks** on
top of **Agent Substrate** (`github.com/agent-substrate/substrate`, "the core
system", self-described as early development and not production-ready).
Substrate is a Kubernetes-hosted runtime that multiplexes many mostly-idle
sandboxed **actors** onto fewer warm **workers** through sub-second
suspend/resume of gVisor or micro-VM snapshots, with identity-aware ingress
routing and a policy-enforced egress path.

Neither project is a workflow engine, and neither is a fit to adopt
wholesale: Riela runs coding agents deterministically on one machine or a
small set of HTTP-pull workers, not billions of actors in a cluster. What both
projects contribute is a small, well-argued set of *primitives around* an
agent process that Riela either does not have or has only as advisory data:

- a reusable, declarative **Workspace** (repos, MCP servers, skills, a
  natural-language bootstrap goal) that is materialized once, reported as a
  readiness condition, and cloned cheaply for every new task ("golden
  snapshot");
- a **Gateway**/egress policy that fences what a sandboxed agent may reach,
  and a **Model** resource that centralizes provider, model, parameters, and
  the credential reference so rotation is one edit;
- a **runner contract** between the control plane and the sandbox (metadata
  the agent can read without an SDK, readiness, keep-alive for inspection,
  `ax ssh`);
- **suspend/resume** of an idle agent as a first-class lifecycle verb, and
  (on Substrate's roadmap) **forking** an actor from a checkpoint to explore
  several reasoning paths;
- strict **failure-domain attribution** (`infrastructure` | `workload` |
  `unknown`) on every lifecycle signal, plus cardinality rules that keep
  per-actor identity in logs and never in metric labels;
- a written **threat model** with enumerated threats and invariants, and the
  fail-closed defaults that AX's own open issues show are easy to get wrong.

This document records the fact-checked mechanisms of both projects (§2–§3),
maps each onto Riela's current state with file evidence (§4), proposes eight
prioritized adoptions (§5), shows how they sit on the Work Runtime (§6),
records what is deliberately declined (§7), and lists risks and open
questions (§8). Everything proposed is expressed on Riela's existing seams:
workflow nodes, the Work Runtime's `Intent`/`WorkTask`/`Attempt` model
(`design-work-runtime-consolidation.md`, P0 implemented 2026-09-21), the
Seatbelt sandbox, container add-ons and the container runtime driver, the
distributed worker contract, the surface catalog, and the OTLP telemetry
exporter. Riela stays JSON-only (`design-workflow-json.md`); no YAML is
introduced.

## 2. Research basis

Read directly on 2026-09-21 from the `main` branches:

- `google/ax`: `README.md`, `DESIGN.md`, `docs/concepts.md`,
  `docs/manifests.md`, `docs/sandbox.md`, `docs/runner.md`,
  `docs/networking.md`, `demo.sh`, and the open issue list (#344–#355).
- `agent-substrate/substrate`: `README.md`, `docs/architecture.md` ("much of
  this architecture is aspirational, and is not yet implemented"),
  `docs/api-guide.md`, `docs/glossary.md`, `docs/authentication.md`,
  `docs/threat-model.md` (43 threats, last updated 2026-06-25),
  `docs/network-egress.md`, `docs/egress-trust-bundle.md`,
  `docs/request-parking.md`, `docs/csi-volumes.md`, `docs/observability.md`,
  `docs/roadmap.md`.

Confidence: the resource kinds, manifest fields, runner contract, CLI verbs,
actor state machine, egress contract, observability conventions, and the
threat list are documented verbatim and are treated as confirmed.
Substrate's north-star numbers (100 ms p95 activation, one billion actors,
1,000 wakeups per second) and several roadmap items are targets, not shipped
behavior, and are cited only as direction. Riela-side facts in §4 were read
from this tree on the same day (an inventory pass over `Sources/`,
`design-docs/specs/`, `impl-plans/`, `docs/`, with spot checks of every
load-bearing line); each row cites its evidence.

## 3. Feature inventory (concrete mechanisms)

### 3.1 AX

AX's problem statement: agents "accumulate state, need strict isolation, call
out to model APIs and tool servers, and can burn money in a loop if nobody is
watching." Four resources answer it, all `ax.io/v1alpha1` YAML, all applied
with `ax apply -f`, all scoped to an *atespace* (tenant).

1. **Task** — "the smallest unit of isolated execution": container `image`,
   `command`, `env`, `resources.requests/limits` (cpu, memory), one
   `gateway` reference, one or more `workspaces` bindings (each with a mount
   `path`; the first is the command's working directory), and `debug: true`
   to enable guest services. Lifecycle is `status.phase` (`Running`,
   `Suspended`, `Failed`, `Terminating`) plus typed **conditions**
   `WorkspaceReady`, `GatewayReady`, `Ready` ("the one to wait on"), each
   with a reason such as `TaskSuspended`. AX deliberately does *not* model
   the plan/delegate/retry shape of an agent: "A single task may be the
   whole job, or it may be the root of a large tree of tasks spawned as the
   agent breaks the problem down."
2. **Workspace** — "populates the filesystem and tool landscape": `git`
   repos cloned at a branch, `mcp.servers` (endpoints) and `mcp.registries`
   (provider + query), `skills.registries` and a `skills.path` where skills
   are materialized (`/.agents/skills` in the example). A binding may carry
   a `goal`, "a plain-language description of the environment the task
   needs"; on first boot the runner hands the goal to an agent (Antigravity,
   `GEMINI_API_KEY`, 10-minute default via `AX_BOOTSTRAP_TIMEOUT`) that
   finishes setup. Setup runs once, in binding order; completion is recorded
   under `/ax` so a resume never repeats it. Several workspaces compose at
   distinct paths.
3. **Gateway** — listeners the task exposes plus an **egress allowlist** of
   `hosts` (`host`, `port`): "restrict an agent to, say, your LLM provider
   and your Git host."
4. **Model** — "a `Model` is not a model. It is a named model
   configuration": `provider` (`google` | `anthropic`), `model`,
   `parameters` (temperature, maxTokens), `secretKey` (Kubernetes secret
   name + key). Rationale: "rotating a key, pinning a new model version, or
   tightening a parameter is one `ax apply` rather than a hunt through task
   definitions." AX's own components read it too (workspace planning).

Verbs: `apply`, `get`, `describe`, `watch` (server-streaming status and
condition transitions), `delete`, `suspend`, `resume`, `ssh` (interactive or
one-off command inside the sandbox; refuses unless `spec.debug`), `ctx`,
`tunnel`.

**Runner contract** (`docs/runner.md`, `docs/sandbox.md`): every task
container starts `/usr/local/bin/ax-task-runner` as PID 1 with `AX_TASK_YAML`
and `AX_WORKSPACES_YAML` in its environment. The runner must serve `/healthz`
(always 200) and `/readyz` (503 until every workspace is prepared) on port
80, optionally `/metadata/v1alpha1/ax/{task,workspaces}` so "your agent can
introspect its own configuration without any SDK" via `AX_METADATA_URL`;
prepare each workspace once and persist the marker; start `spec.command` in
its own process group in the first workspace; **stay up after the command
exits** so metadata and `ax ssh` keep working (the exit code is logged and
"isn't currently returned to the control plane"); on `SIGTERM` forward to the
process group, wait a bounded grace period (10 s), `SIGKILL`, flush state.
Three customization levels: extend the image, embed the Go `runner` package
with an `OnCommandExit` hook, or a from-scratch runner in any language.

**Architecture** (`DESIGN.md`): state in Redis rather than etcd ("millions of
short-lived tasks as CRDs pushes etcd past its comfort zone"); a stateless
gRPC `ax-server`; horizontally scaled `ax-controller` workers consuming Redis
Streams with `XREADGROUP`; Substrate underneath for atespace provisioning,
actor creation, worker assignment, and egress policy.

**Open issues worth learning from** (all open 2026-09-21): #346 a task
reports `Running`/`Ready=True` indefinitely after its command exited; #347 an
empty git clone still reports `WorkspaceReady`; #350 a missing referenced
gateway "grants wildcard egress and starts the task" (fail-open); #345
hostname allowlist entries block all TLS egress including the allowlisted
hosts; #348 no way to give a Task a secret (`EnvVar` has no `valueFrom`, no
`modelRef`); #353 spec edits provision a new template but leave the actor on
the old image; #351/#352 unacknowledged stream events lost on worker failure
and status writes racing spec edits; #344 request for configurable sandbox
runtimes. Each of these is a concrete fail-closed or consistency requirement
in §5.

### 3.2 Agent Substrate

Purpose: "a secure-by-default agent execution runtime engineered to run
millions of sandboxes with 10x higher density than standard container
runtimes." "It is not an SDK for building agents, but rather a system for
running them at scale."

1. **Actor / worker multiplexing.** Actors are instances of an immutable
   `ActorTemplate` (image, containers with optional HTTP `readyz` probes,
   `sandboxConfig` naming a class `gvisor` | `microvm`, `snapshotsConfig`,
   volumes, immutable `resources.limits` baked into snapshots). Workers are
   pre-started pods from a `WorkerPool` CRD; one worker hosts at most one
   actor at a time. State machine `SUSPENDED → RESUMING → RUNNING →
   SUSPENDING → SUSPENDED`, with `PAUSING/PAUSED` for a node-local
   checkpoint, and `CRASHED`. `sandboxClass` is "a hard scheduling gate"
   because a snapshot is not restorable across runtimes.
2. **Golden snapshot.** Creating a template boots a temporary actor, waits
   for readiness, suspends it, and publishes a tag; every new actor resumes
   from it. Best practice: "place expensive initialization ... in your
   application's entry point. These will be captured in the Golden Snapshot
   and won't need to be repeated on every resumption." Snapshot scopes are
   `Full` (memory + rootfs delta + `DurableDir`) or `Data` (`DurableDir`
   only); resume sources are `ColdBoot` or `Golden`. Every snapshot has
   exactly one owner (actor or tag) and a deterministic object-store path;
   the runtime config is "pinned into each snapshot's manifest so restores
   stay reproducible across runtime upgrades."
3. **Identity and routing.** Each actor has a Substrate-managed identity
   independent of hardware; ingress is `ate-target-actor: <atespace>/<actor>`
   through an Envoy `ext_proc` router that resumes the actor on demand and
   tunnels to the worker over mTLS. Per-actor metadata is delivered as
   **files on a read-only bind mount, not environment variables**,
   "precisely so they carry the correct values after a resume from a shared
   snapshot."
4. **Egress contract** (`network-egress.md`). All outbound actor TCP is
   redirected by nftables into `atunnel`, which opens an mTLS HTTP `CONNECT`
   to a policy enforcement point (PEP) presenting a short-lived actor
   certificate. The PEP treats "everything originating from the actor [as]
   untrusted": hostnames and SNI are hints, never authorization; CIDR and
   allowlist policies dial immediately, hostname policies inspect the inner
   request; the PEP may pass through, inspect, redirect, or MITM. DNS on
   port 53 bypasses the PEP. Roadmap: "credential injection via proxies",
   L7-aware filtering.
5. **Request parking** (`request-parking.md`). When worker pools are
   saturated, the router holds requests for suspended actors in a bounded
   lot (default 1024) with exponential backoff and a per-resume budget
   (default 5 s), de-duplicating concurrent requests for the same actor;
   "the budget bounds retries, not a committed resume."
6. **Observability** (`observability.md`). One attribute vocabulary
   (`ate.actor.name/uid`, `ate.atespace`, `ate.template.name`,
   `ate.actor.container.name`) shared by logs, traces, metrics, and lifecycle
   events. Rule: "High-cardinality actor identity ... never appears in
   metric labels — this is enforced." Lifecycle records ("Actor state
   changed", "Actor crashed", "Restore timing breakdown") are "never
   sample[d]" because consumers read the last event per actor. Per-actor
   usage samples (memory, cpu) are periodic log events, not metrics.
   `ate.failure.domain ∈ {infrastructure, workload, unknown}` "is a strict
   function of the reason" and accompanies every `ate.failure.reason`.
7. **Threat model** (`threat-model.md`). Components, trust boundaries, five
   threat-actor classes, 43 enumerated threats (16 critical, e.g. T-15
   sandbox escape, T-17 cross-actor communication, T-27 state leakage across
   actor reuse, T-28 credential mis-issuance) and invariants: mutual
   authentication and TLS everywhere, hardened sandboxes, default-deny
   network with allowlists, opt-in credential exposure "with proxy
   interposition", full policy sync before execution, complete state reset
   between reuses, audit logging.
8. **Roadmap items relevant here.** "Actor forking from checkpoints for
   agent reasoning paths"; multiple run modes (clean start, golden resume,
   persistent rootfs, full process resume); "stateful coding adapters for
   Claude Code and CodeX"; credential injection via proxies; audit logging;
   OTLP export with actor/worker tagging.

## 4. Gap analysis vs Riela

Each row: AX/Substrate mechanism → Riela's current state (file evidence) →
verdict. IMPLEMENTED means in the Swift tree; DESIGNED means a design or plan
exists but the tree does not have it; ABSENT means not found.

### 4.1 Task: sandboxed unit with resource limits → PARTIAL (sandbox yes, limits ABSENT)

Riela's unit is a workflow node, not a container. Three isolation classes
exist: local agent CLIs under the Seatbelt sandbox
(`Sources/RielaAdapters/SeatbeltSandbox.swift`: `LocalProcessSandboxPolicy`
with `enforcement`, `writeScope`, `readPaths`, `networkAllowed`; applied at
the single spawn choke point `Sources/RielaAdapters/LocalProcess.swift:669`;
opt-in via `RIELA_SANDBOX_SEATBELT ∈ {off, auto, required}`), container
*add-ons* through `Sources/RielaCLI/ContainerRuntimeDriver.swift`
(`--read-only`, `--tmpfs /tmp`, `--network none`, Apple `container` adds
`--no-dns`), and container *nodes* (`NodeType.container`,
`Sources/RielaCore/WorkflowModel.swift:55`) whose payload
`WorkflowContainerExecution` (`WorkflowModel.swift:686`) carries only
`image`, `runnerKind`, `runnerPath`, `command`, `environment`,
`workingDirectory`, and a `build` fallback. **No `resources` field exists
anywhere**: no `--cpus`, `--memory`, or `--pids-limit` is ever passed, and
container nodes get no `--network` flag at all
(`Sources/RielaAdapters/WorkflowStdioNodeExecutor.swift`, which mounts only
the memory root). The Work Runtime's `WorkTask`/`Attempt` (`Sources/RielaWork/
WorkModels.swift`) is the closest declarative task object but models no
sandbox or placement. Verdict: adopt resource limits for the container
driver (F3); keep Seatbelt as the local class.

### 4.2 Workspace: declarative repos + MCP + skills + bootstrap goal → ABSENT (strongest gap)

Nothing in Riela provisions a working environment for a run. Git worktree
creation is declared and not built (`Sources/RielaWork/WorkContext.swift:7-8`:
"A git worktree per attempt. The runtime that creates it lands in P4."; the
`ChangeRuntime` protocol exists only as pseudocode in
`design-work-runtime-consolidation.md` §4). Repository cloning is an operator
step (`docs/distributed-workers.md`: "Provision the repository, executables
and agent credentials on each worker"). MCP server configuration is absent
from the workflow model (the only `mcp` mention in `Sources/` is the
agent-gateway adapter). Skills are installed at package-install time only
(`WorkflowPackageManifest.skills`, `Sources/RielaAddons/
WorkflowPackageManifest.swift`), never per run. The nearest reusable
"workspace" is the distributed worker's named directory in `worker.json`
(`{ path, controllerPath, allowedAddons, allowedEnvironment }`), bound by
`placement.workspace` (`Sources/RielaCore/DistributedPlacementValidation.swift`),
which is a pre-provisioned path, not a materialized environment. There is no
readiness marker, no bootstrap step, and no warm cache; every fan-out branch
or new attempt starts cold. Verdict: adopt (A), the highest-leverage item.

### 4.3 Gateway: egress allowlist → BOOLEAN ONLY

Two enforcement points, both all-or-nothing: container add-ons derive
`networkAllowed` from the `network.egress` capability
(`Sources/RielaCLI/ContainerWorkflowAddonResolver.swift:304-313`) and the
driver maps it to `--network none`; Seatbelt emits `(allow network*)` or
`(deny network*)` (`SeatbeltSandbox.swift`), and its design explicitly names
a localhost exemption as "a future extension". No host, port, or CIDR
allowlist exists, no proxy, no per-node network field, and container nodes
have no network policy at all. Verdict: adopt (C).

### 4.4 Model: named model configuration with a secret reference → INLINE ONLY

A node declares `executionBackend`, `model`, `modelFreeze`, `effort`,
`baseURL`, `apiKeyEnvironment`, `provider`, `providerProxy` inline
(`WorkflowModel.swift`, node payload). Credentials are env-var *names*
(`apiKeyEnvironment`, `AgentEnvironmentBinding.fromEnv`,
`Sources/RielaCore/AgentEnvironment.swift`), never references to a secret
store; workers allowlist which host variables a workspace may see
(`docs/distributed-workers.md`, `Sources/RielaCLI/DistributedWorkerCommand.swift`).
`design-open-model-provider-routing.md` is marked superseded by the
agent-gateway migration. The named, host-aware backend table is designed in
`design-work-runtime-consolidation.md` §5a (`BackendCapability`,
`backendPolicy`, `work_hosts`, `hostCapabilities(host:)`) and unimplemented.
Verdict: adopt (D) as the missing resource that §5a probes against.

### 4.5 suspend / resume / fork → STEP-LEVEL RESUME ONLY

`riela session resume` re-enters at `currentStepId`
(`Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`); `session
rerun` re-enters at a chosen step; neither restores agent state. There is no
pause or suspend verb, `WorkflowSessionStatus` is still
`created | running | completed | failed` (`Sources/RielaCore/RuntimeSession.swift:3`;
the `cancelled` status asked for by
`design-cancellation-and-orphan-session-resilience.md` is also not added),
and no process snapshot exists. The building block *is* present:
`WorkflowStepSessionPolicy { mode: new | reuse, inheritFromStepId }`
(`WorkflowModel.swift:480`) and the agent-gateway node adapter's session
store that maps a session key to the vendor session id and resumes it
(`Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:100-120`), following
`design-riela-52-codex-session-reuse.md` ("reuse means starting `codex exec
resume` against a known Codex thread"). Forking is absent. Verdict: adopt
(E) on the session-id seam, never as a process snapshot.

### 4.6 `ax ssh`, guest services, keep-alive after exit → ABSENT

No `exec`, `attach`, or interactive verb exists; containers run `--rm -i`
with stdio piping only (`ContainerRuntimeDriver.swift`). Human interaction is
`nodeType: user-action`, `session continue`, and `sendManagerMessage`.
Verdict: adopt a narrow, evidence-recorded `session exec` (F2).

### 4.7 Runner contract and self-introspection → ABSENT

An agent process learns nothing about its node beyond the prompt, variables,
`RIELA_MEMORY_ROOT`, and per-node `agentEnvironment`. There is no metadata
file or endpoint, no readiness contract for container nodes, and the
container node exit code is folded into the stdio result envelope. Riela
already delivers agent hook events through `Sources/RielaHook` (vendor
`claude-code | codex | gemini`, `agentSessionId`, `transcriptPath`), which is
the inverse direction. Verdict: adopt (F1) as a file contract.

### 4.8 `watch`, typed conditions, `apply` → PARTIAL

The surface catalog is implemented (`design-control-surface-parity.md`,
`Sources/RielaCore/SurfaceCatalog.swift`, 46 rows binding CLI, GraphQL, web
API, library, skills). `riela session progress --follow` is a polling
observer ("emits one text or JSONL digest per refresh", finite
`--poll-interval`); there is no GraphQL subscription or server push.
Session state is `status` + `failureKind` + `currentStepId` +
`SessionBackendActivityVerdict` (`Sources/RielaCore/SessionObservability.swift`);
there are no typed conditions with reasons. The only manifest verb is
`riela workflow manifest validate` (`design-server-workflow-manifest.md`);
declarative writes go through `registerMutableWorkflow` /
`updateMutableWorkflow`. Verdict: adopt (G) narrowly, for the new kinds and
Work Runtime objects only.

### 4.9 Failure-domain attribution → REASON CODES ONLY

`WorkflowSessionFailureKind` (`RuntimeSession.swift:17`) is an open string
type with `maxStepsExceeded`, `cancelled`, `adapterFailure`, `policyBlocked`,
`nodeTimeout`, `internal`, `loopNotConverging`, `budgetExceeded`;
`AdapterExecutionError` carries `code ∈ {provider_error, invalid_input,
policy_blocked, timeout, invalid_output}`, `isRetryable`, `retryAfter`
(`Sources/RielaCore/AdapterContracts.swift:3-15`); step executions carry a
free-text `failureReason`; distributed jobs add `Outcome.lost` for lease
expiry. No infrastructure-versus-workload axis exists, and
`design-work-runtime-consolidation.md` §5a records the consequence: a missing
or unauthenticated backend "surfaces as an `adapterFailure` on the first
attempt, which under the guard counts against the attempt budget." Verdict:
adopt (B), cheapest and most immediately useful.

### 4.10 Observability conventions → IMPLEMENTED, unaligned

`Sources/RielaObservability/RielaObservability.swift` is a self-contained
OTLP/HTTP exporter for traces, logs, and metrics with redaction. Runner
events attach `workflow.id`, `session.id`, `runtime.surface`, `step.id`,
`node.id`, `error_code` (`Sources/RielaCore/DeterministicWorkflowRunner+Events.swift:213-227`),
and emit `riela.workflow.start|step.start|backend.event|silence.warning|
loop.stall|loop.budget.exceeded` logs, `riela.workflow.step|run` spans, and
three counters. Token usage is on `WorkflowStepExecution.usage`
(`RuntimeSession.swift:242`) and persisted with the session; it is dropped
only on preserved-history import (`RuntimeHistoryImport.swift:61`) and on
persisted backend-event rows (`LoopEvidenceProjector.swift:12-15`). There is
no per-attempt usage sample signal, no unsampled lifecycle stream, no
attribute namespace rule, and no cardinality rule. Verdict: fold into (B).

### 4.11 Threat model → ABSENT

No `SECURITY.md`, threat model, or security review document exists under
`docs/` or `design-docs/`; security reasoning is scattered across feature
designs (Seatbelt R2, distributed credential fencing, "This path mapping is
not a process sandbox" in `docs/distributed-workers.md`). Verdict: adopt (H).

### 4.12 Multiplexing, request parking, golden memory snapshots, CSI, mTLS mesh → NOT APPLICABLE

Riela's capacity model is worker `capacity` permits, the specialist store's
`capacity_wait`, and the Work Runtime's `waiting(.capacity)`; a queue with a
bounded wait is already the design. Process-memory snapshots need gVisor or
a VMM and have no macOS equivalent. Declined in §7; the *ideas* (warm
template, idle release of a capacity lane, bounded parking budget) are
carried into A and E.

## 5. Proposed adoptions (prioritized)

Priority weighs fit to Riela's identity (deterministic, evidence-gated
orchestration of coding agents on local machines and a few workers), leverage
of seams that already exist, and cost. Every new operation is a surface
catalog row (`design-control-surface-parity.md`) before it is built, so CLI
and GraphQL ship together or declare `blocked`. All new documents are JSON.
All new references fail closed: a referenced resource that cannot be
resolved is a validation error at `workflow validate` and at dispatch, never
a silent fallback (AX #350).

### A. Workspace resource, materializer, and warm workspace cache *(P0)*

Superseded 2026-09-21, together with C, D, F, and G, by the zero-based
`design-docs/specs/design-execution-environment-consolidation.md` (plan:
`impl-plans/active/execution-environment-consolidation.md`), which also
moves workflow definitions from files into the database with history.
Where the two differ, the consolidation design wins; the summary below is
the intake-level shape and is kept for the rationale.

**Resource.** A `Workspace` document, project scope
`<workingDir>/.riela/workspaces/<name>.json` or user scope
`~/.riela/workspaces/<name>.json`, and optionally inline under a workflow
bundle's `workspaces/` directory:

```json
{
  "apiVersion": "riela/v1",
  "kind": "Workspace",
  "name": "riela-main",
  "git": [
    { "name": "riela", "repo": "https://github.com/tacogips/riela.git",
      "revision": "main", "path": "riela", "depth": 1 }
  ],
  "mcp": {
    "servers": [
      { "name": "wrike", "transport": "stdio",
        "command": ["wrike-gateway-reader", "mcp"],
        "environment": { "WRIKE_TOKEN": { "fromEnv": "RIELA_WRIKE_TOKEN" } } }
    ]
  },
  "skills": [
    { "source": "package", "name": "riela-workflow" },
    { "source": "path", "path": "./skills/repo-conventions" }
  ],
  "bootstrap": {
    "command": ["mise", "install"],
    "goal": "Build the release binary once so tests start from a warm cache",
    "backend": "codex-agent",
    "timeoutMs": 600000
  },
  "warm": { "enabled": true, "relocatable": true }
}
```

- `git[]`: cloned at `revision` (branch, tag, or sha) into `path` (default
  `<root>/<name>`); the first entry is the working directory. A clone is
  ready only when `HEAD` resolves and the tree is non-empty (AX #347).
- `mcp.servers[]`: a backend-neutral description. The materializer writes
  one canonical `<root>/.riela/mcp.json` and a per-backend projection
  through the agent-gateway adapter: for Claude Code a project `.mcp.json`;
  for Codex `-c mcp_servers.<name>...` overrides on the exec command; for a
  backend with no projection, a `WorkflowRuntimeCapabilityGap` diagnostic
  at validation, never silent omission. Secrets in `environment` use
  `AgentEnvironmentBinding` (`fromEnv`, `required`) and are resolved at
  spawn, never written into the projection files.
- `skills[]`: materialized into `<root>/.agents/skills/<name>` (the
  cross-agent convention AX also uses) with backend-specific links
  (`.claude/skills`, `.codex/skills`) created by the same projection step.
  Sources are installed packages (`WorkflowPackageManifest.skills`), local
  paths, or git; registries with provider queries are declined (§7).
- `bootstrap`: a deterministic `command` runs first; a `goal` runs second as
  a synthesized internal agent step (`riela/workspace-bootstrap`) on the
  named backend with `agentSandbox: workspace-write`, the workspace root as
  working directory, and the bootstrap timeout. Its transcript and exit are
  evidence. The readiness marker is written only when both succeed and a
  post-check passes (clone non-empty, projections present, bootstrap exit
  0). The agent used for the goal is whatever backend the user names; no
  provider is hard-wired.

**Materialization and readiness.** Prepared workspaces live under the
runtime store: `<runtime-store-root>/workspaces/<name>/<digest>/` where
`digest = sha256(canonical spec, resolved revisions, bootstrap goal,
materializer version)`. `prepared.json` in that directory is the readiness
marker (spec digest, resolved shas, projection list, bootstrap evidence ids,
timestamps); its presence is the `WorkspaceReady` condition (G). Preparation
is idempotent and runs once per digest; a resume or a second attempt never
repeats it.

**Warm cache (the golden-snapshot analog).** With `warm.enabled`, the
prepared directory is a template and every attempt receives an *instance*:
git repositories are attached as `git worktree add` from the template clone
(objects shared, working tree private), and non-git content (dependency
directories, build caches, virtualenvs) is copied with APFS `clonefile(2)`
on macOS and `copy_file_range`/reflink on Linux, falling back to a plain
copy. `relocatable: false` declares that the bootstrap output embeds absolute
paths and forces the bootstrap to rerun inside each instance instead of
cloning it. `riela workspace prepare <name>` pre-warms; `riela workspace gc`
removes templates no attempt references, with the same ownership rule
Substrate uses for snapshots: a template is owned by its digest, an instance
by its attempt, and deleting an attempt deletes only its instance.

**Binding.** Three binding points, one resolution rule:

- `workflow run --workspace <name>`: the run's working directory becomes the
  first git path of a fresh instance.
- Node payload `workspaces: [{ "name": "...", "path": "...", "goal": "..." }]`:
  per-node bindings, several allowed; for container nodes each binding is a
  bind mount at `path`; for local nodes each is a directory under the
  instance root. The first binding is the working directory.
- Work Runtime `RepositoryContext.workspace: WorkspaceRef?`: the repository
  context adapter's `prepare(attempt:)` materializes the instance and
  returns it as the `IsolationRef`; `discard` removes it. This is how P4's
  `GitWorktreeChangeRuntime` gets its base clone.

Agents learn the bound paths from the node metadata file (F1) and from
`RIELA_WORKSPACE_ROOT`.

**Surfaces.** `riela workspace list|show|validate|prepare|gc`, GraphQL
`workspaces`, `workspace`, `prepareWorkspace`, `gcWorkspaces`; a workspace
picker in Workflow Studio's node settings; the run trace shows the
`workspace` evidence (template digest, instance path, clone method, timing).

### B. Failure-domain attribution, infrastructure-aware guard, telemetry conventions *(P0)*

**Domain.** `FailureDomain: infrastructure | workload | unknown` becomes a
strict, tested function of the structured failure, never a free choice:

| Source | Domain |
| --- | --- |
| `adapterFailure` with `provider_error` and `isRetryable == true` or `retryAfter` set (rate limit, 5xx, network) | infrastructure |
| `adapterFailure` from backend absent or unauthenticated (§5a probe result) | infrastructure |
| distributed `Outcome.lost` (lease expired), worker unreachable, container runtime missing | infrastructure |
| `internal` (runner bug) | infrastructure |
| `policyBlocked`, `invalid_input`, `invalid_output`, `loopNotConverging`, `maxStepsExceeded`, `budgetExceeded` | workload |
| `nodeTimeout` | unknown (the reason string is kept; a director may reclassify) |
| `cancelled` | none (not a failure) |

Step executions gain a structured `failureCode` next to the free-text
`failureReason`; the domain is derived from the code and recorded on
`WorkflowSession`, `AttemptOutcome`, `SessionProgressDigest`, and GraphQL.

**Guard.** `BudgetGuard.maxAttempts` counts only workload-domain attempts.
Infrastructure failures take a bounded retry path in the deterministic
director (`retryAfter` honored, exponential backoff, `maxInfrastructureRetries`
default 3), each retry a `Decision` with the failure evidence as `causedBy`.
This removes the flaw §5a already names before Work Runtime P1 bakes it in.

**Telemetry conventions** (from Substrate `observability.md`):

- one attribute vocabulary on every signal: `riela.workflow.id`,
  `riela.session.id`, `riela.root_session.id`, `riela.step.id`,
  `riela.execution.id`, `riela.task.id`, `riela.attempt.id`,
  `riela.host.id`, `riela.backend`, `riela.model`, `riela.failure.reason`,
  `riela.failure.domain`; today's unprefixed `workflow.id` / `session.id`
  keys are renamed (no back-compat, per repo convention);
- **metric labels are bounded**: workflow id, backend, model, status,
  failure domain and reason; session, attempt, task, and execution ids never
  appear on a metric; per-attempt cost goes to a log event
  `riela.attempt.usage` (tokens, cache tokens, wall clock, cost when known)
  at each step boundary, which is also where the `costs` field of
  `AttemptOutcome` is fed;
- lifecycle records (`riela.session.state`, `riela.attempt.state`,
  `riela.task.state`, one per transition, carrying the failure pair) are
  flagged `unsampled` and are dropped last by the exporter's bounded buffer,
  because a consumer reads the last event per id.

### C. Egress policy and a local policy enforcement point *(P1)*

**Resource.**

```json
{
  "apiVersion": "riela/v1",
  "kind": "EgressPolicy",
  "name": "coding-default",
  "allow": [
    { "host": "api.anthropic.com", "ports": [443] },
    { "host": "api.openai.com", "ports": [443] },
    { "host": "*.github.com", "ports": [443, 22] },
    { "host": "github.com", "ports": [443, 22] }
  ],
  "allowLocalhost": true,
  "onDenied": "record"
}
```

`host` is an exact name or a single leading `*.` suffix pattern; a bare `"*"`
is the only wildcard and must be written explicitly. `onDenied` is `record`
(deny, write evidence, continue) or `fail` (deny and fail the step with
`policyBlocked`). Referencing a missing policy is a validation error;
absence of any `egress` field keeps today's behavior (unrestricted), which is
recorded on the attempt as `egress: unrestricted` so the gap is visible.

**Enforcement point.** A per-session loopback HTTP `CONNECT` proxy in
`RielaAdapters` (`EgressEnforcementPoint`), random port, requiring a
per-attempt bearer in `Proxy-Authorization` so an unrelated local process
cannot ride it (Substrate's client-authorization rule at Riela scale). It
authorizes by the CONNECT authority against the policy, never by SNI or
`Host` inside the tunnel, dials on allow, returns 403 on deny, and writes
one `egress` evidence record per distinct (host, port, verdict) with counts.
It never terminates TLS in this phase.

**Attachment per isolation class.**

| Class | Mechanism | Evidence label |
| --- | --- | --- |
| Local CLI under Seatbelt (Claude Code, Cursor) | `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` → the PEP, empty `NO_PROXY`; SBPL `(deny network*)` plus `(allow network-outbound (remote ip "localhost:<port>"))`, the localhost exemption the Seatbelt design deferred | `enforced` |
| Codex (own Seatbelt, no nesting) | proxy environment only | `advisory` |
| Container add-ons and nodes | driver-specific: an internal network whose only reachable endpoint is the host-side PEP (`host.docker.internal` / Apple container host gateway) plus the proxy environment; where the driver cannot isolate, `required` fails loudly and `auto` records `advisory` | `enforced` / `advisory` |
| Distributed worker | the worker runs its own PEP; the policy travels with the job; a worker that cannot enforce a `required` policy declines the job with an infrastructure-domain reason | `enforced` |

`enforcement ∈ {off, auto, required}` follows the existing tri-state
convention (`RIELA_SANDBOX_SEATBELT`, `RIELA_HOOK_RECORDING`). The evidence
label is never inferred: an `advisory` attachment is what it says.

**Intent ceiling.** `IntentConstraints.egress` (Work Runtime P7 capability
ceilings) names a policy that every node in the intent's tasks is intersected
with; a node may narrow, never widen.

**C2 (later): credential injection through the model proxy.** The node
payload's existing `providerProxy`/`baseURL` seam allows a Riela-owned
loopback reverse proxy for the model API: the agent receives
`baseURL=http://127.0.0.1:<port>` and a placeholder key; the proxy adds the
real credential from the `Model` resource (D) and forwards over TLS. This is
Substrate's "credential injection via proxies" for the one endpoint that
matters, without MITM. Deferred until D ships and the PEP has run in `auto`
for a release.

### D. `Model` resource with credential sources *(P1)*

**Resource.**

```json
{
  "apiVersion": "riela/v1",
  "kind": "Model",
  "name": "opus-review",
  "backend": "claude-code-agent",
  "model": "claude-opus-5",
  "parameters": { "effort": "high" },
  "credential": { "kind": "env", "name": "ANTHROPIC_API_KEY" },
  "baseURL": null,
  "providerProxy": null
}
```

`credential.kind` is `env` (host variable name), `file` (a path under
`${XDG_STATE_HOME:-~/.local/state}/riela/credentials`, following the gateway
credential-directory convention), or `command` (an executable that prints
the secret, for `kinko`, `op`, or `pass`). `command` credentials are honored
only from user scope, never from a project bundle or an installed package,
because a bundle must not be able to run arbitrary commands on the host at
resolution time. Secrets are resolved at spawn and reach the agent the way
they do today (`apiKeyEnvironment`, per-call environment); they are never
written to disk, projections, evidence, or telemetry, and the existing
`RielaTelemetryRedactor` key pattern gains `credential`.

**Node reference.** `modelRef: "<name>"` on the node payload, mutually
exclusive with inline `model`, `apiKeyEnvironment`, `baseURL`,
`providerProxy`; `executionBackend` may be omitted when the profile fixes it.
`modelFreeze` keeps its meaning. Resolution order is worker `worker.json
.models` (worker-side names only; the controller ships the *name*, never
the secret, extending "never distribute controller environment wholesale"),
then project scope, then user scope; an unresolved name is a validation
error, and `riela doctor` lists which profiles resolve on this host.

**Feeds placement.** §5a's `BackendCapability.models` is cross-checked
against `Model` records; the `placement` evidence records the profile name
and the resolved model id.

**Surfaces.** `riela model list|show|validate`, GraphQL `models`, `model`;
Workflow Studio's node settings gain a profile picker next to the backend
picker §5a already plans. Rotation is one file edit; a running attempt uses
the new value at its next spawn.

### E. Attempt suspend, resume, and fork on the agent-session seam *(P1, fork P2)*

Riela cannot snapshot a process and should not try (§7). What it can
checkpoint is what its adapters already track: the vendor session id per
step, the worktree, and the evidence ledger.

- **Status.** `WorkflowSessionStatus` gains `suspended` and the long-pending
  `cancelled`; `AttemptState` gains `suspended`; `DecisionKind` gains
  `suspend(reason)`, `resume`, `fork(count, fromStepId)`.
- **Suspend.** `riela session suspend <id>` / `suspendSession` mutation
  (manager-authenticated). Cooperative by default: the runner stops at the
  next step boundary; `--now` sends `SIGTERM` to the agent process group,
  waits a 10-second grace (AX's runner value), then `SIGKILL`. A
  `SuspendRecord` is persisted: `stepId`, `backendSessionId` per reusable
  step, `IsolationRef` with `HEAD` and a dirty-file digest, reason, time.
  Worker capacity and concurrency leases are released.
- **Resume.** The existing `session resume` path, when a suspend record is
  present, re-enters the recorded step with `sessionPolicy.mode = reuse`
  against the recorded vendor session through the agent-gateway session
  store, so the agent continues its own conversation. If the vendor session
  cannot be loaded, the step restarts fresh and a `resume-degraded` evidence
  record says so (the fail-open rule of the Codex session-reuse design).
- **Idle release.** A task in `waiting(.clarification | .human)` or
  `needsDecision` suspends its live attempt after
  `GuardPolicy.idleSuspendMs` (JSON key `guard.idleSuspendMs`, default off)
  and resumes on the human decision. This is Substrate's
  idle-actor release at Riela's scale: a worker's capacity lane is not held
  by an agent waiting for a person. The wait is bounded by the task's
  budget, not by a parking lot.
- **Fork (P2).** `riela session fork <id> --from-step <step> --count N`
  creates N sibling tasks under the same parent, each with an instance
  cloned from the parent's isolation (A's clone path) and a forked vendor
  session where the backend supports it (Claude Code `--resume <id>
  --fork-session`; Codex and Cursor to be verified, with the fallback of a
  fresh session seeded with the parent transcript summary). Siblings join
  through the existing fan-out join semantics and are compared by evidence;
  this is the "actor forking from checkpoints for agent reasoning paths"
  roadmap item expressed as sibling tasks.

### F. Node metadata contract, `session exec`, container runner, resource limits *(P2)*

**F1. Node metadata file.** For every node execution the runner writes
`<runtime-store>/<session>/<execution>/node-metadata.json` (workflow id,
session id, step id, execution id, task and attempt ids when present,
workspace bindings with resolved paths, egress policy name and enforcement
label, model profile name, isolation ref, evidence sink path) and exports
`RIELA_NODE_METADATA_PATH`; container nodes get it bind-mounted read-only at
`/riela/metadata/node.json`. A file, not environment variables, following
Substrate's reasoning and because a binding list does not fit a variable.
The file is the contract; a loopback `RIELA_METADATA_URL` with `/healthz`,
`/readyz`, `/metadata/v1/node` is optional and only in serve mode.

**F2. `riela session exec`.** `riela session exec <id> [--step <id>] --
<cmd>` runs a command in the attempt's working directory under the node's
sandbox policy (Seatbelt, or `exec` into a container node still alive under
`debug`), and records it as `command` evidence with `producedBy:
human(principal)`. It is a manager-authenticated GraphQL mutation
(`execInSession`) per the manager control-plane rules, a surface catalog
row, and never an SSH server or arbitrary TCP. The point is AX's "look over
the agent's shoulder" with an audit trail Riela's evidence model already
provides.

**F3. Container runner and limits.** `WorkflowContainerExecution` gains
`resources: { cpus, memory, pids }` mapped to `--cpus`, `--memory`,
`--pids-limit` on every driver, `network: { egress: <policy> }` (C), and
`debug: Bool`. A `runnerKind: "riela-runner"` mounts a static
`riela-node-runner` (linux amd64/arm64, produced by the existing
linux-release CI) as the entrypoint: it materializes bound workspaces,
writes the readiness marker, runs the command in its own process group,
forwards `SIGTERM` with a 10-second grace, **returns the exit code** in the
result envelope (AX #346), and under `debug` stays alive after exit until
`session exec` detaches or a TTL expires. Local agent processes get no
resource enforcement (macOS has no cgroups); the gap is recorded as a
diagnostic, not silently ignored.

### G. Uniform resource verbs and typed conditions *(P2)*

- `riela apply -f <file.json|dir>` accepts one document or an array of
  `{ "apiVersion": "riela/v1", "kind": ... }` documents for the kinds this
  design adds (`Workspace`, `EgressPolicy`, `Model`) and the Work Runtime's
  `Intent` and `Task`; `riela get|describe|delete <kind> [name]` mirror it.
  Workflows are excluded: the mutable registry already has CRUD, activation,
  and consolidation, and a second write path would fork it.
- `riela watch task|session <id>`: server-push over `riela serve` (SSE on
  the existing Swift HTTP server, emitting the same digest `session progress
  --follow` prints today, plus condition transitions) with `--follow` polling
  as the fallback when no server is running. No GraphQL subscriptions are
  introduced.
- Typed **conditions** on `SessionProgressDigest` and `Attempt`:
  `[{ type, status, reason, at }]` with `WorkspaceReady`, `EgressReady`,
  `BackendReady` (§5a probe), `IsolationReady`, `Suspended`, and `Ready`
  (= running and every prerequisite true). One concrete consumer: the
  inactivity guard reads `Ready` so workspace preparation and bootstrap
  time never count as a stall.

### H. Threat model document *(P1, documentation only)*

`design-docs/specs/riela-threat-model.md`, structured like Substrate's:

- **Components and trust boundaries**: CLI; `riela serve` (GraphQL, web,
  manager sessions, passkeys); event sources (chat gateways, webhooks, cron,
  file watchers); distributed controller and workers; agent CLIs running
  with the user's own credentials; add-ons (local, container, third-party
  resolvers); package registry and `.rielapkg` archives; Seatbelt and
  container runtimes; SQLite runtime, work, note, and kaiba stores.
- **Threat actors**: repository content and chat messages that prompt-inject
  the agent; a malicious package, add-on, or workflow bundle; a compromised
  worker; a network attacker on the controller or gateway endpoints; another
  local process; an operator mistake.
- **Enumerated threats** (seed list, ids `R-01…`): agent writes outside its
  workspace; agent exfiltrates through unrestricted egress; bundle-supplied
  `command` credential source; worker learns controller environment; worker
  claims another worker's job; evidence tampering; secret leakage through
  telemetry or evidence; stale policy at dispatch; state leakage across
  reused workspace instances; unauthenticated `session exec`; fail-open on a
  missing referenced resource.
- **Invariants**: fail closed on unresolved references; no wholesale
  environment distribution; per-worker credential fencing and incarnation
  tokens; secrets resolved at spawn and never persisted; evidence is
  append-only and every privileged action is evidence; every enforcement is
  labeled `enforced` or `advisory`, never inferred.
- Each threat maps to an existing control or to one of A–G.

## 6. How the adoptions fit the Work Runtime

| Adoption | Work Runtime seam (`design-work-runtime-consolidation.md`) | Phase to land after |
| --- | --- | --- |
| A Workspace | `RepositoryContext.workspace`; `WorkContextAdapter.prepare/discard`; `IsolationRef`; base clone for `GitWorktreeChangeRuntime` | P4 (repository context) — A can ship its resource, materializer, and `workflow run --workspace` before P4 and hand P4 the clone |
| B Failure domain | `AttemptOutcome.failureKind` + new domain; `BudgetGuard` counting rule; deterministic director retry table; `costs` fed from `riela.attempt.usage` | P1 (dispatcher, guard, director) — B should land *with* P1 |
| C Egress | `IntentConstraints.egress` ceiling; node field; `egress` evidence kind | P7 (capability ceilings) for the ceiling; node-level earlier |
| D Model | §5a `BackendCapability.models`, `placement` evidence, `hostCapabilities` | P1/P5 |
| E Suspend/fork | `AttemptState.suspended`; `DecisionKind.suspend/resume/fork`; sibling tasks for fork; idle release in the guard | P1 for suspend/resume, P4 for fork (needs isolation clone) |
| F Metadata/exec/runner | `Evidence(kind: command, producedBy: human)`; container node fields | P5 (surfaces) |
| G Verbs/conditions | surface catalog rows; `Attempt.conditions`; SSE watch | P5 |
| H Threat model | none (documentation) | any time; before C ships |

**Operating scenario.** A Monja work contract assigns a task to Riela. The
task's repository context names workspace `riela-main`; the dispatcher
finds a warm template for its digest, attaches a worktree instance in under a
second, and records `WorkspaceReady`. The node's `modelRef: opus-review`
resolves on the local host (probe says authenticated), the intent's egress
ceiling `coding-default` is attached `enforced` under Seatbelt with the PEP
on a random port, and `Ready` flips true. The attempt hits a rate limit; the
failure is `infrastructure`, the director retries after `retryAfter`, and the
attempt budget is untouched. The agent reaches a review gate that needs a
human; the task enters `needsDecision`, the attempt suspends after the idle
timeout, and the worker lane frees. The reviewer runs `riela session exec
… -- git diff --stat`, which is recorded as human-produced evidence, then
accepts in Monja; the attempt resumes on the same Codex thread, the
completion evaluator passes, and the worktree is finalized through the
existing finalization store. Every step above is a row in the ledger and a
lifecycle log event with `riela.task.id`.

## 7. Explicitly declined or deferred

- **Kubernetes control plane, Redis Streams, reconcile loop, atespaces.**
  Declined. Riela's controller is an embedded library with SQLite state and
  HTTP-pull workers (`design-distributed-workers.md`); its scale target is a
  person's machines, not a cluster. Multi-tenancy is out of scope.
- **Process-memory snapshots (gVisor, micro-VM, golden memory snapshot,
  `PAUSED` node-local checkpoints).** Declined. No macOS equivalent; the
  agent-session seam (E) gives the useful half at zero runtime cost. Only the
  *warm template* idea is adopted (A).
- **Actor multiplexing and request parking.** Declined as mechanisms;
  `waiting(.capacity)` and worker capacity permits already queue work. The
  idea of releasing a lane while idle is adopted (E, idle release).
- **Envoy router, `ate-target-actor` routing, mTLS mesh, `MintCert`/
  `MintJWT`, SPIFFE identities.** Declined. Per-worker bearer tokens,
  incarnation tokens, and job leases are adequate at Riela's scale; TLS is
  already required for non-loopback controllers.
- **CSI volumes, `DurableDir`, snapshot object storage.** Declined. The
  runtime store directory and git are Riela's durable state.
- **MCP and skill *registries* with provider queries.** Declined. Riela has
  its own package registry; `Workspace.skills` references packages, paths,
  or git, and `mcp.servers` are declared explicitly.
- **Antigravity/Gemini-bound bootstrap.** Replaced by a backend-neutral
  bootstrap step on any `NodeExecutionBackend`.
- **YAML manifests.** Declined; Riela is JSON-only.
- **`resources.requests`.** Declined; Substrate itself does not consult
  requests ("an actor occupies its whole worker"). Only `limits` are adopted,
  and only for the container driver (F3).
- **A general SSH or TTY into nodes.** Declined; `session exec` (F2) is a
  recorded, sandboxed, single-command surface.
- **Credential-injecting MITM proxy.** Deferred to C2 in its non-MITM form
  on the model endpoint only.

## 8. Risks and open questions

- **Proxy honoring by agent CLIs (C).** Claude Code documents `HTTPS_PROXY`;
  Codex (reqwest) and Cursor need verification, as does the interaction
  between the proxy environment and Codex's own sandbox. Verification item
  before C leaves `auto`; until then Codex is `advisory` by design.
- **Seatbelt localhost exemption (C).** The SBPL loopback rule must be
  proven not to reopen other local listeners; the profile test suite gains a
  "denied host still denied, PEP port still reachable" pair, and the AX #345
  regression ("allowlisted host still reachable") is a required test.
- **Warm cache correctness (A).** Dependency directories can embed absolute
  paths (`node_modules/.bin` shebangs, virtualenvs). `relocatable: false` is
  the escape hatch; the default `true` must be validated per bootstrap by a
  smoke command (`bootstrap.verify`) run inside the first instance.
  Open question: should Riela detect non-relocatable output automatically
  (scan for the template path in text files)? Recommendation: yes, as a
  warning that flips the default.
- **Fork semantics per backend (E).** Only Claude Code documents a session
  fork; Codex `exec resume` continues one thread. Fork ships behind a
  per-backend capability flag with the transcript-seeded fallback.
- **`session exec` and sandbox parity (F2).** An exec must never widen the
  node's sandbox; it runs under the same policy object the node ran under,
  and the evidence record carries the policy digest. Open question: allow
  exec on a *finished* local node whose worktree still exists? Recommendation:
  yes, read-only.
- **Failure-domain misclassification (B).** The mapping is a strict table
  with tests; anything unmapped is `unknown`, and `unknown` counts as
  workload for budgets (conservative). Open question: should a director be
  allowed to reclassify? Recommendation: yes, as a `Decision` with the reason.
- **Credential `command` sources (D).** Restricting them to user scope
  prevents a bundle from running commands, but a user-scope profile that a
  project references is still an attack surface if the project can choose
  the profile name. Recommendation: projects reference by name only; the
  user-scope profile decides its own `command`, and `riela doctor` prints
  every command-backed profile.
- **Scope pressure on Work Runtime P1–P7.** A and B are independent of P1
  except for the guard counting rule; C–G touch phases that are not started.
  Recommendation: land B with P1, A's resource and materializer in parallel
  with P1, and gate C–G on P4/P5 so the Work Runtime keeps its order.
- **Research confidence.** Substrate's architecture doc is explicitly
  aspirational and AX is being redesigned; the adopted ideas are the stable
  ones (resource split, runner contract, egress contract, failure domain,
  cardinality rules, threat model), not the scale machinery.
