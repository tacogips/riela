# GWJSON176-05: register examples, run example parity, attribute pre-existing failures

```json
{
  "planId": "gwjson176-05",
  "planPath": "impl-plans/active/gwjson176-05-example-registration.md",
  "dependsOn": ["gwjson176-04", "gwjson176-06"],
  "writePaths": [
    "Tests/RielaCLITests/RielaExampleCatalog.swift",
    "Tests/RielaCLITests/RielaExampleParityTests.swift",
    "Tests/RielaCLITests/WorkflowValidateGatewayContextTests.swift",
    "impl-plans/active/gwjson176-05-example-registration.md",
    "impl-plans/progress/gwjson176-05.md"
  ],
  "sharedPaths": [
    "examples/x-gateway-json-search",
    "examples/notion-gateway-json-sync",
    "examples/builtin-gateway-json"
  ],
  "sharedPathNotes": [
    {"path": "examples/x-gateway-json-search", "intendedEdit": "Minimal fixes only, when validation with the production context or the Swift mock run rejects the gwjson176-06 bundle (operation, argument or selection names, payload shape). Record each fix and its cause."},
    {"path": "examples/notion-gateway-json-sync", "intendedEdit": "Same minimal-fix rule (for example, Notion operation or argument names rejected by the pinned catalog)."},
    {"path": "examples/builtin-gateway-json", "intendedEdit": "Same minimal-fix rule (for example, Gmail threads or sendMessage input fields)."}
  ],
  "progressLog": "impl-plans/progress/gwjson176-05.md",
  "status": "planned; design accepted (Step 3 comm-008838)"
}
```

## Authority and intent

- Design rules **R4** (registration) and **R6** (verification and
  attribution).
- Acceptance: the new X and Notion examples and the extended Gmail example
  run green with their mock scenarios through the Swift CLI example parity
  tests.

## Non-goals

- No source changes.
- No fix of pre-existing red examples (for example
  `x-follower-ai-business-digest`). Attribute them only.
- No registration of examples other than the two new ones.

## Write ownership

writePaths and sharedPaths as in the JSON header.

## File-level changes

1. **`Tests/RielaCLITests/RielaExampleCatalog.swift`.** Insert
   `"notion-gateway-json-sync"` and `"x-gateway-json-search"` in sorted
   position. `testAllRielaExampleWorkflowsArePortedAndValidateInSwift`
   compares this list with the discovered directories, so keep the existing
   order convention (alphabetical). `x-gateway-json-search` goes between
   `x-follower-ai-business-digest` and `x-incremental-posts-kv`.
2. **`Tests/RielaCLITests/RielaExampleParityTests.swift`.** Raise
   `ExampleCatalog.expectedMockScenarioCount` from `45` to `47`. Leave
   `expectedNodeMockScenarioCount` (0) unchanged. Add no per-example
   `--variables` branch.
3. **`Tests/RielaCLITests/WorkflowValidateGatewayContextTests.swift`.** Add
   `"x-gateway-json-search"`, `"notion-gateway-json-sync"`,
   `"x-window-checkpoint"` and `"x-incremental-posts-kv"` to the `examples`
   list in `testGatewayWorkflowExamplesValidate`. `builtin-gateway-json` is
   already there. That test uses the production context, so this proves
   design R1's "existing X examples still validate".

## Attribution procedure (only if a parity test fails)

1. Identify the failing example names from the log: the `parity-start` /
   `parity-output` lines and the XCTest failure messages.
2. If every failure is in an example this plan did not touch, reproduce it on
   a clean export of `origin/main`. This needs no worktree or index change:
   - `git archive --format=tar origin/main | (mkdir -p tmp/issue-176/baseline-main && tar -x -C tmp/issue-176/baseline-main)`
   - `arch -arm64 /bin/zsh -lc 'cd tmp/issue-176/baseline-main && swift test --filter RielaExampleParityTests > ../gwjson176-05/baseline-parity.log 2>&1'`
3. Record the `git rev-parse origin/main` value (expected `18f22b7d`), the
   failing test and example names on both trees, and the log paths.
4. A failure is attributed as pre-existing only if the same example fails on
   the baseline.
5. Then re-run with
   `--skip testMockScenarioExamplesRunThroughSwiftCLI`. That skip removes the
   whole mock-run test, so also run each of the three touched examples
   directly through the built binary (commands below), in addition to
   `testAllRielaExampleWorkflowsArePortedAndValidateInSwift`.
6. Delete `tmp/issue-176/baseline-main` afterwards (keep the logs).
7. A failure in a touched example must be fixed under sharedPaths and is never
   attributed.

## Execution rules

- Same branch and working directory. The only git commands allowed are the
  read-only `git archive` and `git rev-parse`.
- Fresh-read every file and record pre/post sha256.
- Logs go under `tmp/issue-176/gwjson176-05/`.
- Use `arch -arm64 /bin/zsh -lc`, in the foreground.

## Verification (each exit 0; tests: testsRun > 0, failureCount 0, except an attributed baseline failure)

```
mkdir -p tmp/issue-176/gwjson176-05
arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-176/gwjson176-05/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowValidateGatewayContextTests > tmp/issue-176/gwjson176-05/context.log 2>&1'
arch -arm64 /bin/zsh -lc 'swift test --filter RielaExampleParityTests > tmp/issue-176/gwjson176-05/parity.log 2>&1'
arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate x-gateway-json-search --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-05/validate-x.log 2>&1'
arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate notion-gateway-json-sync --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-05/validate-notion.log 2>&1'
arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate builtin-gateway-json --workflow-definition-dir ./examples --output json > tmp/issue-176/gwjson176-05/validate-gmail.log 2>&1'
arch -arm64 /bin/zsh -lc '.build/debug/riela workflow run x-gateway-json-search --workflow-definition-dir ./examples --mock-scenario ./examples/x-gateway-json-search/mock-scenario.json --session-store tmp/issue-176/gwjson176-05/sessions-x --output json > tmp/issue-176/gwjson176-05/run-x.json 2> tmp/issue-176/gwjson176-05/run-x.err'
arch -arm64 /bin/zsh -lc '.build/debug/riela workflow run notion-gateway-json-sync --workflow-definition-dir ./examples --mock-scenario ./examples/notion-gateway-json-sync/mock-scenario.json --session-store tmp/issue-176/gwjson176-05/sessions-notion --output json > tmp/issue-176/gwjson176-05/run-notion.json 2> tmp/issue-176/gwjson176-05/run-notion.err'
arch -arm64 /bin/zsh -lc '.build/debug/riela workflow run builtin-gateway-json --workflow-definition-dir ./examples --mock-scenario ./examples/builtin-gateway-json/mock-scenario.json --session-store tmp/issue-176/gwjson176-05/sessions-gmail --output json > tmp/issue-176/gwjson176-05/run-gmail.json 2> tmp/issue-176/gwjson176-05/run-gmail.err'
arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Tests/RielaCLITests/RielaExampleCatalog.swift Tests/RielaCLITests/RielaExampleParityTests.swift Tests/RielaCLITests/WorkflowValidateGatewayContextTests.swift > tmp/issue-176/gwjson176-05/lint.log 2>&1'
```

Every `run-*.err` must contain no `warning: workflow.nodes` line. That shows
the production-context run check (gwjson176-01) finds nothing in the new
examples. Each run JSON must show status `completed`.

## Done criteria

- [ ] Two names are registered, the count is 47, and the four examples are
      added to the gateway validate test.
- [ ] The parity suite passes, or its only failures are attributed with
      baseline evidence and the skip-plus-direct-run evidence is present.
- [ ] Every verification record has integer exitStatus, testsRun and
      failureCount, plus log paths. Any example fixes are recorded with
      their cause.
- [ ] `git diff --name-only` is a subset of writePaths ∪ sharedPaths.

## Progress log expectations

`impl-plans/progress/gwjson176-05.md` contains:

- status;
- per-edit hashes;
- the parity results (each failing example and its attribution);
- the baseline evidence;
- the direct-run outcomes;
- blockers as dependency objects;
- residual risks (no leading severity word).
