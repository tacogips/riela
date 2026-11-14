# Evolution history completion audit

Status: verified (2026-10-15).

The requested outcome is durable, efficient reconstruction of memory, prompt
and workflow changes, with an unambiguous reconstruction format. Implementation
presence alone is not acceptance evidence.

| Requirement | Implementation / evidence source | Current evidence |
| --- | --- | --- |
| Memory stores head plus reverse changes | `RielaMemoryStore.save/update`, `MemoryEvolutionHistory`, `EvolutionReverseDelta` | Standalone RielaMemory package: 33 tests passed, including chain reconstruction and localized-edit size assertion |
| Patch direction and endpoints are explicit | `next-to-previous`, from/to version IDs, byte counts and SHA-256 hashes | Codec tests reject wrong base, wrong version, corrupted hashes/ranges and unsupported direction |
| Attachments survive replacement and reconstruct exact bytes | Retained stored files plus transactional attachment SHA-256 table | Memory tests pass replacement, historical reading and corruption rejection without a new revision |
| Restoration preserves intervening history | Memory restore appends under expected-head/write lock; workflow restore reuses existing transaction coordinator | Memory restore/stale-head tests pass; workflow restore gate passed |
| Workflow/prompt storage avoids full copies per version | Snapshot schema v2, ordered content-defined shared chunks, explicit content-addressed storageFormat | WorkflowSnapshotChunkTests: 4 tests passed, including insertion storage growth, prompt restoration, binary/empty content and corruption |
| Automatic workflow and editor publication captures changes | Registry before/after observations under workflow locks; capture before deletion; recovery reuses transaction-bound IDs | WorkflowRegistryEvolutionTests and WorkflowEditorDefinitionTests passed, including deleted prompt restoration |
| Interrupted publication remains recoverable | Immutable chunk publication; immutable snapshot publication; registry snapshot capture before transaction cleanup | WorkflowHistoryAdversarialTests (7) and WorkflowMutableRegistryTests (15) passed |
| Existing stores remain readable | Memory schema v3→v4 migration; workflow v1 raw-object decoder | Memory migration test passes; legacy workflow fixture test passed |
| History stays discoverable as workflow evolves | History owner matching ignores authored contract version; first history root is anchored in pinned registry state | Contract/root change and restore test passed |
| Listing is bounded and reconstruction work is scoped | Memory cursor/limit; workflow cursor/limit and returned-page body verification | Memory paging passes; workflow paging/corrupt-off-page test passed |
| Humans/agents can inspect and restore versions | Memory history/show-version/restore-version; existing workflow versions/show/diff/restore | MemoryEvolutionCommandTests and WorkflowVersionCommandsTests passed; real executable memory smoke also passed |
| New behavior compiles with the application | Arm64 Xcode SwiftPM build with a dedicated scratch directory and focused integration tests | RielaCLI target build passed. Final focused integration run: 94 tests, zero failures (64.1 s). 57 feature production files matched the verification source copy. |

Memory verification command (passed):

```sh
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --package-path Packages/RielaMemory --scratch-path tmp/evolution-history/memory-build
```

Root verification uses the same Swift executable with
`--scratch-path tmp/evolution-history/root-build --jobs 4` and the filter:

```text
MemoryEvolutionCommandTests|MemoryAddonFileTests|CommandParsingTests|WorkflowSnapshotChunkTests|WorkflowRegistryEvolutionTests|WorkflowVersionCommandsTests|WorkflowSharedNodeVersioningTests|WorkflowSelfImproveVersioningTests|WorkflowHistoryAdversarialTests|WorkflowMutableRegistryTests|WorkflowEditorDefinitionTests|WorkflowHistoryModelsTests
```

Changed-file SwiftLint runs passed using Xcode `xcrun swiftlint lint
--quiet --no-cache` under arm64. `git diff --check` passed for feature paths.

The first integrated test run passed 93 of 94 cases. The new registry fixture
left an unreferenced old prompt at a restoration destination, correctly invoking
the existing unowned-file collision guard. The fixture now deletes the old
prompt when replacing it, then asserts restoration recreates its exact bytes.
The repaired test passed alone, followed by all 94 focused tests passing.
The collision rejection test also passed; production restore protection was
not weakened.

Build evidence: `swift build --scratch-path tmp/evolution-history/root-build
--jobs 4 --target RielaCLI` passed with the explicit arm64 Xcode Swift executable.
The final combined test gate used `swift test --skip-build` against the freshly
built test executable and the filter above. A separate real-binary smoke ran
memory save, update, history, show-version and restore-version, asserting the
reverse direction and retained version sequence `[3, 2, 1]`.

SwiftPM reused original source paths despite an attempted frozen package path.
The executable completed compilation before testing; feature sources were
compared byte-for-byte with the captured copy (57 production files, no
differences). Results therefore cover the current feature implementation.
Scratch logs/build artifacts are disposable; the observed results are recorded
here so cleanup does not leave documentation pointing at required artifacts.

Limits to retain in final documentation: no automatic pruning; failed snapshot
publication can retain reusable orphan chunks; small workflow files occupy a
single chunk; memory's one-splice codec can retain a large span for distant
edits; workflow headers are scanned to order pages; direct filesystem edits are
observed only on the next captured mutation; Kaiba notes and generic KV state
are separate owners and are not claimed as Riela record history.
