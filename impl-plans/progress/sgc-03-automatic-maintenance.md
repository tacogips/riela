# sgc-03 automatic maintenance progress

Implementation is incomplete. The accepted sgc-02 dependency is admitted by
the dispatch, and the plan aligns with design §5. Added the versioned cursor
data model and read-only read / atomic write operations in
`Sources/RielaCLI/StorageMaintenanceCursor.swift`. The file was absent before
the edit; its SHA-256 afterward is recorded in
`tmp/session-storage-gc/sgc-03-automatic-maintenance/cursor-after.sha256`.
Per-edit intent and before evidence are in the same directory.

The conversion queues, lock and budget enforcement, automatic host wiring,
target selection, vacuum budgets, and required tests remain to be implemented.
No per-pass conversion counts or parked-row evidence exist yet. The obsolete
no-config skip test has not yet been replaced.

- `build-attempt-1.log`: `swift build`, exit 0, on the shared moving tree.
- `test-attempt-1.log`: selected suite, exit 1; 42 tests, two assertions fail
  in `testAutomaticHookSkipsMaintenanceWithoutCompletedRetentionPass` because
  sgc-02 now applies default retention. This is an assigned test to replace.
- `lint-attempt-1.log`: strict lint of the cursor file, exit 0.

Formal reviews and integration verification remain downstream. No git state
was changed.

## Continuation 2

Added session resume/rerun/continue target selection by `--scope` in
`AutomaticRetentionHook.swift`; explicit store precedence remains as before.
The resolver deduplicates explicit stores matching a user or project store,
so that case still needs correction. Before and after hashes and the edit
intent are under the evidence directory. The conversion, scheduler, locking,
parking, vacuum budgets and required behavioral tests remain outstanding.
The prior deterministic-failure and retired-row review finding is unresolved.

- `build-attempt-2.log`: arm64 `swift build`, exit 0 on the moving shared tree.
- `test-attempt-2.log`: selected suite, exit 1, 42 tests, 3 assertion
  failures: two in the obsolete assigned no-config test and one in sibling
  `StorageCompactCommandTests.swift:491` (configured versus default).
- `lint-attempt-2.log`: strict lint through `changed-swift-2.nul`, exit 0.

No per-pass conversion counts or parking evidence exist. Formal reviews,
integration reconciliation, staging and commit remain downstream.
