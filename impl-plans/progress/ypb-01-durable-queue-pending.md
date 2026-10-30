# ypb-01 durable queue pending progress

Implementation complete; formal integrity and adversarial review and integration are downstream.

| File | Pre SHA-256 | Post SHA-256 |
| --- | --- | --- |
| Sources/RielaCLI/ProductionNodeAdapter+DurableQueue.swift | 635f0aaf87778b9dab2365ac1e52c0a2e90c3b843ce172377249a74c6cc2d104 | 70c16169e3b48f56660818e5f3e98e37787ac310b1673026d1ad7119153b9530 |
| Tests/RielaCLITests/DurableQueueTests.swift | 87d83d950970a903e61cd5c981b4fa7da06b58e5cd59b68ab985c5901ac6f31b | 29ae8307e5fcd9c5a1fad920822b932fbf99da0d659c75b56616da16d4b6f9ac |
| docs/workflows/durable-queue.md | 3e91df2d84d161ed9845f59bc4039a8527c4baa3438feb0e9db7915ec0530a3c | bcc71b1da59f79a1b71b114ba8270f7601ded93a4cde566298c0f02bf044ab06 |
| This progress file | absent before edit | recorded in plan-local progress-post.sha256 |

Pending options preserve default fields, ordering and read-only state; tests cover selection, exhaustion, validation, size limit and absent directory.

| Gate | Exit | Tests | Failures | Log |
| --- | ---: | ---: | ---: | --- |
| arm64 swift build | 0 | 0 | 0 | tmp/youtube-processing-builtins/ypb-01-durable-queue-pending/build-3.log |
| arm64 swift test --filter DurableQueueTests | 0 | 8 | 0 | tmp/youtube-processing-builtins/ypb-01-durable-queue-pending/test-2.log |
| arm64 selected-file swiftlint --strict | 0 | 0 | 0 | tmp/youtube-processing-builtins/ypb-01-durable-queue-pending/swiftlint-final.log (empty) |
| git diff --quiet -- Sources/RielaCLI/DurableQueueJournal.swift | 0 | 0 | 0 | tmp/youtube-processing-builtins/ypb-01-durable-queue-pending/journal-diff.log |

Earlier shared-tree build failed in sibling Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift (build.log); test failed because sibling Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift changed during compilation (test.log). Subsequent build found owned Int64 compile errors (build-2.log), corrected before passing gates. SwiftPM lock contention was allowed to finish. Per-edit snapshots and intents are in the evidence directory.
