# ask-03-turn-engine

Issue-resolution. No GitHub issue. The design was accepted in `comm-000297` for
`fable-sol-design-and-implement-review-loop-session-4`. The amendment was
accepted in `comm-000325`. The redispatch has an empty `dependsOn` because
the dispatch manifest records `ask-01-catalog-and-selection` and
`ask-02-store-tools` under `acceptedDependencies`.
The implementation branch is `feat/bots-overview` at redispatch checkpoint
`33344ee6b9815f67e6d20d4767f7bd7c5a4a0653`.

## Implemented

- `Sources/RielaCLI/Ask/Engine` owns the rounds turn, bounded prompts, typed
  read and proposal calls, activity, authorization rechecks, and cancellation.
- `Sources/RielaCore/Ask` parses rounds and grounds citations in persisted
  references. The store commits admission and the first activity event
  together, and commits terminal state, the assistant message when applicable,
  and settlement together. Stale recovery settles the turn and removes its
  private scratch directory. Paged activity advances only through returned
  events.
- The policy resolves CLI no-tools arguments and read-only sandbox settings.
  The file-backed adapter replays deterministic rounds. Tests use temporary
  stores and injected adapters. The synthetic log test asserts that the
  attempted stop cannot mutate the session and an action remains proposed.
- Scripted rounds cover `codex-agent`, `claude-code-agent`,
  `cursor-cli-agent`, `official/openai-sdk` and `official/anthropic-sdk`.
  Tests exercise Cursor API refusal on a new conversation, on an existing
  conversation with a completed or stale running turn, and through Automatic
  with only a fixture Cursor credential. They verify the error code, zero
  adapter calls, and unchanged records and activity for existing chats.

## Per-edit hashes

- Root edits and corrective diffs are in
  `tmp/ask-riela/ask-03-turn-engine/edit-intentions.md`.
- Delegated histories are in
  `tmp/ask-riela/ask-03-turn-engine/{protocols,adapter,tests}/edit-intentions.md`.
- `source-audit.log` records predecessor preservation on the first attempt.
  `redispatch-source-audit.log` verifies edited paths and predecessor
  preservation against the current native pre-node snapshot.
  `redispatch-source-before.txt` and `redispatch-source-after.txt` capture
  the source identity for the final test run.
  Evidence filenames in this section are relative to the plan's evidence directory.

## Verification

```sh
arch -arm64 /bin/zsh -lc 'swift test --filter "AskRoundsProtocolTests|AskCitationsTests|AskTurnEngineTests|AskAgentPolicyTests|AskPromptInjectionTests|AskScriptedBackendTests|AskStoreTests|AskToolExecutorTests|AskActionTests|AskModelSelectionTests|BotActivityRuntimeTests|ActivityWaitTests"' > tmp/ask-riela/ask-03-turn-engine/test.log 2>&1
```

Exit 0. `test.log` reports 41 XCTest tests and 33 Swift Testing tests,
74 passing and zero failures. Swift Testing also reports all five
parameterized supported-backend cases and both existing-conversation cases
passing. `redispatch-source-compare.log` records a byte-for-byte source match
(exit 0). Strict SwiftLint exited 0 over 23 Ask engine plan paths using
`redispatch-changed-swift.nul`. Its complete log is
`redispatch-swiftlint.log`. Both required grep checks exited 1 with zero
matches (`redispatch-forbidden-permission.log` and
`redispatch-forbidden-transport.log`). `redispatch-diff-check.log` records
the exit-0 whitespace check.

`redispatch-attempt-1-test.log` preserves the exit-1 compile attempt.
The throwing store calls now run before the test assertion macros.
The pre-amendment 72-test run is retained at `pre-amendment/test.log`.

## Deviations

- Admission and settlement use atomic Ask store transactions over the existing
  activity journal and reducer. The SQLite recorder still writes streamed
  updates. This closes the gap in which a second process could see a terminal
  turn before its activity settled.

- The 2026-11-25 amendment (round 1, `comm-000325`) resolves
  `ASK-03-CURSOR-API`. The pinned gateway starts a cloud agent without
  a read-only policy and returns creation metadata before completion
  (`tmp/ask-riela/ask-03-turn-engine/cursor-gateway.log`). Ask refuses
  `official/cursor-sdk` before turn writes, stale-turn recovery, or adapter
  dispatch when using the production path. Injected and scripted adapters
  retain their test seam.

## Completion criteria

- Five supported rounds backends and the Cursor refusal contract verified.
- Forbidden API checks found zero matches, and selected-file SwiftLint passed.
- Focused verification exited 0, with matching source identity before and after.

## Open items

- Formal test-integrity, adversarial, and integration decisions are pending
  workflow review. Surface wiring remains with the downstream plans.
