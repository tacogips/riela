# Expected Results

## Deterministic Gate

`bash examples/monja-typescript-sdk/scripts/verify.sh` exits zero and ends with:

```text
monja-verify: packed SDK, REST, GraphQL, JSONL, URL policy, and secret checks passed
```

Stable assertions:

- `@monja/client` is built before packing and the archive contains
  `dist/index.js`, `dist/index.d.ts`, and `package.json`, but no `src/` files.
- The installed package resolves from the generated consumer under Riela
  `tmp/`, and emitted code runs as Node ESM without CommonJS wrappers.
- Riela accepts exactly one command output object whose `status` is `ok`.
- The safe REST result has principal kind `apiKey`; GraphQL returns the
  deterministic `riela-sdk` identity.
- The authenticated request order is exactly `GET /api/v1/auth/me`,
  `GET /api/v1/server-capabilities`, then `POST /api/v1/graphql`.
- The URL-policy verifier performs zero network calls. Only the `127.0.0.1`
  case is an end-to-end plaintext transport test.
- Empty, non-object, multiple, and oversized JSONL inputs fail without stdout.
- Oversized GraphQL queries and variables, missing configuration, invalid
  timeout values, and non-loopback HTTP fail before any network call.
- REST failure, disabled GraphQL capability, GraphQL failure, timeout,
  oversized REST/GraphQL responses, and oversized final output all fail with
  bounded classifications and no stdout record.
- Captured evidence contains no ephemeral API token.

Node version, resolved package path, tarball checksum, generated manifests,
lockfile, and transient logs are runtime evidence below `tmp/`; none are
committed because paths and versions can vary by verified environment.

## Live Boundary

A live result is intentionally not prescribed. It requires an operator-started
Monja deployment, an appropriately scoped API key, GraphQL enabled in server
capabilities, and a supported Node runtime with ESM and global `fetch`. The
portable live probe is read-only. No live deployment or mutation is claimed by
the deterministic gate.
