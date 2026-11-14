# Builtin gateway command delegation

Use `riela gateway` for commands owned by the embedded gateway SDKs:

```bash
riela gateway list
riela gateway list --json
riela gateway <name> [--role ROLE] <gateway-command> [gateway-options...]
```

The optional `--role` precedes the gateway command. Everything after that point
is passed unchanged to the selected native SDK. `riela gateway NAME --help`
shows its original help, including the SDK executable name; invoke that command
through the Riela prefix instead. No standalone gateway executable is needed.
Riela's own `riela auth` passkey commands remain separate.

| Gateway | Roles (first is default) | Authentication surface |
| --- | --- | --- |
| `gmail` | reader, draft, sender, threads, message-box | `auth setup`, `login`, `status`, `logout`, `revoke`; reader/draft/sender use persistent auth, the two other modes retain the SDK's legacy contract |
| `x` | reader, writer | `auth oauth2`, `verify`, `scopes`; OAuth2 supports `--store kinko` |
| `apple` | full, reader | `permissions status`, `permissions request` |
| `wrike` | reader, writer, admin | `auth oauth2`, `status`, `logout` |
| `google-service` | auth | `clients`, `consent`, `scopes`, `auth`, `oauth` |
| `google-analytics` | reader, writer, admin | `auth login`/`oauth2`, `status`, `logout`, `doctor` |
| `google-docs` | reader, writer | `auth login`, `status`, `logout`, `revoke` |
| `google-sheets` | reader, writer | `auth login`, `status`, `logout`, `revoke` |
| `google-drive` | reader, writer | `auth login`, `status`, `logout`, `revoke` |

The list reports whether a gateway is linked on the current platform. Wrike and
Google Service are available on Linux; the other currently linked native SDKs
require macOS. Gmail/X workflow reader images remain available independently.

For Gmail, register a shared Google OAuth client or configure a credential's
client, then start the SDK's native browser authorization:

```bash
riela gateway google-service clients register --file /path/to/client.json
riela gateway gmail auth login --credential gmail-personal
riela gateway gmail auth status --credential gmail-personal
```

For an explicit per-credential client setup, follow the current SDK help:

```bash
riela gateway gmail auth setup --credential gmail-personal --client-secret-path /path/to/client.json
riela gateway gmail --role sender auth login --credential gmail-personal
riela gateway google-docs --role writer auth login --credential docs-writer
riela gateway x auth oauth2 --store kinko
riela gateway apple permissions status --json
```

Google gateways use the same shared-client registration, provider selection,
credential storage, callback handling, and post-success cleanup as their own
executables. Explicit `--provider gcloud` remains an SDK option and requires its
gcloud helper. Native login can open a browser and wait for a loopback callback;
run it on the intended host with the SDK's callback options. Wrike and X may use
Kinko according to their native storage contracts. Apple permissions apply to
the host application's macOS permission identity.

Supply credential values through the SDK's environment/file contracts. Status
and help preserve the native SDK's metadata output; explicit native token-export
commands retain their own semantics. Riela does not capture these commands as
workflow steps, and the existing workflow add-on restrictions are unchanged.
Native stdout/stderr are preserved; a nonzero native status maps to Riela exit
status 1, while an invalid Riela gateway name or role uses status 2.
