# Control-Surface Parity Implementation Plan

**Status**: Ready for implementation
**Workflow Mode**: feature
**Feature Fanout**: false — one catalog, one gate, one work package
**Design Reference**: `design-docs/specs/design-control-surface-parity.md`
(sections 1–4 accepted 2026-09-20; section 5 accepted deltas D1–D8,
2026-09-21 — read both before implementing)
**Related**: `impl-plans/active/work-runtime-p0-model-and-store.md` (its
`riela task` / `riela intent` operations enter the catalog only as `blocked`
rows citing that plan — delta D6), Monja `impl-plans/active/47-surface-parity.md`
**Created**: 2026-09-20
**Last Updated**: 2026-09-21

## Task Checklist

Check a box only with a matching evidence entry in the progress log.

- [ ] CSP-1 Catalog
- [ ] CSP-2 CLI and skills gates
- [ ] CSP-3 GraphQL gate and generated SDL
- [ ] CSP-4 Web API and library gates
- [ ] CSP-5 Session mutations on GraphQL
- [ ] CSP-6 Console reads to GraphQL
- [ ] CSP-7 Library facade and skills
- [ ] CSP-8 Integrated verification

## Accepted Design And Review

- Source of truth: `design-docs/specs/design-control-surface-parity.md`,
  including the section 5 deltas. Do not diverge silently; new deltas go to
  the design doc and this progress log.
- The gate lands first and is expected to fail on the current tree with the
  gaps in design section 1. Closing gaps is the second half.
- Auto-improve surfaces are not filled; they are `excluded` because the Work
  Runtime design deletes them.
- NO backward compatibility anywhere: replaced surfaces are deleted outright
  (no aliases, deprecation windows, legacy imports, migrations, or tolerant
  decoding).

## Applicable prior knowledge (operator-verified; apply, do not rediscover)

- **arm64 shell**: every Swift command must run as
  `arch -arm64 /bin/zsh -lc '…'`; the default agent shell is Rosetta and the
  xctest bundle refuses to dlopen there.
- **Known flake**: the interleaved-submit timing flake is the only tolerated
  full-suite failure; identify it by an isolated rerun (the literal string
  "interleaved" does not appear under `Tests/`), rerun it to green, and
  record both runs as evidence.
- **Scratch discipline** (`AGENTS.md`): throwaway artifacts only under
  gitignored `tmp/<task>/`; `scripts/` is for committed reusable tooling
  only; never commit scratch files.
- **Re-read before authoring**: quotes from prior exploration can be stale
  or fabricated; re-read any syntax-critical file (SDL literal, command
  enums, skill markdown) directly before writing code against it.
- **Git discipline for this run**: implementation branch equals base branch
  `feat/control-surface-parity` (HEAD `ca1ce34`, remote
  `origin=https://github.com/tacogips/riela.git`, no upstream yet — first
  push is `git push -u origin feat/control-surface-parity`). Never touch
  `main`, never force-push, work only in this worktree. The `riela-packages`
  checkout and `~/.claude/skills` are read-only seed material.

## Verified seam facts (tree at `ca1ce34`)

- CLI tree: hand-rolled `RielaCommand` /
  `*CommandKind` enums with untyped `CLICommandOptions.arguments`
  (`Sources/RielaCLI/RielaCommand.swift`; `ScopedCommandKind` at line ~233);
  `swift-argument-parser` 1.8.2 is linked for nested actions.
- GraphQL: control-plane SDL literal `schemaContract` in
  `GraphQLContractProjector+Schema.swift` (lines 2–348; `workflowInstances`
  line 303, `continueSession` line 324; no `opsOverview`, no
  rerun/resume/stop). Exactly 27 `GraphQL*DTO` structs (17 in
  `GraphQLContracts.swift`, 9 in `GraphQLLoopAnalyticsContracts.swift`, 1 in
  `GraphQLSessionObservabilityContracts.swift`). Two further SDL literals:
  `workflowRegistryGraphQLSchemaTypes`, `routineGraphQLSchemaTypes`
  (`RoutineGraphQL.swift:423`).
- GraphQL entry points: `riela graphql` →
  `ScopedParityCommands+GraphQLDocument.swift:28`; `riela serve` →
  `ServeWebHost.swift` `/graphql` (line ~126) → `ServeWebRegistryExecutor` →
  `DeterministicServerRouteHandler`; desktop → `RielaAppWebGraphQL.swift`
  composite (registry → routine → config only); desktop router
  `RielaAppWebRouter.swift:39-52`; server contract exposure
  `RielaServer/ServerContracts.swift:233`.
- `continueSession`: protocol `GraphQLContracts.swift:681`, resolver in
  `Sources/RielaCLI/ParityCommandSupport.swift`; request DTOs carry
  `managerSessionId` (`GraphQLContracts.swift:397-514`).
- Session runners: `SessionRerunCommand` (`SessionCommands.swift:381`),
  `SessionResumeCommand` (`SessionCommands.swift:641`), both public. No CLI
  stop command; cancellation finalization hardened in commit `43edf93`
  (`DeterministicWorkflowRunner+Cancellation.swift`, regression in
  `WorkflowCommandAutoImproveTests.swift`).
- Web API: `RielaWebAPIProjection.swift` serves `/api/v1/bootstrap` (:53),
  `/api/v1/instances` (:64), `/api/v1/ops/overview`,
  `/api/v1/workflows/sources` for both serve and desktop host kinds;
  instance actions/creation in `ServeWebHost+Instances.swift` /
  `+InstanceCreation.swift` and `RielaApp/RielaAppInstanceAPI.swift`;
  passkey auth under `/api/v1/auth/`; editor via `webWorkflowRuntime`
  handler; worker settings via `RielaAppWorkerSettingsAPI.swift`.
- Web client: `transport.ts` allows only `/api/v1/*` and `/graphql`; GraphQL
  clients exist (`web/src/workflows/client.ts:136`,
  `web/src/config/client.ts:173`). Instance/overview consumers:
  `views/InstancesView.tsx` (:97, :177), `ops/OpsRunView.tsx`,
  `ops/OpsWorkflowsView.tsx`, `views/WorkflowsView.tsx`,
  `views/RunDetailView.tsx`, `views/LogsView.tsx`,
  `views/WorkflowRunConfigurationsView.tsx`, `transport.test.ts`.
- Library: the only public entry point today is the remote-endpoint
  `executeWorkflow` (`WorkflowCommands.swift:380`).
- Skills: `Resources/` holds only `RielaInfo.plist`; no `Resources/skills`
  anywhere in history; stale flags `--supervisor-workflow` /
  `--no-allow-targeted-rerun` exist only in the external registry copies and
  are absent from `ParsedWorkflowOptions.swift`.
- Enumeration-test precedent:
  `Tests/RielaCoreTests/RielaTestSurfaceCoverageTests.swift`.
- Stale record to delete:
  `impl-plans/progress/plans/graphql-supervision-execution-parity.json`.

## Scope

### Included

- `SurfaceCatalog` types and data in `RielaCore` with one row per current
  CLI command, GraphQL field, web route, library entry point, and skill
  command block, states matching design section 1 plus deltas D1/D6.
- Five gate tests (CLI, GraphQL, web API, library, skills) plus the negative
  CLI-gate test.
- Generated control-plane SDL from DTOs plus catalog; freshness test;
  one-parser proof (delta D2).
- Console reads for instances and overview moved to GraphQL; the replaced
  JSON routes deleted; surviving web routes cataloged with reasons (deltas
  D7/D8).
- Session rerun, resume, stop on GraphQL (delta D3).
- `RielaLibrary` facade, `Resources/skills` canonical skill set (delta D1),
  and catalog-generated skill command blocks.

### Excluded

- Any Work Runtime behavior; only `blocked` catalog rows for its commands.
- New GraphQL coverage for package, node, setup, doctor, gc, worker, memory
  (declared `excluded`).
- Changes to manager-session authentication.
- Registry (`riela-packages`) propagation of the rewritten skills —
  operator follow-up.
- Playwright and desktop debug-build launch (optional evidence, delta D5).

## Task Breakdown

| Task | Deliverables | Primary write scope | Dependencies | Parallelizable |
| --- | --- | --- | --- | --- |
| CSP-1 Catalog | `SurfaceOperation`, `SurfaceAvailability`, `SurfaceCatalog.all`; rows for every current operation; uniqueness tests | `Sources/RielaCore/SurfaceCatalog.swift`, `Sources/RielaCore/SurfaceCatalog+Rows.swift`, `Tests/RielaCoreTests/SurfaceCatalogTests.swift` | none | No |
| CSP-2 CLI and skills gates | Command-tree enumerator over `RielaCommand` and `*CommandKind`; option-name extractor; Swift skill token scanner with allowlist (D4); bijection tests; negative dummy-command test | `Tests/RielaCLITests/SurfaceParityCLITests.swift`, `Tests/RielaCLITests/SurfaceParitySkillTests.swift`, gate helpers in `Sources/RielaCLI` if enumeration needs production seams | CSP-1 | Yes with CSP-3, CSP-4 |
| CSP-3 GraphQL gate and generated SDL | Schema field enumerator over all three SDL sources; SDL generator from DTOs + catalog; checked-in generated `schemaContract` with freshness test; single-parser assertion | `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift`, `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` (becomes generated), `scripts/surface-parity/generate-sdl.sh` (+ tool target if needed), `Tests/RielaGraphQLTests/SurfaceParityGraphQLTests.swift`, `Tests/RielaGraphQLTests/SingleParserTests.swift` | CSP-1 | Yes with CSP-2, CSP-4 |
| CSP-4 Web API and library gates | Declared route tables (D7) for `ServeWebHost` (+ instance extensions), `RielaWebAPIProjection`, `RielaAppWebRouter`, editor/worker/auth surfaces; library facade listing via `#filePath` (D4); bijection tests | `Tests/RielaCLITests/SurfaceParityWebAPITests.swift`, `Tests/RielaCLITests/SurfaceParityLibraryTests.swift`, route-table declarations in the owning sources | CSP-1 | Yes with CSP-2, CSP-3 |
| CSP-5 Session mutations on GraphQL | `rerunSession`, `resumeSession`, `stopSession` mutations reusing `SessionRerunCommand`, `SessionResumeCommand`, and the `43edf93` cancellation path (D3); DTOs; catalog rows flipped | `Sources/RielaGraphQL/GraphQLContracts.swift`, `Sources/RielaGraphQL/RielaGraphQL.swift`, `Sources/RielaGraphQL/GraphQLSessionObservabilityContracts.swift`, `Sources/RielaCLI/ParityCommandSupport.swift`, `Tests/RielaGraphQLTests/SessionMutationTests.swift`, `Tests/RielaCLITests` parity test | CSP-3 | No |
| CSP-6 Console reads to GraphQL | Shared instance/ops GraphQL seam in `RielaAppSupport` wired into serve and desktop composites (D8); new `opsOverview` query + DTO; web and desktop reads via GraphQL; `/api/v1/instances` and ops-overview instance routes deleted; surviving routes cataloged | `Sources/RielaAppSupport/RielaWebAPIProjection.swift` (+ new provider file), `Sources/RielaCLI/ServeWebHost*.swift`, `Sources/RielaApp/RielaAppWebGraphQL.swift`, `Sources/RielaApp/RielaAppInstanceAPI.swift`, `web/src/*`, web tests | CSP-4, CSP-5 | No |
| CSP-7 Library facade and skills | `RielaLibrary.swift` facade; `Resources/skills/riela-workflow-reference` rewritten; `Resources/skills/riela-workflow-run` with generated command block (D1); stale progress record deleted | `Sources/RielaCLI/RielaLibrary.swift`, `Resources/skills/*`, delete `impl-plans/progress/plans/graphql-supervision-execution-parity.json` | CSP-2, CSP-4 | No |
| CSP-8 Integrated verification | Full arm64 build/test, SwiftLint on changed sources, web suite, checklist + progress-log evidence, push | tests and this plan | CSP-1..7 | No |

## Task Details

### CSP-1 Catalog

**Deliverables**: the types from design 2.1; rows for every command in the
`RielaCommand` tree, every Query/Mutation field across all three SDL
sources, every `/api/v1` route the routing owners serve, the current
library entry point, and every command block in the canonical skills;
`blocked` rows (session mutations until CSP-5, console GraphQL reads until
CSP-6, library facade until CSP-7, `riela task` / `riela intent` per D6)
and `excluded` rows per design 2.6 with evidence and reasons; uniqueness
tests over ids, CLI paths, GraphQL fields, and web paths.

**Completion evidence**: catalog tests green
(`swift test --filter SurfaceCatalog`); a review of the rows against design
section 1 recorded in the progress log.

### CSP-2 CLI and skills gates

**Deliverables**: enumerator that walks `RielaCommand` and each
`*CommandKind`, producing command paths and option names; the gate compares
enumeration to catalog `cli` bindings as a pure function
`verify(commands:catalog:) -> [violation]` so the negative test can inject a
dummy command descriptor without a production seam; Swift skill scanner (D4)
that extracts `riela …` command lines and `--flag` tokens from
`Resources/skills/**/SKILL.md` and `references/*.md` via `#filePath` root
resolution, with an explicit allowlist for prose tokens and a denylist entry
asserting `riela-auto-improve` is absent (D1).

**Completion evidence**: bijection tests green after CSP-7; the negative
dummy-command test proves the CLI gate fails on an unregistered command; the
skill gate demonstrably rejects a stale token (unit case using
`--supervisor-workflow`).

### CSP-3 GraphQL gate and generated SDL

**Deliverables**: generator emitting `schemaContract` from the 27 DTO types
plus the catalog's `graphql` bindings (D2); the literal file becomes
generated output with a header naming the generator and
`scripts/surface-parity/generate-sdl.sh` as the regeneration entry point;
freshness test asserts generator output is byte-identical to the checked-in
literal and, on failure, writes the regenerated SDL under
`tmp/surface-parity/` and prints the path; gate enumerates Query/Mutation
fields from `schemaContract` + registry + routine literals and asserts
bijection with catalog `graphql` bindings; single-parser test asserts the
parser type reported by each entry-point assembly (`riela graphql`, serve,
desktop composite, desktop router) is one shared type — expose a parser
identity from the shared parsing path if needed. If a second parser is
found, add a removal task to this plan before CSP-8.

**Completion evidence**: freshness test green; existing GraphQL tests
unchanged and green; single-parser test green.

### CSP-4 Web API and library gates

**Deliverables**: declared route tables (D7) for every routing owner listed
in the seam facts; web gate asserts bijection between declared tables and
catalog `webAPI` bindings, plus spot request tests that at least the
bootstrap and one auth route dispatch as declared; library gate reads the
designated facade file via `#filePath`, extracts `public func` names, and
asserts bijection with catalog `library` bindings.

**Completion evidence**: on the unfixed tree the web gate flags the
instances/overview rows as `blocked` until CSP-6 flips them; the library
gate fails until CSP-7 defines the facade; both green at CSP-8.

### CSP-5 Session mutations on GraphQL

**Deliverables**: three mutations following the `continueSession` layering —
DTOs and SDL in `RielaGraphQL`, resolvers beside `continueSession` in
`ParityCommandSupport.swift` reusing `SessionRerunCommand`,
`SessionResumeCommand`, and for stop the in-process cancellation that
persists terminal state before acknowledging (D3; typed
`session_not_running` error otherwise); manager-session authentication
identical to `continueSession`; catalog rows flipped to `implemented`.

**Completion evidence**: mutation tests against a fixture session store;
parity test that CLI and GraphQL rerun/resume produce identical session
lineage records; stop test asserting persisted cancelled terminal state.

### CSP-6 Console reads to GraphQL

**Deliverables**: shared instance/ops GraphQL execution seam in
`RielaAppSupport` consumed by both `ServeWebHost` and the desktop composite
(D8 — verify the current wiring first and follow the existing provider
pattern in `RielaGraphQL.swift:349`); new `opsOverview` query whose DTO
mirrors what the ops views consume today; web instance list, detail, and
overview reads through the existing GraphQL client; `/api/v1/instances` and
the instance parts of `/api/v1/ops/overview` deleted outright; remaining
`/api/v1` routes cataloged `excluded` with reasons (auth handshake, byte
transfer, editor file operations, worker credentials, bootstrap handshake).

**Completion evidence**: `bun run typecheck`, `bun run lint`,
`bun test src` green; web gate now green on the flipped rows. Playwright
and a desktop debug-build launch are optional (D5).

### CSP-7 Library facade and skills

**Deliverables**: `Sources/RielaCLI/RielaLibrary.swift` with public
`executeWorkflow`, `resumeSession`, `rerunSession`, `inspectWorkflow`,
`sessionView`, `executeGraphQLDocument`, each delegating to the same
runner/executor paths the CLI uses; `Resources/skills/riela-workflow-reference`
rewritten to exactly those names with a compiling snippet exercised by a
test; `Resources/skills/riela-workflow-run` updated with its command block
generated from the catalog; `riela-auto-improve` absent (D1); the stale
progress record deleted.

**Completion evidence**: skill token test green; library gate green; doc
snippet test compiles.

### CSP-8 Integrated verification

`arch -arm64 /bin/zsh -lc 'swift build && swift test'` from the worktree
root with zero failures beyond the known interleaved-submit flake (isolated
rerun recorded); SwiftLint clean on changed sources
(`arch -arm64 /bin/zsh -lc 'swiftlint lint --strict <changed files>'`);
`cd web && bun run typecheck && bun run lint && bun test src` green;
negative dummy-command test present and red-proving; every checklist box
checked with per-box evidence below; all commits on
`feat/control-surface-parity` pushed with `-u` on first push; `main`
untouched.

## Verification commands (record exact output counts as evidence)

- Iteration: `arch -arm64 /bin/zsh -lc 'swift test --filter SurfaceParity'`
  and per-area filters (`SurfaceCatalog`, `SessionMutation`, `SingleParser`).
- Acceptance: `arch -arm64 /bin/zsh -lc 'swift build && swift test'` at the
  worktree root; `cd web && bun run typecheck && bun run lint && bun test src`.
- Logs for long commands: tee to `tmp/surface-parity/logs/` (gitignored);
  keep final exit status with the log path.

## Progress Log

- 2026-09-20: plan created from the accepted design; no code written.
- 2026-09-21: fable-design revision (fable-and-improve-opus-session-132):
  added task checklist, verified seam facts at `ca1ce34`, applicable prior
  knowledge, and aligned tasks with accepted design deltas D1–D8 (see design
  doc section 5: `Resources/skills` creation, SDL generation scope, stop
  semantics, Swift-only gate tooling, CSP-6 evidence narrowing, blocked Work
  Runtime rows, declared route tables, shared console-read wiring). No
  production code written.
