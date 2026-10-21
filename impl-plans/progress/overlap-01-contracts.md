# Schedule Overlap Policy 01: Contracts Progress

- Mode: `issue-resolution`; issue reference: none (`comm-008602`/`comm-008603` intake); codex-agent references: none. Workflow execution: `opus-luna-design-and-implement-review-loop-session-471`; fanout plan: `overlap-01-contracts`.
- Branch: `feat/schedule-overlap-policy`; dependencies: none. Design: `design-docs/specs/design-scheduled-overlap-policy.md` §§3–5, 7.1, 9, 11.
- State: assigned implementation complete. Formal integrity/adversarial review and any review-dependent reconciliation are downstream workflow steps; no commit or push was performed.
- Evidence directory: `tmp/schedule-overlap-policy-20261021-session-471/overlap-01-contracts/`. Per-edit intentions and pre-edit hashes: `edit-intentions.jsonl`; selected SwiftLint paths: `changed-swift-files.nul`.

## Completion criteria

- [x] `EventOverlapPolicy`, source, settings, effective result, error, default queue cap, and binding > workflow > skip resolver are defined in `Sources/RielaCore/EventOverlapPolicy.swift`.
- [x] `workflow.triggerDefaults` decodes and flows from `AuthoredWorkflowJSON` to `WorkflowDefinition`; raw validation emits the §5.2 paths and messages, including boolean/non-integer cap rejection.
- [x] `EventBindingContract` fields decode/encode, omit nil values, project through `overlapSettings`, and `EventContractValidator` emits `INVALID_EVENT_OVERLAP_POLICY` with the §5.1 messages.
- [x] `RoutineRecord` has the three optional overlap fields; run completion preserves the later timestamp and increments count inside its existing update transaction.
- [x] `PersistedEventReceipt` has optional `bindingId`, `overlapPolicy`, `overlapPolicySource`, `cancelledSessionIds`, and `coalescedTickCount` fields.
- [x] Resolver, workflow raw validation, Codable compatibility, contract diagnostics, and routine accounting tests were added.
- [x] Final V1–V3 gates pass on the final source identity.

## Implementation details

- The default queue cap is `defaultEventOverlapMaxQueuedRuns = 1`.
- Raw validation sorts unsupported triggerDefaults keys for deterministic diagnostic order.
- `RoutineStore.recordRunCompletion` parses existing timestamps with the same ISO8601 internet-date-time plus fractional-seconds format used by `RoutineStore.timestamp`; malformed or absent values are replaced.
- Runtime dispatch, inspection output, GraphQL/routine mutation surfaces, generated SDL, and docs belong to downstream plans and were not pulled into this contract plan.

## Final verification

Commands ran from the repository root through `arch -arm64 /bin/zsh -lc`; logs are complete under the evidence directory.

- V1 `swift build --build-tests`: exit 0; `v1-build-final-source.log`.
- V2 `swift test --skip-build --filter "EventOverlapPolicyTests|EventOverlapContractValidationTests|RoutineStoreTests|EventRoutineBindingTests|EventDryRunTests|WorkflowLoopValidationTests|EventLiveServeCronTests"`: exit 0; 68 tests, 0 failures; `v2-tests-final-source.log`.
- V3 strict changed-file SwiftLint via the NUL-delimited manifest: exit 0; `v3-lint-final-source.log`.

## Earlier attempts retained

- `v1-build.log` failed while compiling the first test draft; the follow-up build also exposed a zsh wrapper variable named `status` (read-only). The test type was corrected, and final V1 passed.
- `v2-tests.log`, `v2-tests-rerun.log`, and `v2-tests-final.log` preserve failed intermediate runs. They exposed a test binding pointed at an unknown source and a raw-policy validation branch that did not report unknown values. The test now uses a known source; raw validation uses explicit raw-value typing and has a direct assertion. Final-source V2 passes all 68 tests.
- `v3-lint.log` identified one `large_tuple` finding in the new test; the case representation was narrowed and final-source V3 passes.
