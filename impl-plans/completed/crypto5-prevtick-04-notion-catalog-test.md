# c5pt-04-notion-catalog-test: findChildPage / ensurePagePath through the catalog

```json
{
  "planId": "c5pt-04-notion-catalog-test",
  "planPath": "impl-plans/active/crypto5-prevtick-04-notion-catalog-test.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Tests/RielaCLITests/NotionGatewayAddonTests.swift",
    "impl-plans/progress/c5pt-04-notion-catalog-test.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

The owner requires the following (design §1.4):

- `riela/notion-gateway-write` JSON mode accepts
  `operation: "ensurePagePath"`.
- Both roles accept `findChildPage`, driven by the catalog.

notion-gateway v0.1.6 (`0f16afb3`, pinned by c5pt-01) provides both
operations.

Riela is already catalog-driven:

- `Sources/RielaCLI/ProductionNodeAdapter+NotionGatewayAddons.swift:16-19`
  uses `NotionGatewaySDK(role:).catalog` as the operation catalog.
- `Sources/RielaCLI/BuiltinGatewayRequestChecks.swift` validates JSON mode
  against that catalog.

So **no production code changes**. This plan only adds a focused test. The
docs are owned by c5pt-05.

## Before writing the test

Read the real argument names and types of both operations from the bumped
catalog:

```
arch -arm64 /bin/zsh -lc '.build/debug/riela gateway notion --role writer schema'
arch -arm64 /bin/zsh -lc '.build/debug/riela gateway notion --role reader schema'
```

If the binary is stale, run `swift build` first. Save the output to
`tmp/crypto5-prevtick/c5pt-04-notion-catalog-test/schema-*.log`. Use only
argument names that the schema shows, and record them in the progress log.

Expected catalog, read from
`.build/checkouts/notion-gateway/Sources/NotionGatewayCore/NotionCatalog.swift:29-43`
at the pinned `0f16afb3`. The schema logs are authoritative if they differ.

- `findChildPage(parentId: ID!, title: String!)` is a query, so it is in
  the `reader` tier. The writer catalog is `reads + writes`, so it is in
  both roles.
- `ensurePagePath(parentId: ID!, titles: [String!]!, children: JSON, markdown: String)`
  is a mutation, so it is writer only.
- Both return the `JSON` scalar, so leave `selection` unset (the default).
- Pitfall: `titles` is a list. Pass it as a JSON array of strings, for
  example `["Inbox", "2026"]`, not as a single string.

Continuation note (session 519): c5pt-01 has already landed, so this plan
runs in wave 1. Its only Swift write is this test file.

## Test cases (add to `Tests/RielaCLITests/NotionGatewayAddonTests.swift`)

Patterns to imitate:

- JSON mode with a recorder: `BuiltinGatewayJSONBehaviorTests.swift:61-90`.
  It sets `config["operation"]` and `config["arguments"]`, and passes a
  `RecordingGatewayGraphQLRunner` response.
- The `#if os(macOS)` schema checks in
  `testLinkedReaderRejectsMutationWithoutCredentialsOrNetwork`.
- Credential binding: the
  `env: ["NOTION_API_KEY": .object(["fromEnv": .string("BOUND_NOTION")])]`
  pattern from `testPinnedRoleVariablesAndOnlyExplicitCredentialBinding`.

Cases:

1. Writer JSON mode, `operation: "ensurePagePath"` with schema-valid
   `arguments`, and a recorder returning a synthetic
   `{"data":{"ensurePagePath":{…}}}`. Expected:
   - exactly 1 recorder call, with `tier == "writer"`;
   - the generated document, read from the recorder call's query/document
     property (check `RecordingGatewayGraphQLRunner` for the exact field
     name), contains `ensurePagePath(`.
2. Reader JSON mode, `operation: "findChildPage"`. Expected: 1 call with
   `tier == "reader"`, and the document contains `findChildPage(`.
3. Writer JSON mode, `operation: "findChildPage"`. Expected: 1 call with
   `tier == "writer"`.
4. Reader JSON mode, `operation: "ensurePagePath"`. Expected: it throws
   `AdapterExecutionError` before dispatch, and the recorder has 0 calls.
   The reader catalog contains only reads. If the reader schema log
   unexpectedly lists `ensurePagePath`, record that in the progress log and
   drop this case instead of inventing behavior.

If case 1 fails with "JSON operation does not match its gateway tier
catalog" even though the arguments are schema-valid, list arguments are being
rejected inside Riela's JSON-mode path
(`Sources/RielaCLI/BuiltinGatewayJSONRequest.swift`). Do not edit that file.
Log `outOfScope: Sources/RielaCLI/BuiltinGatewayJSONRequest.swift — list
argument rejected` and mark the plan `blocked`.
5. macOS schema checks:
   - the writer `schema` stdout contains `ensurePagePath` and
     `findChildPage`;
   - the reader `schema` stdout contains `findChildPage`.

Upstream contradiction: if the reader schema lacks `findChildPage`, do not
patch the Riela catalog. Mark the plan
`blocked: upstream-reader-catalog-missing-findChildPage` and attach the schema
log (design §1.4).

## Non-goals and pitfalls

- Do not touch any `Sources/` file. In particular, do not add operation names
  to `BuiltinGatewayRequestChecks.swift` or
  `WorkflowGatewayAddonValidation.swift`.
- No network and no real credentials. Use `"synthetic-token"` env values only.
- Keep the existing tests unchanged.

## Verification (commands → required evidence)

```
arch -arm64 /bin/zsh -lc "swift test --filter 'NotionGatewayAddonTests|BuiltinGatewayJSONBehaviorTests' > tmp/crypto5-prevtick/c5pt-04-notion-catalog-test/test.log 2>&1; echo exit=\$?"
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache Tests/RielaCLITests/NotionGatewayAddonTests.swift > tmp/crypto5-prevtick/c5pt-04-notion-catalog-test/lint.log 2>&1; echo exit=$?'
```

Required results: test `exit=0`, `testsRun > 0`, `failureCount 0`, with the
new test names listed as passed. Lint `exit=0`.

## Done criteria

- `git diff --stat` touches only `Tests/RielaCLITests/NotionGatewayAddonTests.swift`
  and the progress log.
- `grep -c 'ensurePagePath\|findChildPage' Tests/RielaCLITests/NotionGatewayAddonTests.swift`
  is at least 5.
