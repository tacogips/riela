# ypb-09: Register the new examples and reconcile the mock-scenario count

```json
{
  "planId": "ypb-09-example-catalog-finalize",
  "planPath": "impl-plans/active/youtube-processing-builtins-09-example-catalog-finalize.md",
  "dependsOn": ["ypb-07-fanout-cli-validation-example", "ypb-08-youtube-gateway-read"],
  "wave": "W3",
  "writePaths": [
    "Tests/RielaCLITests/RielaExampleCatalog.swift",
    "Tests/RielaCLITests/RielaExampleParityTests.swift",
    "impl-plans/progress/ypb-09-example-catalog-finalize.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design source: `design-docs/specs/design-youtube-processing-builtins.md`,
"Rollout and verification", wave 4.

`RielaExampleParityTests.testAllRielaExampleWorkflowsArePortedAndValidateInSwift`
requires that `rielaExampleWorkflowNames()` equals the sorted set of
`examples/*` directories that contain `workflow.json`.
`testMockScenarioExamplesRunThroughSwiftCLI` requires
`ExampleCatalog.expectedMockScenarioCount` (today 48) to equal the number of
those examples with `mock-scenario.json`, and runs each one.

The new examples are:

- `examples/fanout-include-step-outputs`, from ypb-07;
- `examples/youtube-gateway-read`, from ypb-08.

`examples/video-pipeline-yt-dlp` (ypb-04) has no top-level `workflow.json` and
is intentionally not registered.

## Non-goals

- Do not edit any example contents or Sources.
- Do not change `expectedNodeMockScenarioCount` (0) or any other parity
  assertion.

## File-level changes

- `Tests/RielaCLITests/RielaExampleCatalog.swift`: insert
  `"fanout-include-step-outputs"` and `"youtube-gateway-read"` in sorted
  position. The list is alphabetical; check the neighbors.
- `Tests/RielaCLITests/RielaExampleParityTests.swift`: change
  `static let expectedMockScenarioCount = 48` to `50`. Before editing, confirm
  that `ls examples/*/mock-scenario.json | wc -l` equals 50. If it differs,
  record the actual numbers in the progress log and set the count to the
  number of registered examples that have a mock scenario, with a justification
  line.

## Invariants and pitfalls

- If either example is missing its `workflow.json` or `mock-scenario.json`,
  stop and report back to the owning plan (ypb-07 or ypb-08). Do not fabricate
  files.
- The run must not pick up `examples/video-pipeline-yt-dlp`.

## Tests (situation → expected)

- The parity suite's discovered names equal the catalog list, and its mock
  count equals 50.
- Every mock-scenario example, both new ones included, runs to completion
  through the Swift CLI.

## Verification (evidence)

```bash
mkdir -p tmp/youtube-processing-builtins/ypb-09
ls examples/*/workflow.json | wc -l > tmp/youtube-processing-builtins/ypb-09/counts.txt
ls examples/*/mock-scenario.json | wc -l >> tmp/youtube-processing-builtins/ypb-09/counts.txt
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter RielaExampleParityTests > tmp/youtube-processing-builtins/ypb-09/test-parity.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Tests/RielaCLITests/RielaExampleCatalog.swift Tests/RielaCLITests/RielaExampleParityTests.swift > tmp/youtube-processing-builtins/ypb-09/swiftlint.log 2>&1'
```

What each command must show:

- `counts.txt`: the mock-scenario count is 50.
- parity test: exit 0 with 0 failures.
- swiftlint: empty log.

## Working protocol

- Before each edit, read the file fresh and record the pre/post SHA-256.
- Do not run any git write commands.
- Put scratch files under `tmp/youtube-processing-builtins/ypb-09/`.

## Done criteria

- Two names are added in sorted order and the count is 50.
- The parity suite is green.
- The progress log contains the hashes and the verification table.
