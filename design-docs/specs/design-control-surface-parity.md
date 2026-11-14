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
