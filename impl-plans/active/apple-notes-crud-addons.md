# Apple Notes CRUD Add-ons Implementation Plan

**Status**: Implemented after Step 7 review rerun
**Workflow Mode**: issue-resolution
**Issue Reference**: not applicable; workflow input did not include a GitHub issue
**Design Reference**: design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md#built-in-rielaapple-note-
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Sources**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
- `design-docs/user-qa/qa-apple-notes-crud-gateway-confirmations.md`

Step 3 accepted the design in communication `comm-000650` with decision
`accepted_for_implementation_planning`. This plan treats the accepted design-doc
update as the source of truth. There are no Codex-agent references and no Cursor
CLI behavior mapping obligations for this work.

### Summary

Extend the existing `riela/apple-notes-list` Apple Gateway integration with five
fixed-operation built-in add-ons:

- `riela/apple-note-get`
- `riela/apple-note-create`
- `riela/apple-note-update-body`
- `riela/apple-note-delete`
- `riela/apple-note-move`

The implementation must reuse the existing apple-gateway subprocess bridge,
send user-controlled values only through GraphQL variables, materialize large
note bodies through `apple-gateway file download`, and keep examples safe by
shipping only read and create bundles.

### Scope

**Included**:
- Extract shared Apple Gateway subprocess support from
  `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`.
- Refactor `riela/apple-notes-list` onto the shared support without behavior
  changes.
- Implement the five CRUD add-on executors in a new responsibility-focused
  Swift file.
- Register all five add-ons in catalog and dispatch surfaces.
- Add fake-executable unit tests covering success, validation, provider error,
  invalid output, timeout, and variables-only data transport.
- Add `examples/apple-note-read/` and `examples/apple-note-create/`.
- Keep catalog docs aligned if implementation discovers a confirmed upstream
  detail that narrows the accepted design.

**Excluded**:
- Vendoring or copying `apple-gateway` sources into this repository.
- Requiring live Apple Notes access or macOS automation permissions in tests.
- Shipping runnable delete, move, or update example bundles.
- Modifying the pre-existing dirty files
  `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift`.

---

## Task Breakdown

### TASK-001: Confirm Upstream CLI Details

**Status**: COMPLETED_WITH_ASSUMPTIONS
**Write Scope**: none, except this plan's progress log
**Parallelizable**: yes, with TASK-006 README drafting only

**Tasks**:
- [x] Confirm `apple-gateway graphql --query <doc> --variables <json>`.
- [x] Confirm `apple-gateway file download --key <key> --output-dir <dir>`.
- [x] Capture the successful file-download stdout shape if available.
- [x] Capture or preserve assumptions for `NOTE_LOCKED` and permission-denied
  GraphQL error shapes.
- [x] Record commands and conclusions in this plan's progress log.

**Deliverable**: A progress-log entry records the tolerant parsing and
error-preservation fallback from the accepted QA doc because `apple-gateway` was
not available on `PATH` in this implementation session.

### TASK-002: Extract Shared Apple Gateway Support

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`

**Tasks**:
- [x] Move the process runner, pipe draining, timeout helpers, output model,
  GraphQL envelope model, binary provenance model, and common JSON helpers into
  an internal support file.
- [x] Extract binary resolution to an internal resolver using config
  `binaryPath`, then `APPLE_GATEWAY_BIN`, then `PATH`.
- [x] Keep `binaryPath` literal-only, never rendered or sourced from inputs,
  payloads, variables, or workflow input.
- [x] Add shared mutation-field extraction.
- [x] Add `AppleGatewayFileDownloader` with private-runtime-dir validation for
  `RIELA_APPLE_NOTES_DOWNLOAD_ROOT` and literal `downloadDir`.
- [x] Refactor `riela/apple-notes-list` to use the shared support with
  unchanged output and error behavior.
- [x] Keep each Swift file under 1000 lines.

**Deliverable**: Shared Apple Gateway support that list and CRUD executors can
reuse without duplicated subprocess invocation logic.

### TASK-003: Implement CRUD Executors

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift`

**Tasks**:
- [x] Implement `riela/apple-note-get` with required `noteId`, include flags,
  optional `materializeBody`, and body-file local path output.
- [x] Implement `riela/apple-note-create` with required non-empty `title` and
  at least one of `bodyHtml` or `bodyText`.
- [x] Implement `riela/apple-note-update-body` with required `noteId`, required
  body content, and mode `REPLACE` or `APPEND`.
- [x] Implement `riela/apple-note-delete` with required `noteId`.
- [x] Implement `riela/apple-note-move` with required `noteId` and `folderId`.
- [x] Reject unsupported versions and any authored `addon.env`.
- [x] Send all note ids, folder ids, titles, and bodies via `--variables` JSON;
  never interpolate user-controlled values into GraphQL documents.
- [x] Preserve GraphQL error messages and extensions in provider-error details.
- [x] Publish payloads with `status`, `addon`, `stepId`,
  `appleGateway.binary`, `appleGateway.requestId`, `appleGateway.rawData`, and
  operation-specific `when` flags.

**Deliverable**: Five native CRUD executors matching the accepted output,
validation, and error-mapping contract.

### TASK-004: Register Catalog And Dispatch

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`

**Tasks**:
- [x] Add all five add-on descriptors to
  `RielaBuiltinAddonCatalog.appleGatewayAddons` at version `1`.
- [x] Add resolver dispatch branches beside `riela/apple-notes-list`.
- [x] Extend catalog tests for known names and unsupported-version rejection.
- [x] Confirm node add-on validation accepts all five ids.

**Deliverable**: The new add-ons are discoverable, validatable, and routed to
their executors.

### TASK-005: Add Fake Executable Test Coverage

**Status**: COMPLETED
**Write Scope**:
- `Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`
- Test helper edits only if required by existing test patterns

**Tasks**:
- [x] Build fake `apple-gateway` scripts in per-test temporary directories.
- [x] Cover get success and get materialization.
- [x] Cover materialization without a valid private root as policy blocked.
- [x] Cover create success and missing-title policy blocking.
- [x] Cover update replace and append.
- [x] Cover delete and move success.
- [x] Cover `NOTE_LOCKED` and permission-denied GraphQL errors as provider
  errors with useful upstream diagnostics preserved.
- [x] Cover non-zero exit, malformed JSON, missing mutation field, missing or
  non-executable binary, timeout, rejected `addon.env`, and unsupported version.
- [x] Cover variables-not-injected using user text containing quotes, braces,
  and newlines, proving it appears in `--variables` and not `--query`.

**Deliverable**: Deterministic tests with no live Apple app access.

### TASK-006: Add Safe Example Bundles

**Status**: COMPLETED
**Write Scope**:
- `examples/apple-note-read/workflow.json`
- `examples/apple-note-read/nodes/node-workflow-output.json`
- `examples/apple-note-read/README.md`
- `examples/apple-note-create/workflow.json`
- `examples/apple-note-create/nodes/node-workflow-output.json`
- `examples/apple-note-create/README.md`

**Tasks**:
- [x] Add a read workflow using `riela/apple-note-get` with
  `materializeBody: false` by default.
- [x] Document opt-in materialization and private download roots.
- [x] Add a create workflow using title/body workflow input.
- [x] Document delete, move, and update only as deliberate mutation snippets,
  not runnable default bundles.
- [x] Keep workflow validation offline; examples must not require a live
  `apple-gateway` call during validate.

**Deliverable**: Two valid example bundles that demonstrate body fetch and note
creation without destructive defaults.

### TASK-007: Refresh Docs Only For Confirmed Implementation Details

**Status**: COMPLETED
**Write Scope**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
- `design-docs/user-qa/qa-apple-notes-crud-gateway-confirmations.md`

**Tasks**:
- [x] Update docs only when implementation confirms an upstream detail or
  reveals a necessary accepted-design clarification.
- [x] Keep open upstream unknowns in the QA file when not confirmed.
- [x] Do not redesign the add-on shape during implementation.

**Deliverable**: Catalog docs remain synchronized with the implemented
contract.

### TASK-008: Verification And Safety Audit

**Status**: COMPLETED
**Write Scope**: none, except this plan's progress log

**Tasks**:
- [x] Run `swift test --filter AppleNotesCrud`.
- [x] Run `swift test --filter AppleGateway`.
- [x] Run `swift test --filter AddonExecutionContractsTests`.
- [x] Run `swift build`.
- [x] Run `swift run riela workflow validate apple-note-read --workflow-definition-dir examples`.
- [x] Run `swift run riela workflow validate apple-note-create --workflow-definition-dir examples`.
- [x] Run `git status --short`.
- [x] Run `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`.
- [x] Confirm pre-existing dirty RielaApp timeline files are untouched.

**Deliverable**: Progress-log entry with verification commands and results.

---

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-001 | Step 3 accepted design | Confirms upstream details before locking fixtures |
| TASK-002 | Step 3 accepted design | Shared support must precede new executors |
| TASK-003 | TASK-002 | CRUD executors must reuse the shared bridge |
| TASK-004 | TASK-003 | Dispatch should target implemented executor entry points |
| TASK-005 | TASK-003, TASK-004 | Tests need executors and catalog/dispatch surfaces |
| TASK-006 | TASK-004 | Example validation depends on catalog recognition |
| TASK-007 | TASK-001 through TASK-006 | Docs refresh follows confirmed implementation details |
| TASK-008 | TASK-001 through TASK-007 | Verification runs after implementation and docs are complete |

## Parallelizable Tasks

| Task | Can Run In Parallel With | Reason |
| ---- | ------------------------ | ------ |
| TASK-001 | TASK-006 README drafting | Read-only inspection and example docs have disjoint write scopes |
| TASK-004 catalog descriptor edits | TASK-006 initial workflow files | Source registration and example paths are disjoint |
| TASK-005 test fixture scaffolding | TASK-006 README/workflow drafting | Test target and example bundle paths are disjoint |

Do not parallelize TASK-002 and TASK-003 because both touch Apple Gateway
support contracts. Do not parallelize TASK-007 with any task that is actively
editing the same design-doc files.

## Verification

Required commands:

```bash
swift test --filter AppleNotesCrud
swift test --filter AppleGateway
swift test --filter AddonExecutionContractsTests
swift build
swift run riela workflow validate apple-note-read --workflow-definition-dir examples
swift run riela workflow validate apple-note-create --workflow-definition-dir examples
git status --short
rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans
```

Expected verification notes:
- Narrow Swift tests pass with fake executables only.
- `swift build` succeeds.
- Both new example bundles validate without invoking live Apple Notes.
- Hardcoded user-local apple-gateway paths are absent from committed Swift
  source; README examples may mention local operator paths only when clearly
  documented as examples.
- Pre-existing dirty timeline files remain untouched.

## Completion Criteria

- [x] All five add-ons are registered and validate as built-in version `1`
  add-ons.
- [x] `riela/apple-notes-list` still passes its Apple Gateway regression tests
  after support extraction.
- [x] CRUD executors use fixed GraphQL documents and variables-only transport.
- [x] `riela/apple-note-get` materializes body files through download keys into
  a private runtime directory and returns local paths.
- [x] `riela/apple-note-get` fails closed with `.providerError` when
  `materializeBody` requests a download key but `apple-gateway file download`
  returns no local-path mapping for that key.
- [x] Fake-executable tests cover the accepted success and failure matrix.
- [x] Safe read/create examples validate.
- [x] Catalog docs and QA notes match the final implemented behavior.
- [x] Verification commands and results are recorded in this plan's progress
  log.

## Progress Log

### Session: 2026-07-07

**Tasks Completed**: Implementation plan created after Step 3 acceptance.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: Later implementation sessions must append command/results entries
for upstream confirmation, narrow tests, build, example validation, dirty-file
audit, and hardcoded-path audit.

### Session: 2026-07-07 Step 6 Implementation

**Tasks Completed**: TASK-001 through TASK-008.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**:
- `command -v apple-gateway || true` returned no executable path, so upstream
  file-download envelope and locked-note shapes remain governed by
  `design-docs/user-qa/qa-apple-notes-crud-gateway-confirmations.md`.
- Implemented tolerant file-download parsing for `files`/`downloads` arrays and
  `localPath`/`path`, while requiring an explicit requested `downloadKey`/`key`
  mapping before accepting a materialized body path.
- GraphQL provider errors preserve `errors[].message` plus serialized
  `errors[].extensions` values, including `NOTE_LOCKED`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleNotesCrud`
  (10 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
  (11 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
  (5 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-read --workflow-definition-dir examples`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-create --workflow-definition-dir examples`.
- PASS targeted SwiftLint:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`.
- NOTE full SwiftLint was run with the same Xcode-toolchain environment. New
  file warnings were fixed; remaining warnings are pre-existing in
  `Sources/RielaCLI/RielaArgumentParserHelpers.swift` and
  `Sources/RielaCLI/WorkflowPackageParityCommands.swift`.
- PASS `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`;
  hits are limited to README and implementation-plan documentation, not Swift
  source or tests.
- PASS `git status --short`; pre-existing dirty
  `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift` remain
  untouched by this implementation.

### Session: 2026-07-07 Step 6 Review Rerun

**Tasks Completed**: Addressed Step 7 feedback from communication `comm-000655`.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**:
- Fixed `AppleGatewayFileDownloader` to require an explicit requested
  `downloadKey`/`key` to `localPath`/`path` mapping in the successful file
  download envelope. A well-formed envelope that omits the requested key now
  fails with `.providerError` instead of allowing `apple-note-get` to succeed
  without `bodyFile.localPath`.
- Added fake-executable regression
  `testAppleNoteGetMaterializeFailsWhenDownloadKeyMappingIsMissing`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleNotesCrud`
  (11 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
  (11 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
  (5 tests).
- PASS targeted SwiftLint:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-read --workflow-definition-dir examples`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-create --workflow-definition-dir examples`.
- PASS `git diff --check`.
- PASS `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`;
  hits remain limited to README and implementation-plan documentation.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`;
  touched Swift files are under 1000 lines.
- PASS `git status --short`; pre-existing dirty
  `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift` remain
  outside this fix.

## Related Plans

- **Depends On**: `impl-plans/active/apple-notes-list-addon.md`
- **Design Step**: Step 3 communication `comm-000650`
