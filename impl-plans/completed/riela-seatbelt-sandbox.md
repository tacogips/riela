# Riela Seatbelt Sandbox Implementation Plan

**Status**: Complete
**Design Reference**: design-docs/specs/design-riela-seatbelt-sandbox.md
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Source**: design-docs/specs/design-riela-seatbelt-sandbox.md
(decisions D1–D7; requirements R1–R4)

### Summary

Introduce `LocalProcessSandboxPolicy` carried on
`LocalAgentProcessConfiguration` (D1), an SBPL profile generator and
`sandbox-exec` invocation rewrite applied at the `posix_spawn` choke
point in `FoundationLocalAgentProcessRunner` (D2, D3), an
`agentSandbox`-to-policy derivation helper with agent state-dir
writable roots (D4, D6), and an opt-in `RIELA_SANDBOX_SEATBELT`
env switch (`off`/`auto`/`required`, default `off`) wired into the
Claude and Cursor command builders — never Codex (D5). Pure golden
tests plus macOS-gated integration tests (D7).

### Scope

**Included**: `Sources/RielaAdapters` (new `SeatbeltSandbox.swift`,
edits to `LocalAgentProcess.swift`),
`Sources/ClaudeCodeAgent/ClaudeCodeAgentAdapter.swift`,
`Sources/CursorCLIAgent/CursorCLIAgentAdapter.swift`,
`Tests/AgentAdapterTests/` (new `SeatbeltSandboxTests.swift`, wiring
tests in existing adapter test targets).

**Excluded** (design Non-goals): Codex wrapping, container add-on
fallback, in-process add-ons, gateway/daemon helpers, Linux
enforcement backends, workflow.json schema changes, host/domain
network allowlisting.

**Constraint**: the working tree contains unrelated in-progress
note-edit UI changes (`Sources/RielaNoteUI`, `Sources/RielaApp`,
`Sources/RielaCLI/ProductionNodeAdapter+Apple*`,
`Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`). Do NOT touch
those files; do not revert or reformat anything outside the files
listed per task.

---

## Task Breakdown

### TASK-001: Sandbox policy type + configuration field (D1)
**Status**: Done
**Depends On**: —
**Deliverables**:
- `Sources/RielaAdapters/SeatbeltSandbox.swift`:
  `LocalProcessSandboxPolicy` (`Equatable`, `Sendable`) with
  `Enforcement` (`auto`/`required`), `FilesystemWriteScope`
  (`readOnly` / `paths([String])`), `readPaths: [String]?`
  (nil = broad read), `networkAllowed: Bool`, memberwise init with
  sensible defaults.
- `Sources/RielaAdapters/LocalAgentProcess.swift`:
  `LocalAgentProcessConfiguration` gains
  `public var sandboxPolicy: LocalProcessSandboxPolicy?` with a
  defaulted init parameter appended so every existing call site
  compiles unchanged. Keep `Equatable`/`Sendable`.

**Checklist**:
- [x] `swift build` passes with no call-site edits outside the two
      files above
- [x] Policy type has no Foundation-URL fields (plain `String` paths)
      so `Equatable` stays trivial

### TASK-002: SBPL generation + invocation rewrite (D2, D3)
**Status**: Done
**Depends On**: TASK-001
**Deliverables** (all in `SeatbeltSandbox.swift`, pure functions,
no process spawning):
- `seatbeltProfile(for:workingDirectory:temporaryDirectory:) -> String`
  implementing the D3 base profile:
  `(version 1)` / `(deny default)` / process-fork+exec / signal
  same-sandbox / sysctl-read / mach-lookup / broad `file-read*`
  (or `readPaths` subpath narrowing + `file-read-metadata`) /
  scratch write literals (`/dev/null`, `/dev/dtracehelper`) /
  `file-write*` subpath allows for canonicalized writable roots
  (workspace mode) incl. resolved `TMPDIR`, `/private/tmp`, and the
  resolved `NSTemporaryDirectory()` / explicit none (readOnly) /
  `(allow network*)` or `(deny network*)`.
- Path handling: canonicalize every embedded path with
  `URL(fileURLWithPath:).resolvingSymlinksInPath()` (must turn
  `/var/...` into `/private/var/...`); escape `\` and `"`; throw
  `AdapterExecutionError(.policyBlocked, …)` on newline/control
  characters in paths (profile injection guard).
- `seatbeltInvocation(for configuration:) throws ->
  LocalAgentProcessConfiguration?` — returns nil when
  `sandboxPolicy == nil`; otherwise rewrites to
  `/usr/bin/sandbox-exec` with arguments
  `["-p", profile, originalExecutablePath] + originalArguments`,
  preserving environment/workingDirectory/unsetEnvironmentKeys and
  clearing `sandboxPolicy` on the rewritten configuration.
- Availability probe injectable for tests:
  `SeatbeltAvailability` (default checks
  `FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")`,
  Darwin-only via `#if canImport(Darwin)`).
- Fallback semantics per D2: unavailable + `auto` → return original
  configuration unchanged; unavailable + `required` → throw
  `AdapterExecutionError(.policyBlocked, …)` naming platform or
  missing binary.

**Checklist**:
- [x] Profile output is deterministic (stable ordering of writable
      roots — sort them)
- [x] Rewrite preserves original argv order after the executable path
- [x] Non-Darwin build compiles (guards around Darwin-only probe)

### TASK-003: Apply at the spawn choke point (D2)
**Status**: Done
**Depends On**: TASK-002
**Deliverables**:
- `FoundationLocalAgentProcessRunner.run(configuration:stdin:deadline:outputEventHandler:)`
  (`LocalAgentProcess.swift:636`): resolve
  the effective configuration via the TASK-002 API before pipe/spawn
  setup; on throw, surface the `AdapterExecutionError` as-is.
  `spawnProcess` itself stays policy-unaware.

**Checklist**:
- [x] No behavior change when `sandboxPolicy == nil` (existing
      `AgentAdapterProcessIOTests` untouched and green)
- [x] Errors from `required` enforcement propagate without wrapping

### TASK-004: Policy derivation + env switch (D4, D5, D6)
**Status**: Done
**Depends On**: TASK-001
**Deliverables** (in `SeatbeltSandbox.swift`):
- `SeatbeltSandboxSettings.mode(environment:)` parsing
  `RIELA_SANDBOX_SEATBELT ∈ {off, auto, required}` (default `off`,
  case-insensitive, trimmed); unknown value → throw
  `AdapterExecutionError(.policyBlocked, …)` (fail loudly, R3/D5).
- `localSandboxPolicy(for mode: AgentSandboxMode?, workingDirectory:
  URL?, artifactRoot: URL?, extraWritablePaths: [String],
  enforcement:) -> LocalProcessSandboxPolicy?`:
  `read-only` → `.readOnly` + `networkAllowed: true` +
  `extraWritablePaths` honored as writable state roots (D6);
  `workspace-write` → `.paths(workingDirectory + artifactRoot +
  extraWritablePaths)`; `danger-full-access`/nil → nil.
  Artifact root: read `RIELA_ARTIFACT_DIR` from the builder
  environment when present, else `workingDirectory/.riela/artifacts`
  (mirrors `ContainerWorkflowAddonResolver.artifactRootURL()`,
  `Sources/RielaCLI/ContainerWorkflowAddonResolver.swift:204-209`)
  — implement as a small helper taking the environment dictionary.

**Checklist**:
- [x] `read-only` still yields writable agent state roots but nothing
      else
- [x] Default environment (no var) yields no policy anywhere

### TASK-005: Wire Claude + Cursor builders; keep Codex exempt (D4, D5)
**Status**: Done
**Depends On**: TASK-004
**Deliverables**:
- `Sources/ClaudeCodeAgent/ClaudeCodeAgentAdapter.swift` command
  builder: after building the configuration, when
  `SeatbeltSandboxSettings.mode` on the merged builder environment is
  `auto`/`required`, attach
  `localSandboxPolicy(for: input.node.agentSandbox, …)` with Claude
  state roots (`~/.claude`, `~/.claude.json` parent is `~` — use the
  file's parent only for the literal file, prefer subpath
  `~/.claude` + literal `~/.claude.json`; also
  `~/Library/Caches/claude-cli-nodejs` if trivially known — keep the
  list conservative and documented in code).
- `Sources/CursorCLIAgent/CursorCLIAgentAdapter.swift` builder:
  same wiring with Cursor state roots (`~/.cursor`,
  `~/Library/Application Support/Cursor`).
- Codex builder: no change (guard by wiring test only).
- Existing advisory flags (permission mode, `--sandbox`) unchanged.

**Checklist**:
- [x] Policy attached only when env switch is on (R4)
- [x] `danger-full-access` and absent `agentSandbox` attach nothing
- [x] Codex configuration never carries a policy

### TASK-006: Tests (D7)
**Status**: Done
**Depends On**: TASK-003, TASK-005
**Deliverables**:
- `Tests/AgentAdapterTests/SeatbeltSandboxTests.swift`:
  golden SBPL per mode; network on/off; readPaths narrowing;
  escaping (`"`/`\`), control-char rejection; `/var` canonicalization
  (use `FileManager.default.temporaryDirectory`); invocation rewrite
  argv shape; enforcement fallback matrix via injected availability
  probe; `SeatbeltSandboxSettings` parsing incl. unknown-value throw.
- macOS-gated integration tests (same file, `#if os(macOS)` +
  `XCTSkipUnless(isExecutableFile("/usr/bin/sandbox-exec"))`):
  through `FoundationLocalAgentProcessRunner`, `/bin/sh -c`:
  read-only → write outside temp fails, stdout/stderr pipes intact;
  workspace paths → write inside allowed dir succeeds, outside fails.
- Wiring tests in the Claude/Cursor adapter test files: policy
  attach/absence matrix per TASK-005 checklist; Codex exemption.

**Checklist**:
- [x] `swift test` fully green on macOS
- [x] Integration tests skip (not fail) when sandbox-exec is absent

---

## Validation

- `swift build` (whole package)
- `swift test --filter SeatbeltSandboxTests`
- `swift test` (full suite; pre-existing state: green as of
  2026-07-07 baseline)

**Results (2026-07-07, post-review)**: `swift build` clean;
`SeatbeltSandboxTests` 21/21 (macOS integration tests ran live
against `/usr/bin/sandbox-exec`); `AgentAdapterTests` 91/91 incl.
Seatbelt wiring; full suite 1470 tests with 1 failure —
`RielaExampleParityTests.testAllRielaExampleWorkflowsArePortedAndValidateInSwift`,
verified pre-existing (parity list last touched in 76ed0cb predates
the `apple-note-*` examples added in 7549e63 and the untracked
`examples/note-edit-rewrite/`; unrelated to this work). Review
deviations accepted and back-ported into the design doc: realpath
canonicalization (not `resolvingSymlinksInPath`, which strips
`/private`), process-env fallback for `RIELA_SANDBOX_SEATBELT`,
temp-writability under read-only-with-state-roots.
- Manual smoke (optional): `RIELA_SANDBOX_SEATBELT=required` with a
  `read-only` node on a trivial workflow and confirm the agent
  process runs under `sandbox-exec` (`ps` shows the profile arg) and
  a write attempt is denied.

## Acceptance Criteria

- R1: on macOS with the env switch on, Claude/Cursor agent processes
  run under a Seatbelt profile derived from `agentSandbox`.
- R2: profile semantics match D3/D4 (golden + integration tests).
- R3: `required` fails loudly off-Darwin / without sandbox-exec;
  unknown env values fail loudly.
- R4: default env → zero behavior change; Codex never wrapped; full
  existing test suite stays green; no files outside the task lists
  modified.
