# xs-04 `usageTweets` feasibility and x-collect docs

```json
{
  "planId": "xs-04-usage-and-docs",
  "planPath": "impl-plans/active/xs-04-usage-and-docs.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "README.md",
    "design-docs/specs/design-native-source-collection.md",
    "Tests/RielaCLITests/XGatewayUsageTweetsTests.swift",
    "impl-plans/progress/xs-04-usage-and-docs.md"
  ],
  "sharedPaths": [],
  "artifactRoots": [],
  "sharedPathNotes": [
    {
      "path": "design-docs/specs/design-native-source-collection.md",
      "intendedEdit": "replace only the Implementation outcome placeholder under Daily usage read (usageTweets)"
    },
    {
      "path": "Tests/RielaCLITests/XGatewayUsageTweetsTests.swift",
      "intendedEdit": "created only when the pinned x-gateway SDL has a usage Query field; otherwise left absent"
    }
  ]
}
```

Artifacts: none. `.build/` is the shared SwiftPM build cache and is not owned by any
plan; no plan installs or downloads tools. Evidence logs go under the gitignored
`tmp/x-collect-author-sampling/xs-04/` and are not source.

- planId: `xs-04-usage-and-docs`
- wave: 1, dependsOn: none
- design: `design-docs/specs/design-native-source-collection.md` → "Daily usage read
  (`usageTweets`)", "UTC-day aware re-reads" (dedup statement), options table.
- progress log: `impl-plans/progress/xs-04-usage-and-docs.md`

## Intent and context

ART's monitor wants daily X consumption (GET /2/usage/tweets). Riela calls X only
through the linked x-gateway SDK (pinned exactly in `Package.swift`); the SDK SDL
`type Query` is the operation authority and `riela/x-gateway-reader` already forwards
any SDL operation. Riela must not add a REST client. Also document the new x-collect
options for users.

## Non-goals

- No Swift source changes in `Sources/` (no new operation code, no REST path,
  no `Package.swift` bump).
- Do not edit design sections other than the "Implementation outcome" line.

## Steps

1. Build once (`swift build`, see verification) so `.build/checkouts/x-gateway` exists.
   Determine whether the SDL `type Query` has a usage field: grep the checkout
   (`git grep`/`grep -rn -i "usage" .build/checkouts/x-gateway/Sources`) and, for
   evidence, add the test below that reads `XGatewayOperationCatalog.queryOperationNames`.
   Record the pinned version (from `Package.resolved`) and the matched field name or
   "absent" in the progress log.
2. **Absent:** replace the placeholder after "Implementation outcome:" in the design doc
   with: outcome absent, x-gateway version, checked command, and the reason (SDK change
   is outside this repository; a riela REST path would break the single-SDK rule). Do
   not create a test file.
   **Present:** record outcome present + field name there; create
   `Tests/RielaCLITests/XGatewayUsageTweetsTests.swift` that (a) asserts the field is in
   `XGatewayOperationCatalog.queryOperationNames`, (b) runs `riela/x-gateway-reader`
   JSON mode with `operation: <field>`, a minimal `select`, `postprocess pick` through
   `XGatewayReaderSDK.invocationOverride` (imitate
   `Tests/RielaCLITests/XGatewayEmbeddedReaderRuntimeTests.swift`) and checks the built
   document, and (c) an oversized fake output is rejected by the existing output limit.
3. `README.md`: add a short "`riela/x-collect` cost controls" paragraph near the X reader
   section (around the "X readers also accept `providerFailure`" paragraph) with one
   JSON example using `authorSampling`, `authorDailyPostThreshold`, `referenceDepth`;
   state that X deduplicates billed reads only within a UTC day, that sampled handles
   are read only for that run's window, that a depth change restarts coverage from
   `start`; link `design-docs/specs/design-native-source-collection.md`. If present,
   add the `usageTweets` reader recipe in one sentence. Keep it concise.

## Invariants

- `git diff -- design-docs/specs/design-native-source-collection.md` touches only the
  "Implementation outcome" line(s); the rest of the accepted design is byte-unchanged.
- No real X API calls (tests use the invocation override).

## Concurrency / drift protocol

Runs beside xs-01 (disjoint files; both run `swift build` — SwiftPM serializes on its
lock, just wait). Pre/post SHA-256 per edit in the progress log. No git index/branch ops.

## Verification (evidence under `tmp/x-collect-author-sampling/xs-04/`)

1. `arch -arm64 /bin/zsh -lc 'swift build --build-tests' > tmp/x-collect-author-sampling/xs-04/build.log 2>&1` → exit 0.
2. Usage check: `grep -rn -i "usage" .build/checkouts/x-gateway/Sources > tmp/x-collect-author-sampling/xs-04/usage-grep.log 2>&1` (exit 0 or 1; log retained as evidence).
3. Only if present: `arch -arm64 /bin/zsh -lc "swift test --skip-build --filter XGatewayUsageTweetsTests" > tmp/x-collect-author-sampling/xs-04/test.log 2>&1` → exit 0.
4. `git diff --check -- README.md design-docs/specs/design-native-source-collection.md` → exit 0.

## Done criteria

- Design doc "Implementation outcome" names present/absent, version and evidence log path.
- README has the cost-controls paragraph with the example.
- Progress log lists commands, exit codes, log paths and hashes.
