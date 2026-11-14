# sdwd-04: `riela doctor` definition-source drift report

**planId**: sdwd-04-doctor-drift-report
**dependsOn**: sdwd-02-source-drift-service (`WorkflowDefinitionService.workflowNames()`, `inspectSourceDrift`, `WorkflowDefinitionSourceDriftReport`, `WorkflowDefinitionSourceDrift.diagnostic`)
**Design Reference**: design-docs/specs/design-workflow-definition-store.md §8 "riela doctor drift report", §4.1 Classification and Diagnostics, §12 amendment (DoctorCommandTests)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/sdwd-04-doctor-drift-report.md
**Evidence root**: tmp/stale-definition/sdwd-04-doctor-drift-report/

## Intent and context

Operators need to see stale-source drift without waiting for a service run.
`riela doctor` (`Sources/RielaCLI/DoctorCommand.swift`) gains a
**read-only** per-head report.

## Non-goals

- Doctor never seeds, imports or auto-syncs, and never creates a store
  database.
- No changes to other doctor sections, to `StorageDoctorCommand`, or to the
  sdwd-02 and sdwd-03 files.

## File-level changes (Sources/RielaCLI/DoctorCommand.swift only)

**New type.**

```swift
public struct DoctorDefinitionSourceReport: Codable, Equatable, Sendable {
  public var storeRoot: String
  public var workflowName: String?
  public var currentVersionId: String?
  public var lastFileVersionId: String?
  public var sourceDirectory: String?
  public var result: String           // "inSync" | "pendingAutoSync" | "drift" | "sourceInvalid" | "sourceUnavailable" | "storeUnreadable"
  public var status: DoctorCheckStatus
  public var message: String?
}
```

**Additions to existing types.**

- `DoctorCommandResult` gains `public var definitionSources: [DoctorDefinitionSourceReport]`.
- `DoctorSummary` gains `public var definitionSourceWarnings: Int`.

Both are constructed only in this file (verified with
`grep "DoctorCommandResult(\|DoctorSummary("`).

**In `diagnose`:**

- Candidate roots are
  `WorkflowDefinitionStoreSelection.candidateRoots(sessionStore: parsed.sessionStore, scope: parsed.scope, workingDirectory: workingDirectory.path)`.
  The sessionStore option exists on `ParsedParityOptions`
  (`Sources/RielaCLI/ParityCommandSupport.swift:34`). Deduplicate the roots.
- Skip a root unless
  `FileManager.default.fileExists(atPath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root))`.
  Imitate `DefinitionStoreWorkflowBundleResolver.lookup`.
- For each root, construct
  `WorkflowDefinitionService(storeRoot: root, fileResolver: FileSystemWorkflowBundleResolver())`.
  For each name in `workflowNames()`, call
  `inspectSourceDrift(workflowName:workingDirectory: workingDirectory.path)`.
- Map the result to a result string and status:

  | Report result | `result` string | Status |
  | --- | --- | --- |
  | `inSync` | `inSync` | `.ok` |
  | `autoSync` | `pendingAutoSync` | `.warning` |
  | `drift` | `drift` | `.warning` |
  | `sourceInvalid` | `sourceInvalid` | `.warning` |
  | `sourceUnavailable` | `sourceUnavailable` | `.warning` |

- `message` uses `WorkflowDefinitionSourceDrift.diagnostic(for:path:…).message`
  for non-ok rows, with paths `definitionStore.sourceDrift`, `.sourceInvalid`
  and `.sourceUnavailable`. For `pendingAutoSync`, the message says the
  next service run will import the file.
- Any thrown error for a root (open, listing, or a per-workflow inspect)
  produces one report for that root (or that workflow) with
  `result: "storeUnreadable"`, `status: .unknown` and `message: "\(error)"`.
  Doctor must not fail.
- `definitionSourceWarnings` is the count of `.warning` rows. The summary
  status becomes `.warning` if it is greater than 0, in addition to the
  existing conditions.

**In `renderText`:** after the existing sections, print a
`Definition sources:` block with one line per non-`ok` row:
`<status> <workflowName> (<storeRoot>): <result> — <message>`. Print
nothing extra when all rows are ok. JSON output comes from Codable
automatically.

## Pitfalls

- Doctor must not call `syncFromSourceIfUntouched`, `seedIfAbsent` or
  `importDefinition`.
- Do not construct a service for a missing database path. That would
  create the store.
- Never read or write `~/.riela` in tests. Always pass `--session-store`
  and `--working-dir` to temp directories, and set `--scope project`.

## Tests: Tests/RielaCLITests/DoctorDefinitionSourceTests.swift (new)

- Imitate the command invocation in `Tests/RielaCLITests/DoctorCommandTests.swift`,
  which uses an injected runner and host resolver if needed.
- Put the fixtures under
  `tmp/stale-definition/sdwd-04-doctor-drift-report/fixture-<uuid>`.
- Seed four workflows in one temp store with `seedIfAbsent`:
  - `in-sync`: untouched
  - `pending`: untouched, file edited
  - `edited`: `updatePrompt` and then the file edited
  - `broken`: `workflow.json` set to `{`

Cases:

- **JSON output** → `definitionSources` has 4 rows with results `inSync`,
  `pendingAutoSync`, `drift` and `sourceInvalid`, and statuses
  ok/warning/warning/warning. `summary.definitionSourceWarnings == 3` and
  `summary.status == .warning`. The `drift` message contains
  `riela instance reload` and `import` … `--force`.
- **Read-only** → the `definition_*` row counts are identical before and
  after doctor. Imitate `definitionRowCounts` in
  `WorkflowDefinitionServiceResolutionTests`, or use `history(...).count`
  per workflow.
- **`--session-store` pointing at a nonexistent directory** → zero rows,
  and the database file is still absent afterwards.
- **Text output** contains `Definition sources:` and the `drift` line.

## Acceptance criteria

- [x] The new type and fields exist. Existing doctor tests pass unchanged.
- [x] All new cases are present and pass.

## Verification (arm64; logs plus `.exit` under the evidence root)

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/stale-definition/sdwd-04-doctor-drift-report/build.log 2>&1; echo $? > tmp/stale-definition/sdwd-04-doctor-drift-report/build.exit'`
   → 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "DoctorDefinitionSourceTests|DoctorCommandTests|DoctorBackendCapabilityTests" > tmp/stale-definition/sdwd-04-doctor-drift-report/test.log 2>&1; echo $? > tmp/stale-definition/sdwd-04-doctor-drift-report/test.exit'`
   → 0, 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --strict --quiet Sources/RielaCLI/DoctorCommand.swift Tests/RielaCLITests/DoctorDefinitionSourceTests.swift > tmp/stale-definition/sdwd-04-doctor-drift-report/lint.log 2>&1; echo $? > tmp/stale-definition/sdwd-04-doctor-drift-report/lint.exit'`
   → 0.

## Concurrency and drift protocol

Re-read each file before editing it and record pre/post sha256. Edit only
the files in writePaths. Log sibling build breaks and re-run.

## Progress log expectations

`impl-plans/progress/sdwd-04-doctor-drift-report.md` holds the commands,
exit codes, log paths, hashes and the checked acceptance list.

## Amendment 2026-11-11 (IR-SDWD04-DOCTOR-RULING)

IR-SDWD04-DOCTOR-RULING: sdwd-04 was blocked twice with no DoctorCommand.swift change, so `riela doctor` has no definitionSources drift report. The worker's rebuttal of round 1 is correct: SQLiteDatabase.open(mode: .readOnly) falls back to SQLITE_OPEN_READWRITE (SQLiteDatabase.swift:174-181), and the later service open runs schema preparation. As design author, integration review now rules on design §8 'read-only'. It means no seed, import or auto-sync, no definition_* row writes, and never creating, migrating or discarding a store. A writable service open is permitted only after a .strictReadOnly precheck proves three things: the store is at SQLiteWorkflowRuntimePersistenceStore.schemaGeneration, has definition_heads, and is already in WAL journal mode. On such a store the open's schema preparation is idempotent, so it neither migrates nor discards. This is the same open path the existing read-only `riela workflow definition history|show|diff` commands already use. The TOCTOU replacement window is an accepted residual. No RielaCore or Registry change is authorized or needed.
