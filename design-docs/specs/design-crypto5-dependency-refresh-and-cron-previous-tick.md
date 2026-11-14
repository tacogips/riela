# swift-crypto 5.x Dependency Refresh and Cron Previous Tick

Status: accepted for implementation (2026-10-27). No GitHub issue; the owner
instructions in the opus-luna session-515 intake are authoritative. Base:
`main` at `0b25d5b2`. The change must not revert or rework the definition store
(#179/#180) or the agent tool-policy presets (`0b25d5b2`).
Do not bump `VERSION` and do not release.

Continuation (opus-luna session 519, base `main` at `c14c3b30`): Part 1
§1.1-1.3 landed as `35a910d5` (plan `crypto5-prevtick-01-deps`, completed;
not redone). That commit also carried the `docs/builtin-gateway-json.md`
Notion row from §1.4. What remains is the §1.4 test and README text, all of
Part 2, and the rollout rules in "Continuation rollout" below.

Implemented (2026-10-27, session 519): plans `crypto5-prevtick-02` … `06`
were accepted by the test-integrity, adversarial and combined-tree integration
reviews. The umbrella plan and all child plans are archived as
[`impl-plans/completed/crypto5-prevtick*.md`](../../impl-plans/completed/crypto5-prevtick.md).
User docs: README [Cron tick input](../../README.md#cron-tick-input) and the
Notion add-on paragraph.

The change has two independent parts. Part 1 updates dependency pins. Part 2
adds the previous scheduled occurrence to the cron tick envelope. Neither part
adds a new module, abstraction layer, or configuration key.

## Part 1: Dependency refresh

### 1.1 Target pins

| Package | Manifest | Current | Target | Pin style |
| --- | --- | --- | --- | --- |
| apple/swift-crypto | `Package.swift:74` | `from: "4.5.2"` | `from: "5.0.3"` | from |
| apple/swift-crypto | `Packages/RielaMemory/Package.swift:14` | `from: "4.5.2"` | `from: "5.0.3"` | from |
| swift-server/swift-webauthn | `Package.swift:75` | `exact: "1.0.0-beta.1"` | `revision: "030acd1eedaa835958ae3fcc0e491bec03b2abf1"` | exact → revision (owner-directed) |
| tacogips/agent-gateway | `Package.swift:~71` | old revision | `8282152f29679625fee58729543094961adca633` (v0.1.6) | revision |
| tacogips/apple-gateway | `Package.swift:~100` | old revision | `a57de9d6ea2658dce731067e837b0987ceb1e962` (v0.1.19) | revision |
| tacogips/notion-gateway | `Package.swift:31` | `15e7cbf7…` | `0f16afb306f28506ec50c78483e101694315facc` (v0.1.6) | revision |
| tacogips/gmail-gateway | `Package.swift:~92` | old revision | `ca29da81d8cdb7da40cb6ef6739cd824376bfcdd` (v0.1.29) | revision |
| tacogips/google-service-gateway | `Package.swift:~84` | old revision | `ed020e4a8f45a0acedaf46334e2a67677e3c3e63` (v0.1.7) | revision |
| tacogips/kaiba | `Package.swift:~80` | old revision | `41cbf6bf06e6ab18e7b8e72007e96230e0ea8ad5` (v0.1.19) | revision |
| tacogips/x-gateway | `Package.swift:66` | `exact: "0.1.26"` | `exact: "0.1.27"` | exact |

These stay unchanged: gateway-sdk-kit 0.1.1, google-gateway-auth `48e0112`,
wrike-gateway, google-analytics-gateway, google-documents-gateway,
anydoc-swift, and web-hooky. Their checkouts under `.build/checkouts` declare no
swift-crypto dependency, so they cannot block the resolve.

### 1.2 Resolution rule

Several dependencies at the current pins exclude 5.x. In the local checkouts,
swift-webauthn declares `3.8.1..<5.0.0`, x-gateway `3.0.0..<5.0.0`, and
gmail-gateway, notion-gateway, kaiba and google-service-gateway
`from: 4.5.x`. The target pins are expected to allow 5.x. For swift-webauthn,
the owner states `3.8.1..<6.0.0`.

- `swift package resolve` must succeed for the root package. Afterwards,
  `Package.resolved` must contain exactly one `swift-crypto` entry, with a
  `5.x` version. `Packages/RielaMemory/Package.resolved` must also resolve
  swift-crypto to 5.x.
- If any target pin still excludes 5.x, the run stops and reports that pin as
  a blocker. It must not work around the cap with forks, `.package(path:)`
  overrides, unsafe flags, or an older crypto version.

### 1.3 Adapting to API changes

- Riela call sites are changed only as far as compilation needs, and behavior
  must not change. This covers RielaServer passkey code, the gateway add-on
  engines, the kaiba bridge add-ons, and the in-process gateway hosts.
  Implementation evidence must list each adaptation as
  `file:line → upstream change`.
- **WebAuthn:** the passkey code is
  `Sources/RielaServer/RielaPasskeyService+Ceremonies.swift`, which uses
  `manager.beginRegistration(user:)`, `beginAuthentication(userVerification:)`
  and `finishAuthentication(...)`. Upstream made `AuthenticatorSelection`
  optional. If that changes the default registration options JSON, the call
  site must pass the previous effective value explicitly so the wire output
  stays byte-equivalent. The passkey suites (`RielaPasskeyTests`,
  `PasskeyCommandTests`) are the guard.
- **Gateway and kaiba diffs:** the upstream changes since the old pins are
  read when the dependencies are bumped. The design sandbox could not fetch
  them, so this is listed in the verification gaps. A dependency that removes
  a capability Riela exposes is a blocker to report. It is not a reason to
  remove the Riela add-on surface.

### 1.4 Notion `findChildPage` and `ensurePagePath`

`riela/notion-gateway-read` and `riela/notion-gateway-write` take their
operation list from the catalog: `NotionGatewaySDK(role:).catalog` in
`Sources/RielaCLI/ProductionNodeAdapter+NotionGatewayAddons.swift:16-19`. The
JSON-mode request checks in `Sources/RielaCLI/BuiltinGatewayRequestChecks.swift`
validate against that catalog, and no Riela source file hard-codes Notion
operation names. So the new operations arrive with the v0.1.6 pin, and the
design adds **no explicit catalog entries**.

- Writer JSON mode accepts `{"operation": "ensurePagePath", "arguments": {...}}`.
- Both reader and writer accept `findChildPage`. It is a read operation, so
  the reader role exposes it through its catalog.
- If v0.1.6's reader catalog does not expose `findChildPage`, the test fails.
  That is reported as an upstream contradiction, not patched locally.
- **Test**, in `Tests/RielaCLITests/NotionGatewayAddonTests.swift` (no network,
  no credentials):
  - writer catalog contains `ensurePagePath` and `findChildPage`;
  - reader catalog contains `findChildPage`;
  - a JSON-mode writer request with `operation: "ensurePagePath"` passes
    catalog validation and then stops at the credential or network boundary,
    following the pattern of
    `testLinkedWriterValidatesPagePositionBeforeCredentialsOrNetwork`.
- **Docs:** README.md §"Notion pages and images" and the Notion row/notes in
  `docs/builtin-gateway-json.md` name both operations and their roles.

## Part 2: Cron previous tick

### 2.1 Envelope fields

`dispatchCronTick` (`Sources/RielaCLI/EventLiveServe+Cron.swift`) builds the
`cron.tick` envelope input. Two keys are added to it:

| Key | Format | Meaning |
| --- | --- | --- |
| `scheduledAt` (existing) | ISO-8601 UTC, fractional seconds | this occurrence |
| `scheduledLocalTime` (existing) | `yyyy-MM-dd HH:mm:ss` in source timezone | this occurrence |
| `previousScheduledAt` (new) | same formatter as `scheduledAt` | latest occurrence of the same schedule strictly before `scheduledAt` |
| `previousScheduledLocalTime` (new) | same formatter as `scheduledLocalTime` | the same instant as `previousScheduledAt`, as local time in the source timezone |
| `firedAt`, `timezone` (existing) | unchanged | unchanged |

Rules:

- The value depends only on `(source.schedule, source.resolvedTimeZone,
  scheduledAt)`. It never reads run history, receipts, the overlap
  dispatcher, or `cronLastCheckedAt`. A tick that was skipped, coalesced,
  missed while serve was down, or gated by a routine still counts as the
  previous occurrence.
- When overlap coalescing dispatches only the latest pending tick, only that
  dispatched tick receives its schedule-derived previous value.
- `[previousScheduledAt, scheduledAt)` is the run window for the tick: the
  start is inclusive and the end is exclusive.
- The same `ISO8601DateFormatter` and `DateFormatter` used for the existing
  fields are reused, so the old and new values use identical formats.
- In a fall-back overlap, two different instants can produce the same
  `previousScheduledLocalTime` string. For example, `0 30 1 * * *` in
  America/New_York on 2026-11-01 renders both 01:30 EDT and 01:30 EST as
  `2026-11-01 01:30:00`. The local string is for display only. Windows must
  use the UTC `previousScheduledAt`/`scheduledAt` pair, which is always
  unambiguous.
- If no occurrence exists within the search horizon (§2.2), both keys are
  omitted rather than given a sentinel. The serve loop never produces this
  case, because `scheduledAt` itself matched the schedule.

### 2.2 Previous-occurrence algorithm (RielaCore)

Add `CronSchedule.previousOccurrence(before: Date, calendar: Calendar) -> Date?`
in `Sources/RielaCore/CronSchedule.swift`. A thin
`CronScheduleSource.previousTick(before:)` uses the source's resolved
timezone, like `dueTicks` does.

**Contract:** the result equals
`max { t : t is a whole second, t < before, matches(t, calendar) }`, which is
the value a naive backward per-second scan with the existing `matches` would
return. "Matches" therefore means exactly what `dueTicks` fires on, including
wall-clock DST behavior:

- In a spring-forward gap, a local time that does not exist has no
  occurrence.
- In a fall-back overlap, a repeated local time occurs twice.

**Search (bounded skip-scan):** start at `t = ceil(before) - 1s`, the largest
whole second strictly before `before`, and loop. For the integral `scheduledAt`
values the serve loop produces, this equals `floor(before) - 1s`.
Decompose `t` in the calendar, then check the fields from coarsest to finest:

1. month not in `months`: set `t` to the start of the month containing `t`
   minus 1s;
2. else day predicate false: set `t` to the start of the day minus 1s;
3. else hour not in `hours`: set `t` to the start of the hour minus 1s;
4. else minute not in `minutes`: set `t` to the start of the minute minus 1s;
5. else second not in `seconds`: set `t` to `t - 1s`;
6. else return `t`.

The day predicate is the same dom/dow OR rule that `matches` uses.

- Unit starts come from `calendar.dateInterval(of:for:)` or `startOfDay`, so
  each jump is measured in absolute time and is DST-aware. Every skipped
  instant shares the mismatching field value, which keeps the contract exact.
  A repeated fall-back hour is visited twice, which is correct.
- To guarantee the two paths agree, `matches` and the scan share per-field
  predicate helpers. The day rule is not reimplemented.
- **Horizon:** the search stops once `t` is earlier than
  `calendar.date(byAdding: .year, value: -9, to: before)`, and then returns
  `nil`. The longest Gregorian gap between occurrences of a schedule that
  matches at all is 8 years: Feb 29, as in 2096→2104. The work is bounded by
  roughly 108 month jumps plus a few hundred day, hour, minute and second
  steps.
- `maximumCatchUpSeconds` and `dueTicks` are unchanged.

### 2.3 Producers: all paths agree

| Path | Builds the envelope? | Change |
| --- | --- | --- |
| `events serve` live loop (`EventLiveServe.swift:261-281` → `dispatchCronTick`) | yes, the only runtime producer | add the two keys |
| `events serve --read-only` (`recordReadOnlyEventIfNeeded` inside `dispatchCronTick`) | reuses the same envelope | none; carries the keys by construction |
| Overlap dispatcher (`EventCronOverlapDispatcher.swift`, `CronOverlapFire.envelope`) | carries the envelope unchanged into receipts and runs | none; agrees by construction |
| `events replay` | re-uses the stored receipt envelope as-is | none. Receipts written before this change lack the keys and are not backfilled, because replay evidence stays verbatim |
| `events emit` / `--dry-run` with `--event-file` | consume authored fixture payloads | update the authored cron fixtures (below) |
| `RoutineService.eventBinding` default template (`Sources/RielaWorkflowRegistry/RoutineService.swift:390-397`) | binding template | add `"previousScheduledAt": "{{event.input.previousScheduledAt}}"` and `"previousScheduledLocalTime": "{{event.input.previousScheduledLocalTime}}"` |
| `ProductionNodeAdapter+TimeSignal.swift` | no; it only consumes `scheduledAt` | none |

Routine binding files that already exist on disk are rewritten only when the
routine is created or updated. That matches existing routine behavior, and
no migration is added.

Fixture payloads gain schedule-derived values, all in `Asia/Tokyo`:

- `examples/event-sources/payloads/gmail-latest-mail-hourly-cron.json`
  (`0 */30 * * * *`, scheduled `2026-06-01T00:30:00.000Z`):
  previous `2026-06-01T00:00:00.000Z` / `2026-06-01 09:00:00`.
- `examples/event-sources/payloads/x-follower-ai-business-hourly-cron.json`
  (`0 0 * * * *`, scheduled `2026-06-01T00:00:00.000Z`):
  previous `2026-05-31T23:00:00.000Z` / `2026-06-01 08:00:00`.
- `examples/wrike-project-kanban-agent/payloads/wrike-kanban-cron-tick.json`
  (`*/30 * * * * *`, scheduled `2026-08-06T00:00:00.000Z`):
  previous `2026-08-05T23:59:30.000Z` / `2026-08-06 08:59:30`.
- `examples/memory-consolidation/README.md` sample envelope
  (`0 0 3 * * *`, scheduled `2026-08-09T18:00:00.000Z`):
  previous `2026-08-08T18:00:00.000Z` / `2026-08-09 03:00:00`.

`examples/event-sources/payloads/telegram-time-signal-cron.json` is a workflow
input, not a cron envelope, so it is not changed.

### 2.4 Binding templates

`{{event.input.<key>}}` resolves any envelope input key through the existing
template engine, so no engine change is needed. A test drives a binding
template with `{{event.input.previousScheduledAt}}` and
`{{event.input.previousScheduledLocalTime}}` through
`DeterministicEventDryRunTrigger` with a serve-built envelope. It asserts that
the rendered runtime variables contain the computed values.

### 2.5 Documentation

- README.md, a new short "Cron tick input" subsection directly before
  "Overlapping cron fires". It lists the envelope keys and includes this
  example:

  > Source `{"kind":"cron","schedule":"0 55 * * * *","timezone":"Asia/Tokyo"}`.
  > The tick at `2026-10-27 14:55:00` (`scheduledAt`
  > `2026-10-27T05:55:00.000Z`) carries `previousScheduledAt`
  > `2026-10-27T04:55:00.000Z` / `previousScheduledLocalTime`
  > `2026-10-27 13:55:00`. A binding that maps
  > `"windowStart": "{{event.input.previousScheduledAt}}"` and
  > `"windowEnd": "{{event.input.scheduledAt}}"` processes exactly the items in
  > `[windowStart, windowEnd)`. This spans only the interval between the
  > dispatched tick and its immediately preceding scheduled occurrence. Skipped,
  > coalesced, or downtime intervals can be missed; it does not depend on run
  > history.
- `examples/event-sources/README.md` cron section: one sentence naming the
  two new keys, with a pointer to the README subsection.
- `design-docs/specs/event-listener-workflow-trigger/provider-source-types.md`
  §Cron: the "Normalized input" list names the concrete keys and points here.
- Skill-doc delta: `riela-event-sources` is not tracked in this repository
  (see `design-scheduled-overlap-policy.md` §12). Text to apply where it is
  maintained: "cron.tick input also carries `previousScheduledAt` /
  `previousScheduledLocalTime` (latest schedule occurrence strictly before
  `scheduledAt`; `[previousScheduledAt, scheduledAt)` is the run window)."

## Verification

All `swift` and `swiftlint` commands run via `arch -arm64 /bin/zsh -lc '…'`.
Logs go to `tmp/crypto5-prevtick/`.

1. `swift package resolve`, then confirm that `Package.resolved` has one
   swift-crypto entry with version `5.*`. Do the same in
   `Packages/RielaMemory`.
2. `swift build`.
3. Focused suites:
   - `swift test --filter 'RielaPasskeyTests|PasskeyCommandTests'`
   - `swift test --filter 'NotionGatewayAddonTests|BuiltinGatewayJSONBehaviorTests|WorkflowGatewayValidationTests'`
   - the kaiba add-on suites (`--filter Kaiba`)
   - `swift test --filter 'EventLiveServeCronTests|EventCronOverlapTests|EventCronOverlapServeTests|EventRoutineBindingTests|TimeSignalAddonTests'`
   - the RoutineService tests
4. New unit tests, in `EventLiveServeCronTests` or a RielaCore cron test:
   - `0 55 * * * *` Asia/Tokyo, before `2026-10-27T14:55:00+09:00`, gives
     `2026-10-27T13:55:00+09:00`.
   - Daily `0 0 3 * * *` Asia/Tokyo, at 2026-10-27 03:00, gives
     2026-10-26 03:00.
   - Weekly `0 0 9 * * 1`, at Mon 2026-10-26 09:00, gives
     Mon 2026-10-19 09:00.
   - America/New_York spring-forward:
     - hourly `0 0 * * * *` at `2026-03-08T07:00:00Z` (03:00 EDT) gives
       `2026-03-08T06:00:00Z` (01:00 EST);
     - daily `0 30 2 * * *` at `2026-03-09T06:30:00Z` gives
       `2026-03-07T07:30:00Z`, because 02:30 does not exist on 03-08.
   - America/New_York fall-back: `0 30 1 * * *` at `2026-11-01T06:30:00Z`
     (01:30 EST) gives `2026-11-01T05:30:00Z` (01:30 EDT).
   - Seconds field: `*/15 * * * * *` at `…10:00:00` gives `…09:59:45`, and
     `30 0 * * * *` at `10:00:30` gives `09:00:30`.
   - Sparse: `0 0 0 29 2 *` at `2028-02-29T00:00` gives `2024-02-29T00:00`.
     An impossible schedule such as `0 0 0 31 2 *` returns `nil` within the
     horizon.
   - Equivalence: for a few dense schedules over a bounded window, the
     result equals a brute-force backward `matches` scan.
   - Envelope: a fixed-clock serve tick (the read-only cron test pattern) has
     both keys with the expected values.
   - Binding template (§2.4) and routine default template contain the keys.
   - Fixture agreement: each updated cron fixture's previous values equal
     `previousTick(before:)` for its source file's schedule and timezone.
5. Full `swift test`. Pass means no NEW failures compared with the baseline
   recorded in `tmp/crypto5-prevtick/c5pt-01/baseline-failures.txt` (the
   failing assertion lines; the full baseline log was not kept) and confirmed
   by the continuation workflow input. The baseline failures are:
   - `DeterministicWorkflowRunnerFailureStateTests.testRetryFailedStepErrorNamesTimeoutForCompletedSession`
   - `HandoverContractsTests.testSessionSuspendAndClosedStatusRoundTrip`
   - `ServeWebHostTests.testBrowserExecutionUsesProfileStoreAndGatesSummaryReads`
   - `SessionObservabilityTests.testTransitionalCancelledFailureKindIsTerminal`
   - `WorkflowCommandTests.testCancellationWithoutAutoImprovePersistsTerminalFailure`
   - `WorkflowHostCapabilityTests.testIssue116BuiltinsResolveWithoutExternalExecutable`
   - `WorkflowCommandTests.testConcurrentFreshRunsReceiveDistinctSessionIds`
     (flaky)

   These are reported separately and are not fixed in this change.
6. `swiftlint --strict` on the touched Swift files.
7. Push the implementation branch (`gitPush=true`). No VERSION bump, no
   release.

## Continuation rollout

- Plan `crypto5-prevtick-01-deps` is marked completed (evidence:
  `35a910d5`, `impl-plans/progress/c5pt-01-deps.md`). No Part 1 file is edited
  again.
- The plan 05 docs and fixtures are not re-authored. They come from
  re-applying `tmp/crypto5-prevtick/held/cron-docs.patch`. On `c14c3b30` the
  patch's context lines match the current files unchanged:
  - `README.md` around lines 533-538 and 994-997;
  - `examples/event-sources/README.md` around lines 407-412;
  - the three cron fixtures and the memory-consolidation sample.

  The patch's field names and values equal §2.1, §2.3 and §2.5. It contains
  no `docs/builtin-gateway-json.md` hunk, because that row already landed. If
  the patch does not apply cleanly, the same hunks are applied by hand. They
  are never rewritten with different values.
- Order: the plan 06 fixture-agreement test (§Verification 4) reads the
  fixtures. So the held patch must be applied before that test runs, and it
  keeps the `c5pt-06 dependsOn c5pt-05` edge in
  `impl-plans/active/crypto5-prevtick-dispatch.json`. Docs and code are
  committed together in serial finalization and pushed to `origin/main` in one
  push. So no pushed revision documents keys that the code does not produce.
- The plan set's stale base reference (`0b25d5b2`) is refreshed to
  `c14c3b30` when the plans are re-dispatched. Plan contents, tasks and
  `writePaths` otherwise stay as accepted.

## Out of scope

- Next-occurrence fields.
- Run-history-based "last successful run" windows.
- Backfilling old receipts.
- Changes to `maximumCatchUpSeconds`.
- New cron syntax.
- Explicit Notion catalog entries.
- Any change to the definition store or the tool-policy presets.
