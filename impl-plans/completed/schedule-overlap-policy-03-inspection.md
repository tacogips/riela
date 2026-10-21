# Schedule Overlap Policy 03: CLI Inspection Output Implementation Plan

**planId**: `overlap-03-inspection`
**Status**: Completed 2026-10-22 (implemented in `cd109008`; accepted by the session-474 integration review)
**Workflow Mode**: issue-resolution
**Issue Reference**: none (no issueUrl or issueNumber). The intake came from
workflowInput.requestedBehavior via comm-008602 and comm-008603.
workflowExecutionId: `opus-luna-design-and-implement-review-loop-session-471`.
**Design Reference**: `design-docs/specs/design-scheduled-overlap-policy.md`
(accepted by Step 3, comm-008607): §5.1 (the `events validate` success records),
§7.1 (the `events list` suffixes), §7.3 (`workflow inspect` triggerDefaults).
**dependsOn**: `overlap-01-contracts`
**Branch**: `feat/schedule-overlap-policy`. Make no commits, run no git write
commands.
**Progress log**: `impl-plans/progress/overlap-03-inspection.md`
**Evidence dir**: `tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/`

## Intent and Context

Operators must be able to see the declared and effective overlap policy, and
why a fire was skipped. This plan only changes CLI output:

- `riela events validate` reports each cron binding's declared policy.
- `riela events list` shows each receipt's reason and binding.
- `riela workflow inspect` shows `triggerDefaults`.

Relevant code:

- `Sources/RielaCLI/ScopedParityCommands.swift` `eventResult`: the
  `validate` case is at l.604-615 and the `list` case at l.666-678. Records are
  `"key=value"` strings.
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`:
  - `WorkflowInspectionSummary` is at l.237-264.
  - It is constructed at l.751.
  - The text renderer around l.880-960 appends lines, for example
    `renderLoopText`.

Contracts from `overlap-01-contracts`: `EventBindingContract.overlapPolicy`
(String?), `PersistedEventReceipt.bindingId` / `reason`,
`WorkflowDefinition.triggerDefaults: EventOverlapSettings?`.

## Non-Goals

- Do not resolve the workflow layer in `events validate`. It shows only the
  binding-declared value.
- Do not change validation diagnostics. They belong to `overlap-01`.
- Do not touch the serve, dispatcher, routine, GraphQL or SurfaceCatalog
  files.
- Do not change the existing record keys or their order. Only append.

## File-Level Changes

### 1. `Sources/RielaCLI/ScopedParityCommands.swift`

**`events validate`, success path only (`diagnostics.isEmpty`).** After the
existing two records, append one record per enabled binding whose source has
`kind == .cron`:

- Format: `binding=<id> overlapPolicy=<binding.overlapPolicy ?? "inherit">`.
- Order: the binding order in `config.bindings`.
- Look up the source kind in `config.sources` by `sourceId`.
- When there is no config, append nothing.

**`events list`.** Extend each record line as follows:

- If `reason` is non-nil and non-empty, append ` reason=<reason>`.
- Then, if `bindingId` is non-nil, append ` binding=<bindingId>`.
- The existing prefix stays
  `receipt=… source=… status=… workflowExecutionId=…`.
- The existing `--status` filter is unchanged. It already matches by string,
  so the new statuses work.

### 2. `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`

- Add `public var triggerDefaults: EventOverlapSettings?` to
  `WorkflowInspectionSummary`, after `loop`. Synthesized Codable omits it
  when nil, so the existing JSON output is unchanged for workflows without
  it.
- Construction (l.751): pass `triggerDefaults: workflow.triggerDefaults`.
- Text renderer: when non-nil, append one line,
  `triggerDefaults: overlapPolicy=<v> [maxQueuedRuns=<n>] [maxConcurrentRuns=<n>]`.
  Include each cap only if set. If `overlapPolicy` is nil, print
  `overlapPolicy=inherit`.
- Fix any other `WorkflowInspectionSummary(` constructor call that fails to
  compile. Run `grep -rn "WorkflowInspectionSummary(" Sources Tests` first.
  Calls outside this file must not break, because the new field is Optional.
  If a memberwise call needs it anyway, record that in the progress log and
  only touch files in your `writePaths`.

### 3. Tests: `Tests/RielaCLITests/OverlapPolicyInspectionTests.swift` (new, class `OverlapPolicyInspectionTests`)

Drive the existing command runner the same way
`Tests/RielaCLITests/EventReadOnlyPolicyTests.swift` does: temp event root,
then run `events validate` / `events list` through the parity command entry.
Use `WorkflowInspectCommand` for inspect, as in
`Tests/RielaCLITests/WorkflowHostCapabilityTests.swift`.

| Situation | Expected outcome |
|---|---|
| cron source with binding `overlapPolicy: "queue", maxQueuedRuns: 2` plus a second cron binding without the field; run `events validate` | status `ok`; records contain `binding=<a> overlapPolicy=queue` and `binding=<b> overlapPolicy=inherit` |
| non-cron (webhook) binding | no `overlapPolicy=` record for it |
| receipts dir holding a receipt with `reason: "overlap-skip:b:session-1"`, `bindingId: "b"`, `status: "skipped"`; run `events list --status skipped` | one line ending ` reason=overlap-skip:b:session-1 binding=b` |
| legacy receipt without `bindingId` or `reason`; run `events list` | the line has no ` reason=` and no ` binding=` suffix |
| workflow bundle in a temp `--workflow-definition-dir` with `"triggerDefaults": {"overlapPolicy":"queue","maxQueuedRuns":2}`; run `workflow inspect` | JSON summary `triggerDefaults` equals the input; text output contains `triggerDefaults: overlapPolicy=queue maxQueuedRuns=2` |
| workflow without `triggerDefaults` | JSON has no `triggerDefaults` key; text has no `triggerDefaults:` line |

Write the receipt fixtures with `JSONEncoder` and ISO8601 dates, using the
`PersistedEventReceipt` memberwise init. Use temp directories only.

## Invariants

- Existing record prefixes and order are unchanged. Output only gains appended
  text.
- No validation semantics change.

## Execution Protocol (shared working directory)

- **Before each edit:** read the file fresh and record `git hash-object` before
  and after. On drift, re-read and reapply your intent.
- **Write scope:** edit only this plan's `writePaths`.
- **Concurrent plans:** `overlap-02` and `overlap-04` are editing other
  `RielaCLI` files at the same time.
- **Build failures in files you do not own:** retry the build up to three
  times, then record the failure. Never edit those files.
- **Scratch files:** only under `tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/`.
- **Git:** run no git write commands.

## Verification

```text
V0: mkdir -p tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection
V1: arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/v1-build.log 2>&1
V2: arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "OverlapPolicyInspectionTests|EventReadOnlyPolicyTests|WorkflowHostCapabilityTests|WorkflowInstalledAddonMetadataTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/v2-tests.log 2>&1
V3: arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Sources/RielaCLI/ScopedParityCommands.swift Sources/RielaCLI/WorkflowValidateInspectCommands.swift Tests/RielaCLITests/OverlapPolicyInspectionTests.swift' > tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/v3-lint.log 2>&1
```

Expected results:

- V1: exit 0.
- V2: exit 0, `testsRun > 0`, 0 failures.
- V3: exit 0.

For each command, record an integer `exitStatus`, `testsRun`, `failureCount`
and `logPath`.

## Acceptance Criteria

1. `grep -n "overlapPolicy=" Sources/RielaCLI/ScopedParityCommands.swift` matches.
2. `grep -n " reason=" Sources/RielaCLI/ScopedParityCommands.swift` matches.
3. `grep -n "triggerDefaults" Sources/RielaCLI/WorkflowValidateInspectCommands.swift` matches.
4. V1-V3 pass, with the records in the progress log.

## Progress Log Expectations

`impl-plans/progress/overlap-03-inspection.md` must contain:

- a task checklist;
- a table of pre and post hashes;
- the V1-V3 records;
- residual notes. They must not start with a severity word.
