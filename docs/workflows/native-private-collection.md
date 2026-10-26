# Native private collection (in progress)

The ART migration still needs a whole-workflow guest boundary. Per-agent
isolation cannot protect raw gateway results already stored by a host workflow.

## Embedded X reader (0.2.39)

`riela/x-gateway-reader` calls the pinned XGatewayCore read surface in process on
macOS and Linux. It launches neither a gateway executable nor a second container.
Its queryTemplate / selectFirst / whenFlags / payloadExtras use the common
local gateway contract. Prefer `operation`, JSON `arguments`, and a `select`
field tree for typed requests; see [JSON data processing](json-data-processing.md)
for inline `postprocess` and standalone transform nodes. GraphQL variables are
unsupported by the pinned X CLI surface. Mutation operations are refused.

```json
{
  "id": "account",
  "addon": {
    "name": "riela/x-gateway-reader",
    "version": "1",
    "config": {"queryTemplate": "query { accountMe { id username } }"},
    "env": {"X_GW_TOKEN": {"fromEnv": "SOURCE_X_TOKEN"}}
  }
}
```

Only the six X token/OAuth1 credential names may be env binding targets. The SDK
gets no retries (`--retry 0`). Each HTTP request has a timeout of 30 seconds or the
remaining node deadline, whichever is smaller. One X query can issue several
requests (expansions, references, author lookups). The node deadline bounds the
whole step: at the deadline the step fails with `timeout` and the abandoned SDK
call is discarded. The workflow owns pagination, retry and partial-result decisions. Provider error
bodies are replaced by fixed messages. Its raw output remains in the calling
runtime: use the private workflow boundary for ART acquisition before making it
an active source node.

## Whole-workflow boundary (0.2.39)

The `riela/private-workflow` add-on invokes a static workflow through embedded
Riela inside an owned Linux container. The outer workflow declares the guest
image, credential bindings, inner workflow and export schema. No Python or nested
Riela CLI process constructs or coordinates the graph.

```json
{
  "id": "private-collection",
  "addon": {
    "name": "riela/private-workflow",
    "version": "1",
    "config": {
      "workflowId": "collect-and-screen",
      "definitionRoot": "/app/workflows",
      "variables": {"window": "{{input.window}}"},
      "maxConcurrency": 4,
      "maxSteps": 1000,
      "timeoutSeconds": 600,
      "outputSchema": {
        "type": "object",
        "required": ["checkedItems"],
        "properties": {"checkedItems": {"type": "array", "items": {"type": "object"}}},
        "additionalProperties": false
      }
    },
    "env": {"X_GW_TOKEN": {"fromEnv": "SOURCE_X_TOKEN"}},
    "sandbox": {
      "backend": "container",
      "networkPolicy": "egress-allowed",
      "ephemeralHome": true,
      "credentialEnvironment": {"MODEL_AUTH_JSON": ".codex/auth.json"},
      "container": {"runtime": "apple-container", "image": "your-private-workflow-image:version"}
    }
  }
}
```

Package definitions and required executables in the image. Inner agent nodes use
the guest environment directly and do not declare another container. Their model,
prompt, output contract and tool policy remain ordinary authored node settings.
Gateway and deterministic data nodes run within the same guest runtime.

`config.entryStepId` optionally selects a declared entry step inside that same
workflow definition. Use it to keep a provider's public controller and private
collection/inspection subgraph together. Same-workflow native fanout can run
inspection batches without separate helper workflows. The ordinary CLI entry
is unchanged; the embedded override rejects missing steps before execution.

Only the inner root output is returned. Every intermediate step's session,
artifact, working directory and memory reside under a private guest tmpfs root.
Embedded execution renders only the root and finite lifecycle metadata rather
than serializing the entire session transcript for extraction. Canonical runtime
and CLI session persistence are retained inside the guest; an additional set of
file artifact snapshots is not produced.
The export schema is checked in the guest and controller. It establishes a
structural contract; the authored screening/normalization graph must establish
the semantic boundary for source content.

The worker requires Linux, non-root identity, no capabilities, no-new-privileges
on every current thread, a read-only root and a bounded nosuid/nodev/noexec `/tmp`
tmpfs. The default is 256 MiB. `config.temporaryStorageMiB` optionally selects
64–4096 MiB for graphs whose private runtime records need more space. An
explicit quota also allocates container memory equal to that quota plus
1024 MiB for processes. The guest checks the global ceiling before reading
input and then checks the configured ceiling before starting the graph.
A pre-main native initialization sets privilege and process/core limits
before Swift creates threads. The host refuses unsupported configuration and
reserved environment names before launching; there is no host execution fallback.
Selected secrets travel on attached stdin only. Failures use finite fixed text;
provider events, prompt text, usage and vendor session IDs are not exported.
Exception: with `config.xUsageScope`, normalized X resource-usage telemetry (no
source data or credentials) is forwarded to the host's `x-gateway-api-usage` cache
over a bounded stderr marker channel (at most 2,000,000 bytes per line, 10,000
resources per record and 256 records per run).

Optional `config.cacheSpaces: ["x-gateway-users"]` bridges the builtin author
cache across ephemeral guests. The host seeds only validated public user IDs,
usernames and display names, with their original provider-fetch timestamps.
The guest uses a separate native cache root; no host database or cache directory
is mounted. New author metadata is validated and merged into the host cache even
when the private workflow's final result is rejected. Cache reads and seeds do
not renew the original TTL. Article bodies and authentication data are never
accepted in this channel.

The builtin registry owns each approved space's schema and storage. Unknown or
duplicate space names are refused before container launch. The transport admits
at most 64 records, 1,000,000 bytes per line and 8,000,000 bytes per run. Optional
cache failures become cache misses; normal provider output retains its own
validation. The `private-cache-exchange` backend event contains only configured
space names, finite statuses and counts. Omitting `cacheSpaces` disables both
seed transfer and delta export. Matching host and guest binaries with this
capability are required.

Optional `config.failureStages` maps root step IDs to public diagnostic labels:

```json
"failureStages": { "collect": "acquisition", "batch": "screening", "finish": "normalization" }
```

At most 32 mappings are allowed. Public labels contain lowercase letters, digits
and hyphens and are at most 48 characters. On failure, only a configured label and
one of `adapterFailure`, `nodeTimeout`, `cancelled`, or `other` can leave the guest.
The host validates both before emitting a `private-workflow-failure` backend event
and the fixed diagnostic message. Internal step IDs, command stderr, provider
errors, source content and paths remain private. Unknown labels/kinds and disabled
configuration retain the original fixed failure message. This reports where the
root graph stopped; a nested failure may be reported at its calling root step.

The owned container is removed after completion, deadline or cancellation.

Guest identity requirements:

- Run the image with a non-root uid **and** a non-zero gid (`USER 10001:10001`).
  `docker run --user 1000` or `USER 1000` without a group yields gid 0 and is
  refused. The shipped `containers/builtin-addons/Containerfile` runs as root and
  cannot host this worker.
- Do not share the guest uid with host users. `RLIMIT_NPROC` counts every task of
  the real uid, and rootful Docker/Podman on Linux share the host uid space, so a
  busy host user can exhaust the guest's thread/child budget. Prefer a dedicated
  uid and add a per-container `--pids-limit` where the runtime supports it.
- The process limit is `min(inherited hard limit, 1024)`. A lower inherited hard
  limit (for example `--ulimit nproc=512`) is honored instead of failing.
- A refused identity or limit exits the worker with status 112 before any input
  is read. The controller reports it as `policyBlocked` with the fixed message
  "private worker refused the guest identity or resource limits".

Controller-side mapping: only the validated root payload is guest-controlled. The
controller sets the exported `provider` (`riela-private-workflow`), `model` (the
inner `workflowId`) and routing (`always`) itself instead of trusting guest stdout.
An inner graph that reaches its deadline fails with `timeout`, so outer
`nodeTimeout` retry policy applies. Any other non-zero worker exit is a
`providerError` (the same mapping the sandboxed agent host uses). The request and
record protocol is v2; a v1 worker refuses a v2 request before reading private
input, and the controller refuses v1 records as an outdated worker image.

Focused unit coverage exercises builtin dispatch, actual embedded graph execution,
strict final output, metadata rejection, configuration validation, selected-secret
transport and cancellation cleanup. `PrivateWorkflowLiveTests`, enabled with
`RIELA_PRIVATE_WORKFLOW_IMAGE`, checks the real Linux boundary and an inner fake
vendor against synthetic source/auth. It requires a matching 0.2.39 image and
does not contact an account or inference provider. An opt-in test skip is not
evidence that the OS boundary passed.

## ART migration requirements

- An authored private-workflow add-on must run a complete static workflow inside
  the owned container via embedded Riela, with no Python process/CLI coordinator.
- Reuse the ephemeral detached-init/attached-exec lifecycle. No writable host
  shares, provider/tool events, raw inner session records or secret environment
  values may leave guest tmpfs. Only an explicit validated root schema crosses.
- Project selected runtime environment bindings on stdin, never container argv
  or client environment. Model auth files are created only in guest HOME.
- Verify read-only root, non-root identity, capability removal, no-new-privileges
  and bounded nosuid/nodev/noexec tmpfs before reading private input.
- Root output gets guest and controller validation. Failures are finite fixed
  errors. Deadline/cancellation reaps the exact owned container.
- Run generic builtins, static agent nodes, source pagination/fanout and small ART
  domain format/validation nodes inside this boundary. Keep controller-owned
  durable checkpoints and cache reference protection as explicit builtin steps.
- GmailGatewayCore's Linux support must be adapted before moving Gmail's read
  node into this graph. Preserve its token/auth lifecycle and read-only tier.

This foundation is not an ART deployment or completion of Python minimization.

Host-side pending metadata discovery and fair recovery turns can use
[`snapshot-scan` and `snapshot-rotate`](native-metadata-queues.md). These builtins
retain exact scoped heads and legacy cursors without a per-file Python/CLI loop.


### Bounded cache availability scan

`riela/cache-exchange` version 1 supports `action: "read-scan"`. It uses the
same named `stores` and ordered `{id, store, reference}` requests as `read-set`.
All stores, alias policies and references (including the unread tail) are
validated before cache configuration or reads. The node owns the finite scan;
a worker does not need to start one CLI process for each missing body.

```json
{
  "action": "read-scan",
  "stores": "{{bodyStores}}",
  "requests": "{{orderedBodyRequests}}",
  "startIndex": 0,
  "maxHits": 12,
  "maxExamined": 256,
  "maxItemBytes": 1000000,
  "maxOutputBytes": 7991808
}
```

The response contains ordered `results` with `id`, `status` (`hit`, `missing`,
`expired`, `oversized`) and a payload only for hits. It also reports `nextIndex`,
`examinedCount`, `hitCount`, `complete` and `stopReason` (`end`, `hit-limit`,
`scan-limit`, `output-budget`). Resume with the same request list and
`startIndex: nextIndex`. An output limit leaves the next unconsumed item at
that index; a body too large for an entire response is classified oversized,
so it cannot cause an endless resume at the same item.

`maxHits` is an upper bound: two available bodies are returned immediately,
even when it is twelve. Missing/expired bodies never acknowledge durable work,
advance a provider cursor or renew TTL. `complete` means the requested cache
scan ended; it says nothing about collection or publication completion.
Cancellation and the execution deadline are checked before mutations and at
each scan iteration. Per-item byte metadata is checked before large payloads
are loaded. Limits are 10,000 requests, 1,024 examined items per invocation,
8 MB per item/output (with protocol envelope reserve); defaults are 40 hits,
256 examined items, 1 MB per item, and 7,991,808 output bytes.


### Provider-independent record admission

`riela/record-manifest` action `admit` selects a bounded available batch without
provider calls, persistence, cursor changes or publication acknowledgements.
Use this after an availability scan for Gmail, X, Web or any other source:

```json
{
  "action": "admit",
  "value": {
    "entries": [{"key": "opaque-id", "version": "opaque-version", "value": {"sourceId": "source-id"}}],
    "available": [{"key": "opaque-id", "version": "opaque-version", "payload": {"checked": "body"}}],
    "acknowledged": [],
    "priority": [],
    "examinedKeys": ["opaque-id"],
    "maximumItems": 12,
    "maximumBytes": 1000000
  }
}
```

The result contains `admitted`, `deferred`, `handled` metadata entries,
`records` (admitted payloads), and `unavailableKeys`/`oversizedKeys`. Two ready
items return immediately even when the limit is twelve. A byte limit may defer
a large remaining item while admitting a later smaller one. A body individually
larger than the byte limit is oversized; an item that only exceeds the remaining
batch space is deferred. Unexamined items are deferred without claiming a miss.

Only an explicit acknowledgement of the same key and version produces handled
metadata. Changed versions become eligible again. An existing `priority` prefix
is honored only if every complete descriptor still matches an unacknowledged
entry; otherwise fresh inventory order applies. Available bodies with unknown
keys, different versions or duplicate identities are rejected, including an
invalid tail after the count limit. Callers retain their domain-specific source,
account and body-digest checks. Keys and versions are opaque bounded UTF-8 values.
Defaults are 40 items and 1,000,000 encoded payload bytes; limits are 10,000 items
and 8,000,000 bytes. All request metadata is validated before selecting a result.


### Private worker input delivery

The native node and private-workflow workers distinguish an empty request from
malformed JSONL, invalid UTF-8, unsupported capabilities and execution failures.
Framing uses ASCII LF: Unicode NEL/line/paragraph separators inside JSON string
values remain data. The builtin add-on worker uses the same framing rule.

A private container may attach one additional time only after a sole, current
worker-protocol refusal explicitly reports no request bytes. That refusal is
emitted before request decoding, credential HOME setup and provider/model calls.
The retry uses the identical stdin and the same owned container/deadline. Model
failures, schema rejections, partial/unknown outcomes, nonempty stderr and legacy
ambiguous framing failures never authorize it. Cancellation and final container
cleanup remain owned by the original invocation. A second empty refusal stops.

The host records `private-input-reattach` with only `attempt: 2`,
`phase: "before-request"`, and `reason: "empty-request"`. Neither the first
refusal nor private data becomes an additional terminal result. Both host and
guest must contain this explicit refusal to enable the recovery path.


Embedded private execution keeps its complete canonical runtime records and
failure-stage evidence in the guest tmpfs. It omits the second CLI session
projection on each event; normal `riela workflow run` inspection records are
unchanged. The terminal canonical record still includes final gate/evidence
status. Only the validated root is returned to the parent.
