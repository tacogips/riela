# Issue 188 Plan 02: Workflow validation for `deadlineMs` and `retry`

**Status**: Ready
**planId**: issue188-02-validation
**dependsOn**: (none; wave 1; raw-JSON only)
**Design Reference**: design-docs/specs/design-step-deadline-and-retry-policy.md §6; design-docs/specs/design-workflow-json.md `WorkflowStepRef`
**Issue**: tacogips/riela#188
**Created**: 2026-11-10
**Last Updated**: 2026-11-10

## Intent and context

`riela workflow validate` and loading a workflow must reject invalid or unbounded policies with clear, path-qualified errors. Validation runs on the raw JSON dictionaries in `Sources/RielaCore/WorkflowRawValidation.swift`, in the step loop at lines ~141–215: an `allowedKeys` set, then a per-entry checks loop. This plan needs no types from plan 01.

## Non-goals

- No runtime enforcement.
- No change to `DynamicWorkflowPolicy.swift`.
- No change to fanout validation.
- No change to `WorkflowGatewayAddonValidation.swift`.

## File-level changes

### Sources/RielaCore/WorkflowRawValidation.swift
- Add `"deadlineMs"` and `"retry"` to the step `allowedKeys` set.
- In the per-entry loop, after the `stallTimeoutMs` check, call the new helper once with the entry, its path, the nodes array or id map already available in this function, and `diagnostics`.
- Keep the edit minimal: one call plus the two keys.

### Sources/RielaCore/WorkflowRawValidation+StepRetry.swift (new)

Use an internal function, such as `validateStepDeadlineAndRetry(_ entry: [String: Any], path: String, nodeEntries: [Any], diagnostics: inout [WorkflowValidationDiagnostic])`. Use `error(_:_:)` from `WorkflowValidationHelpers.swift`.

Rules, in this order:
1. **`deadlineMs`**, when present, must be an integer in `1...86_400_000`. Error path: `"\(path).deadlineMs"`.
2. **`retry`**, when present, must be an object. Its keys must be a subset of `maxAttempts, initialDelayMs, multiplier, maxDelayMs, jitter`. Report an unknown key at `"\(path).retry.<key>"`.
   - `maxAttempts` is required, integer `1...10`.
   - `initialDelayMs` is an integer `0...3_600_000`.
   - `multiplier` is a finite number `1.0...10.0`.
   - `maxDelayMs` is an integer `0...3_600_000`, and `>= effective initialDelayMs`, where the default is 1000 when absent.
   - `jitter` is `"none"` or `"deterministic"`.
3. `retry` present without `deadlineMs` → error at `"\(path).retry"`: "retry requires deadlineMs (total elapsed budget)".
4. Step-authored `timeoutMs > deadlineMs` → error at `"\(path).timeoutMs"`. Only when **both** are authored on the step; never compare against `defaults.nodeTimeoutMs`.
5. If either field is present, the step's `nodeId` must resolve to a `nodes[]` entry with an inline `addon` object. Otherwise error at `"\(path).deadlineMs"` or `"\(path).retry"`: "is supported only on add-on-backed steps".
6. `retry` present and the node's `addon.config.writeRetry` present → error at `"\(path).retry"`: "cannot be combined with addon config.writeRetry (nested retry)".
7. Either field together with `placement` → error at `"\(path).placement"`.

Pitfalls:
- `JSONSerialization` yields `NSNumber`. A JSON `true` is also an NSNumber, so reject booleans. Imitate how `validateNumberField` in `WorkflowValidationHelpers.swift` distinguishes types, and do the CFBoolean check where that helper does not.
- Reject non-integral values (`1.5`) for millisecond and attempt fields.
- Reject NaN and Infinity for `multiplier`.
- Report every applicable diagnostic. Do not stop at the first one (match the existing loop style).
- Do not emit diagnostics for steps that use neither field. Existing workflows must produce identical diagnostics.

### Tests/RielaCoreTests/StepRetryPolicyValidationTests.swift (new)

Imitate `Tests/RielaCoreTests/WorkflowStepFailurePolicyTests.swift`. Use its `workflowData` helper shape and the validation entry point those tests call; copy the helper into the new file, do not edit that file.

## Invariants

- Workflows without these keys validate exactly as before.
- Error messages name the full path, for example `workflow.steps[0].retry.maxDelayMs`.

## Test cases (input → expected)

- Valid: add-on step with `deadlineMs:600000`, `timeoutMs:180000`, `retry:{maxAttempts:4,initialDelayMs:2000,multiplier:2,maxDelayMs:60000,jitter:"deterministic"}` → no diagnostics.
- Valid: add-on step with `deadlineMs` only → none.
- `deadlineMs:0` / `-1` / `1.5` / `true` / `"600"` / `86400001` → error at `.deadlineMs`.
- `retry:{}` → missing `maxAttempts`.
- `maxAttempts:0` and `maxAttempts:11` → errors.
- `multiplier:0.5` → error.
- `initialDelayMs:5000, maxDelayMs:1000` → error at `.retry.maxDelayMs`.
- `retry:{maxAttempts:2,foo:1}` → error at `.retry.foo`.
- `jitter:"random"` → error.
- `retry` without `deadlineMs` → error.
- `timeoutMs:700000, deadlineMs:600000` → error at `.timeoutMs`.
- `defaults.nodeTimeoutMs:900000` with step `deadlineMs:600000` and no step `timeoutMs` → **no** error (clamped at runtime).
- Agent (`nodeFile`) step with `deadlineMs` → add-on-only error.
- Add-on node with `config.writeRetry` plus step `retry` → nested-retry error. Same node with only `deadlineMs` → OK.
- `placement` plus `retry` → error.
- Regression: a workflow with no new keys → diagnostics identical to before; assert empty for a known-valid fixture.

## Verification (each must exit 0)

1. `mkdir -p tmp/issue-188 && arch -arm64 /bin/zsh -lc 'swift test --filter StepRetryPolicyValidationTests 2>&1 | tee tmp/issue-188/p02-test.log; exit ${pipestatus[1]}'` — all cases pass.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowStepFailurePolicyTests|WorkflowLoopValidationTests" 2>&1 | tee tmp/issue-188/p02-regression.log; exit ${pipestatus[1]}'` — no regression.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/WorkflowRawValidation.swift Sources/RielaCore/WorkflowRawValidation+StepRetry.swift Tests/RielaCoreTests/StepRetryPolicyValidationTests.swift 2>&1 | tee tmp/issue-188/p02-lint.log; exit ${pipestatus[1]}'`

## Edit safety

- Re-read before each edit, and record pre- and post-edit sha256 in the progress log.
- `WorkflowRawValidation.swift` is owned only by this plan.
- On drift, re-read and re-apply only the two-key and one-call intent.

## Completion criteria

- [ ] All 7 rules are implemented, with path-qualified diagnostics.
- [ ] Verification 1–3 exit 0, with log paths recorded.
- [ ] Only writePaths and this plan file are changed.

## Progress Log

### Session: 2026-11-10
**Tasks Completed**: Plan authored (Opus).
**Blockers**: None.
