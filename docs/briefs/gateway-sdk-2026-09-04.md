# Design: gateway client SDKs, schema search, and operation-mode add-ons (2026-09-04)

Author: Claude Fable 5.1 (design). Implementation: riela `fable-and-improve-opus` runs, one per repository.

## 0. Operator decisions (already made, do not re-litigate)

1. **riela keeps the add-on-node model.** Gateway work is done by add-on nodes whose tier
   (reader / draft / sender, read / write / admin, full / reader) is pinned by the add-on
   name. No LLM-facing tool layer, no MCP, no agent-selectable tiers.
2. **Every gateway library grows a client SDK** so that the common operations can be run
   from an add-on node by naming the operation and passing variables, without the
   workflow author writing GraphQL text.
3. **The SDK keeps the raw GraphQL passthrough** (document + variables) that exists today.
4. **The SDK exposes the schema** and can search it with a regular expression, returning
   only the matching queries / mutations / object types / input types (plus, on request,
   the types those matches reference).
5. **gmail-gateway accepts GraphQL variables.** The "variables are not supported yet"
   rejection goes away.
6. Target gateways: gmail-gateway, wrike-gateway, google-analytics-gateway,
   google-documents-gateway, apple-gateway. google-service-gateway (no GraphQL, typed
   client only) is out of scope. All sources are siblings of the riela checkout under
   `/Users/taco/gits/tacogips/`.

## 1. Verified current state (2026-09-04)

| Gateway | GraphQL runtime | Schema source | Variables | SDL at runtime | Typed client | riela entry point |
|---|---|---|---|---|---|---|
| wrike-gateway 0.2.3 | hand-written lexer/parser/runtime, zero deps | `[CapabilityDefinition]` registry, tiers cumulative read→write→admin | yes, strictly validated | `graphql schema` / `GraphQLRuntime.printedSchema()` | `WrikeReadClient` / `WrikeWriteClient` / `WrikeAdminClient` | `GatewayComposition.makeCommandFrame(role:definitions:environment:)` + `frame.run(["graphql","query",doc,"--variables",json])` |
| google-analytics-gateway | same design as wrike (separate copy), zero deps | `[CapabilityDefinition]` (Read 119 / Write 110 / Admin 23) | yes | `graphql schema` / `GraphQLRuntime.printedSchema()` | none (capability executor only) | same shape as wrike; note riela passes only the write/admin delta definitions |
| apple-gateway 0.1.6 | hand-written, zero deps, `enum GraphQLRuntime` is **internal** | programmatic `GraphQLSchemaRegistry` built from 7 `GraphQLSchemaModule`s; roles `.full` / `.reader` (reader drops mutations) | yes (`VariableResolver`) | `schema print [--role]` (CLI only) | none | `AppleGatewayCommand(arguments:environment:role:...)`, argv only, output string parsed as JSON |
| gmail-gateway | **no parser** — substring scanning over the query text (`prepareGraphQLQuery`, `rootFieldSource`, `extractStringArgument`) | **none** (prose SDL in `design-docs/specs/design-gmail-gateway.md`); root-field lists are `let` arrays per mode | **rejected** by `rejectUnsupportedVariables` (`GmailGatewayCLIParsing.swift:190`); `loadVariables` is dead code | none | `GmailGatewayService` / `GmailGatewayWriteService` / draft / mailbox services returning `[String: Any]`, no tier enforcement | `GmailGatewayCLI(mode:).run(arguments:["graphql","--query",doc], environment:)` (sync) |
| google-documents-gateway | **no GraphQL**; argv commands `<group> <verb> --flag=value` | `GatewayCapabilityCatalog.commands(for: GatewayRole)` (names only; flags live in `GatewayRequestBuilder`) | n/a | `--help` JSON usage, `--dry-run` request plan | none | `GatewayCommandRunner(role:environment:).run(arguments:)` (sync) |

riela side (`Sources/RielaCLI/`):

- `ProductionNodeAdapter+LocalGatewaySupport.swift` — `LocalGatewayGraphQLDescriptor` /
  `LocalGatewayGraphQLEngine`: renders `config.queryTemplate` (+ optional
  `variablesTemplate`) with `addonVariables(for:)`, runs the descriptor's `run` closure,
  parses the JSON envelope, then applies `selectFirst` / `whenFlags` / `payloadExtras`.
  Used by wrike, gmail, analytics add-ons. gmail sets `acceptsVariables: false`.
- `ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift` — separate "args engine"
  (`config.command` + `config.argsTemplate`).
- `ProductionNodeAdapter+AppleGatewaySupport.swift` — `AppleGatewayInvoker`; the apple
  add-on families build GraphQL text by interpolation with `appleGatewayGraphQLString`.
  `riela/apple-gateway-graphql` is the passthrough; `riela/apple-gateway-schema` prints SDL.
- Add-on name catalog: `Sources/RielaAddons/RielaAddons.swift` (`RielaBuiltinAddonCatalog`).
  Dispatch: `BuiltinWorkflowAddonResolver.execute` in `ProductionNodeAdapter.swift`.
- Test seams: `localGatewayGraphQLRunner`, `googleDocumentsGatewayRunner`,
  `appleGatewayRunner` on the resolver; helpers in
  `Tests/RielaCLITests/LocalGatewayAddonTestSupport.swift`.
- Examples must be registered in `Tests/RielaCLITests/RielaExampleCatalog.swift`
  (`rielaExampleWorkflowNames()`, alphabetical) and mock-scenario counts in
  `RielaExampleParityTests.swift` (`expectedMockScenarioCount`).
- Docs: `README.md` sections "Local Gateway Add-ons" and "Apple Gateway Add-Ons".

Facts that shape the design:

- The four GraphQL gateways share **no code**; wrike and analytics are near copies.
  Every repo is deliberately zero-dependency Swift 6 (`swiftLanguageModes: [.v6]`,
  macOS 14+, Swift 6.3.3 via mise), with link-boundary tests asserting that a reader
  binary does not contain writer code.
- The only common abstraction lives in riela (`LocalGatewayGraphQLDescriptor`).
- gmail-gateway's main checkout carries a large **uncommitted** persistent-OAuth WIP
  (18 modified + 19 untracked files, `runPersistent`, `auth setup`, Keychain vault). The
  sync `run(arguments:environment:)` path is unchanged by it. The gmail work below MUST
  run in a git worktree off the committed HEAD (`2761f3b`) on its own branch and must not
  touch the main checkout.
- riela's main checkout has an uncommitted, verified kaiba 0.1.12 bump (see memory
  `riela-kaiba-rag-retrieval-fusion`). riela work below runs in an isolated worktree too.

## 2. Architecture

### 2.1 One shared kit, five thin facades

A new zero-dependency Swift package **`gateway-sdk-kit`** (product `GatewaySDKKit`,
sibling checkout `/Users/taco/gits/tacogips/gateway-sdk-kit`) owns everything that is
gateway-independent:

- the neutral, `Codable` schema catalog model (§2.2),
- the SDL printer for that model,
- regex schema search (§2.4),
- the GraphQL document builder that turns `operation + variables + selection` into a
  document with a proper `$variable` declaration list (§2.3),
- the argv builder for command-style gateways (documents),
- a lexer-aware **variable inliner** (declared/used/required validation + literal
  substitution) that gmail uses to gain variable support without a parser (§3.4),
- the `GatewaySDK` protocol and the shared `GatewayEnvelope` result type,
- a JSON value enum `GatewayJSONValue` (Codable, Sendable) with helpers to convert
  from/to `Any`.

Each gateway adds `GatewaySDKKit` as its only dependency and ships a **facade** type
(`WrikeGatewaySDK`, `GoogleAnalyticsGatewaySDK`, `AppleGatewaySDK`, `GmailGatewaySDK`,
`GoogleDocumentsGatewaySDK`) that (a) exports its schema into the neutral catalog and
(b) executes a raw document / argv through the gateway's existing runtime. Tier
enforcement stays where it is today (the gateway runtime / capability registry / mode
rejection), so the SDK cannot widen a tier.

Why a shared package instead of five copies: the catalog model, search, and document
builder are ~1.5k lines that would otherwise be copied five times (wrike and analytics
already drifted: only wrike has typed clients). The kit has no dependencies, builds on
Linux, and does not change the link-boundary story because it contains no gateway code.

Dependency pinning: during implementation every consumer uses
`.package(path: "../gateway-sdk-kit")` (relative to the consumer's worktree; see §5).
The switch to a URL + revision pin happens in phase 3 after the operator creates the
GitHub repository `tacogips/gateway-sdk-kit` (operator decision, see §6).

### 2.2 Neutral catalog model (`GatewaySDKKit`)

```swift
public struct GatewaySchemaCatalog: Codable, Sendable, Equatable {
  public var provider: String          // "wrike-gateway", "gmail-gateway", ...
  public var tier: String              // "reader", "writer", "admin", "draft", "sender", "full", ...
  public var operations: [GatewayOperation]
  public var types: [GatewayNamedType] // objects, input objects, enums, scalars (name-keyed)
}

public struct GatewayOperation: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable { case query, mutation, command }
  public var name: String              // GraphQL root field, or "files list" for commands
  public var kind: Kind
  public var tier: String              // the lowest tier that may run it
  public var arguments: [GatewayArgument]
  public var result: GatewayTypeRef?   // nil for commands (documents returns opaque JSON)
  public var summary: String
  public var isDestructive: Bool
  public var domain: String?           // "calendar", "notes", "drive", "gtm" ... for grouping
}

public struct GatewayArgument: Codable, Sendable, Equatable {
  public var name: String              // GraphQL argument name, or flag name without "--"
  public var type: GatewayTypeRef
  public var isRequired: Bool
  public var defaultValue: GatewayJSONValue?
  public var description: String?
}

public indirect enum GatewayTypeRef: Codable, Sendable, Equatable {
  case named(String)
  case list(GatewayTypeRef)
  case nonNull(GatewayTypeRef)
}

public struct GatewayNamedType: Codable, Sendable, Equatable {
  public enum Kind: Codable, Sendable, Equatable {
    case scalar
    case object([GatewayField])
    case inputObject([GatewayArgument])
    case enumeration([String])
  }
  public var name: String
  public var kind: Kind
  public var description: String?
}

public struct GatewayField: Codable, Sendable, Equatable {
  public var name: String
  public var type: GatewayTypeRef
  public var arguments: [GatewayArgument]
  public var description: String?
}
```

Rules:

- Built-in scalars `ID String Int Float Boolean JSON` need no `GatewayNamedType` entry.
- `GatewaySchemaCatalog.validate()` returns problems (unknown type references,
  duplicate names, required argument with default). Every facade has a test asserting an
  empty problem list for every tier.
- `sdl()` prints the catalog as SDL in a stable order (scalars, enums, inputs, objects,
  `type Query`, `type Mutation`). Command catalogs print as `type Command` with one field
  per command for uniformity.

### 2.3 Operation invocation (`GatewayOperationRequest` → document / argv)

```swift
public struct GatewayOperationRequest: Sendable {
  public var operation: String
  public var variables: [String: GatewayJSONValue]
  public var selection: GatewaySelection   // .default, .fields([String]), .raw(String)
}

public enum GatewaySelection: Sendable, Equatable {
  case `default`            // generated from the result type, see below
  case fields([String])     // dot paths: ["id", "subject", "messages.from.address"]
  case raw(String)          // a selection set "{ id subject }" used verbatim
}

public struct GatewayDocumentBuilder {
  public init(catalog: GatewaySchemaCatalog)
  public func build(_ request: GatewayOperationRequest) throws -> GatewayBuiltDocument
  // GatewayBuiltDocument { document: String, variables: [String: GatewayJSONValue] }
}
```

- The builder looks the operation up in the catalog, rejects unknown operations and
  unknown / missing-required variables with named errors, declares
  `query Op($accountId: ID!, $first: Int)` from the catalog argument types, emits
  `threads(accountId: $accountId, first: $first)` for the variables that were supplied,
  and appends the selection set. Variables are passed through to the gateway as GraphQL
  variables, never inlined, so gateways keep their own validation.
- **Default selection**: every scalar and enum field of the result object; nested object
  fields recurse up to depth 3; recursion stops at a type already on the current path;
  list-of-object fields recurse the same way. Fields that themselves take required
  arguments are skipped. Result: `threads` yields `totalCount pageInfo {...} edges {
  cursor node { id subject ... messages { ... } } }` without the author listing it.
- `.fields([...])` builds a nested selection from dot paths and validates each path
  against the catalog.
- For `kind == .command` the builder produces argv instead:
  `GatewayArgvBuilder.build(request)` → `["files", "list", "--query", "...", "--page-size", "20"]`.
  Booleans become bare flags when `true`, lists repeat the flag, objects are JSON-encoded.

### 2.4 Schema search

```swift
public struct GatewaySchemaSearch {
  public struct Options: Sendable {
    public var kinds: Set<GatewayDefinitionKind> = [.query, .mutation, .command, .object, .inputObject, .enumeration]
    public var includeReferencedTypes: Bool = false  // pull in argument and result types of matched operations (depth 1)
    public var limit: Int? = nil
  }
  public struct Match: Codable, Sendable, Equatable {
    public var kind: GatewayDefinitionKind
    public var name: String
    public var tier: String?
    public var matchedOn: [String]  // "name", "argument:accountId", "field:subject", "summary"
    public var sdl: String          // the SDL fragment of exactly this definition
  }
  public init(catalog: GatewaySchemaCatalog)
  public func search(_ pattern: String, options: Options = .init()) throws -> [Match]
}
```

The pattern is a Swift `Regex` (`try Regex(pattern)`), matched against the definition
name, its argument / field names, and its summary. Results are ordered: exact-name
matches first, then by kind (query, mutation, command, object, inputObject, enum), then
by name. `includeReferencedTypes` appends the input and result types of matched
operations that are not already present.

### 2.5 The `GatewaySDK` protocol and envelope

```swift
public struct GatewayEnvelope: Sendable, Equatable {
  public var data: GatewayJSONValue?
  public var errors: [GatewayEnvelopeError]  // { message, code?, path? }
  public var requestId: String?
  public var exitCode: Int32
  public var rawOutput: String               // exactly what the CLI would have printed
}

public protocol GatewaySDK: Sendable {
  var provider: String { get }                                    // "wrike-gateway", ...
  var tier: String { get }                                        // "reader", "writer", "admin", "draft", "sender", "full", ...
  var catalog: GatewaySchemaCatalog { get }                       // static per (provider, tier); no credentials needed
  func execute(document: String, variables: [String: GatewayJSONValue], environment: [String: String]) async -> GatewayEnvelope
  func invoke(_ request: GatewayOperationRequest, environment: [String: String]) async -> GatewayEnvelope  // default: build + execute
  func schemaSDL() -> String                                       // default: catalog.sdl()
  func searchSchema(_ pattern: String, options: GatewaySchemaSearch.Options) throws -> [GatewaySchemaSearch.Match]  // default
}
```

The protocol deliberately has no associated type and no static catalog requirement:
tiered gateways (wrike, analytics) keep their capability definitions in per-tier
modules behind link boundaries, so the facade is constructed by the tier module
(`WrikeGatewaySDK.reader(environment:)` lives in `WrikeGatewayRead`, `.writer` in
`WrikeGatewayWrite`, `.admin` in `WrikeGatewayAdmin`) and carries its catalog as an
instance value.

`environment` is the only environment the call may observe (the per-call environment
pattern riela already relies on). Command-style gateways implement `execute` by treating
`document` as a JSON-encoded argv array and returning an `unsupported` envelope for
GraphQL text; their `invoke` goes through `GatewayArgvBuilder`.

## 3. Per-gateway work

Each of these is one riela run in that repo's own worktree. Common acceptance criteria
for every gateway:

- `swift build` and `swift test` green (run from the repo root in an arm64 shell:
  `arch -arm64 /bin/zsh -lc '...'`), swiftlint clean, existing link-boundary tests
  unchanged in intent.
- A `<Name>GatewaySDK` facade conforming to `GatewaySDK`, public, documented in README.
- Catalog parity test: for every tier, the set of catalog operation names equals the set
  of root fields the runtime actually dispatches for that tier (and, where the gateway has
  its own SDL printer, the root fields of that SDL). Both directions.
- Default-selection test: `invoke` with `.default` selection produces a document the
  runtime accepts for at least one query and one mutation per tier (using the existing
  recording / loopback transports).
- `graphql schema` (or `schema print`) keeps working; a new `schema search <regex>
  [--kinds ...] [--include-referenced-types]` CLI subcommand prints matches as JSON.
- Passthrough behaviour (`graphql query <doc> --variables <json>`) unchanged.

### 3.1 wrike-gateway

- Add `WrikeGatewaySDK(tier: .reader | .writer | .admin, definitions: [CapabilityDefinition]? = nil, environment:)`.
- Catalog export: `CapabilityDefinition` → `GatewayOperation` (`field`, `operationClass`
  → kind, `tier`, `arguments` via `ArgumentValueType` → `GatewayTypeRef`, `result:
  ResultShape` → object types, `summary`, `isDestructive`); `InputObjectShape` → input
  types; enumerations → enum types. Reuse the shape knowledge already in
  `GraphQLSchemaPrinter` (the printer and the exporter must agree; test by comparing root
  fields of `printedSchema()` with `catalog.sdl()`).
- `execute` calls `GraphQLRuntime.execute(document:variables:)` directly through a new
  `GatewayComposition.makeRuntime(role:definitions:environment:)`; no argv round trip.
  `WrikeValue` ⇄ `GatewayJSONValue` conversion helpers.
- Keep `WrikeReadClient` / `WriteClient` / `AdminClient` untouched.

### 3.2 google-analytics-gateway

Same as wrike (it is the same design). Also fix the delta problem riela hit: expose
`ReadCapabilities.all + WriteCapabilities.all` as `WriteCapabilities.cumulative` (and
admin likewise) so a writer SDK sees the read fields, matching the writer binary.

### 3.3 apple-gateway

- Add `AppleGatewaySDK(role: .full | .reader, environment:, ...)` in `AppleGatewayCore`
  that composes the same `GraphQLExecutionContext` `AppleGatewayCommand` builds (config
  loading, permissions provider, services) and calls `GraphQLRuntime.executeResponse`
  directly. Keep `GraphQLRuntime` internal; the facade is the public surface.
- Catalog export from `GraphQLSchemaRegistry.bootstrap(role:)`: `GraphQLNamedTypeKind`
  and `GraphQLFieldDefinition` map 1:1 onto the neutral model; `domain` comes from the
  module (`calendar`, `reminders`, `notes`, `mail`, `notifications`, `clockAlarms`,
  `phoneCalls`, `permissions`).
- `schema print` stays; add `schema search`.

### 3.4 gmail-gateway (largest change)

1. **Declare the schema.** New `GmailGatewaySchema.swift` building a
   `GatewaySchemaCatalog` per `GmailGatewayCLIMode` from one full declaration:
   the reader queries (`accounts account threads thread message messageFileSet attachment
   labels profile`), draft queries (`drafts draft`), draft mutations (5), send mutations
   (4), mailbox mutations (13), ingest mutations (2), with the input / payload / object
   types from `design-docs/specs/design-gmail-gateway.md` and the argument names the
   scanner actually reads (`GmailGatewayGraphQLArguments.swift`). Per-mode filtering must
   reproduce the rejection tables exactly (reader: no drafts/mutations; draft: +drafts,
   +draft mutations; sender: +send mutations; threads: +mailbox mutations; message-box:
   +ingest). A parity test asserts catalog names per mode == the existing
   `*RootFields` arrays plus the reader list, both directions.
2. **Variables.** Delete `rejectUnsupportedVariables`; wire `loadVariables` into the
   `graphql` path. Before `prepareGraphQLQuery`, run the kit's
   `GraphQLVariableInliner(catalog:)`: it tokenizes the document (strings, block strings,
   comments, punctuators, names, `$vars`), reads the operation's variable definitions,
   validates declared-but-unused / used-but-undeclared / required-but-null / unknown
   supplied variables against the declared types (same rules as wrike), then rewrites the
   document with the JSON values rendered as GraphQL literals (strings escaped, lists,
   input objects, enums rendered bare when the declared type is an enum). The rewritten
   document has no variable definitions and flows into the unchanged scanner. Because the
   inliner is token-aware, `$` inside string literals is never touched.
3. **Facade.** `GmailGatewaySDK(mode:, authPolicy: .legacy, ...)` whose `execute` calls
   the existing dispatch (`executeReaderGraphQL` etc.) via a new internal
   `GmailGatewayGraphQLExecutor.run(query:variables:mode:environment:)` shared with the
   CLI, returning the same envelope the CLI prints. Do not touch the persistent-auth WIP
   files; the facade uses the `.legacy` policy exactly like `run(arguments:environment:)`.
4. **CLI.** `graphql --query ... --variables <json> | --variables-file <path>` now works in
   every mode; new `graphql schema` and `schema search` subcommands; help text updated.
5. `GmailGatewayService` and friends stay as they are.

### 3.5 google-documents-gateway

- Declare a command catalog: for every command in `GatewayCapabilityCatalog.commands(for:)`
  an entry with its flags (name, type, required) taken from `GatewayRequestBuilder`
  (`--document-id`, `--range`, `--values`, `--page-size`, confirm flags, …). Test: every
  command has an entry, every declared flag is accepted by `--dry-run`, and every flag the
  builder reads for that command is declared (grep-free: drive it through
  `GatewayRequestBuilder.plan` with a fixture per command).
- `GoogleDocumentsGatewaySDK(role:, environment:)`: `invoke` → argv → `GatewayCommandRunner.run`;
  `execute(document:)` accepts a JSON argv array in `document` for passthrough.
- `schema search` subcommand over the command catalog; `--help` unchanged.

## 4. riela integration (one run in riela)

1. **Package.swift**: add `gateway-sdk-kit` (unconditional; pure Swift) and bump the five
   gateway pins to the branch revisions produced by §3 (phase 3 replaces path pins with
   URL pins).
2. **Generic engine.** Replace `LocalGatewayGraphQLDescriptor.run` (a document runner)
   with an SDK-backed descriptor:
   ```swift
   struct LocalGatewaySDKDescriptor {
     var providerName: String; var payloadNamespaceKey: String; var tier: String
     var isAllowedEnvironmentTarget: (String) -> Bool
     var catalog: @Sendable () -> GatewaySchemaCatalog
     var execute: @Sendable (_ document: String, _ variables: [String: GatewayJSONValue], _ env: [String: String]) async throws -> GatewayEnvelope
     var invoke:  @Sendable (_ request: GatewayOperationRequest, _ env: [String: String]) async throws -> GatewayEnvelope
   }
   ```
   `LocalGatewayGraphQLEngine` becomes `LocalGatewayOperationEngine` and accepts two
   mutually exclusive config shapes:
   - **passthrough** (unchanged): `queryTemplate` (+ `variablesTemplate`, now accepted for
     gmail too — drop `acceptsVariables`);
   - **operation**: `operation` (string), `arguments` (object; rendered with
     `renderJSONTemplates`, so `{{path}}` exact templates keep their JSON type and nested
     literals stay typed), optional `selection` (array of dot paths or a raw selection
     string).
   Everything after the envelope (`selectFirst`, `whenFlags`, `payloadExtras`,
   `nowVariables`, `requestId`, `replyText`) is shared by both shapes. The payload gains
   `<namespace>.operation` and `<namespace>.document` (the built document) so runs record
   what was sent.
3. **Add-on wiring.** wrike / analytics / gmail add-ons switch their descriptors to the
   SDK facades. google-documents add-ons gain the same `operation` + `arguments` shape via
   `GoogleDocumentsGatewaySDK` while keeping `command` + `argsTemplate` as passthrough.
   The apple families keep their bespoke add-ons; `riela/apple-gateway-graphql` gains
   `operation` mode through `AppleGatewaySDK`, and `riela/apple-gateway-schema` gains
   `pattern` / `kinds` / `includeReferencedTypes`.
4. **New add-on `riela/gateway-schema`** (`version 1`): config `gateway` (one of
   `wrike-gateway`, `google-analytics-gateway`, `gmail-gateway`, `google-documents-gateway`,
   `apple-gateway`), `tier`, optional `pattern`, `kinds`, `includeReferencedTypes`, `limit`.
   Payload: `{ status, gateway, tier, sdl? (when no pattern), matches: [...], count }`.
   Needs no credentials and no network; usable in mock runs.
5. **CLI**: `riela addon schema <gateway> --tier <tier> [--grep <regex>] [--kinds ...]
   [--include-referenced-types] [--output json|sdl]` for operators and agents authoring
   workflows.
6. **Validation**: add validate-time checks for these add-ons (`operation` xor
   `queryTemplate` / `command`, `selection` shape, known `gateway` / `tier` for
   `riela/gateway-schema`). Operation-name existence is checked at validate time against
   the catalog too, since catalogs are static and credential-free.
7. **Tests**: extend the existing add-on test files with operation-mode cases through the
   recording runner seams (`localGatewayGraphQLRunner` becomes an SDK stand-in that
   records document + variables); gmail variables case; `riela/gateway-schema` tests;
   validation tests.
8. **Examples**: `examples/gmail-operation-thread-digest` (operation mode, gmail
   reader, mock scenario), `examples/gateway-schema-lookup` (schema search feeding an
   agent prompt, mock). Register both in `rielaExampleWorkflowNames()` and bump
   `expectedMockScenarioCount`. Update `examples/wrike-project-kanban-agent` to use
   operation mode for at least one node.
9. **Docs**: README "Local Gateway Add-ons" rewritten around the two config shapes;
   per-gateway operation tables link to `riela addon schema`; note that gmail now accepts
   `variablesTemplate`.

## 5. Execution plan

Every run: isolated `git worktree add -b <branch>` off the committed HEAD, brief committed
on that branch first, `env -u ANTHROPIC_API_KEY <riela-repo>/.build/release/riela workflow
run fable-and-improve-opus --scope user --variables "$(cat vars.json)" --max-steps 80
--default-timeout-ms 10800000 --output jsonl`, the one-feature clause in
`requestedOutcome` and `constraints`.

| Phase | Repo / worktree | Branch | Depends on |
|---|---|---|---|
| 0 | `gateway-sdk-kit` (new local repo) | `main` | – |
| 1a | wrike-gateway | `feat/gateway-sdk` | 0 |
| 1b | google-analytics-gateway | `feat/gateway-sdk` | 0 |
| 1c | apple-gateway | `feat/gateway-sdk` | 0 |
| 1d | gmail-gateway (worktree off `2761f3b`) | `feat/gateway-sdk-variables` | 0 |
| 1e | google-documents-gateway | `feat/gateway-sdk` | 0 |
| 2 | riela | `feat/gateway-sdk-addons` | 1a–1e |
| 3 | all | – | operator creates `tacogips/gateway-sdk-kit`; switch path pins to URL pins; push branches; PRs |

Phase 1 runs execute in parallel (five worktrees, five riela sessions).

## 6. Open items for the operator

- Creation of the public GitHub repository `tacogips/gateway-sdk-kit` (needed only for
  the URL pins in phase 3; everything before that uses path dependencies).
- gmail-gateway: the persistent-auth WIP in the main checkout stays untouched; merging
  `feat/gateway-sdk-variables` into that WIP is the operator's call.
