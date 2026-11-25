# bots-08-pairing-server: pairing codes, scoped grants, address rules, audit, scope policy

```json
{
  "planId": "bots-08-pairing-server",
  "planPath": "impl-plans/active/bots-08-pairing-server.md",
  "dependsOn": ["bots-01-contracts"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaServer",
    "Tests/RielaServerTests",
    "impl-plans/progress/bots-08-pairing-server.md"
  ],
  "sharedPaths": []
}
```

Follow `impl-plans/active/bots-overview.md` §2. The dependency on plan 01 is
for wave ordering only (slice a contracts land first); no symbol of plan 01
is used here.

## Intent and context

Design §11.1, §11.2. Server-side pairing built on the existing API key store:
a one-time, expiring code for an explicit address; redeeming it issues a
scoped, revocable client key. This plan delivers the library pieces in
`RielaServer`; plan 18 wires them into `riela serve`, GraphQL and the CLI.

Current code (`Sources/RielaServer/`):

- `RielaAPIKeyStore` (`RielaAPIKeyStore.swift`): `Record` (`id`, `name`,
  `purpose`, `workerID`, `createdAt`, `expiresAt`, `revokedAt`), `issue`,
  `list`, `revoke`, `authenticate`, `authorizeClient`; state in
  `api-keys.json` under a `flock` on `api-keys.lock`, digests only
  (`transaction`, `:133-150`).
- `RielaAPIKeyHTTPAuthorization.rejection(for:store:)` authorises
  `POST /graphql` bearer requests.
- HTTP types: `RielaHTTPRequest`, `RielaHTTPResponse.json(status:_:)`
  (`RielaHTTPContracts.swift`).

## Non-goals

- No change to passkey code or worker keys.
- No wiring into `ServeWebHost`, CLI or GraphQL (plan 18).
- No relay, no new listener, no TLS termination.
- No client-side registry (plan 19).

## Changes

### `RielaAPIKeyStore.swift`

- `public enum Scope: String, Codable, Sendable, Comparable { case read, operate, admin }`
- `Record` gains optional fields, all decoded with defaults so existing
  `api-keys.json` files load: `scope: Scope?`,
  `pairing: PairingInfo?` (`clientName: String`, `pairedAt: Date`),
  `lastUsedAt: Date?`.
- `public var effectiveScope: Scope { scope ?? .admin }` on `Record`.
- `issue(...)` gains `scope: Scope? = nil, pairing: PairingInfo? = nil`.
- `public func touch(id: String, now: Date)`: sets `lastUsedAt` only when it
  is nil or older than 60 seconds (one write per minute per key at most).
- Pairing state lives in the same locked file: the private `State` gains
  `pairingCode: StoredPairingCode?` (`digest`, `address`, `scope`,
  `expiresAt`, `failedAttempts`, `usedAt`), default nil. The operations below
  are store methods so they run inside the existing `transaction`. Do not add
  a second file or a second lock.
- `public func mintPairingCode(address: String, scope: Scope, serverId: String, now: Date, ttl: TimeInterval = 600) throws -> String`:
  validates the address (below), generates a 256-bit secret the same way
  `issue` does, stores only its SHA-256 digest, replaces any previous unused
  code, returns `"rp1." + base64url(JSON {"address","secret","serverId"})`.
- `public func redeemPairingCode(secret: String, clientName: String, now: Date) throws -> IssuedKey`:
  in one transaction: no code, expired, used, or digest mismatch →
  `StoreError.pairingCodeInvalid` (on mismatch increment `failedAttempts`;
  at 5 the code is deleted). On success mark `usedAt`, issue a client key
  with the code's scope and `pairing`, return it. Client name rules are the
  key name rules of `issue`.
- `public func pairingGrants() throws -> [Record]`: records with `pairing != nil`.
- `StoreError` gains `pairingCodeInvalid`, `pairingAddressNotRoutable`,
  `pairingAddressRequiresTLS`.

### `RielaPairingAddress.swift` (new, pure)

`public enum RielaPairingAddress { public static func validate(_ address: String) throws -> URL }`

- Absolute `http` or `https` URL with a host, no user, password, query or
  fragment, path empty or `/`.
- Refuse (`pairingAddressNotRoutable`): `localhost`, any `127.0.0.0/8`,
  `::1`, `0.0.0.0`, `::`, empty host.
- `http` is allowed only when the host is a literal IP in `10.0.0.0/8`,
  `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `fc00::/7`, `fe80::/10`.
  Any host name, and any other IP, with `http` → `pairingAddressRequiresTLS`.
- `https` with a non-refused host is always allowed.

### `RielaServerIdentity.swift` (new)

`public struct RielaServerIdentity: Codable, Equatable, Sendable { serverId: String; name: String }`
with `static func loadOrCreate(root: URL, name: String?) throws -> RielaServerIdentity`:
file `server-identity.json` (0600) in the API key root; created once with a
lowercase UUID; `name` defaults to `ProcessInfo.processInfo.hostName`; a
later non-nil `name` updates the stored name; the id never changes.

### `RielaPairingAudit.swift` (new)

`public struct RielaPairingAudit { public init(root: URL); public func append(action: String, grantId: String?, clientName: String?, scope: String?, remoteAddress: String?, now: Date) }`

Appends one JSON line to `pairing-audit.jsonl` (0600, created with
`O_APPEND | O_CREAT | O_NOFOLLOW`). Actions: `mint`, `redeem`,
`redeem_failed`, `revoke`. No code, token, secret or digest field exists in
the line type. Failures to write are swallowed.

### `RielaPairingHTTP.swift` (new)

`public enum RielaPairingHTTP`:
- `static let redeemRoute = (method: "POST", path: "/api/v1/pairing/redeem")`
- `static func response(for request: RielaHTTPRequest, store: RielaAPIKeyStore, identity: RielaServerIdentity, audit: RielaPairingAudit, now: Date) -> RielaHTTPResponse?`:
  nil for other routes. Requires `content-type: application/json`, no
  `origin` header, body `{ "secret": String, "clientName": String }` of at
  most 4 KiB. Success → 200 `{ token, grantId, scope, serverId, serverName }`.
  Every failure → 403 `{ "error": "pairing_code_invalid" }` (malformed body
  included). Always `Cache-Control: no-store`. Audits `redeem` or
  `redeem_failed`.

### `RielaAPIScopePolicy.swift` (new, pure)

`public enum RielaAPIScopePolicy`:
- `static let adminMutationFields: Set<String>` = `mintPairingCode`,
  `revokePairingGrant`, `addRemote`, `removeRemote`, `useRemote`,
  `saveProviderInstance`, `removeProviderInstance`, `removeBot`, plus every
  mutation of `RielaConfigGraphQLDocumentExecutor.mutationFields` (read the
  set from that type; do not copy names by hand).
- `static func violation(scope: RielaAPIKeyStore.Scope, roots: [(root: String, field: String)]) -> String?`:
  `read` → any `Mutation` root is a violation; `operate` → a `Mutation` field
  in the admin set is a violation; `admin` → none. Returns the first
  offending `Root.field`.

## Imitate

- `RielaAPIKeyStore.issue` and `transaction` for token generation, digesting,
  locking and atomic persist.
- `RielaAPIKeyHTTPAuthorization.failure` for response shape.
- `RielaPasskeyStore.invite` (`RielaPasskeyStore.swift:45-95`) for a
  digest-keyed one-time token with expiry.

## Pitfalls

- Never log or return the pairing secret after `mintPairingCode` returns.
- Compare digests with the existing constant-time `matches` helper.
- Redeem must mark the code used and issue the key in the same transaction;
  two concurrent redeems must produce exactly one key.
- A wrong secret must not reveal whether a code exists (one error code).
- Old `api-keys.json` (no `scope`, no `pairingCode`) must decode; keys
  without scope are `admin`.
- IPv6 literal hosts arrive with or without brackets from `URLComponents`;
  normalise before the range check.
- `100.64.0.0/10` is 100.64.0.0–100.127.255.255; `172.16.0.0/12` is
  172.16–172.31.

## Tests (new files in `Tests/RielaServerTests/`)

`PairingCodeTests` (temporary root):
- mint then redeem → key with the minted scope, `pairing.clientName` set,
  authenticates as `client`.
- redeem the same code twice → second is `pairingCodeInvalid`.
- redeem after 601 s → `pairingCodeInvalid`.
- mint twice → the first code no longer redeems.
- five wrong secrets → the right secret is then `pairingCodeInvalid`.
- revoke the grant → `authenticate` returns nil.
- 20 concurrent redeems of one code → exactly one success.
- `api-keys.json` never contains the secret or the token (read the file).
- a pre-change `api-keys.json` fixture (version 1, one key without scope) →
  loads, `effectiveScope == .admin`.
- `touch` twice within 60 s → `lastUsedAt` unchanged the second time.

`PairingAddressTests`:
- `http://127.0.0.1:8787`, `http://localhost`, `http://0.0.0.0:1`,
  `http://[::1]`, `http://[::]` → not routable.
- `http://192.168.1.5:8787`, `http://100.100.1.2`, `http://10.0.0.1`,
  `http://[fd00::1]` → accepted.
- `http://example.com`, `http://8.8.8.8`, `http://172.32.0.1` → requires TLS.
- `https://example.com` → accepted; `https://user@example.com`,
  `https://example.com/x?y=1` → invalid.

`PairingHTTPTests`:
- valid redeem → 200 with token, `no-store`.
- bad JSON, missing field, browser `origin` header, wrong secret → 403
  `pairing_code_invalid`.
- other path → nil.
- after success and failure the audit file has `redeem` and `redeem_failed`
  lines and no line contains the secret or the token.

`APIScopePolicyTests`:
- read + query → nil; read + any mutation → violation.
- operate + `setBotPaused` → nil; operate + `removeBot`, `mintPairingCode`,
  `addRemote` → violation.
- admin + anything → nil.

`ServerIdentityTests`: created once, stable across loads, name update keeps id.

## Verification

```
mkdir -p tmp/bots-overview/bots-08-pairing-server
arch -arm64 /bin/zsh -lc 'swift test --filter "PairingCodeTests|PairingAddressTests|PairingHTTPTests|APIScopePolicyTests|ServerIdentityTests|RielaAPIKeyStoreTests|DistributedWorkerAPIKeyTests"' > tmp/bots-overview/bots-08-pairing-server/test.log 2>&1
```

Exit 0. Evidence: new suites pass; existing API key and worker key suites
are unchanged.

## Done criteria

- `grep -rn "print(\|NSLog\|FileHandle.standardError" Sources/RielaServer/RielaPairing*.swift` prints nothing.
- Verification exits 0; progress log written.
