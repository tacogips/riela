# Progress tracker builtin

`riela/progress-tracker` version `1` makes bounded continuation decisions from
small, explicitly verified application observations. It does no fetching, model
work, publication, acknowledgement, filesystem locking or durable queue updates.
A caller threads the returned opaque `state` into the next invocation. Workflow
step history can retain that state for resume; a new cycle can start with no state.

```json
{
  "addon": {
    "name": "riela/progress-tracker",
    "version": "1",
    "config": {
      "mode": "identity-sweep",
      "maximumTurns": 64,
      "event": {
        "identity": "item-a",
        "token": "checked-version-2",
        "advanced": true,
        "accepted": true
      }
    }
  }
}
```

Both modes return `state`, `count`, and `canContinue`. Omitting/nulling `state`
initializes a tracker; omitting/nulling `event` only returns its current decision.
`maximumTurns` is 1–64 (default 64) and must stay identical within a state chain.
Inputs and outputs are capped at 1 MB. Unknown fields and malformed observations
fail closed. Values supplied through CLI variables stay literal data.

`identity-sweep` accepts event fields `identity`/`token` (nullable opaque strings,
1–256 UTF-8 bytes), and boolean `advanced`, `accepted`, `idle`, `published`,
`boundary` (default false). It returns `excludedIds` in first-observed order.
Each identity gets one turn in a distinct sweep. A new token with accepted,
advanced progress makes it eligible for a later sweep; a successful idle probe
starts that sweep only after distinct identities have been exhausted. Repeated
identities in the same sweep and observations without usable progress stop the
tracker. A boundary always stops it. Every observed turn, including an idle or
publish-only result, consumes the shared bound.

An accepted, verified publication can report up to four `proofs`, each exactly
`{"identity":"...","token":"..."}`, with distinct identities. These proofs can
advance a different identity from the current producer. Only unseen tokens count.
A publish-only replay of already-seen proofs stops the sweep. Publication without
identity/proofs can continue within the turn bound (for example another ready
batch). `published` must represent verified completion, never an attempted write.
Token comparison and identity membership use exact UTF-8 bytes. Bounded sets
retain first-seen identity ordering; state token ordering is deterministic.

`decreasing-counters` can initialize from `baseline`, an object of up to 16
counter names and integer values 0–100000. Names use ASCII letters, digits,
underscore, dot or dash, up to 128 bytes. Events accept `counts`, `pending`,
`accepted` and `verified`. The tracker continues only when accepted work remains
and at least one comparable pending count decreases. It retains the minimum seen
for every counter, so oscillation cannot manufacture progress. With no comparable
baseline, a first verified result can admit one additional observation. Repeated
verification alone never admits more turns. Counter names remain bounded to 16
across the entire chain, not just one event. This mode never uses report counts as
proof unless the caller explicitly classifies them as verified completion.

Callers own domain validation: account/window binding, permitted identity syntax,
verification receipts and the meaning of pending counts. Tracker observations
must be closed metadata, not raw provider objects or article text. `canContinue`
is a scheduling decision; it does not prove acquisition/publication completion
and never clears pending work. A cycle may stop sooner for deadlines or another
worker's shared turn budget.
