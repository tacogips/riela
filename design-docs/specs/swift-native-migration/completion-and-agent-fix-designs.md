# Riela Swift Native Migration Design: Completion and Agent Fix Designs

### Deletion-Readiness Completion Pass

The continuation after commits `3f19b642303d14299bfe47f5bee371abcd2a2f4e` and
`1858103` is a gate-completion and source-removal pass, not another parity
narrowing pass. The design source of truth remains
`packaging/swift-deletion-readiness.json`; implementation may only move it from
blocked to deletion-ready when every required domain is current, accepted, and
resolved by `packaging/swift-deletion-readiness-evidence.json`.

For this pass, each required domain must transition together:

- `status=passed` and `reviewDecision=accepted`
- `verifiedBranch` and `verifiedCommit` matching the branch and commit being
  reviewed, not stale evidence from an earlier parity commit
- `acceptedReviewWorkflowId=codex-design-and-implement-review-loop`
- `acceptedReviewNodeId=step7-adversarial-review`
- `acceptedReviewFindingSeverities` containing only non-blocking values such as
  `none`, `info`, `informational`, or `low`
- evidence artifacts that resolve to successful command-result metadata for the
  same domain id, command, branch, commit, workflow id, and command execution
  node id

The top-level gate may then set `migrationStatus=deletion_ready`,
`allowsTypeScriptDeletion=true`, and `typeScriptSourceDeletionReady=true`.
Those three fields must not disagree with each other or with the domain
evidence. Production Swift packaging readiness remains separate and cannot
authorize TypeScript deletion by itself.

Remaining TypeScript-family files are deletion-readiness scope and must be
handled explicitly:

- `scripts/check-source-filenames.ts` and
  `scripts/check-source-filenames.test.ts` should be removed after their root
  `src/` and forbidden `part-<digits>.ts(x)` policy is covered by Swift tests,
  shell checks, or another non-TypeScript verification path.
- `scripts/sync-package-declarations.ts` should be deleted if the TypeScript
  declaration package surface is no longer shipped; if any declaration archive
  remains part of release output, replace the sync behavior with committed
  Swift or shell tooling before deletion.
- `scripts/audit-chat-redaction-literals.ts` should be replaced by Swift or
  shell redaction-literal verification before deletion, because chat gateway
  redaction evidence remains a release and security regression guard.
- `scripts/_compute-digest-temp.mjs` is scratch-style tooling and must not stay
  under `scripts/`; move any still-needed ad-hoc digest work under `tmp/` or
  replace it with reusable committed tooling.
- `examples/telegram-agent-trio-time-signal/scripts/prepare-time-signal.ts`
  must be ported to a native executable, shell script, or static fixture before
  TypeScript deletion is accepted; examples are part of the user-facing source
  surface and cannot be left as the only TypeScript runtime consumer.

`cursor-cli-agent` remains mapped only to the local Cursor CLI adapter.
`official/cursor-sdk` stays isolated behind adapter-dispatch behavior and is not
made deletion-ready by `cursor-cli-agent` evidence. If the official Cursor SDK
backend is still intentionally unavailable, the deletion-readiness record must
keep that as an explicit adapter decision rather than silently aliasing or
dropping the backend.

Deletion-readiness implementation planning must carry forward these required
verification commands, with the Xcode Swift toolchain and SDK environment used
by the current repository:

- `jq empty packaging/swift-deletion-readiness.json packaging/swift-deletion-readiness-evidence.json packaging/homebrew/swift-cutover-gates.json`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter SwiftDeletionReadinessTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowCommandTests`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CodexAgent`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter Claude`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CursorCLIAgent`
- `git diff --check`

## CodexAgent Blocking Adversarial Fix Design

This issue-resolution pass addresses only the high and medium adversarial
findings from `workflow-call:codex-agent-swift-migration-adversarial-fix`.
The scope is deliberately narrower than full Swift deletion readiness: fix the
CodexAgent GraphQL execution, production process/session execution, and auth
token compatibility gaps that would otherwise make the Swift migration review
misleading. Low residual review items remain risks unless they are directly
required by one of these fixes.

Reference mapping:

- Step 1 established `<codex-agent-checkout>` as the active
  local Codex reference root for this child workflow. The default
  `../../codex-agent` root is unavailable from the Riela checkout.
- `src/graphql/index.test.ts`, `src/cli/graphql.test.ts`, and
  `src/graphql/command-handlers.ts` define the command execution contract for
  `version.get`, session list/show/search/searchTranscript/run/resume/fork/watch,
  group create/list/show/add/remove/pause/resume/delete/run, queue
  create/add/show/list/pause/resume/delete/update/remove/move/mode/run,
  bookmark add/list/get/delete/search, token create/list/revoke/rotate, and
  files list/patches/find/rebuild.
- `src/process/manager.ts`, `src/process/manager.test.ts`,
  `src/sdk/agent-runner.test.ts`, and `src/sdk/session-runner.test.ts` define
  process and session parity: real `codex` subprocess spawning by default,
  explicit argv arrays, cwd and environment forwarding, JSONL stdout streaming,
  stderr draining, completion exit codes, resume and fork behavior, process
  list/get/kill/writeInput/killAll/prune lifecycle controls, and injected
  fakes for tests.
- `src/auth/token-manager.ts`, `src/auth/token-manager.test.ts`,
  `src/auth/types.ts`, and GraphQL token handlers define auth parity:
  persistent `tokens.json`, raw `id.secret` token creation and verification,
  SHA-256 secret hashes, timing-safe verification, metadata without exposing
  secrets, permission normalization, wildcard permission matching, expiry,
  revocation, rotation, and atomic save behavior.
- `src/queue/repository.test.ts`, `src/group/repository.test.ts`,
  `src/bookmark/manager.test.ts`, `src/file-changes/*.test.ts`,
  `src/session/*.test.ts`, `src/rollout/*.test.ts`,
  `src/markdown/parser.test.ts`, and `src/sdk/usage-stats.test.ts` remain the
  coverage backstop for the unblocked feature categories named by the parent
  adversarial review.

Behavior decisions:

- `Sources/CodexAgent/CodexOperations.swift` must not return generic
  `{"accepted": true}` placeholders for supported GraphQL commands. Supported
  command names execute against the same Swift operational stores, session
  index, file-change index, token manager, and process/session runners used by
  CLI compatibility surfaces; invalid inputs fail before persistence.
- GraphQL command shorthand must preserve the legacy query/mutation/subscription
  normalization. Mutating commands are mutations, `session.watch` is the only
  subscription, explicit GraphQL documents stay unchanged, `--param` values and
  variable files become object variables, and non-object variables are rejected.
- `session.run`, `session.resume`, and `session.fork` are execution boundaries,
  not argv-preview helpers. Production defaults use the real process/session
  runner; tests may inject fake executables or runners to prove argv, cwd,
  environment, stdout JSONL, stderr, exit-code, kill, and stdin behavior without
  requiring a live Codex install.
- `CodexProcessManager` defaults to Foundation `Process` execution. The runner
  remains injectable, but the no-op executor is test-only and must not be the
  production default. Process records reflect actual process identifiers where
  available, terminal exit status, killed state, input writes, and pruned
  completed records.
- `CodexTokenManager` stores legacy-compatible records in `tokens.json` under
  the configured CodexAgent config directory. Public token values use
  `id.secret`; list operations return metadata only; verify accepts only raw
  tokens, checks revocation and expiry, validates requested permissions, and
  avoids leaking secrets through GraphQL or test-visible diagnostics.
- Cursor-specific behavior remains isolated behind `CursorCLIAgent` and
  official SDK behavior remains under `RielaAdapters`; this CodexAgent fix must
  not add Cursor CLI, official Cursor SDK, workflow publication, communication
  id, or runtime message behavior to the CodexAgent module.

Validation and rollout constraints:

- The 30-file legacy CodexAgent test matrix in
  `Tests/CodexAgentTests/CodexAgentCompatibilityTests.swift` remains explicit
  and must map every referenced legacy test file to at least one Swift parity
  assertion.
- New or updated tests must cover the three blocking findings directly:
  GraphQL command execution for operational stores and sessions, default
  process manager execution through a fake executable, and persistent raw-token
  compatibility.
- Focused verification must include:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter CodexAgentTests`
  and
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --filter AgentAdapterTests`.
  Full `swift test` should run when feasible and any blocker must be reported
  explicitly.
- Scratch evidence, wrapper scripts, logs, or temporary JSON for this pass must
  live under repository-root `tmp/`; do not commit scratch artifacts, do not
  stage changes, and do not push from this workflow node.

## Cursor CLI Agent Standalone Compatibility Review Design

This issue-resolution pass reviews the completed Swift migration of the legacy
Cursor `cursor-agent` / `cursor-cli-agent` standalone surface into Riela. The
review is bounded to Cursor compatibility behavior in `Sources/CursorCLIAgent`,
`Sources/CursorCLIAgentCLI`, `Package.swift`,
`Tests/CursorCLIAgentTests/CursorCLIAgentCompatibilityTests.swift`, the active
implementation plan, and deletion-readiness evidence. It must not move
Cursor-specific behavior into `RielaCore`, `RielaAdapters`, CodexAgent,
ClaudeCodeAgent, GraphQL manager control, event sources, server code, or the
`official/cursor-sdk` adapter boundary.

Reference mapping:

- Step 1 supplied the review subject rather than a GitHub issue. The active
  issue reference is
  `impl-plans/active/cursor-cli-agent-swift-migration.md`.
- The default `../../codex-agent` root is unavailable from this checkout. The
  local references used for this pass are `../cursor-agent` for legacy Cursor
  behavior and `../codex-agent` only for the shared standalone compatibility
  pattern that the Cursor facade mirrors without inheriting Codex-specific
  behavior.
- `../cursor-agent/src/config/paths.ts` defines the Cursor storage roots and
  environment overrides: `CURSOR_CLI_AGENT_DATA_DIR`,
  `CURSOR_CLI_AGENT_CONFIG_DIR`, `CURSOR_CLI_AGENT_CURSOR_HOME`, default
  `~/.local/share/cursor-cli-agent`, default `~/.config/cursor-cli-agent`, and
  default `~/.cursor`.
- `../cursor-agent/src/auth/token-manager.ts` and
  `../cursor-agent/src/persistence/token-store.ts` define token compatibility:
  `tokens.json`, raw `<uuid>.<base64url-secret>` tokens, SHA-256 hex
  `tokenHash`, metadata-only listing, expiry, revocation, rotation, and
  timing-safe verification.
- `../cursor-agent/src/cursor/process-runner.ts` defines Cursor process parity:
  `cursor-agent --print --output-format stream-json`, optional `--model`,
  `--mode`, sandbox/trust/yolo/worktree/image flags, prompt after `--`, resume
  with `--resume`, and explicit environment forwarding.
- `../cursor-agent/src/persistence/session-index.ts` defines transcript
  discovery and session identity: Cursor projects under
  `.cursor/projects/<workspace-slug>/agent-transcripts`, recursive JSONL
  transcript import, local session id / Cursor chat id / record id resolution,
  workspace filtering, and SQLite-backed session lookup.
- `../cursor-agent/src/compat/commands.ts`,
  `../cursor-agent/src/compat/dispatcher.ts`, and
  `../cursor-agent/src/compat/permissions.ts` define the compatibility command,
  GraphQL, and permission surface for session, group, queue, bookmark, files,
  activity, skill, token, server, daemon, usage, markdown, repo, model, and
  version commands.
- `../cursor-agent/src/cursor/activity-signals.ts`,
  `../cursor-agent/src/persistence/activity-store.ts`, rollout/session readers,
  queue/group/bookmark stores, markdown parsing, usage, and tool-version files
  remain supporting references for the test matrix categories listed in
  `Tests/CursorCLIAgentTests/CursorCLIAgentCompatibilityTests.swift`.

Issue-to-design mapping:

- Executable product parity maps to `Package.swift` declaring the
  `cursor-cli-agent` executable product and `Sources/CursorCLIAgentCLI` acting
  as a thin entry point into the Cursor compatibility facade.
- Standalone facade parity maps to `CursorCLIAgent` owning the CLI application,
  GraphQL executor, command dispatcher, storage types, process/session helpers,
  polling, rollout watching, usage, readiness, and SDK utilities.
- Process argv parity maps to Cursor-owned builders producing the legacy
  headless `cursor-agent` argument shape, sanitizing conflicting user-supplied
  print/input/output-format flags, preserving resume/fork forms where supported,
  and keeping prompt text after `--`.
- Token parity maps to `tokens.json` under the Cursor config root with raw
  `uuid.secret` values returned only at creation/rotation time and persisted
  `tokenHash` values only in storage.
- Storage parity maps to distinct config, data, and Cursor home roots, with env
  overrides taking precedence and legacy per-file queue/group/bookmark/activity
  records still readable and writable when encountered.
- Transcript discovery maps to rollout JSONL, Cursor SQLite state, and legacy
  `.cursor/projects/<workspace-slug>/agent-transcripts` import paths, including
  workspace slug fallbacks when transcript rows do not carry `cwd`.
- GraphQL/CLI coverage maps to deterministic command families for `auth`,
  `activity`, `session`, `group`, `queue`, `bookmark`, `token`, `files`,
  `model`, `skill`, `daemon`, `server`, `usage`, `markdown`, `repo`, `version`,
  and `graphql`; unsupported live-execution commands must fail explicitly
  rather than return placeholder success.
- Permission coverage maps to token-authenticated GraphQL contexts enforcing
  Cursor permissions such as `session:read`, `session:create`,
  `session:cancel`, `group:*`, `queue:*`, `bookmark:*`, `files:*`, and
  `server:read`; token-management commands remain local-operator commands.
- Test parity maps to the explicit Cursor legacy test-category matrix and
  focused assertions for argv shape, process runner injection, token format,
  storage roots, GraphQL aliases/params/errors, auth status, permission
  boundaries, session discovery, queue execution, activity hooks, polling, and
  config readers.

Behavior decisions:

- `cursor-cli-agent` is a Cursor product and must keep the provider/backend
  string `cursor-cli-agent`. It must not expose `codex-agent` names, Codex
  argv, Codex auth roots, or Claude/Codex process/session behavior through the
  Cursor facade.
- The executable entry point should remain intentionally thin. Argument parsing,
  output formatting, storage, GraphQL dispatch, and activity hook handling are
  owned by `CursorCLIAgent`.
- Cursor local stores are compatibility stores, not workflow runtime stores.
  They may serve CLI/GraphQL facade commands, but they must not publish
  workflow messages, allocate workflow communication ids, or decide final
  candidate output paths.
- Cursor session execution and queue execution are explicit process boundaries.
  Production behavior may run `cursor-agent`; tests must use injected fake
  executables or runners and synthetic local files rather than live Cursor
  credentials, network access, or installed Cursor tooling.
- Unsupported or unproven Cursor operations must return explicit unsupported or
  degraded diagnostics. Do not silently alias them to CodexAgent behavior and do
  not treat `official/cursor-sdk` as satisfied by standalone `cursor-cli-agent`
  evidence.

Validation and rollout constraints:

- Focused verification for this review is:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CursorCLIAgentTests`.
- Broader verification before migration acceptance remains:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
  and `git diff --check`.
- `packaging/swift-deletion-readiness-evidence.json` may record Cursor-focused
  evidence, but it must not claim full TypeScript deletion readiness or
  `official/cursor-sdk` readiness from this standalone Cursor pass alone.
- Scratch artifacts for review evidence or ad-hoc command logs must stay under
  repository-root `tmp/` and must not be staged.
