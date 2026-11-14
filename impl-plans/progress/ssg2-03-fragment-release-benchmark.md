# ssg2-03 progress

Status: blocked, implementation incomplete. Dependencies ssg2-02 and ssg2-06 are accepted in dispatch. Design §3.2 and plan align on guarded cascade and two fixed bulk rounds.

Partial changes: enabled reduced writes and implemented guarded per-parent cascade and two-round bulk release. These changes are unverified and must be preserved and reviewed on resumption. Pre/post hashes: `tmp/ssg2/ssg2-03-fragment-release-benchmark/pre.sha256` and `post.sha256`. Source snapshots and intent are in that directory.

Ownership blocker: `Tests/RielaCoreTests/RuntimePayloadFragmentWriterTests.swift` test `testDefaultWritesFullPayloadAndNestedWritesReduced` asserts the old default and is selected by the required `RuntimePayload` filter. It is outside this plan's writePaths and sharedPaths. Amend the checkpoint to authorize updating its default expectation, then implement the required release and benchmark tests, adjust authorized expectations, and run all plan gates.

A focused test attempt, `HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter RuntimePayloadFragmentWriterTests/testDefaultWritesFullPayloadAndNestedWritesReduced 2>&1 | tee tmp/ssg2/ssg2-03-fragment-release-benchmark/ownership-test.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-03-fragment-release-benchmark/ownership-test.log; exit $s'`, exited 1 before tests: sibling-owned `Tests/RielaCLITests/RunEndStorageMaintenanceTests.swift` changed during compilation. Re-run after shared tree stabilizes. The incompatibility is confirmed by inspection, not a completed test run.

Changed-file strict lint passed (exit 0) in `tmp/ssg2/ssg2-03-fragment-release-benchmark/changed-lint.log`; manifest `changed-swift.nul`. Required build, aggregate tests, benchmark, and plan lint remain pending. No benchmark numbers or expectation updates yet. Formal reviews and integration remain downstream.
