# whu-05-definition-sync: shared store roots, `WorkflowDefinitionChangeRecording`, baseline capture, intent preparation, sync

```json
{
  "planId": "whu-05-definition-sync",
  "planPath": "impl-plans/active/workflow-history-unification-05-definition-sync.md",
  "dependsOn": [],
  "wave": 2,
  "writePaths": [
    "Sources/RielaWorkflowRegistry/WorkflowDefinitionStoreRoots.swift",
    "Sources/RielaWorkflowRegistry/WorkflowDefinitionChangeRecording.swift",
    "Sources/RielaWorkflowRegistry/WorkflowDefinitionService+FileChanges.swift",
    "Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift",
    "Sources/RielaCLI/WorkflowDefinitionStoreSelection.swift",
    "Sources/RielaCLI/CLIWorkflowSessionStore.swift",
    "Tests/RielaCLITests/WorkflowDefinitionChangeSyncTests.swift",
    "Sources/RielaCLI/WorkflowResolution.swift",
    "impl-plans/progress/whu-05-definition-sync.md"
  ],
  "sharedPaths": [
    "Sources/RielaCore/WorkflowDefinitionHistorySchema.swift",
    "Sources/RielaCore/WorkflowDefinitionStore+FileChanges.swift",
    "Sources/RielaCore/WorkflowDefinitionStore+Retention.swift",
    "Sources/RielaCore/WorkflowDefinitionStore.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionFileChangeStoreTests.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift"
  ]
}
```

## Intent and context

Design §3.2-§3.4 (A). Every committed file change becomes exactly one
definition sync, attributed to the change path. The sync lands in the
store a service run would read. A first tracked change of an existing
workflow gets a baseline parent. This plan builds the reusable machinery.
whu-06 (registry) and whu-07 (coordinator) call it. Follow the execution
protocol in the index plan.

Code to reuse:

- Store-root rules:
  - `Sources/RielaCLI/WorkflowDefinitionStoreSelection.swift`:
    `rootWithHead`, `candidateRoots`, `seedRoot`, `normalizedRoot`;
  - `CLIWorkflowSessionStore.resolveRootDirectory`
    (`CLIWorkflowSessionStore.swift:93-118`: `--session-store`, then
    `RIELA_SESSION_STORE`, then `~/.riela/sessions` for user, otherwise
    `<cwd>/.riela/sessions`).
- Force-import pipeline:
  - `WorkflowDefinitionService.importDefinition` (`:170-243`), including the
    overwritten-changes computation at `:213-221` and the commit at
    `:222-241`;
  - `seedIfAbsent` (`:141`);
  - the authored-edit pipeline with overlay (`:530-575`:
    `WorkflowAuthoredFileOverlay`,
    `WorkflowResolutionOptions(authoredOverlay:)`,
    `WorkflowDefinitionDocument.make(from:authoredOverlay:)`, the
    validators);
  - the `.fromDirectory` collector (`:265-270`:
    `WorkflowDefinitionDocument.make(from: bundle).authoredFiles`).
- whu-01 API:
  - `isChangeComplete`, `recordAuditOnlyChange`, `isFileDerived`;
  - `WorkflowDefinitionWrite.rollbackProposalId`;
  - the new operations and evidence kinds.

## Non-goals

- Do not call the sync from the registry or the coordinator; whu-06 and
  whu-07 do that.
- No CLI or GraphQL surface.
- Do not change service-run resolution behavior.

## Pinned API (consumed by whu-06/07/08)

```swift
// WorkflowDefinitionChangeRecording.swift (RielaWorkflowRegistry)
public struct WorkflowDefinitionChangeAttribution: Codable, Equatable, Sendable {
  public var operation: WorkflowDefinitionOperation      // registryWrite|registryDelete|snapshotRestore|selfImprove|rollback
  public var actor: WorkflowDefinitionActor
  public var reason: String
  public var evidence: [WorkflowDefinitionEvidenceRef]   // caller evidence; the recorder appends fileTransaction / snapshot refs
  public var expectedHeadVersionId: String?              // set only for rollback (CAS, never rebased)
  public var rollbackProposalId: String?                 // set only for rollback
}
public struct WorkflowDefinitionSyncIntent: Codable, Equatable, Sendable {
  public var schemaVersion: Int                          // 1
  public var transactionId: String
  public var workflowName: String
  public var storeRoot: String
  public var sourceDirectory: String                     // the LIVE directory
  public var sourceScope: String
  public var documentDigest: String
  public var documentJSON: String                        // canonical document text
  public var expectedAfterBundleDigest: String?
  public var bundleSnapshotBefore: String?
  public var bundleSnapshotAfter: String?
  public var attribution: WorkflowDefinitionChangeAttribution
}
public enum WorkflowDefinitionBaselineOutcome: Equatable, Sendable { case captured(versionId: String); case headExists(versionId: String) }
public enum WorkflowDefinitionSyncOutcome: Equatable, Sendable {
  case versionWritten(WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord, overwrittenAuditIds: [String])
  case auditOnly(WorkflowDefinitionAuditRecord); case collapsed; case alreadyComplete; case noHead
}
public protocol WorkflowDefinitionChangeRecording: Sendable {
  func storeRoot(workflowName: String, sourceScope: WorkflowScope) throws -> String
  func captureBaselineIfAbsent(workflowName: String, liveDirectory: URL, sourceScope: WorkflowScope, transactionId: String,
                               actor: WorkflowDefinitionActor, operation: WorkflowDefinitionOperation,
                               bundleSnapshotBefore: String?) throws -> WorkflowDefinitionBaselineOutcome?   // nil = no store write needed (workflow does not exist yet)
  func prepareIntent(workflowName: String, stagingDirectory: URL, liveDirectory: URL, sourceScope: WorkflowScope, transactionId: String,
                     expectedAfterBundleDigest: String?, bundleSnapshotBefore: String?, bundleSnapshotAfter: String?,
                     attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncIntent
  func sync(_ intent: WorkflowDefinitionSyncIntent) throws -> WorkflowDefinitionSyncOutcome
  func recordDelete(workflowName: String, sourceScope: WorkflowScope, transactionId: String,
                    bundleSnapshotBefore: String?, attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncOutcome
}
public struct WorkflowDefinitionChangeRecorder: WorkflowDefinitionChangeRecording {
  public init(sessionStoreRoot: String? = nil, workingDirectory: String = FileManager.default.currentDirectoryPath,
              environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
              fileResolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver())
}
// WorkflowDefinitionService.restore(... , expectedVersionId: String? = nil)  — CAS: mismatch → definition_conflict (existing conflict helper)
```

## File-level changes

1. **`WorkflowDefinitionStoreRoots.swift` (new, RielaWorkflowRegistry).**
   Move the pure logic of `resolveRootDirectory`, `candidateRoots`,
   `normalizedRoot` and `rootWithHead` here as `public enum
   WorkflowDefinitionStoreRoots` (the same signatures, plus
   `environment`).
   - Add `seedRoot(sessionStore:sourceScope:workingDirectory:environment:)`:
     `.user` → the user root; every other scope → the project root.
     Prove equivalence with the CLI `seedRoot` in a test for `user`,
     `project` and `direct` bundles.
   - `WorkflowDefinitionStoreSelection` and
     `CLIWorkflowSessionStore.resolveRootDirectory` then delegate to it,
     with identical behavior.
2. **`WorkflowDefinitionChangeRecording.swift` (new).** The types above,
   plus the production recorder. Store roots are computed with
   `rootWithHead(candidateRoots(sessionStoreRoot, scope: sourceScope ==
   .user ? .user : .project, …))`, falling back to `seedRoot`. Every
   environment read goes through the injected `environment`, never
   `ProcessInfo` directly.
3. **`WorkflowDefinitionService+FileChanges.swift` (new)**, called by the
   recorder:
   - **`captureBaselineIfAbsent`.**
     - Resolves the live directory with `fileResolver`, using `scope:
       .direct`, the parent directory as `workflowDefinitionDir` and
       `includeDeactivated: true`, exactly as in `:546-552`.
     - Builds the document and calls `store.commit` with operation
       `.import`, `expectedCurrentVersionId: nil`, reason `baseline
       captured before first tracked <operation> (<tx>)`, and evidence
       `[baselineTransaction:<tx>]` plus `bundleSnapshotBefore` when given.
     - `.alreadyRegistered(head)` → `.headExists`.
     - Never include `fileTransaction`.
   - **`committedDocument`**, used by `prepareIntent`.
     - Resolve the staging directory to collect its authored files (the
       `:265-270` collector).
     - Re-derive at the live directory with `WorkflowAuthoredFileOverlay`
       (`:540-575`), so stdio paths are absolute under the live directory.
     - Run the same validators and return the canonical data and digest.
     - When the live directory does not exist yet (registry create),
       callers pass `stagingDirectory == liveDirectory` after publication.
   - **`sync(intent)`** steps (WHU-R5-01):
     1. `isChangeComplete(op, tx, documentDigest: nil)` true →
        `.alreadyComplete`. This checks **predicate (a) only**. Do not pass
        the digest here: predicate (b) would make step 3 unreachable, and
        the first unchanged-digest change must still record its single
        audit-only row (design §3.3).
     2. No head → commit (operation = `attribution.operation`, parent nil,
        `expectedCurrentVersionId: nil`). A concurrent seed winner leads to
        step 3 or step 4.
     3. The head digest equals the intent digest and `op != .rollback` →
        `recordAuditOnlyChange(operation: op, evidence:
        attribution.evidence + [fileTransaction:<tx>] +
        [bundleSnapshotBefore:<id>, bundleSnapshotAfter:<id> when
        present])`, giving `.auditOnly` or `.collapsed`.
        - **Replay is idempotent.** A recorded row satisfies predicate (a)
          on the next step 1. A collapsed call writes nothing again,
          because collapse matches (head version, operation).
        - **Rollback cannot reach this step.** A `rollback` intent never
          has a digest equal to the head: `vT` differs from its parent by
          construction. If it ever does, throw `invalidDefinition`
          ("rollback target equals head") and write nothing.
     4. Otherwise commit a write with:
        - operation = `attribution.operation`;
        - evidence = `attribution.evidence` + `fileTransaction:<tx>` +
          snapshot refs;
        - `overwrittenChanges` computed as at `:213-221`, where the
          store-only filter becomes `[.updatePrompt, .update, .restore,
          .undo, .redo]` plus `.rollback` without `fileTransaction`
          evidence;
        - `rollbackProposalId` = `attribution.rollbackProposalId`;
        - `expectedCurrentVersionId` = `attribution.expectedHeadVersionId`
          when set, otherwise the head read in step 3.
     5. On `staleHead`, retry from step 1 up to 3 times only when
        `expectedHeadVersionId == nil`. A rollback never retries. Its
        `staleHead` propagates.
   - **Where the full predicate is used.** The full predicate (a)∨(b),
     called with the intent's digest, is used only for completion decisions
     outside `sync`:
     - whu-06: deciding a pending registry record is already synced during
       recovery;
     - whu-07: intent deletion and replay skip;
     - whu-08: bundle-claim recovery, where it reduces to (a) because the
       op is `rollback`.

     Expose it unchanged from whu-01. Do not wrap it in a new helper.
   - **`recordDelete`.** `recordAuditOnlyChange(registryDelete)` with
     evidence `fileTransaction` plus `bundleSnapshotBefore`. No head →
     `.noHead`. It never captures a baseline.
4. **`WorkflowDefinitionService.swift`.**
   - Change `private` to `internal` on the helpers the extension needs
     (`document(_:)`, `diffDocuments`, `requireReason`, `invalidDefinition`,
     `conflict`); keep them out of the public API.
   - Add `expectedVersionId` to `restore`, checked against
     `current.head.currentVersionId` before the write and passed as
     `expectedCurrentVersionId`.

## Pitfalls

- A baseline must never carry `fileTransaction` (D3-001). The sync must
  write the change on top of the baseline.
- Collapse is per (head version, operation). An unchanged no-op never
  creates a version (Q7).
- A rollback intent must CAS on `expectedHeadVersionId` and never fall back
  to the current head.
- Tests must isolate HOME / `RIELA_SESSION_STORE`; see the index protocol.

## Tests (`WorkflowDefinitionChangeSyncTests`; input → expected)

- **First use.** A file workflow with no head: baseline → `.captured(B)`
  (operation `import`, `baselineTransaction:T`, no `fileTransaction`).
  Then edit the prompt in staging, prepare the intent and sync →
  `.versionWritten(I)` with parent B, operation `selfImprove`, evidence
  containing `fileTransaction:T`. The head digest equals the intent
  digest. `undo` returns to B.
- **Replay.** Sync of the same intent again → `.alreadyComplete`, and the
  row count is unchanged.
- **Baseline negative.** Only B present (no sync yet): `isChangeComplete`
  → false, and sync writes I.
- **No-op collapse.** Five syncs of unchanged content with distinct
  transaction ids T1…T5 →
  - zero new versions;
  - exactly one audit-only row, whose operation is the intent's, whose
    evidence contains `fileTransaction:T1` and the bundle snapshot refs,
    and whose `version_id == previous_version_id == head`;
  - T2…T5 return `.collapsed`.
- **Replay of a collapsed no-op.** Re-sync T3's intent → `.collapsed` or
  `.alreadyComplete`, with no new row. The full-predicate call
  `isChangeComplete(op, T3, documentDigest: d)` → true via (b). Re-sync
  T1's intent → `.alreadyComplete` via (a).
- **First unchanged change is recorded.** A head with digest d and one
  sync of a d-digest intent → `.auditOnly`, never `.alreadyComplete`
  (regression for WHU-R5-01).
- **Overwrite.** A store-only `update` U after the last file version, then
  sync → `overwrittenAuditIds` contains U's audit, and
  `last_file_version_id` = I.
- **Rollback CAS.** An intent with `expectedHeadVersionId` = a stale id →
  `staleHead`, with no retry and no rows.
- **Delete.** With a head → one audit-only `registryDelete`. Without a
  head → `.noHead` and zero rows.
- **Store roots.** A user-scope workflow with
  `environment["HOME"]=<tmp>` → `<tmp>/.riela/sessions`. With
  `RIELA_SESSION_STORE` set → that root. The shared roots equal the CLI
  `seedRoot` for user, project and direct.
- **Restore CAS.** `restore(expectedVersionId: stale)` →
  `definition_conflict`, and nothing is written.

## Verification (logs under `tmp/workflow-history-unification/whu-05/`)

- `arch -arm64 /bin/zsh -lc 'swift build' > tmp/workflow-history-unification/whu-05/build.log 2>&1; echo exit=$?`
  → `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionChangeSyncTests|WorkflowDefinitionServiceTests|WorkflowDefinitionServiceResolutionTests|WorkflowDefinitionCommandTests"' > tmp/workflow-history-unification/whu-05/tests.log 2>&1; echo exit=$?`
  → `exit=0`. The existing resolution and command suites prove the
  root-resolution move preserved behavior.
- `swiftlint lint --quiet` on owned files → exit 0.

## Done criteria

- [ ] Pinned types and protocol exist. The CLI selection delegates to
      `WorkflowDefinitionStoreRoots`.
- [ ] All tests above pass, and the existing definition suites stay green.

## Operator decision (2026-11-02): resolver ownership

Use caller injection. `RielaCLI` depends on `RielaWorkflowRegistry`, so registry code must not reference `FileSystemWorkflowBundleResolver`. Give the whu-05 registry-side APIs a resolver parameter (`any WorkflowBundleResolving`, or an equivalent closure if the protocol is not visible to the registry module; move only the protocol, not the implementation, if needed). Update the `RielaCLI` call sites, including `Sources/RielaCLI/WorkflowResolution.swift`, to pass `FileSystemWorkflowBundleResolver`. whu-01..04 are accepted in 542c71f5 and are no longer dependencies.

## Operator decision (2026-11-02): atomic unchanged-digest audit

whu-05 may edit the accepted definition-store core (sharedPaths). Add the expected-head (CAS) check inside the same SQLite transaction as the unchanged-digest audit write in `WorkflowDefinitionStore+FileChanges.swift`, with a deterministic regression test for a concurrent store-only head move. Also make the root-equivalence test compare against CLI selection and make the restore CAS test assert the correct service error.
