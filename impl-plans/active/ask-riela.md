# Ask Riela: implementation overview and shared contract

**Status**: Ready
**Design Reference**: `design-docs/specs/design-ask-riela-chat.md` (accepted by
step3 in comm-000297), user defaults in `design-docs/user-qa/qa-ask-riela-chat.md`
**Created**: 2026-11-25
**Branch**: `feat/bots-overview`, baseline `6b370139`, `gitPush=false`
**Dispatch manifest**: `impl-plans/active/ask-riela-dispatch.json`

Issue reference: none (no GitHub issue). Scope comes from the workflow input
of `fable-sol-design-and-implement-review-loop-session-4`.

This file is not a dispatchable plan. It holds the rules every plan follows.
Each plan file starts with a JSON block (`planId`, `planPath`, `dependsOn`,
`wave`, `writePaths`, `sharedPaths`, `sharedPathNotes`).

## 1. Plans and waves

| Wave | Plan | Content | Depends on |
| --- | --- | --- | --- |
| W1 | `ask-01-catalog-and-selection` | manifest ids, assistant catalogs from the manifest, `automatic` selectable, `AskModelSelection`, `bot create` warning fix | — |
| W1 | `ask-02-store-tools` | store, limits, context, redaction, read tools, executor, proposed actions with confirm and audit | — |
| W2 | `ask-03-turn-engine` | `AskService`, rounds transport, activity mapping, citations, budgets, cancellation, policy, scripted backend, injection test | 01, 02 |
| W3 | `ask-04-surfaces` | catalog rows, `riela ask`, GraphQL, SDL, host chaining, remote forwarding, example | 03 |
| W4 | `ask-05-mcp-transport` | `mcpServers` on the adapter input, `riela ask tool-server`, `mcp` argv | 04 |
| W4 | `ask-07-web` | panel, picker, streaming, links, cards, view wiring, editor switch, settings UI | 04 |
| W5 | `ask-06-workflow-authoring` | `propose_workflow`, apply on confirm, removal of the generation routes and stores | 05 |

Why this shape:

- Plans 03 to 06 all write `Sources/RielaCLI/Ask`, and 04 to 06 write the
  hand-maintained registries (`SurfaceCatalog+Rows*.swift`,
  `CLISurfaceEnumeration.swift`, `RielaCLIApplication.swift`,
  `GraphQLSchemaGenerator.swift`, the generated SDL). They are a chain.
- Plans 01 and 02 share no file: 01 owns `Sources/RielaCLI/Ask/Selection`,
  02 owns `Sources/RielaCLI/Ask/Tools`, `Sources/RielaCLI/Ask/Actions` and
  `Sources/RielaCore/Ask`.
- Plan 07 writes only `web/src`; no Swift plan writes there after plan 01.
- If the run stops early, accepted waves are complete: after W3 the chat
  works on CLI and GraphQL with the `rounds` transport on every backend.

## 2. Rules for every plan

1. Read the design sections named in the plan before editing. The design wins
   over this file; this file wins over guesses. Do not redesign. A gap that
   needs a design change is reported in the progress log as `BLOCKED: design`
   with the section number.
2. Edit only the plan's `writePaths`. A directory path means every file in
   it. New Swift files go into the directories the plan names (SwiftPM
   compiles target subdirectories recursively).
3. Do not change `Package.resolved`, `VERSION`, anything under `.build/`,
   `Packages/RielaMemory`, dependency pins, `web/package.json` or
   `web/bun.lock`. Only plan 01 may edit `Package.swift`, and only the
   `resources:` line of the `RielaAppSupport` target.
4. No worktrees, no branches, no `git stash`, no `git commit`, no push. Work
   in the shared working directory in the foreground.
5. Before each edit of an existing file: read it fresh and record its SHA-256
   (`shasum -a 256 <path>`) and the intended change in
   `tmp/ask-riela/<planId>/edit-intentions.md`. After the edit record the new
   hash. If the pre-edit hash differs from the last hash you recorded for that
   file, another worker changed it: re-read, re-apply only your intended
   change, and note `drift` in the progress log. Never revert someone else's
   lines.
6. A compile error inside a path owned by a sibling plan of the same wave is
   logged as `outOfScope` in the progress log; rerun after the sibling's build
   is green. Never fix it yourself.
7. If a required edit is in a file that is neither listed nor under a listed
   directory, do not edit it: record `BLOCKED: write scope` in the progress
   log with the exact path, symbol and reason, and finish the rest of the
   plan first.
8. Scratch files and logs go under `tmp/ask-riela/<planId>/` only.
9. Tests never touch `~/.riela`, the real credential directory or a live
   model vendor. Every test creates a temporary directory and passes it as
   session store root, registry root, profile root and credential dir. Model
   calls use an injected `NodeAdapter`.
10. Swift commands are wrapped: `arch -arm64 /bin/zsh -lc '<command>'`. Run
    them in the foreground, keep the full log, record the exit code.
11. Error codes named in a plan (for example `ask_turn_running`) are exact
    strings. They appear in the thrown error's `code`, in GraphQL
    `extensions.code` and in CLI stderr.
12. User-visible text: "Ask Riela", English only, short. Family name `ask`.
13. No backward-compatibility shim, no unused code path, no feature flag
    other than the two environment variables the design names
    (`RIELA_ASK_TOOL_TRANSPORT`, `RIELA_ASK_SCRIPTED_BACKEND`).
14. Progress log: each plan writes `impl-plans/progress/<planId>.md` with
    sections `Implemented`, `Per-edit hashes` (path, pre, post, or a pointer
    to the file under `tmp/ask-riela/<planId>/`), `Verification` (command,
    exit code, log path, the test count line), `Deviations`, `Open items`. A
    plan is not done until the log exists.

## 3. Shared contracts

Later plans rely on these exact names. A later plan reads the code its
dependency wrote; the names below are fixed so plan text stays consistent.

### 3.1 `Sources/RielaCore/Ask/` (plan 02)

All types `public`, `Codable`, `Equatable`, `Sendable`. Timestamps use the
representation `BotRecord` uses.

- `AskContextKind`: `none`, `session`, `bot`, `workflow`. `AskContext { kind, id: String? }`.
- `AskSelection { vendor: String?, providerInstanceId: String?, model: String?, effort: String? }`.
- `AskToolTransport`: `mcp`, `rounds`. `AskTurnStatus`: `running`, `completed`, `failed`, `cancelled`.
- `AskTurn { turnId, status, startedAt, finishedAt?, backend, providerInstanceId, model, toolTransport, limitedPolicy: Bool, error: AskTurnError?, runnerId, heartbeatAt }`, `AskTurnError { code, message }`.
- `AskUsage { turns, toolCalls, toolBytes }`.
- `AskConversation { conversationId, title, context, selection, turn: AskTurn?, usage, createdAt, updatedAt }`.
- `AskRefKind`: `session`, `step`, `bot`, `workflow`, `routine`. `AskRef { kind, id, sessionId: String? }`.
- `AskMessage { seq, role, text, turnId, citations: [AskRef], truncated: Bool, createdAt }`, role `user` or `assistant`.
- `AskActionKind`: `stopSession`, `rerunSession`, `answerBotRequest`, `setBotPaused` (plan 06 adds `applyWorkflow`).
- `AskActionStatus`: `proposed`, `confirming`, `confirmed`, `failed`, `dismissed`.
- `AskAction { actionId, conversationId, turnId, kind, target: JSONObject, reason, status, createdAt, expiresAt, decidedAt?, decision?, decidedBy?, result: AskActionResult? }`, `AskActionResult { ok, summary?, ids: [String], code?, message? }`.
- `AskLimits` with the values of design §4 and `AskLimits.standard`.
- `AskError { code, message }` (`Error`).
- `AskToolDescriptor { name, kind: read|propose, arguments: [AskToolArgument] }`, `AskToolSet.all`, `AskToolResult { ok, data: JSONValue?, error: AskToolFailure?, refs: [AskRef], truncated }`.
- Activity key: `AskActivityKey.sessionId(conversationId) == "ask:<conversationId>"`.
- Store: `extension BotStore` in `AskStore.swift`; tables from `AskStoreSchema.prepare(in:)`.

### 3.2 `Sources/RielaCLI/Ask/` (plans 01, 02, 03)

- `AskModelSelection.resolve(settings:selection:catalog:environment:) throws -> AskResolvedModel` (plan 01), `AskResolvedModel { vendor, backend: NodeExecutionBackend, providerInstanceId, model: String?, effort: String?, providerName?, providerProxy?, apiKeyEnvironment?, warnings: [String] }`.
- `protocol AskReadSurface` (one async function per read tool), `AskToolExecutor`, `AskRedaction`, `protocol AskMutationSurface`, `AskActionService` (plan 02).
- `AskService`, `AskRuntime`, `AskAgentPolicy`, `AskSendRequest { conversationId?, message, context?, selection?, draftDefinition: JSONObject? }`, `AskConversationSnapshot { conversation, messages, actions, limits, warnings }` (plan 03).

### 3.3 GraphQL (plan 04; plan 07 reads the generated SDL)

- Queries: `askConversations(remote)`, `askConversation(conversationId, remote)`, `askActivity(conversationId, afterSequence, limit, waitMs, remote)`.
- Mutations: `startAsk(input: StartAskInput!)`, `sendAskMessage(input: SendAskMessageInput!)`, `cancelAsk(input: AskConversationInput!)`, `confirmAskAction(input: AskActionInput!)`, `dismissAskAction(input: AskActionInput!)`, `removeAskConversation(input: AskConversationInput!)`.
- Payloads: `AskConversationPayload { conversation, messages, actions, limits, warnings, origin }`, `AskConversationListPayload { conversations, origin }`, `AskActivityPage` (the fields of `BotActivityPage` with `turnStatus` in place of `sessionStatus`).
- `applyWorkflow` action target (plan 06): `{ mode: "draft" | "store", definition, workflowId, baseWorkflowId?, expectedDefinitionRevision? }`.

### 3.4 Plan-level refinements of the design (no behaviour change)

- Design §13 leaves the row split open. Decision: `ask.send` binds CLI `ask`
  and `Mutation.startAsk`; `ask.reply` binds `Mutation.sendAskMessage` with
  the CLI surface excluded ("`riela ask --conversation` uses the ask
  command"); `ask.activity` (stream) binds `Query.askActivity` with the CLI
  surface excluded ("`riela ask` and `riela ask show --follow` read it").
- Confirm, dismiss and the audit row are built in plan 02 next to the action
  store (design §16 lists them under plan 04); plan 04 only exposes them.
- The scripted backend (`RIELA_ASK_SCRIPTED_BACKEND`) is built in plan 03
  with the engine; plan 04 uses it in the example.
- The vendor → backend map moves to `RielaAppSupport`
  (`RielaAppAssistantVendor.executionBackend`) so the assistant model catalog
  can be computed from `ModelManifest` there;
  `RielaWebAssistantProvider.backend(for:)` returns that value.
- Plan 03 ships the `rounds` transport for every backend. Plan 05 adds `mcp`
  for codex and claude.
- Refinement of design §5.3 for host parity (plan 05 §3a): the tool-server
  command line gains `--scope <scope>` and `--redaction-values <file>`.
  The server entry's environment carries the host's non-secret `HOME`,
  `RIELA_WORKFLOW_HOME`, `RIELA_*` and `XDG_*` variables. Env-bound secret
  values reach the tool server only through a mode 0600 file under
  `<scratchRoot>/redaction`, removed on every terminal path, so tool
  results and redaction are the same in `rounds` and `mcp` (design §5.1,
  §10.2).
- Amendment 2026-11-25 (blocked-wave-scope-or-contract, round 1, finding
  `ASK-03-CURSOR-API`): Ask Riela does not run on `official/cursor-sdk`. At
  the pinned gateway the Cursor API launches a cloud agent without a
  read-only policy and returns creation metadata, not an answer. A turn that
  resolves to that backend is refused with `ask_provider_unsupported` before
  any write and before the adapter is called (plan 03); the web picker does
  not offer such instances (plan 07). The `rounds` transport therefore covers
  `cursor-cli-agent`, `official/openai-sdk` and `official/anthropic-sdk`,
  plus codex and claude when `mcp` is not used. Design §5.3, §9 and §10.1
  still name `official/cursor-sdk`; the sentences are to be corrected at the
  next design edit. Plans 01 and 02 are accepted (wave 1) and are listed as
  `acceptedDependencies` in the manifest; plan 03 no longer lists them in
  `dependsOn`.
- Amendment 2026-11-25 (blocked-wave-scope-or-contract, round 2, finding
  `ASK-04-LOCAL-NO-FOLLOW-LIFECYCLE`): `riela ask --no-follow` is
  server-backed only. A local turn runs in a task owned by the CLI process
  and ends when the CLI exits, so with a local target `--no-follow` is a
  usage error raised before any write; with a paired remote the server owns
  the turn and the option returns after the turn starts (plan 04). No local
  hand-off or background mode is added. Design §13 lists `--no-follow`
  without this limit; the sentence is to be corrected at the next design
  edit. Plan 03 is accepted (wave 2) and is listed in `acceptedDependencies`;
  plan 04 no longer lists it in `dependsOn`.
- Design §7.3 names a definition audit reason `ask:<conversationId>/<actionId>`.
  The registry mutation inputs have no reason field; the link is kept on
  the confirmed action row (plan 06). The design sentence is to be
  corrected at the next design edit.

## 4. Wave gates (serial reconcile, not per-plan work)

After each wave, on the combined tree, logs under `tmp/ask-riela/gate-W<n>/`:

```
arch -arm64 /bin/zsh -lc 'swift build'
arch -arm64 /bin/zsh -lc 'swift test --filter "<suites of all accepted plans>|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParityWebAPITests|SurfaceParityConsoleReadTests|SurfaceParityLibraryTests|SurfaceParitySkillTests|BotCommandTests|BotsGraphQLTests|BotActivityRuntimeTests|ActivityRecorderTests|ActivityWaitTests|ModelCatalogTests|ModelCatalogCommandTests"'
```

From W4 on also `cd web && bun install --frozen-lockfile && bun run typecheck && bun test src && bun run lint && bun run build`.

## 5. Final gate (after W5, or after the last accepted wave)

```
arch -arm64 /bin/zsh -lc 'swift build'
scripts/surface-parity/generate-sdl.sh
arch -arm64 /bin/zsh -lc 'swift test --filter "Ask|SurfaceCatalogTests|SurfaceParity|Bot|Activity|ModelCatalog|ModelManifest|RielaAppAssistantModelCatalogTests|ConfigurationGraphQLTests|WorkflowEditor|RielaExampleParityTests|RielaAppWebAPIRouteTests|AgentToolPolicy|AgentGatewayNodeAdapterTests|AgentGatewayACPV2Tests|GatewayScriptedAgentTests"'
cd web && bun run typecheck && bun test src && bun run lint && bun run build
```

All exit 0; the SDL file is unchanged by regeneration; `git status` shows no
file outside the union of the plans' `writePaths`.

Manual operator check (design §15, not a gate): one live turn each on codex
and claude with the `mcp` transport.

## 6. Completion criteria

- Every acceptance criterion of the workflow input maps to a passing test or
  to the example walkthrough (`examples/ask-run-status/EXPECTED_RESULTS.md`).
- `grep -rn "workflow-editor/generations" Sources web/src` prints nothing.
- `grep -rn "assistant-models" Sources Package.swift` prints nothing.
- Each plan has a progress log; the final gate is green.
