# sdwd-02: Source drift classification and auto-sync (RielaWorkflowRegistry)

**planId**: sdwd-02-source-drift-service
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-workflow-definition-store.md §4.1 (Digests, Classification, Existing stores, Auto-sync write, Concurrency, Diagnostics), §5; user-qa Q1 (2026-11-11 decision)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/sdwd-02-source-drift-service.md
**Evidence root**: tmp/stale-definition/sdwd-02-source-drift-service/

## Intent and context

ART outage: a stored head seeded with `nodeTimeoutMs = 3300000` silently
ignored a `workflow.json` edit to `21600000` for days. This plan adds the
store-side logic, which has no CLI wiring yet:

- a pure classification of head vs file
- a read-only inspection, used by doctor (sdwd-04)
- a check-and-maybe-write auto-sync, used by the resolver (sdwd-03)
- warning diagnostics with remediation text

Both wave-2 plans build on the API below. **Its names and shapes are the
contract. Do not rename them.**

Facts to rely on (already verified):

- `definition_heads.last_file_version_id` is NOT NULL from generation 10
  (`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:38`).
- `WorkflowDefinitionStore.commit` moves it for `.seed`, `.import` and
  `.forceUpdate` (the `fileOperation` rule in
  `Sources/RielaCore/WorkflowDefinitionStore.swift` around 573).
- `commit` with `expectedCurrentVersionId` throws
  `WorkflowDefinitionStoreError(code: .staleHead)` when the head moved.
- Retention always protects the last-file version.

No schema change is needed.

## Non-goals

- No change to `importDefinition`, `seedIfAbsent`, `update*`, `restore`,
  `undo`/`redo`, `prune` or the store schema. `riela instance reload`
  semantics must stay byte-identical.
- No new `WorkflowDefinitionOperation` or `WorkflowDefinitionActorKind`
  value.
- No CLI, resolver, doctor or doc edits (sdwd-03 and sdwd-04).

## File-level changes

### Sources/RielaWorkflowRegistry/WorkflowDefinitionSourceDrift.swift (new)

```swift
public enum WorkflowDefinitionSourceDriftResult: String, Codable, Equatable, Sendable {
  case inSync, autoSync, drift, sourceInvalid, sourceUnavailable
}
public struct WorkflowDefinitionSourceDriftReport: Codable, Equatable, Sendable {
  public var workflowName: String
  public var currentVersionId: String
  public var lastFileVersionId: String
  public var sourceDirectory: String
  public var result: WorkflowDefinitionSourceDriftResult
  public var fileDigest: String?      // nil when the file could not be resolved
  public var baselineDigest: String?  // nil when the baseline could not be read
  public var currentDigest: String
  public var detail: String?          // first resolver/validation error for sourceInvalid/sourceUnavailable
}
public struct WorkflowDefinitionSourceSyncOutcome: Sendable {
  public var report: WorkflowDefinitionSourceDriftReport
  public var bundle: ResolvedWorkflowBundle            // what the run must use
  public var diagnostics: [WorkflowValidationDiagnostic] // 0 or 1 warning, path "definitionStore.<name>"
  public var syncedVersion: WorkflowDefinitionVersion?
  public var audit: WorkflowDefinitionAuditRecord?
}
public enum WorkflowDefinitionSourceDrift {
  public static let autoSyncActorId = "service-auto-sync"
  /// Pure. untouched := currentVersionId == lastFileVersionId.
  public static func classify(fileDigest: String?, fileProblem: WorkflowDefinitionSourceDriftResult?,
    baselineDigest: String?, currentDigest: String, currentVersionId: String,
    lastFileVersionId: String, currentOperation: WorkflowDefinitionOperation) -> WorkflowDefinitionSourceDriftResult
  public static func diagnostic(for report: WorkflowDefinitionSourceDriftReport, path: String,
    syncedVersionId: String?, auditId: String?) -> WorkflowValidationDiagnostic
}
```

**Classification order.** Implement it as a pure function and follow this
order exactly:

1. If `fileProblem` is set (`sourceUnavailable` or `sourceInvalid`), return
   it.
2. If `fileDigest == baselineDigest` or `fileDigest == currentDigest`,
   return `inSync`.
3. If `baselineDigest == nil` (unreadable or undecodable baseline), use the
   fallback. Return `autoSync` only if
   `currentVersionId == lastFileVersionId` and `currentOperation` is
   `.seed`, `.import` or `.forceUpdate`. Otherwise return `drift`.
4. If `currentVersionId == lastFileVersionId`, return `autoSync`.
   Otherwise return `drift`.

**Diagnostic paths.** These are the exact path strings:

- `definitionStore.autoSynced`
- `definitionStore.sourceDrift`
- `definitionStore.sourceInvalid`
- `definitionStore.sourceUnavailable`
- `definitionStore.autoSyncConflict`

Severity is always `.warning`. Every message names the workflow, the
current version, the last-file version and both digests (or `unavailable`
in place of a missing digest). Then:

- **sourceDrift**: the message must contain these literal substrings:
  - `riela workflow definition diff <workflow> --file`
  - `riela instance reload`
  - `riela workflow definition import <workflow> --force --reason`
  - `riela workflow definition export <workflow> --to-source --overwrite`

  Substitute the real workflow name for `<workflow>`.
- **sourceInvalid**: append `detail`, plus "fix the file; the stored head stays in use".
- **autoSynced**: name the new version id and the audit id.

### Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift (additive only)

Add three public methods. Imitate the existing `importDefinition` (about
lines 170-241) for file resolution, document building and the commit or
error mapping. Imitate `commitAuthoredEdit` (about line 567) for the extra
validators.

```swift
public func workflowNames() throws -> [String]   // passthrough to store.workflowNames()
public func inspectSourceDrift(workflowName: String, workingDirectory: String,
  fileResolver: any WorkflowBundleResolving) throws -> WorkflowDefinitionSourceDriftReport?
public func syncFromSourceIfUntouched(workflowName: String, workingDirectory: String,
  actor: WorkflowDefinitionActor,
  fileResolver: any WorkflowBundleResolving) throws -> WorkflowDefinitionSourceSyncOutcome?
```

**Shared evaluation (private).** It returns `nil` when there is no head.

1. `store.current(workflowName:)` returns the head, the current version
   and the current document.
2. Compute `currentDigest = try WorkflowDefinitionDocument.decode(current.document).digest()`.
   This is the re-canonical digest. Do not use the stored
   `document_digest` string directly.
3. Compute `baselineDigest`. Use `store.document(versionId: head.lastFileVersionId)`,
   then decode it, then `.digest()`. If the document is missing or fails
   to decode, the value is `nil`. This must never throw.
4. File side:
   - If `FileManager.default.fileExists(atPath: head.sourceDirectory)` is
     false, the file problem is `.sourceUnavailable`.
   - Otherwise call `fileResolver.resolve(WorkflowResolutionOptions(workflowName: workflowName, workflowDefinitionDir: head.sourceDirectory, workingDirectory: workingDirectory))`.
     Resolve with the **passed `fileResolver`, never `self.fileResolver`**.
     The service's own resolver can be a prepared resolver when sdwd-03
     constructs it.
   - Any thrown error makes the file problem `.sourceInvalid`, with
     `detail = "\(error)"`, truncated to 500 chars.
   - If `bundle.workflow.workflowId != workflowName`, the result is
     `.sourceInvalid`.
   - Then run `DefaultWorkflowValidator().validate(doc.runtime.workflow)`
     plus `validateAgentNodePayload` for each node payload, exactly as
     `commitAuthoredEdit` does. Any `.error` diagnostic makes the result
     `.sourceInvalid`.
   - Otherwise build `fileDoc = WorkflowDefinitionDocument.make(from: bundle)`
     and set `fileDigest = fileDoc.digest()`. The runtime and
     `authoredFiles` therefore come from that single fresh bundle.
5. Call `classify(...)`.

**`inspectSourceDrift`** returns the report and never writes.

**`syncFromSourceIfUntouched`**:

- For a result other than `autoSync`: return an outcome whose bundle is the
  current stored bundle. Build it the same way `lookup(workflowName:)`
  does: `document(...).resolvedBundle(head:version:storeRoot:)`. Add the
  matching diagnostic. `inSync` has none.
- For `autoSync`: commit one `WorkflowDefinitionWrite` with these fields:
  - `operation: .import`
  - `documentData: fileDoc.canonicalData()`
  - `documentDigest: fileDigest`
  - `sourceDirectory: bundle.workflowDirectory`
  - `sourceScope` and `provenance` from the bundle
  - `actor: WorkflowDefinitionActor(kind: actor.kind, id: WorkflowDefinitionSourceDrift.autoSyncActorId)`
  - `reason: "auto-synced from \(head.sourceDirectory) on \(actor.id ?? actor.kind.rawValue) service run: file digest \(fileDigest) differs from last file import \(head.lastFileVersionId)"`
  - `evidence: []`
  - `diff: diffDocuments(currentDoc, fileDoc)`
  - `overwrittenChanges: nil`
  - `expectedCurrentVersionId: head.currentVersionId`
  - `defaultHistoryRetention: defaultHistoryRetention`

  On `.created(version, audit)`, return the new version's bundle (via
  `resolvedBundle` with the re-read head), the `autoSynced` diagnostic,
  `syncedVersion` and `audit`.
- **Conflict handling.** If the commit throws `staleHead`, returns
  `.alreadyRegistered`, or throws any other store or write error, do not
  retry. Re-read `store.current` once.
  - If the re-read current re-canonical digest `== fileDigest`, return that
    bundle with **no** diagnostic.
  - Otherwise return the re-read bundle with an `autoSyncConflict`
    diagnostic. Put the error in its message.
  - Only a failure of the re-read itself may throw.

## Pitfalls

- Never write when the result is not `autoSync`. Never write without
  `expectedCurrentVersionId`. A nil value makes `commit` return
  `alreadyRegistered` silently, which looks like success.
- Do not compare against `WorkflowDefinitionVersion.documentDigest`
  strings alone. Use re-canonical digests (design §4.1 Digests).
- Do not use `importDefinition(force:)`. It writes `forceUpdate` with
  overwritten changes, and it is reload's path.
- File problems never throw out of the two public methods.
- `WorkflowDefinitionActor.id` is optional. Handle nil in the reason.

## Tests: Tests/RielaCLITests/WorkflowDefinitionSourceDriftTests.swift (new)

Use temp stores and workflow directories under
`tmp/stale-definition/sdwd-02-source-drift-service/fixture-<uuid>` from the
repository root. Imitate `makeFixture()` in
`Tests/RielaCLITests/WorkflowDefinitionServiceResolutionTests.swift`, with
`defaults.nodeTimeoutMs: 3300000`. Seed with `seedIfAbsent`, using a file
bundle from `FileSystemWorkflowBundleResolver().resolve(...)`.

- **Classification table (pure `classify`)**: every row of design §4.1,
  including `fileDigest == currentDigest` with an edited head → `inSync`,
  and the nil-baseline fallback for seed, import, forceUpdate and update
  operations.
- **Untouched head, `nodeTimeoutMs` edited to 21600000** →
  `syncFromSourceIfUntouched`:
  - The report says `autoSync`. There is one new version with operation
    `.import`, and head current == `lastFileVersionId` == the new version.
  - The new version document's `runtime.workflow.defaults.nodeTimeoutMs`
    is 21600000, **and** `authoredFiles["workflow.json"]` contains
    `21600000`.
  - The audit has actor id `service-auto-sync`, the given actor kind, a
    reason starting with `auto-synced from`, and a non-empty diff.
  - There is one diagnostic with path `definitionStore.autoSynced`.
- **Second call with the file unchanged** → `inSync`, no diagnostic, and
  the history count is unchanged.
- **Edited head (`updatePrompt`), then file edit** → `drift`. The returned
  bundle's `definitionSource.versionId` equals the `updatePrompt` version.
  History is unchanged. The `sourceDrift` message contains all four
  remediation substrings.
- **`undo` back onto an older version, then file edit** → `drift`, no
  write.
- **Invalid `workflow.json` (`{`)** → `sourceInvalid`, stored bundle, no
  write. **`workflowId` changed in the file** → `sourceInvalid`.
- **`source_directory` removed** → `sourceUnavailable`, no write, no throw.
- **Head whose last file op is `forceUpdate`** (via
  `importDefinition(force: true, reason:)`), then a file edit →
  `autoSync`.
- **Conflict**: a fileResolver test double resolves the real file, and on
  `resolve` it moves the head through `service.updatePrompt` (an injected
  writer). The result is no overwrite, the bundle is the re-read head, and
  there is an `autoSyncConflict` diagnostic. A variant where the concurrent
  writer was another auto-sync to the same file gives no diagnostic and
  exactly one import audit.
- **Prepared-resolver isolation**: construct the service with
  `fileResolver: <a resolver that always returns the stale stored bundle>`.
  Call `syncFromSourceIfUntouched` with an explicit `FileSystemWorkflowBundleResolver()`. The
  file's 21600000 is imported in both runtime and authoredFiles.
- **`inspectSourceDrift`** on an untouched edited head → `autoSync`, and
  `definition_*` row counts are unchanged.
- **Regression**: `importDefinition(force: false)` on a head plus a changed
  file still returns `.differs` with no write.

## Acceptance criteria

- [x] The new file and service methods have exactly the contract
      signatures above.
- [x] No change to the existing method bodies in WorkflowDefinitionService.swift
      (the diff is additive only).
- [x] All tests above are present and pass. The existing
      `WorkflowDefinitionServiceTests`, `WorkflowDefinitionCommandTests`
      and `InstanceReloadSupportTests` pass.

## Verification (arm64; logs under the evidence root, exit code written to `<name>.exit`)

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/stale-definition/sdwd-02-source-drift-service/build.log 2>&1; echo $? > tmp/stale-definition/sdwd-02-source-drift-service/build.exit'`
   → 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionSourceDriftTests|WorkflowDefinitionServiceTests|WorkflowDefinitionCommandTests|InstanceReloadSupportTests" > tmp/stale-definition/sdwd-02-source-drift-service/test.log 2>&1; echo $? > tmp/stale-definition/sdwd-02-source-drift-service/test.exit'`
   → 0, 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet Sources/RielaWorkflowRegistry/WorkflowDefinitionSourceDrift.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift Tests/RielaCLITests/WorkflowDefinitionSourceDriftTests.swift > tmp/stale-definition/sdwd-02-source-drift-service/lint.log 2>&1; echo $? > tmp/stale-definition/sdwd-02-source-drift-service/lint.exit'`
   → 0.

Build failures in sdwd-01's files are not yours to fix. Record them and
re-run.

## Concurrency and drift protocol

Re-read each file before editing it, and record pre/post sha256 in the
progress log. If WorkflowDefinitionService.swift changed unexpectedly, stop
and record the drift. Edit only the files in writePaths.

## Progress log expectations

`impl-plans/progress/sdwd-02-source-drift-service.md` holds the commands,
exit codes, log paths, hashes and the checked acceptance list.
