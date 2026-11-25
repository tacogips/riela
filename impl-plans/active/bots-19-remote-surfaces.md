# bots-19-remote-surfaces: `riela remote`, client registry, forwarding with origin, selectors

```json
{
  "planId": "bots-19-remote-surfaces",
  "planPath": "impl-plans/active/bots-19-remote-surfaces.md",
  "dependsOn": ["bots-18-pairing-surfaces"],
  "wave": 9,
  "writePaths": [
    "Sources/RielaCLI/Remotes",
    "Tests/RielaCLITests/Remotes",
    "Sources/RielaCLI/Bots",
    "Sources/RielaCLI/BotJobs",
    "Sources/RielaCLI/ModelCatalog",
    "Sources/RielaGraphQL/Bots",
    "Tests/RielaGraphQLTests/Bots",
    "Sources/RielaCLI/RielaClientCommandRouter.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/ScopedParityCommands.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaCLI/ParsedWorkflowOptions.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/RoutineCommands.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsBots.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift",
    "impl-plans/progress/bots-19-remote-surfaces.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/Bots", "intendedEdit": "BotsService/BotsGraphQLProvider/command files: replace the `remote_not_configured` stub with forwarding; add --remote / --all-remotes to ParsedBotOptions."},
    {"path": "Sources/RielaCLI/BotJobs", "intendedEdit": "Job and suggestion commands and provider methods accept the remote selector and forward."},
    {"path": "Sources/RielaCLI/ModelCatalog", "intendedEdit": "Model and provider commands and provider methods accept the remote selector and forward."},
    {"path": "Sources/RielaCLI/ParsedWorkflowOptions.swift", "intendedEdit": "Add `--remote <name>` to workflow run options."},
    {"path": "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift", "intendedEdit": "When --remote is set, resolve it to endpoint and auth token from the registry and fill the existing endpoint/authToken options. --remote together with --endpoint is a usage error."},
    {"path": "Sources/RielaCLI/RoutineCommands.swift", "intendedEdit": "`routine create --remote <name>` sends the createRoutine mutation to that server instead of writing locally."},
    {"path": "Sources/RielaCore/SurfaceCatalog+Rows.swift", "intendedEdit": "Add \"--remote\" to the cliOptions of the `workflow run` row only."},
    {"path": "Sources/RielaCore/SurfaceCatalog+RowsCLI.swift", "intendedEdit": "Add \"--remote\" to the options of the routine.create row only."},
    {"path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift", "intendedEdit": "Generated: regenerate with scripts/surface-parity/generate-sdl.sh."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §11.3, §11.4, §11.5. A riela client pairs with a server
(`riela remote add`), keeps the grant under the credential directory, and
then reads and drives that server's bots through the same typed operations
as local ones. Every item says where it came from; an unreachable server is
shown as disconnected with its last known overview.

Current code and earlier plans:

- Server side is complete (plan 18): `POST /api/v1/pairing/redeem`,
  API-key `POST /graphql` with scopes, `origin.serverId` on bot DTOs.
- All bot-family GraphQL inputs already carry `remote`; the local provider
  answers `remote_not_configured` for non-local values (plan 10).
- Remote workflow execution already exists through `--endpoint`,
  `--auth-token`, `--auth-token-env` (`WorkflowRunCommand+Remote.swift`).
- HTTP client pattern with no redirects and no cache:
  `RielaAppAPIClient.transport` (`Sources/RielaCLI/RielaAppAPIClient.swift:24-33`).
- `GraphQLSchemaGenerator.types` holds every DTO's field list.
- `riela environment` already means "instance environment"; the family here
  is `riela remote` (design §11.4, user-QA Q1).

## Non-goals

- No relay or cloud service; no request queue for unreachable servers.
- No change to the RielaApp desktop direct remote mode (`web/src/transport.ts`).
- No browser-held remote tokens; the web switcher is plan 20.
- No server-side change.

## Changes

### Registry (`Sources/RielaCLI/Remotes/RemoteRegistry.swift`, new)

- Directory: `RIELA_CREDENTIAL_DIR`, else `${XDG_STATE_HOME:-~/.local/state}/riela/credentials`
  (resolve from the passed environment and home; never `~/.config`).
  Directory mode 0700; files 0600, written atomically (temp file + rename),
  opened with `O_NOFOLLOW`.
- `remotes.json`: `{ version: 1, active: String, remotes: [RemoteRecord] }`
  with `RemoteRecord { name, address, serverId, serverName, grantId, scope, addedAt, lastSeenAt, lastKnown: RemoteLastKnown? }`;
  `RemoteLastKnown { observedAt, bots: [{ botId, name, counts }] }`.
  `active` defaults to `local`.
- `remotes/<name>.token`: the bearer token only.
- `name` grammar `^[a-z0-9][a-z0-9-]{0,62}$`; `local`, `*` and `unverified`
  are reserved (`remote_name_invalid`).
- API: `list()`, `record(name:)`, `token(name:)`, `add(record:token:)`
  (`remote_exists`), `remove(name:)` (deletes record and token file;
  removing the active one sets `active = local`), `use(name:)`
  (`remote_not_found`), `updateLastKnown`, `touchLastSeen`.

### Pairing client (`Sources/RielaCLI/Remotes/RemotePairingClient.swift`, new)

- `static func decode(code: String) throws -> (address: URL, secret: String, serverId: String)`:
  `rp1.` prefix + base64url JSON; anything else → `pairing_code_invalid`.
  The decoded address is validated with the same rules as the server
  (`RielaPairingAddress.validate`).
- `func redeem(code:clientName:) async throws -> (token, grantId, scope, serverId, serverName)`:
  `POST <address>/api/v1/pairing/redeem`, JSON body, 30 s timeout, no
  redirects. The response `serverId` must equal the code's `serverId`
  (`pairing_server_mismatch`, nothing stored). HTTP 403 → `pairing_code_invalid`;
  transport failure → `remote_unreachable`.
- The transport is an injectable closure for tests.

### Remote GraphQL client (`Sources/RielaCLI/Remotes/RemoteGraphQLClient.swift`, new)

`struct RemoteGraphQLClient { record, token, transport }` with
`func execute(query:variables:operationName:) async throws -> JSONObject`
(`POST <address>/graphql`, `Authorization: Bearer`, `Content-Type: application/json`,
no `Origin`, no cookies). Maps: transport failure/timeout →
`remote_unreachable`; HTTP 401 or `UNAUTHENTICATED` →
`remote_unauthorized`; GraphQL `errors[0].extensions.code` → that code.

### Forwarding (`Sources/RielaCLI/Remotes/RemoteBotsProvider.swift`, new)

`struct RemoteBotsProvider: BotsGraphQLProviding` implements every provider
method by sending one generated document per operation and decoding the
result into the same DTO type the local provider returns.

- Selection sets are generated from `GraphQLSchemaGenerator.types` by a new
  helper `GraphQLSelectionBuilder.selection(forType:)` in
  `Sources/RielaGraphQL/Bots/GraphQLSelectionBuilder.swift` (recursive over
  object fields, scalars and `JSON` leaves as-is; guard against cycles). No
  hand-written field lists.
- The `remote` argument is never sent to the remote server.
- After decoding, every `origin` in the result is rewritten:
  `remote = record.name`; `verified = (origin.serverId == record.serverId)`;
  when `serverId` is missing or different, `remote = "unverified"` and
  `verified = false`; `connection = "connected"`. A result type with no
  origin from an old server is treated as unverified.
- `touchLastSeen`, and for `bots` also `updateLastKnown`.

### Local provider and service routing

One helper `RemoteRouting.resolve(remote: String?, registry:) -> Target`
(`.local`, `.remote(record, token)`, `.all`):
- nil → the registry's `active` remote (default `local`); `"local"` →
  local; a name → that remote (`remote_not_found` when unknown); `"*"` →
  all, accepted only by list and show reads (`bots`, `providers`,
  `modelCatalog`, `botSuggestions`); mutations and `botActivity` with `*` →
  `remote_selector_invalid`.
- `.all` for `bots`: local rows first, then each remote in name order; a
  remote that fails with `remote_unreachable` contributes rows built from
  `lastKnown` with `origin.connection = "disconnected"`,
  `origin.observedAt = lastKnown.observedAt`, `section = "disconnected"`,
  no `inProgress`, no `lastResult`; a remote with no `lastKnown` contributes
  one placeholder row with the remote name and `section = "disconnected"`.
- A single-remote read of `bots` that is unreachable returns the same
  disconnected rows; every other operation on an unreachable remote fails
  with `remote_unreachable`.
- A filter `remote` on list reads is this same selector.
- Scope note: when the local server forwards on behalf of a caller, the
  caller was already scope-checked by the local server (plan 18); the remote
  server checks the stored grant's scope again.

### `riela remote` (`Sources/RielaCLI/Remotes/RemoteCommands.swift`, new)

`RemoteClientAction { add, list, show, remove, use }`, route `remote`.

| Command | Behaviour |
| --- | --- |
| `riela remote add --name N --code <pairing-code> [--client-name C]` | redeem, store; does not change `active`; `--client-name` defaults to the host name |
| `riela remote list` | name, address, server name, scope, active marker, last seen |
| `riela remote show N` | record plus a live `bots` probe result: connected or disconnected |
| `riela remote remove N` | deletes the local record and token; prints `grant not revoked on the server; revoke it there with riela serve pairing revoke` |
| `riela remote use <N\|local>` | sets `active` |

The code and the token are never printed.

### Selectors

- `ParsedBotOptions`, model/provider/job/suggestion options:
  `--remote <name>` and `--all-remotes` (mutually exclusive). The CLI calls
  `RemoteBotsProvider` directly (no local server needed) or the local service.
- Text output adds a `host` column when any row is not local; disconnected
  rows print `disconnected (last seen <time>)` instead of counts.
- `riela workflow run --remote N [--bot B]`: resolved to the existing
  endpoint/token options. `riela routine create --remote N`: sends
  `createRoutine` through `RemoteGraphQLClient`.

### GraphQL (`Sources/RielaGraphQL/Bots/RemotesGraphQL.swift`, new; same executor)

- `Query.remotes: RemoteListPayload!` (`active`, `remotes[{ name, address, serverName, scope, lastSeenAt, connection }]`; no token, no grant secret)
- `Mutation.addRemote(input: AddRemoteInput!): RemoteListPayload!` (`name`, `code`, `clientName`)
- `Mutation.removeRemote(input: RemoveRemoteInput!): RemoteListPayload!`
- `Mutation.useRemote(input: UseRemoteInput!): RemoteListPayload!`

The three mutations are already in the admin set of `RielaAPIScopePolicy`.

### Registries

Catalog rows `remote.add|list|show|remove|use` (show binds `remotes`);
option additions for `workflow run` and `routine create`; descriptors, SDL,
help, router and enumeration entries for `remote`.

## Imitate

- `RielaAppAPIClient` for transport construction and endpoint validation.
- `RielaAPIKeyStore.transaction`/`persist` for 0600 atomic file writes.
- Plan 10's family skeleton.

## Pitfalls

- Never write the token into `remotes.json`, logs, errors or command output.
- `remote add` must leave nothing behind when redeem fails or the server id
  does not match.
- Do not assume "no origin" means local: it means unverified.
- A disconnected remote must never be rendered with zero counts, `idle`, or a
  last result as if current.
- `*` fan-out must not fail the whole read because one remote is down.
- Selection sets come from the descriptors; a hand-written list will drift.
- Credential directory tests pass `RIELA_CREDENTIAL_DIR` explicitly; never
  touch the real `~/.local/state`.
- `--remote` and `--endpoint` together is an error, not a precedence rule.

## Tests (`Tests/RielaCLITests/Remotes/`; the "remote server" is an in-process `serveMachineGraphQLAdapter` + `ServeWebHost` pair with its own temporary home and store, reached through an injected transport closure)

`RemoteRegistryTests`:
- add → `remotes.json` mode 0600, directory 0700, token file 0600, token not
  in `remotes.json`.
- duplicate name → `remote_exists`; name `local` → `remote_name_invalid`.
- remove the active remote → `active == "local"`.
- `XDG_STATE_HOME` set and `RIELA_CREDENTIAL_DIR` unset → path under
  `$XDG_STATE_HOME/riela/credentials`; path never contains `.config`.

`RemotePairingClientTests`:
- valid code → record stored; `remote list` shows it and `active` is still
  `local`.
- reused code → `pairing_code_invalid`, nothing stored.
- response with a different `serverId` → `pairing_server_mismatch`, nothing
  stored.
- malformed code → `pairing_code_invalid` without any request.

`RemoteForwardingTests`:
- `bot list --remote srv --output json` → the server's bots with
  `origin.remote == "srv"`, `verified == true`.
- `bot list --all-remotes` → local and remote rows, each with its origin.
- server replaced by one with another identity → rows have
  `origin.remote == "unverified"`, `verified == false`.
- transport failing → rows from `lastKnown` with
  `connection == "disconnected"`, `section == "disconnected"`; `bot show --remote srv X` →
  `remote_unreachable`.
- `bot pause b1 --remote srv` with an `operate` grant → paused on the server
  store, local store untouched; with a `read` grant → `scope_insufficient`.
- `bot answer R --option allow-1 --remote srv` → the server-side request row
  is answered.
- `bot activity --session S --remote srv` → events from the server.
- `model list --remote srv`, `bot memory show b1 --remote srv` → served.
- `workflow run W --remote srv --bot b1 --mock-scenario ...` → session and
  link exist in the server store, none locally.
- `routine create ... --remote srv` → routine in the server's routine store.
- revoked grant → `remote_unauthorized`.
- every generated document executes against the local composite with a stub
  provider without a GraphQL validation error (guards the selection builder).

`Tests/RielaGraphQLTests/Bots/RemotesGraphQLTests`, `GraphQLSelectionBuilderTests`:
- fields reach the stub provider; the selection for `BotDetailPayload`
  contains nested `board` item fields and no empty braces.

## Verification

```
mkdir -p tmp/bots-overview/bots-19-remote-surfaces
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-19-remote-surfaces/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "RemoteRegistryTests|RemotePairingClientTests|RemoteForwardingTests|RemotesGraphQLTests|GraphQLSelectionBuilderTests|PairingScopeEnforcementTests|BotCommandTests|BotRunLinkageTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests"' > tmp/bots-overview/bots-19-remote-surfaces/test.log 2>&1
```

Both exit 0. Evidence: pairing from the client side, forwarding of every
bot-family operation, origin verification, disconnected state and scope
enforcement through a real server composite.

## Done criteria

- `grep -rn "remote_not_configured" Sources` prints nothing.
- `grep -rn "\.config" Sources/RielaCLI/Remotes` prints nothing.
- Verification exits 0; progress log written.
