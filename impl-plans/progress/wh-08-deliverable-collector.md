# wh-08 implementation progress

Plan: `impl-plans/active/wh-08-deliverable-collector.md`
Workflow mode: issue-resolution
Branch: `feat/work-handover-and-takeover`
Issue: no GitHub issue supplied; tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md`.

## Implementation

- [x] Added `Sources/RielaWork/DeliverableCollector.swift` with the pinned public API. It filters to completed executions with accepted output, maps step IDs through the workflow definition, collects kaiba and declared projected IDs, lists memory/KV stores as local-only, and deterministically merges and sorts results.
- [x] Added `Tests/RielaWorkTests/DeliverableCollectorTests.swift` with six synthetic XCTest cases covering kaiba IDs/merge, projected string and array IDs, KV local-only path, failed/unaccepted executions, and stable output ordering.
- [x] Focused behavioral verification with a positive test count: 6 tests, 0 failures.
- [x] Required full `swift build` against the combined worktree.
- [x] Strict SwiftLint on the exact changed Swift-file manifest and `git diff --check`.

## Verification evidence

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-08-deliverable-collector/build-rerun-01.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-08-deliverable-collector/build-rerun-01.log'` — exit 0; log ends `Build complete! (7.50s)`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "DeliverableCollectorTests" > tmp/work-handover/wh-08-deliverable-collector/focused-rerun-01.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-08-deliverable-collector/focused-rerun-01.log'` — exit 0; 6 tests executed, 0 failures.
- Selected-file strict SwiftLint via `changed-swift-files.nul` — exit 0; full log: `tmp/work-handover/wh-08-deliverable-collector/swiftlint-rerun-01.log`.
- `git diff --check -- Sources/RielaWork/DeliverableCollector.swift Tests/RielaWorkTests/DeliverableCollectorTests.swift impl-plans/progress/wh-08-deliverable-collector.md` — exit 0; log: `tmp/work-handover/wh-08-deliverable-collector/diff-check-rerun-01.log`.
- Source hashes: `DeliverableCollector.swift` `c1430a44d5749678eeff928f6d4a4c0eb9ad1bd014400c4b5107d625c8cbd4cf`; `DeliverableCollectorTests.swift` `a84431fabac3d4fe9a626e01440fff5250da11b89c460c5cf268a4cdf390069b`.
- Historical failed attempts remain preserved: initial `build.log` and `focused.log` exposed a collector helper access issue that was corrected; `build-final-02.log` and `focused-final-01.log` failed on concurrent wh-09 sink compilation. The rerun logs above pass on the current source tree after that shared compile error cleared.

Implementation-phase verification is complete. Formal test-integrity/adversarial review and serial integration review remain downstream workflow steps; this progress record does not claim review acceptance.

## Step 6 test-integrity self-repair

- Finding (mid): `DeliverableCollector.collect(snapshot:)` guarded on `node.addon`, so executions of registry nodes without an add-on (for example a `nodeFile` command node, the monja case in design §9.2/§18) were skipped and their declared `output.deliverables` projection was silently dropped, contradicting plan rule 2. `testCollectsDeclaredProjectionStringAndArrayIds` masked this by giving the command node a fake `custom/command` add-on.
- Change: `Sources/RielaWork/DeliverableCollector.swift` now treats the add-on as optional. The completed/accepted-payload/step/node guards are kept; the `kaiba/` rule and the memory/KV local-only rules apply only when an add-on is present; the projection rule applies regardless of add-on. Ordering, merging, dedup and never-throwing behavior are unchanged. The test now uses `WorkflowNodeRef(id: "command", nodeFile: "nodes/command.json")` (no add-on) with an `AgentNodePayload` of `nodeType: .command`; all assertions are unchanged.
- Verification (logs under `tmp/work-handover/wh-08-deliverable-collector/step6-review/`):
  - `prefix-focused.log` — updated test against the unfixed source: exit 1, 6 tests, 1 failure (confirms the test now catches the defect).
  - `build.log` — `swift build` exit 0.
  - `focused.log` — `swift test --filter DeliverableCollectorTests` exit 0, 6 tests, 0 failures.
  - `swiftlint.log` — strict SwiftLint on both Swift files exit 0.
- Preimages and hashes: `*.preimage` and `*.preimage.sha256` in the same directory.
- New sha256: `DeliverableCollector.swift` `0e9a7c5996d90aad6870b593dcdcae531971c3dcee68d481a21373d5f1e88244`; `DeliverableCollectorTests.swift` `9f4ffc825dbcf542c2eabfa415a53bc30565a9db7126559e68139bd45fd2fe41`.
