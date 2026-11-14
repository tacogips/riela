# Built-in gateway JSON requests

Available in Riela 0.2.45, tracked by issue #176. Riela-side workflow
validation/catalog reconciliation for linked built-in gateways is implemented;
the complete ART migration and production cutover remain unfinished.

Gateway nodes can receive typed JSON and shape their results without a Python,
shell or JavaScript helper. The workflow still owns pagination, retries,
concurrency and per-item failure handling.

## Available input surfaces

| Add-on family | JSON request | Selection | Execution boundary |
| --- | --- | --- | --- |
| `riela/x-gateway-reader` | literal `operation`, object `arguments` | required field-path `selection`, or compatibility nested `select` | linked read-only SDK; host or private worker |
| `riela/x-gateway-read` | same X JSON contract | same X fields | existing reader container and explicit environment framing |
| `riela/gmail-gateway-reader`, `-draft`, `-sender` | literal `operation`, object `arguments` | optional field paths, literal selection set, or catalog default | fixed-mode async SDK; host or Linux worker |
| `riela/gmail-gateway-read` | same reader JSON contract | same reader selections | existing reader container; validated typed values become document literals |
| `riela/wrike-gateway-read`, `-write`, `-admin` | literal `operation`, object `arguments` | optional fields, literal selection set, or catalog default | fixed-tier linked gateway |
| `riela/google-analytics-gateway-read`, `-write`, `-admin` | literal `operation`, object `arguments` | optional fields, literal selection set, or catalog default | fixed-tier linked gateway, macOS build |
| `riela/notion-gateway-read`, `-write` | literal `operation`, object `arguments` | optional fields, literal selection set, or catalog default | fixed-role SDK, macOS build |
| `riela/google-docs-gateway-read`, `-write`; `google-sheet-gateway-read`, `-write`; `google-drive-gateway-read`, `-write` | literal catalog command in `operation`, object `arguments` | no selection; shape the result with postprocess | fixed-role SDK argv construction and existing command runner, macOS build |
| `riela/google-service-gateway-read`, `-write` | literal operation such as `services.get`, object `arguments` | no selection; shape the result with postprocess | existing typed service client |
| `riela/apple-gateway-graphql` | literal `operation`, object `arguments` | optional fields, literal selection set, or catalog default | macOS SDK; container requests are prepared on the host and use its existing exact-argv bridge |
| Apple Notes, Mail, Calendar, Reminders, notifications and clock product nodes | operation fixed by add-on name; existing JSON `config`/`inputs` | fixed SDK query and output projection | existing native boundary and scoped host bridge |
| named `kaiba/*` nodes | operation fixed by add-on name; object `arguments` | existing typed result projection | preflight-captured HTTP client; host or worker |
| Kaiba GraphQL compatibility nodes | `arguments` containing `query` and optional `variables` | authored GraphQL document | same preflight-captured HTTP client |

Both X readers support `config.userCache: true` (default: disabled). The built-in
owns the separate `x-gateway-users` cache namespace and its policy: 30 days,
512 KiB, TTL and LRU pruning. It stores only public `{id, username, name}` metadata;
article bodies and credentials never enter this namespace. Reads restore known
authors locally and batch only missing or expired IDs into X user lookups.
Reading a cached author does not renew its TTL. No workflow memory/cache nodes
or Python lookup script are needed. Runtime `RIELA_CACHE_ROOT` can select the
common cache root; otherwise the current user's `.riela/cache` is used, so a
workflow checkout change does not reset the cache. A private ephemeral guest
still needs durable runtime cache storage to reuse it across guest executions.
Cache health is reported as the finite `userCacheStatus` (`ok`,
`write-unavailable`, `unsupported`): in `xGateway.observations` for the embedded
reader and in `xGateway.runtime` for the container reader. A reader image without
the cache exchange still returns its paid data, marked `unsupported`. The cache is
shared by every workflow of the OS user, not partitioned per credential: it holds
only public author metadata, and the SDK uses it only for authors of posts the
caller already fetched.

The matrix describes execution support. `riela workflow validate` checks
catalog-backed built-in gateway operation requests when the corresponding SDK
catalog is available: it rejects mixed operation and legacy modes, non-literal
or malformed operation/selection values, invalid non-templated
`config.postprocess` programs, unknown catalog operations, and a present
`arguments` value that is not an object. A missing `arguments` is accepted, as at
runtime, where it means `{}` (for example `{"operation":"labels"}`). It accepts the
existing aliases and legacy request modes. Templated postprocess programs and
providers without an available catalog are deferred to runtime. Validation for
X readers, legacy container readers, Google Service and Kaiba nested arguments
remains runtime-only; ART migration, release and deployment work also remain
open.
Availability of a host SDK does not make it available in a Linux guest: only
Gmail, Wrike and X in this matrix have portable linked execution, while native
Apple operations use the host bridge. Existing provider authorization still
applies.

For catalog-backed gateways, `operation` and `selection` are literal authored
values. `arguments` is optional (missing means `{}`), is limited to 8 MiB of
encoded JSON, and renders once: exact placeholders preserve numbers, booleans,
arrays, objects and null. A substituted source string containing `{{...}}` is
not evaluated again. Unknown operations, invalid fields and type errors are
rejected before provider execution. Legacy Gmail reader documents are rechecked
after type-aware literal serialization, including enum values. Legacy container
JSON documents are limited to 120,000 UTF-8 bytes to fit a Linux argv entry.

X exposes SDL rather than a catalog, so the X readers serialize their own
literal document. They still use the shared contract: `arguments` goes through
the same bounded renderer, `selection` uses the same literal field-path rules,
and request errors use the same `policyBlocked` code. This is a user-visible
change: X JSON request errors were `invalidInput` before the 2026-10-24 review, so
workflows or retry rules that match that code for X requests must match
`policyBlocked` instead. The nested `select` object
is an X-only compatibility form, and X requires a selection because it has no
catalog default. Integral numbers render as GraphQL integers on every platform
(`25.0` becomes `25`).

Existing GraphQL `queryTemplate`, Docs command/flags and fixed product-node
inputs remain available. Do not mix them with a JSON operation request. Google
Service and Kaiba nested arguments exclude flat config and explicit addon input
overrides. In nested Kaiba GraphQL arguments, `query`, `document` and
`operationName` must remain literal; template data only inside `variables`.
Select the Kaiba instance through top-level `kaibaInstanceId`, not
through argument data; endpoint and authentication remain captured by preflight.

## Example: X posts and their authors

```json
{
  "name": "riela/x-gateway-reader",
  "version": "1",
  "config": {
    "operation": "homeTimeline",
    "arguments": {"maxResults": 25, "paginationToken": "{{input.cursor}}"},
    "selection": ["posts.id", "posts.text", "posts.author.username", "pageInfo.nextToken"],
    "postprocess": [
      {"pick": "/data/homeTimeline/posts"},
      {"map": {"id": "/id", "text": "/text", "authorId": "/author/username"}}
    ]
  }
}
```

Bind the X credential variables explicitly through `addon.env`. Supply a null
cursor for the initial page when its gateway schema permits it. The workflow
can read the original `data.homeTimeline.pageInfo.nextToken`; shaping does not
discard pagination metadata or fetch the next page implicitly.

## Finite postprocess

Every built-in resolver accepts optional `config.postprocess`, using the same
finite operations as `riela/json-transform`:

| Instruction | Meaning |
| --- | --- |
| `{"pick":"/data/items"}` | select a JSON Pointer |
| `{"map":{"id":"/id","author":"/author/username"}}` | project each array element into named fields |
| `{"filter":{"path":"/enabled","equals":true}}` | retain matching array elements |
| `{"unique":"/id"}` | keep the first element for each pointer value |
| `{"take":25}` | retain at most that many array elements |

Limits are 32 instructions, 8 MiB (8,388,608 bytes) of encoded JSON for each
intermediate and final value, and 10,000 array entries, with bounded paths and
mapping fields. The provider payload itself is not size-checked before the first
instruction: container readers repeat the response in `xGateway.data` and
`xGateway.response`, so only the picked values count. A program without
instructions returns the whole payload and is therefore checked. The standalone
`riela/json-transform` add-on also checks its input against the same 8 MiB bound. No expression evaluation, script or
implicit provider retry is available. JSON Pointer rules include `/` and `~`
escaping. Missing `map` field paths project as null; missing `pick` or `unique`
paths fail shaping. `unique` keys must be strings or integers.

The original provider payload remains present. Shaped output is
`payload.processed`. Success sets `postprocessPassed`; a data-dependent failure
sets `postprocessFailed` and returns `postprocess.status: failed` with
`retryProvider: false`. Branch on those flags before consuming `processed`.
This also applies to X reads: shaping failure no longer implicitly fails and
retries their provider operation.

Instruction syntax is compiled before provider effects. After a completed
write, shaping failure preserves the provider result, completion state and
internal finalization receipt. Container dispatch strips the program from its
leaf request so it runs once. Mock-scenario responses use the same shaping path.

Docs operation construction retains its existing command runner; it does not
add the SDK `invoke` file-access policy or execution limits. Apple preparation
retains explicit write-retry metadata and its existing workspace/mount rules.

An executable single-node example with a credential-free mock scenario lives
in [`examples/builtin-gateway-json`](../examples/builtin-gateway-json/README.md).


## X retry failure diagnostics (0.2.47)

The embedded X reader and legacy container reader retain only allowlisted machine
error fields in Riela's failure reason. X gateway 0.1.17 reports the failed HTTP
request's `requestAttempts` (0–11), `retryAttempts` (0–10), cumulative `backoffMs`
(0–6000000), `retryable`, and closed `retryStopReason`, plus HTTP/provider codes.
These are failed-request diagnostics, not total GraphQL-operation or billing
counts. Preflight authorization failures explicitly report `not-started` / zero;
uninstrumented errors omit evidence. Raw provider details remain inside the reader.
The embedded reader still sets `--retry 0`; a retryable failure therefore reports
`retry-disabled`. Retry ownership is unchanged by this observability patch.
Apple Container initialization failures identify their stage and exit status
without forwarding runtime stderr or claiming an HTTP request occurred.

0.2.47 verification: 19 focused CLI/container/JSON tests passed (one opt-in test
skipped); actual native CLI and Apple Container denied-network preflight failures
also retained AUTH_MISSING, requestAttempts0, and not-started through the consumer
parser. X SDK56tests and smoke checks passed; actual Opus5.5 medium review/closure
reported no blocker. macOS arm64 archive SHA256:
`8e88974e705e24baa40bfb332b42ea4e0118b394cc47df22592ba92054c580f2`.
Homebrew upgrade/test and both Linux release builds passed. The follow-up
image-builder adaptation on main recognizes the already portable upstream X
source without rewriting it; the release's Swift source remains identical.


0.2.48 adds the finite provider problem `spend-cap-reached` (X SDK0.1.18).
X can return this billing-limit condition as HTTP403 with a valid user token,
while accountMe continues succeeding. Preserve it separately from unknown
permission errors; HTTP403 remains non-retryable, and no billing settings or
retry policy are changed. Verified against the provider's structured response,
then covered by SDK host/type tests and Riela/consumer masking tests.

## X resource usage cache (0.2.53)

Both X readers support `usageCache: true`. The built-in records upstream resource observations in `x-gateway-api-usage`, scope `observations`, independently of article and user caches. Its default policy is 35 days / 10 MiB, unprotected TTL/LRU. Set `usageScope` to a stable application identifier shared by that application's OAuth/Bearer readers. Without a configured application scope, credential fingerprints are explicitly not reliable application-level billing deduplication. No credentials, source text, raw IDs, URLs or usernames enter usage records; IDs are unsalted SHA-256 hashes computed by the SDK and response days are UTC. Numeric X IDs are enumerable, so these hashes are pseudonymous, not anonymous.

`resourceUsage` counts upstream resources before projection and cache author restoration, including reference and missing-author lookup responses. Returned resources, local deduplication and provider billed units are different. Unsupported/invalid telemetry is a missing observation, not zero usage. Failed operations preserve observations received before failure. `riela cache keys x-gateway-api-usage --scope observations` lists retained events for batch cache get; this is a disposable observation history, not an invoice or an indefinite ledger.

Private workflows opt in with `config.xUsageScope`. Their SDK readers still set `usageCache: true`; normalized telemetry is forwarded over a dedicated stderr record to the host cache before the guest is removed, independently of success/source-output validation. Only markers received by the host survive cancellation; an interrupted HTTP call or a missing marker is not proof of zero billing. Private raw stdout/stderr is never included in the source result. Finite cache status counts are exposed as backend events. The host keeps the guest's `invalid` status when the guest forwarded no observation. The host also bounds the side channel: a marker line is at most 2,000,000 bytes, an observation with more than 10,000 resources is stored as `invalid`, and at most 256 markers are stored per private-workflow run. Later markers are counted as `droppedRecords` in the backend event, not stored.

## X reader transport parity

Both X readers, embedded and container, pass `--retry 0` and `--timeout-ms` to the
SDK. The workflow owns retry and pagination, so SDK retries never multiply paid
reads. The timeout bounds each HTTP request at 30 seconds or the remaining node
deadline, whichever is smaller. It is not an operation bound: one query can issue
several requests, such as expansions, references and user-cache author lookups.

The embedded reader runs the blocking SDK call on a dedicated thread, outside
Swift's cooperative pool. At the node deadline the step fails with `timeout`
immediately; the abandoned SDK call finishes in the background and its result is
discarded. Usage observed by that late call is still recorded when `usageCache`
is enabled, because the read may have been billed.

`addon.env` for either X reader accepts only the credential variables
`X_GW_TOKEN`, `X_GW_APP_TOKEN`, `X_GW_CONSUMER_KEY`, `X_GW_CONSUMER_SECRET`,
`X_GW_ACCESS_TOKEN` and `X_GW_ACCESS_TOKEN_SECRET`. Transport controls such as
`X_GW_RETRY`, `X_GW_TIMEOUT_MS` and `X_GW_MEDIA_ROOT_DIR` stay runtime-owned.
The legacy `X_GW_AUTH_MODE` and `X_GW_ACCOUNT_USERNAME` are not read by the X SDK,
so binding them is rejected. Remove them from older workflows. `riela/x-digest`
still reads `X_GW_ACCOUNT_USERNAME` from the runtime environment.

The embedded reader writes with the riela process's permissions, so it rejects
any document with a `mediaRootDir` argument before calling X. Without a media
root, `downloadMedia` and `forceDownload` have no effect and media stays as
source URLs.

Failure diagnostics still apply when X attaches large `error.resourceUsage`
telemetry. That telemetry is stripped before the 65,536-byte envelope check, up
to 8,000,000 bytes. Every other oversized failure envelope yields no diagnostics.
