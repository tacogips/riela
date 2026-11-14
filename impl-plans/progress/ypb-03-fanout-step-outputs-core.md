# ypb-03 progress

Implementation and focused verification performed. Formal review, integration and commit are downstream.

| Path | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| Sources/RielaCore/WorkflowModel.swift | a5ae872a52ab61ed4907ff989e94daec99217b95655d09eaef06cfad20632373 | c2e6509a9a77487ac83e589862bd9b25d492b44d271629ce1aacea69f1f664f4 |
| Sources/RielaCore/RuntimePublication.swift | 19a78815b33e1aac49a4d41d0661f7f52778d69a22248a79e1126c637403663a |
| Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift | 03e85cd111b0d5d1f57aff575af17be2174b25c77a62acb7edf1795534a5f64c |
| Sources/RielaCore/DeterministicWorkflowRunner+NestedReservations.swift | a694c3a465a8efe5b8afbdd89f9034190149c528dafdcb19bdafb7b2d5c69750 | 5519dfb62072055e5538144c653d5f1a7a13739025f67694d70141e01b81930c |
| Sources/RielaCore/WorkflowValidation.swift | 5468b022eeb36c494539bcb3178f730c077def9b5c92b30866d4a5ac125205dc | e0be0bd4e697459ba67096459e5c1a4c2339819bbdbac7257bd250babfec0a69 |
| Sources/RielaCore/WorkflowRawValidation.swift | f6e6faefb441dbb2b9015d1170d5dac0a128c1447213c5626c7061a6d9432836 | 72e1bba3f5ffcc8fc5f2b8d47c3aec166032da399affbb83c0a4cac19854a038 |
| Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift | 3728631ad381fabf3617f9dcf1bc1c4eee469a5a4b1751d9c961e1ef3d20b8ee | 95057067e19915fa411d29cf6ad050a2dcd50a0d155154502dfc621b5ee438c1 |
| Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutResumeTests.swift | fa7bc47429c52b9d6dc3c61a432010df1c75266bed4f990eee1a5ac5a06633ce |

Progress file pre-edit hash: `6871e3f43757a987b0ed540444f652ef4f9689485c67b222f2cad91c5c034771`. Per-edit intentions and snapshots: `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/edit-intents.jsonl`.

| Gate | Exit | Results | Log |
| --- | --- | --- | --- |
| `swift build` | 0 | passed | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/build-verified3.log` |
| Focused fanout suites | 0 | 63 tests, 0 failures | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/test-verified4.log` |
| `swift test --filter PartialFanoutResumeTests` | 0 | 1 test, 0 failures | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/test-cli-verified2.log` |
| Selected-file strict SwiftLint | 0 | empty log | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/swiftlint-verified5.log` |
| Directive construction count | 0 | 1 live, 2 resume | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/directive-sites.log` |
| SQLite nested-store diff | 0 | no diff | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/sqlite-diff.log` |
| Diff whitespace | 0 | clean | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/diff-check.log` |

Earlier build encountered sibling `Sources/RielaCLI/ProductionNodeAdapter+DurableQueue.swift` compiler errors; later build passed. Earlier test fixture failures were corrected and rerun; logs remain in the evidence directory.

Continuation: deterministic uninterrupted and branch-terminal-interrupted runs compare complete sorted join JSON bytes for local fanout and cross-workflow fanout with and without `resumeStepId`. Each case checks a single durable receipt and accepted child payload. The regression exposed and corrected rejection of cross-workflow fanout without `resumeStepId`.

| Continuation gate | Exit | Result | Log |
| --- | --- | --- | --- |
| `swift build` | 0 | passed | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/continuation-build.log` |
| Focused fanout suites | 0 | 64 tests, 0 failures | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/continuation-fanout.log` |
| `swift test --filter PartialFanoutResumeTests` | 0 | 1 test, 0 failures | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/continuation-cli.log` |
| Selected SwiftLint | 0 | empty | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/continuation-lint.log` |
| Directive counts | 0 | 1 live and 2 resume | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/continuation-sites.log` |
| SQLite diff | 0 | unchanged | `tmp/youtube-processing-builtins/ypb-03-fanout-step-outputs-core/continuation-sqlite.log` |

Implementation-phase criteria complete; independent review and integration remain downstream.
