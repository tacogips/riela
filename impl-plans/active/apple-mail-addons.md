# Apple Mail Add-ons Implementation Plan

**Status**: Implemented
**Workflow Mode**: issue-resolution
**Issue Reference**: Add apple-gateway Mail builtin add-ons and an example
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

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
- [ ] Inspect `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
  and current Apple Notes/Notifications tests before editing shared bridge code.
- [ ] Confirm the implemented shared runner already supports the accepted
  binary resolution order: literal `addon.config.binaryPath`, then
  `APPLE_GATEWAY_BIN`, then `PATH`.
- [ ] Confirm whether `apple-gateway file download --key <downloadKey>` returns
  raw stdout bytes or requires an explicit output argument.
- [ ] If the real gateway requires explicit output, update the implementation
  approach to pass only a Riela-chosen validated destination and record the
  reason in this plan's progress log and design docs.

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
- [ ] Promote reusable process runner, binary resolver, GraphQL envelope, JSON
  accessors, compact diagnostics, and FDA/error-marker helpers to module scope
  where needed by the Mail implementation.
- [ ] Add or expose a raw `Data` process runner path for file downloads while
  preserving the existing UTF-8 GraphQL runner behavior.
- [ ] Keep process invocation fixed-argument, shell-free, deadline-aware, and
  minimal-env-only.
- [ ] Preserve `riela/apple-notes-list` behavior; run existing Apple Gateway
  regression tests after extraction.

**Deliverable**: Shared bridge helpers reused by Notes and Mail without
duplicating subprocess invocation logic.

### 3. Register Mail Built-ins

**Status**: DONE
**Write Scope**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- built-in validation/catalog tests as needed

**Tasks**:
- [ ] Add `riela/apple-mail-list` version `1` and
  `riela/apple-mail-message` version `1` to the built-in add-on catalog.
- [ ] Dispatch both add-on ids from `BuiltinWorkflowAddonResolver` to the new
  Mail executor methods.
- [ ] Reject unsupported versions and any `addon.env` usage with
  `policyBlocked`.

**Deliverable**: Both Mail add-ons validate as known worker-only built-ins and
reach native dispatch.

### 4. Implement `riela/apple-mail-list`

**Status**: DONE
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift`
- `Tests/RielaCLITests/AppleMailAddonTests.swift` or the repo-local equivalent

**Tasks**:
- [ ] Render one read-only GraphQL document for `permissions`,
  `mailAccounts`, optional `mailboxes(accountId:)`, and
  `mailMessages(input:)`.
- [ ] Support accepted `MailSearchInput` fields: `accountId`, `mailboxId`,
  `query`, `from`, `to`, `subject`, `receivedAfter`, `receivedBefore`,
  `unreadOnly`, `flaggedOnly`, `first`, and `after`.
- [ ] GraphQL-escape strings, render booleans unquoted, validate `first` as
  `1...100` with default `25`, and omit absent fields.
- [ ] Parse accounts, mailboxes, message metadata, pageInfo, totalCount,
  requestId, permissions, and file descriptors under `appleMail`.
- [ ] Map Full Disk Access denial or related stderr/GraphQL markers to
  `policyBlocked`; map provider failures, malformed output, and timeouts per
  the accepted design.

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
- [ ] Require `messageId` from literal config or resolved `addon.inputs`; never
  source `binaryPath` or `downloadDir` from inputs, variables, or upstream
  payloads.
- [ ] Query `permissions` and `mailMessage(messageId:)` with the same message
  fields and file descriptor structure as list.
- [ ] Treat present-but-null `data.mailMessage` as a successful soft not-found
  result with `when.found = false`; treat absent `mailMessage` key as
  `invalidOutput`.
- [ ] Implement materialization flags:
  `materializeBodyText` default `true`, `materializeBodyHtml` default `false`,
  `materializeRawSource` default `false`, and `materializeAttachments` default
  `false`.
- [ ] Apply `maxDownloadBytes` per descriptor with default `25 MiB`; skip and
  report oversize descriptors.
- [ ] Resolve download root from literal `config.downloadDir`, then
  `APPLE_GATEWAY_DOWNLOAD_DIR`, then
  `<TMPDIR>/riela-apple-mail/<workflowId>/<nodeId>/<messageId>/`.
- [ ] Validate the download root is Riela-owned, symlink-resistant, and cannot
  be escaped by intermediate symlinks or sanitized leaf names.
- [ ] Sanitize gateway filenames by removing path separators, `..`, and control
  characters; use deterministic fallback names when needed.
- [ ] Invoke the fixed file-download subcommand for each selected
  `downloadKey`, write bytes only under the validated root, and return
  `appleMail.materialized[]`, `appleMail.skippedDownloads[]`, and
  `appleMail.downloadRoot`.
- [ ] Map file-download FDA failures to `policyBlocked` and other non-zero
  download failures to `providerError`.

**Deliverable**: `riela/apple-mail-message` can retrieve one message and
materialize selected files into Riela-controlled local paths.

### 6. Add Fake-Executable Coverage

**Status**: DONE
**Write Scope**:
- `Tests/RielaCLITests/AppleMailAddonTests.swift` or repo-local equivalent
- temporary fake executables created only under per-test temp directories

**Tasks**:
- [ ] Cover list success, GraphQL query construction, permissions query,
  accounts, mailboxes, messages, pageInfo, totalCount, and descriptor parsing.
- [ ] Cover config, env, and PATH binary resolution; prove `binaryPath` is not
  taken from inputs, workflow variables, or upstream payloads.
- [ ] Cover child environment filtering and no secret-like env forwarding.
- [ ] Cover Full Disk Access `DENIED`, `NOT_DETERMINED`, and diagnostic marker
  mapping to `policyBlocked`.
- [ ] Cover GraphQL errors, non-zero process exits, malformed JSON, missing
  data, missing binary, non-executable binary, and deadline timeout.
- [ ] Cover message success, soft not-found, missing `messageId`, selected file
  materialization, oversize skip, filename sanitization, download-root escape
  resistance, download failure mapping, explicit `downloadDir`, and default temp
  dir creation.
- [ ] Ensure no test requires live Apple Mail access or Full Disk Access.

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
- [ ] Model the workflow on the existing Apple local-CLI examples and keep it
  read-only.
- [ ] Use a worker node with `riela/apple-mail-list` and accepted input mappings
  for account, mailbox, query, sender, recipient, subject, unread, flagged, and
  cursor filters.
- [ ] Add an output node that exposes the add-on result without requiring a live
  gateway during workflow validation.
- [ ] Document external `apple-gateway` install/build, Full Disk Access setup,
  `apple-gateway permissions status --json`, `binaryPath`,
  `APPLE_GATEWAY_BIN`, and `riela/apple-mail-message` download behavior.
- [ ] Keep committed Swift free of machine-local `/Users/...` paths; README may
  include local-path examples only when clearly illustrative.

**Deliverable**: `examples/apple-mail-list` validates offline and gives
operators enough setup context for read-only local Mail listing.

### 8. Update Catalog Docs After Implementation

**Status**: DONE
**Write Scope**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
- `design-docs/user-qa/qa-apple-mail-gateway-file-download.md`

**Tasks**:
- [ ] Keep the accepted Mail catalog sections aligned with the final code
  surface, defaults, error mappings, and materialization contract.
- [ ] Preserve the local Apple Mail versus container `mail-gateway` distinction.
- [ ] Close or update the file-download QA note after upstream contract
  confirmation.
- [ ] Record any implementation divergence explicitly in the plan progress log
  and design docs.

**Deliverable**: Catalog and QA docs match the implemented behavior.

### 9. Verification And Safety Audit

**Status**: DONE
**Write Scope**: none, except progress-log updates

**Tasks**:
- [ ] Run `swift test --filter AppleMail`.
- [ ] Run `swift test --filter AppleGateway`.
- [ ] Run `swift build`.
- [ ] Run
  `swift run riela workflow validate apple-mail-list --workflow-definition-dir examples`.
- [ ] Run
  `rg -n "/Users/taco" Sources Tests examples design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md design-docs/user-qa`.
- [ ] Run `git status --short` and verify unrelated dirty RielaApp timeline
  files remain untouched if still present.

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
