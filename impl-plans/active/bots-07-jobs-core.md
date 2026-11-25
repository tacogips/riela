# bots-07-jobs-core: job schedule and ledger, suggestions store, look-around policy check

```json
{
  "planId": "bots-07-jobs-core",
  "planPath": "impl-plans/active/bots-07-jobs-core.md",
  "dependsOn": ["bots-01-contracts"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCore/BotJobs",
    "Tests/RielaCoreTests/BotJobs",
    "impl-plans/progress/bots-07-jobs-core.md"
  ],
  "sharedPaths": []
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §10.1 (schedule, due check, ledger), §10.2 (enforcement check and
output contract), §10.3 (suggestion states). This plan is the deterministic
core; plan 16 runs the jobs and exposes them.

Tables `bot_job_runs` and `bot_suggestions` exist from plan 01.
`BotJobSchedule` and `BotRecord.memoryUpkeep` / `.lookAround` exist.

## Non-goals

- No workflow execution, no agent turn, no serve loop (plan 16).
- No CLI, GraphQL or web.
- No memory parsing (plan 06).

## Changes (new files in `Sources/RielaCore/BotJobs/`)

### `BotJobSchedule+Due.swift` (pure)

- `public enum BotJobKind: String, Codable, CaseIterable, Sendable { case upkeep, lookAround = "look-around" }`
- `public struct BotJobDueInput: Sendable`: `schedule: BotJobSchedule`,
  `now: Date`, `calendar: Calendar` (carries the time zone),
  `paused: Bool`, `busy: Bool` (the bot has an In-progress or Needs-you
  item), `lastActivityAt: Date?`, `lastSuccessAt: Date?`,
  `ledgerPeriodKeys: Set<String>`.
- `public enum BotJobDecision: Equatable, Sendable { case notDue(reason: String); case skip(periodKey: String, reason: String); case run(periodKey: String, skippedPeriodKeys: [String]) }`
- `public enum BotJobDue { static func periodKey(for date: Date, schedule: BotJobSchedule, calendar: Calendar) -> String?; static func decide(_ input: BotJobDueInput) -> BotJobDecision }`

Rules:
- Period key: nightly → `yyyy-MM-dd` of the local date; weekly →
  `YYYY-'W'ww` ISO week (use `calendar` with ISO-8601 week settings and the
  given time zone); `off` → nil.
- The candidate period is the newest **closed** period: yesterday for
  nightly, last ISO week for weekly.
- `off` → `.notDue("off")`. Paused → `.notDue("paused")`. Busy →
  `.notDue("busy")` (no ledger row; it is retried on the next tick).
- Candidate already in `ledgerPeriodKeys` → `.notDue("done")`.
- No activity newer than `lastSuccessAt` (or no activity at all) →
  `.skip(candidate, "no_activity")`.
- Otherwise `.run(candidate, skippedPeriodKeys:)` where the skipped keys are
  the older closed periods after `lastSuccessAt`'s period that have no ledger
  row, at most 30, oldest first (catch-up as one run).

### `BotJobLedger.swift`

`extension BotStore`:
- `claimJobRun(botId:job:periodKey:sessionId:at:) throws -> Bool`: `INSERT`
  with status `running`; returns false when the primary key already exists
  (another process claimed it). Never `INSERT OR REPLACE`.
- `finishJobRun(botId:job:periodKey:status:detail:at:)` with status
  `succeeded` | `failed` | `skipped`.
- `recordSkippedJobRuns(botId:job:periodKeys:reason:at:)` (`INSERT OR IGNORE`).
- `jobRuns(botId:job:limit:) throws -> [BotJobRun]` (newest first),
  `lastSuccessfulJobRun(botId:job:)`.
- `BotJobRun { botId, job, periodKey, status, sessionId, detail, startedAt, finishedAt }`.

### `BotSuggestion.swift`

- `public struct BotSuggestionAction: Codable, Equatable, Sendable { workflowName: String; input: JSONObject }`
- `public struct BotSuggestion: Codable, Equatable, Sendable`: `suggestionId`,
  `botId`, `title`, `detail: String?`, `action: BotSuggestionAction?`,
  `status` (`open`|`accepted`|`started`|`dismissed`), `createdAt`,
  `sourceSessionId: String?`, `acceptedAt`, `acceptedBy`, `dismissedAt`,
  `dismissedBy`, `dismissReason`, `startedSessionId` (optionals).
- `static func parseOutput(_ payload: JSONObject) throws -> [BotSuggestionDraft]`:
  reads `suggestions[{title, detail?, action?{workflowName, input?}}]`.
  Missing `suggestions` array or a non-string title → `look_around_output_invalid`.
  Titles are trimmed and cut to 200 characters; at most 20 suggestions are
  kept; an action without `workflowName` is dropped (the suggestion stays).
- `extension BotStore`:
  - `insertSuggestions(botId:drafts:sourceSessionId:at:) throws -> [BotSuggestion]`
    (ids `sug-` + UUID).
  - `suggestions(botId:status:) throws -> [BotSuggestion]` (newest first).
  - `acceptSuggestion(suggestionId:by:at:)`, `dismissSuggestion(suggestionId:by:reason:at:)`:
    conditional on status `open`; otherwise `suggestion_already_decided`;
    unknown id → `suggestion_not_found`.
  - `markSuggestionStarted(suggestionId:sessionId:)`: only from `accepted`.

### `LookAroundPolicy.swift` (pure)

`public enum LookAroundPolicy { static func violations(workflow: WorkflowDefinition, nodePayloads: [String: AgentNodePayload]) -> [String] }`

A workflow is acceptable for look-around only when every node is an agent
node. Report one violation string per offending node for: a node with an
`addon`; a payload with `command`; a payload with `container`; a node that
calls another workflow; more than one step. Read
`Sources/RielaCore/WorkflowModel.swift` and `AgentNodePayload.swift` for the
exact fields. An empty result means acceptable. Plan 16 turns a non-empty
result into `look_around_not_read_only` and also forces the sandbox.

## Imitate

- `Sources/RielaCore/CronSchedule.swift` for calendar handling with an
  explicit time zone.
- `Sources/RielaCore/RoutineStore.swift` for conditional JSON updates.

## Pitfalls

- No `Date()` and no `Calendar.current` in `BotJobDue`; everything comes from
  the input.
- `claimJobRun` is the cross-process once-per-period guard; do not read
  before insert.
- Accept and dismiss must be one conditional `UPDATE` checked by changed-row
  count, not read-then-write.
- Week keys near a year boundary must use the ISO week-year.

## Tests (`Tests/RielaCoreTests/BotJobs/`)

`BotJobDueTests` (fixed time zone `Asia/Tokyo`):
- schedule off → `.notDue("off")`; paused → `.notDue("paused")`; busy →
  `.notDue("busy")`.
- nightly, activity yesterday, empty ledger → `.run` with yesterday's key.
- nightly, no new activity since last success → `.skip(_, "no_activity")`.
- nightly, three missed days with activity → `.run` newest key and two
  skipped keys, oldest first.
- candidate key in ledger → `.notDue("done")`.
- weekly on 2027-01-04 → key `2027-W01`'s predecessor `2026-W53`.

`BotJobLedgerTests`:
- two `claimJobRun` calls for the same key → true then false.
- finish → status and detail stored; `lastSuccessfulJobRun` returns it.

`BotSuggestionStoreTests`:
- parse valid output → drafts; output without `suggestions` →
  `look_around_output_invalid`; 25 suggestions → 20 kept.
- accept → `accepted`; second accept or dismiss → `suggestion_already_decided`.
- dismiss with reason → recorded.
- `markSuggestionStarted` on `open` → error; on `accepted` → `started`.

`LookAroundPolicyTests`:
- single agent node → no violations.
- workflow with a command payload → one violation naming the node.
- workflow with an add-on node, a container payload, two steps → violations
  for each.

## Verification

```
mkdir -p tmp/bots-overview/bots-07-jobs-core
arch -arm64 /bin/zsh -lc 'swift test --filter "BotJobDueTests|BotJobLedgerTests|BotSuggestionStoreTests|LookAroundPolicyTests"' > tmp/bots-overview/bots-07-jobs-core/test.log 2>&1
```

Exit 0; four suites, 0 failures.

## Done criteria

- `grep -rn "Calendar.current\|Date()" Sources/RielaCore/BotJobs/BotJobSchedule+Due.swift` prints nothing.
- Verification exits 0; progress log written.
