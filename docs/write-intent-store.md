# Durable write-intent store

`riela/write-intent-store` version `1` stores the exact serialized target of an
external write separately from a disposable provider/body cache. It uses native
SQLite KV with two alternating slots per `(rootDirectory, storeId, scope)`.
There is no TTL or LRU eviction. A successful stage returns an opaque reference;
load verifies its owner and original UTF-8 bytes. No source is acknowledged, no
provider cursor advances, and no external service is called by this node.

The application holds its publication/journal fence from staging through durable
pointer commit. Stage with the currently selected reference: the other slot can
be replaced while the selected target remains readable. Stage with `null` only
when there is no selected target. After an interrupted pointer commit, keep
using the previously selected reference. Unknown external write outcomes must
be reconciled against that exact target.

Storage is explicit in all actions:

```json
{
  "action": "stage",
  "storage": {
    "rootDirectory": "/private/workflow-state/write-intents",
    "storeId": "publication-targets",
    "scope": "destination-and-date"
  },
  "key": "rendered-target",
  "serializedJSON": "{{checkedSerializedTarget}}",
  "selectedReference": null
}
```

`serializedJSON` must be valid JSON, at most 16 MiB. The byte string is stored
literally, preserving numeric spelling, timestamps, encoded binary data and
source text that resembles template syntax. Supplied source strings are never
recursively evaluated as templates. The response is `{ "reference": ... }`.
Pass that entire reference as `selectedReference` when advancing the same
publication target to another phase.

Load takes only `action`, `storage`, and `reference`, returning
`{ "found": true, "serializedJSON": "..." }` or
`{ "found": false, "serializedJSON": null }`. An overwritten old slot is a miss;
a foreign owner, malformed payload, or changed selected target is an error.
References bind the canonical root path as well as store/scope, so relocating a
store requires explicit migration.

Clear takes `action: "clear"`, `storage`, and `released: true`. The caller must
first durably clear its verified journal pointer while holding the same fence.
This atomically empties both slots; a crash before clear leaves bounded orphan
data, while a crash before pointer-clear leaves the exact target resumable.
Passing `released: false` is rejected. This field records application evidence;
it is not a substitute for verifying the external write or serializing callers.

The library API is `RielaWriteIntentStore` in `RielaMemory`. The node uses the
same implementation rather than a provider-specific dispatcher or script.
