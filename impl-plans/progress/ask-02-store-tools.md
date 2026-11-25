# ask-02-store-tools progress

Workflow mode `issue-resolution`. Branch `feat/bots-overview`. Checkpoint `a6d3f06222303970da46abd61148e778a86745a6`.
There is no GitHub issue. The scope is from `fable-sol-design-and-implement-review-loop-session-4` and the design was accepted in `comm-000297`.

## Implemented

- Added generation-13 Ask storage with transactional conversation retention, monotonic message sequence numbers, turn state, heartbeats, call and byte budgets, and action audit rows.
- Wired the 16 reads to runtime providers. Resolved session, bot, and workflow contexts on the server. The executor validates arguments, redacts values, caps serialized data, accounts for bytes, records activity, and emits typed references.
- Separated typed action proposals from user confirmation. Confirmation conditionally claims one decision, revalidates the stored target, and records the provider outcome. Confirmed audit records survive conversation deletion.
- Added deterministic tests against temporary runtime and registry stores, including a mock-scenario session and a simultaneous-confirmation test.

## Per-edit hashes

- `tmp/ask-riela/ask-02-store-tools/edit-intentions.md`
- `tmp/ask-riela/ask-02-store-tools/edit-intentions-reads.md`
- `tmp/ask-riela/ask-02-store-tools/actions/edit-intentions.md`
- `tmp/ask-riela/ask-02-store-tools/edit-intentions-cli-tests.md`

The native pre-step snapshot is `tmp/riela-fanout/C40DE5D6-BBF3-45F9-BBEA-CB0CC9FB8A23/73120988-FB65-4CDB-B39C-F72F3CD28868.json`.
The pre- and post-test source manifests match. SHA-256 of `tmp/ask-riela/ask-02-store-tools/test-source-after.txt` is `4aa089060ca0d853c79b3682da357cac0c9011554b259c3af8ae1d878617db53`.

## Verification

```sh
mkdir -p tmp/ask-riela/ask-02-store-tools
arch -arm64 /bin/zsh -lc 'swift test --filter "AskStoreTests|AskToolSetTests|AskToolExecutorTests|AskContextTests|AskReadOnlyTests|AskActionTests|BotStoreTests|BotStoreMigrationTests|ActivityRecorderTests"' > tmp/ask-riela/ask-02-store-tools/test.log 2>&1
arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/ask-riela/ask-02-store-tools/changed-swift.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'
grep -rn "stopSession\|rerunSession\|setBotPaused\|answerBotRequest" Sources/RielaCLI/Ask/Tools
git diff -- Sources/RielaCore/Bots/BotStore.swift
/bin/zsh tmp/ask-riela/ask-02-store-tools/check-diff.zsh
```

- [x] Focused Swift suite exited 0. XCTest ran 37 tests with 0 failures and Swift Testing ran 11 with 0 failures. Full log `tmp/ask-riela/ask-02-store-tools/test.log`.
- [x] Selected-file SwiftLint exited 0 on all 26 Swift files. NUL manifest `tmp/ask-riela/ask-02-store-tools/changed-swift.nul` and log `tmp/ask-riela/ask-02-store-tools/swiftlint.log`.
- [x] Read-tool mutation grep returned no matches. Log `tmp/ask-riela/ask-02-store-tools/read-only.log`.
- [x] BotStore diff has one added line and no removals. Log `tmp/ask-riela/ask-02-store-tools/bot-store-diff.log`.
- [x] Scoped whitespace check covers tracked and new plan paths. Log `tmp/ask-riela/ask-02-store-tools/diff-check.log`.

Superseded runs and their source manifests remain under `tmp/ask-riela/ask-02-store-tools/`. Attempt 1 exited 1 during compilation while the read adapter was being completed and identified a lazy sequence conversion error. Attempt 2 exited 1 while the sibling plan held the shared build database. Attempt 3 ran 48 tests and exited 1 on sealed fixture teardown. The fixture cleanup now restores directory owner-write access within its workflow-history tree before deleting the fixture.

## Deviations

- Session observation uses the GraphQL runtime snapshot query service that backs the session reads. Mutable workflow inspection uses the editor's retain-handle projection, and immutable inspection uses the structural CLI projection.
- Conversation deletion preserves a claimed confirmation until settlement so a concurrent deletion cannot erase the audit of a successful mutation. A failed confirmation is discarded if its conversation was removed.
- Conversation creation returns `ask_budget_exceeded` when every stored conversation is running and retention cannot free a slot.

## Open items

Formal review, integration, and commit handoff remain with the downstream workflow steps.
