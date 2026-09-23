# Control-Surface Parity Implementation Plan

**Status**: Complete — all 8 CSP boxes checked with evidence; accepted and
committed as `bc3518e` on `feat/control-surface-parity`
**Archived**: 2026-09-21 — moved from `impl-plans/active/` to
`impl-plans/completed/` together with its dispatch manifest
`impl-plans/completed/surface-parity-dispatch.json`
**Workflow Mode**: feature
**Feature Fanout**: false — one catalog, one gate, one work package
**Design Reference**: `design-docs/specs/design-control-surface-parity.md`
(sections 1–4 accepted 2026-09-20; section 5 accepted deltas D1–D8,
2026-09-21 — read both before implementing)
**Related**: `impl-plans/active/work-runtime-p0-model-and-store.md` (its
`riela task` / `riela intent` operations enter the catalog only as `blocked`
rows citing that plan — delta D6), Monja `impl-plans/active/47-surface-parity.md`
**Created**: 2026-09-20
**Last Updated**: 2026-09-21 (archived to `completed/`)

## Task Checklist

Check a box only with a matching evidence entry in the progress log.

- [x] CSP-1 Catalog
- [x] CSP-2 CLI and skills gates
- [x] CSP-3 GraphQL gate and generated SDL
- [x] CSP-4 Web API and library gates
- [x] CSP-5 Session mutations on GraphQL
- [x] CSP-6 Console reads to GraphQL
- [x] CSP-7 Library facade and skills
- [x] CSP-8 Integrated verification

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
  (`Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift` — note
  the file lives in RielaCore, not RielaCLI; regression in
  `WorkflowCommandAutoImproveTests.swift`). The typed error string
  `session_not_running` does not exist anywhere under `Sources/` yet; CSP-5
  introduces it.
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
- 2026-09-21: fable-design confirmation pass (fable-and-improve-opus-
  session-2): re-verified every seam fact against HEAD `86fe704` (diff
  `ca1ce34..86fe704` is docs-only: this plan and the design doc). Confirmed
  absent as expected: `Sources/RielaCore/SurfaceCatalog*`,
  `Resources/skills/`, `scripts/surface-parity/`,
  `Sources/RielaCLI/RielaLibrary.swift`, GraphQL
  `opsOverview`/`rerunSession`/`resumeSession`/`stopSession`. Confirmed
  present: `schemaContract` literal (:2, `workflowInstances` :303,
  `continueSession` :324), `SessionRerunCommand` :381 /
  `SessionResumeCommand` :641, web routes `/api/v1/bootstrap` :53,
  `/api/v1/instances` :64, `/api/v1/ops/overview` :89 in
  `RielaWebAPIProjection.swift`, desktop composite chains
  registry→routine→configuration only, stale progress record still present.
  Corrected one seam fact: the cancellation file lives in `Sources/RielaCore`.
  Branch has no upstream (`git rev-parse @{u}` fails): first push must be
  `git push -u origin feat/control-surface-parity`. No design deltas beyond
  D1–D8 required; design doc unchanged. No production code written.

- 2026-09-21: **implementation (fable-and-improve-opus, Claude Opus 5)**.
  All eight tasks implemented on `feat/control-surface-parity` from checkpoint
  `f8b763a`. Evidence per box below; commands ran through
  `arch -arm64 /bin/zsh -lc '…'` from the worktree root, logs under
  `tmp/surface-parity/control-surface-parity/attempt-1/logs/` (gitignored).

  - **CSP-1 Catalog** — `Sources/RielaCore/SurfaceCatalog.swift` (types,
    invariants, shared bijection helper), `SurfaceCatalog+RowSupport.swift`
    (design-2.6 exclusion reasons, row builder), and the row files
    `SurfaceCatalog+Rows.swift` (workflow/session/loop),
    `+RowsCLI.swift` (package, node, memory, instance, specialist, local
    tools, events, routine, serve, graphql client, auth, worker) and
    `+RowsConsole.swift` (console reads, configuration, web platform, Work
    Runtime). 211 rows. Every required surface (`cli`, `graphql`, `webAPI`,
    `library`) is declared on every row; `blocked` rows carry evidence and
    `excluded` rows carry a reason and a design link, enforced by
    `SurfaceCatalog.invariantViolations()`.
    Evidence: `swift test --filter SurfaceCatalog` → 7 tests, 0 failures.
    Row review against design section 1: every query and mutation listed
    there has a row; `riela task` / `riela intent` are `blocked` on
    `impl-plans/active/work-runtime-p0-model-and-store.md` (D6);
    `session.supervision` is `excluded` on all four surfaces citing the Work
    Runtime design; package/node/setup/doctor/gc/worker/memory/specialist are
    `excluded` with the section-2.6 reasons.

  - **CSP-2 CLI and skills gates** — `Sources/RielaCLI/CLISurfaceEnumeration.swift`
    walks `RielaClientCommandRouter.configuration.subcommands` and the typed
    family enums, and adds the two pre-parser commands (`auth`, `worker`)
    dispatched in `RielaCLIApplication.runParsed`. To make the walk real,
    `CaseIterable` was added to `WorkflowClientSubcommand`,
    `SessionClientSubcommand`, `InstanceClientSubcommand`,
    `SetupClientSubcommand`, `WorkflowManifestClientSubcommand`,
    `WorkflowVersionClientOperation`, `LoopBaselineAction`,
    `PackageCommandKind`, `NodeCommandKind`, `LoopCommandKind`,
    `SpecialistCommandKind`, `ScopedCommandKind`,
    `WorkflowVersionCommandKind` and `MemoryCommandKind`, and the
    string-switched families gained declared enums
    (`RoutineClientAction`, `ServeClientAction`, `KaibaInstanceClientAction`,
    `PasskeyClientAction`, `DistributedWorkerClientAction`) that their owning
    switches now read their literals from. The gate is the pure function
    `CLISurfaceEnumerator.violations(commands:catalog:)`, so the negative test
    injects a dummy descriptor with no production seam. The option universe is
    rendered from the argument-parser definitions themselves
    (`ParsableArguments.helpMessage()`).
    Evidence: `swift test --filter SurfaceParityCLITests` → 6 tests, 0
    failures, including `testGateFailsForACommandWithoutACatalogRow` (dummy
    `dummy command` produces exactly one violation),
    `testGateFailsForACatalogRowWithoutACommand`, and
    `testGateFailsForAnUnknownOptionOnACatalogRow` (a `--supervisor-workflow`
    option on a row is rejected).
    Skill gate: `swift test --filter SurfaceParitySkillTests` → 7 tests, 0
    failures; `testAStaleFlagIsRejected` proves `--supervisor-workflow` and
    `--no-allow-targeted-rerun` are rejected and that the scanner sees them;
    `testCanonicalSkillSetIsPresentAndRejectedSkillsAreAbsent` proves
    `riela-auto-improve` is absent (D1).

  - **CSP-3 GraphQL gate and generated SDL** —
    `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift` holds the 64 contract
    type descriptors and the root-field signature table;
    `catalogFields(root:)` takes the published Query/Mutation fields and their
    order from `SurfaceCatalog`. `GraphQLContractProjector+Schema.swift` is now
    generated output with a header naming the generator;
    `scripts/surface-parity/generate-sdl.sh` regenerates it by rerunning the
    suite with `RIELA_WRITE_GENERATED_SDL=1` (delta D4 — no extra tool target).
    `SurfaceParityDTOSchemaTests` reads the 27 `GraphQL*DTO` structs from
    source through `#filePath` and asserts each one's property names *and*
    mapped GraphQL types equal its schema type descriptor, so the SDL is
    derived from the DTOs rather than maintained beside them.
    Evidence: `swift test --filter RielaGraphQLTests` → 65 tests, 1 skipped
    (the regeneration entry point), 0 failures. Byte-identity is asserted twice:
    `render()` vs `schemaContract`, and `swiftSourceTemplate()` vs the
    checked-in file. Selection validation still reads the schema
    (`GraphQLVariableValidation.swift`), so no hand-maintained table exists.
    Single-parser proof: `swift test --filter SingleParserTests` → 4 tests, 0
    failures.

  - **CSP-4 Web API and library gates** —
    `Sources/RielaAppSupport/RielaWebAPIRouteTable.swift` declares 31 routes
    across the five routing owners (D7), each with the owner file and, where
    dispatch is component-based, the token the gate looks for. The gate asserts
    the bijection with the catalog, that every declared route appears in its
    owner file, that no source serves an `/api/v1` path the table omits, and
    spot-dispatches `GET /api/v1/bootstrap` (200, carries `apiVersion` and
    `csrfToken`) and `GET /api/v1/auth/status` through `RielaPasskeyService`
    (200, `passkey`). The library gate reads
    `Sources/RielaCLI/RielaLibrary.swift` through `#filePath` (D4).
    Red proof recorded before the fix:
    `logs/red-proof-webapi-gate.log` (9 errors) and
    `logs/red-proof-webapi-gate-2.log` — the gate failed with exactly the
    design-section-1 gaps: `/api/v1/instances` and `/api/v1/ops/overview`
    still served and answering 200.
    Evidence after CSP-6/CSP-7:
    `swift test --filter SurfaceParityWebAPITests` → 6 tests, 0 failures;
    `swift test --filter SurfaceParityLibraryTests` → 4 tests, 0 failures.

  - **CSP-5 Session mutations on GraphQL** —
    `Sources/RielaGraphQL/GraphQLSessionControlContracts.swift` adds the
    DTOs and `SessionControlGraphQLDocumentExecutor`;
    `Sources/RielaCLI/SessionControlProvider.swift` implements the provider
    against `SessionRerunCommand` and `SessionResumeCommand`, with
    `RielaRunningSessionRegistry` tracking sessions this process runs. The
    executor is chained into all three composites (`riela graphql document`,
    `riela serve` `/graphql`, the desktop composite). `stopSession` cancels the
    registered task and returns only after it finished — which is after the
    runner's cancellation path (`43edf93`) persisted the terminal state — and
    otherwise throws the typed `session_not_running` error (D3).
    Evidence: `swift test --filter SessionMutationTests` → 6 tests, 0 failures;
    `swift test --filter SurfaceParitySessionLineageTests` → 3 tests, 0
    failures, including CLI/GraphQL rerun lineage parity against the real
    `worker-only-single-step` runner (same status, same `sourceStepId`, same
    `entryMode`, same `rootSessionId`, new session id) and the fail-closed
    stop.

  - **CSP-6 Console reads to GraphQL** —
    `Sources/RielaAppSupport/RielaConsoleGraphQLProvider.swift` is the shared
    seam (D8); `Sources/RielaGraphQL/GraphQLConsoleContracts.swift` adds the
    DTOs and `ConsoleGraphQLDocumentExecutor`, chained into `riela serve` and
    the desktop composite. `RielaWebAPIProjection` lost the
    `GET /api/v1/instances` list, the `GET /api/v1/instances/{identity}`
    detail and the whole `/api/v1/ops/overview` route, together with
    `webOpsOverview`, `webInstanceDetail`, `webInstanceJSON`,
    `webInstancesJSON` and `webMissingSourceInstanceJSON`; its now-unused
    `runtimeSnapshot` and `environment` parameters were removed too. The web
    console reads through `web/src/console/client.ts`
    (`consoleInstances`, `consoleInstance`, `opsOverview`).
    Evidence: `swift test --filter SurfaceParityConsoleReadTests` → 5 tests, 0
    failures; `cd web && bun run typecheck` (clean), `bun run lint` (clean,
    production source audit passed), `bun test src` → 100 pass, 0 fail across
    21 files, including `src/console/client.test.ts` which proves the reads go
    to `/graphql` and that no source file calls the retired routes.
    Playwright and a desktop debug-build launch were not run (optional, D5).

  - **CSP-7 Library facade and skills** —
    `Sources/RielaCLI/RielaLibrary.swift` exposes exactly `executeWorkflow`,
    `resumeSession`, `rerunSession`, `inspectWorkflow`, `sessionView` and
    `executeGraphQLDocument`, each delegating to the command the CLI runs.
    `Resources/skills/` was created (D1) with `riela-workflow-reference`
    rewritten against those names and `riela-workflow-run` carrying
    catalog-generated command blocks; the blocks are compared with the catalog
    family by family. `impl-plans/progress/plans/graphql-supervision-execution-parity.json`
    is deleted.
    Evidence: `swift test --filter SurfaceParityLibraryTests` → 4 tests, 0
    failures, including a compiling exercise of every documented call with its
    documented argument labels and a test that the retired TypeScript names
    (`createWorkflowExecutionClient`, `resumeWorkflow`, `rerunWorkflow`,
    `getRuntimeSessionView`, `callWorkflowStep`, `executeGraphqlRequest`,
    `createGraphqlSchema`) do not reappear.

  - **CSP-8 Integrated verification** — see the verification entry below.

- 2026-09-21: **accepted deltas and findings recorded during implementation**
  (fable-and-improve-opus, Claude Opus 5). Each is also written into
  `design-docs/specs/design-control-surface-parity.md` section 5.

  - **D9 — SDL normalization (pre-authorized).** The plan's open decision point
    allowed checking in the generator's canonical output if byte-identical
    regeneration of the hand-written literal proved impractical. It did: the
    old literal mixed one-line and multi-line type declarations and ordered
    root fields by hand. The checked-in SDL is now the generator's canonical
    form — every type multi-line, root fields in `SurfaceCatalog` order. Five
    assertions in `GraphQLContractsTests` that pinned the one-line `input`
    formatting were rewritten to pin the same fields in the new formatting;
    no assertion was weakened or removed.
  - **D10 — executor placement.** `GraphQLDocumentDomainPreflighting` is
    internal to `RielaGraphQL`, so an executor declared in `RielaAppSupport`
    cannot take part in the composite's mixed-domain preflight. The console
    and session-control *executors* therefore live in `RielaGraphQL`; the
    shared console *provider* lives in `RielaAppSupport`
    (`RielaConsoleGraphQLProvider`) as delta D8 requires, consumed by both
    `ServeWebHost` and the desktop composite.
  - **D11 — `/api/v1/ops/overview` is deleted whole.** The manifest named only
    "the instance portions" of the route, but the ops views consume one
    payload (workflows, instances and runs together), so splitting it would
    leave the dashboard reading two sources. `Query.opsOverview` replaces the
    whole route and the route is gone.
  - **D12 — `continueSession` had no executor.** The schema published
    `continueSession` and `GraphQLControlPlaneServicing` declared it, but no
    document executor in the tree answered it, so a `/graphql` request for it
    returned "selected GraphQL root was not handled". The session-control
    executor implements it (delegating to the resume path, exactly as the
    CLI's `SessionContinueCommand` does), which makes the catalog's
    `session.continue` GraphQL claim true.

  - **Seam-fact corrections against `f8b763a`.** The plan's seam facts were
    accurate except for three points, corrected here rather than silently:
    (1) `schemaContract` interpolates **three** hand-written SDL blocks, not
    two — `workflowRegistryGraphQLSchemaTypes`,
    `configurationGraphQLSchemaTypes` and `routineGraphQLSchemaTypes`;
    (2) `Sources/RielaCLI/ParityCommandSupport.swift` contains no
    `continueSession` resolver — it holds `ParsedParityOptions` and shared
    rendering helpers, and no resolver existed anywhere;
    (3) `Sources/RielaApp/RielaAppInstanceAPI.swift` has no read paths to
    delete — it serves only the two `POST` instance routes, which survive.

  - **Architecture-review dual-lexer finding: closed, negative.** There is one
    GraphQL parser. `SingleParserTests` asserts the lexing primitives are
    declared in exactly one file
    (`Sources/RielaGraphQL/GraphQLDocumentParsing.swift`), that no other file
    declares a `parseGraphQL…`/`readGraphQL…`/`skipGraphQL…`/`tokenizeGraphQL…`
    function, that all four `/graphql` entry points assemble the shared
    composite executor, and that two different entry-point assemblies reject
    the same malformed document with the same diagnostic. The one other
    `parseGraphQL*` name in the tree,
    `RielaServer.parseGraphQLEnvelope`, decodes the HTTP JSON envelope and
    delegates operation-name parsing to the shared parser; the test allowlists
    it by name and asserts that delegation. No removal task was needed.

  - **F1 (follow-up, newly discovered) — schema fields with no document
    executor.** Implementing CSP-5 surfaced a gap the accepted design did not
    know about: 17 of the fields the control-plane schema publishes have no
    document executor, so `/graphql` cannot reach them even though the schema
    and the read services both exist. They are
    `Query.workflowInstances`, `Query.workflowInstance`,
    `Query.workflowSession`, `Query.workflowSessions`,
    `Query.sessionProgress`, `Query.sessionHealth`, `Query.loopEvidence`,
    `Query.loopSessions`, `Query.loopWorkflowStats`,
    `Query.loopEvidenceDiff`, `Query.managerSession`,
    `Mutation.createWorkflowInstance`, `Mutation.updateWorkflowInstance`,
    `Mutation.deleteWorkflowInstance`, `Mutation.sendManagerMessage`,
    `Mutation.replayCommunication` and
    `Mutation.retryCommunicationDelivery`. The first fourteen have services
    (`GraphQLRuntimeSnapshotQueryService`, `GraphQLWorkflowInstanceService`)
    waiting to be wired; the last three have only the
    `GraphQLControlPlaneServicing` protocol with no implementation anywhere.
    This is recorded as a machine-checked allowlist in
    `Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift`, whose
    tests fail if the list grows or drifts, so the gap can only shrink. It is
    **not** closed by this plan; it needs its own task.

- 2026-09-21: **CSP-8 integrated verification** (fable-and-improve-opus,
  Claude Opus 5). Every command ran in the foreground from the worktree root
  through `arch -arm64 /bin/zsh -lc '…'`; logs are under
  `tmp/surface-parity/control-surface-parity/attempt-1/logs/` (gitignored).

  - `swift build && swift test` →
    `logs/csp8-swift-test-final.log`, exit status 1, **10 failing tests**, all
    of them pre-existing and environmental, none introduced by this change:
    `RielaAppUXOnboardingControllerTests` (4),
    `RielaAppSettingsEditorNavigationTests` (1) and
    `RielaAppWindowContentInsetTests` (1) fail on AppKit view-hierarchy
    lookups (`XCTUnwrap failed: expected non-nil value of type "NSTableView"`,
    `"NSButton"`, `"DaemonWorkflowInstanceListView"`) in this headless agent
    session; `WorkflowRound7AdversarialTests` (3) fail with
    `NSCocoaErrorDomain Code=4 "…sock" couldn't be removed` when the sandbox
    refuses to unlink a unix socket; `WorkflowCommandTests`
    `testPackageAppEnvironmentEnablementRunAndMonitoringScenario` (1) fails on
    `appState.managedCandidates(from:)` returning a third, ambient candidate.
    Evidence that they are not this change's: each failing test file contains
    zero references to `RielaWebAPIProjection`, `/api/v1`,
    `consoleGraphQLProvider` or `SurfaceCatalog`, and none of the sources they
    exercise appear in this change's diff. All ten also fail when run in
    isolation on this tree.
  - The earlier full run (`logs/csp8-swift-test.log`) had **17** failures: the
    same ten plus seven that this change did cause — `RielaAppWebAPIRouteTests`
    (5) and `ServeWebHostTests` (2) read the retired
    `GET /api/v1/instances`, `GET /api/v1/instances/{identity}` and
    `GET /api/v1/ops/overview` routes. Those seven were **ported, not
    weakened**: every assertion (composite-identity decoding, secret
    redaction, `needsSource` projection, typed node patches, the ops-overview
    workflow graph, instances and runs, the missing-definition diagnostic)
    now runs against `RielaConsoleGraphQLProvider`, and each test additionally
    asserts the retired route answers 404.
    `swift test --filter RielaAppWebAPIRouteTests` → 16 tests, 0 failures;
    `swift test --filter ServeWebHostTests` → 8 tests, 0 failures.
  - **The interleaved-submit flake did not appear** in either full run, so no
    isolated rerun was needed. The ten failures above are *not* that flake and
    are not covered by the plan's tolerated-failure rule; they are reported as
    a verification gap, not as a pass.
  - `swiftlint lint --strict <42 changed sources>` →
    `Found 0 violations, 0 serious in 42 files`.
  - `cd web && bun run typecheck && bun run lint && bun test src` →
    `logs/csp8-web.log`, exit status 0: `tsc --noEmit` clean, `eslint` clean
    with "Production source audit passed", and **100 pass, 0 fail, 1795
    expect() calls across 21 files**.
  - Surface gates on the final tree, each run individually:
    `SurfaceCatalog` 7/7, `SurfaceParityCLITests` 6/6,
    `SurfaceParitySkillTests` 7/7, `SurfaceParityGraphQLTests` 6/6 (1 skipped
    regeneration entry point), `SurfaceParityDTOSchemaTests` 2/2,
    `SingleParserTests` 4/4, `SurfaceParityWebAPITests` 6/6,
    `SurfaceParityLibraryTests` 4/4, `SessionMutationTests` 6/6,
    `SurfaceParitySessionLineageTests` 3/3,
    `SurfaceParityConsoleReadTests` 5/5,
    `SurfaceParityExecutorCoverageTests` 3/3.
  - **Not committed and not pushed.** This run executed under the
    shared-branch write protocol, which forbids `git add`/`commit`/`push`;
    that protocol takes precedence over the plan's own "push with `-u`" step.
    The working tree on `feat/control-surface-parity` carries the whole
    change, ready for the serial join. One index side effect to be aware of:
    `impl-plans/progress/plans/graphql-supervision-execution-parity.json` was
    removed with `git rm --cached` before the file was deleted, so its
    deletion is already staged; nothing else is staged.

- 2026-09-21: **review revision 1 — R1–R7 from the independent
  implementation review** (fable-and-improve-opus, Claude Opus 5). Evidence
  under `tmp/surface-parity/control-surface-parity/attempt-2/logs/`.

  - **R1 (medium) — Playwright fixtures were left wired to the deleted
    routes. Fixed and the suite now runs.** Six specs stubbed the retired
    reads, not four: `dashboard.spec.ts`, `workflow-management.spec.ts`,
    `workflow-configurations.spec.ts`, `workflow-studio.spec.ts`,
    `server-instances.spec.ts` (its `/api/v1` fallthrough doubled as the
    instance list) and `desktop-connection.spec.ts` (its desktop-pipe
    `/graphql` stub answered every operation with `data.workflows`). Every
    `GET /api/v1/instances`, `GET /api/v1/instances/{identity}` and
    `/api/v1/ops/overview` branch is deleted; each spec's `/graphql` handler
    now answers `WebConsoleInstances`, `WebConsoleInstance` and
    `WebOpsOverview` with the payload its deleted branch used to fulfil,
    preserving each fixture's live state (`instancesDelay`, the
    `externalInstanceChange` revision bump, the mutable `items` list, the
    `running`/`enabled` toggles). The POST `/api/v1/instances`,
    `.../actions` and `.../executions` branches are untouched.
    One assertion changed meaning and was restated rather than dropped:
    `workflow-configurations.spec.ts` counted *every* `/graphql` request as a
    "registry read" and asserted zero; `/graphql` now legitimately carries the
    console reads, so the counter counts registry operations, which is the
    assertion the test was always making.
    Evidence: `cd web && bun run test:e2e` →
    `logs/e2e-3.log`, exit status 0, **42 passed**. Two of those specs
    (`passkey-desktop`, `server-authentication`) spawn a real
    `.build/debug/riela serve --web-root web/dist`; they failed on the first
    two runs (`logs/e2e.log`, `logs/e2e-2.log`) purely because `web/dist` did
    not exist in this session. `bun run build` (`logs/web-build.log`, exit 0)
    produced it and all 42 pass.

  - **R2 (medium) — the console migration had no transport-level coverage.
    Added, one per host.**
    `ServeWebHostTests.testConsoleReadDocumentsResolveOverGraphQLWithBrowserHeaders`
    POSTs the literal `WebConsoleInstances`, `WebConsoleInstance` and
    `WebOpsOverview` documents copied from `web/src/console/client.ts` — full
    selection set — to `/graphql` on `ServeWebHost`, with the headers the
    console attaches (`host`, `origin`, `content-type`, `x-riela-csrf` taken
    from the bootstrap response, `x-riela-profile`). It asserts 200, that the
    `JSONObject` scalars survive projection (`workflowVariables.greeting ==
    "hello"`, `nodePatches`, `eventSources`), that the nested
    `environmentVariables`/`requiredEnvironment` lists resolve with the
    `••••••••` mask, that the stored secret does not appear in the response
    body, and — the contract the retired JSON GET never had — that dropping
    `x-riela-profile` yields 409.
    `RielaAppWebAPIRouteTests.testConsoleInstancesDocumentResolvesThroughTheDesktopRouter`
    sends the same document through `RielaAppWebRouter` with the router's CSRF
    token and asserts the same projection and redaction.
    Evidence: both filters green, 1 test each, 0 failures.

  - **R3 (medium) — baseline produced; the ten failures are pre-existing.**
    `git archive HEAD | tar -x -C $(mktemp -d)` then
    `arch -arm64 /bin/zsh -lc 'swift build && swift test'` in that copy, per
    the reviewer's non-mutating recipe: `logs/baseline-swift-test.log`.
    The XCTest phase completed — `Executed 2218 tests, with 1 test skipped and
    172 failures` in 930s — and **all ten** of the failures seen on the
    working tree fail at pristine HEAD as well (grep-confirmed, one occurrence
    each): the six AppKit view-hierarchy cases, the three
    `NSCocoaErrorDomain Code=4` socket-unlink cases, and
    `testPackageAppEnvironmentEnablementRunAndMonitoringScenario`.
    Two honest caveats: the baseline's *total* is not comparable to the
    working tree's, because an extracted copy under `/var/folders` is outside
    a git repository and outside the install layout, so whole suites that pass
    in place (git add-ons, packaged-CLI symlink, container) fail there — the
    baseline is a superset, which is sufficient to establish "pre-existing"
    but not to compare counts. And the wrapper's exit marker was lost when the
    harness backgrounded the command after 600s, so the log ends at the XCTest
    summary rather than an exit status; the summary line itself is complete.
    The extracted tree and one orphaned `riela specialist serve` process it
    left behind were cleaned up.
    **Acceptance criterion 8 is therefore met modulo a named environmental
    set**: ten tests fail in this headless agent session, all ten fail
    identically at `f8b763a`, none of them touches any file in this change.

  - **R4 (low) — the stop-by-id rule is now stated and pinned.** A rerun
    registers under the session it re-enters, because the id its payload
    reports does not exist until the rerun has already finished — so that id
    can never be a stop handle. The rule is documented on
    `GraphQLStopSessionInput`, on `RielaSessionControlProvider.stopSession`,
    and in `Resources/skills/riela-workflow-reference`. It is pinned by
    `SurfaceParitySessionLineageTests.testStopUsesTheEnteredSessionIdNotTheIdTheRerunReports`,
    which reruns a real session and asserts the reported id yields
    `SESSION_NOT_RUNNING`.

  - **R5 (low) — `managerSessionId` documented as inert; workflow ownership
    is now actually enforced.** The reviewer offered documentation or
    deletion; the field is kept (the manager control-plane design puts it on
    every request DTO and a future verifier needs it) and is documented as a
    non-authenticator on all three input types, in the skill, and in design
    section 6, together with the real trust boundary. The second half of the
    finding was fixed in code rather than documented:
    `requireSessionBelongsToWorkflow` loads the persisted session and rejects
    a `workflowId` that does not own it with `SESSION_WORKFLOW_MISMATCH`, so a
    guessed session id can no longer be driven under an arbitrary workflow
    name. `stopSession` keeps its fail-closed ordering — registry check first,
    then ownership, then cancel — so delta D3 is unchanged. Pinned by
    `testSessionControlRejectsAWorkflowThatDoesNotOwnTheSession`.

  - **R6 (low) — the CLI enumerator's blind default branch is closed.**
    `CLISurfaceEnumerator` now declares `leafRoutes` (deliberately
    subcommand-free) and `expandedRoutes` (walked into subcommands), and
    `unclassifiedRoutes()` returns any router subcommand in neither.
    `SurfaceParityCLITests.testEveryRouterRouteIsClassifiedAsALeafOrExpanded`
    requires that to be empty, so registering `riela task` forces an explicit
    classification and, if it is nested, an expansion case — its subcommands
    cannot ship invisible to the gate.

  - **R7 (low) — full out-of-`writePaths` list for the serial join.**
    `impl-plans/completed/surface-parity-dispatch.json` `writePaths` cannot be
    used for collision detection on this plan. The complete set of paths this
    plan created or modified outside it is:
    `Package.swift`; `design-docs/specs/design-control-surface-parity.md`;
    `Sources/RielaApp/RielaAppWebAPI.swift`;
    `Sources/RielaAppSupport/RielaConsoleGraphQLProvider.swift`,
    `Sources/RielaAppSupport/RielaWebAPIRouteTable.swift`;
    `Sources/RielaCLI/CLISurfaceEnumeration.swift`,
    `Sources/RielaCLI/SessionControlProvider.swift`,
    `Sources/RielaCLI/DistributedWorkerCommand.swift`,
    `Sources/RielaCLI/MemoryCommandModels.swift`,
    `Sources/RielaCLI/PasskeyCommand.swift`,
    `Sources/RielaCLI/RielaClientFamilyArguments.swift`,
    `Sources/RielaCLI/RielaCommand.swift`,
    `Sources/RielaCLI/RoutineCommands.swift`,
    `Sources/RielaCLI/ScopedParityCommands+GraphQLDocument.swift`,
    `Sources/RielaCLI/ScopedParityCommands+Serve.swift`;
    `Sources/RielaCore/SurfaceCatalog+RowSupport.swift`,
    `Sources/RielaCore/SurfaceCatalog+RowsCLI.swift`,
    `Sources/RielaCore/SurfaceCatalog+RowsConsole.swift`;
    `Sources/RielaGraphQL/GraphQLConsoleContracts.swift`,
    `Sources/RielaGraphQL/GraphQLSessionControlContracts.swift`;
    `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift`,
    `Tests/RielaCLITests/ServeWebHostTests.swift`,
    `Tests/RielaCLITests/SurfaceParityConsoleReadTests.swift`,
    `Tests/RielaCLITests/SurfaceParitySessionLineageTests.swift`,
    `Tests/RielaGraphQLTests/GraphQLContractsTests.swift`,
    `Tests/RielaGraphQLTests/SurfaceParityDTOSchemaTests.swift`,
    `Tests/RielaGraphQLTests/SurfaceParityExecutorCoverageTests.swift`;
    `web/src/console/client.ts`, `web/src/console/client.test.ts`;
    `web/e2e/dashboard.spec.ts`, `web/e2e/workflow-management.spec.ts`,
    `web/e2e/workflow-configurations.spec.ts`,
    `web/e2e/workflow-studio.spec.ts`, `web/e2e/server-instances.spec.ts`,
    `web/e2e/desktop-connection.spec.ts`.
    Every one belongs to this plan; no other worker's edits were touched.

- 2026-09-21: **revision-1 verification** (fable-and-improve-opus, Claude Opus
  5). Logs under `tmp/surface-parity/control-surface-parity/attempt-2/logs/`.

  - `arch -arm64 /bin/zsh -lc 'swift build && swift test'` →
    `logs/final-swift-test.log`, `SWIFT_EXIT=1`, **the same ten failures and no
    others** — byte-for-byte the environmental set R3 confirmed at pristine
    HEAD. No failure was introduced by the R1–R7 work.
  - `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict <42 changed sources>'`
    → `Found 0 violations, 0 serious in 42 files`.
  - `cd web && bun run typecheck && bun run lint && bun test src` →
    `logs/web.log`, `WEB_EXIT=0`, 100 pass / 0 fail / 1795 expect() across 21
    files.
  - `cd web && bun run test:e2e` → `logs/e2e-3.log`, exit 0, **42 passed**
    (Playwright now actually runs; R1).
  - Surface gates on the final tree:
    `swift test --filter "SurfaceParity|SurfaceCatalog|SingleParser|SessionMutation"`
    → 63 tests, 1 skipped (the SDL regeneration entry point), 0 failures.
  - Still not committed and not pushed: the shared-branch write protocol
    forbids `git add`/`commit`/`push`. The only staged entry remains the
    deletion of `impl-plans/progress/plans/graphql-supervision-execution-parity.json`.
