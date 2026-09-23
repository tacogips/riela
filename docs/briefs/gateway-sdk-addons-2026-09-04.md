# Brief: operation-mode gateway add-ons on the gateway client SDKs (2026-09-04)

Master design: `docs/briefs/gateway-sdk-2026-09-04.md` in this checkout (sections 2 and 4
are normative; section 1 lists the riela seams with file:line references verified on
2026-09-04). Treat this whole brief as exactly ONE feature.

## Inputs that already exist (do not modify them)

- `/Users/taco/gits/tacogips/gateway-sdk-kit` — `GatewaySDKKit` (catalog model,
  `GatewaySDK` protocol, `GatewayEnvelope`, `GatewayOperationRequest`, `GatewaySelection`,
  `GatewaySchemaSearch`, `GatewayDocumentBuilder`, `GatewayArgvBuilder`,
  `GraphQLVariableInliner`, `GatewayJSONValue`). Read its README first.
- Five public gateway releases, each with a facade conforming to `GatewaySDK`:
  - `https://github.com/tacogips/wrike-gateway.git` at `0.2.4` — `WrikeGatewaySDK`
    (`.reader()` in `WrikeGatewayRead`, `.writer()` in `WrikeGatewayWrite`, `.admin()` in
    `WrikeGatewayAdmin`)
  - `https://github.com/tacogips/google-analytics-gateway.git` at `0.1.1` —
    `GoogleAnalyticsGatewaySDK` (same tier constructors; writer/admin are cumulative now)
  - `https://github.com/tacogips/apple-gateway.git` at `0.1.7` — `AppleGatewaySDK(role:)`
  - `https://github.com/tacogips/gmail-gateway.git` at `0.1.11` — `GmailGatewaySDK(mode:)`;
    gmail now accepts GraphQL variables
  - `https://github.com/tacogips/google-documents-gateway.git` at `0.3.1` —
    `GoogleDocumentsGatewaySDK(role:)` (command catalog; `execute` takes a JSON argv array)

## Goal

riela's gateway add-ons gain an **operation mode** (`config.operation` + `config.arguments`
+ optional `config.selection`) next to the existing passthrough mode
(`config.queryTemplate` + `config.variablesTemplate`, or `command` + `argsTemplate` for
google-documents), gmail accepts `variablesTemplate`, a new credential-free
`riela/gateway-schema` add-on and a `riela addon schema` CLI expose SDL and regex search,
and workflow validation checks the new config shapes against the static catalogs.

## Deliverables

1. **Package.swift.** Add `GatewaySDKKit` from `.package(url: "https://github.com/tacogips/gateway-sdk-kit.git", exact: "0.1.0")`
   as a dependency of `RielaCLI` (unconditional; pure Swift). Consume the five gateway
   repositories from their public GitHub URLs at the exact versions listed above. Keep
   the same product names and macOS-only conditions. Bump nothing else in this feature.
2. **Generic engine.** In `Sources/RielaCLI/ProductionNodeAdapter+LocalGatewaySupport.swift`
   replace `LocalGatewayGraphQLDescriptor.run` / `LocalGatewayGraphQLRunner` with an
   SDK-backed descriptor and rename the engine:
   ```swift
   struct LocalGatewaySDKDescriptor {
     var providerName: String
     var payloadNamespaceKey: String
     var tier: String
     var isAllowedEnvironmentTarget: (String) -> Bool
     var catalog: @Sendable () -> GatewaySchemaCatalog
     var execute: @Sendable (_ document: String, _ variables: [String: GatewayJSONValue], _ environment: [String: String]) async throws -> GatewayEnvelope
     var invoke:  @Sendable (_ request: GatewayOperationRequest, _ environment: [String: String]) async throws -> GatewayEnvelope
   }
   struct LocalGatewayOperationEngine { ... }   // was LocalGatewayGraphQLEngine
   ```
   Config shapes (exactly one of the two, else `policyBlocked`):
   - passthrough: `queryTemplate` (+ optional `variablesTemplate`, now allowed for every
     provider; delete `acceptsVariables`);
   - operation: `operation` (string), `arguments` (object rendered with
     `renderJSONTemplates` so exact `{{path}}` templates keep their JSON type; converted
     to `[String: GatewayJSONValue]`), optional `selection` (array of dot-path strings →
     `.fields`, or a string starting with `{` → `.raw`; absent → `.default`).
   Everything after the envelope (`selectFirst`, `whenFlags`, `payloadExtras`,
   `nowVariables`, `requestId`, `replyText`, `<namespace>.tier`) is shared. The payload
   gains `<namespace>.mode` (`passthrough` | `operation`), `<namespace>.operation` and
   `<namespace>.document` (the document or argv actually sent) so runs record what ran.
   Envelope errors map to `providerError` as today; builder errors (unknown operation,
   missing required variable, invalid selection) map to `policyBlocked` with the kit's
   message. Deadline handling (`localGatewayRunWithDeadline`) unchanged.
3. **Add-on wiring.**
   - `ProductionNodeAdapter+WrikeGatewayAddons.swift`,
     `+GoogleAnalyticsGatewayAddons.swift`, `+GmailGatewayCLIAddons.swift`: descriptors
     built from the facades (`WrikeGatewaySDK.reader()` etc., `GmailGatewaySDK(mode:)`);
     env allowlists unchanged; the `#if canImport` / "requires macOS" fallbacks unchanged.
   - `ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift`: keep `command` +
     `argsTemplate` as passthrough and add `operation` + `arguments` via
     `GoogleDocumentsGatewaySDK` (argv from `GatewayArgvBuilder`); the `auth login` /
     `auth revoke` refusal applies to both modes.
   - `ProductionNodeAdapter+AppleGatewayAdminAddons.swift`: `riela/apple-gateway-graphql`
     gains operation mode through `AppleGatewaySDK`; `riela/apple-gateway-schema` gains
     `pattern`, `kinds`, `includeReferencedTypes`, `limit` (matches in the payload; SDL
     when no pattern). The other apple families stay as they are.
   - The resolver test seam `localGatewayGraphQLRunner` becomes `localGatewaySDKStandIn`
     (records document/argv + variables, or the `GatewayOperationRequest`, and returns a
     canned envelope); update `Tests/RielaCLITests/LocalGatewayAddonTestSupport.swift`.
4. **New add-on `riela/gateway-schema`** (`version "1"`, registered in
   `Sources/RielaAddons/RielaAddons.swift` and dispatched in
   `BuiltinWorkflowAddonResolver.execute`): config `gateway` (one of `wrike-gateway`,
   `google-analytics-gateway`, `gmail-gateway`, `google-documents-gateway`,
   `apple-gateway`), `tier` (the provider's tier strings; for google-documents
   `docs-read` … `drive-write`; for apple `full` / `reader`), optional `pattern`, `kinds`
   (array), `includeReferencedTypes`, `limit`. Payload `{ status, addon, stepId, gateway,
   tier, sdl (only when no pattern), matches: [{kind, name, tier, matchedOn, sdl}], count,
   replyText }`. No credentials, no network, works in mock runs and on Linux (catalogs
   are static; behind `#if canImport` the add-on returns `policyBlocked` "requires macOS"
   like the others).
5. **CLI.** `riela addon schema <gateway> --tier <tier> [--grep <regex>] [--kinds a,b]
   [--include-referenced-types] [--limit N] [--output json|sdl]` (new `addon` command
   group in `Sources/RielaCLI`, or under the existing command that lists add-ons if one
   exists; follow the repo's ArgumentParser conventions). `--output sdl` prints SDL (or
   the matched fragments); `json` prints the `riela/gateway-schema` payload.
6. **Validation.** At `riela workflow validate` time (`Sources/RielaCore/WorkflowNodeValidation.swift`
   / a new `WorkflowGatewayAddonValidation.swift`): for the gateway add-on names, exactly
   one of `queryTemplate` / `operation` (or `command` / `operation` for google-documents);
   `selection` shape; `arguments` must be an object; for `riela/gateway-schema` known
   `gateway` and `tier`; and, when the platform can load the catalogs, `operation` must
   exist in that add-on's catalog (diagnostic message lists the closest names). Keep the
   validation in RielaCore free of gateway imports: RielaCLI injects a catalog lookup
   closure (`WorkflowValidationContext.gatewayCatalog: (gateway, tier) -> GatewaySchemaCatalog?`)
   and the pure-shape checks run everywhere.
7. **Tests** (`Tests/RielaCLITests/*GatewayAddonTests.swift`, `Tests/RielaAddonsTests`):
   operation mode for wrike (query with variables, mutation with input object, `.fields`
   selection), analytics, gmail (variables now pass through; a `variablesTemplate`
   passthrough case), google-documents (argv built from `arguments`; confirm flag), apple
   passthrough add-on operation mode; the two-shape exclusivity error; builder errors →
   `policyBlocked`; `riela/gateway-schema` with and without pattern; validation tests for
   item 6; catalog contract test in `AddonExecutionContractsTests` for the new add-on.
8. **Examples.** `examples/gmail-operation-thread-digest` (gmail reader operation mode
   `threads` with `arguments` from workflow input, `selection` on subject/from, a mocked
   LLM summary step; mock scenario), `examples/gateway-schema-lookup`
   (`riela/gateway-schema` search for `(?i)draft` on gmail draft tier feeding a mocked
   agent prompt; mock scenario). Convert one node of `examples/wrike-project-kanban-agent`
   to operation mode. Register the two new examples in
   `Tests/RielaCLITests/RielaExampleCatalog.swift` `rielaExampleWorkflowNames()`
   (alphabetical) and bump `expectedMockScenarioCount` in
   `Tests/RielaCLITests/RielaExampleParityTests.swift` by the number of new mock scenario
   files. Each example gets a README and EXPECTED_RESULTS.md like its neighbours.
9. **Docs.** `README.md` "Local Gateway Add-ons" and "Apple Gateway Add-Ons": describe the
   two config shapes with one example each, `riela/gateway-schema`, `riela addon schema`,
   and that gmail accepts `variablesTemplate` now. `.agents/skills/riela-node-addons`
   (if present in this checkout) gets the same summary.

## Verification

In an arm64 shell (`arch -arm64 /bin/zsh -lc '...'`), from this worktree root:
`swift build -c release` and
`swift test --filter 'WrikeGatewayAddonTests|GmailGatewayAddonTests|GoogleAnalyticsGatewayAddonTests|GoogleDocumentsGatewayAddonTests|AppleGatewayAdminAddonTests|AddonExecutionContractsTests|RielaExampleParityTests|WorkflowValidation'`
green, then the full `swift test` (known flake: the interleaved-submit timing test).
Also `.build/release/riela workflow run gmail-operation-thread-digest --mock-scenario
<name> --output jsonl` and the same for `gateway-schema-lookup` succeed, and
`.build/release/riela addon schema gmail-gateway --tier draft --grep '(?i)draft'` prints
matches. Commit on `feat/gateway-sdk-addons` as work lands; do not push.

## Non-goals

No change to the apple calendar / notes / mail / reminders / clock families beyond what
is listed, no container add-on changes (`riela/gmail-gateway-read` container add-on stays),
no google-service-gateway changes, no release. Do not modify the gateway worktrees or the
kit. Do not touch `/Users/taco/gits/tacogips/riela` (the main checkout).
