# bots-18-pairing-surfaces: `riela serve` pairing, redeem route, scope enforcement, server origin

```json
{
  "planId": "bots-18-pairing-surfaces",
  "planPath": "impl-plans/active/bots-18-pairing-surfaces.md",
  "dependsOn": ["bots-08-pairing-server", "bots-16-jobs-surfaces"],
  "wave": 8,
  "writePaths": [
    "Sources/RielaCLI/Pairing",
    "Tests/RielaCLITests/Pairing",
    "Sources/RielaGraphQL/Bots",
    "Tests/RielaGraphQLTests/Bots",
    "Sources/RielaCLI/Bots",
    "Sources/RielaCLI/APIKeyGraphQLAuthorization.swift",
    "Sources/RielaCLI/ServeHTTPCommand.swift",
    "Sources/RielaCLI/ServeWebHost.swift",
    "Sources/RielaCLI/ParityCommandSupport.swift",
    "Sources/RielaCLI/ScopedParityCommands+Serve.swift",
    "Sources/RielaCLI/RielaClientFamilyArguments.swift",
    "Sources/RielaCLI/CLISurfaceEnumeration.swift",
    "Sources/RielaCLI/RielaCLIApplication.swift",
    "Sources/RielaAppSupport/RielaWebAPIRouteTable.swift",
    "Sources/RielaGraphQL/GraphQLSchemaGenerator.swift",
    "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsBots.swift",
    "impl-plans/progress/bots-18-pairing-surfaces.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/APIKeyGraphQLAuthorization.swift", "intendedEdit": "After a bearer token is accepted: resolve the key record, enforce RielaAPIScopePolicy on the document's root fields, call store.touch, and expose a grant re-check closure for long waits. Requests without a credential keep today's behaviour."},
    {"path": "Sources/RielaCLI/ServeHTTPCommand.swift", "intendedEdit": "Handle --pairing-address / --pairing-scope / --server-name at start (mint and print once), pass the server identity to the hosts. Keep plan 10's composite edit and plan 16's scheduler edit."},
    {"path": "Sources/RielaCLI/ServeWebHost.swift", "intendedEdit": "In routedResponse (line 119-), answer POST /api/v1/pairing/redeem BEFORE the passkey, API-key and browserAccess checks. The literal \"/api/v1/pairing/redeem\" must appear in this file. Also pass the server identity to the bots provider origin."},
    {"path": "Sources/RielaCLI/ParityCommandSupport.swift", "intendedEdit": "ParsedParityOptions: add --pairing-address, --pairing-scope, --server-name, --address, --grant options."},
    {"path": "Sources/RielaCLI/ScopedParityCommands+Serve.swift", "intendedEdit": "Dispatch `serve pairing mint|list|revoke` to the new pairing commands before the HTTP probe actions."},
    {"path": "Sources/RielaAppSupport/RielaWebAPIRouteTable.swift", "intendedEdit": "Declare POST /api/v1/pairing/redeem with owner Sources/RielaCLI/ServeWebHost.swift and include it in `all` (not in desktopOnly)."},
    {"path": "Sources/RielaCLI/Bots", "intendedEdit": "BotsService/BotsGraphQLProvider: origin from the server identity when hosted by `riela serve`; pairing provider methods; wait re-check from the task-local grant check."},
    {"path": "Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift", "intendedEdit": "Generated: regenerate with scripts/surface-parity/generate-sdl.sh."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2. Runs in the same wave as
`bots-17-example-docs`; the two share no path.

## Intent and context

Design §11.1, §11.2 and the three review notes on it (redeem must be routed
before the browser gate; registry mutations are admin; scope is checked on
the server that receives the request). Plan 08 built the store, address
rules, redeem handler, audit and scope policy in `RielaServer`. This plan
wires them into `riela serve`: minting, the redeem route, grants, revocation,
scope enforcement on every API-key GraphQL request, and a stable server
identity in every bot DTO's `origin`.

Current code:

- `riela serve` start: `ServeHTTPCommand.run` (`ServeHTTPCommand.swift:33-`),
  options in `ParsedParityOptions` (`ParityCommandSupport.swift:11-`).
- HTTP routing of the web host: `ServeWebHost.routedResponse`
  (`ServeWebHost.swift:119-`): passkey routes, then the API-key machine path
  for `/graphql`, then the browser gate (`browserAccess.rejection`).
- API-key GraphQL authorisation: `APIKeyGraphQLAuthorization.execute`
  (`APIKeyGraphQLAuthorization.swift:7-25`) validates
  `request.transportCredential` with `store.authorizeClient(token:)`.
- Key store location: `serverAPIKeyStore(homeDirectory:)` (`:38-41`).
- Declared web routes: `Sources/RielaAppSupport/RielaWebAPIRouteTable.swift`;
  gate `Tests/RielaCLITests/SurfaceParityWebAPITests.swift` (bijection with
  catalog rows and "path literal appears in the owner file").
- `serve` actions: `ServeClientAction` (`RielaClientFamilyArguments.swift:163-168`),
  dispatch in `ScopedParityCommands+Serve.swift`.

## Non-goals

- No client registry, `riela remote`, forwarding or `--remote` (plan 19).
- No TLS termination; no change to passkey login or worker keys.
- No pairing on the RielaApp desktop host in this plan: its API-key routes
  stay as they are (`desktopOnly` table untouched).
- No new long-lived connection type.

## Changes

### Server start (`ServeHTTPCommand.swift`, `ParsedParityOptions`)

- `--server-name <name>`: stored through `RielaServerIdentity.loadOrCreate`
  (root = the API key store root).
- `--pairing-address <url>` (+ `--pairing-scope read|operate|admin`, default
  `operate`): after the listener is ready, call
  `store.mintPairingCode(address:scope:serverId:now:)`, append the `mint`
  audit line, and print exactly once to **stdout**:
  `pairing code (expires in 10 minutes): <code>` and
  `pairing address: <url>`. Address errors end the command before listening
  with the code `pairing_address_not_routable` or
  `pairing_address_requires_tls`. `--pairing-scope` without
  `--pairing-address` is a usage error.
- The code is never written to stderr, the serve record, an event, a log
  file or an error message.

### `serve pairing` commands (`Sources/RielaCLI/Pairing/PairingCommands.swift`, new)

`ServePairingClientAction { mint, list, revoke }`; three-level paths
`serve pairing <action>`.

| Command | Behaviour |
| --- | --- |
| `riela serve pairing mint --address <url> [--pairing-scope S]` | mints against the same on-disk store the running server reads; prints the code once |
| `riela serve pairing list` | grants: id, client name, scope, created, last used, revoked |
| `riela serve pairing revoke --grant <id>` | `store.revoke`, audit `revoke`; unknown id → `pairing_grant_not_found` |

All three operate on `serverAPIKeyStore(homeDirectory:)`; tests pass an
explicit home directory.

### Redeem route (`ServeWebHost.swift`, route table)

At the top of `routedResponse`, before any other check: if the request is
`POST /api/v1/pairing/redeem`, return
`RielaPairingHTTP.response(for:store:identity:audit:now:)`. Declare the
route in `RielaWebAPIRouteTable` and add the catalog row `pairing.redeem`
(webAPI implemented; cli excluded "reached through riela remote add"; graphql
excluded "must work before any credential exists; design §12"; library
excluded).

### Scope enforcement (`APIKeyGraphQLAuthorization.swift`)

When a bearer credential is present and valid:
- resolve the record with `store.authenticate(token, purpose: .client)`;
- parse the document's root fields (the request's `parsedRootFields`, or the
  same parser the executors use) and call
  `RielaAPIScopePolicy.violation(scope: record.effectiveScope, roots:)`; a
  violation returns a GraphQL error with `extensions.code = "scope_insufficient"`
  and the offending field in the message; the request is not executed;
- `store.touch(id:now:)`;
- run `next.execute` inside a task-local
  `BotsRequestGrant.$current.withValue(...)` (define the `@TaskLocal` in
  `Sources/RielaCLI/Pairing/BotsRequestGrant.swift`) carrying a closure
  `isStillValid() -> Bool` that re-authenticates the token against the store.
- A document that cannot be parsed is rejected as today by the executors;
  for scope purposes an unparsable document with a non-admin scope is
  refused (`scope_insufficient`).
Requests with no credential (locally trusted, or `requireClientKey == false`)
are not scope-limited: behaviour unchanged.

`BotsGraphQLProvider.botActivity` passes
`isStillAuthorized: { BotsRequestGrant.current?.isStillValid() ?? true }`
(the hook plan 12 left). A revoked grant therefore ends a held wait within
one 250 ms poll with an authentication error.

### GraphQL (`Sources/RielaGraphQL/Bots/PairingGraphQL.swift`, new; same executor)

- `Query.pairingGrants: PairingGrantListPayload!`
- `Mutation.mintPairingCode(input: MintPairingCodeInput!): PairingCodePayload!`
  (`address`, `scope`) → `{ code, expiresAt, address, scope }`
- `Mutation.revokePairingGrant(input: RevokePairingGrantInput!): PairingGrantListPayload!`
- `PairingGrant { grantId, clientName, scope, createdAt, lastUsedAt, revokedAt }`.
Both mutations are in `RielaAPIScopePolicy.adminMutationFields` (plan 08);
`pairingGrants` is additionally refused for a credential whose scope is not
`admin` (`scope_insufficient`), because it lists other clients.

### Origin

`BotsService.origin` returns
`BotOrigin.local(serverId: identity.serverId, serverName: identity.name, at: now)`
when the host is `riela serve` (both the browser composite and the API-key
composite). Plain CLI reads keep a nil server id.

### Registries

Catalog rows `serve.pairing.mint|list|revoke` and `pairing.redeem`; schema
descriptors; SDL; help text; enumeration for the three-level `serve pairing`
paths.

## Imitate

- `Sources/RielaCLI/PasskeyCommand.swift` (`riela auth invite`) for printing a
  one-time secret once.
- `ServeWebHost.swift:119-129` for early-return routing.
- `RielaWebAPIRouteTable` existing declarations for owner and marker rules.

## Pitfalls

- The redeem branch must be first. If it sits after `browserAccess.rejection`
  a remote client gets 401/403 and pairing never works.
- The literal `"/api/v1/pairing/redeem"` must appear in `ServeWebHost.swift`
  or the owner-file gate fails.
- Do not print the pairing code anywhere except the single stdout write; do
  not include it in `CLICommandResult.stderr` on later errors.
- Scope is enforced on the server that receives the request, before any
  executor runs, for every root field of the document (a document mixing a
  query and an admin mutation is refused as a whole).
- Keys without `scope` are `admin` (existing keys keep working).
- Revocation needs no connection tracking: every request re-reads the store.
  Do not add a cache in front of `authenticate`.
- `touch` is rate-limited inside the store; call it once per request.

## Tests (`Tests/RielaCLITests/Pairing/`, real `ServeWebHost` / adapter with temporary home and store roots, no real network beyond the in-process handler)

`PairingServeTests`:
- `serve pairing mint --address http://192.168.1.5:8787` → stdout has one
  code; `api-keys.json` and `pairing-audit.jsonl` do not contain the secret.
- `--address http://127.0.0.1:8787` → `pairing_address_not_routable`;
  `http://example.com` → `pairing_address_requires_tls`.
- `POST /api/v1/pairing/redeem` through `ServeWebHost.response(for:)` with a
  host configured for passkey access (non-loopback) → 200 with a token (the
  browser gate did not block it).
- second redeem → 403 `pairing_code_invalid`.
- `serve pairing list` shows the grant; `revoke --grant <id>` → a following
  GraphQL request with that token returns `UNAUTHENTICATED`.

`PairingScopeEnforcementTests` (API-key composite from
`serveMachineGraphQLAdapter`):
- `read` token: `{ bots { bots { bot { botId } } } }` → data;
  `mutation { setBotPaused(...) }` → `scope_insufficient`.
- `operate` token: `setBotPaused` → ok; `removeBot`, `mintPairingCode`,
  `saveProviderInstance` → `scope_insufficient`; `pairingGrants` →
  `scope_insufficient`.
- `admin` token and a pre-change key without scope → all allowed.
- a document with one query and one admin mutation, `operate` token → refused,
  and the query's side is not executed (provider call count 0).
- held `botActivity(waitMs: 25000)` with a token revoked 300 ms later → the
  call returns an authentication error in under 2 s.
- response origin of `bots` through the API-key composite has the server id
  from `server-identity.json`.

`Tests/RielaGraphQLTests/Bots/PairingGraphQLTests`: fields reach the stub
provider and encode the declared shape.

## Verification

```
mkdir -p tmp/bots-overview/bots-18-pairing-surfaces
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/bots-18-pairing-surfaces/sdl.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "PairingServeTests|PairingScopeEnforcementTests|PairingGraphQLTests|PairingCodeTests|BotActivityGraphQLTests|SurfaceCatalogTests|SurfaceParityCLITests|SurfaceParityGraphQLTests|SurfaceParityExecutorCoverageTests|SurfaceParityDTOSchemaTests|SurfaceParityWebAPITests|SurfaceParitySkillTests"' > tmp/bots-overview/bots-18-pairing-surfaces/test.log 2>&1
grep -rn "rp1\." tmp/bots-overview/bots-18-pairing-surfaces/test.log
```

The first two exit 0; the `grep` prints nothing (no pairing code in test
logs). Evidence: pairing works end to end against the real serve routing,
scopes and revocation are enforced, the web route gate accepts the new route.

## Done criteria

- `grep -n "/api/v1/pairing/redeem" Sources/RielaCLI/ServeWebHost.swift Sources/RielaAppSupport/RielaWebAPIRouteTable.swift` shows both.
- In `ServeWebHost.routedResponse` the redeem branch is above the line that calls `browserAccess.rejection`.
- Verification passes; progress log written.
