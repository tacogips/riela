# ClaudeCodeAgent Swift Migration Implementation Plan

**Status**: Completed
**Design Reference**: `design-docs/specs/design-swift-native-migration.md`
**Workflow Mode**: rielflow-adversarial-implementation-review
**Created**: 2026-06-17
**Last Updated**: 2026-06-17

## Summary

Migrate the legacy `claude-code-agent` TypeScript feature surface into the
Swift `ClaudeCodeAgent` package in `riela`. The migration must preserve the
observable CLI, SDK utility, repository, token/auth, GraphQL command, polling,
activity, and process execution behavior that callers depended on in the
legacy package.

## Source Of Truth

- Active Swift target: `Sources/ClaudeCodeAgent`
- Active Swift CLI target: `Sources/ClaudeCodeAgentCLI`
- Legacy reference root: `../claude-code-agent`
- Existing adjacent migration reference: `Sources/CodexAgent`

## Legacy Reference Mapping

- CLI: `../claude-code-agent/src/cli/main.ts`,
  `../claude-code-agent/src/cli/commands/*.test.ts`
- Auth and credentials: `../claude-code-agent/src/auth/*.test.ts`,
  `../claude-code-agent/src/sdk/credentials/__tests__/*.test.ts`
- Repositories: `../claude-code-agent/src/repository/**/*.test.ts`
- GraphQL command facade: `../claude-code-agent/src/graphql/index.test.ts`,
  `../claude-code-agent/src/cli/graphql.test.ts`
- Polling and activity:
  `../claude-code-agent/src/polling/*.test.ts`,
  `../claude-code-agent/src/sdk/activity/*.test.ts`
- SDK utilities:
  `../claude-code-agent/src/sdk/**/*.test.ts`,
  `../claude-code-agent/src/container.test.ts`
- Process and control protocol:
  `../claude-code-agent/src/sdk/session-runner.ts`,
  `../claude-code-agent/src/sdk/transport/subprocess.test.ts`,
  `../claude-code-agent/src/sdk/control-protocol.test.ts`

## Tasks

### TASK-001: Lock the legacy coverage matrix

**Deliverables**:

- `Tests/ClaudeCodeAgentTests/ClaudeCodeAgentCompatibilityTests.swift`

**Work**:

- Enumerate the legacy Claude test categories and map each to Swift parity
  assertions.
- Keep the matrix explicit enough to fail when a legacy feature category is
  removed from migration coverage.
- Record intentional divergences only when they are SwiftPM packaging or
  Foundation-process implementation details.

**Status**: COMPLETED

### TASK-002: Port process/session execution and CLI argument contracts

**Deliverables**:

- `Sources/ClaudeCodeAgent/ClaudeCodeAgentProcess.swift`
- `Sources/ClaudeCodeAgent/ClaudeCodeProcessManager.swift`
- `Sources/ClaudeCodeAgentCLI/EntryPoint.swift`
- `Tests/ClaudeCodeAgentTests/ClaudeCodeAgentCompatibilityTests.swift`

**Work**:

- Build `claude -p --output-format stream-json` execution, resume, and process
  lifecycle helpers with injectable runners for tests and Foundation `Process`
  defaults for production.
- Preserve `--model`, `--permission-mode`, `--add-dir`, extra args, cwd,
  environment, stdin, stdout/stderr, exit code, process id, kill, input write,
  and prune behavior.
- Add the `claude-code-agent` executable product.

**Status**: COMPLETED

### TASK-003: Port auth/token, credentials, and repositories

**Deliverables**:

- `Sources/ClaudeCodeAgent/ClaudeCodeOperationalStores.swift`
- `Tests/ClaudeCodeAgentTests/ClaudeCodeAgentCompatibilityTests.swift`

**Work**:

- Persist `cca_` raw tokens as SHA-256 hashes with metadata-only list output,
  expiration, revoke, rotate, permission wildcard matching, and validation.
- Port in-memory and file-backed session, group, queue, bookmark, activity, and
  atomic JSON store behavior.
- Cover duration parsing and credential config resolution.

**Status**: COMPLETED

### TASK-004: Port GraphQL and CLI command execution

**Deliverables**:

- `Sources/ClaudeCodeAgent/ClaudeCodeOperations.swift`
- `Tests/ClaudeCodeAgentTests/ClaudeCodeAgentCompatibilityTests.swift`

**Work**:

- Execute `session.list/get/messages`, `group.create/list/get/run/pause/resume/delete/addSession/removeSession`,
  `queue.create/list/get/addCommand/updateCommand/removeCommand/run/pause/resume/delete`,
  `bookmark.add/list/search/get/content/delete`, `activity.list/get`, and
  token/auth utility commands against Swift stores.
- Preserve unsupported-operation errors for legacy commands that were
  intentionally declared but not implemented.
- Preserve JSON variables and `--param` coercion behavior.

**Status**: COMPLETED

### TASK-005: Port polling, activity, and SDK utilities

**Deliverables**:

- `Sources/ClaudeCodeAgent/ClaudeCodePolling.swift`
- `Sources/ClaudeCodeAgent/ClaudeCodeSDKUtilities.swift`
- `Tests/ClaudeCodeAgentTests/ClaudeCodeAgentCompatibilityTests.swift`

**Work**:

- Port JSONL buffering, transcript event mapping, active tool/subagent/task
  state, monitor rendering, activity status updates, transcript ask-user
  detection, event emitter, markdown parsing, file-change extraction, and tool
  registry/version helpers.

**Status**: COMPLETED

### TASK-006: Rielflow adversarial review and closure

**Deliverables**:

- `impl-plans/active/claude-code-agent-swift-migration.md`
- `tmp/riela-claude-code-agent-migration-review/`

**Work**:

- Run the Rielflow adversarial implementation review against the migration.
- Fix every high or medium finding and rerun/review until none remain.
- Move this plan to `impl-plans/completed/` only after implementation,
  focused Swift tests, and review closure are complete.

**Status**: COMPLETED

## Module Status

| Module | File Path | Status | Tests |
| ------ | --------- | ------ | ----- |
| Coverage matrix | `Tests/ClaudeCodeAgentTests/ClaudeCodeAgentCompatibilityTests.swift` | COMPLETED | `swift test --filter ClaudeCodeAgentTests` |
| Process and CLI | `Sources/ClaudeCodeAgent/*Process*.swift`, `Sources/ClaudeCodeAgentCLI/EntryPoint.swift` | COMPLETED | Process/CLI compatibility assertions |
| Stores and auth | `Sources/ClaudeCodeAgent/ClaudeCodeOperationalStores.swift` | COMPLETED | Token/repository assertions |
| GraphQL operations | `Sources/ClaudeCodeAgent/ClaudeCodeOperations.swift` | COMPLETED | Command facade assertions |
| Polling/activity/SDK | `Sources/ClaudeCodeAgent/ClaudeCodePolling.swift`, `Sources/ClaudeCodeAgent/ClaudeCodeSDKUtilities.swift` | COMPLETED | Polling/activity/SDK assertions |
| Review evidence | `tmp/riela-claude-code-agent-migration-review/` | COMPLETED | Rielflow accepted closure session |

## Completion Criteria

- [x] `claude-code-agent` executable target is wired in SwiftPM.
- [x] Swift `ClaudeCodeAgent` exposes the migrated process, CLI, SDK,
      GraphQL, auth/token, repository, polling, and activity behavior.
- [x] Legacy test categories are mapped to Swift parity tests.
- [x] Focused Claude Swift tests pass.
- [x] Full Swift test suite passes or any unrelated failure is documented.
- [x] Rielflow adversarial review has no high or medium findings.
- [x] Plan is moved to `impl-plans/completed/` with final verification notes.

## Progress Log

### Session: 2026-06-17 18:00 JST

**Tasks Completed**: Legacy feature/test surface inspection and initial active
implementation plan.
**Tasks In Progress**: TASK-001 coverage matrix and Swift target wiring.
**Blockers**: None.
**Notes**: Use `../claude-code-agent` as the legacy reference root. Scratch
review artifacts must stay under `tmp/`.

### Session: 2026-06-17 20:42 JST

**Tasks Completed**: TASK-001 through TASK-006.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**:

- Added the SwiftPM `claude-code-agent` executable and migrated the ClaudeCodeAgent
  process, CLI, auth/token, store, GraphQL, queue/group/bookmark, session
  discovery, polling, activity, rollout, and SDK utility surfaces into Swift.
- Ported legacy compatibility coverage into
  `Tests/ClaudeCodeAgentTests/ClaudeCodeAgentCompatibilityTests.swift`.
- Closed Rielflow review findings for stdin activity hooks, `activity.setup`
  merge/non-object handling, legacy activity object shape/projectPath/locking,
  token millisecond timestamps and expiry parsing, cleanup hour/default and
  fractional timestamp handling, and deletion-readiness evidence freshness.
- Verification:
  - `swift test --filter ClaudeCodeAgentTests`: passed, 19 tests.
  - `swift test --filter SwiftDeletionReadinessTests`: passed, 29 tests.
  - `swift test`: passed, 386 tests.
  - Rielflow closure review:
    `riel-temporary-claude-code-agent-migration-review-codex-closure-1781696580-c0f7cbaf`,
    accepted with no high or medium findings.
