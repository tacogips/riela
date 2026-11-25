# Bots overview: implementation overview and shared contract

**Status**: Ready
**Design Reference**: `design-docs/specs/design-bots-overview.md` (accepted by
step3 in comm-000004), user defaults in `design-docs/user-qa/qa-bots-overview.md`
**Created**: 2026-11-25
**Branch**: `feat/bots-overview`, baseline `7f04f6e6`, `gitPush=false`
**Dispatch manifest**: `impl-plans/active/bots-overview-dispatch.json`

Issue reference: none (no GitHub issue). Scope comes from the workflow input
of `fable-sol-design-and-implement-review-loop-session-1`.

This file is not a dispatchable plan. It holds the rules every plan follows.
Each plan file starts with a JSON block (`planId`, `planPath`, `dependsOn`,
`wave`, `writePaths`, `sharedPaths`, `sharedPathNotes`).

## 1. Plans, slices and waves

| Wave | Plan | Slice | Depends on |
| --- | --- | --- | --- |
| W1 | `bots-01-contracts` | a, b contracts | — |
| W2 | `bots-02-board-projector` | a, d | 01 |
| W2 | `bots-03-activity-core` | b | 01 |
| W2 | `bots-04-acp-adapter` | b | 01 |
| W2 | `bots-05-model-catalog-core` | c | 01 |
| W2 | `bots-06-memory-core` | e | 01 |
| W2 | `bots-07-jobs-core` | f | 01 |
| W2 | `bots-08-pairing-server` | g | 01 |
| W2 | `bots-09-run-linkage` | a | 01 |
| W3 | `bots-10-bot-surfaces` | a, d | 02, 03, 09 |
| W3 | `bots-11-activity-runtime` | b | 03, 09 |
| W4 | `bots-12-activity-surfaces` | b | 10, 11 |
| W5 | `bots-13-model-surfaces` | c | 05, 12 |
| W5 | `bots-14-web-bots` | a, b, d | 12 |
| W6 | `bots-15-memory-surfaces` | e | 06, 13 |
| W7 | `bots-16-jobs-surfaces` | f | 07, 15 |
| W8 | `bots-17-example-docs` | cross | 16 |
| W8 | `bots-18-pairing-surfaces` | g | 08, 16 |
| W9 | `bots-19-remote-surfaces` | g | 18 |
| W10 | `bots-20-web-management` | c, e, f, g | 14, 19 |

Why the surface plans (10, 12, 13, 15, 16, 18, 19) form a chain: they all edit
the same hand-maintained registries (`RielaClientFamilyArguments.swift`,
`CLISurfaceEnumeration.swift`, `rielaCLIHelpText`, `GraphQLSchemaGenerator.swift`,
the generated SDL, `SurfaceCatalog+RowsBots.swift`). One owner per wave avoids
write clashes. Everything that does not need those files runs in W2.

Slice order: the wave order finishes slice a before b surfaces, b before c,
and so on. If the run stops early, the accepted waves are complete slices and
the remaining plans stay in `impl-plans/active/`.

## 2. Rules for every plan

1. Read `design-docs/specs/design-bots-overview.md` sections named in the
   plan before editing. The design wins over this file; this file wins over
   guesses. Do not redesign. A gap that needs a design change is reported in
   the progress log as `BLOCKED: design` with the section number.
2. Edit only the plan's `writePaths` and `sharedPaths`. A path listed as a
   directory means every file inside it; new code for a plan goes into its
   new subdirectory (SwiftPM compiles target subdirectories recursively; no
   `Package.swift` edit is needed or allowed).
3. Do not change `Package.swift`, `Package.resolved`, `VERSION`, anything
   under `.build/`, `Packages/RielaMemory`, or the memory schema version.
4. No worktrees, no branches, no `git stash`, no `git commit`, no push. Work
   in the shared working directory in the foreground.
5. Before each edit of an existing file: read it fresh and record its SHA-256
   (`shasum -a 256 <path>`) and the intended change in
   `tmp/bots-overview/<planId>/edit-intentions.md`. After the edit record the
   new hash. If the pre-edit hash differs from the last hash you recorded for
   that file, another worker changed it: re-read, re-apply only your intended
   change, and note `drift` in the progress log. Never revert someone else's
   lines.
6. A compile error inside a path owned by a sibling plan of the same wave is
   logged as `outOfScope` in the progress log; rerun after the sibling's
   build is green. Never fix it yourself.
7. Scratch files and logs go under `tmp/bots-overview/<planId>/` only.
8. Tests never touch `~/.riela` or the real credential directory. Every test
   creates a temporary directory and passes it as session store root, routine
   store root, memory root, API key root or credential dir.
9. Swift commands are wrapped: `arch -arm64 /bin/zsh -lc '<command>'`. Run
   them in the foreground and keep the full log. Record the exit code.
10. Error codes named in a plan (for example `bot_not_found`) are exact
    strings. They appear in the thrown error's `code` and in CLI stderr.
11. Terminology in user-visible text: "riela memory", "remote", "bot". No
    Orca or T3 Code names anywhere.
12. Progress log: each plan writes `impl-plans/progress/<planId>.md` with
    sections `Implemented`, `Per-edit hashes` (path, pre, post),
    `Verification` (command, exit code, log path, the test count line),
    `Deviations`, `Open items`. A plan is not done until the log exists.

## 3. Shared contracts (pinned by `bots-01-contracts`)

Later plans rely on these exact names. See plan 01 for full shapes.

- `Sources/RielaCore/Bots/`: `BotRecord`, `BotJobSchedule`, `BotStore`,
  `BotStoreError`, `BotStoreSchema`, `BotSessionLink`, `BotRunContext`,
  `BotOrigin`, `ModelSentinel`, `ActivityEvent`, `ActivityEventKind`,
  `ActivityState`, `ActivitySettleReason`, `WorkflowActivityRecording`.
- `Sources/RielaCore/AdapterContracts.swift`: `AdapterActivityUpdate`,
  `AdapterPermissionRequest`, `AdapterPermissionOption`,
  `AdapterPermissionOutcome`, `AdapterPermissionRequestHandler`,
  `AdapterBackendEvent.activity`, `AdapterExecutionContext.permissionRequestHandler`.
- `DeterministicWorkflowRunRequest.botContext`, `.activityRecorder`.
- `RoutineRecord.botId`.
- Session store generation 13 with the eleven tables of design §4.1.
- `SurfaceCatalog.botFamilyRows` in `Sources/RielaCore/SurfaceCatalog+RowsBots.swift`.

Plan-level refinements of the design (no behaviour change):

- The bots GraphQL provider lives in `Sources/RielaCLI/Bots/` (not
  `RielaAppSupport`), next to `WorkflowExecutionProvider.swift`, because it
  must start workflow runs. The executor and DTOs live in
  `Sources/RielaGraphQL/Bots/`.
- Settlement is called at the adapter-call exit inside the runner (the single
  point before every terminal marking) and by the orphan reconcilers.
- ACP replay fixtures are Swift string constants in the test target, because
  `RielaAdaptersTests` declares no resources.
- The memory writer takes a `redact` closure; the CLI passes
  `HandoverRedactionRules.redactText` (RielaCore cannot import RielaWork).
- Design §16 suggests seven plan files, one per slice. The work is split into
  twenty plans under `impl-plans/active/` so that code which does not touch
  the shared registries runs in parallel; each plan names its slice (§1).

## 4. Wave gates (serial reconcile, not per-plan work)

### 4.1 Suite sets

`swift test --filter` takes a regular expression. The sets below are the
exact suite names used by the plans. `S<n>` lists the suites first required
at wave n (new suites created in that wave plus existing regression suites
its plans rely on).

- **S1**: `BotStoreTests|BotStoreMigrationTests|ActivityContractTests|SQLiteRuntimeSchemaMigrationTests|SQLiteRuntimeExecutionRowsTests|WorkflowDefinitionStoreTests|WorkflowDefinitionRetentionTests|SQLiteWorkflowMessageLogTests|RoutineStoreTests|WorkStoreTests|SurfaceCatalogTests`
- **S2**: `BotBoardProjectorTests|BotListProjectionTests|BotListStateStoreTests|ActivityReducerTests|ActivityRecorderTests|ActivityPermissionTests|ActivitySettlementRunnerTests|ActivityWaitTests|DeterministicWorkflowRunnerTests|ActivityNormalizationTests|GatewayScriptedAgentTests|GatewayModelSentinelTests|AgentGatewayACPV2Tests|AgentGatewayNodeAdapterTests|AgentGatewayCancellationTests|BackendWaitSignalClassifierTests|GatewayTurnLifetimeTests|ModelCatalogTests|ProviderStoreTests|WorkflowBackendPolicyWarningTests|WorkflowBackendPolicyTests|BotMemoryWriterTests|BotMemoryMarkdownTests|BotMemoryUndoTests|BotJobDueTests|BotJobLedgerTests|BotSuggestionStoreTests|LookAroundPolicyTests|PairingCodeTests|PairingAddressTests|PairingHTTPTests|APIScopePolicyTests|ServerIdentityTests|RielaAPIKeyStoreTests|DistributedWorkerAPIKeyTests|BotRunLinkageTests|BotRoutineLinkageTests|RoutineCommandTests|RoutineGraphQLTests|WorkflowExecutionGraphQLTests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests`
- **S3**: `BotCommandTests|BotsGraphQLTests|BotActivityRuntimeTests|SessionReconcileCommandTests|SessionAbandonedInvocationTests|TerminalRetentionTests|TerminalRetentionPolicyTests|SurfaceParityCLITests|SurfaceParityExecutorCoverageTests|SurfaceParityWebAPITests|SurfaceParityConsoleReadTests|SurfaceParityLibraryTests`
- **S4**: `BotActivityCommandTests|BotActivityGraphQLTests`
- **S5**: `ModelCatalogCommandTests|ModelCatalogGraphQLTests|ActivityCatalogReportTests`
- **S6**: `BotMemoryCommandTests|BotMemoryInjectionTests|BotMemoryPromptInjectionTests|BotMemoryGraphQLTests`
- **S7**: `BotJobRunnerTests|LookAroundReadOnlyTests|ForcedReadOnlySandboxRunnerTests|BotJobSchedulerTests|BotJobsGraphQLTests`
- **S8**: `BotExampleWalkthroughTests|RielaExampleParityTests|PairingServeTests|PairingScopeEnforcementTests|PairingGraphQLTests`
- **S9**: `RemoteRegistryTests|RemotePairingClientTests|RemoteForwardingTests|RemotesGraphQLTests|GraphQLSelectionBuilderTests`
- **S10**: no Swift suites (web only).

`C<n>` is the cumulative filter of wave n: `S1|S2|...|S<n>` joined with `|`.
`C9` (= `C10`) is therefore the union of every plan's verification filter.
When a plan adds a suite that is not listed here, the reconcile step adds its
name to the `S<n>` of its wave in this file before running the gate.

### 4.2 Gate commands

After each wave n, in the foreground, logs under `tmp/bots-overview/wave-<n>/`:

```
arch -arm64 /bin/zsh -lc 'swift build' > tmp/bots-overview/wave-<n>/build.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "<C<n> written out>"' > tmp/bots-overview/wave-<n>/tests.log 2>&1
```

Both must exit 0.

Cumulative rerun rule: the gate always runs `C<n>`, not only the suites of
the wave's own plans. This is what proves that earlier behaviour survives
later writes to files that several serial plans edit:
`DeterministicWorkflowRunner.swift` (plans 01, 03, 15, 16),
`SQLiteWorkflowActivityRecorder.swift` (03, 13), `WorkflowRunCommand.swift`
(09, 11, 16), `Sources/RielaCLI/Bots` and `Sources/RielaGraphQL/Bots`
(10, 12, 13, 15, 16, 18, 19), `ServeHTTPCommand.swift` and `ServeWebHost.swift`
(10, 16, 18), and the registries. A suite of an earlier wave that fails at a
later gate blocks the wave; the fix belongs to the plan of the current wave
that edited the shared file.

From W3 on, also (the SDL must be stable under regeneration):

```
shasum -a 256 Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift > tmp/bots-overview/wave-<n>/sdl-before.sha
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/wave-<n>/sdl.log 2>&1
shasum -a 256 -c tmp/bots-overview/wave-<n>/sdl-before.sha
```

The check must report `OK` (regenerating changes nothing). The nine parity
suites are already part of `C<n>` from W3 on.

From W5 on (after a web plan), the web gate of §5 is also run.

## 5. Final gate (after W10, or after the last accepted wave n)

Run from the repository root, in the foreground, logs under
`tmp/bots-overview/final/`:

```
mkdir -p tmp/bots-overview/final
arch -arm64 /bin/zsh -lc 'swift build' > tmp/bots-overview/final/build.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "<C<n> written out>"' > tmp/bots-overview/final/tests.log 2>&1
shasum -a 256 Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift > tmp/bots-overview/final/sdl-before.sha
scripts/surface-parity/generate-sdl.sh > tmp/bots-overview/final/sdl.log 2>&1
shasum -a 256 -c tmp/bots-overview/final/sdl-before.sha
bun --version > tmp/bots-overview/final/bun-version.log 2>&1
(cd web && bun install --frozen-lockfile) > tmp/bots-overview/final/web-install.log 2>&1
(cd web && bun run typecheck) > tmp/bots-overview/final/web-typecheck.log 2>&1
(cd web && bun run test) > tmp/bots-overview/final/web-test.log 2>&1
(cd web && bun run build) > tmp/bots-overview/final/web-build.log 2>&1
git status --short web/package.json web/bun.lock
git diff --check
git diff --stat 7f04f6e6 -- Package.swift Package.resolved VERSION
```

Every command exits 0; the two `git` reads at the end and the
`git status` line print nothing.

For the full run (n = 10) the test filter, written out, is:

```
BotStoreTests|BotStoreMigrationTests|ActivityContractTests|SQLiteRuntimeSchemaMigrationTests|SQLiteRuntimeExecutionRowsTests|WorkflowDefinitionStoreTests|WorkflowDefinitionRetentionTests|SQLiteWorkflowMessageLogTests|RoutineStoreTests|WorkStoreTests|SurfaceCatalogTests|BotBoardProjectorTests|BotListProjectionTests|BotListStateStoreTests|ActivityReducerTests|ActivityRecorderTests|ActivityPermissionTests|ActivitySettlementRunnerTests|ActivityWaitTests|DeterministicWorkflowRunnerTests|ActivityNormalizationTests|GatewayScriptedAgentTests|GatewayModelSentinelTests|AgentGatewayACPV2Tests|AgentGatewayNodeAdapterTests|AgentGatewayCancellationTests|BackendWaitSignalClassifierTests|GatewayTurnLifetimeTests|ModelCatalogTests|ProviderStoreTests|WorkflowBackendPolicyWarningTests|WorkflowBackendPolicyTests|BotMemoryWriterTests|BotMemoryMarkdownTests|BotMemoryUndoTests|BotJobDueTests|BotJobLedgerTests|BotSuggestionStoreTests|LookAroundPolicyTests|PairingCodeTests|PairingAddressTests|PairingHTTPTests|APIScopePolicyTests|ServerIdentityTests|RielaAPIKeyStoreTests|DistributedWorkerAPIKeyTests|BotRunLinkageTests|BotRoutineLinkageTests|RoutineCommandTests|RoutineGraphQLTests|WorkflowExecutionGraphQLTests|SurfaceParityGraphQLTests|SurfaceParityDTOSchemaTests|SurfaceParitySkillTests|BotCommandTests|BotsGraphQLTests|BotActivityRuntimeTests|SessionReconcileCommandTests|SessionAbandonedInvocationTests|TerminalRetentionTests|TerminalRetentionPolicyTests|SurfaceParityCLITests|SurfaceParityExecutorCoverageTests|SurfaceParityWebAPITests|SurfaceParityConsoleReadTests|SurfaceParityLibraryTests|BotActivityCommandTests|BotActivityGraphQLTests|ModelCatalogCommandTests|ModelCatalogGraphQLTests|ActivityCatalogReportTests|BotMemoryCommandTests|BotMemoryInjectionTests|BotMemoryPromptInjectionTests|BotMemoryGraphQLTests|BotJobRunnerTests|LookAroundReadOnlyTests|ForcedReadOnlySandboxRunnerTests|BotJobSchedulerTests|BotJobsGraphQLTests|BotExampleWalkthroughTests|RielaExampleParityTests|PairingServeTests|PairingScopeEnforcementTests|PairingGraphQLTests|RemoteRegistryTests|RemotePairingClientTests|RemoteForwardingTests|RemotesGraphQLTests|GraphQLSelectionBuilderTests
```

Web gate notes: `web/node_modules` does not exist in this worktree at
`7f04f6e6`, so `bun install --frozen-lockfile` is a required precondition
(skippable only when `web/node_modules` already exists). `web/node_modules`
and `web/dist` are gitignored build outputs outside every plan's writePaths;
they are untracked writes that need no plan authorisation and no
`artifactRoots` entry. The install must not change `web/bun.lock` or
`web/package.json`. If the install fails for environment reasons the web
gate is reported as `BLOCKED: environment` with the log path; it is never
reported as passed. The web lines are skipped only when no web plan (14, 20)
was accepted.

Also at the final gate: the example mock run from plan 17 with
`--session-store` and `--artifact-root` under `tmp/bots-overview/example/`
(when plan 17 was accepted), and `swiftlint --strict` on touched Swift files
(here, not per plan). The known interleaved-submit timing flake is
unrelated; rerun once before treating it as a failure.

## 6. Completion criteria

- Every plan's done criteria are met and its progress log is written.
- The wave gates and the final gate pass with logs kept under
  `tmp/bots-overview/`.
- Suite presence: `tmp/bots-overview/final/tests.log` shows every suite of
  `C<n>` executed with 0 failures. A suite name of `C<n>` that does not
  appear in the log (not compiled, renamed, filtered out) is a failed gate,
  even when the command exits 0. Check each name with
  `grep -c "<SuiteName>" tmp/bots-overview/final/tests.log` (must be ≥ 1).
  The same rule applies to each wave gate log and `C<n>` of that wave.
- Acceptance criteria of the design (§5–§11, §12–§14) are covered by the
  suites listed in the plans.
- Plans that were not reached stay in `impl-plans/active/` unchanged.


## Operator amendment (after fable-sol session 1)

Accepted baseline: plans 01-14 committed in `73674ceb`. Remaining plans 15-20 run serially with the write scope in each plan header; see each plan's operator amendment. Plan 20 additionally delivers the left-pane Bots layout and task -> run-screen navigation requested by the user.

## Amendment 2026-11-25 (tracking-contract, plan-contract-validate)

`plan-contract-validate` reported `contract_valid: false` for plans 15-19: the roots `Sources/RielaCLI` (414 entries), `Sources/RielaCore`, `Tests` (810 entries) and, for plan 17, `examples` (1152 entries) expand past the limit of 512 source snapshot entries per plan.

- Correction: plans 15, 16, 18 and 19 now hold one common Swift scope: whole `Sources/RielaGraphQL`, `Sources/RielaServer`, `Sources/RielaAdapters`, `Tests/RielaGraphQLTests`, `Tests/RielaServerTests`, `scripts/surface-parity`; the bot-feature subdirectories of `Sources/RielaCLI`, `Sources/RielaCore`, `Tests/RielaCLITests`, `Tests/RielaCoreTests`; and 84 named flat files (about 316 entries). Plan 17 holds its example and documentation paths plus the same scope (about 372 entries). Plan 20 (`web/src`, 117 entries) is unchanged.
- No `artifactRoots`: no plan installs tools, caches or binaries into a tracked path. `.build`, `web/node_modules` and `web/dist` are gitignored and outside every write path.
- Growth budget: at most 40 new files per plan, so the largest plan stays under 512 after waves W1-W5.
- Plan IDs, serial order (15 -> 16 -> 17 -> 18 -> 19 -> 20), tasks, tests, wave gates and the final gate are unchanged. Plans 01-14 stay accepted dependencies (commit `73674ceb`).
- W6-U1-undeclared-redeem-literal stays owned by plan 18; the needed files are in its scope. Until wave W4 the route is served through the split literal in `Sources/RielaServer/RielaPairingHTTP.swift:5`, so `SurfaceParityWebAPITests` is expected green in the W1-W3 gates.
