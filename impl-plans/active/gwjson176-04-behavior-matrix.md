# GWJSON176-04: per-gateway behavioral test matrix

```json
{
  "planId": "gwjson176-04",
  "planPath": "impl-plans/active/gwjson176-04-behavior-matrix.md",
  "dependsOn": ["gwjson176-03"],
  "writePaths": [
    "Tests/RielaCLITests/BuiltinGatewayJSONBehaviorTests.swift",
    "impl-plans/active/gwjson176-04-behavior-matrix.md",
    "impl-plans/progress/gwjson176-04.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/gwjson176-04.md",
  "status": "planned; design accepted (Step 3 comm-008838)"
}
```

## Authority and intent

- Design rule **R5**.
- Issue #176 completion criteria: "gateway ごとの型付き入力、権限境界、変換、pagination、既存モード互換の検証" and "引数中の引用符・template 風文字列、null/欠落、空配列、不正な仕様、上限超過、後処理失敗後の write 再送防止".

This plan is tests only. It fills a coverage matrix of gateway family ×
criterion. Each cell is covered either by an **existing** test, cited in the
progress log, or by a new test in `BuiltinGatewayJSONBehaviorTests.swift`. Do
not duplicate a cell that an existing test already covers.

## Non-goals

- No source changes. If a test exposes a runtime bug, do not fix it here.
  Record a blocker dependency object naming the source path and the failing
  test; the bug goes to serial repair.
- No edits to existing test files or shared test-support files. Declare any
  helper `private` inside the new file. Existing internal helpers such as
  `RecordingGatewayGraphQLRunner` in `LocalGatewayAddonTestSupport.swift` may
  be used read-only.

## Write ownership

writePaths as in the JSON header; no sharedPaths.

## Matrix

Rows (families):

1. Wrike read/write
2. Gmail reader/draft/sender
3. Notion read/write (macOS)
4. Analytics read/write (macOS)
5. Docs/Sheets/Drive read/write (macOS)
6. Apple GraphQL `full` (macOS)
7. X embedded
8. X container
9. Gmail container
10. Google Service read/write
11. Kaiba named
12. Kaiba GraphQL compatibility

Columns (criteria):

- **C1**: quotes, newlines and `{{...}}` text inside argument values reach the
  provider as data and are rendered once. Assert on the recorded document or
  variables.
- **C2**: null vs missing. A missing argument is omitted and an explicit null
  is kept as null in variables or the literal. A `map` field that is missing
  projects as null; an explicit null stays null.
- **C3**: empty arrays are preserved in arguments and in `processed`.
- **C4**: an invalid spec (mixed mode, non-literal operation, bad selection)
  gives `policyBlocked` and 0 provider calls.
- **C5**: limits. Arguments over 8 MiB give `policyBlocked` and 0 calls. The
  container document limit is 120,000 bytes (rows 8 and 9). A postprocess
  over 10,000 entries or 8 MiB gives `postprocessFailed`. The provider is
  still called once.
- **C6**: write tiers only (Wrike write, Gmail draft/sender, Notion write,
  Docs write, Google Service write, Apple mutation). After a successful write,
  a postprocess `pick` of a missing path gives exactly 1 runner call,
  `completionPassed == true`, `postprocessFailed == true`,
  `postprocess.retryProvider == false`, and the original provider payload is
  kept.
- **C7**: tier boundaries.
  - A reader tier rejects a mutation or a writer-only operation with 0 calls.
  - Google Service read rejects `services.enable`.
  - The X reader rejects a mutation document.
  - Kaiba arguments cannot set `endpoint`, `apiKey` or `kaibaInstanceId`.
  - `addon.env` allowlists are unchanged: a disallowed target gives
    `policyBlocked`.
- **C8**: pagination metadata (`pageInfo.nextToken`, `endCursor` or
  `nextPageToken`) stays in the original payload next to `processed`.
- **C9**: legacy mode compatibility. `queryTemplate` still works (rows 1-4, 7,
  8, 9). Docs `command`/`argsTemplate` work. X nested `select` produces the
  same document as `selection`. Google Service flat mode works, including
  `allPages`. Fixed Apple product nodes are untouched; cite an existing test.

Mark a cell `n/a` with a reason only when the criterion cannot apply, for
example C6 for read-only families.

## How to write the new tests

- Use the seams:
  - `BuiltinWorkflowAddonResolver(environment:, localGatewayGraphQLRunner:)`
    for GraphQL families;
  - `(environment:, containerProcessRunner:)` for containers;
  - `(environment:, googleServiceGatewayClientFactory:)`;
  - `XGatewayReaderSDK.$invocationOverride.withValue` for embedded X;
  - the Documents runner override as in `GoogleDocumentsGatewayAddonTests.swift`;
  - `KaibaAddonCatalog.executeForTesting`, from RielaKaibaAddonsTests patterns.
    If it is not reachable from RielaCLITests, cite the existing Kaiba tests
    and the gwjson176-02 `KaibaWorkflowGatewayValidationTests`.
- Prefer one table-driven test per criterion that iterates the families, with
  `#if canImport` guards and `XCTSkip` messages for macOS-only rows.
- Choose operation and argument names from each catalog at test time, as
  `BuiltinGatewayJSONRequestTests.testCatalogRequestsReachEachPinnedGatewayWithoutQueryTemplates`
  does. Do not hard-code names that might not exist in the pinned SDK.
- Assertions must check the provider call count. A test that only asserts
  "no throw" does not count.

## Execution rules

- Same branch and working directory. No git writes.
- Fresh-read every file and record pre/post sha256.
- Logs go under `tmp/issue-176/gwjson176-04/`.
- Use `arch -arm64 /bin/zsh -lc`.

## Verification (each exit 0; testsRun > 0; failureCount 0)

```
mkdir -p tmp/issue-176/gwjson176-04
arch -arm64 /bin/zsh -lc 'swift build --build-tests > tmp/issue-176/gwjson176-04/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter BuiltinGatewayJSONBehaviorTests > tmp/issue-176/gwjson176-04/behavior.log 2>&1'
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Tests/RielaCLITests/BuiltinGatewayJSONBehaviorTests.swift > tmp/issue-176/gwjson176-04/lint.log 2>&1'
```

## Done criteria

- [ ] The progress log contains the full 12×9 matrix. Every cell names a
      test (`Suite/testName`) or `n/a: <reason>`.
- [ ] Every new test asserts provider call counts. The C6 cells all assert
      exactly one write call.
- [ ] All commands exit 0 with the counts recorded.
- [ ] `git diff --name-only` is a subset of writePaths.

## Progress log expectations

`impl-plans/progress/gwjson176-04.md` contains:

- status;
- the matrix;
- per-edit hashes;
- verification records with integer exitStatus, testsRun and failureCount;
- blockers as dependency objects (including any runtime bug found);
- residual risks (no leading severity word).
