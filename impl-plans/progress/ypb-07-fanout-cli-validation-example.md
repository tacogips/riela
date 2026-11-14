# ypb-07 progress

Plan matches design §B. Dependency ypb-03 accepted in dispatch. Formal review and integration remain downstream.

| Path | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| Sources/RielaCLI/WorkflowValidateInspectCommands.swift | 2157fa22504747a6bcc5ca4f10fbd5f3bf51c57d1a6e6240e5d58d9972acdc32 | d60ad93b4d30047f8ddfc90f74469d76afe7d46ec9db1136176739fbad748959 |
| Tests/RielaCLITests/FanoutIncludeStepOutputsTests.swift | absent | 30b8488dfdff85bc7512c72edefe2f2ccb11d1794935d23613cd813f2956ba1a |
| docs/workflows/json-data-processing.md | 50033a90633a2bacec1ea336825bb7a57efa1a97ecb4390afc3808c254a2fb70 | 60c5857ea111173896f9c429e14fb983a291d79a2debac19076a54846a06d421 |
| examples/fanout-include-step-outputs/EXPECTED_RESULTS.md | absent | 3c6e50e1217625e443c936508509cbf2c1e323dcd72c1214b41735d08acbd385 |
| examples/fanout-include-step-outputs/README.md | absent | 68e726d618f26a029b4f344e287d01014eac8351fc0c3e0c408d957f1d70e3d6 |
| examples/fanout-include-step-outputs/mock-scenario.json | absent | 3f10010109660255a6a36d85e6a706edad96aede92bdd4b4a4117e065cd87f38 |
| examples/fanout-include-step-outputs/workflow.json | absent | e91e138651edf06738c551c9c4420fa2439655165c318e69bef42d4fe78f24ca |

Per-edit pre/post hashes and intent: `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/edit-intents.txt`. Progress pre hash: absent.

| Gate | Exit | Evidence |
| --- | --- | --- |
| Build final | 0 | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/build-final.log` |
| Focused new tests | 0; 2 tests, 0 failures | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/test-own.log` |
| Strict lint | 0; empty | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/swiftlint-final.log` |
| Validate example | 0 | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/validate.json` |
| CLI run | 137 | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/run.json`; printed completed result and both transcripts but process hung and was terminated |
| Aggregate test | 137 | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/test.log`; prior fixture invalid node IDs fixed, existing cross-workflow test launched an undeclared scratch build outside artifact roots and was terminated |

No tests reference json-data-processing.md; no JSON fence added. Full aggregate and CLI process exit remain unresolved; request artifact-root amendment for the existing subprocess test.

## INT-W2-M1 repair

The earlier unresolved status above is superseded by the following verification on the current combined tree. No source, test, documentation, or example edits were necessary. Fresh pre-repair hashes matched `tmp/youtube-processing-builtins/reconcile-wave-002/current-sha256.txt`; the pre-repair and post-repair hashes for every owned file are recorded in `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/r2-pre.sha256` and `r2-post.sha256`, respectively. The progress file's post hash is recorded externally to avoid self-reference.

`FanoutIncludeStepOutputsTests.testCalleeReferencesWithAndWithoutResume` checks both missing and valid callee step IDs with and without `resumeStepId`; the missing ID yields the indexed diagnostic naming the step and callee, and the valid ID yields no such diagnostic. This confirms the CLI validation behavior agrees with the publisher guard relaxation.

| Gate | Exit | Evidence |
| --- | --- | --- |
| Build | 0 | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/build-r2.log` |
| Focused tests | 0; 3 tests, 0 failures | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/test-r2.log` |
| Example validate | 0; valid true | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/validate-r2.json` |
| Bounded example mock run | 0; completed; transcript s1 and transcript s2 | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/run-r2.json` |
| Strict lint | 0; empty | `tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/swiftlint-r2.log` |
| Cross-workflow aggregate | deferred-to-integration; reconciliation exit 0, 6 tests, 0 failures | `tmp/youtube-processing-builtins/reconcile-wave-002/test-ypb07-aggregate.log`; the subprocess suite builds under undeclared artifact root `tmp/specialist-supervisor/process-recovery-build`, so it was not rerun in this plan |

The repair addresses INT-W2-M1; formal test-integrity and adversarial reviews remain downstream. Example registration and the mock count belong to ypb-09.
