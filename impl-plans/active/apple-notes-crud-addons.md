# Apple Notes CRUD Add-ons Implementation Plan

**Status**: Ready for focused hardening implementation after Step 3 design review `comm-000724`
**Workflow Mode**: issue-resolution
**Issue Reference**: Finish apple-gateway Notes CRUD add-ons: close outstanding review/adversarial hardening findings
**Design Reference**: design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md#built-in-rielaapple-note-
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Sources**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
- `design-docs/user-qa/qa-apple-notes-crud-gateway-confirmations.md`

Step 3 accepted the latest design in communication `comm-000724` with decision
`accepted`. This plan treats the accepted design-doc update as the source of
truth and supersedes the older broad implementation plan for the next
implementation step.

Codex agent trace:
- `codex-design-and-implement-review-loop-session-1152`

### Summary

The Apple Notes CRUD add-ons are already implemented in the working tree. The
next implementation step must not redesign or rewrite them from scratch. It
must close exactly the accepted hardening findings from `comm-000724`:

- file materialization parent validation must be side-effect-free on reject
  paths, reject symlink components, and enforce resolved-path boundaries before
  any directory creation
- note parsing must return `when.has_note = false` for null or missing
  `data.note`, while present non-object note values remain invalid output
- timeout cleanup must terminate the apple-gateway process group and
  descendants, with destructive mutation add-on coverage

### Scope

**Included**:
- Focused edits to
  `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`,
  `Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift`, and
  `Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`.
- Documentation progress updates in this plan only when implementation or
  verification changes the status.
- Verification commands listed by the accepted review.

**Excluded**:
- Reworking catalog shape, add-on ids, example strategy, or GraphQL operation
  design that Step 3 already accepted.
- Touching unrelated working-tree changes.
- Modifying the pre-existing dirty files
  `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift`.

---

## Current Hardening Task Breakdown

### HARDEN-001: Side-effect-free body materialization root validation

**Status**: PLANNED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`

**Tasks**:
- [ ] Inspect existing `AppleGatewayFileDownloader` root validation and
  materialization directory creation order.
- [ ] Before `mkdir`, walk every existing parent component of `downloadDir` /
  `RIELA_APPLE_NOTES_DOWNLOAD_ROOT`, resolve real paths, reject symlink
  components, and ensure the resolved path remains under the allowed private
  runtime root.
- [ ] Ensure rejected paths create no new directory or file-system side effect.
- [ ] Preserve existing successful materialization behavior, local-path
  boundary checks, owner-private permissions, and provider-error mapping for
  bad download envelopes.
- [ ] Add fake-executable/filesystem coverage for an intermediate-symlink
  `downloadDir`, including an assertion that no outside directory is created.

**Deliverables**:
- Hardened materialization path validator with no `mkdir` on reject paths.
- Regression test proving intermediate symlink rejection and no outside
  directory creation.

### HARDEN-002: Note parsing distinction for absent/null vs malformed notes

**Status**: PLANNED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift`
- `Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`

**Tasks**:
- [ ] Inspect `riela/apple-note-get` parsing of `data.note`.
- [ ] Change null or missing `data.note` to a successful output with
  `when.has_note = false` and no malformed-output error.
- [ ] Keep present non-object `data.note` values mapped to
  `AdapterExecutionError.invalidOutput`.
- [ ] Add fake-executable coverage for a non-object note value.
- [ ] Preserve existing success, materialization, and GraphQL error behavior.

**Deliverables**:
- Explicit absent/null-note handling in get output.
- Regression test for malformed present non-object note output.

### HARDEN-003: Process-tree timeout cleanup for destructive mutations

**Status**: PLANNED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`

**Tasks**:
- [ ] Inspect existing timeout cleanup in `AppleGatewayProcessRunner`.
- [ ] Ensure the apple-gateway subprocess is launched in a process group where
  supported and timeout cleanup terminates the group, then escalates if needed.
- [ ] Ensure descendant processes that inherit stdout/stderr cannot outlive the
  adapter call or keep pipe drains open indefinitely.
- [ ] Add fake-executable coverage for a destructive mutation add-on
  (`delete`, `move`, or `update-body`) that spawns a descendant past deadline.
- [ ] Assert the descendant is terminated on timeout, not merely that the
  adapter returns promptly.
- [ ] Preserve existing timeout error mapping as `.timeout`.

**Deliverables**:
- Process-group and descendant-aware timeout cleanup.
- Regression test proving descendant termination for a destructive mutation
  timeout path.

### HARDEN-004: Verification, progress log, and safety audit

**Status**: PLANNED
**Write Scope**:
- `impl-plans/active/apple-notes-crud-addons.md`

**Tasks**:
- [ ] Run all required verification commands.
- [ ] Record pass/fail results and any known pre-existing unrelated dirty files
  in the progress log.
- [ ] Confirm no hardcoded `/Users/taco/...apple-gateway` source paths in
  committed source surfaces.
- [ ] Confirm `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift` remain
  untouched.

**Deliverables**:
- Progress-log entry with exact commands and outcomes.
- Clean handoff evidence for Step 5 review.

## Current Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| HARDEN-001 | Step 3 accepted design `comm-000724` | Implements accepted materialization hardening |
| HARDEN-002 | Step 3 accepted design `comm-000724` | Implements accepted note parsing behavior |
| HARDEN-003 | Step 3 accepted design `comm-000724` | Implements accepted timeout hardening |
| HARDEN-004 | HARDEN-001 through HARDEN-003 | Verification must run after code and tests are updated |

## Current Parallelizable Tasks

| Task | Can Run In Parallel With | Reason |
| ---- | ------------------------ | ------ |
| HARDEN-001 test design | HARDEN-002 parser/test edits | File materialization and note parsing contracts are separate code paths; avoid simultaneous writes to the same test file |
| HARDEN-003 support-code inspection | HARDEN-002 parser implementation | Timeout support inspection and CRUD note parsing have disjoint source files |

Do not parallelize final edits to `Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`.
The hardening tests share helpers and should be reconciled in one pass before
verification.

## Current Verification

Required commands:

```bash
swift test --filter AppleNotesCrud
swift test --filter AppleGateway
swift test --filter AddonExecutionContractsTests
swift build
riela workflow validate apple-note-read --workflow-definition-dir examples
riela workflow validate apple-note-create --workflow-definition-dir examples
git status --short
rg -n "/Users/taco/.+apple-gateway"
```

Expected verification notes:
- New hardening regressions fail before the fix and pass after the fix where
  feasible to demonstrate coverage.
- No live Apple Notes access or macOS automation permission is required.
- Validation of example bundles remains offline.
- Unrelated dirty files remain untouched.

## Current Completion Criteria

- [ ] Materialization root validation rejects intermediate symlinks and
  out-of-root resolved paths before directory creation.
- [ ] Rejected materialization paths leave no outside directory side effects.
- [ ] `apple-note-get` returns `when.has_note = false` for missing or null
  `data.note`.
- [ ] Present non-object `data.note` maps to `.invalidOutput`.
- [ ] Timeout cleanup terminates apple-gateway descendants for destructive
  mutation add-ons.
- [ ] Required filtered Swift tests, build, workflow validations, status audit,
  and hardcoded-path audit pass or have documented residual risk.
- [ ] Step 5 reviewers can trace each fix to `comm-000724`, the accepted
  design-doc files, and `codex-design-and-implement-review-loop-session-1152`.

## Historical Full Implementation Task Breakdown

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
- [x] Resolved workflow input text is not rendered as a template a second time;
  literal `{{...}}` note titles and bodies are preserved in GraphQL variables.
- [x] Required title, note id, folder id, and body non-empty validation fails
  closed when the resolved value is whitespace-only, while non-blank values are
  sent to GraphQL variables verbatim.
- [x] `riela/apple-note-get` materializes body files through download keys into
  a private runtime directory and returns local paths.
- [x] `riela/apple-note-get` fails closed with `.providerError` when
  `materializeBody` requests a download key but `apple-gateway file download`
  returns no local-path mapping for that key.
- [x] `riela/apple-note-get` validates materialized `localPath` values are
  inside the requested `outputRoot` and exist before publishing them.
- [x] `riela/apple-note-get` resolves materialized output roots and local paths
  through real paths, rejects symlink output roots, and rejects symlink or
  non-regular downloaded files before publishing local paths.
- [x] `riela/apple-note-get` creates new materialization roots with `0700`
  permissions and rejects existing download roots that are not current-user
  owned and owner-private.
- [x] Apple Gateway timeout cleanup is bounded when a subprocess descendant
  keeps stdout or stderr pipes open after the parent is terminated.
- [x] Fake-executable tests cover the accepted success and failure matrix.
- [x] Safe read/create examples validate.
- [x] Catalog docs and QA notes match the final implemented behavior.
- [x] Verification commands and results are recorded in this plan's progress
  log.

## Progress Log

### Session: 2026-07-07 Step 4 Hardening Plan `comm-000724`

**Tasks Completed**: Revised the active implementation plan for the accepted
Step 3 design review.
**Tasks In Progress**: HARDEN-001 through HARDEN-004 are planned for the next
implementation step.
**Blockers**: None.
**Notes**:
- Plan source of truth is the accepted design review payload from `comm-000724`
  and the reviewed design docs listed above.
- The plan intentionally keeps the prior Apple Notes CRUD implementation
  intact and scopes the next implementation step to the three accepted
  hardening findings only.
- Step 5 review feedback is not present in the runtime variables for this
  rerun, so no Step 5 high or mid findings required additional plan changes.
- Progress-log expectation for the implementation step: append exact command
  results for the filtered Swift tests, build, example validations, dirty-file
  audit, and hardcoded-path audit before handoff.

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

### Session: 2026-07-07 Step 6 Review Rerun `comm-000659`

**Tasks Completed**: Addressed both mid-severity Step 7 findings from
communication `comm-000659`.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**:
- Fixed Apple Notes CRUD string resolution so values already resolved from
  `addon.inputs` / workflow input are passed into GraphQL variables verbatim.
  Only authored config templates are rendered by the CRUD executor.
- Added fake-executable regression
  `testAppleNoteCrudResolvedUserTextIsNotTemplatedTwice` for note title/body
  values containing literal `{{...}}`.
- Fixed `AppleGatewayFileDownloader` to standardize returned `localPath`
  values, reject paths outside the requested download root, and reject paths
  that do not exist before publishing `bodyFile.localPath` /
  `body.materializedPath`.
- Added fake-executable regression
  `testAppleNoteGetMaterializeValidatesDownloadedLocalPath` for outside-root
  and missing-file envelopes.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleNotesCrud`
  (13 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
  (11 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
  (5 tests).
- PASS targeted SwiftLint:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`.
- NOTE full SwiftLint was run with the same Xcode-toolchain environment. It
  still reports only pre-existing warnings in
  `Sources/RielaCLI/RielaArgumentParserHelpers.swift` and
  `Sources/RielaCLI/WorkflowPackageParityCommands.swift`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-read --workflow-definition-dir examples`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-create --workflow-definition-dir examples`.
- PASS `git diff --check`.
- PASS `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`;
  hits remain limited to implementation-plan documentation.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`;
  touched Swift files are under 1000 lines.
- PASS `git status --short`; unrelated untracked note-edit-agent-ui design /
  implementation-plan files remain outside this fix.

### Session: 2026-07-07 Step 6 Review Rerun `comm-000663`

**Tasks Completed**: Addressed the mid-severity Step 7 finding from
communication `comm-000663`.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**:
- Fixed Apple Notes CRUD validation so required strings and body-presence
  checks fail closed when the resolved value trims to empty, while preserving
  non-blank resolved values verbatim in GraphQL variables.
- Added fake-executable regression
  `testAppleNoteCrudRejectsWhitespaceOnlyRequiredInputs` covering whitespace-only
  create title/body, update body, get/delete `noteId`, and move `folderId`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleNotesCrud`
  (14 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
  (11 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
  (5 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS targeted SwiftLint:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-read --workflow-definition-dir examples`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-create --workflow-definition-dir examples`.
- PASS `git diff --check`.
- PASS `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`;
  hits are limited to implementation-plan command text.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`;
  touched Swift files are under 1000 lines.
- PASS `git status --short`; unrelated note UI dirty files remain outside this
  fix.

### Session: 2026-07-07 Step 6 Adversarial Review Rerun `comm-000668`

**Tasks Completed**: Addressed both mid-severity Step 7 adversarial findings
from communication `comm-000668`.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**:
- Hardened `AppleGatewayFileDownloader` so body materialization validates an
  output root by real path, rejects symlink output roots, compares downloaded
  real paths against the real output root, and rejects symlink or non-regular
  downloaded files before publishing `bodyFile.localPath` /
  `body.materializedPath`.
- Hardened `AppleGatewayProcessRunner` timeout cleanup by replacing blocking
  `readDataToEndOfFile` drains with cancellable pipe drains and bounded pipe
  waits on timeout, so a subprocess descendant inheriting stdout/stderr cannot
  keep workflow cancellation blocked indefinitely.
- Added fake-executable regression
  `testAppleNoteGetMaterializeRejectsSymlinkRootsAndFiles` for symlink
  download roots and symlink downloaded files.
- Added fake-executable regression coverage in
  `testAppleNoteCrudMapsBinaryTimeoutEnvAndVersionFailures` for a timed-out
  parent process with a background child holding stdout open.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleNotesCrud`
  (15 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
  (11 tests; rerun after an initial transient compile failure from unrelated
  dirty `Tests/AgentAdapterTests/SeatbeltSandboxWiringTests.swift` state).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
  (5 tests).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS targeted SwiftLint:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-read --workflow-definition-dir examples`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-create --workflow-definition-dir examples`.
- PASS `git diff --check`.
- PASS `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`;
  hits are limited to implementation-plan command text.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`;
  touched Swift files are under 1000 lines.
- PASS `git status --short`; unrelated note UI, agent adapter, and seatbelt
  dirty files remain outside this fix.

### Session: 2026-07-07 Step 6 Adversarial Review Rerun `comm-000673`

**Tasks Completed**: Addressed the mid-severity Step 7 adversarial finding from
communication `comm-000673`.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**:
- Hardened `AppleGatewayFileDownloader` materialization root validation so
  existing roots must be current-user owned directories with no group/other
  permission bits before invoking `apple-gateway file download`.
- New materialization roots are created with `0700` permissions and rechecked
  after creation; shared `/tmp` and `/var/tmp` descendants must have an
  owner-private first directory boundary instead of relying on a shared temp
  prefix alone.
- Added fake-executable/filesystem regression
  `testAppleNoteGetMaterializeRejectsPublicRootsAndAcceptsOwnerPrivateRoot`
  covering world-readable, world-writable, and owner-private roots.
- Updated materialization tests to create explicit owner-private download roots
  instead of relying on host umask defaults.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleNotesCrud`
  (16 tests).
- PASS targeted SwiftLint:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
  (11 tests; rerun after an initial transient compile failure while unrelated
  dirty `Sources/RielaCLI/SessionCommands.swift` work was incomplete).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
  (5 tests; rerun after the same transient unrelated dirty-source state).
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-read --workflow-definition-dir examples`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-note-create --workflow-definition-dir examples`.
- PASS `git diff --check`.
- PASS `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`;
  hits are limited to implementation-plan command text.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`;
  touched Swift files are under 1000 lines.
- PASS `git status --short`; unrelated dirty files remain outside this fix.

### Session: 2026-07-07 Step 6 Adversarial Review Rerun `comm-000678`

**Tasks Completed**: Addressed the mid-severity Step 7 adversarial finding from
communication `comm-000678`.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**:
- Hardened `AppleGatewayProcessRunner` so apple-gateway is spawned in an
  isolated POSIX session/process group on Darwin and timeout cleanup sends TERM
  then KILL to the process group before returning.
- Added timeout cleanup fallback that snapshots and kills descendant PIDs during
  timeout cleanup, covering wrappers that leave destructive child processes
  outside the immediate parent lifecycle.
- Added fake-executable regression coverage in
  `testAppleNoteCrudMapsBinaryTimeoutEnvAndVersionFailures` for a timed-out
  destructive delete add-on whose descendant attempts to write a mutation marker
  after the adapter deadline.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleNotesCrud`
  (16 tests).
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
  hits are limited to implementation-plan command text.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`;
  touched Swift files are under 1000 lines.
- PASS `git status --short`; unrelated dirty files remain outside this fix.

## Related Plans

- **Depends On**: `impl-plans/active/apple-notes-list-addon.md`
- **Design Step**: Step 3 communication `comm-000650`
