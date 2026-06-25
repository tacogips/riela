# Riela Swift Native Migration Design: Architecture and Early Slices

## Status

Active migration design for the `swift-migration` branch.

## Goal

Migrate Riela from a TypeScript/Bun runtime into a macOS-native Swift implementation while preserving the existing responsibility split:

- `riela-core` -> `RielaCore`
- `riela-addons` -> `RielaAddons`
- `riela-adapters` -> `RielaAdapters`
- `riela-events` -> `RielaEvents`
- `riela-graphql` -> `RielaGraphQL`
- `riela-server` -> `RielaServer`
- `riela-hook` -> `RielaHook`
- `riela` CLI/runtime -> `RielaCLI`
- external agent packages `codex-agent`, `claude-code-agent`, and `cursor-cli-agent` -> first-class Swift targets `CodexAgent`, `ClaudeCodeAgent`, and `CursorCLIAgent`

The initial migration is additive. TypeScript remains in place until the Swift targets reach feature parity and the packaging/release path can switch safely.

## Architecture

The Swift package is rooted at repository top level with one SwiftPM target per existing package boundary. Cross-target dependencies point inward:

- `RielaCore` owns JSON boundary types, authored workflow model types, backend identifiers, adapter contracts, and validation-independent helpers.
- `RielaAdapters` owns dispatching, retry, shared prompt construction, local process execution, and official SDK adapter infrastructure.
- `CodexAgent`, `ClaudeCodeAgent`, and `CursorCLIAgent` own backend-specific local agent command integration.
- `RielaAddons`, `RielaEvents`, `RielaGraphQL`, `RielaServer`, and `RielaHook` stay separate so migration can proceed by package without collapsing responsibilities.
- `RielaCLI` is the executable target and should become the only command-line entry point after parity.

The migration must keep the Swift package additive until parity gates pass. The TypeScript/Bun packages remain the production runtime during the migration, and Swift targets should be allowed to depend on fixture data and contract definitions from the existing repository, not on private runtime state.

## Runtime Contracts To Preserve

- Execution backend strings remain stable: `codex-agent`, `claude-code-agent`, `cursor-cli-agent`, `official/openai-sdk`, `official/anthropic-sdk`, and `official/cursor-sdk`.
- Authored workflows remain step-addressed and file-backed.
- Add-on nodes stay declarative and isolated from runtime engine internals.
- Agent adapters return a normalized provider/model/prompt/completion/payload envelope.
- Hook context keeps `agentSessionId` and optional backend metadata.
- Existing workflow package, event source, GraphQL manager-control, and session inspection surfaces remain compatibility targets for parity tests.
- Runtime output publication remains runtime-owned. Swift adapters may parse provider output into a normalized envelope, but final workflow message delivery, candidate-path handling, and output validation belong to the workflow engine boundary.
- Runtime session and workflow message APIs remain runtime-owned. Swift adapters, command executors, and add-ons may return candidate output only; they must not allocate communication ids, mutate session state, publish downstream messages, or learn the final `output.json` destination.
- External process execution remains explicit and injectable. Backend adapters construct argv arrays directly, avoid shell interpolation, redact credentials from failures, enforce deadlines, and expose deterministic runner injection for tests.

## Reference Mapping

Step 1 intake selected a single-path workflow because this migration is dependency-coupled across core models, adapter contracts, agent targets, package behavior, and CLI/runtime parity. It also marked the change high risk and requiring adversarial review because it touches runtime migration, external command execution, package behavior, and release cutover.

Step 1 intake established `<rielflow-checkout>` as the
reference repository root for this workflow pass. The default `../../codex-agent`
root is not the active reference for this deletion-readiness run. The current
TypeScript adapters, pinned package dependencies, and the Step 1 Codex reference
files are the authoritative references:

- `packages/riela-adapters/src/codex.ts` and `packages/riela-adapters/src/readiness.ts` define current `codex-agent` adapter execution, auth/readiness probes, output normalization, and failure mapping.
- `packages/riela-adapters/src/claude.ts` and `packages/riela-adapters/src/readiness.ts` define current `claude-code-agent` execution, auth/readiness probes, session handling, and failure mapping.
- `packages/riela-adapters/src/cursor.ts` and `packages/riela-adapters/src/readiness.ts` define current `cursor-cli-agent` behavior through the Cursor adapter SDK boundary.
- `packages/riela-adapters/src/dispatch.ts`, `packages/riela-adapters/src/shared.ts`, `packages/riela-adapters/src/openai-sdk.ts`, and `packages/riela-adapters/src/anthropic-sdk.ts` define current official SDK dispatch, API-key lookup, retry/error handling, timeout behavior, request construction, response text extraction, and output-envelope normalization.
- `packages/riela-core/src/render.ts`, `packages/riela-core/src/prompt-template-context.ts`, `packages/riela-core/src/prompt-template-file.ts`, `packages/riela-core/src/node-template-fields.ts`, `packages/riela/src/workflow/load.ts`, and `packages/riela/src/workflow/prompt-composition.ts` define current prompt rendering, prompt variable roots, template-file safety, asset loading, and composed prompt behavior.
- `packages/riela/src/workflow/adapter.ts`, `packages/riela/src/workflow/output-attempt-runner.ts`, and `packages/riela/src/workflow/engine/step-result-finalization.ts` define current JSON candidate extraction, output-contract retry/finalization, and runtime-owned publication behavior.
- `packages/riela-adapters/package.json` pins repository-owned references for `codex-agent`, `claude-code-agent`, and `cursor-cli-agent`; Swift target behavior should be mapped from those package contracts, not copied blindly.
- `<rielflow-checkout>/packages/rielflow/src/workflow/adapters/codex.test.ts`
  is the `codex-agent` behavioral reference for command construction,
  authentication failure handling, output normalization, and redaction.
- `<rielflow-checkout>/packages/rielflow/src/workflow/adapters/claude.test.ts`
  is the `claude-code-agent` behavioral reference for command construction,
  readiness/auth behavior, session handling, and redaction.
- `<rielflow-checkout>/packages/rielflow/src/workflow/adapters/cursor.test.ts`
  is the `cursor-cli-agent` behavioral reference for Cursor CLI command
  construction, model/mode behavior, stream handling, auth classification, and
  redaction.
- `<rielflow-checkout>/packages/rielflow/src/workflow/runtime-readiness-agent-probes.ts`
  is the shared `codex-agent` and `cursor-cli-agent` structural reference for
  tool summaries, auth status separation, model-probe results, and runtime
  readiness verification framing.

Swift target mapping:

- `CodexAgent` maps the `codex-agent` backend only. It owns Codex CLI/session integration, Codex-specific readiness, and Codex-specific output normalization helpers that are not shared with other providers.
- `ClaudeCodeAgent` maps the `claude-code-agent` backend only. It owns Claude CLI/session integration and any Claude-specific auth/readiness behavior.
- `CursorCLIAgent` maps the `cursor-cli-agent` backend only. Cursor-specific modes, stream formats, readiness probes, and SDK compatibility must stay inside this target or a Cursor-specific adapter module.
- `RielaAdapters` owns provider-neutral adapter contracts, dispatch, retry, prompt preparation, injected subprocess runners, deadline handling, output-envelope parsing, error categories, and the official OpenAI and Anthropic SDK adapter implementations.

Intentional divergence from the reference behavior is allowed only at the adapter boundary and must be documented in this file or the implementation plan. The current accepted divergence is structural: Swift splits the three repository-owned agent integrations into independent SwiftPM targets instead of importing npm packages, while preserving backend strings and normalized adapter envelopes.

## Local Agent Command Builder And Readiness Parity Slice

The completed TASK-004 local-agent slice replaces the generic Swift subprocess argv builder with backend-specific command builders for `codex-agent`, `claude-code-agent`, and `cursor-cli-agent`. The shared `RielaAdapters` boundary defines the injectable process runner, command-builder protocol, deadline/error normalization, redaction, descriptor isolation, image-path resolution, and normalized output handling. Backend-specific targets own the command shape, optional flags, auth/model preflight, stream normalization, and readiness interpretation.

Command-builder requirements:

- `CodexAgent` owns Codex command construction. It must preserve provider `codex-agent`, use the Codex model from the node payload, keep Codex-only reasoning-effort and additional-argument handling inside the Codex target, and continue normalizing `codex exec --json` JSONL into final assistant text before output-contract parsing.
- `ClaudeCodeAgent` owns Claude Code command construction. It must preserve provider `claude-code-agent`, map working directory, model, effort, permission/plan mode, attachments or image path behavior only where Swift input contracts support them, and keep Claude-specific auth status checks in the Claude target.
- `CursorCLIAgent` owns Cursor CLI command construction. It must preserve provider `cursor-cli-agent`, keep Cursor mode and stream-mode options inside the Cursor target, and must not expose Cursor CLI concepts through `RielaCore`, shared adapter dispatch, add-ons, GraphQL, events, server code, or the `official/cursor-sdk` backend.
- The old generic shape of `executableName + baseArguments + --model` is not a sufficient parity boundary. Shared code may execute a prepared `LocalAgentProcessConfiguration`, but it must not infer backend-specific argv beyond provider-neutral process execution concerns.
- Tests assert the exact executable, argv, environment overlay, working directory, stdin prompt behavior, provider string, output-contract handling, deadline propagation, descriptor isolation, and stderr/configured-secret redaction through injected process runners.

Readiness parity requirements:

- Swift readiness APIs should model the TypeScript categories from `packages/riela-adapters/src/readiness.ts`: `available`, `unavailable`, `unknown`, and `not_checked` for tools, auth probes, and model reachability.
- Auth and policy-blocked adapter failures should preserve current behavior: failed Codex login, unavailable Claude CLI/auth, and unavailable Cursor CLI/auth/model probes become `policy_blocked` at adapter preflight time, while runtime-readiness validation reports deterministic invalid or unknown results without running a workflow.
- Runtime-readiness probing should map the behavior from `packages/riela/src/workflow/runtime-readiness-agent-probes.ts`: tool summaries for Codex, Git, Claude, and Cursor; source step ids; model-specific reachability messages; Codex account readiness; Claude auth/model checks; and Cursor's explicit unknown auth result when no stable local auth-status command exists.
- Probe operations are injectable and deterministic in tests. Unit tests must not require live local CLI tools, network access, repository-owned npm package installs, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `CURSOR_API_KEY`.
- Credential-bearing stdout, stderr, thrown errors, and probe details must pass through the existing adapter redaction policy before becoming test-visible or user-visible diagnostics.

## Official SDK Adapter Parity Slice

The completed TASK-004 official SDK slice ports `official/openai-sdk` and `official/anthropic-sdk` only. Both backends remain provider-neutral official SDK adapters under `RielaAdapters`; they must not be implemented in, or create dependencies from, `CodexAgent`, `ClaudeCodeAgent`, or `CursorCLIAgent`.

Dispatch requirements:

- `DispatchingNodeAdapter` must offer default Swift adapter factories for `NodeExecutionBackend.officialOpenAISDK` and `NodeExecutionBackend.officialAnthropicSDK`.
- Public backend strings remain `official/openai-sdk` and `official/anthropic-sdk`.
- The existing `official/cursor-sdk` enum case and authored backend string remain recognized, but its adapter implementation stays explicitly deferred unless a later, separately reviewed slice scopes it.
- Tests must prove both registered official SDK backends resolve without live credentials when injected clients or request executors are supplied, and that an intentionally missing registry entry still fails deterministically.

OpenAI parity:

- Build a Responses request with `model: input.node.model`, `input: input.promptText`, and optional system instructions from `input.systemPromptText`.
- Resolve credentials from configured `apiKeyEnv` or `OPENAI_API_KEY`; missing credentials are `policy_blocked`.
- Preserve optional base URL propagation, bounded retry defaults, retry delay clamping, context deadline/abort handling, provider-error normalization, and credential redaction in failure surfaces.
- Extract response text from `output_text` first, then from `output[].content[]` entries with `type: "output_text"`, joined by newline.
- Return provider `official-openai-sdk` and normalize text payloads or output-contract envelopes through the shared adapter envelope rules.

Anthropic parity:

- Build a Messages request with `model: input.node.model`, default `max_tokens: 1024` clamped to at least `1`, optional system text from `input.systemPromptText`, and one user message from `input.promptText`.
- Resolve credentials from configured `apiKeyEnv` or `ANTHROPIC_API_KEY`; missing credentials are `policy_blocked`.
- Preserve optional base URL propagation, bounded retry defaults, retry delay clamping, context deadline/abort handling, provider-error normalization, and credential redaction in failure surfaces.
- Extract response text from `content[]` entries with `type: "text"`, joined by newline.
- Return provider `official-anthropic-sdk` and normalize text payloads or output-contract envelopes through the shared adapter envelope rules.

Testing constraints:

- Official SDK tests use injected clients, client factories, or request executors with synthetic responses only.
- Tests must not require `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `CURSOR_API_KEY`, network access, or live SDK calls.
- Deterministic coverage must include request shape, configured API-key environment names, base URL forwarding, retry/error normalization, timeout handling, response text extraction, output-envelope normalization, and credential redaction.

## Cursor CLI Behavior Boundary

Cursor CLI behavior must remain isolated behind `CursorCLIAgent` and Cursor-specific readiness helpers. No `Cursor`-specific mode, stream normalization, binary probe, auth probe, or SDK compatibility assumption should leak into `RielaCore`, provider-neutral `RielaAdapters`, add-on validation, GraphQL, events, or server targets.

The Swift migration should preserve these Cursor contracts:

- backend string: `cursor-cli-agent`
- default executable lookup remains backend-owned, not core-owned
- prompt construction uses the shared adapter prompt preparation contract before entering Cursor-specific execution
- Cursor mode and stream-mode options are Cursor adapter configuration, not workflow engine concepts
- provider responses normalize into the same `AdapterExecutionOutput` envelope used by Codex and Claude
- readiness checks report unavailable tools, auth failures, model reachability, and policy-blocked states without requiring live workflow execution

The `official/cursor-sdk` backend is a separate official SDK adapter and must not be conflated with `cursor-cli-agent`. Any Swift port of `official/cursor-sdk` should be a later, separately gated adapter slice unless implementation parity requires a minimal compatibility shim.

## v0.1.17 Cursor CLI Goal Parity Slice

This slice closes accepted adversarial-review gaps for GitHub issue #63 only where they fit the additive Swift migration parity boundary. It does not declare the Swift migration complete, does not change backend strings, and does not move Cursor-specific behavior outside `CursorCLIAgent` or the TypeScript Cursor adapter.

Reference inputs:

- GitHub issue #63: `cursor-cli-goal` auth preflight probes unresolved `gpt-5.5`, auth failures are reported as model failures, and user-scope session resume can miss the extended `codex-goal` base workflow.
- The historical Step 1 Codex reference root for this slice was unavailable in
  the checkout; the current deletion-readiness pass uses the concrete
  `<rielflow-checkout>` reference files listed in Reference
  Mapping instead of placeholder local-reference paths.
- The historical Cursor CLI agent reference for this slice was reference-only.
  Current Cursor CLI planning uses
  `<rielflow-checkout>/packages/rielflow/src/workflow/adapters/cursor.test.ts`
  and
  `<rielflow-checkout>/packages/rielflow/src/workflow/runtime-readiness-agent-probes.ts`
  for Cursor command, model, auth, and readiness behavior.
- Riela parity sources are `packages/riela-adapters/src/cursor.ts`, `packages/riela/src/workflow/adapters/cursor.test.ts`, `packages/riela/src/workflow/adapter.ts`, `Sources/CursorCLIAgent/`, `Sources/RielaCore/AdapterContracts.swift`, `scripts/verify-and-update-v017-parity.sh`, `impl-plans/PROGRESS.json`, and `packaging/homebrew/swift-cutover-gates.json`.

Issue-to-design mapping:

- The unresolved `gpt-5.5` preflight gap maps to shared TypeScript and Swift Cursor model resolution, with execution and preflight using the same resolved slug.
- The auth-versus-model diagnostic gap maps to Cursor-specific probe classification that reports auth-like failures before generic model reachability failures.
- The goal-review routing gap maps to provider-neutral output-envelope reconciliation before transition selection.
- The feasible session-resume gap maps only to preserving the original user workflow scope for user-scope `cursor-cli-goal` sessions that extend user-scope `codex-goal`.
- The verification-metadata gap maps to `scripts/verify-and-update-v017-parity.sh` treating `.verify-results.txt` with `OVERALL_EXIT_CODE: 0` as the metadata update gate.

Cursor model and effort decisions:

- TypeScript execution, TypeScript auth/model preflight, Swift command construction, and Swift auth/model preflight must resolve the Cursor model through the same `gpt-5.5` effort rule before invoking or probing Cursor CLI.
- For `gpt-5.5` family models, Riela resolves `effort` into the Cursor model id itself: `low` -> `gpt-5.5-low`, `medium` -> `gpt-5.5-medium`, `high` -> `gpt-5.5-high`, and `xhigh` -> `gpt-5.5-extra-high`, preserving a trailing `-fast` suffix when present. This is an intentional adapter-level divergence from the dependency-owned generic effort helper because issue #63 shows the Cursor model availability surface can reject the unresolved bare workflow model.
- Composer-family models continue to suppress Cursor effort forwarding and model suffix mutation. Other non-Composer models may continue using the Cursor SDK-owned `effort` field when the adapter supports it.
- User-visible diagnostics for this slice should report the resolved model slug that was actually probed or executed. Auth-like probe output must be classified as `cursor-cli-agent authentication is unavailable` before falling back to a model reachability message.

Goal-review and session decisions:

- `goal-review` output routing must reconcile business payloads with transition conditions. A payload declaring `goalAchieved: false`, `decision: "needs_work"`, or equivalent `needs_work` state routes to the work path even if the envelope emitted `when.always`.
- The feasible issue #63 session-resume fix is scoped to preserving the original workflow resolution scope for user-scope sessions whose workflow extends another user-scope workflow, such as `cursor-cli-goal` extending `codex-goal`. Broader cross-scope migration behavior remains outside this parity slice.

Verification and rollout decisions:

- `scripts/verify-and-update-v017-parity.sh` is the authoritative green gate for this slice. It must run the Xcode-SDK Swift checks, targeted TypeScript tests, JSON validity checks, and write `.verify-results.txt` with `OVERALL_EXIT_CODE: 0` before metadata in `impl-plans/PROGRESS.json` or `packaging/homebrew/swift-cutover-gates.json` is treated as current.
- `packaging/homebrew/swift-cutover-gates.json` and `impl-plans/PROGRESS.json` must describe the verified parity slice honestly. They must not imply every Swift migration gate or every issue #63 behavior is complete unless the corresponding command output is present.
- Verification commands for this slice are `bash scripts/verify-and-update-v017-parity.sh`, `bash .verify-run.sh`, targeted `bun test packages/riela/src/workflow/adapters/cursor.test.ts`, targeted `bun test packages/riela/src/workflow/adapter.test.ts`, and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test`.

## TASK-002/TASK-003 Prompt, JSON, And Envelope Prerequisite Closure

This prerequisite slice closes the remaining Swift migration blockers before
TASK-009. TASK-002 is implementation-complete for the current Swift model and
validation scaffold, but the active implementation plan must record fresh
Swift-capable verification evidence before marking it complete. TASK-003 remains
open until prompt rendering fixtures, prompt asset loading, escaped and missing
variable behavior, and output-envelope normalization are all covered by
deterministic Swift tests.

Prompt rendering contracts:

- Swift prompt rendering must match the TypeScript `renderPromptTemplate`
  behavior for `{{ path }}` placeholders using dotted object traversal.
- Missing, undefined, null, or non-traversable paths render as an empty string.
- String values render unchanged; booleans and numbers render as scalar text;
  object and array values render as compact JSON.
- Unmatched text and unsupported placeholder syntax remain literal text.
- Tests must include literal brace text, backslash-escaped JSON string content,
  multiple placeholders, dotted paths, object and array substitutions, falsey
  scalar values, missing variables, and null values.

Prompt asset loading contracts:

- The supported template-file fields are `systemPromptTemplateFile`,
  `promptTemplateFile`, and `sessionStartPromptTemplateFile` on node payloads and
  prompt variants.
- Template-file paths are workflow-relative only. Empty paths, absolute paths,
  `.` or `..` segments, traversal above the workflow root, and canonical
  workflow definition targets such as `workflow.json` or `node-*.json` fail
  deterministically.
- Loading a template file populates the corresponding inline template field for
  execution while preserving authored file references for save and validation
  workflows.
- Missing or unreadable template files fail during workflow loading or
  validation with field-specific diagnostics; tests must not depend on external
  package installation or live runtime state.

Output-envelope normalization contracts:

- Adapter and SDK output may be plain text when no node output contract is
  present; JSON-looking text must stay a text payload in that case.
- When a node output contract is present, provider text must yield a JSON object
  candidate or fail with `invalid_output`.
- A candidate object with `when` is an output-contract envelope. `when` must be
  an object of booleans, `payload` must be an object, and `completionPassed`
  must be a boolean when supplied. Missing `completionPassed` defaults to true.
- A candidate object without `when` is treated as the business payload with the
  default successful routing condition.
- JSON candidate extraction must ignore braces inside quoted strings and escaped
  string characters while finding the first balanced object candidate.
- Runtime-owned publication remains outside backend adapters. Swift adapters
  normalize provider text into adapter output only; candidate-path handling,
  output validation, accepted output artifacts, workflow messages,
  communication ids, and final root output selection remain runtime-owned.

Current verification evidence:

- Xcode Swift toolchain command:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift --version`
- Current result: Apple Swift 6.3.2, target `arm64-apple-macosx26.0`.
- Swift test command:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
- Current parity evidence: `.verify-results.txt` from 2026-06-14 records full
  `swift test` with 289 tests passed, 0 failures, and `OVERALL_EXIT_CODE: 0`.
  TASK-003 must still stay in progress until the prompt and envelope test gaps
  above are implemented and rerun.
