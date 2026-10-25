# DS179-02 Definition Document and Operations Service (RielaWorkflowRegistry)

**planId**: `ds179-02-definition-service`
**Status**: Ready for implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: tacogips/riela#179 section 2 + execution-mode policy + (A) whole-workflow update with mandatory reason
**Design Reference**: `design-docs/specs/design-workflow-definition-store.md` §3 (stored document), §5 (operations, authored view and authored-edit pipeline, validation), §6 (diff), §7 (export); QA Q7
**dependsOn**: none (ds179-01-store-core is an accepted dependency, commit 6337aa24)
**Branch**: `feat/definition-store-179` (local commits only; `gitPush=false`)
**Progress log**: `impl-plans/progress/ds179-02-definition-service.md`

## Intent and context

This plan builds the stored document from a resolved file bundle and turns
a stored version back into a `ResolvedWorkflowBundle`. It implements every
definition operation as a library service:

- seed, import, force import
- the whole-workflow `update` (JSON Patch, authored files or from-file;
  user requirement (A))
- update-prompt, rebuilt on the same authored-edit pipeline
- restore, history, show (including the authored view), diff, export

The CLI resolver (03), the CLI commands (04), GraphQL (05) and the
improvement add-ons (07) are thin callers of this service.

Whole-workflow edits never touch the `runtime` part directly:

1. They edit the authored files.
2. They re-derive `runtime` by running the normal file resolver at the
   head's `source_directory`, with own-directory reads (workflow.json,
   node files, prompt files) served from an in-memory overlay.

`export` therefore stays exact, and relative stdio paths stay absolute
under the real source directory (design §5).

Repository facts:

- `ResolvedWorkflowBundle` (`Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift:5`)
  is Equatable but not Codable. Its parts are Codable:
  - `WorkflowDefinition`
  - `AgentNodePayload`
  - `WorkflowPackageManifest`
- The loader is `WorkflowRegistryBundleLoader.loadBundle` (`:78`):
  - It reads `workflow.json` and then each `nodeRegistry[].nodeFile`.
  - It hydrates prompts with `PromptTemplateAssetLoader.hydrate`
    (`Sources/RielaCore/PromptTemplateAssets.swift:26`). Hydration fills
    `promptTemplate` / `systemPromptTemplate` / `sessionStartPromptTemplate`
    and the `promptVariants[key]` equivalents, and keeps the `*File` paths.
  - It makes stdio paths absolute (`:203`).
- Materialization sets a default `nodeFile` for every registry node
  (`Sources/RielaCore/WorkflowValidation.swift:624`). Nodes that come from
  `nodeRef` or an `extends` base live in other directories.
- `resolvePromptTemplatePath` (`PromptTemplateAssets.swift:103`) is the
  containment-checked relative path resolver. Reuse it for authored-file
  collection and for export path validation.
- Validators: `DefaultWorkflowValidator().validate(_:)` (`WorkflowValidation.swift:35`)
  and `validateAgentNodePayload` (`Sources/RielaCore/WorkflowNodeValidation.swift:3`).
- Canonical JSON: `JSONCanonical.encode` / `sha256Hex`. Store API: plan 01's
  `WorkflowDefinitionStore`.
- **Own-directory file reads.** The overlay must cover exactly these three
  reads:
  - `WorkflowRegistryBundleLoader.loadBundle` reads `workflow.json` at
    `WorkflowRegistryBundleLoader.swift:97` (`Data(contentsOf: workflowURL)`)
    and each own node file at `:146`.
  - It hydrates prompts at `:149` through `PromptTemplateAssetLoader.hydrate`.
    The text read is `String(contentsOf:)` at `PromptTemplateAssets.swift:99`.
  - A derived (`extends`) workflow reads only its own `workflow.json`.
    `loadInheritedBundle`
    (`WorkflowRegistryBundleLoader+Inheritance.swift:11`) takes its payloads
    from the base and reads no other own file.

  The shared-node reads in `WorkflowRegistryBundleLoader+SharedNodeRefs.swift:208,268,271`
  belong to other directories. They must NOT use the overlay.
- `WorkflowResolutionOptions` (`WorkflowRegistryBundleLoader.swift:47`) is
  `Codable, Equatable, Sendable` with synthesized coding.
- The file resolver is `FileSystemWorkflowBundleResolver`
  (`Sources/RielaCLI/WorkflowResolution.swift:31`):
  - `resolveCandidate` (`:258`) checks that `workflow.json` exists on disk
    (`:269-271`) and calls `loadBundle` (`:273`, delegating at `:706`).
  - With `workflowDefinitionDir`, the candidates are `<dir>/<workflowName>`
    and then `<dir>` itself (`candidateDirectories`, `:503-514`).
  - The inheritance base resolver builds fresh `WorkflowResolutionOptions`
    (`:289-296`, `:315-321`). Those must not inherit the overlay.
- No JSON Patch implementation exists in `Sources/`. There is a private
  pointer reader in `DeterministicWorkflowRunner+Fanout.swift:656` and a
  pointer escaper in `WorkflowRegistryGraphQLProvider.swift:661`; neither
  is public. Write a small RFC 6902 applier; do not add a package
  dependency.

## Non-goals

- No CLI parsing, no GraphQL, and no changes to `WorkflowRunCommand`.
- Do not store scripts, mock scenarios or add-on files.
- Do not change the loader's existing behavior for file runs. With
  `authoredOverlay == nil`, every code path must be byte-for-byte the
  current behavior.
- Do not extend `riela workflow update` or `WorkflowRegistryService.update`.
  They stay mutable-registry file operations (design §11).
- No JSON Patch `move` or `copy` ops (design §5 lists add, remove, replace
  and test).

## Pinned contract (plans 03, 04, 05 and 07 call these exactly)

In `Sources/RielaWorkflowRegistry/WorkflowDefinitionDocument.swift` (new):

- `public struct WorkflowDefinitionDocument: Codable, Equatable, Sendable`
  - `formatVersion: Int` (always 1)
  - `runtime: Runtime`
  - `authoredFiles: [String: String]`
  - `public struct Runtime: Codable, Equatable, Sendable { workflow: WorkflowDefinition; nodePayloads: [String: AgentNodePayload]; packageManifest: WorkflowPackageManifest? }`
  - `static func make(from bundle: ResolvedWorkflowBundle) throws -> Self`
  - `func canonicalData() throws -> Data`
  - `func digest() throws -> String`
  - `static func decode(_ data: Data) throws -> Self`
  - `func resolvedBundle(head: WorkflowDefinitionHead?, version: WorkflowDefinitionVersion, storeRoot: String) -> ResolvedWorkflowBundle`.
    It sets:
    - `workflowDirectory = version.sourceDirectory`
    - `sourceScope = WorkflowScope(rawValue: version.sourceScope) ?? .direct`
    - `provenance` from `version.provenance`
    - `packageManifest`
    - `definitionSource = .init(kind: .store, workflowName, versionId, storeRoot: <absolute storeRoot>, digest: version.documentDigest, sourcePath: version.sourceDirectory, sourceScope: version.sourceScope)`

    The service passes its own `storeRoot`.
- `public static func fileDefinitionSource(for bundle: ResolvedWorkflowBundle, workflowName: String) -> WorkflowDefinitionSource`.
  It is best effort and never throws:
  - It builds the document; any unreadable authored file is omitted.
  - On encode failure the digest is computed over the `runtime` part only.
  - The result has `kind .file`, `sourcePath = bundle.workflowDirectory`
    and `sourceScope = bundle.sourceScope.rawValue`.

In `WorkflowRegistryBundleLoader.swift`:

- Add `public var definitionSource: WorkflowDefinitionSource?` to
  `ResolvedWorkflowBundle` (init default nil).
- Add `public var authoredOverlay: WorkflowAuthoredFileOverlay?` to
  `WorkflowResolutionOptions`. Default it to nil in the init, and keep
  synthesized Codable (a missing key decodes as nil).
- Add a trailing `authoredOverlay: WorkflowAuthoredFileOverlay? = nil`
  parameter to `loadBundle(at:...)`. When it is non-nil, the `workflow.json`
  read (`:97`), the node-file read (`:146`) and the `hydrate` call (`:149`)
  take their bytes from the overlay. They never read disk, even when the
  key is missing; a missing key throws `invalidWorkflow` with a diagnostic
  that names the path. Shared-node and inheritance-base reads are unchanged.

In `Sources/RielaCore/WorkflowAuthoredFileOverlay.swift` (new):

```
public struct WorkflowAuthoredFileOverlay: Codable, Equatable, Sendable {
  public private(set) var files: [String: String]   // normalized relative path -> UTF-8 text
  public init(files: [String: String]) throws        // normalizes keys; rejects absolute, "..", empty, collisions
  public func text(at fileURL: URL, workflowDirectory: URL) -> String?
}
```

Key normalization: strip a leading `./`, collapse `a/./b`, and reject any
path that escapes after standardizing. `text(at:workflowDirectory:)`
computes the path relative to the standardized, symlink-resolved
`workflowDirectory` and looks up the normalized key.

In `Sources/RielaCore/PromptTemplateAssets.swift`, give
`PromptTemplateAssetLoader.hydrate(_:workflowDirectory:)` a trailing
`overlay: WorkflowAuthoredFileOverlay? = nil` parameter. When it is set,
the `:99` text read uses `overlay.text(at:workflowDirectory:)`, and a nil
result throws the existing missing-asset `PromptTemplateAssetLoadingError`.
The containment check in `resolvePromptTemplatePath` still runs first.

In `Sources/RielaCLI/WorkflowResolution.swift`
(`FileSystemWorkflowBundleResolver`):

- `resolveCandidate` treats `workflow.json` as present when
  `options.authoredOverlay?.files["workflow.json"] != nil`.
- It passes `options.authoredOverlay` to `loadBundle`, and from there to
  the registry loader.
- The inheritance base resolver closures build their own options. Leave
  them without an overlay.
- The mutable-registry branch (`:104-159`) is not reached for `.direct`
  scope. Do not thread the overlay into it.

In `Sources/RielaWorkflowRegistry/WorkflowDefinitionJSONPatch.swift` (new):

- `enum WorkflowDefinitionJSONPatch { static func apply(_ patch: JSONValue, to document: JSONValue) throws -> JSONValue }`
- RFC 6902 ops `add`, `remove`, `replace` and `test`, with RFC 6901
  pointers (`~1` is `/`, `~0` is `~`).
- `add` to an array index inserts, and `-` appends. `add` to an object
  member creates or replaces it.
- `remove` or `replace` of a missing target fails. `test` uses `JSONValue`
  `==`.
- Any other op, a non-array patch, or a malformed entry throws
  `WorkflowDefinitionServiceError(code: .invalidPatch)`.
- Ops apply in order to a working copy; any failure returns no partial
  result.
- `static func pointer(_ tokens: [String]) -> String`: an escaping helper
  that plans 04 and 07 reuse.

In `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift` (new):

- `public enum WorkflowDefinitionPromptField: Equatable, Sendable`, with
  `case node(Kind)`, `case variant(key: String, Kind)` and
  `enum Kind: String { promptTemplate, systemPromptTemplate, sessionStartPromptTemplate }`.
  Add `init(parsing: String) throws`. It accepts exactly `promptTemplate`,
  `systemPromptTemplate`, `sessionStartPromptTemplate`, and
  `promptVariants.<key>.<kind>`; anything else throws.
- `public struct WorkflowDefinitionServiceError: Error, Equatable, CustomStringConvertible { var code: Code; var message: String }`
  with `enum Code: String, Codable { case reasonRequired = "reason_required", definitionNotRegistered = "definition_not_registered", definitionConflict = "definition_conflict", invalidPatch = "invalid_patch", invalidDefinition = "invalid_definition" }`.
  Map store errors at the service boundary:
  - `missingReason` → `reason_required`
  - `headMissing` → `definition_not_registered`
  - `staleHead` → `definition_conflict`

  Every other store error is rethrown unchanged. Validation and resolve
  failures of a new document → `invalid_definition`.
- `public enum WorkflowDefinitionUpdateSource: Equatable, Sendable { case patch(JSONValue); case authoredFiles([String: String]); case fromDirectory(WorkflowResolutionOptions) }`
- `public enum WorkflowDefinitionUpdateOutcome: String, Codable { updated, unchanged }`
- `public struct WorkflowDefinitionUpdateResult: Codable, Equatable { outcome; versionId: String; digest: String; version: WorkflowDefinitionVersion?; audit: WorkflowDefinitionAuditRecord?; diff: [WorkflowDefinitionDiffEntry] }`.
  For `unchanged`, `versionId`/`digest` are the current head's values and
  `version`/`audit` are nil.
- `WorkflowDefinitionDocument.authoredView() throws -> JSONValue`: an
  object keyed by the `authoredFiles` keys. Values ending in `.json` are
  parsed into `JSONValue`; any other value is `.string(text)`.
- `WorkflowDefinitionDocument.authoredFiles(fromView: JSONValue, previous: [String: String]) throws -> [String: String]`:
  - An entry whose view value is unchanged from `previous`'s parsed value
    keeps the previous verbatim text.
  - A changed `.json` entry is re-serialized with
    `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` plus a trailing
    newline.
  - A non-`.json` entry must be a string, else `invalid_patch`.
  - Top-level non-object view → `invalid_patch`.
- `public enum WorkflowDefinitionImportOutcome: String, Codable { seeded, unchanged, differs, forceUpdated }`
- `public struct WorkflowDefinitionImportResult: Codable, Equatable { outcome; version: WorkflowDefinitionVersion?; diff: [WorkflowDefinitionDiffEntry]; audit: WorkflowDefinitionAuditRecord? }`
- `public enum WorkflowDefinitionExportTarget { case directory(String); case source(overwrite: Bool) }`
- `public struct WorkflowDefinitionExportedFile: Codable, Equatable { path: String; content: String }`
- `public struct WorkflowDefinitionService: Sendable`, with
  `init(storeRoot: String, fileResolver: any WorkflowBundleResolving)`.
  Methods:
  - `func lookup(workflowName: String) throws -> ResolvedWorkflowBundle?`
    — store only, no file IO.
  - `func loadPinned(versionId: String) throws -> ResolvedWorkflowBundle`
    — throws `versionNotFound`.
  - `func seedIfAbsent(fileBundle: ResolvedWorkflowBundle, workflowName: String, actor: WorkflowDefinitionActor) throws -> ResolvedWorkflowBundle`.
    Reason: `"seeded from <workflowDirectory> on first service run"`. On
    `.alreadyRegistered` it returns the winner's current version via
    `lookup`.
  - `func importDefinition(resolution: WorkflowResolutionOptions, force: Bool, reason: String?, evidence: [WorkflowDefinitionEvidenceRef], actor: WorkflowDefinitionActor) throws -> WorkflowDefinitionImportResult`
  - `func update(workflowName: String, source: WorkflowDefinitionUpdateSource, reason: String, expectedVersionId: String?, evidence: [WorkflowDefinitionEvidenceRef], actor: WorkflowDefinitionActor) throws -> WorkflowDefinitionUpdateResult`
  - `func authoredView(workflowName: String, versionId: String?) throws -> (version: WorkflowDefinitionVersion, view: JSONValue)`.
    Read only. Used by `show --authored` (04) and the context add-on (07).
  - `func updatePrompt(workflowName: String, nodeId: String, field: WorkflowDefinitionPromptField, text: String, reason: String, expectedVersionId: String?, evidence: [...], actor: ...) throws -> (WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord)`.
    An unchanged result (same text) throws `invalid_definition` with the
    message "prompt unchanged".
  - `func restore(workflowName: String, versionId: String, reason: String, evidence: [...], actor: ...) throws -> (WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord)`
  - `func history(workflowName: String, nodeId: String?, limit: Int?) throws -> [WorkflowDefinitionAuditRecord]`
  - `func show(workflowName: String, versionId: String?) throws -> (head: WorkflowDefinitionHead, version: WorkflowDefinitionVersion, document: WorkflowDefinitionDocument)`
  - `func diff(workflowName: String, fromVersionId: String?, toVersionId: String?, againstFile: WorkflowResolutionOptions?) throws -> [WorkflowDefinitionDiffEntry]`.
    With no versions and no file it compares the head with the file
    resolution for `workflowName` (`WorkflowResolutionOptions(workflowName:)`).
  - `func export(workflowName: String, versionId: String?, target: WorkflowDefinitionExportTarget?) throws -> [WorkflowDefinitionExportedFile]`.
    A nil target returns the files without writing them (used by GraphQL).

## File-level changes and rules

1. **`make(from:)` — authored-file collection.**
   - `root` is the bundle's `workflowDirectory`.
   - Always include `workflow.json`.
   - For each `workflow.nodeRegistry` entry with `nodeRef == nil` and a
     `nodeFile` that resolves inside `root` (`resolvePromptTemplatePath`
     with the field name `nodeFile`) and exists: include the file's text.
     Decode that file as `AgentNodePayload` and include every `*File`
     prompt path it names, including `promptVariants`, when it resolves
     inside `root` and exists.
   - Store text verbatim. Read as UTF-8; a non-UTF-8 file is a thrown error
     in `make` (best-effort omission applies only in
     `fileDefinitionSource`).
   - Keys are the relative paths exactly as authored.
2. **Round-trip.** `Runtime` encodes with `JSONCanonical.encode` and
   decodes with `JSONCanonical.decoder()`. The test below asserts
   `decode(encode(x)) == x` for the bundles used in the suite. If a
   field is lossy, stop and report it in the progress log as a blocker.
   Do not paper over it.
3. **`importDefinition`.**
   - The file bundle is `fileResolver.resolve(resolution)`, and
     `fileDoc = make(from:)`.
   - **No head:**
     - With `force` set, throw `headMissing` ("not registered; run import
       without --force").
     - Otherwise commit `import`. The reason is the trimmed given reason,
       or `"initial import from <dir>"`. The outcome is `seeded`.
   - **Head exists, `!force`:** write nothing. Return `unchanged` when the
     digests are equal, else `differs`, with
     `WorkflowDefinitionDiff.compute(storeDoc → fileDoc)`.
   - **Head exists, `force`:**
     - A missing or blank reason throws `missingReason`. Check this before
       any resolve or read.
     - `overwritten = { sinceVersionId: head.lastFileVersionId, auditIds: store.auditRecords(after: lastFileVersionId).filter{ updatePrompt|update|restore }.map(\.auditId), diff: compute(doc(lastFileVersionId) → doc(current)) }`
     - Commit `forceUpdate` with `expectedCurrentVersionId = head.currentVersionId`,
       `diff = compute(current → fileDoc)`, and target nil.
     - `sourceDirectory` and `sourceScope` of the write come from the file
       bundle. A force import from an explicit `--workflow-definition-dir`
       therefore moves the head's recorded source (design §5).
     - The outcome is `forceUpdated`.
4. **The authored-edit pipeline** is one private helper,
   `commitAuthoredEdit(newAuthoredFiles:operation:target:reason:expected:evidence:actor:)`.
   `update` and `updatePrompt` both use it. Order:
   1. Reject a blank reason (`reason_required`) before any store read.
   2. Read the current head and document. If there is no head, throw
      `definition_not_registered`. If `expected` is non-nil and differs
      from `head.currentVersionId`, throw `definition_conflict`.
   3. Build `WorkflowAuthoredFileOverlay(files: newAuthoredFiles)`. A bad
      key → `invalid_patch`.
   4. **Re-derive.** Call `fileResolver.resolve(WorkflowResolutionOptions(workflowName: <last path component of head.sourceDirectory>, scope: .direct, workflowDefinitionDir: <parent of head.sourceDirectory>, workingDirectory: <parent>, includeDeactivated: true, authoredOverlay: overlay))`.
      Any thrown error → `invalid_definition` carrying the underlying
      description.
   5. Check that the standardized `resolved.workflowDirectory` equals the
      standardized `head.sourceDirectory`, and that
      `resolved.workflow.workflowId` equals the current runtime's
      `workflowId`. Otherwise → `invalid_definition` ("re-derived bundle
      does not match the registered source").
   6. Build the new document as `make(from: resolved, authoredOverlay: overlay)`.
      Add that optional overlay parameter to `make`; it makes the collector
      read referenced files from the overlay instead of disk. If the
      collected authored key set (normalized) is not exactly the overlay
      key set → `invalid_definition` ("unreferenced authored file <path>").
   7. Validate with `DefaultWorkflowValidator().validate(workflow)` and
      `validateAgentNodePayload` for each node. Any `.error` →
      `invalid_definition`.
   8. If the new digest equals the current digest, write nothing and return
      `unchanged`.
   9. Commit with `expectedCurrentVersionId = head.currentVersionId` and
      `diff = WorkflowDefinitionDiff.compute(currentDoc → newDoc)`. The
      write's `sourceDirectory`, `sourceScope` and `provenance` are copied
      from the current version. Never take them from `resolved`.
5. **`update(source:)`.** It builds `newAuthoredFiles` from the source,
   then calls the pipeline with operation `.update` and a nil target:
   - `.patch(p)`: `authoredFiles(fromView: WorkflowDefinitionJSONPatch.apply(p, to: currentDoc.authoredView()), previous: currentDoc.authoredFiles)`
   - `.authoredFiles(f)`: `f` as given (GraphQL form)
   - `.fromDirectory(opts)`: resolve `opts` with `fileResolver`. The
     resolved `workflowId` must equal the current runtime's `workflowId`.
     Then `make(from:)` (disk) and take its `authoredFiles`. The
     from-directory bundle's `runtime` is discarded; only its authored text
     is used, so stdio paths are re-anchored at `head.sourceDirectory` in
     pipeline step 4.
6. **`updatePrompt`.**
   - Reject an unknown node, an unknown variant key, and a node whose
     `nodeFile` is not a key in `authoredFiles` (materialized from `nodeRef`
     or `extends`). These throw `invalid_definition`.
   - Build a one-op patch over the authored view:
     - The authored node file names a `*File` for that field: `replace` at
       `pointer([<prompt path>])` with `text`.
     - The field is inline: `add` at `pointer([<nodeFile>] + fieldTokens)`.
       For a variant the tokens are `promptVariants`, `<key>`, `<kind>`.
   - Run the pipeline with operation `.updatePrompt`,
     `targetNodeId = nodeId` and `targetField = <field string>`.
   - Re-derivation gives every runtime field that shares that prompt file
     the new text automatically. Do not patch `runtime` by hand.
7. **`restore`.** The target version must exist and belong to the same
   workflow name. Commit `restore` with that version's document bytes
   (same blob digest), parent = current, and the reason required.
8. **`export`.** Write only the `authoredFiles` entries.
   - Validate each key with `resolvePromptTemplatePath(key, fieldName: "export", workflowDirectory: target)`
     before writing anything. Any failure aborts with zero writes.
   - `.directory(p)`: `p` must not exist, or must be an empty directory;
     otherwise throw. Create parent directories as needed.
   - `.source(overwrite:)`: `overwrite == false` throws a usage-style error.
     The target is `version.sourceDirectory`.
   - Write each file to `<path>.ds179-tmp-<uuid>` and `rename` it over the
     destination.
   - Never delete files. Export never commits rows.
9. **Store root.** The service never chooses a store root; callers pass it.

## Invariants

- `lookup`, `loadPinned`, `history`, `show` and the non-force `import` never
  write rows.
- After `export(target: .source(overwrite: true))`, a non-force import
  returns `unchanged`.
- `updatePrompt` followed by `export` to a temporary directory, followed by
  a file resolve of that directory, gives a bundle whose
  `make(from:).runtime.nodePayloads[node]` prompt equals `text`.
- The authored-edit pipeline never reads an own-directory file from disk.
  It may read `extends` bases and `nodeRef` targets from disk (QA Q7).
- Every rejected `update` or `updatePrompt` writes zero rows.
- `riela workflow run` and every other `authoredOverlay == nil` resolve
  behave exactly as before.

## Pitfalls

- Hydrated payloads carry both the `*File` path and the inline text. Do not
  drop the path from the runtime.
- The default `nodeFile` exists for every node even when no file exists
  (for example nodeRef nodes). Always check existence and containment.
- Absolute stdio paths in the runtime are expected. Do not relativize them.
  Export uses `authoredFiles`, which are already relative.
- Do not call `FileSystemWorkflowBundleResolver` directly. It lives in
  RielaCLI; use the injected `fileResolver`.
- `WorkflowScope` raw values: check the enum and store `rawValue`
  consistently.
- **Missing overlay key.** It must fail. Falling back to disk silently
  reintroduces file reads and breaks the "patch removed a prompt file"
  rejection.
- **Path comparison.** `containedFile` resolves symlinks (macOS `/var` vs
  `/private/var`). Compare `workflowDirectory` paths only after
  `resolvingSymlinksInPath().standardizedFileURL`, both in the overlay
  lookup and in pipeline step 5.
- **Re-serialization.** Do not re-serialize unchanged `.json` entries.
  That would create spurious diffs and break the "unchanged" digest check.
- `JSONValue` integer vs double: the authored view parses node files with
  the same decoder the rest of the service uses. Do not round-trip through
  `JSONSerialization` for comparison.
- **Inherited workflows.** For a derived (`extends`) workflow, the authored
  set is only `workflow.json` plus own node files, if any. Pipeline step 6
  must not demand base files.

## Tests

Add `Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift`. RielaCLITests
already depends on RielaWorkflowRegistry; RielaGraphQLTests does not.

- **Fixture.** A temporary workflow directory with:
  - `workflow.json` with 2 nodes
  - node A, whose `promptTemplateFile` is `prompts/a.md`
  - node B, with an inline `promptTemplate`

  Imitate the inline fixture writers in
  `Tests/RielaCLITests/WorkflowVersioningTestSupport.swift`.
- **Round-trip.** `make(from: fileBundle)` → canonical → decode equals the
  original, and `resolvedBundle` has `workflow` and `nodePayloads` equal to
  the file bundle's.
- **Import.**
  - First import → `seeded`, with 1 head, 1 version and 1 audit row.
  - Edit `prompts/a.md`, then non-force import → `differs`, with a diff entry
    whose path starts with `/authoredFiles/prompts~1a.md` and another at
    `/runtime/nodePayloads/A/promptTemplate`. Row counts are unchanged.
  - An unchanged file → `unchanged`.
- **Force.**
  - `updatePrompt(A, "promptTemplate", "X", reason: "r1")`, then edit the
    file, then force-import with reason `r2` → `forceUpdated`.
  - The audit's `overwrittenChanges.auditIds` contains the updatePrompt
    audit id.
  - `restore(versionId: <updatePrompt version>)` brings A's runtime prompt
    back to `X`.
- **Reason and target validation.**
  - force without a reason → `missingReason` and zero new rows
  - `updatePrompt` with a blank reason → `missingReason`
  - an unknown node or field throws
  - a nodeRef node is rejected
- **Inline field.** `updatePrompt(B, "promptTemplate", "Y")` → the node file
  JSON in `authoredFiles` has `promptTemplate == "Y"`, and export plus file
  re-resolve gives `Y`.
- **Shared prompt path.** Two nodes that reference the same
  `prompts/shared.md` → after `updatePrompt` on one, both runtime fields
  change and the diff lists both.
- **Export.**
  - to a new directory → files byte-identical to `authoredFiles`
  - to a non-empty directory → throws
  - `.source(overwrite: false)` → throws
  - `.source(overwrite: true)` then non-force import → `unchanged`
- **History.** `history(nodeId: "A")` returns only A's records, newest first.

**Whole-workflow update (A).** Same file. Extend the fixture with a third
node C whose `command.executable` is the relative `scripts/run.sh`, plus a
transition `A → B`.

- **Structure and prompt in one patch.** A patch that does `replace
  /prompts~1a.md` and changes the A→B transition's `toStepId` gives:
  - outcome `updated`, operation `update`
  - an audit whose reason, evidence `[session:s1, stepExecution:e1]`,
    actor and diff include both pointers
  - `last_file_version_id` unchanged
  - `lookup` returning a bundle with the new prompt text and transition
  - the files on disk byte-unchanged (sha256 before and after)
- **Overlay isolation.** After seeding, write `"DISK"` to `prompts/a.md` on
  disk, then patch only node B's inline prompt. A's runtime prompt is
  still the stored text, not `"DISK"`.
- **From-directory.** Export to `tmp/<uuid>/w`, edit its prompt, then
  `update(.fromDirectory(direct options for that dir))`. C's runtime
  `command.executable` is `<head.sourceDirectory>/scripts/run.sh`, not
  under `tmp/<uuid>`.
- **Expected version.** `expectedVersionId` = an older version id →
  `definition_conflict`, zero new rows.
- **Rejections, each with zero new rows:**
  - blank reason → `reason_required`
  - failing `test` op → `invalid_patch`
  - pointer to a missing member for `replace` → `invalid_patch`
  - `remove /prompts~1a.md` → `invalid_definition` (the missing overlay
    key fails the resolve; no disk fallback)
  - `add /prompts~1orphan.md` → `invalid_definition` (unreferenced
    authored file)
  - a patch making `workflow.json` invalid → `invalid_definition`
  - `update` on an unregistered workflow → `definition_not_registered`
- **No-op.** A patch whose result equals the current document → outcome
  `unchanged`, no rows.
- **Force after update.** After an `update`, a force import's
  `overwrittenChanges.auditIds` contains the `update` audit id.
- **Authored view.** `authoredView` returns `workflow.json` as an object
  and `prompts/a.md` as a string.
- **JSON Patch unit cases.** add to an array index and to `-`, add/replace
  an object member, remove, `test` pass and fail, `~1` and `~0` escapes, an
  unknown op `move` → `invalid_patch`.

## Verification (each command must exit 0)

- `arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/ds179/02-build.log'`
- `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowDefinitionServiceTests 2>&1 | tee tmp/ds179/02-test.log'`.
  Record testsRun and failureCount.
- `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowDefinitionStoreTests 2>&1 | tee tmp/ds179/02-store-regression.log'`
- `arch -arm64 /bin/zsh -lc 'swift test --filter "PromptTemplateTests|WorkflowInheritanceResolutionTests|WorkflowSharedNodeVersioningTests" 2>&1 | tee tmp/ds179/02-loader-regression.log'`.
  This proves the nil-overlay path is unchanged. Record testsRun and
  failureCount. A failure that also reproduces on the pre-change tree is a
  residual risk, not a blocker; record the test name.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/WorkflowAuthoredFileOverlay.swift Sources/RielaCore/PromptTemplateAssets.swift Sources/RielaCLI/WorkflowResolution.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionDocument.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift Sources/RielaWorkflowRegistry/WorkflowDefinitionJSONPatch.swift Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift'`
  must print no violations.

## Done criteria

- `grep -n "public var definitionSource" Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift`
  matches.
- `grep -n "authoredOverlay" Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader.swift Sources/RielaCLI/WorkflowResolution.swift Sources/RielaCore/PromptTemplateAssets.swift`
  matches in all three files.
- Every pinned method above exists, checked with `grep -n "func importDefinition\|func updatePrompt\|func update(\|func authoredView\|func restore\|func export\|func seedIfAbsent\|func lookup\|func loadPinned"`.
- All verification commands exit 0, and the progress log records each
  command with exitStatus, testsRun, failureCount and the log path.

## Progress log expectations

Log each file edit in `impl-plans/progress/ds179-02-definition-service.md`
with the pre-edit and post-edit sha256. `WorkflowRegistryBundleLoader.swift`,
`PromptTemplateAssets.swift` and `WorkflowResolution.swift` are shared with
nothing else in this chain, but re-read each fresh before editing. Record
any blocker, such as Codable loss, verbatim.


## Operator amendment 1 (after session-494 blocked wave)

- ds179-01-store-core is accepted and committed in 6337aa24. The definition store API now returns
  `WorkflowDefinitionCurrent` (struct with head/version/document) from `current(workflowName:)`, and
  `WorkflowDefinitionDiffEntry.Op` was renamed to `WorkflowDefinitionDiffEntry.Operation`.
- Known pre-existing failures on main f4fcf68c (not caused by this work; exclude them from gates with
  `--skip` and never treat them as blockers): `DeterministicWorkflowRunnerFailureStateTests.testRetryFailedStepErrorNamesTimeoutForCompletedSession`,
  `HandoverContractsTests.testSessionSuspendAndClosedStatusRoundTrip`, `SessionObservabilityTests.testTransitionalCancelledFailureKindIsTerminal`.
  `DeterministicWorkflowRunnerFanoutTests.testProductionCollectPartialPersistsCancelledChildBeforePublishingJoin` is timing-flaky under
  full-suite load and passes in isolation.
