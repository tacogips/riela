# Schedule Overlap Policy 01: Contracts Implementation Plan

**planId**: `overlap-01-contracts`
**Status**: Ready for implementation (wave 1)
**Workflow Mode**: issue-resolution
**Issue Reference**: none (no issueUrl or issueNumber). The intake came from
workflowInput.requestedBehavior via comm-008602 and comm-008603.
workflowExecutionId: `opus-luna-design-and-implement-review-loop-session-471`.
**Design Reference**: `design-docs/specs/design-scheduled-overlap-policy.md`
(accepted by Step 3, comm-008607): §3, §4, §5, §7.1 receipt fields, §9 record
fields, §11 `lastRunAt`. User decisions are in
`design-docs/user-qa/qa-scheduled-overlap-policy.md`.
**dependsOn**: none
**Branch**: `feat/schedule-overlap-policy`. Make no commits, do not push, run
no git write commands.
**Progress log**: `impl-plans/progress/overlap-01-contracts.md`
**Evidence dir**: `tmp/schedule-overlap-policy-20261021-session-471/overlap-01-contracts/`

## Intent and Context

This plan pins the shared data contracts every later plan builds on:

- the policy enum and its resolver;
- the workflow `triggerDefaults` field and its raw validation;
- the event-binding fields and their validator diagnostics;
- the routine record fields and a `recordRunCompletion` that never moves
  `lastRunAt` backwards;
- the extra optional fields on the persisted event receipt.

This plan changes no runtime behavior. The serve loop, CLI, and GraphQL are
changed in waves 2 and 3 (`overlap-02`, `overlap-03`, `overlap-04`).

How the code works today (`main` @ `3e6d4adf`):

- `EventBindingContract` (`Sources/RielaEvents/EventContracts.swift:626`) has a
  custom `init(from:)` that uses `decodeIfPresent`, plus a synthesized encoder.
- `WorkflowDefinition` (`Sources/RielaCore/WorkflowModel.swift:602`) and
  `AuthoredWorkflowJSON` (`WorkflowModel.swift:505`) use synthesized Codable.
- The authored workflow is converted into the definition in
  `Sources/RielaCore/WorkflowValidation.swift` around l.600-614, in the call
  `return WorkflowDefinition(...)` that passes `loop:` and `handover:`.
- Raw validation (`validateRawAuthoredWorkflow` in
  `Sources/RielaCore/WorkflowRawValidation.swift:15`) runs before the typed
  decode (`WorkflowValidation.swift` `validateAuthoredWorkflowData`).
- `RoutineRecord` (`Sources/RielaCore/RoutineStore.swift:13`) uses synthesized
  Codable stored in the JSONB `record_json` column. `recordRunCompletion` is
  at `RoutineStore.swift:253`.
- `PersistedEventReceipt` is defined in `Sources/RielaCLI/EventReadOnly.swift:89`.

## Non-Goals

- Do not change the serve loop, dispatch, `dueTick`, receipts writing, CLI
  output, GraphQL, or SurfaceCatalog. Those belong to other plans.
- Add no policy values beyond `skip`, `cancelRunning`, `queue`, `concurrent`.
  Add no `inherit` or `none` value.
- Make no SQLite schema or `user_version` bump for routines. The new fields
  live in `record_json`.
- Do not change `WorkflowLoopValidation.swift`. Do not make its private
  helpers public. Copy the boolean-NSNumber idiom instead.
- Do not touch the `typed` validation path (`validateTypedAuthoredWorkflow`).
  Raw validation is the gate for this feature.

## File-Level Changes

### 1. `Sources/RielaCore/EventOverlapPolicy.swift` (new)

Pin these public contracts. Other plans use these exact names.

- `public enum EventOverlapPolicy: String, Codable, CaseIterable, Sendable { case skip, cancelRunning, queue, concurrent }`
  - Raw values must equal the case names exactly.
  - Add `public static let allowedValuesText = "skip, cancelRunning, queue, concurrent"`.
    Keep this order. It is used verbatim in diagnostics.
- `public enum EventOverlapPolicySource: String, Codable, Sendable { case binding, workflow, \`default\` }`
- `public struct EventOverlapSettings: Codable, Equatable, Sendable`
  - Fields: `overlapPolicy: String?`, `maxQueuedRuns: Int?`,
    `maxConcurrentRuns: Int?`.
  - Add a public memberwise init with all parameters defaulting to nil.
  - This is the authored, unvalidated layer. It is used for both
    `workflow.triggerDefaults` and the binding projection.
- `public struct EffectiveEventOverlapPolicy: Codable, Equatable, Sendable`
  - Fields: `policy: EventOverlapPolicy`, `source: EventOverlapPolicySource`,
    `maxQueuedRuns: Int?`, `maxConcurrentRuns: Int?`.
- `public struct EventOverlapPolicyError: Error, Equatable, Sendable, CustomStringConvertible`
  holds a `message`.
- `public let defaultEventOverlapMaxQueuedRuns = 1` (or a static on the enum;
  either is fine, but pick one name and record it in the progress log).
- The resolver function:

  ```swift
  public func resolveEventOverlapPolicy(binding: EventOverlapSettings?, workflow: EventOverlapSettings?) throws -> EffectiveEventOverlapPolicy
  ```

  Rules (design §4.3):
  1. Find the winning layer. If `binding?.overlapPolicy` is non-nil, the binding
     wins. Otherwise, if `workflow?.overlapPolicy` is non-nil, the workflow wins.
     Otherwise the result is `.skip` with source `.default`.
  2. Take the caps only from the winning layer:
     - `policy == .queue`: `maxQueuedRuns = winner.maxQueuedRuns ?? 1`.
     - `policy == .concurrent`: `maxConcurrentRuns = winner.maxConcurrentRuns`.
       nil means no cap.
     - Any other policy: both caps are nil.
  3. A winning value that is not a valid `EventOverlapPolicy` throws
     `EventOverlapPolicyError("overlapPolicy must be one of skip, cancelRunning, queue, concurrent; got '<v>'")`.

### 2. `Sources/RielaCore/WorkflowTriggerDefaultsValidation.swift` (new)

Add `func validateRawTriggerDefaults(_ raw: Any?, diagnostics: inout [WorkflowValidationDiagnostic])`
(internal). Messages and paths must match design §5.2 exactly. Use the
`error(_:_:)` helper from `WorkflowValidationHelpers.swift`.

| Situation | Path | Message |
|---|---|---|
| `raw` is nil | (none) | No diagnostic; return. |
| `raw` is not `[String: Any]` | `workflow.triggerDefaults` | `must be an object when provided` |
| a key other than the three known keys | `workflow.triggerDefaults.<k>` | `is not a supported triggerDefaults field` |
| `overlapPolicy` is not a String or not an allowed value | `workflow.triggerDefaults.overlapPolicy` | `must be one of skip, cancelRunning, queue, concurrent` |
| a cap is not an integer ≥ 1 | `workflow.triggerDefaults.maxQueuedRuns` / `.maxConcurrentRuns` | `must be an integer >= 1` |
| `maxQueuedRuns` present while `overlapPolicy != "queue"` (including absent) | `workflow.triggerDefaults.maxQueuedRuns` | `requires workflow.triggerDefaults.overlapPolicy queue` |
| `maxConcurrentRuns` present while `overlapPolicy != "concurrent"` | `workflow.triggerDefaults.maxConcurrentRuns` | `requires workflow.triggerDefaults.overlapPolicy concurrent` |

"Integer ≥ 1" means all of the following:

- it is an `NSNumber`;
- it is not a boolean. Mirror `WorkflowLoopValidation.swift:842`
  (`CFGetTypeID(number) == CFBooleanGetTypeID()`); copy the idiom, do not
  import the private helper;
- `doubleValue` equals `Double(intValue)`;
- `intValue >= 1`.

### 3. `Sources/RielaCore/WorkflowRawValidation.swift`

Add exactly one call in `validateRawAuthoredWorkflow`:
`validateRawTriggerDefaults(raw["triggerDefaults"], diagnostics: &diagnostics)`.
Place it next to the `validateRawMemoryDeclarations` call (around l.46),
before the `nodes` guard's early `return`. Make no other edits.

### 4. `Sources/RielaCore/WorkflowModel.swift`

- `AuthoredWorkflowJSON`: add `public var triggerDefaults: EventOverlapSettings?`.
  Add an init parameter with default `nil`, placed after `handover`.
- `WorkflowDefinition`: add `public var triggerDefaults: EventOverlapSettings?`.
  Add an init parameter `triggerDefaults: EventOverlapSettings? = nil`. Put it
  last or after `handover`, and keep every existing call site compiling.

### 5. `Sources/RielaCore/WorkflowValidation.swift`

In the authored-to-definition conversion (around l.600-614), pass
`triggerDefaults: workflow.triggerDefaults`. Make no other edit.

### 6. `Sources/RielaCore/RoutineStore.swift`

- `RoutineRecord`: add `public var overlapPolicy: String?`,
  `public var maxQueuedRuns: Int?` and `public var maxConcurrentRuns: Int?`.
  Add init parameters defaulting to `nil`, appended after `origin`.
  Synthesized Codable decodes missing keys as nil, so existing DB rows still
  load.
- `recordRunCompletion(routineId:at:)`:
  - Set `lastRunAt` to the later of the existing value and `at`. Parse the
    existing value with the same ISO8601 fractional-seconds format as
    `RoutineStore.timestamp`. If parsing fails or the value is nil,
    overwrite it.
  - `runCount += 1` stays inside the same `update` transaction.

### 7. `Sources/RielaEvents/EventContracts.swift`

- `EventBindingContract`:
  - Add `public var overlapPolicy: String?`, `public var maxQueuedRuns: Int?`
    and `public var maxConcurrentRuns: Int?`.
  - Add the matching `CodingKeys` cases.
  - Add init parameters defaulting to `nil`, appended after
    `routineStoreRoot`.
  - In `init(from:)`, use `decodeIfPresent` for each.
  - The synthesized encoder must omit nil fields. Do not write a custom
    `encode` unless one already exists. If one exists, use
    `encodeIfPresent`.
- Add a computed `public var overlapSettings: EventOverlapSettings?`. It
  returns nil when all three fields are nil.

### 8. `Sources/RielaEvents/EventContractValidator.swift`

In the per-binding loop (l.76-95), add the diagnostics from design §5.1. Use
code `INVALID_EVENT_OVERLAP_POLICY`. Messages must be verbatim:

| Path | Message | Condition |
|---|---|---|
| `bindings[<i>].overlapPolicy` | `overlapPolicy must be one of skip, cancelRunning, queue, concurrent; got '<v>'` | unknown value |
| `bindings[<i>].overlapPolicy` | `overlapPolicy is only supported on bindings whose source kind is cron` | the value is set, the source exists in `sourcesById`, and its `kind != .cron`. Skip this check when the source is unknown. |
| `bindings[<i>].maxQueuedRuns` | `maxQueuedRuns must be an integer >= 1` | value < 1 |
| `bindings[<i>].maxQueuedRuns` | `maxQueuedRuns requires overlapPolicy queue on the same binding` | present while `overlapPolicy != "queue"` |
| `bindings[<i>].maxConcurrentRuns` | `maxConcurrentRuns must be an integer >= 1` | value < 1 |
| `bindings[<i>].maxConcurrentRuns` | `maxConcurrentRuns requires overlapPolicy concurrent on the same binding` | present while `overlapPolicy != "concurrent"` |

Put the logic in a private helper, `validateOverlapPolicy(binding:source:index:diagnostics:)`,
modeled on `validateMailboxBridge`.

### 9. `Sources/RielaCLI/EventReadOnly.swift`

Make one edit only: add optional stored properties to `PersistedEventReceipt`:

- `bindingId: String?`
- `overlapPolicy: String?`
- `overlapPolicySource: String?`
- `cancelledSessionIds: [String]?`
- `coalescedTickCount: Int?`

Declare them as `var x: T?` with no explicit initializer, so the memberwise
init gets defaulted parameters and the existing call sites in
`ScopedParityCommands.swift` and `EventReadOnly.swift` keep compiling without
edits. Do not change `runEventWorkflow` or `recordReadOnlyEventIfNeeded`.

### 10. Tests

**`Tests/RielaCoreTests/EventOverlapPolicyTests.swift`** (new, class
`EventOverlapPolicyTests`):

- Resolution:
  - no binding, no workflow → `.skip` / `.default`, both caps nil
  - workflow `queue` without a cap → `.queue` / `.workflow` / `maxQueuedRuns == 1`
  - binding `concurrent` with cap 3 and workflow `queue` with cap 5 → `.concurrent` / `.binding`, `maxConcurrentRuns == 3`, `maxQueuedRuns == nil`
  - binding nil and workflow `cancelRunning` → `.cancelRunning` / `.workflow`
  - binding `"bogus"` → throws `EventOverlapPolicyError` with the exact message
- Raw workflow validation, via `validateAuthoredWorkflowData` on a minimal
  valid workflow JSON (copy one from an existing RielaCoreTests fixture):
  - `triggerDefaults: {"overlapPolicy":"bogus"}` → a diagnostic at path `workflow.triggerDefaults.overlapPolicy` with the exact message
  - `{"overlapPolicy":"skip","maxQueuedRuns":2}` → the `requires ... queue` diagnostic
  - `{"overlapPolicy":"queue","maxQueuedRuns":0}` → `must be an integer >= 1`
  - `{"overlapPolicy":"queue","maxQueuedRuns":true}` → `must be an integer >= 1`
  - `{"typo":1}` → `is not a supported triggerDefaults field`
  - `triggerDefaults: "x"` → `must be an object when provided`
  - a workflow without `triggerDefaults` → no `triggerDefaults` diagnostics
  - valid `{"overlapPolicy":"queue","maxQueuedRuns":2}` → the decoded `WorkflowDefinition.triggerDefaults` equals the input
- Routine store, using a temp-dir `RoutineStore`:
  - `recordRunCompletion(at: t2)` then `recordRunCompletion(at: t1)` with
    `t1 < t2` → `lastRunAt` equals `t2`'s timestamp and `runCount == 2`
  - a record saved with `overlapPolicy: "queue"` and `maxQueuedRuns: 2` loads
    back with the same values
  - a record JSON without the keys loads with nil values

**`Tests/RielaEventsTests/EventOverlapContractValidationTests.swift`** (new,
class `EventOverlapContractValidationTests`):

- cron binding `overlapPolicy: "bogus"` → exactly one `INVALID_EVENT_OVERLAP_POLICY` diagnostic with the verbatim unknown-value message
- webhook (non-cron) binding `overlapPolicy: "skip"` → the "only supported on bindings whose source kind is cron" message
- cron binding `maxQueuedRuns: 2` without a policy → the "requires overlapPolicy queue" message
- `overlapPolicy: "concurrent"` with `maxConcurrentRuns: 0` → the ">= 1" message
- a cron binding with no fields → no overlap diagnostics
- JSON decode then encode of a binding with no overlap fields → the
  re-encoded JSON has no `overlapPolicy`, `maxQueuedRuns` or
  `maxConcurrentRuns` keys
- decoding `{"overlapPolicy":"queue","maxQueuedRuns":2}` → `overlapSettings`
  equals `EventOverlapSettings(overlapPolicy:"queue", maxQueuedRuns:2)`

## Invariants

- Configs and workflows without the new fields decode, validate, and encode
  exactly as before.
- No runtime behavior change. Existing `EventLiveServeCronTests`,
  `EventRoutineBindingTests` and `RoutineStoreTests` still pass unmodified.
- Diagnostic texts match the design verbatim. Later plans and the integration
  smoke check grep for them.

## Execution Protocol (shared working directory)

- **Before each edit:** read the file fresh and record `git hash-object <file>`
  in the progress log. If the hash differs from your last recorded value,
  re-read the file and reapply your intent; never overwrite blindly. Record
  the post-edit hash.
- **Write scope:** edit only this plan's `writePaths`.
- **Build failures outside your paths:** wave 1 has no peers. If such a failure
  happens anyway, record it as a blocker instead of fixing it.
- **Scratch files:** only under `tmp/schedule-overlap-policy-20261021-session-471/overlap-01-contracts/`.
- **Git:** run no git write commands, create no worktrees, no stash.

## Verification (each command must report a positive test count where applicable)

```text
V0: mkdir -p tmp/schedule-overlap-policy-20261021-session-471/overlap-01-contracts
V1: arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/schedule-overlap-policy-20261021-session-471/overlap-01-contracts/v1-build.log 2>&1
V2: arch -arm64 /bin/zsh -lc 'swift test --skip-build --filter "EventOverlapPolicyTests|EventOverlapContractValidationTests|RoutineStoreTests|EventRoutineBindingTests|EventDryRunTests|WorkflowLoopValidationTests|EventLiveServeCronTests"' > tmp/schedule-overlap-policy-20261021-session-471/overlap-01-contracts/v2-tests.log 2>&1
V3: arch -arm64 /bin/zsh -lc 'swiftlint lint --strict Sources/RielaCore/EventOverlapPolicy.swift Sources/RielaCore/WorkflowTriggerDefaultsValidation.swift Sources/RielaCore/WorkflowRawValidation.swift Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/WorkflowValidation.swift Sources/RielaCore/RoutineStore.swift Sources/RielaEvents/EventContracts.swift Sources/RielaEvents/EventContractValidator.swift Sources/RielaCLI/EventReadOnly.swift Tests/RielaCoreTests/EventOverlapPolicyTests.swift Tests/RielaEventsTests/EventOverlapContractValidationTests.swift' > tmp/schedule-overlap-policy-20261021-session-471/overlap-01-contracts/v3-lint.log 2>&1
```

Expected results:

- V1: exit 0.
- V2: exit 0, `testsRun > 0`, 0 failures. Both new classes appear in the log.
- V3: exit 0, no violations.

For each command, record an integer `exitStatus`, an integer `testsRun`, an
integer `failureCount`, and the full `logPath`.

## Acceptance Criteria (mechanically checkable)

1. `grep -n "case skip, cancelRunning, queue, concurrent" Sources/RielaCore/EventOverlapPolicy.swift` matches.
2. `grep -n "func resolveEventOverlapPolicy" Sources/RielaCore/EventOverlapPolicy.swift` matches.
3. `grep -n "INVALID_EVENT_OVERLAP_POLICY" Sources/RielaEvents/EventContractValidator.swift` matches.
4. `grep -n "triggerDefaults" Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/WorkflowValidation.swift Sources/RielaCore/WorkflowRawValidation.swift` matches in all three files.
5. V1-V3 pass as specified, and the progress log holds their records.

## Progress Log Expectations

`impl-plans/progress/overlap-01-contracts.md` must contain:

- a task checklist;
- a table of pre and post hashes per file;
- the chosen name of the default-queue constant;
- the V1-V3 records (`exitStatus`, `testsRun`, `failureCount`, `logPath`);
- residual notes. Residual-risk text must not start with a severity word.
