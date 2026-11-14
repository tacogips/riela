# whu-07 coordinator sync progress

Status: implementation complete; formal reviews and finalization are downstream. Dependency whu-06 was admitted by the operator amendment. The plan aligns with design §§3.1, 3.3 and 3.4 as amended by the project/direct immutability decision below.

Coordinator sync context, intent persistence and replay, import replay, and self-improve/restore integration are present and verified. Per-edit intentions and snapshots are under `tmp/workflow-history-unification/whu-07-coordinator-sync/`.

Former blocker (resolved by the operator amendment): registry ownership was required to expose the actual transaction ID to mutable restore's pre-publication hook.

- [x] Finish coordinator, self-improve and restore integration, including warning rendering.
- [x] Add required failure-injection and behavioral tests, as amended for immutable sources.
- [x] Run required build, focused tests and strict changed-file SwiftLint on the final source.
- [ ] Formal reviews and finalization belong to later workflow steps.

Operator note (2026-11-02, resume #11): fresh dispatch; earlier entries do not count toward any continuation limit. Sources/RielaWorkflowRegistry is now in sharedPaths.

Resume #11: Added the attributed registry pre-publication hook carrying the actual replacement transaction ID, after the prepared recovery record is durable; mutable restore supplies the hook. Restore text renders definition warnings. Split intent ordering into typed steps to resolve a Swift compiler type-check failure. The previous ownership blocker is resolved by the operator amendment.

Earlier status: mutable restore attribution and coordinator test coverage were incomplete; strict lint failed. The aggregate run was interrupted after exposing an immutable-workflow error-order regression, subsequently fixed. Evidence is under `tmp/workflow-history-unification/whu-07-coordinator-sync/`.

Continuation 1: Mutable restore and self-improve persist their actual operation snapshot references through registry publication; fallback registry references are used only when no explicit reference exists. Added intent replay, mutable restore attribution, coordinator publication failure, replay refusal, and pre-publication interruption tests. A lock-safe direct resolver prevents registry/target lock re-entry. Coordinator cleanup preserves typed sync-pending and baseline-failure errors. Build and strict changed-file lint pass; the final focused suite passed 37 tests with zero failures (`tests-final-cont1-3.log`).

At that point remaining coverage included rollback-claim release, import replay, mutable attribution and warnings, and post-database-commit interruption. Formal review and finalization remain downstream.

Continuation 2: Added tests for rollback-claim release, post-database-commit replay, mutable self-improve baseline/attribution, and mutable restore warning output. Build and strict changed-file lint passed; the focused suite passed 40 tests with zero failures (`tests-cont2.log`).

Former blocker: project/direct self-improve and restore conflicted with existing immutable-source assertions; the operator resolved this below.

Operator note (2026-11-02, resume #13): project/direct sources stay immutable (option 1); finish import-replay coverage and final verification in this fresh dispatch.

Resume #13: Added a real definition import replay test, verified that a subsequent coordinator commit replays a pending change before creating its child, and covered mutable self-improve overwrite warning text and clean JSON omission. Focused tests passed 42/42 (`tests-resume13.log`); arm64 build and strict selected-file SwiftLint passed (`build-resume13.log`, `lint-resume13.log`; NUL manifest `changed-swift-resume13.nul`). Logs are under `tmp/workflow-history-unification/whu-07-coordinator-sync/`. Formal integrity, adversarial and integration review, review-dependent documentation, staging and commit remain downstream.

WHU07-TI-01: `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowRegistryDefinitionSyncTests|WorkflowRegistryEvolutionTests|WorkflowMutableRegistryTests|WorkflowEditorDefinitionTests|GraphQLWorkflowRegistryTests"'` exited 0 with 57 tests and 0 failures. The unchanged registry evolution and editor snapshot assertions passed. Complete log: `tmp/workflow-history-unification/whu-07-coordinator-sync/tests-registry-regression.log`; source identity: `tmp/workflow-history-unification/whu-07-coordinator-sync/source-identity-registry-regression.txt` (tracked diff SHA-256 `ae8e864f2ca861c68f7922992d9a92bc52b9c49ff127e2d544ea881ce638a907`). No source or test changes were needed; independent review remains downstream.
