# Instance control 02: startedAt/endedAt on the instance executions projection

**Status**: Planned
**planId**: instance-control-02-executions-projection
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md D6, D5 (executions)
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-02-executions-projection/

## Intent and context

`GET /api/v1/instances/{identity}/executions` (`Sources/RielaAppSupport/RielaWebAPIProjection.swift:webExecutions`) returns `sessionId, workflowId, status, currentStepId, activeStepIds, updatedAt`. A monitor also needs the start and end time of each execution. This plan adds two additive fields to every item:

- `startedAt`: the session's `createdAt`, ISO-8601, or `null` when unknown.
- `endedAt`: `updatedAt` when status is terminal, otherwise `null`.

## Non-goals

- No change to existing fields, ordering, the 100-item bound or `truncated`.
- No new endpoint. No CLI work (plan 04 consumes these fields and tolerates their absence).
- No web console (SolidJS) change.

## File-level changes

1. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift`
   - `SessionSummary` gains `public var createdAt: Date?` as the **last** init parameter, with default `nil` so existing callers compile.
   - In `summaryRows` (around line 262), select `json_extract(snapshots.session_json, '$.createdAt') AS created_at`.
   - In `loadSessionSummaries`, map it through `Self.date(from:)`. An unparsable or missing value gives `nil` and never throws. A malformed `created_at` must not fail the row; only the existing required columns can.
2. `Sources/RielaViewer/WorkflowViewerSessionSummary.swift`
   - Add `public var startedAt: Date?`, with init parameter `startedAt: Date? = nil` placed last.
   - Codable stays backward compatible. The type is synthesized Codable, so the optional decodes as nil when absent. Verify this; if a custom `init(from:)` exists, use `decodeIfPresent`.
3. `Sources/RielaViewer/WorkflowViewer.swift`
   - At the two constructors (around lines 324 and 448), pass `startedAt: $0.createdAt` and `startedAt: session.createdAt` respectively.
4. `Sources/RielaAppSupport/RielaWebAPIProjection.swift` `webExecutions`: each item adds:
   - `"startedAt"`: the ISO-8601 string of `session.startedAt`, or `.null`;
   - `"endedAt"`: the ISO-8601 of `updatedAt` iff the status is terminal, else `.null`.
   - Terminal means every `WorkflowSessionStatus` case other than `running`, `paused` or another non-finished state. Read the enum in `Sources/RielaCore` and list the terminal cases explicitly in a `switch` with no `default`, so a new case forces a decision.
   - Use the same `ISO8601DateFormatter()` already used for `updatedAt` in that function.

## Tests

Add **Tests/RielaAppSupportTests/RielaAppInstanceExecutionsProjectionTests.swift (new)**. Imitate the projection fixtures in `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift` and the session-store setup used there or in `Tests/RielaViewerTests/WorkflowViewerTests.swift`. Use a temp session-store root under `tmp/`.

| Situation | Expected |
| --- | --- |
| A completed session with known createdAt/updatedAt | item `startedAt == createdAt` (ISO), `endedAt == updatedAt` |
| A running session | `endedAt == null`, `startedAt` set |
| A failed session | `endedAt` set |
| Old snapshot JSON without `createdAt` | `startedAt == null`; the response still succeeds |
| Any case | existing keys unchanged; byte-compare the other keys against expectations |

## Invariants

- Existing JSON keys and values are unchanged; the change is purely additive.
- `loadSessionSummaries` never throws because of `createdAt`.

## Verification (each exits 0; logs under the evidence root)

1. `mkdir -p tmp/instance-control/instance-control-02-executions-projection && arch -arm64 /bin/zsh -lc 'swift test --filter "RielaAppInstanceExecutionsProjectionTests|WorkflowViewerTests|RielaAppWebAPIRouteTests" 2>&1 | tee tmp/instance-control/instance-control-02-executions-projection/test.log; exit ${pipestatus[1]}'`
   - All three classes run with 0 failures.
   - A compile error caused only by a sibling plan's files is recorded as `sibling-blocked` and re-run later. Never edit sibling files.
2. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+WebSummaries.swift Sources/RielaViewer/WorkflowViewerSessionSummary.swift Sources/RielaViewer/WorkflowViewer.swift Sources/RielaAppSupport/RielaWebAPIProjection.swift Tests/RielaAppSupportTests/RielaAppInstanceExecutionsProjectionTests.swift 2>&1 | tee tmp/instance-control/instance-control-02-executions-projection/lint.log; exit ${pipestatus[1]}'`

## Edit safety

- Fresh-read before each edit, and record the pre- and post-edit sha256.
- These files are owned only by this plan. On drift, re-apply only the numbered changes.

## Completion criteria

- [ ] Both fields are emitted.
- [ ] Old snapshots are tolerated.
- [ ] Verification 1–2 exit 0, with logs recorded.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.
