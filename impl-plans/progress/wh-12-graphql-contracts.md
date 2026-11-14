# wh-12-graphql-contracts progress

Plan: `impl-plans/active/wh-12-graphql-contracts.md`  
Issue: no GitHub issue supplied; tracked under `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.  
Branch: `feat/work-handover-and-takeover`  
Dependency: `wh-01-contracts` accepted by the dispatch integration review (`fanoutItem.acceptedPlanIds`).

## Implementation

- Added `Sources/RielaGraphQL/TaskHandoverGraphQL.swift`: pinned DTOs, provider protocol, seven root-operation handlers, error payload mapping, 4 MiB report input bound, domain preflight, and standalone SDL block.
- Added `Tests/RielaGraphQLTests/TaskHandoverGraphQLTests.swift`: seven-operation routing and decoded arguments, unhandled delegation, provider error payload, oversized report rejection before provider call, and SDL contract checks.
- No provider, root-field/catalog registration, auth wrapper, generated SDL registration, or integration wiring was added; those seams belong to wh-16/wh-20.

## Verification

Final source verification is under `tmp/work-handover/wh-12-graphql-contracts/attempt-04/`:

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-12-graphql-contracts/attempt-04/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-12-graphql-contracts/attempt-04/build.log'` — exit 0; build complete.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "TaskHandoverGraphQLTests|RoutineGraphQLTests" > tmp/work-handover/wh-12-graphql-contracts/attempt-04/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-12-graphql-contracts/attempt-04/focused.log'` — exit 0; 10 tests, 0 failures.
- `arch -arm64 /bin/zsh -lc 'if [ -s tmp/work-handover/wh-12-graphql-contracts/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/work-handover/wh-12-graphql-contracts/changed-swift-files.nul > tmp/work-handover/wh-12-graphql-contracts/attempt-05/swiftlint.log 2>&1; else printf \"%s\\n\" \"No Swift files changed; selected-file SwiftLint not run.\" > tmp/work-handover/wh-12-graphql-contracts/attempt-05/swiftlint.log; fi; echo \"exit=$?\" >> tmp/work-handover/wh-12-graphql-contracts/attempt-05/swiftlint.log'` — exit 0; full log `tmp/work-handover/wh-12-graphql-contracts/attempt-05/swiftlint.log`.
- `git diff --check` — exit 0; full log `attempt-04/diff-check.log`.

Earlier failed attempts are retained: `focused.log` (first test iteration), `attempt-02/focused.log` (the new SDL type was not yet registered in the global parser, which is wh-20 work), and `swiftlint.log` (initial line-length and statement-position diagnostics). The parser test now uses the parser-supported `JSONObject!` variable declaration while exercising the pinned report input decoding and byte gate. The final source-matched verification above passes.

## Completion

- [x] DTOs, protocol, executor and SDL names implemented.
- [x] All seven operations route through the provider; unrelated documents delegate.
- [x] Provider failures return payload errors with allowed codes; oversized report input is rejected before provider invocation.
- [x] `TaskHandoverGraphQLTests` and `RoutineGraphQLTests` pass (10 total, 0 failures).
- [x] Build, exact changed-file SwiftLint, and diff check pass.
- [x] Progress evidence recorded.

Formal test-integrity/adversarial review and any later review-dependent updates, staging, commit, and push remain with downstream workflow steps.

## Step 6 review test repair

The step6 review repaired the tests: the delegation test now uses `RecordingNextExecutor` to assert that unrelated documents (and handled responses) pass through `next` unchanged, and the payload assertions decode the encoded response payloads. Evidence: `tmp/work-handover/wh-12-graphql-contracts/step6-review/`.

## Step 7 adversarial review self-repair

- Defect: `TaskHandoverGraphQLDocumentExecutor.preflight` demanded `isLocallyTrusted` for every document, so a non-task document (for example `executeWorkflow` from a manager-session bearer request) was rejected as `unauthorized` when the task executor sits in a `CompositeGraphQLDocumentExecutor` fallback chain (wh-16). It also skipped non-task roots with `continue` instead of passing them to `next`'s preflight, bypassing downstream whole-document validation and allowing partial side effects before a later root was rejected.
- Fix: `preflight` now partitions roots like `SessionControlGraphQLDocumentExecutor` and `WorkflowExecutionGraphQLDocumentExecutor`. Trust, provider and operation-type checks apply only to task roots; non-task roots are delegated to `next as? GraphQLDocumentDomainPreflighting` with only those roots, and rejected as `invalid_input` when `next` cannot preflight.
- Tests added to `TaskHandoverGraphQLTests`: `testPreflightDelegatesNonTaskRootsForUntrustedRequests`, `testPreflightDelegatesOnlyNonTaskRootsOfMixedDocumentAndPropagatesRejection`, `testPreflightRejectsUntrustedTaskRootWithoutConsultingNext`, `testPreflightRejectsMixedDocumentWhenNextIsMissingOrNotPreflighting`, `testPreflightRejectsTaskQueryFieldInsideMutationOperation`.
- Verification logs: `tmp/work-handover/wh-12-graphql-contracts/step7-review/{build,focused,swiftlint}.log`.
