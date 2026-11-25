# bots-20-web-management: web models view, bot memory, suggestions, jobs, remotes

```json
{
  "planId": "bots-20-web-management",
  "planPath": "impl-plans/active/bots-20-web-management.md",
  "dependsOn": ["bots-14-web-bots", "bots-19-remote-surfaces"],
  "wave": 10,
  "writePaths": [
    "web/src/bots",
    "web/src/models",
    "web/src/routes.ts",
    "web/src/routes.test.ts",
    "web/src/profileViewState.ts",
    "web/src/App.tsx",
    "web/src/App.test.ts",
    "impl-plans/progress/bots-20-web-management.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "web/src/routes.ts", "intendedEdit": "Add nav view `models` with hash `#/models`. Existing routes, including plan 14's bot routes, keep resolving."},
    {"path": "web/src/profileViewState.ts", "intendedEdit": "Add 'models' to NavigationView."},
    {"path": "web/src/App.tsx", "intendedEdit": "Add the nav entry `{ id: 'models', label: 'Models', ... }` and its <Match> branch."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §7.5 (web view), §9.3 (web editor), §10.3 (web cards), §11.4–§11.5
(remote switcher, host label, filter, disconnected). Plan 14 delivered the
Bots list, board and activity. This plan adds the remaining web pieces on the
GraphQL fields of plans 13, 15, 16, 18 and 19.

Fields used (read exact names from `Sources/RielaGraphQL/Bots/*.swift` and
the SDL): `modelCatalog`, `providers`, `refreshProviders`,
`saveProviderInstance`, `removeProviderInstance`; `botMemory`,
`updateBotMemory`, `undoBotMemoryChange`, `captureBotFeedback`;
`botSuggestions`, `decideBotSuggestion`, `runBotJob`; `remotes`, `addRemote`,
`removeRemote`, `useRemote`; the `remote` argument and `origin` on every
bot-family field.

Existing web code to extend: `web/src/bots/client.ts`, `contracts.ts`,
`BotsView.tsx`, `BotDetailView.tsx` (plan 14).

## Non-goals

- No pairing-code minting UI and no grant list (server admin stays on the CLI).
- No remote token in the browser: the browser only sends remote names.
- No change to `web/src/transport.ts` or the desktop connection control.
- No new dependencies; English only, little text.

## Changes

### Remote selection (`web/src/bots/`)

- `remoteSelection.ts` (pure + a small Solid store): the selected remote is
  `'local'`, a name, or `'*'`; persisted in `sessionStorage` under
  `riela.bots.remote`; default is the `active` value of `remotes`.
  `remoteArgument(selection)` returns the value to send (`undefined` for the
  server's active default is not used: always send the explicit selection).
- `RemoteSwitcher.tsx`: a select with `Local`, each remote name, `All`; a
  compact "Add" form (name + pairing code) calling `addRemote`; remove and
  "set default" (`useRemote`) actions per remote. Errors show the error code.
  The pairing code input is `type="password"`, cleared after submit, never
  logged.
- `client.ts`: every method takes the remote selection and passes it as the
  `remote` argument / input field; mutations and activity never send `'*'`
  (they use the item's own `origin.remote`).
- `BotsView.tsx`: mount the switcher; show the host label on rows whose
  `origin.remote !== 'local'`; rows with `origin.connection === 'disconnected'`
  render in a `Disconnected` section with `last seen <relative time>` and no
  counts, no last result, no actions; rows with `origin.verified === false`
  show an `unverified` badge and no actions.
- `BotDetailView.tsx`: all calls for a bot use that bot's `origin.remote`.

### Memory, suggestions, jobs (`web/src/bots/`)

- `BotMemoryPanel.tsx` (in the bot detail): the Markdown in a textarea, Save
  (`updateBotMemory`), change list (latest 20: actor, reason, time) with an
  Undo button on the newest (`undoBotMemoryChange`). After a save the panel
  reloads; `memory_change_conflict` and `memory_limit` show the code.
- `BotSuggestionsPanel.tsx`: open suggestions as cards with Accept, Accept
  and run (only when the suggestion has an action), Dismiss.
- Jobs row in the bot detail: schedule labels for upkeep and look-around,
  last run status, and "Run now" buttons (`runBotJob` with `force: true`).
- Feedback: on a Closed item, a one-line "Correction" input calling
  `captureBotFeedback` with the item's session id.
- `memoryPanel.ts` (pure): `isDirty(original, edited)`,
  `changeLabel(change)`.

### Models view (`web/src/models/`, new)

- `ModelsView.tsx`: polled `providers` (5 s is not needed; load on mount and
  on Refresh). One card per instance: label, driver, account, availability,
  authentication, version, probe age, Refresh (`refreshProviders` for that
  instance). Under each card the model list: id, source badges, option chips
  (reasoning efforts, service tiers, modes); absent options render nothing.
  A small form to add a user instance with custom model ids and a remove
  button on user instances.
- `modelsView.ts` (pure): `probeAgeLabel(probedAt, now)`,
  `optionChips(model)`.
- Uses the same remote selection as the Bots view.
- Bot create form (plan 14) gets a model select fed by `modelCatalog` for the
  chosen backend, with `default` first and free text still allowed.

## Imitate

- Plan 14 files and their tests.
- `web/src/views/APIKeySettings.tsx` for a form that handles a secret input.

## Pitfalls

- Never send `remote: '*'` on a mutation or on `botActivity`.
- A disconnected or unverified row must have no enabled actions.
- Do not derive status client-side from timestamps; `disconnected` comes from
  `origin.connection`.
- Do not store the pairing code anywhere (no signals kept after submit, no
  `sessionStorage`).
- Keep the textarea content when a save fails.
- Extend, do not weaken, `App.test.ts` and `routes.test.ts`.

## Tests (bun, beside the sources)

`web/src/bots/remoteSelection.test.ts`:
- default follows `remotes.active`; stored selection wins; an unknown stored
  name falls back to `local`.
- `remoteArgument` for a mutation with selection `'*'` → the item's own remote.

`web/src/bots/client.remote.test.ts`:
- `listBots` with selection `srv` sends `filter.remote = 'srv'`.
- `answerRequest` for an item from `srv` sends `input.remote = 'srv'`.
- `addRemote` sends name and code and returns the list; the code is not in
  any thrown error message.

`web/src/bots/memoryPanel.test.ts`: dirty detection; change label.

`web/src/bots/boardView.remote.test.ts` (extend the pure helpers):
- a row with `connection: 'disconnected'` → section `Disconnected`, label
  `last seen ...`, `actionsEnabled === false`.
- a row with `verified: false` → `actionsEnabled === false`.

`web/src/models/modelsView.test.ts`: probe age label; option chips skip empty
lists.

`web/src/routes.test.ts`: `#/models` round-trips.
`web/src/App.test.ts`: navigation contains `Models`.

## Verification

Every line is run from the repository root; each web command is a subshell,
so the working directory never changes.

```
mkdir -p tmp/bots-overview/bots-20-web-management
bun --version > tmp/bots-overview/bots-20-web-management/bun-version.log 2>&1
(cd web && bun install --frozen-lockfile) > tmp/bots-overview/bots-20-web-management/install.log 2>&1
(cd web && bun run typecheck) > tmp/bots-overview/bots-20-web-management/typecheck.log 2>&1
(cd web && bun run test) > tmp/bots-overview/bots-20-web-management/test.log 2>&1
(cd web && bun run lint) > tmp/bots-overview/bots-20-web-management/lint.log 2>&1
(cd web && bun run build) > tmp/bots-overview/bots-20-web-management/build.log 2>&1
git status --short web/package.json web/bun.lock
```

All exit 0 and the last command prints nothing. Evidence: the whole web test
suite passes with the new views, the bundle builds, the lockfile is
unchanged.

Dependency install and artifacts:

- The install line may be skipped only when `web/node_modules` already
  exists (say so in the progress log). `--frozen-lockfile` is mandatory: the
  install must not rewrite `web/bun.lock` or `web/package.json`.
- `web/node_modules` and `web/dist` are gitignored build outputs. They lie
  outside every writePath of this plan (it owns `web/src/*` paths only) and
  are untracked writes that need no plan authorisation per the workflow
  input, so no `artifactRoots` entry is declared.
- The progress log records the bun version, the install command, its exit
  code and log path, and the empty `git status` result.
- If the install fails (for example no network or cache), record
  `BLOCKED: environment` in the progress log with the path of
  `install.log`. Do not mark the web verification as passed.

## Done criteria

- `grep -rn "localStorage\|console.log" web/src/bots web/src/models` prints nothing.
- `git status --short web/package.json web/bun.lock` prints nothing.
- Verification exits 0; progress log written.
