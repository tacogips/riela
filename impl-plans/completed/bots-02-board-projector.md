# bots-02-board-projector: pure board, overview and list-state projection

```json
{
  "planId": "bots-02-board-projector",
  "planPath": "impl-plans/active/bots-02-board-projector.md",
  "dependsOn": ["bots-01-contracts"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCore/BotBoard",
    "Tests/RielaCoreTests/BotBoard",
    "impl-plans/progress/bots-02-board-projector.md"
  ],
  "sharedPaths": []
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §5.3, §5.4, §8.1–§8.5. One pure function turns runtime records into
the board, the overview row and the ordered list. CLI, GraphQL and web all
render its output, which is how they stay identical. It also owns the
`bot_list_state` table queries.

Inputs come from existing types: `WorkflowSession`
(`Sources/RielaCore/RuntimeSession.swift:383`), `WorkflowSessionStatus`,
`SuspendRecord`/`SuspendReasonKind` (`Sources/RielaCore/HandoverContracts.swift`),
`ActivityState` and `BotRecord` (plan 01). RielaCore cannot import RielaWork,
so Work tasks arrive as a neutral value type defined here.

## Non-goals

- No loading of sessions, tasks or routines (plan 10 does the I/O).
- No clock, no file or database access inside the projector.
- No GraphQL or CLI types.

## Changes (all new, in `Sources/RielaCore/BotBoard/`)

### `BotBoardModels.swift`

- `public enum BotBoardGroup: String, Codable, CaseIterable, Sendable { case needsYou, inProgress, waiting, planned, closed }`
- `public struct BotBoardSessionInput: Sendable`: `session: WorkflowSession`
  (root), `descendants: [WorkflowSession]`, `activity: ActivityState?`,
  `pendingRequests: [BotBoardPendingRequest]` (`requestId`, `title`,
  `options: [AdapterPermissionOption]`, `createdAt`, `expiresAt`),
  `finalMessageLine: String?`, `requestedModel: String?`.
- `public struct BotBoardTaskInput: Sendable`: `taskId`, `title`,
  `state: String` (TaskState raw value), `updatedAt: Date`,
  `waitReason: String?`, `question: BotBoardQuestion?` (`questionId`, `text`,
  `optionIds: [String]`), `attemptSessionIds: [String]`.
- `public struct BotBoardRoutineInput: Sendable`: `routineId`, `name`,
  `workflowName`, `nextFireAt: Date?`, `active: Bool`.
- `public struct BotBoardSuggestionInput: Sendable`: `suggestionId`, `title`,
  `status: String`, `acceptedAt: Date?`, `startedSessionId: String?`.
- `public struct BotListState: Codable, Equatable, Sendable`: `pinned: Bool`,
  `manualOrder: Int?`, `snoozedUntil: Date?`, `snoozedAt: Date?`,
  `settledAt: Date?`, `settledBy: String?` (`user` | `auto`). (No stored
  `bumpedAt`; it is computed.)
- `public struct BotBoardInput: Sendable`: `bot: BotRecord`, `sessions`,
  `tasks`, `routines`, `suggestions`,
  `listStates: [BotListStateKey: BotListState]`, `now: Date`, `origin: BotOrigin`.
  `BotListStateKey { itemKind: String ("bot"|"session"|"task"), itemId: String }`.
- `public struct BotBoardItem: Codable, Equatable, Sendable` with the fields
  of design §5.3: `itemKind`, `itemId`, `group`, `title`, `workflowId`,
  `stepId`, `nodeId`, `backend`, `model`, `startedAt`, `elapsedMs`,
  `lastActivityAt`, `status`, `waitingReason`, `limitedResetAt`,
  `activitySource`, `doingNow`, `checklist: [ActivityPlan]`,
  `pendingRequests`, `answerPath` (`"bot"` | `"task"`), `question`,
  `lastResult`, `sessionId`, `bumpedAt`, `listState`, `origin`.
- `public struct BotBoard: Codable, Equatable, Sendable`: `botId`,
  `groups: [BotBoardGroup: [BotBoardItem]]` (encode as five named arrays),
  `closedTotal: Int`.
- `public struct BotOverviewRow: Codable, Equatable, Sendable`: `bot`,
  `counts { needsYou, working, waiting, planned }`, `inProgress: [BotBoardItem]`,
  `lastActivityAt`, `lastResult`, `listState`, `section`
  (`active` | `working` | `snoozed` | `settled`), `workspaceGroup`, `origin`.
- `public struct BotOverviewList`: `rows: [BotOverviewRow]` in final order,
  `groups: [BotWorkspaceGroup]` (`key`, `needsYou: Bool`, `botIds`) when
  `groupBy == .workspace`.

### `BotBoardProjector.swift`

- `public enum BotBoardProjector`
  - `static func board(_ input: BotBoardInput) -> BotBoard`
  - `static func overviewRow(_ input: BotBoardInput) -> BotOverviewRow`
  - `static func overviewList(_ inputs: [BotBoardInput], groupBy: BotListGrouping) -> BotOverviewList`
  - `static func lastResultLine(session:finalMessageLine:redact:) -> String`
    (`redact: (String) -> String`, at most 200 characters, one line).
  - `static func canSettle(_ item: BotBoardItem) -> Bool`,
    `static func canSettleBot(_ board: BotBoard) -> Bool`.

Group rules, first match wins, exactly as the table in design §5.3. Details a
careless version gets wrong:

- A session whose id is in any task's `attemptSessionIds` is not an item; its
  activity, pending requests and running state are folded into the task item.
- "pending permission request in the session family" includes descendants.
- `suspended` with `userInputRequired` or `userPresenceRequired` → Needs you;
  `suspended` with any other reason → Waiting with that reason kind.
- Work task `needsDecision`, or a task with a `question` → Needs you with
  `answerPath = "task"`. Permission requests set `answerPath = "bot"`.
- An item whose `activity.lastStop.limited` is true and whose session is
  terminal or suspended → group Waiting, `status = "limited"`,
  `waitingReason = "limited"`, `limitedResetAt` set. A limited item is never
  Closed.
- Planned: session `created`; task `draft`/`ready`/`scheduled`; one item per
  active routine with a non-nil `nextFireAt` (`itemKind = "routine"`);
  suggestions with status `accepted` and no `startedSessionId`
  (`itemKind = "suggestion"`).
- Closed: newest first by terminal time, at most 20; `closedTotal` is the
  full count before the cut.
- `model` = `activity.reportedModel ?? requestedModel ?? nil`.
- `doingNow` = title of the newest tool call whose status is `pending` or
  `inProgress`, else `currentStepId`.
- `elapsedMs` = `now - startedAt` for non-terminal items, terminal time minus
  start for Closed.
- `bumpedAt`: session terminal time for finished or failed items; the newest
  pending request `createdAt` or suspend time for Needs-you items; else nil.

List rules (design §8.2, §8.3):

- Order key: pinned first; then `manualOrder` ascending (nil last); then
  `bumpedAt ?? lastActivityAt` descending (nil last); then id ascending.
- Section of a bot row, evaluated in this order: `settled` if `settledAt` is
  set and no work or Needs-you item is newer than it; `snoozed` if
  `now < snoozedUntil` and no Needs-you item or failure is newer than
  `snoozedAt`; `working` if it has non-closed items and all of them are In
  progress or Waiting; else `active`.
- Auto-settle: a Closed item with no activity for 7 days is reported with
  `settledBy = "auto"` and `settledAt = lastActivityAt + 7 days`. Never for
  items in Needs you, In progress or Waiting.
- `counts.working` counts In-progress items; `lastResult` on the row is set
  only when `counts.working == 0`.
- Workspace grouping: key = `bot.workspace ?? "ungrouped"`; `needsYou` is
  true when any bot in the group has `counts.needsYou > 0`.

### `BotListStateStore.swift`

`extension BotStore`:
- `listState(botId:) throws -> [BotListStateKey: BotListState]`
- `setListState(botId:key:_ mutate: (inout BotListState) -> Void) throws -> BotListState`
  (upsert; a state equal to the default value deletes the row).

Use `BotStore.read` / `BotStore.write` from plan 01 and the `bot_list_state`
columns defined there.

## Imitate

- `Sources/RielaCore/LoopSessionOverview.swift` for a pure projection over
  sessions.
- `Sources/RielaCore/RoutineStore.swift:save` for the JSON upsert.

## Pitfalls

- No `Date()` anywhere in this directory; `now` comes from the input.
- Do not write `bumpedAt` to the store; reads must not write.
- Do not import `RielaWork`.
- Sorting must be total and stable (always end with id) so every client gets
  the same order.

## Tests (`Tests/RielaCoreTests/BotBoard/`)

`BotBoardProjectorTests`:
- running session → In progress with step, backend, model, `doingNow`.
- running session with a pending request on a child session → Needs you,
  `answerPath = "bot"`, options present.
- suspended `userInputRequired` → Needs you; suspended `operatorMove` →
  Waiting with reason `operatorMove`.
- task `needsDecision` → Needs you with `answerPath = "task"`.
- task with attempt session that is also linked → one item (the task).
- failed session with `lastStop.limited` → Waiting, status `limited`, reset time.
- active routine with next fire → one Planned item; disabled routine → none.
- accepted suggestion without session → Planned; with session → not listed.
- 25 completed sessions → 20 Closed items, `closedTotal == 25`, newest first.
- failed session → `lastResult` is the failure reason, single line, ≤ 200
  characters, passed through `redact`.
- bot with no work → zero counts, nil `lastActivityAt`.

`BotListProjectionTests`:
- pinned beats manual order beats bumped time; ties by id.
- snoozed until tomorrow → section `snoozed`; a newer Needs-you item → `active`.
- settled bot with new work after `settledAt` → `active`.
- bot with only In-progress and Waiting items → `working`.
- closed item idle for 8 days → auto-settled; In-progress item idle for 8
  days → not settled.
- `canSettle` false for In progress, Waiting, Needs you.
- workspace grouping sets `needsYou` on the right group.

`BotListStateStoreTests`:
- set pin then read → pinned; reset to default → row deleted.

## Verification

```
mkdir -p tmp/bots-overview/bots-02-board-projector
arch -arm64 /bin/zsh -lc 'swift test --filter "BotBoardProjectorTests|BotListProjectionTests|BotListStateStoreTests"' > tmp/bots-overview/bots-02-board-projector/test.log 2>&1
```

Exit 0; the log shows the three suites with 0 failures.

## Done criteria

- `grep -rn "Date()" Sources/RielaCore/BotBoard` prints nothing.
- `grep -rn "import RielaWork" Sources/RielaCore/BotBoard` prints nothing.
- Verification exits 0; progress log written.
