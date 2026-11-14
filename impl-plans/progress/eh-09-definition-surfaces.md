# eh-09-definition-surfaces progress

## Status

Implementation is complete. The self-improvement context builder uses session
listing only to select a prior session ID, then loads the full record before
generating execution evidence. This matches eh-06's header-only list contract;
no runtime persistence files were changed.

## Changes

- `Sources/RielaCLI/WorkflowDefinitionArguments.swift`: parsed undo/redo,
  `--history-retention`, and `--expected-revision`; enforced operation-specific
  options and bounds.
- `Sources/RielaCLI/WorkflowDefinitionCommand.swift`: wired undo/redo, passed
  retention through write operations, surfaced retained-version errors, and
  formatted diff before/after JSON lines.
- `Sources/RielaCLI/WorkflowDefinitionHistoryConfiguration.swift` (new): added
  project/user/default retention resolution and configuration validation.
- `Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift`: added undo/redo
  mutation handling, retention-aware service creation, and retained audit DTO
  projection.
- `Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift` and
  `Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift`:
  resolved configured retention for definition-store writes, including
  self-improvement apply.
- `Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift` and
  `GraphQLSchemaGenerator.swift`: added GraphQL undo/redo inputs and fields,
  history retention inputs, and `retained` on the audit contract.
- `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`: regenerated
  SDL root mutations.
- `Sources/RielaCore/SurfaceCatalog+Rows.swift`: catalogued undo/redo and
  history-retention options; added the eh-07 reconcile option.
- Added CLI, GraphQL, configuration, and workflow-improvement coverage in
  `Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift`,
  `WorkflowDefinitionGraphQLTests.swift`, `WorkflowImprovementNodeTests.swift`,
  and `Tests/RielaGraphQLTests/WorkflowDefinitionGraphQLContractTests.swift`.
- Added `Tests/RielaCoreTests/VersionedHistoryConformanceTests.swift` for
  memory and definition store diff, undo/redo, branch removal, retention, and
  row-count conformance.
- Updated the self-improvement context path in
  `Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift` to
  load the selected prior session by ID before building its digest.
- Extended `testServiceRunsApplyAuditedPromptUpdateAndNextRunUsesIt` to prove
  the persisted list row omits executions while the improvement digest still
  contains the prior summarize execution.

## Verification

Commands and results:

- `arch -arm64 /bin/zsh -lc 'scripts/surface-parity/generate-sdl.sh'` — first attempt exited 1 because `SessionAbandonedInvocationReconciler.swift` changed during the build; rerun exited 0 and its regeneration suite executed 1 test, 0 failures. The generated SDL was regenerated.
- `arch -arm64 /bin/zsh -lc 'swift build'` — exit 0; Build complete (17.03s).
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionCommandTests|WorkflowDefinitionGraphQLTests|WorkflowDefinitionGraphQLContractTests|VersionedHistoryConformanceTests|WorkflowImprovementNodeTests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests"'` — earlier attempt exited 1; 30 tests executed, 1 skipped, 1 failure. The failure in `testServiceRunsApplyAuditedPromptUpdateAndNextRunUsesIt` came from the eh-09 adapter treating an eh-06 header-only list result as a full session.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionCommandTests|WorkflowDefinitionGraphQLTests|WorkflowDefinitionGraphQLContractTests|VersionedHistoryConformanceTests|WorkflowImprovementNodeTests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests"'` — final run exited 0; 30 tests executed, 1 skipped, 0 failures. The skipped test is `SurfaceParityGraphQLTests.testRegenerateGeneratedSDLWhenRequested`, which skips in ordinary test runs because the script above performs SDL regeneration.
- `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowImprovementNodeTests/testServiceRunsApplyAuditedPromptUpdateAndNextRunUsesIt'` — earlier reproduction exited 1; 1 test executed, 1 failure. The session was found from the summary row, but its execution list was intentionally empty until loaded by ID.
- `arch -arm64 /bin/zsh -lc 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/WorkflowDefinitionArguments.swift Sources/RielaCLI/WorkflowDefinitionCommand.swift Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift Sources/RielaCLI/WorkflowDefinitionHistoryConfiguration.swift Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift Sources/RielaCLI/WebWorkflowRequestHandler+Definition.swift Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift Sources/RielaGraphQL/GraphQLSchemaGenerator.swift Sources/RielaCore/SurfaceCatalog+Rows.swift Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift Tests/RielaCLITests/WorkflowDefinitionGraphQLTests.swift Tests/RielaCLITests/WorkflowImprovementNodeTests.swift Tests/RielaGraphQLTests/WorkflowDefinitionGraphQLContractTests.swift Tests/RielaCoreTests/VersionedHistoryConformanceTests.swift'` — exit 0, no diagnostics.
- `git diff --check` — exit 0.

## Independent review repair

### Resolutions

- **F1:** Revision CAS mismatches now throw `staleRevision`; `expectedVersionId`
  still throws `staleHead` and maps to `definition_conflict`. Added CLI and
  GraphQL assertions for both CAS sources.
- **F2:** GraphQL maps closed history errors to documented upper-snake codes:
  `DEFINITION_NOTHING_TO_UNDO`, `DEFINITION_NOTHING_TO_REDO`,
  `DEFINITION_STALE_REVISION`, and `DEFINITION_VERSION_NOT_RETAINED`. Store
  messages now include memory-parity details. Added GraphQL assertions for
  oldest undo, dropped redo, and a dropped version lookup.
- **F3:** Self-improve patch files use `FileManager.default.temporaryDirectory`
  and are removed after use. The run working directory is derived from the
  definition source directory without searching parent directories for config.
  Added assertions that apply leaves no `tmp/efficient-history` under its
  source project and uses the default retention when no project config exists.
- **F4:** Replaced the diff comparison input with the two stored version
  documents, compared redo results, checked precise `nothingToRedo` errors,
  compared row counts against each store's retained-version list, and asserted
  both retained sets after the branch write (`[10,5,4]` in memory and
  `[1,4,5,10]` in definitions). The memory/definition stores still use separate
  setup paths because their version IDs and last-file pin semantics differ;
  the same operations and value expectations are asserted in the shared test.
- **F5:** CLI now performs import plus three updates, checks undo returns the
  prior version and redo restores the original head, verifies retained and
  dropped outcomes plus the precise retained set, and covers write-after-undo
  and both stale CAS forms. GraphQL now asserts returned IDs and closed errors.
- **F6:** Added `revision` to the GraphQL workflow version DTO and schema, and
  populated it for version/head queries and undo/redo payloads. GraphQL rejects
  simultaneous `expectedRevision` and `expectedVersionId`.
- **F7:** CLI history and audit text now report retention; dropped-version
  envelopes include retained IDs and retention generation count. GraphQL error
  extensions carry the same metadata. Store messages include the retention
  setting.
- **F8:** CLI config resolution runs only for writes. Store-backed workflow
  lookup no longer parses retention config; seed and write paths still do.
  GraphQL and self-improve context read services also use the default without
  resolving write config; self-improve apply still resolves it. Added a
  read-under-invalid-config regression.
- **F9:** CLI diff JSON uses sorted keys and does not escape slashes. An absent
  JSON value is rendered as `<absent>` so it differs from a real `null`.
- **F10:** Added default throwing implementations for the two new GraphQL
  provider methods, preserving source compatibility for existing conformers.
  The design doc records the unsupported-provider error behavior.
- **Memory diff parity (eh-08 cross-plan):** `show-version --diff-against`
  text output now includes each `op path`, `before:` and `after:` row. This
  authorized cross-plan edit is confined to `MemoryCommands.swift`.

### Assertion changes and reasons

- `WorkflowDefinitionCommandTests.testUndoRedoRetentionAuditAndTextDiff` now
  uses import plus three updates and replaces the weak `undoVersion !=
  redoVersion` assertion with exact expected IDs. This encodes the contract's
  previous-version and original-head semantics.
- The CLI retention test now checks the dropped-version envelope's retained
  IDs and configured generation count, and checks both `retained == false` and
  the text retention notice.
- `VersionedHistoryConformanceTests` now compares stored definition documents,
  asserts the memory redo result, checks `nothingToRedo` codes, and compares
  retained sets after branching. These replace checks that could pass on an
  unrelated error or compared a table's count to itself.
- The `definition_blobs` to `definition_history_versions` helper table rename
  remains an eh-04 schema alignment; row-count meaning is unchanged.
- No pre-existing assertions were removed or weakened.

### Cross-plan edits and limitations

- `Sources/RielaCore/WorkflowDefinitionStore.swift` contains the authorized
  eh-04 cross-plan stale-revision classification and message/retention details.
- `Sources/RielaCLI/MemoryCommands.swift` contains the authorized eh-08 diff
  text-parity fix. Concurrent memory implementation changes in that file were
  preserved.
- The design document now records GraphQL error-code casing and revision
  exposure. No eh-06 or eh-07 files were edited.
- No unlisted out-of-scope files were changed by this repair.

### Repair verification

- `arch -arm64 /bin/zsh -lc 'scripts/surface-parity/generate-sdl.sh'` — exit
  **0**; regeneration test executed **1**, failed **0**. The generated schema
  now includes the additive version `revision` field.
- `arch -arm64 /bin/zsh -lc 'swift test --scratch-path tmp/efficient-history/eh-09-repair/build --filter "WorkflowDefinitionCommandTests|WorkflowDefinitionGraphQLTests|WorkflowDefinitionGraphQLContractTests|VersionedHistoryConformanceTests|WorkflowImprovementNodeTests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests"'` — exit **0**; **31 tests**, **1 skipped**, **0 failures**. The skip is
  `SurfaceParityGraphQLTests.testRegenerateGeneratedSDLWhenRequested`, which
  runs only through the SDL script.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/WorkflowDefinitionArguments.swift Sources/RielaCLI/WorkflowDefinitionCommand.swift Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift Sources/RielaCLI/WorkflowDefinitionHistoryConfiguration.swift Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift Sources/RielaCLI/WebWorkflowRequestHandler+Definition.swift Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift Sources/RielaGraphQL/GraphQLSchemaGenerator.swift Sources/RielaCore/SurfaceCatalog+Rows.swift Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift Tests/RielaCLITests/WorkflowDefinitionGraphQLTests.swift Tests/RielaCLITests/WorkflowImprovementNodeTests.swift Tests/RielaGraphQLTests/WorkflowDefinitionGraphQLContractTests.swift Tests/RielaCoreTests/VersionedHistoryConformanceTests.swift` — exit **0**, no diagnostics. Generated SDL was excluded.
- `git diff --check` — exit **0**.

An earlier focused run failed on assertions that assumed the wrong GraphQL
undo sequence and on initial retained-set expectations; those tests were
corrected to match the actual version clock and then passed in the final run.
The first default `.build` verification was blocked by a stale lock referring
to an exited PID. A later isolated build attempt hit an in-progress eh-06
switch change in `CLIWorkflowSessionResolution.swift`; after that concurrent
edit settled, the successful final run used the task-local scratch path shown
above. No concurrent eh-06/eh-07 files were edited.

The first focused run after the repair exited 1 on a compile error in the new
selection closure (list rows expose session fields through `.session`). The
closure was corrected before the passing final run. The SDL script's first
attempt failed on the concurrent input-file modification noted above and
passed when rerun.

The earlier full focused-filter failures recorded above came from the initial
eh-09 bug and a corrected closure compile error. The final focused run passed.

## Deviations and risks

### Assertion changes and reasons

- In `WorkflowImprovementNodeTests`, the original digest assertion was split
  into a named expected execution ID plus a diagnostic message; its condition
  remains the same. An additional explicit assertion checks
  `summarize-attempt-1-exec-1`, and a new assertion confirms that the selected
  list row is header-only. These make the regression and its contract precise.
- The existing retention row-count helper changed its first table name from
  `definition_blobs` to `definition_history_versions` to track eh-04's schema
  table rename. The counts and invariant being asserted are unchanged.
- No pre-existing test assertion was weakened or removed.

### Source audit

- `ProductionNodeAdapter+WorkflowImprovementAddon.swift` was the only source
  caller found that selected a session from `CLIWorkflowSessionStore.list`
  and then read execution details. It now reloads the full record by ID.
- `SessionDiscoveryCommand.swift` consumes list rows only to render summary
  fields; it does not read step or execution data. No other list-result
  execution consumers were found in `Sources/`, so there are no out-of-scope
  caller follow-ups.

- The conformance test expects the definition store to retain its protected
  last-file version in addition to the configured recent window; this follows
  the store's file-pin invariant. The memory store retains only the window.
- `SurfaceParityCLITests` was not run because the plan defers CLI command
  enumeration parity to eh-11.
- Out-of-scope edits by this repair: none. Concurrent unrelated memory CLI
  changes in the shared worktree were left untouched.
- The reviewer request included no separately enumerated L1–L4 items; the
  supplied actionable finding was the session-list/full-load defect above.

## Follow-up reviewer repairs (N1–N4)

### Resolutions

- **N1 (Medium):** The improvement adapter now receives the actual run
  `WorkflowResolutionOptions.workingDirectory` and uses it for both retention
  config resolution and the subprocess `--working-dir`. The regression uses
  the standard `<project>/.riela/workflows/<name>` layout with retention 2,
  verifies the configured window drops the two oldest non-file versions, and
  verifies no `tmp/efficient-history` directory is newly created under HOME
  or the current directory.
- **N2 (Low):** Store head moves now return their committed revision from
  inside the transaction. `WorkflowDefinitionService` carries that value in
  `WorkflowDefinitionHeadMoveResult`; the GraphQL mutation uses it directly
  instead of rereading the current head. A provider hook injects a competing
  write after the move and the regression verifies the payload revision stays
  at the move's revision while the store head advances.
- **N3 (Low):** The definition conformance test gets retained version IDs
  from retained store history records and maps those IDs to history numbers;
  its row-count comparison is now independent of the retained-row count
  query. Both adapters normalize and sort their retained windows, remove the
  definition file-version pin where present, and assert the shared literal
  `[4, 5, 10]`.
- **N4 (Low):** Memory text mode is explicitly selected and asserts the exact
  added object row with `<absent>`, sorted object keys, and unescaped slashes.
  Definition text diff now has an added runtime node and asserts the exact
  sorted object row and absence of escaped slashes.
- **F1–F10:** The earlier independent-review resolutions remain in place and
  their regression coverage passed in the final focused run.
- **L1–L4:** The supplied review excerpt had no separate L1–L4 descriptions.
  N2–N4 cover its listed low-severity follow-ups. The design document now
  records the head-move revision snapshot contract, including the concurrent
  writer case, as requested for the L4 documentation follow-up.

### Assertion changes and reasons

- `WorkflowImprovementNodeTests.testProjectHistoryRetentionConfigAppliesToSelfImprovementWrite`
  now uses the standard project workflow layout and project-scope resolution;
  this replaces the non-standard fixture path that could not expose N1.
  Existing retention assertions remain, with additional HOME/current-directory
  temp-path assertions.
- `VersionedHistoryConformanceTests` replaces the definition side's
  table-derived retained list with retained store history records and replaces
  adapter-specific expected arrays with one normalized `[4, 5, 10]` check.
  These changes remove the tautological count/list source and shared-expectation
  gap called out by N3.
- `MemoryHistoryCommandTests` changes the added payload value from a boolean to
  an object with deliberately unsorted keys and a URL. Existing JSON diff
  shape assertions remain; new text assertions pin key sorting and slash
  escaping without weakening earlier conditions.
- `WorkflowDefinitionGraphQLTests` adds the injected competing-write scenario
  and asserts both the payload's move revision and the later store revision.
- `WorkflowDefinitionServiceTests` replaces tuple-index audit assertions with
  named `audit` fields (same conditions) and adds exact revision assertions.
- `WorkflowDefinitionCommandTests` adds a version with an added object node
  and pins the exact text diff row. It adds no weakened or removed assertions.
- No pre-existing test assertion was removed or weakened.

### Out-of-scope edits required for propagation

- `Sources/RielaCLI/WorkflowRunCommand.swift` passes the resolved run working
  directory into the addon context; `Sources/RielaCLI/SessionCommands.swift`
  passes the active working directory for resume and rerun contexts. These are
  necessary propagation call sites outside eh-09's `writePaths`.
- `Sources/RielaCore/WorkflowDefinitionStore.swift` adds the revision-bearing
  move API, and `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift`
  carries it through as a named result. These are required lower-layer API
  changes for N2 and are outside eh-09's `writePaths`.
- `Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift` was updated for
  the named head-move result and revision assertions. It is outside eh-09's
  `writePaths`.
- `Tests/RielaCLITests/MemoryHistoryCommandTests.swift` is outside eh-09's
  `writePaths`, but N4 explicitly requires its memory text regression. The
  concurrent `Sources/RielaCLI/MemoryCommands.swift` implementation was not
  touched.
- No other out-of-scope files were edited for this repair. Concurrent memory
  CLI and eh-10 storage changes were left untouched.

### Repair verification

- `arch -arm64 /bin/zsh -lc 'swift test --scratch-path tmp/efficient-history/eh-09-review-fix/build --filter "WorkflowDefinitionCommandTests|WorkflowDefinitionGraphQLTests|WorkflowDefinitionGraphQLContractTests|WorkflowDefinitionServiceTests|VersionedHistoryConformanceTests|WorkflowImprovementNodeTests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests|MemoryHistoryCommandTests"'` — exit **0**; **51 tests**, **1 skipped**, **0 failures**. The skip is `SurfaceParityGraphQLTests.testRegenerateGeneratedSDLWhenRequested`, which is exercised by the SDL script.
- `arch -arm64 /bin/zsh -lc 'scripts/surface-parity/generate-sdl.sh'` — exit **0**; regeneration suite **1 test**, **0 failures**; generated SDL refreshed.
- `arch -arm64 /bin/zsh -lc 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/WorkflowDefinitionArguments.swift Sources/RielaCLI/WorkflowDefinitionCommand.swift Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift Sources/RielaCLI/WorkflowDefinitionHistoryConfiguration.swift Sources/RielaCLI/DefinitionStoreWorkflowBundleResolver.swift Sources/RielaCLI/WebWorkflowRequestHandler+Definition.swift Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift Sources/RielaCLI/WorkflowRunCommand.swift Sources/RielaCLI/SessionCommands.swift Sources/RielaCore/WorkflowDefinitionStore.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift Sources/RielaGraphQL/WorkflowDefinitionGraphQL.swift Sources/RielaGraphQL/GraphQLSchemaGenerator.swift Sources/RielaCore/SurfaceCatalog+Rows.swift Tests/RielaCLITests/WorkflowDefinitionCommandTests.swift Tests/RielaCLITests/WorkflowDefinitionGraphQLTests.swift Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift Tests/RielaCLITests/WorkflowImprovementNodeTests.swift Tests/RielaCLITests/MemoryHistoryCommandTests.swift Tests/RielaGraphQLTests/WorkflowDefinitionGraphQLContractTests.swift Tests/RielaCoreTests/VersionedHistoryConformanceTests.swift'` — exit **0**, no diagnostics.
- `git diff --check` — exit **0**.

The first follow-up test attempts found tuple-destructuring and fixture/expected
output mistakes in the new code and tests. Those were corrected; the final
verification above is green. The required `tmp/` task directory was created
under the repository root and scratch outputs remain there.
