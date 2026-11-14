# App-managed API and worker authentication

## Requested outcome

The Mac app issues, persists and revokes API keys. Its Settings screen controls
whether machine API calls require a key. Clients use an issued key without
configuring a shared server environment secret. Issuance supports a chosen
expiration time or no expiration. Workers authenticate to their controller with
separately scoped, app-issued keys. `RIELA_MANAGER_AUTH_TOKEN` is removed from
server authentication and client defaults.

## Existing behavior and integration points

- `RielaAppWebRouter` applies `RielaWebRequestSecurity` to `/api/v1` and
  `/graphql`. POST requests require the app's Host, Origin and CSRF token.
- `RielaAppWebGraphQL` converts admitted requests to local trusted requests
  before composing execution, session control, registry and configuration
  executors. Therefore authentication must precede this conversion.
- `ServeHTTPCommand.serveMachineGraphQLAdapter` and `ServeWebHost` use
  `RIELA_MANAGER_AUTH_TOKEN` for external execution/task authentication. The
  GraphQL wrapper currently checks only execution roots; an HTTP gate is needed
  to cover other machine operations consistently.
- `DistributedControllerConfiguration.Worker` currently names an environment
  variable. The app loads its plaintext value from `controller.env` and
  `DistributedWorkerHTTPRouter` retains a static array of plaintext credentials.
- `DistributedWorkerCommand` already supports outbound `tokenFile` or
  `tokenEnvironment` credentials and excludes the token environment variable
  from node execution environments. The transport refuses redirects and
  defaults to HTTPS except for loopback connections.

## Trust boundaries

| Surface | Authority | Policy |
| --- | --- | --- |
| Native desktop Settings | Local operator via inherited IPC | Issue/revoke/configure keys only here; require expected profile for mutations |
| Same-origin browser Settings | Browser operator | Keep Host, Origin, CSRF and profile checks; key administration is unavailable |
| Machine `/graphql` and existing task API | Client API key | Require persisted client key when enabled; bypass only this key requirement when disabled |
| `/distributed/v1/worker` | Worker API key | Always require live worker-scoped key, regardless of client toggle |
| Inherited-pipe/local runtime execution | Runtime provenance | Preserve existing local trust; never derive it from a network header |
| Runtime manager session controls | Session authority | Preserve manager-session authorization and attachment scoping after transport authentication |

An API key does not grant access to its own issuance, revocation or policy
management routes. Machine key authentication must not bypass browser CSRF on
Settings, expose the app bootstrap CSRF token, or claim arbitrary local working
directory authority. Requests with Origin remain browser requests; a Bearer
header must not allow a hostile browser Origin through the native machine
branch. GET/HEAD machine reads need the same key policy as mutations.

The disabled client-key setting is explicit local operator policy, not an
inference from a missing/corrupt store. Storage errors fail closed. In disabled
mode, missing credentials may access designated machine endpoints, but a
provided invalid, expired, revoked or wrong-purpose key must not authenticate.
The local administrative surface remains available so the operator can recover
or change policy without a working machine key.

## Persistent credential model

Use a shared server-layer store at the stable app-global path
`~/.riela/rielaapp/api-auth`. The same instance/path is supplied to app machine
routes, the distributed controller and CLI serve. Client keys authorize the
active server profile; switching profiles does not silently invalidate them.
Worker IDs form an app-global identity namespace: a worker key can authenticate
in any active profile that configures that worker ID, with the active profile
providing its groups and capacity. A stale Settings view includes the expected
profile and cannot issue a worker key against a newly selected profile.

Persist a versioned document containing `requireClientAPIKey` and key records:

- Stable ID, display label, purpose (`client` or `worker`), creation timestamp.
- A SHA-256 digest of the complete generated secret; never the secret itself.
- Optional absolute UTC expiration and optional revocation timestamp.
- For worker keys, controller-owned worker ID binding. Groups and maximum
  capacity remain controller configuration, never caller-controlled claims.

Secrets use at least 32 cryptographically random bytes, encoded as printable
ASCII with a distinguishable prefix and optional public lookup ID. Hashing is
appropriate for high-entropy generated credentials; user-chosen passwords are
not accepted. Compare digests in constant time. Reject unbounded or malformed
credentials before hashing. Duplicate worker key records may support rotation;
they must bind to the same configured worker principal, not duplicate
registrations or worker capacity.

The store serializes mutations and uses restrictive directory/file permissions,
atomic replacement and cross-process coordination where the app and CLI may
share a path. Each authentication observes committed current policy and records
so revocation, expiry and toggles apply to existing listeners without restart.
Do not overwrite unreadable/unsupported-version documents with permissive
defaults. Successful issuance is returned only after persistence succeeds.
Persisted list results contain metadata only. Raw values appear once in the
issuance response and transient UI; they are absent from logs, normal status,
workflow variables, job payloads, receipts and runtime records.

## Mac Settings workflow

Add an API Keys pane with:

1. A persisted "Require API key for client requests" switch and visible current
   policy. Explain that worker authentication remains mandatory in the change-confirmation dialog.
2. A metadata list showing label, purpose, created date, expiration/no expiry,
   active/expired/revoked state and worker ID when applicable.
3. Issuance with label, client/worker purpose, configured worker ID for worker keys,
   and expiration date/time or explicit no-expiry selection. Reject dates at or
   before the current time and invalid/nonfinite values.
4. A one-time secret display with Copy and close actions. Closing or leaving the pane
   removes the transient secret. Normal listing cannot retrieve it again.
5. Individual revocation, updating the list only after the store commits it.

Both client and worker keys obey `now < expiresAt`; equality is expired.
Expiration is checked on every request using an injectable runtime clock for
tests. An expired worker key cannot register, claim, renew, append events,
complete or acknowledge a stop. Existing leases retain runtime-owned timeout
and recovery semantics rather than acquiring authority from lease tokens alone.
Rotation consists of issuing a replacement, updating the client, then revoking
the old key. A worker key must be bound to an existing configured worker; the
worker cannot select arbitrary ID, groups or capacity.

## Worker/controller integration

Controller configuration becomes identity and placement metadata, not secret
storage. Managed workers use the shared API key store; app setup no longer
requires editing `controller.env`. Existing controller token-variable records
decode as identity/placement metadata with retired token-variable fields ignored.
Migration documentation instructs operators to issue a worker key and remove
retired fields and `controller.env`. No legacy credential values are accepted.

The router resolves the Bearer key against the current store for every request,
checks worker purpose, expiry and revocation, then maps its worker ID to current
configured groups/capacity. Client keys cannot access worker operations; worker
keys cannot access GraphQL or administrative routes. Keep the existing Origin
rejection, exact path/query checks, JSON/body limits, registration incarnation,
job ID, lease token, result/event validation and capability constraints.

The worker keeps the issued plaintext secret locally through existing
`tokenFile` or `tokenEnvironment`. A token file is outside workflow bundles and
protected with owner-only permissions; the controller stores only its digest.
The outbound worker keeps existing TLS and redirect controls. This is bearer
authentication over the trusted transport, not a new challenge protocol.

## Client and CLI contract

Clients send `Authorization: Bearer <issued-key>`. Native machine requests do
not need browser Origin/CSRF. Browser and desktop management requests retain explicit profile provenance.
Native machine requests bind to the active server profile and do not require
`x-riela-profile`; supplied keys authenticate app-global client authority.

CLI remote workflow and task clients accept the existing explicit token option
and custom environment-name option, with the default renamed to `RIELA_API_KEY`.
A file option can avoid shell history/process argument exposure if added
consistently. No client or server falls back to `RIELA_MANAGER_AUTH_TOKEN`.
CLI serve consumes the same persisted key policy and records at the resolved
app-home path rather than accepting a new server shared-secret environment
variable. Issuance remains in the Mac app management UI.

Remove old environment instructions, examples and tests that treat the old token
as active authentication. Diagnostic migration text may name the removed
variable but must not read or honor its value. Retain unrelated third-party
provider credentials and session manager tokens.

## Acceptance evidence

- Fresh issuance returns one secret; on-disk bytes and list responses omit it.
- Store/listener recreation accepts a previously issued key and retains policy.
- Issuance failure does not expose an uncommitted credential.
- Revocation and policy changes affect an already running listener immediately.
- Client-required mode rejects absent/invalid/worker keys on machine reads and
  mutations; disabled mode admits absent client credentials only on designated
  machine endpoints. Administrative routes remain browser/native authorized.
- Host/Origin/CSRF hostile-browser cases remain rejected with and without a key.
- An issued worker key registers and executes a real bounded job exchange;
  client, expired and revoked keys fail every worker operation. Worker identity,
  groups and capacity are controller-owned; worker keys never grant client or
  Settings authority.
- Boundary-time and restart tests prove expiry for both purposes. UI issuance
  covers chosen expiry and no expiry and displays expired state.
- Profile changes reject stale worker issuance requests. App-global client keys
  remain usable after a profile switch; worker keys resolve only to worker IDs
  configured by the active controller.
- Remote CLI workflow/task requests use the new default; the removed environment
  variable alone cannot authorize server or client operations.
- Focused Swift suites, arm64 build, SwiftLint, browser Settings tests and current
  debug Mac app UI verification cover the final implementation. Rendered/UI
  evidence must show usable management, copying, revocation and policy controls.

## Settings usability refinement

Shared actions display their operation names with semantic SVG icons; Settings
uses a cog and key issuance/revocation use key/key-off icons. Unrecognized actions
remain text instead of acquiring an unrelated arrow. Icon-only controls require
explicit opt-in. The header uses Riela's existing rail silhouette.

API Keys omits a manual refresh button and introductory prose. Listing refreshes
after mutations. Issuance and client-policy changes display action-specific
confirmation dialogs. The user selects an issued key, then uses the separate
red Revoke key action beneath the list; a confirmation identifies the exact key
and effect before mutation. Cancel/Escape performs no write. Explanatory text
about persistence, one-time disclosure and access consequences belongs in these
dialogs. The main pane retains necessary names, purposes and timestamp metadata.
