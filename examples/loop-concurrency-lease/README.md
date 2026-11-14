# loop-concurrency-lease

Demonstrates the **advisory loop concurrency guard** (`loop.concurrency`):
while one run of a workflow holds its lease, every other execution entry for
the same workflow (`workflow run`, `loop start`, event-serve dispatch,
resume/rerun) is stopped at preflight — before any session is created.

```json
"concurrency": {
  "maxActive": 1,
  "onBusy": "fail"
}
```

- `onBusy: "fail"` — the second run prints a `loop_concurrency_busy` record
  and exits **1**.
- `onBusy: "skip"` — same record shape with type `loop_concurrency_skipped`
  and exit **0** (useful for cron/event triggers that should quietly yield).
- The lease is bound to the session at the first snapshot save, heartbeats
  with every snapshot upsert, and is released at terminal persistence. A
  lease whose heartbeat is older than **600s** is taken over with a
  `took over stale lease` diagnostic on the new run.

The workflow's first step is a `nodeType: "sleep"` node (6s) so the lease is
observably held; the second step is an ordinary mocked worker.

## Reproduce locally

```bash
./examples/loop-concurrency-lease/run-demo.sh riela
```

or manually:

```bash
STORE=/tmp/riela-loop-lease
WF=loop-concurrency-lease

# Terminal A — holds the lease for ~6 seconds.
riela workflow run $WF --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario.json \
  --session-store $STORE --output json

# Terminal B — while A is running:
riela workflow run $WF --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario.json \
  --session-store $STORE --output json
# -> {"type":"loop_concurrency_busy","holderSessionId":"...-session-1",...}, exit 1

riela loop list --workflow $WF --session-store $STORE --output json
# -> session-1 is `running`; no session was created for the refused run
```

Limitations are inherent to an advisory lease: two different session stores
see different lease tables, and a paused-but-alive process can lose its lease
to the staleness takeover.

See `EXPECTED_RESULTS.md` for the stable assertions verified with the bundled
mock scenario.
