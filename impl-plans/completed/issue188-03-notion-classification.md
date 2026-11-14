# Issue 188 Plan 03: Notion failure classification (effectOutcome / retryability)

**Status**: Completed (2026-11-10; accepted by step7 adversarial review comm-000095 and combined-tree integration, issue #188)
**planId**: issue188-03-notion-classification
**dependsOn**: issue188-01-core-contract (needs `AdapterEffectOutcome`, `AdapterExecutionError.effectOutcome`)
**Design Reference**: design-docs/specs/design-step-deadline-and-retry-policy.md §4.1, §4.2, §8, §10 cases 6, 6a, 6b, 6c, 7, 8
**Issue**: tacogips/riela#188
**Created**: 2026-11-10
**Last Updated**: 2026-11-10

## Intent and context

The step supervisor (plan 04) retries only when an error has `isRetryable == true` and an `effectOutcome` other than `.unknown`. Today, Notion add-on failures become unclassified errors such as `AdapterExecutionError(.providerError, "<addon> GraphQL errors: ...")`; see `Sources/RielaCLI/ProductionNodeAdapter+LocalGatewaySupport.swift`, `LocalGatewayGraphQLEngine.execute` (around line 153) and `notionUploadCall` (around line 667).

This plan makes Notion errors carry `isRetryable`, `retryAfter` and `effectOutcome`, following the design's **ordered precedence**. It keeps today's message text byte-identical.

The notion-gateway at the pinned revision 41f64e6 reports failures in its GraphQL error envelope:
- `errors[].code`: a Notion API code such as `rate_limited`, `conflict_error`, `validation_error`, or a gateway code such as `TRANSPORT`, `CANCELLED`, `INVALID_RESPONSE`, `INVALID_ARGUMENT`, `AUTHENTICATION_REQUIRED`, `CAPABILITY_DENIED`, `RESPONSE_TOO_LARGE`.
- `errors[].extensions.httpStatus`.
- `errors[].message`, ending with `[notionDiagnostics mutationOutcome=<notDispatched|rejected|unknown> retryAfterSeconds=<n>]`. Either field can be absent.

## Non-goals

- No change to notion-gateway, and no pin bump.
- No reconciliation, and no idempotency keys.
- No change to other gateways (gmail, X, Wrike, and so on).
- No change to `GatewayFailureDiagnostics.swift`.
- Do not alter `localGatewayRunWithDeadline` itself; other gateways use it. Add a Notion-only wrapper.
- No runner/core edits.
- Do not edit `Tests/RielaCLITests/LocalGatewayAddonTestSupport.swift`. Use its existing `RecordingGatewayGraphQLRunner(responses:)` sequencing as is.

## File-level changes

### Sources/RielaCLI/NotionGatewayFailureClassification.swift (new)

Pinned internal API:

```swift
enum NotionGatewayFailureClassifier {
  /// Classifies a failed envelope. `message` is the exact text today's code would have used.
  static func classify(stdout: String, isMutation: Bool, message: String) -> AdapterExecutionError
  /// Fail-safe: writer tier defaults to mutation. See "isMutation (fail-safe)".
  static func isMutation(tier: String, operationKind: GatewayDefinitionKind?, isJSONOperationMode: Bool,
                         document: String) -> Bool
}
func notionRunWithDeadline(deadline: Date?, addonName: String, isMutation: Bool,
  operation: @escaping @Sendable () async throws -> String) async throws -> String
```

- **Parsing.** Decode stdout as `JSONValue`. Read `errors[]` objects, up to 16. From each one take:
  - `code`;
  - `extensions.httpStatus`, an integer in 100...599;
  - from `message`, the bracketed `notionDiagnostics` tokens `mutationOutcome=` and `retryAfterSeconds=` (an integer in 0...86400).

  If any error has `mutationOutcome=unknown`, the whole failure is `unknown`, because unknown wins. Otherwise classify by the first error.
- **Fail-safe override (rule 0, checked before everything else).** If any parsed error carries `mutationOutcome=unknown`, return `effectOutcome=.unknown` with `isRetryable=false`, **regardless of `isMutation`**. The read rules never see such an error, so an explicit unknown can never be downgraded.
- **isMutation (fail-safe).**
  - Tier `reader` → always `false`. The reader catalog has no mutations.
  - Tier `writer`, JSON-operation mode (`config["operation"]` set): use the kind from `descriptor.catalog`'s `operation(named:)`. `.mutation` → true. A **failed lookup or a nil catalog → true**. Only a positively identified query → false.
  - Tier `writer`, raw document mode: strip leading whitespace and every leading line that starts with `#` (a GraphQL comment). The document is a read **only** if what remains starts with `query` or `{`. Anything else is a mutation, including `mutation`, an empty document, or unknown text.
  - Use the same `isMutation` value for `classify` and for `notionRunWithDeadline`'s started-timeout branch.
  - Paths inside `publishPage` and `uploadLocalFile` are mutations except the `blockChildren` / `findChildPage` lookup documents. Those are reads only when they pass the raw-document rule above.
  - The kind enum is `GatewayDefinitionKind` (`.build/checkouts/gateway-sdk-kit/Sources/GatewaySDKKit/GatewayCatalogModel.swift:4`; its cases include `query`, `mutation` and `command`). Only `.query` counts as a positively identified read. Every other kind, including `.command`, is a mutation.
- **Write precedence**, used when `isMutation` is true and rule 0 did not apply. The first matching rule wins:
  1. `mutationOutcome == unknown` → `effectOutcome=.unknown`, `isRetryable=false`. This applies regardless of status or code, **including 429 and 409**.
  2. No parseable `mutationOutcome`, including stdout that is not JSON → `.unknown`, `false`.
  3. `rejected`:
     - status 429 or code `rate_limited` → `.rejected`, retryable, `retryAfter = .seconds(retryAfterSeconds)` when present;
     - status 409 or code `conflict_error` → `.rejected`, retryable;
     - anything else → `.rejected`, not retryable.
  4. `notDispatched` → `.notDispatched`, not retryable.
- **Reads** (`isMutation == false`, and rule 0 did not apply): `effectOutcome=nil`.
  - Retryable: status 429, 409, 408 or 500...599, or code `TRANSPORT` / `INVALID_RESPONSE`. Keep `retryAfter`.
  - Not retryable: everything else.
- The returned error is `AdapterExecutionError(.providerError, message, isRetryable:, retryAfter:, effectOutcome:)`. `message` is passed in unchanged.
- **`notionRunWithDeadline`** wraps `localGatewayRunWithDeadline`. It sets a lock-protected `started` flag as the first statement inside the operation closure. When the wrapped call throws `AdapterExecutionError` with `code == .timeout`:
  - `!started` → rethrow the same code and message with `effectOutcome=.notDispatched`, `isRetryable=true`.
  - `started`, mutation → `.unknown`, `false`.
  - `started`, read → `isRetryable=true`, `effectOutcome=nil`.
  - In every case, keep `code == .timeout` and the message.

### Sources/RielaCLI/ProductionNodeAdapter+LocalGatewaySupport.swift
- **`LocalGatewayGraphQLEngine.execute`**, only when `descriptor.providerName == "notion-gateway"`:
  - Compute `isMutation` with `NotionGatewayFailureClassifier.isMutation(tier: descriptor.tier, ...)`, following the fail-safe rules above.
  - Use `notionRunWithDeadline` instead of `localGatewayRunWithDeadline`.
  - On `!envelope.errors.isEmpty`, throw `classify(stdout:isMutation:message:)` with the **same** message string the current code builds.
  - Gmail and every other provider take the unchanged path.
- **`notionUploadCall`**: same treatment. It is always called with tier `"writer"`, so compute `isMutation` with `isMutation(tier: "writer", operationKind: nil, isJSONOperationMode: false, document:)`.
- **`executeNotionPublishPage`**:
  - Add a local `var nonIdempotentSucceeded = false`. Set it to true after a successful `createPage` call and after **each** successful `appendBlocks` call: in the existing-page loop, the new-page chunk loop, and the deferred-children loop.
  - Do **not** set it after `ensurePagePath` or after upload calls.
  - In the existing `catch` at the end:
    - when `pageId == nil`, rethrow the original error unchanged (its classification is preserved);
    - when building `publishPage incomplete: {...}`, take `isRetryable`, `retryAfter` and `effectOutcome` from the underlying `AdapterExecutionError` if `nonIdempotentSucceeded == false`. Otherwise set `effectOutcome=.unknown`, `isRetryable=false`.
    - Message text unchanged.
  - Pitfall: in `pageId` mode `pageId` is non-nil from the start, so the first failing append must keep its own classification, because nothing has been applied yet.
- **`executeNotionLocalFileUpload`** / **`uploadNotionLocalPath`**: classification flows through `notionUploadCall`. Errors that `uploadLocalFile` throws itself (`.invalidOutput`, `.policyBlocked`) stay unclassified, which means not retryable.

### Tests/RielaCLITests/NotionGatewayAddonRetryClassificationTests.swift (new)

Imitate `Tests/RielaCLITests/NotionGatewayAddonTests.swift`, which uses `BuiltinWorkflowAddonResolver(environment:localGatewayGraphQLRunner:)` and `RecordingGatewayGraphQLRunner(responses:)`. Build envelopes such as `{"data":null,"errors":[{"message":"Notion returned HTTP 429 [notionDiagnostics mutationOutcome=rejected retryAfterSeconds=3]","code":"rate_limited","path":["createPage"],"extensions":{"httpStatus":429}}]}`.

## Invariants

- Error `message` text is unchanged for every path. Assert equality with the pre-change string for at least one write case and one read case.
- An explicit `unknown` is never downgraded.
- Non-Notion gateways behave identically.
- No live network: tests only use the runner override.

## Test cases (input → expected)

- **6a** ensurePagePath write, error status 429 with `mutationOutcome=unknown` → `effectOutcome=.unknown`, `isRetryable=false`. Same with 409.
- **6b** single-call `createPage` (JSON operation), 429 with `mutationOutcome=rejected retryAfterSeconds=3` → `.rejected`, retryable, `retryAfter == .seconds(3)`. Same with 409 and no retryAfter.
- **6c** mutation error envelope with no `notionDiagnostics` → `.unknown`, not retryable. Non-JSON stdout on a mutation → `.unknown`.
- **6** 500 with `mutationOutcome=unknown` → unknown. `TRANSPORT` unknown → unknown.
- **6** publishPage (new page): `createPage` succeeds, then the first `appendBlocks` returns 429 `rejected` → error message starts `publishPage incomplete:` and still contains `"pageId"`. `effectOutcome=.unknown`, not retryable.
- publishPage with a `path`: `ensurePagePath` succeeds, then `createPage` returns 429 `rejected` → retryable `.rejected` (exemption). The thrown error is the original classified error, because `pageId == nil`.
- publishPage in `pageId` mode: the first `appendBlocks` returns 429 `rejected` → `publishPage incomplete` with `.rejected`, retryable.
- **7** 400 `validation_error` rejected → not retryable `.rejected`. 401 `unauthorized` → not retryable. `AUTHENTICATION_REQUIRED` notDispatched → not retryable `.notDispatched`.
- **8**-prep: 429 rejected with `retryAfterSeconds=120` → `retryAfter == .seconds(120)`. The supervisor (plan 04) decides the stop.
- Read (`riela/notion-gateway-read` findChildPage): 503 → retryable, `effectOutcome nil`. 404 → not retryable.
- **Fail-safe A**: writer raw `queryTemplate` `"# save\nmutation{createPage(...)}"` and a 502 envelope with `mutationOutcome=unknown` → `.unknown`, not retryable.
- **Fail-safe B**: writer raw document `"query{findChildPage(...)}"` with a 503 envelope and no `notionDiagnostics` → retryable, `effectOutcome` nil.
- **Fail-safe C**: a reader-tier envelope that contains `mutationOutcome=unknown`, which is synthetic → `.unknown`, not retryable. This proves rule 0 runs ahead of the read rules.
- **Fail-safe D**: writer JSON-operation mode with an operation name missing from the catalog, using a synthetic catalog override or a runner-only test of `isMutation(...)` → `isMutation == true`.
- `isMutation` table test:
  - `("reader", nil, false, "mutation{x}")` → false;
  - `("writer", nil, false, "  # c\n# d\n{ x }")` → false;
  - `("writer", nil, false, "")` → true;
  - `("writer", nil, false, "subscription{x}")` → true.
- Timeout: deadline already past → `.timeout`, `.notDispatched`, retryable, runner call count 0. Runner that blocks past the deadline on a mutation → `.timeout`, `.unknown`. Use a short real deadline of 50–200 ms on the existing `context.deadline` path; this is the only real-time test and must stay under 1 s.

## Verification (each must exit 0)

1. `mkdir -p tmp/issue-188 && arch -arm64 /bin/zsh -lc 'swift test --filter NotionGatewayAddonRetryClassificationTests 2>&1 | tee tmp/issue-188/p03-test.log; exit ${pipestatus[1]}'` — all pass.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "NotionGatewayAddonTests|GatewayRetryDiagnosticsTests" 2>&1 | tee tmp/issue-188/p03-regression.log; exit ${pipestatus[1]}'` — no regression in existing Notion and diagnostics tests. Check that the log shows tests from **both** classes ran, so the filter is not vacuous.

If a compile error comes only from a sibling plan's writePaths, record it as `sibling-blocked` and re-run later. Never edit sibling files.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCLI/NotionGatewayFailureClassification.swift Sources/RielaCLI/ProductionNodeAdapter+LocalGatewaySupport.swift Tests/RielaCLITests/NotionGatewayAddonRetryClassificationTests.swift 2>&1 | tee tmp/issue-188/p03-lint.log; exit ${pipestatus[1]}'`

## Edit safety

- Re-read before each edit. Record pre- and post-edit sha256.
- `ProductionNodeAdapter+LocalGatewaySupport.swift` is owned only by this plan.
- On drift, re-apply only the Notion-scoped changes.

## Completion criteria

- [x] The classifier and wrapper exist with the pinned signatures.
- [x] Gateway-level malformed-output classification and context.deadline timeout coverage pass.
- [x] Focused, regression and strict changed-file lint gates pass; see progress log.
- [x] Edits are confined to plan writePaths.

## Progress Log

### Session: 2026-11-10
**Tasks Completed**: Plan authored (Opus).
**Blockers**: Waits for issue188-01.

### Implementation: 2026-11-10

Implemented Notion-only ordered classification, fail-safe operation detection, deadline metadata and publishPage taint propagation. Focused tests: `tmp/issue-188/issue188-03-notion-classification/test-final-04.log` (7 passed). Regression: `tmp/issue-188/issue188-03-notion-classification/regression-final-04.log`. Strict changed-file lint: `tmp/issue-188/issue188-03-notion-classification/lint-final-04.log`. Tests ran on the shared working tree. The non-JSON case is tested directly against the classifier; the gateway envelope parser still throws before classification. Timeout tests exercise the wrapper directly, not the context.deadline integration path. These remain implementation work. Formal review and serial integration remain downstream.

### Continuation: 2026-11-10

Notion envelope parse failures retain the original error code and message while receiving safe retry and outcome metadata, including publish/upload calls. Context deadline tests cover pre-dispatch and started mutation timeouts. `continuation-test-final.log`: 9 passed; `continuation-regression-final.log`: 43 passed across both required suites; `continuation-lint-final.log`: strict changed-file lint exit 0. All logs are under `tmp/issue-188/issue188-03-notion-classification/`. The earlier `continuation-test.log` failed because the publishPage test fixture omitted required children; the fixture was corrected and the full suite rerun. These gates ran on the shared tree; formal review and serial integration remain downstream.

### Redispatch verification: 2026-11-10

The accepted core-contract dependency is available. On the shared tree, `redispatch-test.log` passed 9 tests and `redispatch-regression.log` passed 43 tests across both required classes. `redispatch-strict-lint.log` and `redispatch-plan-lint.log` exited 0. Evidence and the selected Swift file manifest are under `tmp/issue-188/issue188-03-notion-classification/`. Formal review and serial integration remain downstream.
