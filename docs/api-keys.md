# API keys

Open **Settings → API Keys** in the Mac app's local desktop window. Set a name,
choose **Client API** or **Worker → controller**, and optionally choose a local
expiration date/time. Blank expiration means no expiry. Worker keys require an
ID already saved in the active profile's Worker Controller settings.

**Issue API key** opens a confirmation; confirming returns the secret once. Copy it and store it on the client;
leaving or dismissing the issuance view removes it from the screen. List results
contain only metadata. The app stores SHA256 hashes, never plaintext keys, in
`api-auth/api-keys.json` beneath its app root (normally
`~/.riela/rielaapp`). Files are private to the OS user. File locking and atomic
writes preserve concurrent issuance, revocation and policy updates.

Select a key in **Issued keys**, then choose the red **Revoke key** button beneath
the list. Confirming permanently rejects that key on subsequent requests. Expiration is
checked using the server clock on every request; renew by issuing a replacement
key and revoking the old one. Revocation or expiry stops subsequent worker
messages, including lease renewal and completion. Already admitted operations
are not retroactively cancelled; a worker that loses authorization cannot renew
its lease. Plan rotation before the old key expires.

**Require an API key for client requests** defaults enabled and persists across
restarts. Disabling it admits native clients without credentials. A supplied
invalid, revoked, expired or worker-purpose key is rejected even when the
requirement is off. Worker authentication remains mandatory. Policy changes require confirmation;
re-enabling takes effect immediately. Store corruption/unavailability fails closed.

Client keys grant the existing operator GraphQL surface. They do not grant key
administration, which is restricted to the local inherited desktop IPC channel.
Browser consoles retain their own same-origin/CSRF or Passkey authority. Keys
and policy are app-global; client requests use the host's active profile and
worker keys use a global worker-ID namespace, constrained by the controller's
current configured workers/groups/capacity.

## Clients

Set `RIELA_API_KEY` on the client to the issued value, then run:

```sh
riela workflow run my-workflow --endpoint http://127.0.0.1:19091/graphql --output json
```

Existing `--auth-token-env` selects another credential environment variable.
HTTP clients send `Authorization: Bearer <issued-key>` and JSON to `/graphql`.
Native clients omit browser Origin and CSRF headers. `RIELA_MANAGER_AUTH_TOKEN`
is no longer a server authentication source. CLI `riela serve` shares the default
app store on the same OS account. A custom Mac app root keeps its keys separate.
Use HTTPS for connections outside loopback.

## Workers

Copy the issued worker key into an owner-only regular file on the worker, set
`"tokenFile": "worker.token"` in worker configuration and run
`riela worker --config worker.json`. A trailing newline is accepted. The worker
never needs access to the controller's key store. See
[controller and workers](distributed-workers.md) for endpoint and workspace
configuration. Worker keys cannot call the client GraphQL API; client keys cannot
register workers or report results.

## Migration

Issue replacement keys in the Mac app. Replace shared manager credentials on
clients with issued client keys. Controller configurations retain worker IDs,
groups and capacity; remove retired `tokenEnvironment` fields there and retire
`controller.env`. On each worker replace the old token with its app-issued worker
key. Existing worker-side `tokenEnvironment` references are also supported, but
private key files avoid requiring a launch-time environment.

Key lists update automatically after issuing or revoking. Shared controls show
operation names alongside their icons; key administration remains local-only.
