# Cursor CLI Agent Swift Migration Review Plan

Status: completed
Workflow: `codex-design-and-implement-review-loop`
Mode: issue-resolution

## Issue Reference

- Review subject: completed Swift migration of legacy `cursor-agent` /
  `cursor-cli-agent` functionality into Riela.
- Primary plan path: `impl-plans/completed/cursor-cli-agent-swift-migration.md`
- Target paths:
  - `Package.swift`
  - `Sources/CursorCLIAgent`
  - `Sources/CursorCLIAgentCLI`
  - `Tests/CursorCLIAgentTests`
  - `packaging/swift-deletion-readiness-evidence.json`

## Design Source Of Truth

Use `design-docs/specs/design-swift-native-migration.md`, section
`Cursor CLI Agent Standalone Compatibility Review Design`, as the accepted design
for this plan. Step 3 accepted the design with no high or mid findings.

The accepted design requires Cursor-specific behavior to stay isolated in
`CursorCLIAgent` and `CursorCLIAgentCLI`. It must not leak into `RielaCore`,
provider-neutral `RielaAdapters`, `CodexAgent`, `ClaudeCodeAgent`, GraphQL
manager control, events, server code, or the `official/cursor-sdk` boundary.

## Reference Inputs

- `../cursor-agent/src/config/paths.ts`: storage roots and environment
  overrides.
- `../cursor-agent/src/auth/token-manager.ts` and
  `../cursor-agent/src/persistence/token-store.ts`: `tokens.json`, raw
  `<uuid>.<base64url-secret>` tokens, SHA-256 hex `tokenHash`, metadata-only
  listing, expiry, revocation, rotation, and verification.
- `../cursor-agent/src/cursor/process-runner.ts`: `cursor-agent --print
  --output-format stream-json`, optional `--model`, `--mode`, trust/yolo,
  worktree, image, sandbox flags, prompt after `--`, resume shape, and
  environment forwarding.
- `../cursor-agent/src/persistence/session-index.ts`: transcript discovery,
  Cursor project slugs, rollout JSONL, SQLite state, workspace filtering, and
  session id resolution.
- `../cursor-agent/src/compat/commands.ts`,
  `../cursor-agent/src/compat/dispatcher.ts`, and
  `../cursor-agent/src/compat/permissions.ts`: compatibility CLI, GraphQL, and
  permission command surface.
- `../codex-agent`: shared standalone facade pattern only. Do not copy Codex
  names, argv, auth roots, session behavior, or provider semantics into Cursor.

## Task Breakdown

- [x] T1 Package and entry-point review
  - Deliverables: verify `Package.swift` declares library `CursorCLIAgent`,
    executable product `cursor-cli-agent`, executable target
    `CursorCLIAgentCLI`, test target `CursorCLIAgentTests`, and Riela CLI
    target dependency only where required.
  - Files: `Package.swift`, `Sources/CursorCLIAgentCLI/EntryPoint.swift`.
  - Completion: executable entry point is thin and delegates argument handling to
    `CursorCLIAgent`.

- [x] T2 Cursor facade isolation review
  - Deliverables: verify Cursor compatibility code lives under
    `Sources/CursorCLIAgent` and `Sources/CursorCLIAgentCLI`; verify no Cursor
    mode, store, CLI command, transcript, or permission behavior was moved into
    Codex, Claude, core runtime, event, server, or `official/cursor-sdk` code.
  - Files: `Sources/CursorCLIAgent/**`, `Sources/CursorCLIAgentCLI/**`,
    `Sources/RielaCore/**`, `Sources/RielaAdapters/**`, `Sources/CodexAgent/**`,
    `Sources/ClaudeCodeAgent/**`.
  - Completion: any shared dependency is provider-neutral; Cursor-specific
    behavior remains target-local.

- [x] T3 Process argv and runner compatibility review
  - Deliverables: verify `cursor-agent` invocation shape, stream JSON output,
    optional model/mode/worktree/image/trust/yolo/system prompt arguments,
    conflicting flag sanitization, prompt-after-`--`, resume shape, injected
    runner support, lifecycle status, and credential redaction boundaries.
  - Files: `Sources/CursorCLIAgent/CursorCLIAgentProcess.swift`,
    `Sources/CursorCLIAgent/CursorCLIProcessManager.swift`,
    `Sources/CursorCLIAgent/CursorCLIAgentAdapter.swift`.
  - Completion: process execution is explicit, argv-array based, deterministic in
    tests, and does not inherit Codex or Claude command construction.

- [x] T4 Storage, token, and permission compatibility review
  - Deliverables: verify config/data/Cursor-home root defaults and environment
    overrides; verify `tokens.json` stores only SHA-256 hex `tokenHash` and
    metadata; verify raw `uuid.secret` token creation/rotation output,
    expiration, revocation, permission wildcard normalization, timing-safe
    verification intent, and token-authenticated GraphQL restrictions.
  - Files: `Sources/CursorCLIAgent/CursorCLIOperationalStores.swift`,
    `Sources/CursorCLIAgent/CursorCLIOperations.swift`,
    `Sources/CursorCLIAgent/CursorCLISessionIndex.swift`.
  - Completion: local compatibility stores are not workflow runtime stores and do
    not publish workflow messages, allocate communications, or decide candidate
    output paths.

- [x] T5 Operational store, GraphQL, and CLI command coverage review
  - Deliverables: verify deterministic coverage for `auth`, `activity`,
    `session`, `group`, `queue`, `bookmark`, `token`, `files`, `model`, `skill`,
    `daemon`, `server`, `usage`, `markdown`, `repo`, `version`, and `graphql`;
    verify unsupported live-execution commands return explicit unsupported or
    degraded diagnostics.
  - Files: `Sources/CursorCLIAgent/CursorCLIOperations.swift`,
    `Sources/CursorCLIAgent/CursorCLIOperationalStores.swift`,
    `Sources/CursorCLIAgent/CursorCLIUsageStats.swift`,
    `Sources/CursorCLIAgent/CursorCLIPolling.swift`,
    `Sources/CursorCLIAgent/CursorCLIRolloutWatcher.swift`.
  - Completion: command aliases, GraphQL parameter forms, errors, and permission
    checks match the legacy compatibility facade where scoped by the design.

- [x] T6 Transcript discovery and session compatibility review
  - Deliverables: verify rollout JSONL import, Cursor SQLite state lookup,
    legacy `.cursor/projects/<workspace-slug>/agent-transcripts` discovery,
    workspace slug fallback when `cwd` is missing, message/history/search/grep
    GraphQL surfaces, and activity hook status mapping.
  - Files: `Sources/CursorCLIAgent/CursorCLISessionIndex.swift`,
    `Sources/CursorCLIAgent/CursorCLISessionSQLiteIndex.swift`,
    `Sources/CursorCLIAgent/CursorCLIRollout.swift`,
    `Sources/CursorCLIAgent/CursorCLIRolloutWatcher.swift`,
    `Sources/CursorCLIAgent/CursorCLIPolling.swift`.
  - Completion: transcript discovery is Cursor-specific and deterministic with
    synthetic fixtures.

- [x] T7 Test and evidence review
  - Deliverables: verify `Tests/CursorCLIAgentTests` covers the legacy category
    matrix, argv, process runner injection, token format, roots, GraphQL aliases,
    auth status, permission boundaries, session discovery, queue behavior,
    activity hooks, polling, and config readers; verify documentation and
    evidence updates stay limited to the active plan, accepted design, and
    deletion-readiness manifest; update deletion-readiness evidence only with
    commands that were actually run and passed.
  - Files: `Tests/CursorCLIAgentTests/CursorCLIAgentCompatibilityTests.swift`,
    `packaging/swift-deletion-readiness-evidence.json`.
  - Completion: evidence does not claim full TypeScript deletion readiness or
    `official/cursor-sdk` readiness from this standalone Cursor review alone.

- [x] T8 Verification, review gate, and closeout
  - Deliverables: run focused and broad verification where feasible; record any
    blockers explicitly; run adversarial implementation review because Step 1
    classified the change as high risk; fix any high or mid findings before
    moving the plan to completed.
  - Files: this plan and any implementation/test/evidence files touched by fixes.
  - Completion: no high or mid review findings remain, verification status is
    explicit, and the plan is moved to `impl-plans/completed/` only after review
    acceptance.

## Dependencies

- T1 must complete before T2 and T7 final acceptance.
- T2 must complete before accepting any task that proves anti-leakage behavior.
- T3, T4, T5, and T6 depend on the design reference mapping but may be reviewed
  independently.
- T7 depends on T3 through T6 so tests can be mapped to the behavior they prove.
- T8 depends on all tasks and on the adversarial implementation review result.

## Parallelization

The implementation review may be split only across disjoint write scopes:

- T1 may run in parallel with T3 through T6 if it only reads `Package.swift` and
  `Sources/CursorCLIAgentCLI`.
- T3, T4, T5, and T6 may run in parallel as read-only review slices.
- T7 must not update `packaging/swift-deletion-readiness-evidence.json` in
  parallel with any verification command that may add evidence.
- T8 is sequential.

## Verification Plan

- `git diff --check -- Package.swift Sources/CursorCLIAgent Sources/CursorCLIAgentCLI Tests/CursorCLIAgentTests packaging/swift-deletion-readiness-evidence.json impl-plans/completed/cursor-cli-agent-swift-migration.md`
- `rg -n "codex-agent|claude-code-agent|Codex|Claude" Sources/CursorCLIAgent Sources/CursorCLIAgentCLI Tests/CursorCLIAgentTests`
- `rg -n "CURSOR_CLI_AGENT_DATA_DIR|CURSOR_CLI_AGENT_CONFIG_DIR|CURSOR_CLI_AGENT_CURSOR_HOME|tokens.json|tokenHash|--output-format|stream-json|--resume" Sources/CursorCLIAgent Tests/CursorCLIAgentTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CursorCLIAgentTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
- Rielflow adversarial implementation review with no high or mid findings.

## Progress Log Expectations

- Record task completion by checking off the relevant task only after its
  deliverables and verification evidence are available.
- If a verification command is skipped, record the exact blocker and whether the
  blocker is environmental or behavioral.
- Keep scratch evidence, wrappers, command logs, and intermediate JSON under
  repository-root `tmp/` only; do not stage scratch artifacts.
- Do not move this plan to `impl-plans/completed/` until Step 5 and any required
  adversarial implementation review accept the implementation.

## Completion Criteria

- `cursor-cli-agent` executable product and `CursorCLIAgentCLI` entry point are
  present and target-local.
- Cursor-specific compatibility behavior is isolated from Claude, Codex,
  provider-neutral core/runtime code, and `official/cursor-sdk`.
- Process argv shape, raw token format, token hash storage, storage roots,
  transcript discovery, permissions, command coverage, and tests are explicitly
  verified against the reference mapping.
- `packaging/swift-deletion-readiness-evidence.json` is accurate for the commands
  actually run.
- Swift build/typecheck passes or any blocker is explicitly documented.
- Focused Swift tests pass or any blocker is explicitly documented.
- Full Swift tests pass or any blocker is explicitly documented.
- No high or mid review findings remain.

## Verification Results

- `swift test --filter CursorCLIAgentTests`: passed, 19 tests.
- `swift test --filter SwiftDeletionReadinessTests`: passed, 29 tests.
- `swift test`: passed, 405 tests.
- Follow-up adversarial implementation review found high/mid issues in
  `session.create`/`session.resume`/`session.cancel`/`session.pause` and
  `group:run` token handling; those issues were implemented and covered by
  focused CursorCLIAgent tests before closeout.

## Addressed Feedback

- Step 3 design review accepted the design with no findings, so no high or mid
  feedback required remediation before this plan revision.
- This plan replaces the initial checklist with task-level deliverables,
  dependencies, parallelization limits, verification commands, completion
  criteria, and Codex/Cursor reference traceability.
- Rielflow adversarial review feedback on session lifecycle implementation and
  `group:run` permission boundaries has been addressed in Swift code and tests.

## Risks

- The repository contains pre-existing implementation and evidence changes; do
  not revert unrelated work while reviewing this plan.
- `skipInitialImplementation=true` means this node is planning/review-handoff
  focused; implementation fixes belong to later workflow steps unless a later
  review requires plan updates.
- Full `swift test` can be slow or environment-sensitive under Xcode SDK
  configuration; any blocker must be reported with the exact command.
- `official/cursor-sdk` remains out of scope and must not be treated as covered
  by standalone `cursor-cli-agent` evidence.
