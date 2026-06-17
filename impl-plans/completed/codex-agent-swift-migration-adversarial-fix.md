# CodexAgent Swift Migration Adversarial Fix Implementation Plan

**Status**: Completed
**Design Reference**: `design-docs/specs/design-swift-native-migration.md:1019`
**Workflow Mode**: issue-resolution
**Issue Reference**: `workflow-call:codex-agent-swift-migration-adversarial-fix`
**Created**: 2026-06-17
**Last Updated**: 2026-06-17

## Summary

Fix the accepted high and medium adversarial findings for the Swift
`CodexAgent` migration. This plan is limited to CodexAgent GraphQL command
execution, production process/session execution, legacy-compatible auth token
persistence, and explicit coverage for the legacy CodexAgent feature/test
categories named by the parent review.

## Source Of Truth

- `design-docs/specs/design-swift-native-migration.md:1019`
- Step 3 review decision: `accepted-design-review`
- Active Codex reference root: `../codex-agent`

## Codex Reference Mapping

- GraphQL execution: `../codex-agent/src/graphql/index.test.ts`, `../codex-agent/src/cli/graphql.test.ts`, `../codex-agent/src/graphql/command-handlers.ts`
- Process/session execution: `../codex-agent/src/process/manager.ts`, `../codex-agent/src/process/manager.test.ts`, `../codex-agent/src/sdk/agent-runner.test.ts`, `../codex-agent/src/sdk/session-runner.test.ts`
- Auth tokens: `../codex-agent/src/auth/token-manager.ts`, `../codex-agent/src/auth/token-manager.test.ts`, `../codex-agent/src/auth/types.ts`
- Coverage backstop: `../codex-agent/src/queue/repository.test.ts`, `../codex-agent/src/group/repository.test.ts`, `../codex-agent/src/bookmark/manager.test.ts`, `../codex-agent/src/file-changes/*.test.ts`, `../codex-agent/src/session/*.test.ts`, `../codex-agent/src/rollout/*.test.ts`, `../codex-agent/src/markdown/parser.test.ts`, `../codex-agent/src/sdk/usage-stats.test.ts`

## Tasks

### TASK-001: Lock the legacy coverage matrix

**Deliverables**:

- `Tests/CodexAgentTests/CodexAgentCompatibilityTests.swift`

**Work**:

- Keep the 30-file legacy CodexAgent matrix explicit.
- Map every referenced legacy test file to at least one Swift parity assertion.
- Add failure messages that identify any unmapped process, session, rollout,
  SDK, readiness, usage-stats, queue, group, bookmark, auth, GraphQL, markdown,
  or file-change category.

**Dependencies**: none.

**Completion criteria**:

- The matrix fails if a legacy reference is removed, renamed, or left without a
  Swift assertion mapping.

### TASK-002: Replace GraphQL accepted placeholders with real execution

**Deliverables**:

- `Sources/CodexAgent/CodexOperations.swift`
- `Sources/CodexAgent/CodexOperationalStores.swift`
- `Sources/CodexAgent/CodexSessionIndex.swift`
- `Sources/CodexAgent/CodexSessionSQLiteIndex.swift`
- `Sources/CodexAgent/CodexUsageStats.swift`
- `Sources/CodexAgent/CodexRollout.swift`
- `Sources/CodexAgent/CodexRolloutWatcher.swift`
- `Tests/CodexAgentTests/CodexAgentCompatibilityTests.swift`

**Work**:

- Execute `version.get`, session list/show/search/searchTranscript/run/resume/fork/watch,
  group create/list/show/add/remove/pause/resume/delete/run, queue
  create/add/show/list/pause/resume/delete/update/remove/move/mode/run,
  bookmark add/list/get/delete/search, token create/list/revoke/rotate, and
  files list/patches/find/rebuild against Swift stores and runners.
- Preserve query/mutation/subscription shorthand normalization:
  `session.watch` is the only subscription, mutating commands become mutations,
  explicit GraphQL documents remain unchanged, `--param` and variable-file
  inputs become object variables, and non-object variables are rejected.
- Validate inputs before persistence.
- Remove generic `{"accepted": true}` results for supported commands.

**Dependencies**: TASK-001 mapping; TASK-003 for execution-backed session run,
resume, and fork; TASK-004 for token command behavior.

**Completion criteria**:

- Supported GraphQL commands return command-specific data or validation errors.
- Invalid commands, invalid variables, and invalid subscription names fail
  before mutating Swift stores.

### TASK-003: Make production process/session execution real by default

**Deliverables**:

- `Sources/CodexAgent/CodexAgentProcess.swift`
- `Sources/CodexAgent/CodexProcessManager.swift`
- `Sources/CodexAgent/CodexSDKUtilities.swift`
- `Sources/CodexAgent/CodexAgentAdapter.swift`
- `Tests/CodexAgentTests/CodexAgentCompatibilityTests.swift`
- `Tests/AgentAdapterTests/AgentAdapterTests.swift`

**Work**:

- Make `CodexProcessManager` default to Foundation `Process` execution of the
  configured `codex` executable.
- Preserve injected runners and fake executables for deterministic tests.
- Forward explicit argv arrays, cwd, environment, stdin writes, stdout JSONL,
  stderr, exit codes, resume/fork arguments, process ids where available,
  killed state, `killAll`, and `prune` lifecycle behavior.
- Ensure `session.run`, `session.resume`, and `session.fork` execute through the
  production runner instead of returning argv previews.

**Dependencies**: TASK-001 mapping.

**Completion criteria**:

- Tests prove process behavior with fake executables/runners and no live Codex
  install.
- Production defaults no longer use a no-op executor.

### TASK-004: Restore legacy-compatible auth token persistence

**Deliverables**:

- `Sources/CodexAgent/CodexOperationalStores.swift`
- `Sources/CodexAgent/CodexOperations.swift`
- `Tests/CodexAgentTests/CodexAgentCompatibilityTests.swift`

**Work**:

- Persist token records in `tokens.json` under the configured CodexAgent config
  directory.
- Create public raw tokens as `id.secret`.
- Store SHA-256 secret hashes; verify raw tokens with timing-safe comparison.
- Normalize permissions, support wildcard matching, enforce expiry and
  revocation, rotate secrets, and keep list output metadata-only.
- Ensure GraphQL and test-visible diagnostics never expose stored secrets.
- Save token updates atomically.

**Dependencies**: TASK-001 mapping.

**Completion criteria**:

- Token create/list/verify/revoke/rotate behavior matches the legacy reference
  without leaking secrets.

### TASK-005: Close category-level parity gaps named by the review

**Deliverables**:

- `Sources/CodexAgent/CodexOperationalStores.swift`
- `Sources/CodexAgent/CodexSessionIndex.swift`
- `Sources/CodexAgent/CodexSessionSQLiteIndex.swift`
- `Sources/CodexAgent/CodexRollout.swift`
- `Sources/CodexAgent/CodexRolloutWatcher.swift`
- `Sources/CodexAgent/CodexUsageStats.swift`
- `Tests/CodexAgentTests/CodexAgentCompatibilityTests.swift`

**Work**:

- Verify Swift behavior exists for queue, group, bookmark, file-change, session,
  rollout, markdown, usage-stats, SDK, readiness, and process categories.
- Add focused assertions where existing Swift tests only list a category but do
  not exercise the behavior.
- Record intentional divergences from TypeScript only when accepted by the
  design: SwiftPM target structure, Foundation `Process`, and no workflow
  publication/runtime-message behavior in `CodexAgent`.

**Dependencies**: TASK-002, TASK-003, TASK-004.

**Completion criteria**:

- No referenced CodexAgent feature/test category remains unported or mapped only
  by a placeholder assertion.

### TASK-006: Package wiring, progress log, and final verification evidence

**Deliverables**:

- `Package.swift`
- `impl-plans/active/codex-agent-swift-migration-adversarial-fix.md`
- `impl-plans/README.md`
- `Tests/CodexAgentTests/CodexAgentCompatibilityTests.swift`
- `Tests/AgentAdapterTests/AgentAdapterTests.swift`

**Work**:

- Keep SwiftPM targets and test targets wired for new CodexAgent source files.
- Keep implementation-plan documentation indexed in `impl-plans/README.md` and
  record any accepted behavior divergence in the active plan progress log.
- Add a dated progress entry after each implementation slice with delivered
  files, tests added, commands run, and blockers.
- Keep scratch logs, wrappers, and evidence under repository-root `tmp/`.
- Do not stage, push, or publish from implementation workflow nodes.

**Dependencies**: TASK-002, TASK-003, TASK-004, TASK-005.

**Completion criteria**:

- Focused and full verification commands are run or blockers are reported
  explicitly.

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-001 | none | Establishes the reference-backed coverage contract. |
| TASK-002 | TASK-001, TASK-003, TASK-004 | GraphQL dispatch depends on process/session and token behavior. |
| TASK-003 | TASK-001 | Process/session behavior can be implemented after the mapping is locked. |
| TASK-004 | TASK-001 | Auth can be implemented after the mapping is locked. |
| TASK-005 | TASK-002, TASK-003, TASK-004 | Category parity is only reviewable after blocking behavior exists. |
| TASK-006 | TASK-002, TASK-003, TASK-004, TASK-005 | Final wiring and evidence depend on implementation completion. |

## Parallelization

- TASK-003 and TASK-004 are parallelizable after TASK-001 if implementers keep
  write scopes disjoint: process/session work in `CodexAgentProcess.swift`,
  `CodexProcessManager.swift`, `CodexSDKUtilities.swift`, and adapter tests;
  auth work in token-store code and auth-specific tests.
- TASK-002 is not parallelizable with TASK-003 or TASK-004 once GraphQL begins
  wiring `session.run`, `session.resume`, `session.fork`, or token commands.

## Completion Log

- 2026-06-17: Implemented real Swift GraphQL dispatch for session, queue,
  group, bookmark, token, and file-change commands; added a Swift CLI command
  executor that routes parsed legacy commands into the same dispatch path.
- 2026-06-17: Replaced the default `CodexProcessManager` no-op executor with a
  Foundation `Process` execution path while preserving injected executors for
  deterministic tests.
- 2026-06-17: Added persistent `tokens.json` raw-token support with `id.secret`
  creation, metadata-only listing, verification, revocation, rotation, expiry
  checks, and GraphQL token handlers.
- 2026-06-17: Added focused Swift parity tests for operational GraphQL/CLI
  commands, token persistence, file-change command extraction, usage stats,
  default readiness probes, and default process execution with a fake
  executable.
- TASK-005 and TASK-006 are join tasks and are not parallelizable.

## Verification

Required focused commands:

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift build`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter CodexAgentTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter AgentAdapterTests`
- `git diff --check`

Run when feasible:

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test`

## Completion Criteria

- Step 3 accepted design constraints remain intact.
- No supported CodexAgent GraphQL command returns a generic accepted
  placeholder.
- Production `CodexProcessManager` defaults to real Foundation `Process`
  execution while tests remain deterministic through injected fakes.
- `CodexTokenManager` is legacy-compatible for `tokens.json` and `id.secret`
  raw tokens.
- The explicit legacy CodexAgent test matrix proves every referenced category
  has Swift behavior coverage.
- SwiftPM build/typecheck and focused test commands pass, or implementation
  blockers are documented with exact failing commands.
- Implementation-plan documentation and progress logs identify completed
  slices, verification commands, and accepted divergences.
- Cursor CLI, official Cursor SDK, workflow publication, communication ids, and
  runtime-message behavior remain outside `Sources/CodexAgent`.

## Progress Log

### Session: 2026-06-17

**Tasks Completed**: Implementation plan created after Step 3 accepted design;
self-review added explicit SwiftPM build/typecheck and documentation-index
expectations.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: Implementation must update this log after each slice with files,
tests, commands, and residual risks.

## Risks

- GraphQL, process/session, and auth behavior touch shared `CodexAgent` stores;
  late wiring conflicts are likely if TASK-002 starts before TASK-003/TASK-004
  contracts settle.
- Full `swift test` may expose unrelated migration failures; focused blockers
  must still be reported explicitly.
- Low residual adversarial findings remain out of scope unless they are
  required to close the accepted high or medium findings.
