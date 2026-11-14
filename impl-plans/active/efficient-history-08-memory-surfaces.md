# eh-08-memory-surfaces: memory CLI undo/redo/diff/retention and `memories[].historyRetention`

```json
{
  "planId": "eh-08-memory-surfaces",
  "planPath": "impl-plans/active/efficient-history-08-memory-surfaces.md",
  "dependsOn": ["eh-03-memory-history"],
  "wave": 3,
  "writePaths": [
    "Sources/RielaCLI/MemoryCommands.swift",
    "Sources/RielaCLI/MemoryCommandModels.swift",
    "Sources/RielaCLI/ParsedMemoryOptions.swift",
    "Sources/RielaCore/WorkflowModel.swift",
    "Sources/RielaCore/WorkflowMemoryValidation.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Memory.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+MemoryAddonCore.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+PersonaMemory.swift",
    "Tests/RielaCLITests/MemoryHistoryCommandTests.swift",
    "Tests/RielaCLITests/MemoryEvolutionCommandTests.swift",
    "Tests/RielaCLITests/MemoryHistoryRetirementCommandTests.swift",
    "Tests/RielaCLITests/SnapshotStoreAddonTests.swift",
    "Tests/RielaCLITests/PersonaMemoryAddonTests.swift",
    "Tests/RielaCoreTests/WorkflowMemoryHistoryRetentionValidationTests.swift",
    "impl-plans/progress/eh-08-memory-surfaces.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §3 ("Surfaces") and §2.6/§2.7. Memory needs:

- `riela memory undo|redo`;
- `show-version --diff-against`;
- `--history-retention`;
- history output for the new storage, with clear `version_not_retained`
  errors;
- a per-memory `historyRetention` declaration.

The store APIs come from eh-03 (pinned):

- `save`/`update`/`restoreRecordVersion(..., historyRetention:)`;
- `undoRecord`/`redoRecord(memoryId:recordId:expectedHeadVersion:) -> MemoryHeadMoveResult`;
- `recordDiff(memoryId:recordId:fromVersion:toVersion:)`;
- `MemoryEvolutionRevision` with `isHead`, `revision` and `storage`.

Engine errors arrive as `VersionedHistoryError` (with `.code`), or as
`RielaMemoryError.invalidHistoryRetention`.

Current code:

- `MemoryCommandKind` (`MemoryCommandModels.swift:4-16`) and the flags
  (`ParsedMemoryOptions.swift:6-31`, version flags > 0 at `:77`).
- Per-command JSON output in `MemoryCommands.swift` (history at `:97-103`).
- `WorkflowMemoryDeclaration` (`WorkflowModel.swift:229-252`) and its raw key
  allowlist (`WorkflowMemoryValidation.swift:86`).
- Memory writes from workflows happen at:
  - `DeterministicWorkflowRunner+Memory.swift:254`;
  - `ProductionNodeAdapter+MemoryAddonCore.swift:418,443`;
  - `ProductionNodeAdapter+PersonaMemory.swift:101`.
- Snapshot-store add-on writes already use R=1 inside RielaMemory (eh-03).
  This plan does not change them.

## Non-goals

- No `SurfaceCatalog` rows and no help text; eh-11 owns
  `SurfaceCatalog+RowsCLI.swift` and `RielaCLIApplication.swift` usage.
  `SurfaceParity` may fail until eh-11. Log that as outOfScope.
- No GraphQL for memory (design §9).
- `CommandParsingTests.swift` is not edited. Put parsing tests in
  `MemoryHistoryCommandTests.swift`.

## Contract

**CLI:**

```
riela memory undo <memory-id> --record-id <id> --expected-head-version <revision> [--memory-root <dir>] [--output json|jsonl|text]
riela memory redo <memory-id> --record-id <id> --expected-head-version <revision> [...]
riela memory show-version <memory-id> --record-id <id> --version <v> [--diff-against <v|head>]
riela memory save|update|restore-version ... [--history-retention <1...1000>]
```

**JSON output:**

- undo/redo → `{record, revision, headVersion, fromVersion}`.
- `show-version` with `--diff-against` → `{record, diff: [VersionedHistoryDiffEntry]}`.
  The entry JSON must match `riela workflow definition diff` entries:
  `path`, `op`, `before` and `after` as JSON values, decoded from
  `beforeJSON`/`afterJSON`, plus the optional bytes-fallback fields. Without
  `--diff-against`, the output is unchanged (`MemoryRecord`).
- `history` → new-format entries `{version, recordedAt, isHead, revision?,
  storage: {encoding, codec, storedBytes, byteCount, sha256, detached}}`.
  Legacy entries keep `reverseDelta` unchanged.
- **Errors** use the existing memory error envelope. The engine `code`
  values are `version_not_retained`, `nothing_to_undo`, `nothing_to_redo`
  and `stale_revision`. Invalid retention gives `invalid_history_retention`.
  The `version_not_retained` message lists the retained versions and says
  "dropped by retention or never a stored version".

**Declaration:** `WorkflowMemoryDeclaration.historyRetention: Int?`. The raw
allowlist adds `historyRetention`, and validation rejects values outside
1...1000 with a message naming the memory id. Workflow-driven `save`/`update`
calls pass the declared value for that memory id (nil when undeclared).

## Pitfalls

- `--expected-head-version` is required for undo/redo, as it is for
  `restore-version`. It carries the revision.
- `--diff-against head` diffs the requested version against the current
  head. A number diffs version → number. Both must be retained.
- **Declaration codable compatibility.** Decoding must accept workflows
  without the key, and encoding omits nil, so existing JSON round-trips stay
  byte-identical.
- **Snapshot-store records.** Do not pass `historyRetention` to the snapshot
  APIs. Snapshot records stay at R=1 by design (QA Q6).
- **Existing tests.** `MemoryEvolutionCommandTests` and
  `MemoryHistoryRetirementCommandTests` assume unlimited history. Make them
  pass `--history-retention` (or the API parameter) where they need several
  versions. Keep their assertions.

## Tests

`MemoryHistoryCommandTests.swift`:

- `memory update` 3 times at the default retention → `history` lists 2
  entries, the head has `isHead` and `revision`, and `show-version` of
  version 1 → exit non-zero with `version_not_retained`.
- `memory undo` → the record equals the previous value. A second `undo` →
  `nothing_to_undo`. `redo` → back. A stale expected version →
  `stale_revision`.
- `--history-retention 5` on `update` → 4 previous versions are kept.
  `--history-retention 0` → usage error.
- `show-version --diff-against head` → a `diff` array whose entries have
  `path`/`op`. The JSON key set equals the definition diff key set (assert
  the keys literally).

`WorkflowMemoryHistoryRetentionValidationTests.swift`:

- A declaration with `historyRetention: 3` validates.
- `0` and `1001` → validation errors.
- An unknown key is still rejected.
- A workflow mock run (imitate `DeterministicWorkflowRunnerMemoryTests`)
  that writes 5 times to a memory declared with `historyRetention: 3` → 2
  previous versions are kept.

Fix the existing suites (`MemoryEvolutionCommandTests`,
`MemoryHistoryRetirementCommandTests`, `SnapshotStoreAddonTests`,
`PersonaMemoryAddonTests`) only where the default retention changes their
setup.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift test --filter "MemoryHistoryCommandTests|MemoryEvolutionCommandTests|MemoryHistoryRetirementCommandTests|SnapshotStoreAddonTests|PersonaMemoryAddonTests|MemoryAddonFileTests|WorkflowMemoryHistoryRetentionValidationTests|DeterministicWorkflowRunnerMemoryTests|MemoryPayload"' > tmp/efficient-history/eh-08-memory-surfaces/test.log 2>&1; echo $?
arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet --no-cache <owned Swift files>'
```

Expected: exit 0, with every suite executed.

## Done criteria

- [ ] `riela memory undo|redo` and `--diff-against` work (tests).
- [ ] `--history-retention` is parsed. The declaration key validates.
- [ ] The listed suites pass. Every changed pre-existing test is justified
      in the progress log.
