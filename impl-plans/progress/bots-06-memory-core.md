# bots-06-memory-core progress

## Implemented

- Bot memory uses the existing RielaMemoryStore database for each stable bot ID. Entries carry source provenance and topic tags. Removed entries are retained as tombstones and excluded from live reads and limits.
- One writer serializes bot mutations through the session-store transaction. It validates the whole batch, redacts text before policy and size checks, and publishes the audit row after the memory writes. Undo validates every target head and restore version before mutating any entry.
- Markdown retains record identity and multiline text. The prompt renderer enforces its UTF-8 byte budget and places notes under an information-only heading. Upkeep checks the proposed note removals against current memory within the write transaction.
- The three focused suites cover storage, write policy, Markdown identity, prompt size, upkeep, audit diffs, undo and conflicts.

## Per-edit hashes

- `tmp/bots-overview/bots-06-memory-core/edit-intentions.md` records each path, its before and after SHA-256, and the intended change.
- `tmp/bots-overview/bots-06-memory-core/pre-node-snapshot.log` records the native snapshot check for the assigned paths.
- `tmp/bots-overview/bots-06-memory-core/intended-swift-final.patch` records the intended Swift hunks.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift test --filter "BotMemoryWriterTests|BotMemoryMarkdownTests|BotMemoryUndoTests"'` exited 0. `tmp/bots-overview/bots-06-memory-core/test.log` reports 20 tests and 0 failures across the three suites (9 writer, 6 Markdown, 5 undo).
- Selected-file `xargs -0 swiftlint lint --strict --quiet --no-cache` exited 0. `tmp/bots-overview/bots-06-memory-core/changed-swift.nul` contains the ten Swift paths and `tmp/bots-overview/bots-06-memory-core/swiftlint.log` is empty.
- `git status --short Packages/RielaMemory` exited 0 with empty output in `tmp/bots-overview/bots-06-memory-core/package-status.log`.
- `grep -rn "import RielaWork" Sources/RielaCore/BotMemory` exited 1 with no matches in `tmp/bots-overview/bots-06-memory-core/work-import.log`.
- The final plan-local Swift hashes matched before and after the test. The files were tested in the shared working tree. Serial integration verification covers the combined tree.

## Deviations

- Initial shared-tree test attempts stopped before tests ran. The complete logs are `test-attempt-1.log` (activity SQLite binding diagnostics), `test-attempt-2.log` (ACP command mapping diagnostic), and `test-attempt-3.log` (activity test's Swift isolation diagnostic), under `tmp/bots-overview/bots-06-memory-core/`. The sibling plans own those files.
- The initial selected-file SwiftLint log is retained as `swiftlint-attempt-1.log`. The UTF-8 conversion diagnostics were fixed in the two named files.

- `test-attempt-4.log` reports 20 tests and one failure. The test expected 176 bytes of output under a 173-byte budget. It now checks that the entire prefix fits exactly at 176 bytes and loses the oldest visible note at 175 bytes, while retaining the marker and the newer note.

## Open items

- Formal test-integrity, adversarial, and integration reviews follow implementation.
