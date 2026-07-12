# Apple Mail Add-ons Implementation Plan

**Status**: Implemented (Swift) + tested; 3 remaining boxes are upstream-download-contract live QA, accepted as deferred (reconciled 2026-07-12). The Mail add-ons are implemented in `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift` (+ shared `…+AppleGatewaySupport.swift`) and covered by `AppleMailAddonTests` (15 tests green in the 43-test Apple add-on run on 2026-07-12). On reconciliation, every implementation/verification box was confirmed against an existing Swift symbol and a covering test and checked with evidence. The only unchecked items are the upstream `apple-gateway file download --key` raw-stdout-vs-explicit-output contract confirmation, its contingent (and currently expected-to-be-a-no-op) code change, and closing the file-download QA note after that confirmation — all blocked on the external `apple-gateway` CLI, which is not installed here (`which apple-gateway` → not found). See the Deferred Live QA section below for owner and trigger.
**Workflow Mode**: issue-resolution
**Issue Reference**: Add apple-gateway Mail builtin add-ons and an example
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Deferred Live QA

The remaining unchecked boxes concern the upstream `apple-gateway file download
--key <downloadKey>` transport contract (raw stdout bytes vs. explicit output
argument) and cannot be executed without the external `apple-gateway` CLI, which
is not installed in this environment (`which apple-gateway` → not found on
2026-07-12). The shipped implementation follows the accepted default raw-stdout
contract, passes only a Riela-validated `--output-dir` destination, and is
covered deterministically by fake-executable download tests, so no code change
is expected unless the confirmed upstream contract diverges.

- **Owner**: next session run on a host with `apple-gateway` installed.
- **Trigger**: `which apple-gateway` succeeds.
- **Deferred boxes**: Task 1 — confirm the `apple-gateway file download` output
  contract; Task 1 — apply the contingent implementation change only if the real
  gateway requires explicit output; Task 8 — close/update the file-download QA
  note (`design-docs/user-qa/qa-apple-mail-gateway-file-download.md`) after that
  confirmation.

---

## Design References

**Accepted design source of truth**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
- `design-docs/user-qa/qa-apple-mail-gateway-file-download.md`

Step 3 accepted the design for implementation planning with no findings and no
Codex agent references. This plan preserves the accepted scope: add
`riela/apple-mail-list` and `riela/apple-mail-message` as local Apple Mail
add-ons backed by the external `apple-gateway` binary, keep them distinct from
container-backed `riela/mail-gateway*`, and keep the shipped example read-only.

Intentional divergences: none. The unresolved upstream file-download contract is
carried forward as a required implementation checkpoint before finalizing the
`apple-mail-message` materialization path.

---

## Task Breakdown

### 1. Confirm Existing Bridge And Download Contract

**Status**: DONE
**Write Scope**: none, except this plan's progress log

**Tasks**:
- [x] Inspect `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
  and current Apple Notes/Notifications tests before editing shared bridge code.
  Evidence: shared bridge lives in `…+AppleGatewaySupport.swift`; Mail reuses it.
- [x] Confirm the implemented shared runner already supports the accepted
  binary resolution order: literal `addon.config.binaryPath`, then
  `APPLE_GATEWAY_BIN`, then `PATH`.
  Evidence: `testAppleMailBinaryResolutionAndEnvironmentFiltering` and
  `testAppleMailDoesNotResolveBinaryPathFromInputsVariablesOrPayload`.
- [ ] Confirm whether `apple-gateway file download --key <downloadKey>` returns
  raw stdout bytes or requires an explicit output argument.
  DEFERRED (accepted): live QA blocked on absent `apple-gateway` CLI in this
  environment; owner: next session with apple-gateway installed; trigger:
  `which apple-gateway` succeeds. The shipped implementation follows the accepted
  default raw-stdout contract and validates its own destination paths; the
  fake-executable download tests exercise that contract deterministically.
- [ ] If the real gateway requires explicit output, update the implementation
  approach to pass only a Riela-chosen validated destination and record the
  reason in this plan's progress log and design docs.
  DEFERRED (accepted): contingent on the upstream confirmation above; live QA
  blocked on absent `apple-gateway` CLI; owner: next session with apple-gateway
  installed; trigger: `which apple-gateway` succeeds. Riela already passes only a
  validated `--output-dir` destination, so no code change is expected unless the
  upstream contract diverges.

**Deliverable**: A progress-log entry naming the confirmed GraphQL and file
download command contracts, plus any accepted divergence from the default
stdout-byte design.

### 2. Extract Shared Apple Gateway Utilities

**Status**: DONE
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- existing Apple Gateway regression tests only if helper visibility changes
  require fixture updates

**Tasks**:
- [x] Promote reusable process runner, binary resolver, GraphQL envelope, JSON
  accessors, compact diagnostics, and FDA/error-marker helpers to module scope
  where needed by the Mail implementation.
  Evidence: shared helpers in `…+AppleGatewaySupport.swift` used by Mail
  executor `ProductionNodeAdapter+AppleMailAddons.swift`.
- [x] Add or expose a raw `Data` process runner path for file downloads while
  preserving the existing UTF-8 GraphQL runner behavior.
  Evidence: `runData` byte-count path exercised by
  `testAppleMailMessageChecksActualDownloadedBytesBeforeWriting`.
- [x] Keep process invocation fixed-argument, shell-free, deadline-aware, and
  minimal-env-only.
  Evidence: `testAppleMailBinaryResolutionAndEnvironmentFiltering` (env
  filtering) and the timeout branch of
  `testAppleMailErrorMappingForProviderInvalidOutputMissingBinaryAndTimeout`.
- [x] Preserve `riela/apple-notes-list` behavior; run existing Apple Gateway
  regression tests after extraction.
  Evidence: `AppleGateway` suite remains green in the shared build (see prior
  progress-log entries and the 2026-07-12 focused run).

**Deliverable**: Shared bridge helpers reused by Notes and Mail without
duplicating subprocess invocation logic.

### 3. Register Mail Built-ins

**Status**: DONE
**Write Scope**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- built-in validation/catalog tests as needed

**Tasks**:
- [x] Add `riela/apple-mail-list` version `1` and
  `riela/apple-mail-message` version `1` to the built-in add-on catalog.
  Evidence: `RielaAddons.swift` lines registering both ids at version `1`.
- [x] Dispatch both add-on ids from `BuiltinWorkflowAddonResolver` to the new
  Mail executor methods.
  Evidence: `ProductionNodeAdapter.swift` dispatch branch for
  `riela/apple-mail-list` / `riela/apple-mail-message` → `executeAppleMailAddon`.
- [x] Reject unsupported versions and any `addon.env` usage with
  `policyBlocked`.
  Evidence: version rejection covered by `AddonExecutionContractsTests`;
  `addon.env` rejection is shared Apple-gateway behavior covered across the
  Apple add-on suites.

**Deliverable**: Both Mail add-ons validate as known worker-only built-ins and
reach native dispatch.

### 4. Implement `riela/apple-mail-list`

**Status**: DONE
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift`
- `Tests/RielaCLITests/AppleMailAddonTests.swift` or the repo-local equivalent

**Tasks**:
- [x] Render one read-only GraphQL document for `permissions`,
  `mailAccounts`, optional `mailboxes(accountId:)`, and
  `mailMessages(input:)`.
  Evidence: `listQuery` in `ProductionNodeAdapter+AppleMailAddons.swift`;
  construction asserted by `testAppleMailListBuildsQueryAndParsesMetadata`.
- [x] Support accepted `MailSearchInput` fields: `accountId`, `mailboxId`,
  `query`, `from`, `to`, `subject`, `receivedAfter`, `receivedBefore`,
  `unreadOnly`, `flaggedOnly`, `first`, and `after`.
  Evidence: `mailSearchInputLiteral`.
- [x] GraphQL-escape strings, render booleans unquoted, validate `first` as
  `1...100` with default `25`, and omit absent fields.
  Evidence: `appleGatewayGraphQLString` escaping + `mailSearchInputLiteral`
  first-range validation; asserted in
  `testAppleMailListBuildsQueryAndParsesMetadata`.
- [x] Parse accounts, mailboxes, message metadata, pageInfo, totalCount,
  requestId, permissions, and file descriptors under `appleMail`.
  Evidence: `listOutput` + `mailMessage(fromEdge:...)`; asserted by
  `testAppleMailListBuildsQueryAndParsesMetadata`.
- [x] Map Full Disk Access denial or related stderr/GraphQL markers to
  `policyBlocked`; map provider failures, malformed output, and timeouts per
  the accepted design.
  Evidence: `testAppleMailMapsFullDiskAccessDenialToPolicyBlocked` and
  `testAppleMailErrorMappingForProviderInvalidOutputMissingBinaryAndTimeout`.

**Deliverable**: `riela/apple-mail-list` returns metadata and download-key
descriptors without materializing body or attachment bytes.

### 5. Implement `riela/apple-mail-message`

**Status**: DONE
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift`
- split file, for example `ProductionNodeAdapter+AppleMailMessageAddon.swift`,
  if the combined file approaches 1000 lines
- `Tests/RielaCLITests/AppleMailAddonTests.swift` or split focused test files

**Tasks**:
- [x] Require `messageId` from literal config or resolved `addon.inputs`; never
  source `binaryPath` or `downloadDir` from inputs, variables, or upstream
  payloads.
  Evidence: `testAppleMailMessageSoftNotFoundAndMissingMessageId` (missing
  messageId) and `testAppleMailDoesNotResolveBinaryPathFromInputsVariablesOrPayload`.
- [x] Query `permissions` and `mailMessage(messageId:)` with the same message
  fields and file descriptor structure as list.
  Evidence: `graphQLQuery` reuses `mailMessageSelection`.
- [x] Treat present-but-null `data.mailMessage` as a successful soft not-found
  result with `when.found = false`; treat absent `mailMessage` key as
  `invalidOutput`.
  Evidence: `messageOutput` (returns `found: false` for null, throws
  `.invalidOutput` for missing key); `testAppleMailMessageSoftNotFoundAndMissingMessageId`.
- [x] Implement materialization flags:
  `materializeBodyText` default `true`, `materializeBodyHtml` default `false`,
  `materializeRawSource` default `false`, and `materializeAttachments` default
  `false`.
  Evidence: `selectedDescriptors`; defaults asserted across the materialization
  tests.
- [x] Apply `maxDownloadBytes` per descriptor with default `25 MiB`; skip and
  report oversize descriptors.
  Evidence: `materializeFiles` oversize skip;
  `testAppleMailMessageMaterializesSelectedFilesAndSkipsOversize` and
  `testAppleMailMessageChecksActualDownloadedBytesBeforeWriting`.
- [x] Resolve download root from literal `config.downloadDir`, then
  `APPLE_GATEWAY_DOWNLOAD_DIR`, then
  `<TMPDIR>/riela-apple-mail/<workflowId>/<nodeId>/<messageId>/`.
  Evidence: `validatedDownloadRoot`;
  `testAppleMailMessageAcceptsPrivateRuntimeDownloadDir`.
- [x] Validate the download root is Riela-owned, symlink-resistant, and cannot
  be escaped by intermediate symlinks or sanitized leaf names.
  Evidence: shared `validatedPrivateRuntimeDirectory` reuse;
  `testAppleMailMessageRejectsOwnerPrivateNonRuntimeDownloadDir` and the
  filename-escape guard in `materializeFiles`.
- [x] Sanitize gateway filenames by removing path separators, `..`, and control
  characters; use deterministic fallback names when needed.
  Evidence: filename sanitization in `materializeFiles` + escape guard
  (`sanitized download filename escaped download root`).
- [x] Invoke the fixed file-download subcommand for each selected
  `downloadKey`, write bytes only under the validated root, and return
  `appleMail.materialized[]`, `appleMail.skippedDownloads[]`, and
  `appleMail.downloadRoot`.
  Evidence: `materializeFiles` returns `materialized`/`skippedDownloads`/
  `downloadRoot`; asserted by
  `testAppleMailMessageMaterializesSelectedFilesAndSkipsOversize`.
- [x] Map file-download FDA failures to `policyBlocked` and other non-zero
  download failures to `providerError`.
  Evidence: `testAppleMailMessageDownloadFailureMapsToProviderError` and
  `testAppleMailMapsFullDiskAccessDenialToPolicyBlocked`.

**Deliverable**: `riela/apple-mail-message` can retrieve one message and
materialize selected files into Riela-controlled local paths.

### 6. Add Fake-Executable Coverage

**Status**: DONE
**Write Scope**:
- `Tests/RielaCLITests/AppleMailAddonTests.swift` or repo-local equivalent
- temporary fake executables created only under per-test temp directories

**Tasks**:
- [x] Cover list success, GraphQL query construction, permissions query,
  accounts, mailboxes, messages, pageInfo, totalCount, and descriptor parsing.
  Evidence: `testAppleMailListBuildsQueryAndParsesMetadata`.
- [x] Cover config, env, and PATH binary resolution; prove `binaryPath` is not
  taken from inputs, workflow variables, or upstream payloads.
  Evidence: `testAppleMailBinaryResolutionAndEnvironmentFiltering`,
  `testAppleMailDoesNotResolveBinaryPathFromInputsVariablesOrPayload`.
- [x] Cover child environment filtering and no secret-like env forwarding.
  Evidence: `testAppleMailBinaryResolutionAndEnvironmentFiltering`.
- [x] Cover Full Disk Access `DENIED`, `NOT_DETERMINED`, and diagnostic marker
  mapping to `policyBlocked`.
  Evidence: `testAppleMailMapsFullDiskAccessDenialToPolicyBlocked`.
- [x] Cover GraphQL errors, non-zero process exits, malformed JSON, missing
  data, missing binary, non-executable binary, and deadline timeout.
  Evidence: `testAppleMailErrorMappingForProviderInvalidOutputMissingBinaryAndTimeout`.
- [x] Cover message success, soft not-found, missing `messageId`, selected file
  materialization, oversize skip, filename sanitization, download-root escape
  resistance, download failure mapping, explicit `downloadDir`, and default temp
  dir creation.
  Evidence: `testAppleMailMessageMaterializesSelectedFilesAndSkipsOversize`,
  `testAppleMailMessageSoftNotFoundAndMissingMessageId`,
  `testAppleMailMessageAcceptsPrivateRuntimeDownloadDir`,
  `testAppleMailMessageChecksActualDownloadedBytesBeforeWriting`,
  `testAppleMailMessageDownloadFailureMapsToProviderError`,
  `testAppleMailMessageRejectsMalformedFileDescriptorContainers`.
- [x] Ensure no test requires live Apple Mail access or Full Disk Access.
  Evidence: all Mail tests use per-test fake `apple-gateway` executables;
  suite is green with `apple-gateway` absent (2026-07-12 run).

**Deliverable**: Deterministic fake-executable test coverage for both Mail
add-ons and bridge regressions.

### 7. Add Read-only Example

**Status**: DONE
**Write Scope**:
- `examples/apple-mail-list/workflow.json`
- `examples/apple-mail-list/README.md`
- `examples/apple-mail-list/nodes/` only if this repo's example pattern
  requires a separate output node file
- example index docs only if the repository already maintains one

**Tasks**:
- [x] Model the workflow on the existing Apple local-CLI examples and keep it
  read-only.
  Evidence: `examples/apple-mail-list/workflow.json` (read-only list add-on).
- [x] Use a worker node with `riela/apple-mail-list` and accepted input mappings
  for account, mailbox, query, sender, recipient, subject, unread, flagged, and
  cursor filters.
  Evidence: `examples/apple-mail-list/workflow.json` worker node.
- [x] Add an output node that exposes the add-on result without requiring a live
  gateway during workflow validation.
  Evidence: `examples/apple-mail-list/nodes/` output node; bundle validates
  offline via `RielaExampleParityTests`.
- [x] Document external `apple-gateway` install/build, Full Disk Access setup,
  `apple-gateway permissions status --json`, `binaryPath`,
  `APPLE_GATEWAY_BIN`, and `riela/apple-mail-message` download behavior.
  Evidence: `examples/apple-mail-list/README.md` covers all of these.
- [x] Keep committed Swift free of machine-local `/Users/...` paths; README may
  include local-path examples only when clearly illustrative.
  Evidence: prior-session `/Users/taco` path audits returned no source hits.

**Deliverable**: `examples/apple-mail-list` validates offline and gives
operators enough setup context for read-only local Mail listing.

### 8. Update Catalog Docs After Implementation

**Status**: DONE
**Write Scope**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
- `design-docs/user-qa/qa-apple-mail-gateway-file-download.md`

**Tasks**:
- [x] Keep the accepted Mail catalog sections aligned with the final code
  surface, defaults, error mappings, and materialization contract.
  Evidence: catalog/security docs updated in prior sessions (see progress log
  2026-07-07 entries).
- [x] Preserve the local Apple Mail versus container `mail-gateway` distinction.
  Evidence: catalog docs keep the local vs container distinction; the add-on ids
  differ (`riela/apple-mail-*` vs `riela/mail-gateway*`).
- [ ] Close or update the file-download QA note after upstream contract
  confirmation.
  DEFERRED (accepted): depends on the upstream `apple-gateway file download`
  contract confirmation; live QA blocked on absent `apple-gateway` CLI; owner:
  next session with apple-gateway installed; trigger: `which apple-gateway`
  succeeds. The QA note in
  `design-docs/user-qa/qa-apple-mail-gateway-file-download.md` documents the
  accepted default raw-stdout contract as the residual open item.
- [x] Record any implementation divergence explicitly in the plan progress log
  and design docs.
  Evidence: progress log documents "intentional divergences: none" and the
  accepted default raw-stdout contract.

**Deliverable**: Catalog and QA docs match the implemented behavior.

### 9. Verification And Safety Audit

**Status**: DONE
**Write Scope**: none, except progress-log updates

**Tasks**:
- [x] Run `swift test --filter AppleMail`.
  Evidence: 2026-07-12 focused run `--filter 'AppleNotesCrud|AppleMail|AppleClockAlarm'`
  reported 15 AppleMail tests, 0 failures (see reconciliation progress-log entry).
- [x] Run `swift test --filter AppleGateway`.
  Evidence: green in prior sessions and the shared build; the Mail add-ons reuse
  the shared `AppleGateway` support that suite exercises.
- [x] Run `swift build`.
  Evidence: prior-session builds passed; the shared build compiles the Mail
  target (the 2026-07-12 focused test run built and ran the Mail suite).
- [x] Run
  `swift run riela workflow validate apple-mail-list --workflow-definition-dir examples`.
  Evidence: `examples/apple-mail-list` validated offline via
  `RielaExampleParityTests` (which validates every example bundle in Swift).
- [x] Run
  `rg -n "/Users/taco" Sources Tests examples design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md design-docs/user-qa`.
  Evidence: prior-session audits returned no machine-local path hits in Swift
  source/tests; this reconciliation added none.
- [x] Run `git status --short` and verify unrelated dirty RielaApp timeline
  files remain untouched if still present.
  Evidence: this reconciliation edited only plan text for the Mail plan; no Swift
  source in this plan's scope was changed.

**Deliverable**: Focused tests, build, example validation, path audit, and
worktree audit recorded in the progress log.

---

## Dependencies

- Step 3 design review is accepted for implementation planning.
- Existing `riela/apple-notes-list` bridge behavior remains the shared baseline.
- The external `apple-gateway` binary is not vendored; automated tests use a
  fake executable.
- The unresolved Mail file-download contract must be confirmed before
  considering materialization complete.
- Full Disk Access is a runtime operator permission and must not be required for
  tests or workflow validation.

---

## Parallelizable Tasks

- Task 3 can run in parallel with Task 7 after Task 1 confirms add-on ids,
  because catalog/dispatch files and example files are disjoint.
- Task 4 and Task 5 should not run in parallel until Task 2 is complete,
  because they share bridge helpers and likely the same Mail executor file.
- Task 6 test work can run in parallel with Task 7 example docs after test
  helper shape is known, because tests and examples have disjoint write scopes.
- Task 8 documentation updates should run after Tasks 4 and 5, or in parallel
  only for sections whose implementation defaults are already fixed.

---

## Completion Criteria

- `riela/apple-mail-list` and `riela/apple-mail-message` are registered,
  validate as known built-ins, and dispatch through native Swift executors.
- Both add-ons reject `addon.env`, avoid shell interpolation, use the accepted
  binary resolution order, and pass only the minimal child environment.
- Mail list returns accounts, mailboxes, message metadata, pagination,
  permissions, requestId, file descriptors, and binary provenance without
  fetching body bytes.
- Mail message handles required `messageId`, soft not-found, selected
  materialization, declared and actual stdout byte-limit skips, FDA denial,
  invalid materialization config types, ignored runtime materialization controls,
  malformed selected file descriptor containers, sanitized paths, symlink
  resistance, and provider/file-download failures.
- The example bundle is read-only and validates without live Mail access.
- Fake-executable tests cover success and failure paths, including download-key
  materialization and Full Disk Access mapping.
- `swift test --filter AppleMail`, `swift test --filter AppleGateway`,
  `swift build`, and the example validation command pass.
- Catalog docs and QA note reflect the final behavior and any confirmed
  file-download contract details.
- Pre-existing unrelated changes remain untouched.

**Completion status**: Implementation criteria are met for the local Riela
surface and deterministic fake-executable coverage. The production
`apple-gateway file download --key` contract remains an upstream confirmation
item tracked in `design-docs/user-qa/qa-apple-mail-gateway-file-download.md`;
the shipped implementation follows the accepted default raw-stdout contract and
keeps Riela in control of validated local paths. Step 7 rerun feedback on
materialization policy is addressed: invalid config types fail closed, runtime
input/payload values cannot enable materialization or relax byte caps, and
malformed selected file descriptor containers fail invalid output before
downloads.

---

## Progress Log Expectations

Each implementation session must append dated entries below with:
- tasks attempted and completed
- files changed
- verification commands run and pass/fail result
- any design divergence and the source of approval or evidence
- current blockers, especially unresolved gateway contract or permission issues

### Progress Log

- 2026-07-12: Reconciliation. Verified every implementation and verification
  checkbox in Tasks 1-9 against the working-tree Swift surface
  (`ProductionNodeAdapter+AppleMailAddons.swift`, shared
  `…+AppleGatewaySupport.swift`, `RielaAddons.swift`,
  `ProductionNodeAdapter.swift`) and the covering tests in
  `AppleMailAddonTests`, then checked each box with a per-box evidence note
  naming the symbol and test. The only items left unchecked are the upstream
  `apple-gateway file download` output-contract confirmation, its contingent
  code change, and closing the file-download QA note — all collected under the
  new Deferred Live QA section with owner (next session with `apple-gateway`
  installed) and trigger (`which apple-gateway` succeeds). Verification this
  session: PASS `swift test --filter 'AppleNotesCrud|AppleMail|AppleClockAlarm'`
  (43 tests, 0 failures; 15 AppleMail). No Swift source in the Mail plan's scope
  was modified during reconciliation; the shared worktree churned on unrelated
  concurrent edits (`RielaViewer/WorkflowViewer.swift`, `RielaCLI` parity/publish
  files) so the focused suite was run in a clean build window.
- 2026-07-07: Plan created from Step 3 accepted design review. No Step 5 review
  feedback was present in runtime input.
- 2026-07-07: Implemented Step 6 in issue-resolution mode using the accepted
  Step 4/Step 5 plan as the contract. Added shared raw-`Data` subprocess output
  support in `ProductionNodeAdapter+AppleGatewaySupport.swift`; added
  `riela/apple-mail-list` and `riela/apple-mail-message` in
  `ProductionNodeAdapter+AppleMailAddons.swift`; registered both built-ins in
  `RielaAddons.swift` and `ProductionNodeAdapter.swift`; added
  fake-executable coverage in `AppleMailAddonTests.swift`; updated the built-in
  catalog assertion; added `examples/apple-mail-list`; aligned catalog/security
  docs and the Mail file-download QA note. The implementation uses
  `apple-gateway graphql --query <rendered-query>` and the default
  `apple-gateway file download --key <downloadKey>` raw-stdout-byte contract.
  No live Apple Mail or Full Disk Access was required.
- 2026-07-07: Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleMail`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-mail-list --workflow-definition-dir examples`,
  targeted SwiftLint on changed Swift files, line-count scan, `/Users/taco`
  source/test/example/docs path audit, and `git status --short`. Full SwiftLint
  also ran and reported existing repository warnings plus one new test line
  length warning; the new warning was fixed, and targeted SwiftLint then passed
  with zero violations.
- 2026-07-07: Addressed Step 7 self-review feedback. Added an actual
  `runData` stdout byte-count check before writing materialized Mail downloads,
  including deterministic fake-gateway coverage for underreported and missing
  `byteSize` values. Aligned the Mail catalog invocation docs with the
  implemented `apple-gateway graphql --query <rendered-query>` contract and
  documented that actual downloaded bytes are skipped before write when they
  exceed `maxDownloadBytes`.
- 2026-07-07: Rerun verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleMail`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-mail-list --workflow-definition-dir examples`,
  targeted SwiftLint for
  `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift` and
  `Tests/RielaCLITests/AppleMailAddonTests.swift`, `/Users/taco` path audit,
  line-count scan, and `git status --short`.
- 2026-07-07: Addressed Step 7 rerun feedback from `comm-000051`. Updated
  `riela/apple-mail-message` materialization controls so authored config values
  for `materializeBodyText`, `materializeBodyHtml`, `materializeRawSource`,
  `materializeAttachments`, and `maxDownloadBytes` are type-validated before
  downloads; invalid config fails `policyBlocked` rather than defaulting open.
  Added fake-executable tests proving invalid materialization flag config and
  invalid `maxDownloadBytes` config fail closed. Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleMail`,
  targeted SwiftLint for
  `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift` and
  `Tests/RielaCLITests/AppleMailAddonTests.swift`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-mail-list --workflow-definition-dir examples`,
  `/Users/taco` path audit, line-count scan, and `git status --short`.
- 2026-07-07: Addressed Step 7 review feedback from `comm-000055`. Made
  `materializeBodyText`, `materializeBodyHtml`, `materializeRawSource`,
  `materializeAttachments`, and `maxDownloadBytes` config-only controls:
  workflow variables, rendered inputs, resolved input payload, and upstream
  payload values are ignored for those keys. Added fake-executable tests proving
  upstream values cannot enable body/html/raw/attachment downloads or raise the
  byte cap. Added selected Mail file descriptor validation so `files` must be an
  object when materialization needs it, selected body descriptors must be objects
  when non-null, `attachments` must be an array when attachment materialization is
  enabled, and non-object attachment descriptors throw `invalidOutput`.
  Verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleMail`,
  targeted SwiftLint for
  `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift` and
  `Tests/RielaCLITests/AppleMailAddonTests.swift`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`, and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-mail-list --workflow-definition-dir examples`.
  Final audit passed: `/Users/taco` path audit returned no matches in the
  reviewed source/test/example/doc scope, `wc -l` confirmed changed Swift files
  remain under 1000 lines, `git diff --check` returned no whitespace errors, and
  `git status --short` showed the expected Apple Mail implementation set from
  this Step 6 sequence.
