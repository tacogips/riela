# ISW-176 gateway validation implementation progress

## Implemented

- Added Notion read/write mappings and tiers to Core gateway validation.
- Added an optional postprocess compiler closure. Context-free validators retain the prior behavior; the CLI production context uses the runtime `JSONDataTransform.compile` implementation.
- Enforced runtime parity for operation mode conflicts, Gmail passthrough variables, literal operation names, and bounded literal selections. Apple operation requests also reject legacy document/config modes.
- `WorkflowValidateCommand.run` is the only production call site that injects `.production()`. Inspect and other callers remain context-free.
- Production catalog projection uses the exact runtime SDK constructors through their existing descriptors. `GatewaySchemaCatalog.operations` is the public listing for GraphQL operation names and document command names, preserving Docs/Sheets/Drive space-separated command names. Catalog initialization failures and unavailable SDKs return nil. Gmail `threads` and `message-box` do not have CLI SDK constructors and return nil.
- Non-templated `config.postprocess` on `riela/*` and `kaiba/*` add-ons is compiled at validation time. Templated programs and context-free callers defer as designed.
- Updated `docs/builtin-gateway-json.md` and the remaining acceptance matrix in `impl-plans/builtin-gateway-json-176.md`. X readers, legacy container readers, Google Service, Kaiba argument validation, ART migration, release and deployment remain open.

## Verification

Commands were run from the repository root via arm64 zsh. Logs are complete and each has its final integer exit status.

| Command | Result | Evidence |
| --- | --- | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-20261024/ISW-176/build-final3.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-176/build-final3.log'` | exitStatus 0 | `tmp/issue-sweep-20261024/ISW-176/build-final3.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests > tmp/issue-sweep-20261024/ISW-176/core-final.log 2>&1; echo exitStatus=$? >> tmp/issue-sweep-20261024/ISW-176/core-final.log'` | historical attempt: exitStatus 1 before test execution; later current-tree retry passed 6 tests with 0 failures | `tmp/issue-sweep-20261024/ISW-176/core-final.log`; compile error was in sibling `Tests/RielaAdaptersTests/CommandFailureDiagnosticsTests.swift:126` and is absent from the successful retry |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/issue-sweep-20261024/ISW-176/evidence/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/issue-sweep-20261024/ISW-176/evidence/changed-swift-files.nul; else printf ...; fi'` | exitStatus 0 | `tmp/issue-sweep-20261024/ISW-176/lint-final5.log`; exact changed Swift-file set is recorded in `tmp/issue-sweep-20261024/ISW-176/evidence/changed-swift-files.nul` |

An earlier test attempt (`tmp/issue-sweep-20261024/ISW-176/core.log`) executed six tests and found one failed assertion in the newly added test: it expected no diagnostics for a templated postprocess on an otherwise incomplete addon. That assertion was corrected to check only the postprocess diagnostic. A subsequent historical run failed to compile because of a sibling adapter test issue; the Step 6 current-tree retry below confirms both Core and CLI filters now pass.

The plan-owner amendment `IR-176-GATE-AMEND` supersedes the active plan checklist's example gate. The applicable workflow bundles are `builtin-gateway-json`, `gmail-latest-mail-digest-telegram`, `wrike-project-kanban-agent`, `apple-gateway-admin`, and `apple-gateway-packaging-plan`. `wrike-webhook-realtime` is an event-source bundle with no `workflow.json`, so it is not part of this workflow-validation gate.

## Current Step 6 verification — IR-176-PARITY-SKIP

The direct review repair brief supersedes the earlier aggregate parity command for this implementation gate. Its one excluded case is recorded as an out-of-scope dependency, not as a pass. The amended five-workflow-bundle gate from `IR-176-GATE-AMEND` remains applicable; `wrike-webhook-realtime` is an event-source bundle without `workflow.json`.

| Command | exitStatus | testsRun | failureCount | Evidence |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-176/parity-skip/build.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowGatewayValidationTests'` | 0 | 6 | 0 | `tmp/issue-sweep-20261024/ISW-176/parity-skip/core.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowValidateGatewayContextTests'` | 0 | 3 | 0 | `tmp/issue-sweep-20261024/ISW-176/parity-skip/cli.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowHostCapabilityTests'` | 0 | 22 | 0 | `tmp/issue-sweep-20261024/ISW-176/parity-skip/host.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter RielaExampleParityTests --skip testMockScenarioExamplesRunThroughSwiftCLI'` | 0 | 8 | 0 | `tmp/issue-sweep-20261024/ISW-176/parity-skip/parity-skipped.log`; one test excluded and not claimed as passing |
| Five direct `.build/debug/riela workflow validate <bundle> --workflow-definition-dir examples/<bundle> --output json` invocations | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-176/parity-skip/five-bundle-validate.log`; five `valid: true`, zero diagnostics |
| Strict lint through the NUL-delimited changed-Swift manifest | 0 | 0 | 0 | `tmp/issue-sweep-20261024/ISW-176/parity-skip/lint.log`; manifest: `tmp/issue-sweep-20261024/ISW-176/review-amendment/changed-swift-files.nul` |

### Superseded / out-of-scope parity evidence

The earlier full `RielaExampleParityTests` run remains an X-only baseline candidate, not a current passing gate: `tmp/issue-sweep-20261024/ISW-176/review-amendment/parity.log` has exitStatus 1, 9 tests and 2 failures. Both assertions came from `testMockScenarioExamplesRunThroughSwiftCLI` for `x-follower-ai-business-digest`: `riela/x-gateway-read` returned `VALIDATION_ERROR`, followed by a missing `workflowId` decode error. Comparison `tmp/issue-sweep-20261024/ISW-176/review-amendment/comparison.json` reports `identical: true`, 2 aggregate and 2 baseline assertions, with empty `aggregateOnly` and `baselineOnly`; the baseline log is `tmp/issue-sweep-20261024/reconcile-wave-001/examples.log`.

Dependency object: `{ "blockedOn": "examples/x-follower-ai-business-digest (riela/x-gateway-read container, riela-x-gateway:local)", "reason": "out-of-scope X container VALIDATION_ERROR; skipped per IR-176-PARITY-SKIP" }`. The skipped method is excluded by the authorized repair and is not reported as a passing test. No source or test files changed for this repair. The active checklist `impl-plans/active/issue-sweep-20261024-176-gateway-validation.md` remains superseded by the plan-owner review amendments and was not edited because it is outside this plan's `writePaths`.

## Source identity and edit evidence

- Pre-edit hashes: `tmp/issue-sweep-20261024/ISW-176/evidence/pre-edit.sha256`.
- Final source hashes: `tmp/issue-sweep-20261024/ISW-176/evidence/final-source.sha256`.
- Per-edit intentions: `tmp/issue-sweep-20261024/ISW-176/evidence/edit-intent-001.md` through `edit-intent-006.md`.
- No SDK checkout source was changed. No credentials or network access were used to instantiate catalogs.
