# Control-surface parity: one operation catalog for CLI, GraphQL, web API, library, and skills

Status: accepted design, 2026-09-20. Not implemented. Plan:
`impl-plans/active/control-surface-parity.md`. Companion to the Monja design
`design-docs/specs/design-surface-parity.md` in the sibling repository, which
applies the same mechanism to Monja's REST, GraphQL, MCP, and SDK surfaces.
Related: `design-work-runtime-consolidation.md` (the first feature that must
ship catalog-first), `design-graphql-manager-control-plane.md`,
`design-riela-architecture-review.md` (Theme 1, "GraphQL surface
quadruple-maintained").

## 1. Problem

Riela exposes its control plane through five surfaces: the CLI, the GraphQL
control plane (`riela graphql` and `riela serve`), the web JSON API under
`/api/v1` used by the web and desktop consoles, the desktop request channel,
and the Swift library entry points. A sixth surface is documentation: the
packaged skills that tell agents which commands and flags exist. Coverage
drifts between them because nothing declares which operation is meant to be
on which surface, and nothing fails when one is missing.

Facts from the tree on 2026-09-20:

- **CLI is the widest surface.** `riela --help` lists workflow, session,
  loop, package, node, instance, specialist, memory, setup, auth, worker,
  serve, graphql, hook, events, call-step, workflow-call, doctor, gc.
- **GraphQL covers a subset.** Queries: `workflows`, `workflow`,
  `workflowSessions`, `workflowSession`, `sessionProgress`, `sessionHealth`,
  `managerSession`, `loopEvidence`, `loopSessions`, `loopWorkflowStats`,
  `loopEvidenceDiff`, `routines`, `routine`, `workflowInstances`,
  `workflowInstance`, `configuration`. Mutations: session continue and manager
  messaging, communication replay and retry, routine CRUD, mutable workflow
  CRUD and activation and consolidation, instance CRUD, event source and
  profile and appearance and assistant and HTTP server configuration. Absent:
  session rerun and resume and stop, loop recover and start and baseline and
  regress and findings, every package, node, specialist, memory, and worker
  operation. Supervision, which the auto-improve skill says is visible as
  `session.supervision` in GraphQL, has no type in the schema.
- **The web API is a parallel surface.** `/api/v1/instances`,
  `/api/v1/ops/overview`, `/api/v1/workflows/sources`,
  `/api/v1/workflow-editor/*`, `/api/v1/settings/workers`, and the passkey
  and device auth routes serve the consoles over JSON, beside GraphQL, with
  their own projection types in `RielaAppSupport`. Instances exist on both
  GraphQL and the web API with separate DTOs.
- **The library surface is undocumented in Swift.** `executeWorkflow` is the
  only public entry point of the ten the `riela-workflow-reference` skill
  names; `createWorkflowExecutionClient`, `inspectWorkflow`,
  `resumeWorkflow`, `rerunWorkflow`, `getRuntimeSessionView`,
  `callWorkflowStep`, `executeGraphqlRequest`, `createGraphqlSchema`, and
  `executeGraphqlDocument` do not exist. The skill describes the deleted
  TypeScript runtime.
- **Skills drift from flags.** The `riela-auto-improve` skill documents
  `--supervisor-workflow` and `--no-allow-targeted-rerun`; neither exists in
  `ParsedWorkflowOptions`. The `riela-workflow-run` and `riela-troubleshooting`
  skills are not verified here and must be assumed to carry the same class of
  error.
- **GraphQL is maintained four times.** Core models, 27 `GraphQL*DTO` mirror
  structs, an SDL string literal in `GraphQLContractProjector+Schema.swift`,
  and the document, operation, fragment, and variable parsers with their
  validation rules. Tests are the only thing that keeps them aligned. The
  architecture review's finding of two independent GraphQL lexers is not
  reproduced by a name search today and must be closed or confirmed by the
  plan, not assumed.
- **Riela's own memory of parity is aspirational.** The progress record
  `impl-plans/progress/plans/graphql-supervision-execution-parity.json` is
  marked completed, and the Swift tree has no supervision type in GraphQL.

Problems, stated:

- **P1 No source of truth** for which operation is on which surface.
- **P2 No gate.** Adding a CLI command, a GraphQL field, a web route, or a
  library function does not require the others, or a declared reason for
  their absence.
- **P3 Documentation surfaces describe a runtime that no longer exists.**
  Skills are read by agents as fact, so a wrong flag is an agent failure.
- **P4 Four-way GraphQL maintenance** with a security-critical parser in the
  middle.
- **P5 Two console surfaces** (GraphQL and `/api/v1`) for overlapping data,
  so the web needs one client for each and DTOs diverge.

## 2. Design

### 2.1 Operation catalog in `RielaCore`

Add `Sources/RielaCore/SurfaceCatalog.swift`: a static array of
`SurfaceOperation` values, one per public control operation, keyed by a
stable id that names the runtime capability, not a command.

```swift
public enum SurfaceName: String, Codable, Sendable { case cli, graphql, webAPI, desktop, library, skill }

public enum SurfaceAvailability: Codable, Sendable, Equatable {
  case implemented
  case blocked(evidence: String)        // accepted, waiting on named evidence
  case excluded(reason: String, design: String)
}

public struct SurfaceOperation: Codable, Sendable {
  public var id: String                 // "session.rerun"
  public var family: String             // "session"
  public var kind: Kind                 // query | mutation | stream | process
  public var surfaces: [SurfaceName: SurfaceAvailability]
  public var cli: CLIBinding?           // command path + flag names
  public var graphql: GraphQLBinding?   // root + field
  public var webAPI: WebAPIBinding?     // method + path
  public var library: LibraryBinding?   // type + function
  public var skills: [String]           // skill names that document it
  public var designSource: String
}
```

The catalog is data and imports nothing from `RielaCLI`, `RielaGraphQL`,
`RielaAppSupport`, or `RielaServer`, so all of them can import it.

### 2.2 Gate tests, one per surface

Under `Tests/RielaCoreTests/SurfaceParity/` and the owning module tests:

- **CLI.** Enumerate the typed command tree from `RielaCommand` and its
  `*CommandKind` enums plus `swift-argument-parser` option names; assert a
  bijection with catalog `cli` bindings. Help text is rendered from the same
  tree, so help cannot list a command the parser lacks.
- **GraphQL.** Build the schema and enumerate `Query` and `Mutation` fields;
  bijection with `graphql` bindings.
- **Web API.** Enumerate routes registered by `ServeWebHost` and
  `RielaAppWebRouter`; bijection with `webAPI` bindings.
- **Library.** A checked-in list of public entry points in `RielaCLI` and
  `RielaWorkflowRegistry` compared with `library` bindings, generated by a
  script that greps `public func` in the designated facade files.
- **Skills.** For every skill under `Resources/skills` and the packaged
  `.claude/skills`, extract command and flag tokens that match `riela ` and
  `--` patterns and assert each resolves to a catalog `cli` binding or an
  allowlisted prose token. This is the test that would have caught
  `--supervisor-workflow`.

An operation added on one surface without a catalog row fails that surface's
test; a catalog row claiming a surface without an implementation fails too.
`blocked` rows require the evidence string; `excluded` rows require a reason
and a design link.

### 2.3 Derive the GraphQL surface from the catalog and the DTOs

Collapse the four-way maintenance to two: the DTO structs stay as the typed
contract, and the SDL string is generated from them plus the catalog's
`graphql` bindings by a build-time script whose output is checked in with a
freshness test. Selection validation reads the generated schema instead of a
hand-kept table. The parsers stay as they are, but the plan includes one task
that proves a single parsing path serves `riela graphql`, `riela serve`, the
desktop provider, and the web router, closing the dual-lexer finding one way
or the other with a test that would fail if a second parser appeared.

### 2.4 Retire the parallel console surface where GraphQL already covers it

`/api/v1/instances` and the instance parts of `/api/v1/ops/overview` are
served by the same `WorkflowInstance` data GraphQL exposes. The web and
desktop clients move those reads to GraphQL; the web routes stay only for
byte transfer, auth handshakes, the workflow editor's file operations, and
worker credentials, and each surviving route has a catalog row with the
reason it is not GraphQL. New console features ship on GraphQL only.

### 2.5 Fix the documentation surface

Skills become derived documentation for their command tables: each skill's
command block is generated from the catalog's `cli` bindings for the
operations the skill lists, so a renamed flag fails the skill test instead
of misleading an agent. Prose stays hand-written. The
`riela-workflow-reference` skill is rewritten against the Swift library
surface that actually exists, and the TypeScript-era names are removed.

### 2.6 Closing the current gaps

| Gap | Decision |
| --- | --- |
| Session rerun, resume, stop on GraphQL | Implement; remote operation of a session without a shell is the point of the control plane |
| Loop recover, start, baseline, regress, findings on GraphQL | Do not implement on the loop names; they arrive as `task` operations in the Work Runtime P2, catalog-first |
| Supervision types on GraphQL | `excluded`, reason "auto-improve is deleted by the Work Runtime design"; the stale progress record is corrected |
| Package, node, specialist, memory, worker, setup, doctor, gc on GraphQL | `excluded` for package install, node install, setup, doctor, gc, worker (local process and filesystem operations); specialist folds into task serve; memory stays CLI and library only with reason |
| Library entry points | Define the facade: `executeWorkflow`, `resumeSession`, `rerunSession`, `inspectWorkflow`, `sessionView`, `executeGraphQLDocument`; each gets a catalog row and the skill is rewritten |
| Web API instances and overview | Retire per 2.4 |
| Task and intent operations (Work Runtime) | Catalog rows land in P0 before the commands; GraphQL and CLI ship together in P1 and P5 with the gate enforcing it |

### 2.7 Rule for every future change

A change that adds or renames a public operation on any surface updates the
catalog in the same commit and either implements the operation on every
surface the row claims or declares `blocked` or `excluded`. Review rejects
"GraphQL later" without a `blocked` row. The Work Runtime's `riela task` and
`riela intent` commands are the first features held to this rule.

## 3. What this does not do

It does not merge CLI and GraphQL, generate command parsers, or replace the
hand-written resolvers. It does not change authorization on the manager
session. It does not touch the Monja integration beyond requiring that the
tracker adapter's operations, when they get a CLI or GraphQL face, are
catalog rows.

## 4. Verification

- On the current tree the five gate tests fail with exactly the gaps listed
  in section 1, which proves the gate detects the drift it targets.
- After 2.6 they pass with only the listed `blocked` and `excluded` rows.
- The generated SDL is byte-identical to the checked-in file; the selection
  validator has no hand-maintained table; a test asserts one parser type
  serves every GraphQL entry point.
- Every packaged skill's command block passes the token test; the
  `riela-auto-improve` skill is deleted and `riela-workflow-reference` names
  only functions that compile.

## 5. Accepted deltas (2026-09-21, fable-and-improve-opus-session-132)

Recorded against the tree at `ca1ce34` before implementation. Each delta
resolves a fact the accepted text assumed but the tree does not provide; none
changes the design's intent.

- **D1 — `Resources/skills` is created, not edited.** The tree has no
  `Resources/skills` and never had one (`git log --all -- Resources/skills`
  is empty); the packaged skills live in the separate `riela-packages`
  registry and at user scope. This feature creates `Resources/skills/` as the
  canonical in-repo source the skill gate scans. Canonical set for this
  feature: `riela-workflow-reference` (rewritten against the real
  `RielaLibrary` facade) and `riela-workflow-run` (command block regenerated
  from the catalog). `riela-auto-improve` is not carried into the canonical
  set and the skill gate's allowlist rejects its name, which is what
  "deleted" means here. Propagating the rewritten skills to the
  `riela-packages` registry is an operator follow-up outside this feature.
- **D2 — SDL generation scope.** The generated SDL is the control-plane
  `schemaContract` in `GraphQLContractProjector+Schema.swift`, produced from
  the 27 `GraphQL*DTO` types plus the catalog's `graphql` bindings. The two
  other SDL literals (`workflowRegistryGraphQLSchemaTypes`,
  `routineGraphQLSchemaTypes`) stay hand-written, but the GraphQL gate
  enumerates Query and Mutation fields from every schema source, so no field
  escapes the catalog. Extending generation to those literals is deferred.
- **D3 — `stopSession` semantics.** No `riela session stop` CLI command
  exists; the "stop path" is the cancellation finalization hardened in
  `43edf93` (`DeterministicWorkflowRunner+Cancellation.swift`). `stopSession`
  cancels a session executing in the answering process and returns only
  after the terminal cancelled state is persisted; a session not running in
  that process yields the typed error `session_not_running` (fail closed, no
  cross-process kill). CLI/GraphQL lineage parity is asserted for rerun and
  resume; stop's evidence is the persisted terminal state.
- **D4 — Gate tooling runs under `swift test`.** The skill token scanner and
  the library facade listing are implemented in Swift inside the test
  targets, resolving the repository root via `#filePath`, so the gates run
  in `swift test` with no Python or shell dependency. `scripts/surface-parity/`
  holds only the SDL regeneration entry point.
- **D5 — CSP-6 evidence narrowing.** Required web evidence is
  `bun run typecheck`, `bun run lint`, `bun test src`. Playwright
  (`test:e2e`) and a desktop debug-build launch are optional extras, not
  gates for this feature.
- **D6 — Work Runtime rows.** `riela task` and `riela intent` operations
  enter the catalog as `blocked` rows citing
  `impl-plans/active/work-runtime-p0-model-and-store.md`; no P0 behavior is
  implemented here.
- **D7 — Declared route tables.** `/api/v1` routing is switch- and
  prefix-based, so each web-routing owner (`RielaWebAPIProjection`,
  `ServeWebHost` and its instance extensions, `RielaAppWebRouter`, the
  workflow-editor handler, worker settings, passkey auth) declares an
  enumerable route table; the web gate asserts a bijection between the
  declared tables and the catalog. Dispatch-versus-table drift is mitigated
  with spot request tests against declared routes.
- **D8 — Console reads need shared control-plane wiring.** `workflowInstances`
  is projected in `RielaGraphQL` (`RielaGraphQL.swift`), but the desktop
  `/graphql` composite (`RielaAppWebGraphQL.swift`) chains only
  registry → routine → configuration executors. Moving console reads to
  GraphQL therefore adds a shared instance/ops execution seam in
  `RielaAppSupport` consumed by both `ServeWebHost` and the desktop
  composite, and a new `opsOverview` query whose DTO mirrors what the ops
  views actually consume from `/api/v1/ops/overview` today.
