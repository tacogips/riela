# Workflow history unification: implementation plan index

**Status**: Ready
**Design Reference**: design-docs/specs/design-workflow-history-unification.md
(accepted by step3, comm-012342), decisions in
design-docs/user-qa/qa-workflow-history-unification.md. The user accepted
Q1-Q6, and Q7 (bounded storage) is binding.
**Branch**: `feat/workflow-history-unification` (off main `28ce6a28`).
`gitPush=false`: commit locally only.
**Created**: 2026-11-02

## User intent

Make workflow self-improvement history and rollback complete and unified:

- **(A)** Every file change becomes a definition-store version or audit
  row with actor, reason, evidence and diff. This covers registry
  create/update/delete, `workflow restore` and `workflow self-improve`.
- **(B)** Bundle snapshots become the file-restore auxiliary, with
  `parentSnapshotId`, a unified content diff and GraphQL
  `workflowVersions` / `workflowVersionDiff` / `restoreWorkflowVersion`
  (dry run by default).
- **(C)** A regression verdict produces a rollback proposal. Policy is
  manual, approval-required or automatic. Approve and reject are available
  on CLI and GraphQL, and every rollback is audited.
- **Web.** A history and rollback screen in the web console.
- **Catalog.** SurfaceCatalog parity rows and a regenerated SDL.
- **Q7.** Storage stays bounded.

## Plans and waves (dependency DAG)

| Wave | Plan | Depends on | Slice |
| --- | --- | --- | --- |
| W1 | [whu-01-store-core](workflow-history-unification-01-store-core.md) | - | RielaCore: new enum cases, generation 13 proposal table, proposal store, head guard and rollback claim in `commit`, completion predicate, audit-only collapse, proposal retention, `loop.regressionRollback` model and validation |
| W1 | [whu-02-snapshot-service](workflow-history-unification-02-snapshot-service.md) | - | B: `parentSnapshotId`, unified content diff, `WorkflowSnapshotRestoreService` extraction, `--content` / `--reason` |
| W1 | [whu-03-graphql-contract](workflow-history-unification-03-graphql-contract.md) | - | RielaGraphQL DTOs, protocol methods with unsupported defaults, dispatch and generator rows for the 7 new GraphQL operations |
| W1 | [whu-04-web-history-screen](workflow-history-unification-04-web-history-screen.md) | - | web/src `versions` tab, GraphQL history client and view |
| W2 | [whu-05-definition-sync](workflow-history-unification-05-definition-sync.md) | whu-01 | Shared store-root resolution, `WorkflowDefinitionChangeRecording`, baseline capture, intent preparation, sync |
| W3 | [whu-06-registry-sync](workflow-history-unification-06-registry-sync.md) | whu-05 | WorkflowMutableRegistry baseline, attribution, `finish` sync, delete audit, recovery, GraphQL host wiring |
| W3 | [whu-07-coordinator-sync](workflow-history-unification-07-coordinator-sync.md) | whu-02, whu-05 | Coordinator locked callbacks, durable intents and replay, self-improve and restore attribution, import replay |
| W4 | [whu-08-rollback-service](workflow-history-unification-08-rollback-service.md) | whu-01, whu-06, whu-07 | Regression evaluation, proposal creation, store-mode and bundle-mode apply, recovery, post-run hook, Q7 one-time-run regression test |
| W4 | [whu-09-versions-graphql](workflow-history-unification-09-versions-graphql.md) | whu-02, whu-03, whu-07 | Provider implementation of `workflowVersions`, `workflowVersionDiff` and `restoreWorkflowVersion` |
| W5 | [whu-10-rollback-surfaces](workflow-history-unification-10-rollback-surfaces.md) | whu-03, whu-08, whu-09 | CLI `workflow definition rollback check/list/approve/reject` plus the GraphQL rollback provider |
| W6 | [whu-11-catalog-sdl-docs](workflow-history-unification-11-catalog-sdl-docs.md) | all | SurfaceCatalog rows, SDL regeneration, help text, docs, final gates |

whu-10 depends on whu-09 only because both edit
`Sources/RielaCLI/WorkflowDefinitionGraphQLProvider.swift`, which must be
serialized.

Parallel members of each wave have disjoint `writePaths`, as checked in
`workflow-history-unification-dispatch.json`.

## Execution protocol (applies to every plan)

1. **Reads and baselines.** Read every owned file fresh before each edit.
   Record its `shasum -a 256` before and after the edit in the plan's own
   progress log, `impl-plans/progress/<planId>.md`, which is the only
   progress file a worker writes.
2. **Intent snapshot.** Before the first edit, record a one-paragraph
   intent snapshot (what changes, which symbols).
3. **Drift.** If an owned file's hash differs from the last hash this
   worker recorded, a sibling or a reconcile step changed it. Stop editing
   that file, log `drift <path> <expected> <actual>`, re-read it, and
   re-apply only the intended delta.
4. **Write scope.** Never edit a path outside the plan's `writePaths`.
   - A compile error inside a sibling's `writePaths` is logged as
     `outOfScope <path> <first error>`. Rerun the command after the sibling
     reports a green build. Never fix it as a non-owner.
5. **No VCS or environment operations.** No git commits, branches,
   worktrees, stash, formatting of foreign files, lockfile changes or
   `Package.swift` edits.
6. **Shell rules.** Scratch files and command logs live only under
   `tmp/workflow-history-unification/<planId>/`. Run every command in the
   foreground. Swift commands always run as `arch -arm64 /bin/zsh -lc '...'`;
   writing under `.build` is allowed. Record each command's exit status and
   the log path in the progress log.
7. **Test isolation.** Tests never touch the real `~/.riela`.
   - Use realpath temporary roots, plus either an explicit
     `RIELA_SESSION_STORE` / store root or the existing
     `environment: ["HOME": <temp>]` pattern
     (`Tests/RielaCLITests/WorkflowMutableRegistryTests.swift:734`).
   - The production recorder resolves roots through
     `CLIRuntimeEnvironment.mergedProcessEnvironment()`, so HOME
     overrides isolate it.
8. **Progress log.** The log ends with a `Done criteria` checklist, each
   item ticked with its evidence (log path and exit status).

## Wave gates (serial reconcile, foreground, logs under `tmp/workflow-history-unification/wave-<n>/`)

- **After every wave:** `arch -arm64 /bin/zsh -lc 'swift build'` exits 0,
  and the union of the wave members' focused filters exits 0.
  - `SurfaceParity*` suites are excluded until W6, because SDL and catalog
    rows land in whu-11.
  - W1 also runs `cd web && bun run lint && bun run typecheck && bun test
    src && bun run build`, which must exit 0.
- **W6 (final):**
  - `swift build`;
  - the design §9 focused filter:
    `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinition|WorkflowVersionCommands|WorkflowRegistryEvolution|SelfImprove|LoopBaseline|LoopRegression|SurfaceCatalog|SurfaceParity|WorkflowRollback|WorkflowHistory|WorkflowCoordinatorDefinitionSync|WorkflowRegistryDefinitionSync|WorkflowVersionContentDiff|WorkflowVersionsGraphQL"'`;
  - `scripts/surface-parity/generate-sdl.sh`, whose second run leaves
    `git diff --stat Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`
    empty;
  - the web gates;
  - `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet <touched swift files>'`;
  - `git diff --check`;
  - `git diff --stat 28ce6a28 -- Package.swift Package.resolved VERSION Packages/RielaMemory`
    is empty, which shows no memory schema bump and no manifest changes.

## Completion criteria

- Every plan's done criteria are ticked with evidence in its progress log.
- The W6 gates are green, with logs recorded in
  `impl-plans/progress/whu-11-catalog-sdl-docs.md`.
- The design §9 test list is covered. whu-11 maps each §9 bullet to the
  test method that covers it, in its progress log.
