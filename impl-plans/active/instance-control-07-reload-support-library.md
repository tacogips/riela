# Instance control 07: RielaCLI reload support (validation, head-aware import, installed fingerprint)

**Status**: Planned
**planId**: instance-control-07-reload-support-library
**dependsOn**: instance-control-01-contracts (`RielaAppInstanceReloadFingerprint`, `RielaAppInstanceStartRecord`, `RielaAppInstanceReloadError`/`Code`, `RielaAppInstanceReloadResponse.Definition`)
**Design Reference**: design-docs/specs/design-instance-reload-run-cli.md D4 steps 3, 4, 5 (fingerprint source), 7.1 (head-aware import, DR-002); §5
**Created**: 2026-11-10
**Evidence root**: tmp/instance-control/instance-control-07-reload-support-library/

## Intent and context

The RielaApp target cannot be unit-tested against real SQLite definition stores easily. `RielaWorkflowRegistry` and `RielaCLI` are available to `RielaCLITests`. So the reusable library pieces that the App's reload route needs (plan 09) live in RielaCLI. RielaApp already depends on RielaCLI.

There are three functions:

1. Validate a candidate directory as the instance's workflow:
   - full file-resolver validation;
   - node patches;
   - same `workflowId`;
   - event-root validation reusing the `riela events validate` logic.
2. Import into the definition store, respecting whether a head exists (DR-002). The existing contract is `WorkflowDefinitionService.importDefinition` (`Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift:170-241`):
   - `force:true` with no head throws `headMissing`;
   - `force:false` with no head seeds, or returns `unchanged`/`differs` when a concurrent seeder won;
   - `force:true` with a head is guarded by `expectedCurrentVersionId` and throws `staleHead` on a race.
3. Compute the trigger-defaults fingerprint the child will install. This mirrors `CLIWorkflowTriggerDefaultsResolver` (`Sources/RielaCLI/EventLiveServe.swift:969-987`): a lookup-only store head when present, otherwise the file bundle.

## Non-goals

- Do not change `WorkflowDefinitionService` or `DefinitionStoreWorkflowBundleResolver` contracts.
- No HTTP and no App code. No CLI subcommand.

## File-level changes

### Sources/RielaCLI/InstanceReloadSupport.swift (new)

`public enum InstanceReloadSupport` with the following static functions.

**1. Validate the candidate.**

```swift
public static func validateCandidate(
  workflowDirectory: String, eventRoot: String?, expectedWorkflowId: String,
  nodePatches: [String: WorkflowInstanceNodePatch], workingDirectory: String
) throws -> (bundle: ResolvedWorkflowBundle, triggerDefaultsFingerprint: String, eventRootDigest: String)
```

- Resolve with `FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(workflowName: expectedWorkflowId, workflowDefinitionDir: workflowDirectory, workingDirectory:))`. A failure → `RielaAppInstanceReloadError(code: .invalidWorkflowDefinition, message: safe summary)`.
  - Use `WorkflowWebProjectionPolicy().safeSummary` for messages. Never include file contents or environment values.
- `bundle.workflow.workflowId != expectedWorkflowId` → `.workflowIdMismatch`.
  - Pitfall: the resolver may fail before the id check when the name differs. Classify a not-found-by-name failure as `workflowIdMismatch` only if the directory's own `workflow.json` decodes and has a different id. Otherwise it is `invalidWorkflowDefinition`.
- Apply node patches through `WorkflowInstanceResolver.resolve(workflowId:base:nodePayloads:)`, imitating `InstanceCommandRunner.materializedInstance`. A failure → `.invalidWorkflowDefinition`.
- Event root:
  - If `eventRoot` is non-nil, run the same parse and validation as `riela events validate`. Locate it from `ScopedParityCommands.swift` (case `"validate"` in the events scope).
  - If that logic is private, extract the minimal internal function it calls into this file or a `fileprivate` helper. **Do not change the `events validate` command output.** If the extraction requires editing `ScopedParityCommands.swift`, limit it to making one existing function `internal`.
  - A failure → `.invalidEventBindings`.
- Fingerprints: `RielaAppInstanceReloadFingerprint.triggerDefaultsFingerprint(bundle.workflow.triggerDefaults)` and `RielaAppInstanceReloadFingerprint.eventRootDigest(eventRoot:)`.

**2. Import the definition, respecting the head.**

```swift
public static func importDefinition(
  storeRoot: String, workflowDirectory: String, workflowId: String, reason: String,
  workingDirectory: String
) throws -> RielaAppInstanceReloadResponse.Definition
```

- Build `WorkflowDefinitionService(storeRoot: storeRoot, fileResolver: FileSystemWorkflowBundleResolver())`. Imitate `WorkflowDefinitionCommand.swift:127`. The actor is `.init(kind: .api, id: "instance-reload")`; evidence is `[]`.
- Algorithm:
  1. Read whether a head exists. Use the service or store's current lookup; if no public API exists, call `importDefinition(force:false)` first. The two outcomes are equivalent, because a non-force import with a head never writes.
  2. **No head:** `force:false` with the `reason`.
     - Outcome `seeded` → return it.
     - `unchanged` (a concurrent seeder with the same digest) → return `unchanged`.
     - `differs` → exactly one retry with `force:true`.
  3. **Head present:** `force:true` with the `reason` → `forceUpdated` or `unchanged`. Check how the service reports equal digests; map it to `unchanged`.
- Error mapping:

  | Service error | Reload code |
  | --- | --- |
  | `staleHead` | `.definitionConflict` (no write of ours happened) |
  | validation errors | `.invalidWorkflowDefinition` |
  | `headMissing` on the retry path (head vanished) | `.definitionConflict` |
  | I/O and other errors | `.definitionStoreFailure` |

- Return `Definition { outcome, versionId, digest }` from the result's version.

**3. Fingerprint the child will install.**

```swift
public static func installedTriggerDefaultsFingerprint(
  storeRoot: String, workflowDirectory: String, workflowId: String, workingDirectory: String
) -> String?
```

- Use `DefinitionStoreWorkflowBundleResolver(inner: FileSystemWorkflowBundleResolver(), sessionStore: storeRoot, actor: .init(kind: .cli, id: "events-serve"), mode: .lookupOnly).resolve(...)`, the same as `CLIWorkflowTriggerDefaultsResolver`.
- Fingerprint `.workflow.triggerDefaults`. Any error → nil; plan 06 treats nil as an unknown baseline.
- Plus `public static func startRecord(candidateDirectory:eventRoot:storeRoot:workflowId:workingDirectory:) -> RielaAppInstanceStartRecord?`, which combines the event-root digest and this fingerprint. Plan 09 uses it as the runtime's `StartRecordProvider`.

## Tests

**Tests/RielaCLITests/InstanceReloadSupportTests.swift (new)** — temp dirs under `<cwd>/tmp/`. Imitate the fixture helpers in `Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift`.

| Situation | Expected |
| --- | --- |
| Valid workflow dir, matching id | the bundle plus both fingerprints are returned |
| Malformed `workflow.json` | `invalid_workflow_definition` |
| A dir whose workflow id differs | `workflow_id_mismatch` |
| Invalid `.riela-events` (binding to an unknown source) | `invalid_event_bindings` |
| Unknown node id in the patch | `invalid_workflow_definition` |
| **Fresh store** (no head) | outcome `seeded`; a head now exists; the audit operation is `import`; no workflow run was needed |
| **Existing head**, then files changed | `forceUpdated`; the audit row has operation `forceUpdate` and the given reason |
| Existing head, identical files | `unchanged`; no new version |
| **Concurrent seed with a different digest** | head seeded by another doc before our call → no-head check races → forced retry → `forceUpdated` (or `definition_conflict` when the head moves again) |
| Retry hits `staleHead` (inject by moving the head between calls with a test hook, or call the force path with a stale expected version) | `definition_conflict`; the store head equals the competing version, so no write of ours |
| Invalid definition | nothing is written to the store (version count unchanged) |
| `installedTriggerDefaultsFingerprint` with a head holding triggerDefaults A and files holding B | the A fingerprint (store wins) |
| Same, with no head | the B fingerprint |
| Same, store unreadable | nil |

## Invariants

- The service contracts are unchanged, and `riela events validate` output is unchanged.
- No write happens on any validation failure.

## Verification

1. `mkdir -p tmp/instance-control/instance-control-07-reload-support-library && arch -arm64 /bin/zsh -lc 'swift test --filter "InstanceReloadSupportTests|WorkflowDefinitionServiceTests" 2>&1 | tee tmp/instance-control/instance-control-07-reload-support-library/test.log; exit ${pipestatus[1]}'` — 0 failures.
2. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCLI/InstanceReloadSupport.swift Tests/RielaCLITests/InstanceReloadSupportTests.swift 2>&1 | tee tmp/instance-control/instance-control-07-reload-support-library/lint.log; exit ${pipestatus[1]}'`
3. If `ScopedParityCommands.swift` was touched: `arch -arm64 /bin/zsh -lc 'swift test --filter "ScopedParity|EventValidate" 2>&1 | tee tmp/instance-control/instance-control-07-reload-support-library/events-validate.log; exit ${pipestatus[1]}'` — confirm that tests ran (non-zero count) and 0 failed.

## Edit safety

- Fresh-read before each edit; record the pre- and post-edit sha256.
- `ScopedParityCommands.swift` is a sharedPath limited to a visibility change of one function.

## Completion criteria

- [ ] All three functions are implemented with these exact names.
- [ ] All tests pass.
- [ ] Lint exits 0.
- [ ] Progress log written.

## Progress Log

### Session: 2026-11-10
Plan authored (Opus). Not started.
