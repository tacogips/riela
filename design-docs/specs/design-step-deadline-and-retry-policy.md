# Step Deadline and Bounded Retry Policy (save jobs)

Issue: tacogips/riela#188 "Make persistence job timeouts and retry backoff configurable".
Status: design (Opus). Implementation: Terra. Scope: timeout and backoff, cancellation,
diagnostics, and mutation safety for add-on-backed save steps. This design does not
claim to fix the CPU or scheduling overhead seen on 2026-11-10. It makes that overhead
observable and bounded.

## 1. Problem

ART's hourly Notion persistence (a publish fanout whose branches run
`riela/notion-gateway-write`) can run for hours. On 2026-11-10:

- successful Notion calls took about 5 s;
- three failed creates each took about 337 s and reported `mutationOutcome=unknown`;
- a pure `riela/json-route` dispatch step took up to 1049 s while the CLI used about one CPU core.

Riela has no way to say "this save step must finish, including waiting, within N",
and no bounded, mutation-safe retry.

## 2. Existing mechanisms (inventory, reused)

| Mechanism | Where | Current semantics | Reuse decision |
|---|---|---|---|
| `steps[].timeoutMs` / `defaults.nodeTimeoutMs` / CLI `--timeout-ms` | `WorkflowStepRef.swift`, `DeterministicWorkflowRunner+Prompting.swift` `deadline(for:)` | Precedence: request override, then step, then request default, then workflow default. Converted to `Date(now + timeoutMs)` **at adapter dispatch** (after attachment projection and `recordStepStartedExecution`) and handed to the adapter as `AdapterExecutionContext.deadline`. The runner does not enforce it; only adapters that read `context.deadline` enforce it (for example `localGatewayRunWithDeadline`). It does **not** cover queueing, fanout slot waits, admission, or publication. | **Kept unchanged and redefined in the docs as the per-attempt timeout.** No new attempt-timeout field. |
| `AdapterExecutionError.isRetryable` / `.retryAfter` | `Sources/RielaCore/AdapterContracts.swift`, carried by `BuiltinAddonContainerProtocol.swift` | Set by git, Home Assistant and fanout-snapshot paths. **No runtime consumer retries on them.** | Becomes the single retry-eligibility signal for the new step retry loop. |
| `RetryPolicy` + `executeWithRetry` | `Sources/RielaAdapters/AdapterUtilities.swift` | Library helper: maxAttempts, retryDelay, multiplier, maxDelay, Retry-After capped at maxDelay, optional random jitter. It has **no production callers**. | The new core policy reuses its field semantics and delay formula. RielaCore cannot import RielaAdapters, so the pure delay math is re-expressed in RielaCore; RielaAdapters is not refactored. |
| `config.writeRetry {initialWaitSeconds, maxRetries}` | `GatewayWriteRetryConfiguration.swift` (gmail only, via env to gmail-gateway) | Retries inside the gateway. | It is never combined with step retry (see the nested-retry rule in §6). |
| Gateway retry diagnostics (`requestAttempts`, `retryAttempts`, `backoffMs`, `retryStopReason`) | `GatewayFailureDiagnostics.swift` | Finite-vocabulary suffix for gateway-internal retries (gmail, X). | The stop-reason vocabulary (`non-retryable`, `retry-exhausted`) is reused for runtime stop reasons. |
| notion-gateway error model | NotionGatewayCore at pinned `41f64e6` (`NotionTransport.swift`, `NotionGatewaySDK.swift`) | **No internal retry.** URLSession `timeoutIntervalForRequest=60`, `timeoutIntervalForResource=120`. Each GraphQL error carries `code` (Notion API code or gateway code such as `TRANSPORT`, `CANCELLED`, `INVALID_RESPONSE`, `INVALID_ARGUMENT`, `AUTHENTICATION_REQUIRED`), `extensions.httpStatus`, and a message suffix `[notionDiagnostics mutationOutcome=<notDispatched/rejected/unknown> retryAfterSeconds=<n>]`. Writes cancelled after dispatch are reported as `mutationOutcome=unknown`. | Reused as is. **No notion-gateway change and no pin bump** (see §8). |
| Fanout `failurePolicy: "collect-partial"` | `WorkflowModel.swift` `WorkflowFanoutFailurePolicy` | The join receives a per-branch status/failureReason record instead of failing the dispatch. | This is how unresolved save items are retained for the caller. |
| Scheduled overlap policy (`skip`, `cancelRunning`, `queue`, `concurrent`) | `design-scheduled-overlap-policy.md` | Bounds a whole scheduled run against the next tick. | It remains the whole-run bound. No new run-level deadline is added. |
| Session cancellation | `design-cancellation-and-orphan-session-resilience.md` | Task cancellation leaves running executions not completed. | Backoff sleeps and attempts must be cancellation-aware so this path applies unchanged. |

## 3. New step fields

Two optional fields are added to `WorkflowStepRef`, on inline steps and step files.
**When neither is authored, runner behaviour is unchanged on every code path**:
one attempt, no runner race, and today's `deadline(for:)`.

```json
{
  "id": "save-page",
  "nodeId": "notion-write",
  "timeoutMs": 180000,
  "deadlineMs": 600000,
  "retry": {
    "maxAttempts": 4,
    "initialDelayMs": 2000,
    "multiplier": 2,
    "maxDelayMs": 60000,
    "jitter": "deterministic"
  },
  "transitions": [{ "toStepId": "next" }]
}
```

### 3.1 `deadlineMs`: step deadline (the whole save job and its total elapsed budget)

- **Anchor (`readyAt`)**: `readyAt = max(inputReadyAt, runStartedAt)`.
  - `inputReadyAt` is the `createdAt` of the latest delivered input message addressed
    to this step in this session (`WorkflowMessageRecord.createdAt`). It is absent for
    an entry step.
  - `runStartedAt` is the time the current run request began. For a **fanout branch**
    it is the time the parent dispatched the fanout directive, not the time the branch
    obtained a concurrency slot. This is a new request field, set once per dispatch and
    copied into every `branchRequest`. Taking the `max` means an operator
    resume or rerun opens a fresh window instead of failing immediately on a
    stale message timestamp.
- `stepDeadline = readyAt + deadlineMs`. Every phase is handled in exactly one of two
  ways. **Active expiry** means a runner timer fires at the deadline and resolves the
  work without waiting for the blocked operation. **Elapsed accounting** means the
  time is counted and checked at the next guard, but it cannot be pre-empted.

  | Phase | Handling | Mechanism |
  |---|---|---|
  | Fanout slot wait (branch whose entry step authors `deadlineMs`; branch not yet scheduled) | **Active expiry** at `stepDeadline` | Fanout expiry timer (§5.3). The entry is resolved as a failed branch record with `attempts=0` and is never scheduled. An occupied slot is not released. |
  | Attachment projection, every attempt, every backoff sleep | **Active expiry** at `stepDeadline + backstopGrace` | Step supervisor (§5.1) around the whole supervised region |
  | Time between input-message delivery and step dispatch, while the runner itself does synchronous scheduling, history or store work (it is not blocked on a wait) | **Elapsed accounting** | Dispatch guard (§5.2): if already expired, the step fails with `attempts=0` and nothing is dispatched. `queueWaitMs` records the time. |
  | Runtime-store writes: `recordStepStartedExecution`, and failure or success publication | **Elapsed accounting**, not pre-emptible | These are runtime-owned writes that must complete for record consistency. Their durations are emitted (§7). |

  `backstopGrace` is a fixed 5 s constant and is not configurable. It lets an adapter that
  honours `context.deadline` report its own classified timeout first.
- **Advertised bound**: a step with `deadlineMs` stops initiating work and stops
  awaiting blocked operations no later than `stepDeadline + 5 s`. The
  runtime-store write that records the outcome happens after that, and its duration is
  reported. That is the whole bound: this design does not pre-empt runtime CPU or store work.
- **Late dispatch is impossible.** An external call starts only through the dispatch
  guard (§5.2). The guard requires that the supervisor has not expired, that the task is
  not cancelled, and that `now < stepDeadline`. Preparation that resumes after expiry
  (for example a projection that ignored cancellation) therefore cannot start a write.
- **Backoff budget**: before each backoff sleep, if `now + delay >= stepDeadline`, the
  runner does not sleep and stops with `stopReason=deadline-exhausted`.
- **Successful-effect exception**: if an attempt returns success to the supervisor
  **before** the supervisor expires, the success is always published, even if the
  publication write ends after `stepDeadline`. A completed external effect is never
  discarded or re-run. Backend event `riela.step.deadline.exceededAfterSuccess` is
  emitted. A success that arrives **after** expiry is discarded and recorded as
  `effectOutcome=unknown` (§5.1).
- Without `retry`, `deadlineMs` still applies: one attempt under the same supervisor and
  guards. This is how a slow pure-routing step (`riela/json-route`) gets a whole-step
  bound that an HTTP-only timeout cannot express.

### 3.2 `timeoutMs`: per-attempt timeout (existing field, semantics unchanged)

- Each attempt's adapter deadline is
  `attemptDeadline = min(attemptStart + effectiveTimeoutMs, stepDeadline)`, where
  `effectiveTimeoutMs` keeps today's precedence. If `effectiveTimeoutMs <= 0`, then
  `attemptDeadline = stepDeadline`. It is passed as
  `AdapterExecutionContext.deadline` exactly as today.
- An HTTP request timeout inside a gateway (notion-gateway: 60 s idle / 120 s resource) is
  a third, inner bound. It is **never** presented as the save-job deadline.

### 3.3 `retry`: bounded exponential backoff

| Field | Type / range | Default | Meaning |
|---|---|---|---|
| `maxAttempts` | integer 1...10 | required | Total attempts, including the first. A value of `1` means no retry. |
| `initialDelayMs` | integer 0...3_600_000 | 1000 | Delay before attempt 2. |
| `multiplier` | finite number 1.0...10.0 | 2.0 | `base(n) = initialDelayMs * multiplier^(n-1)` for the delay after failed attempt `n`. |
| `maxDelayMs` | integer `initialDelayMs`...3_600_000 | 30000 | Cap applied to every computed delay. |
| `jitter` | `"none"` or `"deterministic"` | `"none"` | `deterministic`: `delay = base * (0.5 + 0.5 * u)`, where `u` comes from the first 8 bytes of `SHA-256("<sessionId>/<executionId>/<attempt>")` divided by 2^64. It is reproducible across replays and tests, and no RNG is used. |

Total elapsed budget = `deadlineMs`, which is **required whenever `retry` is
present**. There is no separate `maxElapsedMs`, because one knob cannot drift out of
sync with another.

Delay for the next attempt:

1. `d = min(base(n), maxDelayMs)`, then apply jitter.
2. If the failure carries `retryAfter` (Retry-After): `d = max(d, retryAfter)`. If
   `retryAfter > maxDelayMs`, **stop** with `stopReason=retry-after-exceeds-max-delay`
   rather than retry before the provider asked.
3. Budget check (§3.1 point 3).

## 4. Retry eligibility and mutation safety

A failed attempt is retried only if **all** of these hold:

1. the error is an `AdapterExecutionError` with `isRetryable == true`. `nil` counts as
   `false`, so add-ons that do not classify their errors never retry;
2. `effectOutcome != .unknown` (see below);
3. `attempt < maxAttempts`;
4. the delay and budget rules in §3.3 allow it;
5. the task is not cancelled.

### 4.1 `AdapterExecutionError.effectOutcome` (new optional field)

`enum AdapterEffectOutcome: String { notDispatched, rejected, unknown }`. The default is
`nil`, so existing construction sites stay source-compatible. It is the generic form of
notion-gateway's `mutationOutcome` and gmail's `MUTATION_OUTCOME_UNKNOWN`.
`unknown` is a hard stop: `stopReason=outcome-unknown`. The failure reason contains
`effectOutcome=unknown`, and the execution stays `failed` (unresolved, never
`completed`). The runtime never automatically repeats such an attempt.

### 4.2 Notion classification (`riela/notion-gateway-read|write`, RielaCLI only)

`LocalGatewayGraphQLEngine` stops flattening Notion errors into an unclassified
`.providerError`. For the notion-gateway descriptor, it reads the first structured error
from the raw envelope (`code`, `extensions.httpStatus`, and the message's
`notionDiagnostics` suffix: `mutationOutcome`, `retryAfterSeconds`). The adapter error
**message text is kept as it is today**.

**Write (mutation document) classification is decided by the first matching rule, in order.**
The gateway's explicit outcome always takes precedence over HTTP status or code.

1. **`mutationOutcome=unknown` is present**: `effectOutcome=unknown`, not retryable. This
   holds **whatever the status or code**, including 429 and 409. A composite
   `ensurePagePath` that created some pages before a later 429 or 409 lands here:
   NotionPagePath.swift rethrows with the HTTP status but `mutationOutcome=unknown`. So
   do 5xx, 408, `TRANSPORT`, `INVALID_RESPONSE` and `CANCELLED` after dispatch.
2. **Mutation document but no parseable `mutationOutcome`**: `effectOutcome=unknown`,
   not retryable. This is fail-safe and is never inferred from the status.
3. **`mutationOutcome=rejected`** (the gateway confirms nothing was applied by this call):
   - status 429 (`rate_limited`), or 409 (`conflict_error`): `rejected`, **retryable**.
     For 429, `retryAfter` comes from `retryAfterSeconds`.
   - any other 4xx (`validation_error`, `invalid_request`, `unauthorized`,
     `restricted_resource`, `object_not_found`, `missing_version`, quota or limit
     rejections): `rejected`, **not retryable** (permanent).
4. **`mutationOutcome=notDispatched`**: gateway pre-dispatch errors (`INVALID_ARGUMENT`,
   `AUTHENTICATION_REQUIRED`, `CAPABILITY_DENIED`, `RESPONSE_TOO_LARGE`, body > 500 KB)
   are `notDispatched`, **not retryable** (permanent).
5. **Riela-raised timeouts** (no gateway error): a `localGatewayRunWithDeadline` timeout
   raised **before** the call is `notDispatched`, retryable. One raised **while** calling
   is `unknown`, not retryable.

Reads (query documents) carry no `mutationOutcome`. These are retryable: 429, 409, 5xx,
408, `TRANSPORT`, `INVALID_RESPONSE`, and Riela timeouts. Other 4xx and gateway
pre-dispatch errors are not retryable.

**Riela-side multi-call operations** (`publishPage`, `uploadLocalFile`, implemented in
`ProductionNodeAdapter+LocalGatewaySupport.swift`):

- The classification of the failing sub-call is preserved on the thrown
  `AdapterExecutionError`. That covers the paths that rethrow when no page exists yet
  and the `publishPage incomplete: {pageId,...}` wrapper. An explicit `unknown` is never
  downgraded to `rejected` or `notDispatched`.
- **Taint rule**: once a non-idempotent sub-call (`createPage` or any `appendBlocks`) has
  **succeeded** in the current attempt, any later failure in that attempt is
  `effectOutcome=unknown`, not retryable. The `publishPage incomplete` partial record
  (pageId, appendRequests) stays in the message unchanged.
- **Exemption, narrowed**: only an `ensurePagePath` sub-call that **returned success** in
  this attempt does not taint a later failure, because a retry re-scans and finds the
  pages it created. An `ensurePagePath` that **failed** is classified only by rules 1–4,
  so a partial path creation is `unknown` by rule 1. Creating file-upload objects leaves
  only unattached, expiring uploads and does not taint.
- **Remains retryable**: a single-call `createPage` (no prior successful sub-call in this
  attempt) rejected with `mutationOutcome=rejected` and status 429 or 409.

Notion offers no idempotency key, and title lookups (`findChildPage`) are not unique, so
**no automatic reconciliation is performed** (see the QA file). Writes whose outcome is
unknown are reported and retained.

Other add-ons are not reclassified by this issue. A step `retry` on them retries only
the errors they already mark `isRetryable == true`.

## 5. Runner execution model

The supervised path is used **only when the step authors `deadlineMs` or `retry`**. Steps
without either field keep today's code path byte-for-byte.

### 5.1 Step supervisor (`DeterministicWorkflowRunner+Addons.swift`)

- **Order of operations on the supervised path**:
  1. dispatch guard (§5.2);
  2. `recordStepStartedExecution`, which is a runtime-store write, is not pre-empted,
     and gives the failure record an execution to attach to;
  3. the **supervised region**, run as a child `Task`: attachment projection, then for
     each attempt the dispatch guard, `executePlacedAddon`, and the backoff sleep;
  4. publication of the outcome by the supervisor.

  On this path, projection moves after `recordStepStartedExecution`. The unsupervised
  path keeps today's order.
- **One step execution record per step dispatch.** Attempts are internal to that
  record. `executionIdentity`/`operationExecutionId` stay stable across attempts. The
  runtime store, not the adapter, records every attempt as a step backend event
  (`recordStepBackendEventReceipt`).
- **The supervisor is the only publisher.** The child never publishes. It returns an
  attempt result or a final error to the supervisor. The supervisor waits for the first of:
  - the region's result;
  - a per-attempt backstop at `min(attemptDeadline, stepDeadline) + backstopGrace`. The
    region reports each attempt's start to the supervisor so the supervisor can arm this
    backstop;
  - the step-deadline expiry at `stepDeadline + backstopGrace`;
  - parent cancellation.

  When a timer fires, the supervisor sets the shared `expired` flag, cancels the child, and
  **does not await it**. A non-cooperative projection or adapter therefore cannot hang the
  step. Any late child result is discarded.
- **Recorded outcome on expiry**:
  - expiry while an attempt is in flight: `.timeout`, `timeoutSource=runner-backstop`,
    `effectOutcome=unknown`, not retryable. The runner cannot know whether a late effect
    happened;
  - expiry during projection or backoff, when no attempt is in flight:
    `timeoutKind=step-deadline`, `effectOutcome` absent. `attempts` is the number of
    attempts already finished.

  The supervisor then publishes the failure through the existing
  `publishFailureAndThrow` / `publishAdvisoryFailure`.

### 5.2 Dispatch guard

This guard is the single gate before `recordStepStartedExecution` and before every
`executePlacedAddon` call. It is a synchronous check, immediately before the call:
`!expired && !Task.isCancelled && clock.now() < stepDeadline` (and, for attempts,
`< attemptDeadline`).
- When it fails before the first attempt: no adapter call, `attempts=0`,
  `stopReason=step-deadline`.
- When it fails between attempts: `stopReason=step-deadline`.

Because every external call passes through this guard, expired or cancelled preparation
can never later start a write.

### 5.3 Fanout expiry for unscheduled branches (`DeterministicWorkflowRunner+Fanout.swift`, `runFanoutBranches`)

This applies only when the branch workflow's entry step, `directive.targetStepId`,
authors `deadlineMs`. Otherwise scheduling is unchanged.

- Each pending (unscheduled) index has `expiresAt = fanoutDispatchAt + deadlineMs`.
- The task group also runs one **expiry timer** child, of the same group element type with
  an `expiryTick` case, that sleeps until the earliest pending `expiresAt`. On a tick,
  every pending index with `expiresAt <= now` becomes a
  `FanoutBranchOutcome.failure(index, item, sessionId: nil, reason: "[rielaRetry attempts=0 stopReason=step-deadline timeoutKind=step-deadline queueWaitMs=<ms>] branch not started before deadline", cancelled: false)`.
  That index is removed from the queue and never scheduled. The timer re-arms for the
  next earliest index.
- Running branches and occupied slots are not touched. The join still waits for running
  branches, which their own step deadlines bound.
- The scheduler also checks `expiresAt` when it pops an index for a freed slot, so an
  index that expired between ticks is never started.
- With `fail-fast`, the existing cancellation of unscheduled work wins.

### 5.4 Clock, cancellation, final failure

- **Clock injection**: a new RielaCore protocol
  `WorkflowRetryClock { now() -> Date; sleep(until: Date) async throws }`.
  - The default (`SystemWorkflowRetryClock`) sleeps until the `Date`
    deadline on the wall clock (`wallClockSleep(until:)`, so host sleep
    counts toward the budget; amendment 2026-11-11, see
    `design-wall-clock-deadlines.md`). Tests inject a manual fake clock.
  - The runner uses it for `readyAt`, deadlines, both backstops, the fanout expiry timer,
    and backoff.
  - Production uses the same wall-clock time base as `WorkflowRuntimeClock`. Tests set
    the store's `FixedWorkflowRuntimeClock` and the fake retry clock to the same instants.
- **Cancellation**: workflow/session cancellation (including scheduled
  `cancelRunning`) makes the supervisor cancel the child. That covers projection, an
  in-flight attempt, or a backoff sleep, and the supervisor does not await the child.
  The fanout expiry timer is cancelled together with its task group. A
  `CancellationError` goes through the existing `isWorkflowRunCancellation` path, so
  the execution is never marked `completed`. Backend event `stopReason=cancelled`.
- **Final failure** goes through the existing `publishFailureAndThrow` /
  `publishAdvisoryFailure` with the last attempt's error, or with the synthesized
  step-deadline error. A finite diagnostics suffix is appended to the message (§7).
  `failurePolicy` semantics are unchanged. In particular, `advisory` still routes an
  empty payload and lets the branch continue, so it gives **no** retention guarantee
  (§9).

## 6. Validation (`WorkflowRawValidation`, `riela workflow validate`)

New errors, each with a clear path such as `workflow.steps[i].retry.maxDelayMs`:

- `deadlineMs` must be an integer in 1...86_400_000.
- `retry` must be an object with only the keys in §3.3. `maxAttempts` is required.
  Each value must be an integer or finite number within its range. Negative values,
  non-finite values, non-integer milliseconds, and `maxDelayMs < initialDelayMs` are
  rejected.
- `retry` requires `deadlineMs`, so the total budget is never unbounded.
- If a step authors its own `timeoutMs` and it is `> deadlineMs`, that is an error: the
  attempt timeout would exceed the job deadline. An inherited timeout
  (`defaults.nodeTimeoutMs` or the CLI `--timeout-ms` override) is not an error. It is
  clamped at runtime by `min(attemptStart + timeoutMs, stepDeadline)`. A
  non-positive effective timeout ("no timeout") means `attemptDeadline = stepDeadline`,
  so every attempt stays bounded.
- `retry` and `deadlineMs` are allowed only on **add-on-backed** steps (`nodes[].addon`,
  which includes `riela/json-route` and `riela/notion-gateway-*`). Agent and stdio steps
  are rejected. They already have `timeoutMs`/`stallTimeoutMs`, and the save-job scope
  does not need more.
- **Nested-retry rule**: `retry` on a step whose add-on `config.writeRetry` is present is
  rejected (gateway-internal retry × runtime retry). The total attempt count is therefore
  always exactly `retry.maxAttempts` gateway invocations. notion-gateway has no internal
  retry.
- `retry` or `deadlineMs` together with `placement` (distributed execution) is rejected.
  The remote failure codec does not carry `effectOutcome`, and adding it is not needed
  for this issue.
- Fanout `failurePolicy: "fail-fast"` remains allowed. Section 9 recommends `collect-partial`.

`WorkflowRegistryGraphQLProvider` patch classification: the new paths fall into the
default `sensitive` class. No change is required.

## 7. Diagnostics

Per attempt, the backend event `riela.step.attempt.finished` carries this metadata:
`attempt`, `maxAttempts`, `attemptDurationMs`, `outcome` (`succeeded` or `failed`),
`errorCode`, `retryable`, `effectOutcome?`, `timeoutKind?` (`attempt` or
`step-deadline`), `timeoutSource?` (`adapter` or `runner-backstop`),
`retryAfterMs?`, `nextDelayMs?`, `elapsedMs` (since `readyAt`), and
`budgetRemainingMs`.

On stop, the backend event `riela.step.retry.stopped` carries `attempts`, `stopReason`, and
`elapsedMs`. `stopReason` is one of `succeeded`, `non-retryable`,
`outcome-unknown`, `retry-exhausted`, `deadline-exhausted`, `step-deadline`,
`retry-after-exceeds-max-delay`, or `cancelled`. The time from `readyAt` to the first
attempt is also emitted (`queueWaitMs` on attempt 1), so pre-execution slowness such as
the 1049 s json-route case becomes visible separately from adapter latency. The two
store writes that cannot be pre-empted are measured as well:

- `recordStartedDurationMs` is emitted on the attempt-1 event;
- the outcome publication duration is emitted, after the write, as telemetry log
  `riela.step.publication.duration` (`durationMs`, `exceededDeadline`). It is a
  telemetry log rather than a backend event because the execution is already terminal.

The final failure message suffix, which is finite and contains no provider text, is:
` [rielaRetry attempts=<n> stopReason=<r> elapsedMs=<ms> timeoutKind=<k> effectOutcome=<o>]`.
It appears in `failureReason`, in fanout `collect-partial` join records, and in
`riela session status`.

## 8. notion-gateway dependency decision

No change is required. The gateway already provides everything this design needs: a
per-call `mutationOutcome` (`notDispatched`, `rejected` or `unknown`), `Retry-After`,
HTTP status, cancellation awareness through URLSession async, and no internal retry, so
nothing multiplies. The per-attempt bound is enforced by Riela cancelling the call. The
pin `41f64e602c3e242a3f1132f2a297dec47a091afa` stays. This was verified by reading the
SwiftPM checkout `.build/checkouts/notion-gateway` (VERSION 0.1.6) matching
`Package.resolved`.

## 9. Settings for ART (`workflows/art/workflow.json`; applied later by the ART integration)

The step ids below are role names. The ART integration maps them to the real ids.

- **Notion save step** (`riela/notion-gateway-write`, for example `publishPage`, inside the publish fanout branch):
  `"timeoutMs": 180000, "deadlineMs": 600000, "retry": {"maxAttempts": 4, "initialDelayMs": 2000, "multiplier": 2, "maxDelayMs": 60000, "jitter": "deterministic"}`.
  Also set **`"failurePolicy": "fail"`** explicitly (or omit the field, which defaults to
  `fail`). **Do not use `advisory`** on save steps: an advisory failure routes an empty
  payload, the branch can still complete, and fanout then records it as `completed`,
  with no failure record.
  - The 180 s attempt timeout sits above notion-gateway's 120 s per-request resource
    timeout but allows multi-chunk `publishPage`.
  - The 600 s deadline bounds slot wait, projection, attempts and backoff for that item.
  - The worst case is 4 attempts with delays of 2, 4 and 8 s, which stays well within budget.
- **Publish fanout**: use `"failurePolicy": "collect-partial"`. Each unresolved item
  (`stopReason`, `effectOutcome=unknown`, a permanent rejection, or a branch that did
  not start before its deadline) then reaches the join of **this run** as a
  `status: "failed"` record. The record carries the original `item`, a `failureReason`
  with the `[rielaRetry ...]` suffix, and a `sessionId` when the branch started. Such an
  item is never reported as published.
- **Retention boundary**: Riela retains unresolved work only as runtime evidence. That
  means the failed step execution in the runtime store and the failed join record in the
  current run. **collect-partial does not persist a backlog across runs.** Carrying failed
  join items into the next hourly run is ART's responsibility, for example through its
  KV or scripts/art.py, and is done in the ART integration.
- **Pure routing/dispatch steps** (`riela/json-route`): `"deadlineMs": 120000` with no
  `retry`. This bounds and exposes runtime overhead. **It does not fix CPU usage.**
- **Whole hourly run**: keep the event binding's scheduled overlap policy (`skip` today).
  When the save step is the branch entry step:
  - a branch that never started is resolved at `fanoutDispatch + deadlineMs`;
  - a started branch stops save work by `fanoutDispatch + deadlineMs + 5 s` (backstop
    grace), plus the runtime-store write that records the outcome.

  Steps after the save step in a branch are bounded only by their own `deadlineMs`.
- **Items with `effectOutcome=unknown`** must be reconciled by ART or an operator before
  resubmission, for example by checking the parent page in Notion. Riela never repeats them.

## 10. Tests (deterministic, fake clock plus fake runner/transport, no live Notion)

The focused suites are a new `StepRetryPolicyTests` (RielaCore) and
`NotionGatewayAddonRetryClassificationTests` (RielaCLI, using a `localGatewayGraphQLRunner`
override or a fake `NotionHTTPTransport`). They also extend `WorkflowRawValidation` tests.
Cases 6–6c belong to `NotionGatewayAddonRetryClassificationTests`, case 5 to the
validation tests, and all others to `StepRetryPolicyTests`. The cases are:

1. A stuck or slow adapter that ignores cancellation: the runner backstop yields `timeoutSource=runner-backstop`, `effectOutcome=unknown`, no retry, execution `failed`, and the step returns without awaiting the child.
2. A transient failure (429 with Retry-After 3 s), then success: two attempts, a delay of `max(backoff, 3 s)`, completed, and events recorded.
3. Total-budget exhaustion: the next delay would cross `stepDeadline`, giving `deadline-exhausted` without sleeping.
4. Cancellation during backoff: the fake clock sleep is cancelled, the execution is not completed, and `stopReason=cancelled`.
5. Invalid policies: every rule in §6 produces its diagnostic path.
6. An ambiguous write (5xx or transport after dispatch on `createPage`, or an `appendBlocks` failure after `createPage` succeeded) gives `outcome-unknown` with exactly one attempt. The `publishPage incomplete` partial text survives classification.
6a. Precedence (Notion classification suite): a gateway error with status 429 **and** `mutationOutcome=unknown` (a partial `ensurePagePath`: first page created, second create 429) gives `outcome-unknown`, one attempt, and `effectOutcome=unknown` carried into the `AdapterExecutionError`. The same holds for 409.
6b. A single-call `createPage` with `mutationOutcome=rejected` and status 429 is retryable, gives two attempts on a scripted 429 followed by success, and the result is published as completed.
6c. A mutation error envelope without a parseable `mutationOutcome` gives `outcome-unknown`.
7. A permanent quota or validation 4xx, or `AUTHENTICATION_REQUIRED`, gives `non-retryable` with one attempt.
8. Retry-After greater than `maxDelayMs` gives `retry-after-exceeds-max-delay`.
9. A slow pure-routing step (fake cancellation-aware add-on standing in for json-route) hits `deadlineMs` through **active expiry**: `timeoutKind=step-deadline` and not completed.
9a. **Elapsed accounting**: the fake clock is advanced past `readyAt + deadlineMs` before dispatch, simulating runtime work that is not a blocked wait. The dispatch guard fails the step with `attempts=0`, the adapter call count is 0, and `queueWaitMs` is reported.
12. **Suspended projection, active expiry**: a fake attachment projector blocks forever and ignores cancellation. At `stepDeadline + 5 s` (fake clock), the supervisor publishes a `step-deadline` failure without the projector ever being released.
13. **No late dispatch**: in the same setup, the projector is released after expiry. The adapter call count stays 0, and the child neither publishes nor alters the failed record.
14. **Blocked slot acquisition**: fanout with concurrency 1 and 3 items. The entry step has `deadlineMs`. Branch 0's later step blocks without a deadline. At `dispatchAt + deadlineMs` (fake clock), items 1 and 2 become failed join records (`attempts=0`, `stopReason=step-deadline`, original `item` present). They are never started (session count 1), branch 0's slot is not released, and the join completes after branch 0 is unblocked.
15. **Retention / failure-policy classification** (collect-partial): branch = failing save step (`failurePolicy` omitted, so `fail`, with an outcome-unknown error) followed by a successful downstream step. The branch record must be `status: "failed"` with the item and the `[rielaRetry ...]` suffix, and the downstream step must not run. Control case: the same branch with `failurePolicy: "advisory"` keeps today's behaviour (`completed` branch record), proving advisory semantics are unchanged.
16. **Successful-effect exception**: an attempt returns success before expiry, and the publication store write is slowed past `stepDeadline`. The outcome is published as completed and `exceededAfterSuccess` is emitted. A success that arrives after supervisor expiry is discarded with `effectOutcome=unknown`.
10. Backward compatibility: a step without `deadlineMs`/`retry` makes one adapter call with today's `deadline(for:)` value, no supervisor, today's projection order, and unchanged fanout scheduling. Existing timeout tests pass unchanged.
11. Deterministic jitter gives identical delays for an identical (session, execution, attempt).

No real sleeps are allowed. Every wait goes through the injected `WorkflowRetryClock`.

## 11. Non-goals

- Fixing runtime CPU, history or scheduling overhead. It is only bounded and made observable.
- A run-level deadline. The existing scheduled overlap policy covers that.
- Retry for agent or stdio steps, distributed placement, and reclassifying add-ons other than Notion.
- Automatic Notion reconciliation or idempotency keys.
- Changing resume or rerun semantics. An operator resume of an `outcome-unknown` step is an explicit human action. See the QA file.
- An example bundle under `examples/`. The fixture is optional, and the mock-scenario format would need failure-sequence support that is out of scope.

## References

- `design-docs/specs/design-workflow-json.md` (`WorkflowStepRef`)
- `design-docs/specs/design-scheduled-overlap-policy.md`
- `design-docs/specs/design-cancellation-and-orphan-session-resilience.md`
- `design-docs/specs/design-gateway-sdk-addons.md` (Notion tiers)
- `design-docs/user-qa/qa-step-deadline-and-retry-policy.md`
