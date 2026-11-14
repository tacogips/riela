# whu-03 GraphQL contract progress

- Implemented the seven pinned operations, DTOs, default unsupported provider methods, executor dispatch, SDL types and root descriptors. Restore defaults to dry run and definition restore accepts `expectedVersionId`.
- Generator exposes the new roots before downstream catalog registration and deduplicates them once registered. Provider implementations, catalog rows and generated SDL belong to whu-09, whu-10 and whu-11.
- Added contract tests for dispatch, arguments, unsupported providers, schema signatures and variable validation.
- Verification logs are under `tmp/workflow-history-unification/whu-03-graphql-contract/`; final statuses are reported in the Step 6 handoff. Formal review and finalization remain downstream.
- [x] WHU-INT-02: generated root arguments merge with checked-in entries taking precedence; explicit overrides remain. The negative test asserts rejection at parsing, where validation occurs. Both limit 3 dispatch assertions pass.
- [x] Final-source build and scoped strict SwiftLint exit 0; focused suite exits 0 with 32 tests and zero failures. Logs: `tmp/workflow-history-unification/whu-03-graphql-contract/{build-final,tests-final,swiftlint-final}.log`. These ran on the shared fanout tree; serial integration verification remains downstream. Earlier attempts are retained in that directory.
