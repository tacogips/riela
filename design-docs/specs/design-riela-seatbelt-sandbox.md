# Riela Seatbelt Sandbox for Local Process Execution

## Summary

Add macOS Seatbelt (`sandbox-exec` / SBPL profile) enforcement to
riela's sandbox mechanism for locally spawned processes — the path
that executes workflow-driven scripts and agent CLIs. Today
`agentSandbox` on a workflow node is *advisory*: it maps to
agent-specific trust flags (Claude Code permission modes, Codex
`--sandbox`, Cursor force modes) but riela itself enforces nothing at
the OS level. Container add-ons get real enforcement (capability-derived
mounts + network policy) but only when a container runtime is
installed; on Apple machines the local spawn path has no OS-level
sandbox at all.

This design introduces a platform-neutral `LocalProcessSandboxPolicy`
that travels with `LocalAgentProcessConfiguration`, an SBPL profile
generator, and Seatbelt application at the single `posix_spawn` choke
point in `FoundationLocalAgentProcessRunner`. On macOS the child
process is launched as `/usr/bin/sandbox-exec -p <profile> <exe>
<args…>`, deriving writable roots and network access from the node's
`agentSandbox` mode. On Linux (and when Seatbelt is unavailable) the
policy degrades according to an explicit enforcement mode
(`off` / `auto` / `required`).

Requirements source: user goal 2026-07-07 — "riela のsandbox機構
(script実行など) apple 環境でのSeatbeltを対応するようにする".

## Requirements (restated)

1. **R1 — Seatbelt enforcement on Apple**: when riela executes local
   processes on macOS (agent CLIs that run scripts on behalf of
   workflows), the existing sandbox policy (`agentSandbox`) can be
   enforced with a Seatbelt profile, not just forwarded as advisory
   agent flags.
2. **R2 — Policy fidelity**: `read-only` denies all filesystem writes
   (except process-required scratch such as `/dev/null`);
   `workspace-write` allows writes only under the node working
   directory, the artifact root, and temp dirs; `danger-full-access`
   applies no Seatbelt. Network egress is controllable independently.
3. **R3 — Explicit degradation**: environments without Seatbelt
   (Linux, missing `sandbox-exec`) must behave predictably: `auto`
   runs unsandboxed, `required` fails loudly (matching the repo's
   fail-loudly convention, cf. commit aa7d021).
4. **R4 — No behavior change by default**: existing workflows keep
   running exactly as today unless Seatbelt is opted into via
   environment/config. Codex's native Seatbelt (`--sandbox`) must not
   be double-wrapped.

## Code-Verified Current State

- **Single spawn choke point**: all agent processes launch via
  `posix_spawn` in `spawnProcess`
  (`Sources/RielaAdapters/LocalAgentProcess.swift:550-614`), called
  only by `FoundationLocalAgentProcessRunner`
  (`LocalAgentProcess.swift:629-…`), which implements
  `LocalAgentProcessRunning` (`:73-75`) and
  `LocalAgentProcessEventStreaming` (`:92-99`).
  `LocalAgentProcessConfiguration` (`:9-29`) carries
  `executableURL`, `arguments`, `environment`,
  `unsetEnvironmentKeys`, `workingDirectoryURL`; the env is the
  process env minus `unsetEnvironmentKeys` merged with
  `configuration.environment` (`:596-600`). Darwin conditionals are
  already established (`:543-548`, `:588-592`).
- **Runner injection**: adapters receive
  `runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner()`
  (e.g. `Sources/ClaudeCodeAgent/ClaudeCodeAgentAdapter.swift:96`,
  `Sources/RielaCLI/ContainerWorkflowAddonResolver.swift:24,30`).
  Command construction happens in `LocalAgentCommandBuilding.buildCommand`
  implementations that produce a `LocalAgentCommand` wrapping a
  `LocalAgentProcessConfiguration`.
- **Advisory sandbox mode**: `AgentSandboxMode`
  (`Sources/RielaCore/WorkflowModel.swift:66-70`, raw values
  `read-only` / `workspace-write` / `danger-full-access`) is a node
  field `agentSandbox` (`WorkflowModel.swift:790`). Consumers:
  - Claude: `claudePermissionMode(for:)` maps to `plan` /
    `acceptEdits` / `bypassPermissions`
    (`ClaudeCodeAgentAdapter.swift:81-92`) — purely advisory.
  - Codex: passes `sandbox: input.node.agentSandbox?.rawValue`
    (`Sources/CodexAgent/CodexAgentAdapter.swift:45`) — Codex applies
    its own Seatbelt internally on macOS.
- **Container sandbox (enforced, runtime-gated)**:
  `ContainerAddonSandboxPolicy`
  (`Sources/RielaCLI/ContainerWorkflowAddonResolver.swift:292-510`)
  derives `mounts` + `networkAllowed` from add-on capabilities
  (`network.egress`, `filesystem.read`/`filesystem.write` with scopes
  `addon.input` / `runtime.output` / `repo` / absolute paths;
  `env.read` allowlists HOME/PATH/TMPDIR at `:150`), validates input
  payload paths against mounts (`:407-429`), rejects mounting `/`
  (`:386-388`). Enforcement is delegated to podman/docker/Apple
  Container (`readOnlyRootFilesystem: true`, `:61`); with no runtime
  the resolver errors (`:100-103`).
- **Other direct `Process` launches** (not on the runner protocol):
  Apple Gateway bridge
  (`Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`),
  note-UI workflow providers
  (`Sources/RielaNoteUI/RielaNoteWorkflowLinkProposalProvider.swift`),
  daemon serve
  (`Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift`),
  package archive ops (`Sources/RielaAddons/WorkflowPackageArchive.swift`).
  These helpers need Apple-service (TCC) or infrastructure access and
  are out of scope (see Non-goals).
- **Env-mode convention**: tri-state env switches already exist, e.g.
  `RIELA_HOOK_RECORDING ∈ {auto, off, required}`
  (`Sources/RielaHook/HookContracts.swift:21-44`).
- **Tests**: process I/O behavior in
  `Tests/AgentAdapterTests/AgentAdapterProcessIOTests.swift`; container
  policy behavior in
  `Tests/RielaCLITests/ContainerWorkflowAddonResolverTests.swift`;
  style is dependency-injected fake runners
  (`runner: any LocalAgentProcessRunning`).

## Design Decisions

### D1 — Policy travels with the process configuration

Add to `Sources/RielaAdapters` a platform-neutral value type:

```swift
public struct LocalProcessSandboxPolicy: Equatable, Sendable {
  public enum Enforcement: String, Equatable, Sendable {
    case auto      // sandbox when available, run plain otherwise
    case required  // fail loudly when Seatbelt is unavailable
  }
  public enum FilesystemWriteScope: Equatable, Sendable {
    case readOnly                 // no writes beyond process scratch
    case paths([String])          // writable roots (absolute paths)
  }
  public var enforcement: Enforcement
  public var writeScope: FilesystemWriteScope
  public var readPaths: [String]?   // nil = allow all reads (default)
  public var networkAllowed: Bool
}
```

`LocalAgentProcessConfiguration` gains
`public var sandboxPolicy: LocalProcessSandboxPolicy?` (default `nil`
— an added init parameter with a default so all existing call sites
compile unchanged; `Equatable`/`Sendable` preserved). `nil` means "no
riela-level sandbox", exactly today's behavior (R4).

Rationale: the policy is per-invocation (working directory and mode
differ per node), and the configuration is the one value that reaches
the spawn choke point. A decorator runner was considered and rejected:
runners are constructed once per adapter and cannot see per-node
`agentSandbox`.

### D2 — Seatbelt application at the spawn choke point

In `FoundationLocalAgentProcessRunner.run`, before spawning, resolve
the effective invocation:

- **Darwin + policy present**: rewrite the invocation to
  `/usr/bin/sandbox-exec -p <profile> <original exe> <args…>` and
  spawn that. Implemented as a pure function
  `sandboxedInvocation(for: LocalAgentProcessConfiguration) throws ->
  LocalAgentProcessConfiguration` in a new
  `Sources/RielaAdapters/SeatbeltSandbox.swift` so it is unit-testable
  without spawning.
- **Darwin, `sandbox-exec` missing** (checked via
  `FileManager.isExecutableFile`): `auto` → spawn plain; `required` →
  throw `AdapterExecutionError(.policyBlocked, …)` naming the missing
  binary.
- **Non-Darwin**: `auto` → spawn plain; `required` → throw
  `AdapterExecutionError(.policyBlocked, …)` stating Seatbelt is
  Apple-only. Guarded with `#if canImport(Darwin)` following
  `LocalAgentProcess.swift:543-548`.

`sandbox-exec` is deprecated by Apple but remains the supported
mechanism used in practice (Codex CLI, Bazel, Chromium). The `-p
<inline profile>` form avoids temp-file lifecycle issues.

### D3 — SBPL profile generation

New pure generator in `SeatbeltSandbox.swift`:
`seatbeltProfile(for policy: LocalProcessSandboxPolicy,
workingDirectory: URL?, temporaryDirectory: URL) -> String`.

Base profile (deny-by-default with broad read, following the
industry-proven Codex CLI shape):

```
(version 1)
(deny default)
(allow process-fork)
(allow process-exec)
(allow signal (target same-sandbox))
(allow sysctl-read)
(allow mach-lookup)
(allow file-read*)                ; unless readPaths narrows it
(allow file-write-data (literal "/dev/null") (literal "/dev/dtracehelper"))
(allow file-ioctl (literal "/dev/dtracehelper"))
(allow file-read-metadata)
```

- `writeScope == .paths(roots)`: append `(allow file-write* (subpath
  "<root>") …)` for each canonicalized root, plus the resolved
  `TMPDIR`, `/private/tmp`, and Darwin per-user temp
  (`NSTemporaryDirectory()` resolved through symlinks — `/var` →
  `/private/var` canonicalization is mandatory or the allow rules
  silently miss).
- `writeScope == .readOnly`: no `file-write*` subpath allows (scratch
  literals above only).
- `networkAllowed == true`: append `(allow network*)`; otherwise
  append `(deny network*)` and keep `(allow network* (local ip
  "localhost:*"))` **out** — full deny; localhost exemption is a
  future extension.
- `readPaths != nil`: replace the broad `(allow file-read*)` with
  per-path subpath allows + `(allow file-read-metadata)`. Default is
  broad read (agent CLIs need system frameworks, node/python
  runtimes, git objects, etc.; read-narrowing is opt-in).
- All embedded paths escaped for SBPL string literals (`\` and `"`),
  and rejected if they contain newlines/control characters —
  `AdapterExecutionError(.policyBlocked, …)` (profile injection
  guard).
- Canonicalization detail: `URL.resolvingSymlinksInPath()` must NOT
  be used — on macOS it strips the `/private` prefix
  (`/private/tmp` → `/tmp`), the opposite of what the Seatbelt kernel
  evaluates. Paths are resolved with `realpath` on the longest
  existing ancestor (non-existent tails re-appended), yielding the
  physical `/private/...` form.

### D4 — Deriving policy from `agentSandbox`

New helper in `Sources/RielaAdapters` (usable by all agent CLIs):

```swift
public func localSandboxPolicy(
  for mode: AgentSandboxMode?,
  workingDirectory: URL?,
  artifactRoot: URL?,
  enforcement: LocalProcessSandboxPolicy.Enforcement
) -> LocalProcessSandboxPolicy?
```

- `read-only` → `writeScope: .readOnly`, `networkAllowed: true`
  (agents must reach their APIs; network restriction is orthogonal
  and container-capability-driven, not `agentSandbox`-driven).
- `workspace-write` → `writeScope: .paths([workingDirectory,
  artifactRoot, "~/.claude"-style agent state dirs are *not* included
  — see Risks])`, `networkAllowed: true`.
- `danger-full-access` or `nil` → returns `nil` (no sandbox).

Consumers: Claude and Cursor command builders attach the derived
policy to their `LocalAgentProcessConfiguration` when Seatbelt is
enabled (D5). **Codex is exempt** (R4): it already applies its own
Seatbelt from `--sandbox`; nesting `sandbox-exec` inside Seatbelt is
not reliably supported. The existing advisory flags (permission
modes, `--sandbox`) continue to be passed exactly as today.

### D5 — Opt-in configuration surface

Environment variable, following the `RIELA_HOOK_RECORDING` tri-state
convention (`HookContracts.swift:21-44`):

- `RIELA_SANDBOX_SEATBELT ∈ {off, auto, required}`, default `off`
  (R4). Parsed by a small `SeatbeltSandboxSettings` reader in
  `RielaAdapters`. Lookup order: the builder environment (adapter
  base env merged with the node's `agentEnvironment` — so workflows
  can opt in per node) first; when the key is absent there, the riela
  process environment (so `RIELA_SANDBOX_SEATBELT=auto riela workflow
  run …` works without threading the variable through
  `ProductionNodeAdapter` adapter construction).
- `off` → never attach policies (today's behavior).
- `auto` → attach derived policies; run plain where Seatbelt is
  unavailable.
- `required` → attach policies with `.required` enforcement; spawns
  fail loudly when Seatbelt is unavailable or the profile cannot be
  built.

Unknown values fail validation loudly (`AdapterExecutionError` at
first use) rather than being silently treated as `off`.

### D6 — Agent state directories under `read-only` / `workspace-write`

Agent CLIs write session state (e.g. `~/.claude`, `~/.codex`,
`~/.cursor`, caches). Under Seatbelt these writes fail and the agent
may abort. Decision: the derived policy for Claude/Cursor appends the
agent's known state directories as writable roots in **both**
`read-only` and `workspace-write` modes. Each command builder declares
its own state roots (Claude: `~/.claude`, `~/.claude.json`,
`~/Library/Caches/claude-cli-nodejs`; Cursor: `~/.cursor`,
`~/Library/Application Support/Cursor`); the helper in D4 accepts
`extraWritablePaths: [String]`. This keeps "read-only" meaning
"read-only for *user data and the repo*", which is the semantics the
advisory mapping already implies (`plan` mode still writes its own
session files).

Consequence: with state roots present, `read-only` uses the `.paths`
write scope, which (per D3) also grants the resolved `TMPDIR` and
`/private/tmp` — agent CLIs cannot run without temp scratch. The
strict no-write profile applies only to policies constructed directly
with `writeScope: .readOnly` and no extra roots.

### D7 — Testing strategy

- **Pure profile tests** (`Tests/AgentAdapterTests/SeatbeltSandboxTests.swift`,
  new): golden assertions on generated SBPL for each mode
  (readOnly / paths / network on-off / readPaths narrowing), path
  escaping, control-character rejection, `/var`→`/private/var`
  canonicalization, invocation rewrite (`sandbox-exec -p` argument
  order preserves original argv), enforcement fallbacks (auto vs
  required on non-Darwin simulated via injected availability probe).
- **Integration tests, macOS-gated** (`#if os(macOS)` +
  `try XCTSkipUnless(FileManager…isExecutableFile(atPath:
  "/usr/bin/sandbox-exec"))`): spawn `/bin/sh -c` through
  `FoundationLocalAgentProcessRunner` with a policy and assert:
  - `readOnly`: `touch` outside temp fails (nonzero exit), stdout
    pipe still works.
  - `paths([dir])`: write inside `dir` succeeds, write outside fails.
  - `networkAllowed: false` is asserted via profile content only (no
    network calls in tests).
- **Adapter wiring tests**: with `RIELA_SANDBOX_SEATBELT=auto` in the
  builder environment, Claude/Cursor command builders attach the
  expected policy; Codex builder never attaches one; default env
  attaches none (R4 regression guard).

## Non-goals

- Sandboxing the in-process add-on paths (`BuiltinWorkflowAddonResolver`,
  `NativeBundleAddonResolver` dylibs) — Seatbelt applies to child
  processes; in-process isolation is a different mechanism.
- Replacing container add-on enforcement or providing a Seatbelt
  fallback for container add-ons — their entrypoints are Linux image
  binaries, not host executables.
- Sandboxing Apple-service helper processes (apple-gateway,
  mail-gateway-reader) and daemon/serve infrastructure — they require
  TCC-mediated access (Notes, Contacts, Mail) that Seatbelt profiles
  would break; they also do not execute workflow-provided scripts.
- Network allowlisting by host/domain (Seatbelt cannot filter by
  domain; only all-or-nothing / port-level).
- Linux enforcement (landlock/bwrap) — the policy type is
  platform-neutral so a Linux backend can be added later.
- Workflow-schema changes: no new workflow.json fields; the existing
  `agentSandbox` plus the env switch fully determine behavior.

## Risks

- **Agent breakage under enforcement**: agent CLIs touch
  unanticipated paths (keychains, sockets, `/dev/tty`). Mitigated by:
  default `off`, broad-read default, agent state dirs writable (D6),
  scratch literals in the base profile, and `auto` mode falling back
  cleanly. Seatbelt denials surface in stderr
  (`sandbox-exec: … deny …`) which riela already captures.
- **`sandbox-exec` deprecation**: Apple may remove it; the design
  isolates all Seatbelt specifics in `SeatbeltSandbox.swift` behind
  the policy type so an `sandbox_init`/libsandbox or Endpoint
  Security backend can replace it.
- **Symlinked temp paths**: unresolved `/var/folders/...` vs
  `/private/var/folders/...` mismatches make profiles silently
  useless — canonicalization is mandatory and unit-tested (D3, D7).
- **Signal management**: the child becomes `sandbox-exec`'s child;
  process-group kill already targets the group
  (`LocalAgentProcess.swift:589,594`), and `sandbox-exec` execs the
  target directly (no intermediate lingering process), so
  terminate/kill semantics are unchanged.
- **Codex double-sandbox**: excluded by design (D4); a wiring test
  guards it.
