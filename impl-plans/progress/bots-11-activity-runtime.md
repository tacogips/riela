# bots-11-activity-runtime progress

## Implemented

- Wired the canonical SQLite activity recorder into local workflow run, session resume and session rerun. The endpoint path returns before recorder construction.
- Restored bot context from the existing session's root link, including paused bots. Reruns link their new session to the source bot and record the source session ID.
- Settled orphaned sessions and abandoned child sessions with process-exit reason after persisting their terminal state, while holding the existing execution locks.
- Deleted activity and bot session links inside all three existing result retention transactions. The table guards cover pre-generation-13 stores.
- Added isolated tests for ordered mock-run activity, linked and unlinked reruns, resume of a paused bot with its configured permission wait, orphan settlement idempotence, and scoped retention including a legacy-shaped fixture.

## Per-edit hashes

The pre- and post-edit SHA-256 digests and intended hunks are in
`tmp/bots-overview/bots-11-activity-runtime/edit-intentions.md`,
`reconcile-edit-intentions.md` and `test-edit-intentions.md` within that
evidence directory. `snapshot-scope.log` compares the five edited existing
Swift files against the native pre-node snapshot and confirms both
bots-09 runtime helpers are untouched.

| Swift path | Pre-node SHA-256 | Final SHA-256 |
| --- | --- | --- |
| `Sources/RielaCLI/BotRuntime/BotActivityRuntime.swift` | `missing` | `9137dfd8bb8a068cb3b5c57d63ce3b9eae336ec6af92d5677658331002c01431` |
| `Sources/RielaCLI/WorkflowRunCommand.swift` | `5dc6ad58abd053d22fdfeececc93aea533963b87fe1711306a938cfa95c774b4` | `25ae8a37243a8f87fb0c5e02b21e14f8cec9aa9c216afc5c3257d346deca35ee` |
| `Sources/RielaCLI/SessionCommands.swift` | `8c30c3586aed8502f550147c061bacd5a84f350b894d9ad612de2815854b9eb8` | `f20fd2acdbeefbb259ebb8bfe6c90b2d632d180ee25a98934e26b3252a6b57ff` |
| `Sources/RielaCLI/SessionReconcileCommand.swift` | `72675e65e091e595a42bb5f733f80f2caf5f0b75f7a8441fc84edeaa5b1bf38f` | `9a672778e5493b021482621db3b43b1bef4942f2d2c3e45673f7fe709c144d5b` |
| `Sources/RielaCLI/SessionAbandonedInvocationReconciler.swift` | `a9e9846aca03b995743d1692d4e6a7183dfd21c45e957a2626018cc01e53b297` | `3c3a41f8685a16cacc358077631ba6d0c04fd47f29d9e445d6259b8a3445bd04` |
| `Sources/RielaCLI/TerminalRetentionExecutor.swift` | `2af6f829c970043cd75f66da70bed76ca20c7c4cc2c5adc864dcdb7bcd286e90` | `ef68c6f8befbfad2125348ab00df847d3837988a4c00439d2f59562c164c90e9` |
| `Tests/RielaCLITests/BotActivityRuntime/BotActivityRuntimeTests.swift` | `missing` | `67dfd261ffc3abbc72d31cfeac930d37d033e3ba198e15c09af51c826315722d` |

## Verification

- The three recorder request sites and the three retention deletion calls
  were confirmed by the plan's grep commands (exit 0, `recorder-sites.log`
  and `retention-sites.log`).
- Strict selected-file SwiftLint passed (exit 0, `swiftlint-after-paused-context.log`).
- Final paired-source test gate (exit 0, `test.log`):

  ```sh
  arch -arm64 /bin/zsh -lc 'swift test --filter "BotActivityRuntimeTests|BotRunLinkageTests|SessionReconcileCommandTests|SessionAbandonedInvocationTests|TerminalRetentionTests|TerminalRetentionPolicyTests"' > tmp/bots-overview/bots-11-activity-runtime/test.log 2>&1
  ```

  83 tests passed with zero failures, including 6 activity runtime, 9 run linkage,
  10 reconcile, 7 abandoned invocation, 28 retention and 23 retention policy
  tests. The before and after source manifests match and all 1,787 entries
  verified against the working tree (exit 0, `source-identity.log`).
- Scoped `git diff --check` passed (exit 0, `diff-check.log`).
- The first Swift test attempt on the moving shared tree exited 1 before
  running tests. The sibling file
  `Sources/RielaGraphQL/Bots/BotsGraphQLContracts.swift` failed to compile
  because `BotDetailPayload` did not conform to `Decodable`.
  See `test-moving-shared-tree.log` and `test-moving-source-drift.log`.
  The next run passed 83 tests while the sibling generated SDL
  (`test-after-sdl-generation.log`, `test-sdl-source-drift.log`).
  The final stable run supersedes both attempts.

## Deviations

- The committed plan lists activity core and run linkage as predecessors.
  Dispatch supplied activity core as a previously accepted dependency and
  explicitly admitted run linkage for this execution.
- The four existing reconcile and retention test class names match the
  committed filter, and their files have no edits in this dispatch.

## Open items

- Formal review and the cumulative wave gate follow Step 6.
