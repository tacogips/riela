# Built-in gateway JSON requests

Available in Riela 0.2.45, tracked by issue #176. The complete ART migration,
validation/catalog reconciliation and production cutover remain unfinished.

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

The matrix describes execution support. Core catalog discovery and validation
reconciliation are still acceptance work; structural workflow validation alone
does not prove that every operation exists in an installed gateway image.
Availability of a host SDK does not make it available in a Linux guest: only
Gmail, Wrike and X in this matrix have portable linked execution, while native
Apple operations use the host bridge. Existing provider authorization still
applies.

For catalog-backed gateways, `operation` and `selection` are literal authored
values. `arguments` renders once: exact placeholders preserve numbers, booleans,
arrays, objects and null. A substituted source string containing `{{...}}` is
not evaluated again. Unknown operations, invalid fields and type errors are
rejected before provider execution. Legacy Gmail reader documents are rechecked
after type-aware literal serialization, including enum values. Legacy container
JSON documents are limited to 120,000 UTF-8 bytes to fit a Linux argv entry.

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
finite operations as `riela/data-transform`:

| Instruction | Meaning |
| --- | --- |
| `{"pick":"/data/items"}` | select a JSON Pointer |
| `{"map":{"id":"/id","author":"/author/username"}}` | project each array element into named fields |
| `{"filter":{"path":"/enabled","equals":true}}` | retain matching array elements |
| `{"unique":"/id"}` | keep the first element for each pointer value |
| `{"take":25}` | retain at most that many array elements |

Limits are 32 instructions, 8 MiB intermediate values and 10,000 array entries,
with bounded paths and mapping fields. No expression evaluation, script or
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

Both X readers support `usageCache: true`. The built-in records upstream resource observations in `x-gateway-api-usage`, scope `observations`, independently of article and user caches. Its default policy is 35 days / 10 MiB, unprotected TTL/LRU. Set `usageScope` to a stable application identifier shared by that application's OAuth/Bearer readers. Without a configured application scope, credential fingerprints are explicitly not reliable application-level billing deduplication. No credentials, source text, raw IDs, URLs or usernames enter usage records; IDs are SHA-256 hashes and response days are UTC.

`resourceUsage` counts upstream resources before projection and cache author restoration, including reference and missing-author lookup responses. Returned resources, local deduplication and provider billed units are different. Unsupported/invalid telemetry is a missing observation, not zero usage. Failed operations preserve observations received before failure. `riela cache keys x-gateway-api-usage --scope observations` lists retained events for batch cache get; this is a disposable observation history, not an invoice or an indefinite ledger.

Private workflows opt in with `config.xUsageScope`. Their SDK readers still set `usageCache: true`; normalized telemetry is forwarded over a dedicated stderr record to the host cache before the guest is removed, independently of success/source-output validation. Only markers received by the host survive cancellation; an interrupted HTTP call or a missing marker is not proof of zero billing. Private raw stdout/stderr is never included in the source result. Finite cache status counts are exposed as backend events.
