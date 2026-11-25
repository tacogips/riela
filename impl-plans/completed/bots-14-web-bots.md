# bots-14-web-bots: web Bots list, bot board, live activity, answer cards

```json
{
  "planId": "bots-14-web-bots",
  "planPath": "impl-plans/active/bots-14-web-bots.md",
  "dependsOn": ["bots-12-activity-surfaces"],
  "wave": 5,
  "writePaths": [
    "web/src/bots",
    "web/src/routes.ts",
    "web/src/routes.test.ts",
    "web/src/profileViewState.ts",
    "web/src/App.tsx",
    "web/src/App.test.ts",
    "impl-plans/progress/bots-14-web-bots.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "web/src/routes.ts", "intendedEdit": "Add `bots` to the nav views and the route `{ view: 'bot-detail'; botId: string }` with hash `#/bots/{botId}`. Existing routes keep resolving."},
    {"path": "web/src/profileViewState.ts", "intendedEdit": "Add 'bots' to NavigationView, 'bot-detail' to View, and the fallback `bot-detail` -> `bots`."},
    {"path": "web/src/App.tsx", "intendedEdit": "Add the nav entry `{ id: 'bots', label: 'Bots', icon: <existing icon name> }`, the two <Match> branches, and hash sync for bot-detail. Do not add 'bots' to CLI_SERVE_HIDDEN_VIEWS."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2. This plan runs in the same
wave as `bots-13-model-surfaces`; it touches only `web/src`.

## Intent and context

Design §5.3, §5.4, §6.5 (web), §6.6 (web answer), §8.6, §12 (web). The web
console gets a Bots view that renders exactly what the server projected: the
ordered bot list with counts and sections, the board per bot, the live
activity of the selected item, and answer buttons for pending requests.

Current code: hash routes in `web/src/routes.ts`, view state in
`web/src/profileViewState.ts`, mounting and navigation in `web/src/App.tsx`
(`navigation` array `:23-27`, `<Match>` branches `:180-`). GraphQL reads use
`ConsoleClient.execute` in `web/src/console/client.ts` (headers, error
mapping). Polling uses `createPollingController` in `web/src/polling.ts`
(5 s, pauses when hidden). Ops views under `web/src/ops/` show the styling
and test conventions (`*.test.ts` beside the source, pure logic split from
components).

GraphQL fields available (plans 10 and 12): `bots(filter)`, `bot(botId)`,
`createBot`, `updateBot`, `setBotPaused`, `removeBot`, `setBotListState`,
`botActivity(sessionId, afterSequence, limit, waitMs)`, `answerBotRequest`.
Field names of the DTOs are in `Sources/RielaGraphQL/Bots/BotsGraphQL.swift`
and the SDL; read them, do not guess.

## Non-goals

- No models view, memory editor, suggestions, jobs, remotes (plan 20).
- No new REST calls; GraphQL only.
- No client-side ordering, snooze or settle logic: render server order and
  sections.
- No new dependencies in `web/package.json`.
- English only, little text; no explanatory paragraphs in the UI.

## Changes (new files in `web/src/bots/` unless noted)

- `client.ts`: `BotsClient` built like `ConsoleClient` (reuse its
  environment type and `execute` pattern; export a default instance).
  Methods: `listBots(groupBy, signal)`, `getBot(botId, signal)`,
  `createBot`, `updateBot`, `setPaused`, `removeBot`, `setListState`,
  `getActivity({ sessionId, afterSequence, waitMs, signal })`,
  `answerRequest({ requestId, optionId?, decline? })`. GraphQL errors become
  `APIError` with `extensions.code` as the code.
- `contracts.ts`: TypeScript types for the DTOs used.
- `activityFeed.ts` (pure): `mergeActivityPage(feed, page)` appends events
  with `seq` greater than the feed's last, replaces `state`, and resets the
  feed from `state` when `page.truncated` is true;
  `nextCursor(feed)`; `activitySummary(event)` returns the one-line label.
- `activityStream.ts`: a controller that calls `getActivity` in a loop with
  `waitMs: 25000` and `afterSequence = nextCursor`, aborts on dispose or item
  change, stops when `sessionStatus` is terminal and the state has no current
  execution, and after a failed request waits 5 s before retrying (the
  existing polling interval). It pauses while `document.hidden`.
- `boardView.ts` (pure): `groupTitles` (`Needs you`, `In progress`,
  `Waiting`, `Planned`, `Closed`), `formatElapsed(ms)`, `countsLabel(counts)`
  (for example `1 needs you · 2 working`), `sectionOrder`.
- `BotsView.tsx`: polled list (`createPollingController`, 5 s). Sections in
  order `active`, `working` (collapsed by default), `snoozed`, `settled`
  (both collapsed). Each row: name, counts label or last-result line when
  idle, relative last-activity time, a dot when `counts.needsYou > 0`, the
  origin label when `origin.remote !== 'local'`. Row actions: pin/unpin,
  snooze (1 hour, 1 day), settle, pause/resume. A group-by toggle
  (none / workspace) with a needs-you dot on collapsed groups. A small
  "New bot" form (name, backend select from the driver list, model text).
- `BotDetailView.tsx`: polled `bot(botId)`. Five groups in order with their
  items; each item shows title, step/node, backend and model, elapsed time,
  `doingNow`, the checklist (plan entries with status), waiting reason,
  `limited` with reset time, and `activitySource`. Needs-you items render one
  button per option plus "Decline" for `answerPath === 'bot'`; for
  `answerPath === 'task'` they show the question text and the task id (no
  buttons). Selecting an item opens the activity pane fed by
  `activityStream`. Routines list with next run. Closed shows
  `closedTotal` when larger than the list.
- `bots.css`: styles, imported by the two views; reuse existing CSS variables.
- `routes.ts`, `profileViewState.ts`, `App.tsx`: as in the sharedPathNotes.

## Imitate

- `web/src/ops/OpsWorkflowsView.tsx` and `web/src/ops/overview.ts` for a
  polled GraphQL view with pure helpers and tests.
- `web/src/console/client.ts:ConsoleClient` for requests and error handling.
- `web/src/components/ActionButton` for buttons and icons.

## Pitfalls

- Hash segments are split before decoding (`parseViewHash`); encode `botId`
  with `encodeURIComponent` in `viewHash`.
- Abort the long-poll request when the component unmounts or the selected
  item changes; one stream at a time.
- Never sort, filter or re-bucket what the server returned.
- Disable answer buttons while a request is in flight; on
  `request_already_resolved` or `request_expired` just refresh.
- The repository lints with ESLint 10 and type-checks with TypeScript 6;
  Solid `ref` variables need the existing project pattern (see other views).
- `App.test.ts` and `routes.test.ts` already assert navigation and routes;
  extend them, do not weaken them.

## Tests (bun, beside the sources)

`web/src/bots/activityFeed.test.ts`:
- two pages in order → events concatenated, cursor = last seq.
- a page containing an already-seen seq → not duplicated.
- `truncated` page → feed reset to the page's events and state.

`web/src/bots/boardView.test.ts`:
- counts `{needsYou:1, working:2}` → `1 needs you · 2 working`; all zero → ``.
- `formatElapsed(372000)` → `6m 12s`.
- section order constant is `active, working, snoozed, settled`.

`web/src/bots/client.test.ts` (fake environment like `console/client.test.ts`):
- `listBots` sends one POST to `/graphql` with the profile headers and
  returns the payload.
- a GraphQL error with `extensions.code = 'bot_not_found'` → `APIError` with
  that code.
- `getActivity` passes `afterSequence` and `waitMs` variables.

`web/src/bots/activityStream.test.ts` (injected client and timers):
- stops after a terminal, settled page.
- a failed request → retries after 5 s.
- dispose aborts the in-flight request.

`web/src/routes.test.ts`: `#/bots` and `#/bots/release-bot` parse and
round-trip; an id with `/` round-trips encoded.
`web/src/App.test.ts`: the navigation contains `Bots`.

## Verification

Every line is run from the repository root; each web command is a subshell,
so the working directory never changes.

```
mkdir -p tmp/bots-overview/bots-14-web-bots
bun --version > tmp/bots-overview/bots-14-web-bots/bun-version.log 2>&1
(cd web && bun install --frozen-lockfile) > tmp/bots-overview/bots-14-web-bots/install.log 2>&1
(cd web && bun run typecheck) > tmp/bots-overview/bots-14-web-bots/typecheck.log 2>&1
(cd web && bun test src/bots src/routes.test.ts src/App.test.ts) > tmp/bots-overview/bots-14-web-bots/test.log 2>&1
(cd web && bun run lint) > tmp/bots-overview/bots-14-web-bots/lint.log 2>&1
(cd web && bun run build) > tmp/bots-overview/bots-14-web-bots/build.log 2>&1
git status --short web/package.json web/bun.lock
```

All exit 0 and the last command prints nothing. Evidence: types match, pure
logic and routing tests pass, the bundle builds, the lockfile is unchanged.

Dependency install and artifacts:

- `web/node_modules` does not exist in this worktree at `7f04f6e6`, so the
  install line is required. It may be skipped only when `web/node_modules`
  already exists (say so in the progress log).
- `--frozen-lockfile` is mandatory: the install must not rewrite
  `web/bun.lock` or `web/package.json`.
- `web/node_modules` and `web/dist` are gitignored build outputs
  (`.gitignore` lines 2 and 5). They lie outside every writePath of this plan
  (it owns `web/src/*` paths only) and are untracked writes that need no
  plan authorisation per the workflow input, so no `artifactRoots` entry is
  declared and none of them is a source snapshot.
- The progress log records the bun version, the install command, its exit
  code and log path, and the empty `git status` result.
- If the install fails (for example no network or cache), record
  `BLOCKED: environment` in the progress log with the path of
  `install.log`. Do not mark the web verification as passed and do not
  replace it with a weaker check.

## Done criteria

- `grep -rn "fetch(\|/api/v1/" web/src/bots` prints nothing (GraphQL through the shared client only).
- `git status --short web/package.json web/bun.lock` prints nothing.
- Verification exits 0; progress log written.
