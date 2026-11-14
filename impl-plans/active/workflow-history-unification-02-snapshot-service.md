# whu-02-snapshot-service: parentSnapshotId, unified content diff, shared snapshot service, `--content` / `--reason`

```json
{
  "planId": "whu-02-snapshot-service",
  "planPath": "impl-plans/active/workflow-history-unification-02-snapshot-service.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCore/WorkflowHistoryModels.swift",
    "Sources/RielaWorkflowRegistry/WorkflowHistoryStore.swift",
    "Sources/RielaCLI/WorkflowVersionContentDiff.swift",
    "Sources/RielaCLI/WorkflowSnapshotService.swift",
    "Sources/RielaCLI/WorkflowVersionCommands.swift",
    "Sources/RielaCLI/ParityCommandSupport.swift",
    "Tests/RielaCLITests/WorkflowVersionContentDiffTests.swift",
    "Tests/RielaCoreTests/WorkflowHistoryModelsTests.swift",
    "impl-plans/progress/whu-02-snapshot-service.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design §2 and §4 (part B). Bundle snapshots stay the file-restore auxiliary
and gain:

- an advisory `parentSnapshotId`;
- an opt-in unified text diff;
- one shared service that the CLI, GraphQL (whu-09) and rollback (whu-08)
  all call.

Follow the execution protocol in `impl-plans/active/workflow-history-unification.md`.

Current code:

- `WorkflowBundleSnapshotManifest`: `WorkflowHistoryModels.swift:265-310`.
- `WorkflowHistoryStore.createSnapshot` / `list` / `loadSnapshot` /
  `restoreSnapshot`: `WorkflowHistoryStore.swift:55-200`.
  `WorkflowSnapshotReference` is at `:13-32`.
- `WorkflowVersionCommand.run`: `WorkflowVersionCommands.swift:81-190`,
  holding list, show, diff and restore. The private `diff` is at
  `:204-223`; the private `restore` is at `:225-338` (dry run unless `--yes`,
  mutable path via `mutableRegistry.withWorkflowMutationAccess`).
- `ParsedParityOptions`: `Sources/RielaCLI/ParityCommandSupport.swift:11`
  (`--yes` is `exactYes`).
- `WorkflowHistoryCanonicalCoding`
  (`Sources/RielaCore/WorkflowHistoryCanonicalCoding.swift`) encodes and
  validates manifests and sidecars.

## Non-goals

- No definition-store sync. whu-07 adds it to `WorkflowSnapshotService.restore`.
- No GraphQL. whu-09 does that.
- No catalog or help text. whu-11 does that.
- No change to snapshot storage format, schema version or chunking.
- Do not touch `WorkflowMutableRegistry*` files, which whu-06 owns.

## Pinned API

```swift
// WorkflowHistoryModels.swift
// WorkflowBundleSnapshotManifest += parentSnapshotId: String?   (init param defaulted nil; encodeIfPresent; schemaVersion stays 2)
// WorkflowHistoryStore.swift
// WorkflowSnapshotReference += parentSnapshotId: String?
public func objectBytes(snapshot: WorkflowBundleSnapshotManifest, relativePath: String) throws -> Data   // verified object read
// WorkflowVersionContentDiff.swift
public struct WorkflowVersionContentDiff: Codable, Equatable, Sendable { public var unified: String?; public var binary: Bool; public var tooLarge: Bool; public var limitBytes: Int? }
public enum WorkflowUnifiedDiff { public static let maxBytesPerSide = 262_144
  public static func render(path: String, before: Data?, after: Data?) -> WorkflowVersionContentDiff }
// WorkflowVersionCommands.swift: WorkflowVersionDifference += content: WorkflowVersionContentDiff? (omitted when nil)
//                                WorkflowRestoreCommandResult += reason: String?, definitionVersionId: String?, definitionAuditId: String?,
//                                                                definitionWarnings: [String]?   (all nil-omitted; whu-02 leaves them nil, whu-07 fills them)
// WorkflowSnapshotService.swift
public struct WorkflowSnapshotTargetRequest: Sendable { workflowName: String; scope: WorkflowScope; workflowDefinitionDir: String?; workingDirectory: String }
public struct WorkflowSnapshotService: Sendable {
  public init(resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(), mutableRegistry: WorkflowMutableRegistry = WorkflowMutableRegistry())
  public func list(_ request: WorkflowSnapshotTargetRequest, limit: Int, beforeSnapshotId: String?) throws -> WorkflowVersionsCommandResult
  public func show(_ request: WorkflowSnapshotTargetRequest, snapshotId: String) throws -> WorkflowVersionShowCommandResult
  public func diff(_ request: WorkflowSnapshotTargetRequest, from: String, to: String, includeContent: Bool) throws -> WorkflowVersionDiffCommandResult
  public func restore(_ request: WorkflowSnapshotTargetRequest, snapshotId: String, approved: Bool, reason: String?,
                      actor: WorkflowDefinitionActor) throws -> WorkflowRestoreCommandResult
}
```

## File-level changes

1. **Manifest field.** Add `parentSnapshotId` to the manifest. Check
   whether canonical encoding is synthesized or custom:
   - if custom, emit the key only when non-nil;
   - `WorkflowHistoryCanonicalCoding.validate` must accept both the
     present and the absent forms.
2. **`createSnapshot`.** It sets `parentSnapshotId` to the newest existing
   snapshot of the same target identity in that history root (by
   `createdAt`, then `snapshotId`, using UTF-8 order), read through the
   existing `list` logic, or nil for the first snapshot. `list` exposes the
   value. Add `objectBytes`, reusing the verified read used by
   `restoreSnapshot`.
3. **`WorkflowVersionContentDiff.swift`.** Implement a deterministic line
   diff:
   - an LCS/Myers diff over lines with 3 context lines;
   - `--- a/<path>` / `+++ b/<path>` headers and `@@ -l,s +l,s @@` hunks;
   - a missing side counts as empty;
   - `binary` when either side is not valid UTF-8 or contains `0x00`;
   - `tooLarge` (`limitBytes = 262144`) when either side exceeds the limit;
   - identical bytes → no hunks.

   Do not shell out to `diff`.
4. **`WorkflowSnapshotService.swift`.** Move the body of
   `WorkflowVersionCommand.run` (identity and history-root resolution;
   list, show, diff and restore; the mutable-registry branch) into the
   service, behavior-identical.
   - Content diff fills `content` for `added`, `removed` and
     `content-modified` entries:
     - a snapshot side reads through `objectBytes`;
     - the `current` side reads the inventory file bytes
       (`WorkflowOwnedFile.bytes`).
   - Restore records `reason` in its result, as given or nil.
5. **`WorkflowVersionCommands.swift` and `ParityCommandSupport.swift`.**
   `WorkflowVersionCommand.run` becomes a thin parser and renderer over the
   service. Add the flags:
   - `--content` (`workflow version diff`);
   - `--reason <r>` (`workflow restore`). An empty-after-trim value is a
     usage error.

   Text output for diff with `--content` prints the unified block after each
   `kind path` line. JSON output without `--content` must be byte-identical
   to today's output.

## Pitfalls

- Old manifests on disk (no key) must still verify. Do not regenerate
  sidecars.
- Keep `WorkflowSnapshotService` free of definition-store calls; whu-07
  adds them.
- The restore path must still go through
  `mutableRegistry.withWorkflowMutationAccess` for mutable workflows,
  exactly as today. Use the existing closure signature: whu-06 adds an
  overload and does not change this one.
- Dirty-conflict refusal and the immutable-workflow error stay unchanged.

## Tests (`input → expected`)

`WorkflowVersionContentDiffTests`:

- Two text versions of one prompt file → `--content` gives a unified block
  with exact `@@` header and line content.
- An added file → hunks only with `+` lines. A removed file → only `-`
  lines.
- A file containing NUL → `binary: true` and no `unified`.
- 300 KiB of text → `tooLarge: true, limitBytes: 262144`.
- `executable-bit-only` → no `content`.
- Diff without `--content` → JSON equals the pre-change encoding (golden
  string).
- Snapshots: first → `parentSnapshotId` nil; second → equals the first's
  id; `list` exposes it.
- `workflow restore <id> --yes --reason "r"` → the result has `reason ==
  "r"`. `--reason "  "` → usage exit code.

`WorkflowHistoryModelsTests`:

- A manifest with no key decodes and re-encodes byte-identically.
- A manifest with the key round-trips.

## Verification (logs under `tmp/workflow-history-unification/whu-02/`)

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/workflow-history-unification/whu-02/build.log 2>&1; echo exit=$?`
  → `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowVersionContentDiffTests|WorkflowHistoryModelsTests|WorkflowVersionCommandsTests|WorkflowSharedNodeVersioningTests"' > tmp/workflow-history-unification/whu-02/tests.log 2>&1; echo exit=$?`
  → `exit=0` with 0 failures. Existing `WorkflowVersionCommandsTests`
  passing proves behavior is preserved.
- `swiftlint lint --quiet` on owned Swift files → exit 0.

## Done criteria

- [ ] Pinned symbols exist. `WorkflowVersionCommand` delegates to
      `WorkflowSnapshotService`.
- [ ] Old-manifest compatibility test passes.
- [ ] Focused tests and build are green, recorded in the progress log.
