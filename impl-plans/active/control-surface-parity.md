# Control-Surface Parity Implementation Plan

**Status**: Ready for implementation
**Workflow Mode**: feature
**Feature Fanout**: false — one catalog, one gate, one work package
**Design Reference**: `design-docs/specs/design-control-surface-parity.md`
**Related**: `impl-plans/active/work-runtime-p0-model-and-store.md` (must add its task and intent operations to the catalog), Monja `impl-plans/active/47-surface-parity.md`
**Created**: 2026-09-20
**Last Updated**: 2026-09-20

## Accepted Design And Review

- Source of truth: `design-docs/specs/design-control-surface-parity.md`.
- The gate lands first and is expected to fail on the current tree with the
  gaps in design section 1. Closing gaps is the second half.
- Auto-improve surfaces are not filled; they are `excluded` because the Work
  Runtime design deletes them.

## Scope

### Included

- `SurfaceCatalog` types and data in `RielaCore` with one row per current
  CLI command, GraphQL field, web route, library entry point, and skill
  command block, states matching design section 1.
- Five gate tests (CLI, GraphQL, web API, library, skills).
- Generated SDL and validator from DTOs plus catalog; one-parser proof.
- Console reads for instances and overview moved to GraphQL; surviving web
  routes cataloged with reasons.
- Session rerun, resume, stop on GraphQL.
- Library facade and the rewritten `riela-workflow-reference` skill.
- Skill command blocks generated from the catalog.

### Excluded

- Any Work Runtime behavior; P0 only adds catalog rows for its commands.
- New GraphQL coverage for package, node, setup, doctor, gc, worker, memory
  (declared `excluded`).
- Changes to manager-session authentication.

## Task Breakdown

| Task | Deliverables | Primary write scope | Dependencies | Parallelizable |
| --- | --- | --- | --- | --- |
| CSP-1 Catalog | `SurfaceOperation`, `SurfaceAvailability`, `SurfaceCatalog.all`; rows for every current operation; uniqueness tests | `Sources/RielaCore/SurfaceCatalog.swift`, `Sources/RielaCore/SurfaceCatalog+Rows.swift`, `Tests/RielaCoreTests/SurfaceCatalogTests.swift` | none | No |
| CSP-2 CLI and skills gates | Command-tree enumerator over `RielaCommand` and `*CommandKind`; option-name extractor; skill token scanner with allowlist; bijection tests | `Tests/RielaCLITests/SurfaceParityCLITests.swift`, `Tests/RielaCLITests/SurfaceParitySkillTests.swift`, `scripts/surface-parity/skill-tokens.py` | CSP-1 | Yes with CSP-3, CSP-4 |
| CSP-3 GraphQL gate and generated SDL | Schema field enumerator; SDL generator from DTOs + catalog; checked-in generated SDL with freshness test; validator reads generated schema; single-parser assertion across `riela graphql`, `riela serve`, desktop provider, web router | `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` (becomes generated), `Sources/RielaGraphQL/GraphQLSchemaGenerator.swift`, `scripts/surface-parity/generate-sdl.swift`, `Tests/RielaGraphQLTests/SurfaceParityGraphQLTests.swift`, `Tests/RielaGraphQLTests/SingleParserTests.swift` | CSP-1 | Yes with CSP-2, CSP-4 |
| CSP-4 Web API and library gates | Route enumerator over `ServeWebHost` and `RielaAppWebRouter`; library facade list script; bijection tests | `Tests/RielaCLITests/SurfaceParityWebAPITests.swift`, `Tests/RielaCLITests/SurfaceParityLibraryTests.swift`, `scripts/surface-parity/library-facade.sh` | CSP-1 | Yes with CSP-2, CSP-3 |
| CSP-5 Session mutations on GraphQL | `rerunSession`, `resumeSession`, `stopSession` mutations calling the same runner paths as the CLI; DTOs; catalog rows flipped | `Sources/RielaGraphQL/GraphQLContracts.swift`, `Sources/RielaGraphQL/RielaGraphQL.swift`, `Sources/RielaGraphQL/GraphQLSessionObservabilityContracts.swift`, `Tests/RielaGraphQLTests/SessionMutationTests.swift` | CSP-3 | No |
| CSP-6 Console reads to GraphQL | Web and desktop instance and overview reads via GraphQL client; `/api/v1/instances` and instance overview routes removed; surviving routes cataloged with reasons | `web/src/api.ts`, `web/src/workflows/client.ts`, `Sources/RielaCLI/ServeWebHost+Instances.swift`, `Sources/RielaApp/RielaAppInstanceAPI.swift`, `Sources/RielaAppSupport/RielaWebAPIProjection.swift`, web tests | CSP-4 | No |
| CSP-7 Library facade and skills | Public facade functions; `riela-workflow-reference` rewritten; skill command blocks generated; `riela-auto-improve` skill deleted; stale progress record deleted | `Sources/RielaCLI/RielaLibrary.swift`, `Resources/skills/*`, `impl-plans/progress/plans/graphql-supervision-execution-parity.json` | CSP-2, CSP-4 | No |
| CSP-8 Integrated verification | Full build and tests on arm64, SwiftLint, negative test with an unregistered dummy command, progress log | tests and this plan | CSP-1..7 | No |

## Task Details

### CSP-1 Catalog

**Deliverables**: the types from design 2.1; rows for every command in
`riela --help`, every GraphQL field, every `/api/v1` route, `executeWorkflow`,
and every command block in the packaged skills; `blocked` and `excluded` rows
per design 2.6 with evidence and reasons; uniqueness tests over ids, CLI
paths, GraphQL fields, and web paths.

**Completion evidence**: catalog tests green; a review of the rows against
design section 1 recorded in the progress log.

### CSP-2 CLI and skills gates

**Deliverables**: enumerator that walks `RielaCommand` and each
`*CommandKind`, producing command paths and typed option names from the
`swift-argument-parser` definitions; skill scanner that extracts `riela ...`
command lines and `--flag` tokens from `Resources/skills/**/SKILL.md` and
`references/*.md`; bijection tests with messages that print the missing side.

**Completion evidence**: on the unfixed tree the skill test fails naming
`--supervisor-workflow` and `--no-allow-targeted-rerun` at minimum; after
CSP-7 it passes.

### CSP-3 GraphQL gate and generated SDL

**Deliverables**: generator that emits the SDL from the 27 DTO types and the
catalog's `graphql` bindings; the SDL literal file becomes generated output
with a header and a freshness test; selection validation consumes the
generated schema; a test that instantiates every GraphQL entry point and
asserts they share one parser type.

**Completion evidence**: generated file byte-identical to the checked-in
file; existing GraphQL tests unchanged and green; single-parser test green
or, if a second parser is found, a task added to this plan to remove it
before CSP-8.

### CSP-4 Web API and library gates

**Deliverables**: route enumerator for `ServeWebHost` and
`RielaAppWebRouter`; script that lists `public func` in the designated
facade file; bijection tests.

**Completion evidence**: on the unfixed tree the web test fails for instances
and overview only after CSP-6 flips their rows; the library test fails until
CSP-7 defines the facade.

### CSP-5 Session mutations on GraphQL

**Deliverables**: three mutations reusing `SessionRerunCommand`,
`SessionResumeCommand`, and the stop path that persists cancelled sessions
before acknowledging; manager-session authentication as for
`continueSession`; DTOs; catalog rows `implemented`.

**Completion evidence**: mutation tests against a fixture session store;
parity test that the CLI and GraphQL paths produce identical session
lineage records.

### CSP-6 Console reads to GraphQL

**Deliverables**: web and desktop instance list, detail, and overview via
GraphQL `workflowInstances` and a new `opsOverview` query; the JSON routes
removed; remaining `/api/v1` routes cataloged as `excluded` from GraphQL with
reasons (auth handshake, byte transfer, editor file operations, worker
credentials).

**Completion evidence**: `bun run typecheck`, `bun run lint`, web unit and
Playwright tests green; desktop debug build launches and lists instances.

### CSP-7 Library facade and skills

**Deliverables**: `RielaLibrary.swift` with `executeWorkflow`,
`resumeSession`, `rerunSession`, `inspectWorkflow`, `sessionView`,
`executeGraphQLDocument`; `riela-workflow-reference` rewritten to those
names; skill command blocks regenerated; `riela-auto-improve` deleted;
`riela-workflow-run` updated; the stale progress record deleted.

**Completion evidence**: skill token test green; a doc test compiles a
snippet from `riela-workflow-reference`.

### CSP-8 Integrated verification

`arch -arm64 /bin/zsh -lc 'swift build && swift test'` from the repository
root with zero failures beyond the known interleaved-submit flake; SwiftLint
on changed sources; a negative test that registers a dummy command without a
catalog row and asserts the CLI gate fails; progress log entry with evidence.

## Progress Log

- 2026-09-20: plan created from the accepted design; no code written.
