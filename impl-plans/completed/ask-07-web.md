# ask-07-web: Ask panel, picker, streaming, record links, action cards, editor switch, settings UI

```json
{
  "planId": "ask-07-web",
  "planPath": "impl-plans/active/ask-07-web.md",
  "dependsOn": [
    "ask-04-surfaces"
  ],
  "wave": 4,
  "writePaths": [
    "web/src",
    "impl-plans/progress/ask-07-web.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {
      "path": "web/src",
      "intendedEdit": "New directory web/src/ask. Edits in App.tsx (mount), routes.ts only if a helper is needed, profileViewState.ts (panel state), bots/activityStream.ts (reader parameter), bots/BotDetailView.tsx and views/RunDetailView.tsx (Ask button), workflows/WorkflowGraphEditor.tsx (editor switch), views/SettingsView.tsx (assistant section), stylesheets. Delete workflows/WorkflowAgentChat.tsx."
    }
  ]
}
```

Follow `impl-plans/active/ask-riela.md` §2, §3.3. Design: §9 (settings UI),
§11 (editor integration), §12 (origin), §14, §15 (web tests).

## Intent and context

The web console gets one chat panel, reachable from every view, that knows
which run, bot or workflow the user is looking at, streams the answer,
links the records it cites and shows proposed actions as cards to confirm
or dismiss. The workflow editor's own chat is replaced by this panel.

Current code:

- `web/src/App.tsx` renders the routed view; `web/src/routes.ts` defines
  `HashRoute` (`run-detail` with `sessionId` and `remote`, `ops-run`,
  `bot-detail` with `botId` and `remote`, `workflow-detail` with `sourceId`)
  and `viewHash`.
- GraphQL client pattern: `web/src/bots/client.ts` (`BotsClient`, typed
  documents, `remote` variable, error codes), contracts in
  `web/src/bots/contracts.ts`.
- Streaming: `web/src/bots/activityStream.ts:createActivityStream` (25 s
  long-poll, 250 ms idle re-poll, 5 s retry, pause when hidden) and
  `web/src/bots/activityFeed.ts` (`mergeActivityPage`, `nextCursor`,
  `activitySummary`).
- `web/src/components/Markdown.tsx`; remote selection in
  `web/src/bots/remoteSelection.ts` and `RemoteSwitcher.tsx`.
- Editor chat: `web/src/workflows/WorkflowAgentChat.tsx`, mounted in
  `WorkflowGraphEditor.tsx:196` with `onStart`, `onActive`, `onDefinition`.
- Settings: `web/src/views/SettingsView.tsx:171` assistant form; client in
  `web/src/config/client.ts`.
- Server contract from plan 04: overview §3.3 and the generated SDL
  (`Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`, read only).

## Non-goals

- No Swift change, no new dependency, no change to `web/package.json` or
  `web/bun.lock`.
- No new transport: only the existing GraphQL client and long-poll.
- No client-side record content in requests: the panel sends a context
  reference only. The single exception is the editor's unsaved draft.
- No chat history search, export or rename.
- No change to the desktop (Tauri) shell.

## Changes

### 1. Client and contracts (`web/src/ask/`, new)

- `contracts.ts`: TypeScript types for the DTOs of overview §3.3.
- `client.ts`: `AskClient` with `start`, `send`, `cancel`, `list`, `get`,
  `getActivity({ conversationId, afterSequence, waitMs, signal, remote })`,
  `confirm`, `dismiss`, `remove`. Same request helper, error mapping and
  `remote` handling as `BotsClient`.

### 2. Pure logic (`web/src/ask/`, each with a `.test.ts`)

- `context.ts`: `contextFromRoute(route, lookup) -> { context, label, remote? }`.
  `run-detail` and `ops-run` → `{ kind: 'session', id: sessionId }`, label
  `Run <id>`; `bot-detail` → `{ kind: 'bot', id }`, label `Bot <name>` (name
  from `lookup`, else the id); `workflow-detail` → `{ kind: 'workflow', id }`
  with the workflow id of that source, label `Workflow <id>`; others → none.
  `remote` from the route, else the Bots view's selected remote.
- `citations.ts`: `citationHref(ref, remote) -> string | undefined` using
  `viewHash`: session → `run-detail`; step → `run-detail` of its
  `sessionId`; bot → `bot-detail`; workflow → `workflow-detail` when a
  source for that id is known, else undefined; routine → undefined. Remote
  is carried on routes that support it.
  `renderCitations(text, citations) -> string`: replaces each `[[kind:id]]`
  marker that matches an entry of `citations` by a Markdown link; any other
  marker stays as text.
- `actions.ts`: `actionCard(action) -> { title, detail, state, canDecide }`.
  Title from `kind` and typed `target` fields only (for example
  `Stop run <sessionId>`, `Pause bot <botId>`, `Apply workflow <workflowId>`);
  `detail` is `reason`; `canDecide` only for `proposed` and not expired.
- `picker.ts`: state for vendor/model selection: default from
  `configuration.assistant`, options from `modelCatalog` (instances, models,
  efforts when the model lists any), the selection object to send, and the
  "resolved" line from `conversation.turn` (`backend`, `model`,
  `toolTransport`, `limitedPolicy`).
- `panelState.ts`: reducer over `{ snapshot, feed, error, pending }` giving
  the rendered list: stored messages, then for a running turn the live
  items from the feed (message text so far, tool calls with status, plan
  entries, usage), then action cards; `canSend` is false while a turn runs.

### 3. Panel (`web/src/ask/AskPanel.tsx`, `ask.css`)

- Mounted once in `App.tsx`, outside the routed view. Collapsible right
  side panel with a rail button labelled `Ask`. Open state and active
  conversation id persist through `profileViewState.ts` (same storage
  mechanism the file already uses).
- Header: context chip (clearable), origin server name when a remote is
  selected, vendor/model picker, `New` button.
- Body: the list from `panelState`. Assistant text through `Markdown` after
  `renderCitations`. Tool calls as one-line rows. Turn errors and request
  errors (`remote_unreachable`, `ask_vendor_unavailable`, ...) as error
  rows with the code; never a placeholder answer.
- Footer: textarea, `Send`, and `Stop` while a turn runs (calls `cancel`).
- Each send passes the current context and remote; a new conversation is
  started when none is active or the remote changed.
- Streaming: `createActivityStream` gains a reader parameter (a function
  `(cursor, signal) => Promise<page>` plus the status field to read) so it
  can read `askActivity` with `turnStatus`; existing bot callers pass the
  bot reader and behave as before. When the stream ends, the panel reloads
  the conversation once to get the stored message, citations and actions.
- Cards: `Confirm` and `Dismiss` call the mutations and replace the card
  state with the returned action (result summary or error code).

### 4. View wiring

- `bots/BotDetailView.tsx` and `views/RunDetailView.tsx`: an `Ask` button
  that opens the panel with that item as context. The panel is opened
  through a small exported signal or function in `web/src/ask` (no prop
  drilling through `App.tsx` beyond what the file already does).
- `workflows/WorkflowGraphEditor.tsx`: remove the `WorkflowAgentChat` mount
  and import; add an `Ask` button that opens the panel with the workflow as
  context and registers an editor bridge:
  `{ draft: () => definition, apply: (definition) => void }`. While the
  bridge is registered, each send includes `draftDefinition: draft()`.
  `Confirm` on an `applyWorkflow` action whose `target.mode` is `draft`
  calls the mutation, then `apply(target.definition)`, which pushes the
  current document on the undo stack and calls `setDoc` (what `onStart` and
  `onDefinition` did). The bridge is removed when the editor unmounts; a
  draft action confirmed without a bridge shows "Open the workflow editor
  to apply".
- Delete `workflows/WorkflowAgentChat.tsx` and its styles; remove the
  `generating` lock if nothing else sets it.

### 5. Settings (`views/SettingsView.tsx`, `config/client.ts`)

- Vendor select gains `Automatic` (`automatic`). With `Automatic` the model
  select is hidden and no `model` is sent.
- Model options come from `assistant.modelCatalogs` as today.
- A link `Models` to `#/models` next to the model select.

## Imitate

- `web/src/bots/client.ts` and `client.test.ts` for the client and its
  tests (fake fetch, asserted documents and variables).
- `web/src/bots/activityStream.test.ts` for stream tests with the fake
  environment.
- `web/src/bots/BotMemoryPanel.tsx` for a panel with `Markdown` and
  mutations; `web/src/bots/memoryPanel.ts` for pure-logic-plus-test layout.

## Pitfalls

- Links come only from `citations[]`. Do not turn arbitrary `[[...]]` text
  or model-written URLs into navigation.
- The card title must not include model text; `reason` is secondary text
  rendered as plain text.
- Do not send record content (run status, logs, bot data) to the server as
  context.
- Keep the bot activity stream behaviour identical; its tests must pass
  unchanged apart from the new parameter.
- The panel must work when the server has no ask fields (older remote):
  show the error code, do not crash the app shell.
- `bun run lint` runs `scripts/audit-source.ts`; read it before adding files
  and follow its rules.
- English only; short labels (`Ask`, `Send`, `Stop`, `New`, `Confirm`,
  `Dismiss`).

## Tests (`bun test src`)

`ask/context.test.ts`:
- `run-detail` route with remote → session context, label `Run <id>`, that
  remote; `bot-detail` with a known name → `Bot <name>`; `settings` → none.

`ask/citations.test.ts`:
- session ref → the `run-detail` hash; step ref → hash of its session;
  routine ref → undefined.
- text with a cited and an uncited marker → only the cited one becomes a
  link.

`ask/actions.test.ts`:
- `setBotPaused` proposed → title `Pause bot b1`, `canDecide`.
- `confirmed` with result → state shows the summary, no buttons.
- expired `proposed` → `canDecide == false`.
- a `reason` containing Markdown link syntax → `detail` is the raw string.

`ask/picker.test.ts`:
- default from configuration; choosing an instance and model yields the
  selection input; a model without efforts hides effort; `automatic`
  default yields an empty selection.

`ask/panelState.test.ts`:
- snapshot plus a feed with message chunks and a tool call → ordered items;
  `canSend == false` while running; after the turn ends and the snapshot
  reloads, live items are replaced by the stored message.
- a failed turn → an error item with the code, no assistant item.

`ask/client.test.ts`:
- `start` sends `message`, `context`, `selection`, `remote` variables;
  `getActivity` passes `waitMs`; a GraphQL error maps to its code.

`bots/activityStream.test.ts` (extended):
- a stream built with an ask reader ends when `turnStatus` is terminal and
  the state is settled.

`routes.test.ts`, `App.test.ts`: existing cases pass; add one that the app
shell renders the Ask rail button on a routed view.

## Verification

```
mkdir -p tmp/ask-riela/ask-07-web
cd web && bun install --frozen-lockfile > ../tmp/ask-riela/ask-07-web/install.log 2>&1
cd web && bun run typecheck > ../tmp/ask-riela/ask-07-web/typecheck.log 2>&1
cd web && bun test src > ../tmp/ask-riela/ask-07-web/test.log 2>&1
cd web && bun run lint > ../tmp/ask-riela/ask-07-web/lint.log 2>&1
cd web && bun run build > ../tmp/ask-riela/ask-07-web/build.log 2>&1
```

All exit 0 (each line is run from the repository root). Evidence: panel
logic, links, cards, picker and stream behave as specified; the app builds
without the old editor chat.

## Done criteria

- `grep -rn "WorkflowAgentChat\|workflow-editor/generations" web/src` prints nothing.
- `git status --porcelain web/package.json web/bun.lock` prints nothing.
- Verification exits 0; progress log written.

## Amendment 2026-11-25 (blocked-wave-scope-or-contract, round 1)

Ask Riela does not run on `official/cursor-sdk` (see
`impl-plans/active/ask-03-turn-engine.md`, same amendment): the server
refuses such a turn with `ask_provider_unsupported`.

- `ask/picker.ts`: the override list leaves out provider instances whose
  driver is `official/cursor-sdk` or `official/gemini-sdk` (the two drivers
  the server refuses). The driver ids are two constants in this file.
- When the default vendor from settings is `cursor-api`, the picker shows the
  default as it is; a send then shows the server's error row with the code.
  Do not hide or rewrite the user's setting.
- Tests (`ask/picker.test.ts`): a catalog with a Cursor API instance and a
  Gemini instance → neither is offered; the other instances are offered in
  catalog order.
- Write paths, wave and dependency are unchanged.
