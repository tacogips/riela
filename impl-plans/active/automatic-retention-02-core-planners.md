# ar-02-core-planners: family planner modes and log planner (RielaCore)

```json
{
  "planId": "ar-02-core-planners",
  "planPath": "impl-plans/active/automatic-retention-02-core-planners.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCore/TerminalRetentionPlan.swift",
    "Sources/RielaCore/RielaLogRetentionPlan.swift",
    "Tests/RielaCoreTests/TerminalRetentionPlanTests.swift",
    "Tests/RielaCoreTests/RielaLogRetentionPlanTests.swift",
    "impl-plans/progress/ar-02-core-planners.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §4.1 and §4.4. `TerminalRetentionPlan.make`
(`Sources/RielaCore/TerminalRetentionPlan.swift:38`) only supports an explicit
workflow set, a mandatory age and a mandatory cap, and one byte counter. Policy
retention needs four things:

- an all-workflows-except mode (`keepWorkflowIds`);
- optional age and optional cap;
- separate results and message byte counters;
- a per-pass family limit.

Logs need a pure planner that sees no filesystem. The existing family-building
logic and every protection reason must stay byte-for-byte equivalent.

Follow the shared worker protocol in `impl-plans/active/automatic-retention.md`.

## Non-goals

- No executor, SQLite or filesystem code.
- Do not change the protection reasons that already exist
  (`unresolvedLineage`, `rootOutsideScope`, `nonterminalOrConflictingStatus`,
  `unknownOrFutureTimestamp`, explicit `protection`).
- Do not touch `Sources/RielaCLI`.

## File-level changes

### `Sources/RielaCore/TerminalRetentionPlan.swift`

Pinned additions:

```swift
public enum TerminalRetentionScope: Equatable, Sendable { case workflows(Set<String>); case allExcept(Set<String>) }
public enum TerminalRetentionByteKind: Equatable, Sendable { case results, messages }
// TerminalRetentionSession: add `public var messageBytes: Int64` (init param `messageBytes: Int64 = 0`, must be >= 0)
// TerminalRetentionFamily: add `public var messageBytes: Int64`
// TerminalRetentionPlan: add `public var workLimitReached: Bool`
// TerminalRetentionPlan: add `public var eligible: [TerminalRetentionFamily]` (see "Eligible families")
public static func make(sessions: [TerminalRetentionSession], scope: TerminalRetentionScope, now: Date,
                        maxAge: TimeInterval?, maxBytes: Int64?, bytes: TerminalRetentionByteKind,
                        familyLimit: Int = .max) throws -> TerminalRetentionPlan
```

Keep the existing `make(sessions:workflows:now:retentionHours:maxPayloadBytes:)`
signature as a thin wrapper. It keeps its current validation (non-empty workflow
set; each id non-empty and ≤512 bytes; hours 1...8760; bytes
1...68_719_476_736) and delegates with `.workflows(workflows)`,
`maxAge: hours*3600`, `bytes: .results`. The CLI `session prune` still calls it,
so its results must be identical.

New-API validation (throw `.invalidPolicyOrMetadata` on failure):

- at least one of `maxAge` and `maxBytes` is set;
- `maxAge` is in (0, 36500*86400];
- `maxBytes` is in 1...(1<<50);
- `familyLimit` ≥ 1;
- for `.workflows`, the set is non-empty and its entries are valid;
- for `.allExcept`, entries are non-empty and ≤512 bytes, and the set may be
  empty;
- session ids are unique, and `payloadBytes` and `messageBytes` are ≥ 0.

Semantics:

- **Family building is unchanged.** In the `.workflows` scope, the gate is
  "family contains a member whose workflow is in the scope", and
  `rootOutsideScope` applies as today. In `.allExcept(keep)`, every family is
  considered. If any member's `workflowId` is in `keep`, the reason is
  `keptWorkflow`. Assign it before the status and timestamp checks, so a stronger
  later reason still overrides it, matching today's override order where the
  last assignment wins. The explicit `protection` stays last.
- **Byte totals.** Each family sums `payloadBytes` and `messageBytes` with
  overflow checks. `beforeBytes` and `projectedRemainingBytes` use the selected
  kind: `.results` uses `payloadBytes`, `.messages` uses `messageBytes`.
- **Selection.** Over unprotected families sorted by `(updatedAt, rootId)`,
  select a family when `(maxAge != nil && updatedAt <= now - maxAge) ||
  (maxBytes != nil && remaining > maxBytes)`.
- **Messages kind.** A family whose `messageBytes == 0` is never selected and
  does not count toward `familyLimit`. This covers families whose messages were
  already retired (design §4.3).
- **Family limit.** Once `selected.count == familyLimit`, stop. Set
  `workLimitReached = true` only if at least one more family would have been
  selected.
- **Cap result.** `capAchieved` is `maxBytes == nil || remaining <= maxBytes`.
- **Eligible families.** `eligible` is every unprotected family in
  `(updatedAt, rootId)` order, independent of `maxAge`, `maxBytes` and
  `familyLimit`, so it is a superset of `selected`. For `bytes: .messages` it
  excludes families with `messageBytes == 0`. The executor (ar-05) re-selects
  over `eligible` for the merged families-plus-orphans messages pass and
  rechecks membership against it. The legacy wrapper may populate it too; its
  other behavior is unchanged.

### `Sources/RielaCore/RielaLogRetentionPlan.swift` (new)

Pinned contract:

```swift
public struct RielaLogFileEntry: Equatable, Sendable {
  public enum Kind: String, Sendable { case regular, symlink, directory, other }
  public var name: String; public var kind: Kind; public var size: Int64
  public var modifiedAt: Date; public var device: UInt64; public var inode: UInt64
}
public struct RielaLogRetentionPlan: Equatable, Sendable {
  public static let graceInterval: TimeInterval = 86_400
  public var selected: [RielaLogFileEntry]; public var protected: [String: Int]
  public var beforeBytes: Int64; public var projectedRemainingBytes: Int64
  public var capAchieved: Bool; public var workLimitReached: Bool
  public static func make(entries: [RielaLogFileEntry], now: Date, maxAge: TimeInterval?, maxBytes: Int64?,
                          removalLimit: Int = 1000) throws -> RielaLogRetentionPlan
}
```

Rules:

1. Classify protected entries first:
   - `symlink` -> `symlink`;
   - `directory` or `other` -> `notRegularFile`;
   - names starting with `.` -> `hidden`, even when the entry is regular.
   These never count toward bytes.
2. The managed set is regular, non-hidden files. `beforeBytes` is the sum of
   their `size`.
3. Inside the managed set, `now - modifiedAt < graceInterval` (which includes a
   future mtime) -> `withinGraceWindow`. These still count toward bytes.
4. Candidates are the managed files outside the grace window, sorted by
   `(modifiedAt, name)`. Select by the same OR rule as the family planner, up to
   `removalLimit`, with `workLimitReached` as above.
5. Validation is the same as the family planner: at least one limit, the same
   ranges, `removalLimit` ≥ 1, sizes ≥ 0.

## Patterns to imitate

- `TerminalRetentionPlan.make`: its overflow-checked addition and its
  `(updatedAt, rootId)` sort.
- `Tests/RielaCoreTests/TerminalRetentionPlanTests.swift`: its existing fixture
  style.

## Pitfalls

- Do not reorder the existing protection assignments. Add `keptWorkflow` in the
  correct position and verify the old tests still pass unchanged.
- A family with `maxAge == nil` and no cap pressure is never selected. Do not
  default the age to 0.
- `familyLimit` must not count families that are skipped as zero-message.
- The wrapper must reproduce today's selection exactly. All existing tests in
  `TerminalRetentionPlanTests` must stay green without edits, except where a new
  field forces a changed initializer call.

## Tests

`TerminalRetentionPlanTests` (extend):

- `.allExcept(["keep"])` -> a family with any member of workflow `keep` is
  protected `keptWorkflow` and the others are selected by age
- an age-only plan (`maxBytes: nil`) -> old families selected, `capAchieved` true
- a cap-only plan (`maxAge: nil`) -> oldest selected until `remaining <= cap`
- under cap pressure, running, suspended, created and unresolved-lineage
  families stay protected and `capAchieved` is false
- `.messages` -> totals use `messageBytes`, and a family with `messageBytes == 0`
  is not selected and does not consume `familyLimit`
- `familyLimit: 1` with three eligible families -> one selected and
  `workLimitReached` true
- `eligible` lists unselected unprotected families (for example a young family
  under no cap pressure) in `(updatedAt, rootId)` order, and for `.messages`
  excludes families with `messageBytes == 0`
- both limits nil -> throws
- the legacy wrapper returns a value equal to the new API with the mapped
  arguments, for an existing fixture

`RielaLogRetentionPlanTests` (new):

- age -> files older than `maxAge` selected oldest first
- cap -> oldest selected until the total is ≤ cap
- a file modified 1h ago -> protected `withinGraceWindow`; it counts in bytes,
  and `capAchieved` is false if it alone exceeds the cap
- symlink, directory and `.hidden` -> protected with the matching reasons and
  excluded from bytes
- `removalLimit: 2` -> two selected and `workLimitReached` true
- equal mtimes -> name order

## Verification

1. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetentionPlanTests|RielaLogRetentionPlanTests" > tmp/automatic-retention/ar-02-core-planners/test.log 2>&1'
   ```
   Must show exitStatus 0, testsRun ≥ (pre-existing TerminalRetentionPlanTests
   count + 15) and failureCount 0. Record the pre-existing count before editing.
2. ```
   arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet --no-cache Sources/RielaCore/TerminalRetentionPlan.swift Sources/RielaCore/RielaLogRetentionPlan.swift Tests/RielaCoreTests/TerminalRetentionPlanTests.swift Tests/RielaCoreTests/RielaLogRetentionPlanTests.swift > tmp/automatic-retention/ar-02-core-planners/swiftlint.log 2>&1'
   ```
   Must exit 0.
3. ```
   arch -arm64 /bin/zsh -lc 'swift test --filter TerminalRetentionTests > tmp/automatic-retention/ar-02-core-planners/cli-regression.log 2>&1'
   ```
   Must exit 0. This proves the legacy wrapper keeps `session prune` green. If
   it fails only because of in-progress peer edits in RielaCLI, record that as
   peer drift.

## Done criteria

- `grep -n "case allExcept" Sources/RielaCore/TerminalRetentionPlan.swift` matches.
- `grep -n "graceInterval: TimeInterval = 86_400" Sources/RielaCore/RielaLogRetentionPlan.swift`
  matches.
- The verification records exist in `impl-plans/progress/ar-02-core-planners.md`
  with integer fields.
