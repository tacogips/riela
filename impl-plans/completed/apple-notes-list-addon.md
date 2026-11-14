# Apple Notes List Add-on Implementation Plan

**Status**: Implemented, revised, and verified
**Design Reference**: design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md#built-in-rielaapple-notes-list
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Sources**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`

### Summary

Add the built-in worker add-on `riela/apple-notes-list`, backed by an external
`apple-gateway` executable, and ship a deterministic example workflow that
lists Apple Notes without requiring live Notes access during validation or unit
tests.

### Scope

**Included**:
- Register `riela/apple-notes-list` in the built-in add-on dispatch and
  validation/catalog surfaces.
- Implement a local subprocess bridge in
  `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`.
- Resolve the executable from literal `addon.config.binaryPath`, then
  `APPLE_GATEWAY_BIN`, then `PATH`; never source `binaryPath` from
  `addon.inputs`, workflow input, or upstream payloads.
- Invoke only `apple-gateway graphql --query <graphql>` with separate process
  arguments and no shell interpolation.
- Build a read-only Notes GraphQL query using `noteAccounts`, `noteFolders`,
  and `notes(input:)`.
- Parse the upstream GraphQL envelope into `appleNotes` output.
- Pass only a minimal allowlisted environment to the `apple-gateway`
  subprocess; do not forward provider/API secrets by default.
- Add fake-executable unit tests covering argument construction, binary
  resolution precedence, success parsing, GraphQL errors, malformed JSON,
  non-zero exit, and missing binary behavior.
- Add `examples/apple-notes-list/` with README setup guidance.

**Excluded**:
- Vendoring or copying `apple-gateway` source into this repository.
- Mutating Apple Notes through Riela.
- Live Apple Notes access in automated tests.
- Changing unrelated RielaApp timeline files already dirty in the worktree.

### Accepted Review Feedback Addressed In This Plan

- The bounded implementation default for `first` is set to `25`.
- Error mapping is explicit before implementation:
  - missing or non-executable binary: `AdapterExecutionError(.policyBlocked, ...)`
  - non-zero process exit: `AdapterExecutionError(.providerError, ...)`
  - non-empty GraphQL `errors`: `AdapterExecutionError(.providerError, ...)`
  - malformed JSON or missing `data`: `AdapterExecutionError(.invalidOutput, ...)`
- No Codex-reference mapping is required because `codexAgentReferences` is
  empty.

---

## Task Breakdown

### 1. Confirm Upstream CLI Contract

**Status**: COMPLETED
**Write Scope**: none

**Tasks**:
- [x] Run the local apple-gateway checkout with `schema print` and `--help`.
- [x] Confirm `graphql --query <graphql>` is the apple-gateway 0.1.0 argument
  shape.
- [x] Capture the success and error envelope shape expected by the parser.
- [x] Record the observed commands and output summary in this plan's progress
  log.

**Deliverable**: A progress-log entry with the confirmed CLI shape and envelope
notes.

### 2. Add Built-in Catalog And Dispatch Registration

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- validation tests that already cover built-in add-on names

**Tasks**:
- [x] Add `riela/apple-notes-list` version `1` to the built-in catalog and
  validation acceptance path.
- [x] Register dispatch in `BuiltinWorkflowAddonResolver.execute`.
- [x] Reject unsupported versions deterministically.
- [x] Keep `addon.env` unsupported for this add-on.

**Deliverable**: The add-on resolves as a known built-in and reaches the Apple
Gateway executor.

### 3. Implement Apple Gateway Add-on Executor

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`

**Tasks**:
- [x] Add a focused executor extension for `BuiltinWorkflowAddonResolver`.
- [x] Merge supported `addon.config` and `addon.inputs`, allowing inputs to
  supply search query and cursor-like filters.
- [x] Use `first = 25` when not configured, and validate numeric limits as
  positive and bounded.
- [x] Validate include flags as booleans and default `includePlaintext`,
  `includeBodyHtml`, and `includeAttachments` to `false`.
- [x] Resolve `binaryPath` from literal config, `APPLE_GATEWAY_BIN`, then
  `PATH`.
- [x] Ensure executable selection is not sourced from `addon.inputs`,
  workflow input, or upstream payloads.
- [x] Run the subprocess without a shell, passing `graphql`, `--query`, and the
  rendered GraphQL query as separate arguments.
- [x] Drain stdout and stderr while the subprocess is running to avoid pipe
  buffer deadlocks on large GraphQL responses or diagnostics.
- [x] Honor `AdapterExecutionContext.deadline` by terminating the subprocess
  on timeout and returning `AdapterExecutionError(.timeout, ...)`.
- [x] Parse `{ "data": ..., "errors": ..., "extensions": ... }`.
- [x] Fail closed on malformed nested Notes GraphQL data by requiring
  `noteAccounts`, `noteFolders`, `notes.edges`, every `edges[].node`,
  `notes.pageInfo`, and `notes.totalCount`.
- [x] Publish structured output under `appleNotes` with `accounts`, `folders`,
  `notes`, `pageInfo`, `totalCount`, and optional `requestId`.
- [x] Attach bounded diagnostics and resolved binary provenance without leaking
  secrets into node output.
- [x] Pass only a minimal allowlisted child environment to `apple-gateway`.
- [x] Keep the new Swift file under 1000 lines.

**Deliverable**: A deterministic `riela/apple-notes-list` executor matching the
accepted design.

### 4. Add Fake Executable Unit Tests

**Status**: COMPLETED
**Write Scope**:
- `Tests/RielaAddonsTests/AppleGatewayAddonTests.swift`
- test-only helpers or fixtures under the same test target as needed

**Tasks**:
- [x] Introduce a small process-runner test hook only if direct fake executable
  scripts are insufficient.
- [x] Create fake `apple-gateway` scripts in per-test temporary directories,
  not committed fixtures.
- [x] Verify argument construction records `graphql --query <query>`.
- [x] Verify binary resolution precedence: config path over env path over
  `PATH`.
- [x] Verify workflow input, upstream payloads, and `addon.inputs` cannot
  override executable resolution.
- [x] Verify secret-like runtime environment variables are not forwarded to the
  fake executable.
- [x] Verify successful GraphQL envelope parsing.
- [x] Verify GraphQL `errors` maps to `.providerError`.
- [x] Verify non-zero exit maps to `.providerError`.
- [x] Verify malformed JSON or missing `data` maps to `.invalidOutput`.
- [x] Verify missing or non-executable binary maps to `.policyBlocked`.
- [x] Verify large stdout and stderr output is drained before process exit.
- [x] Verify a fake executable that sleeps past a short deadline maps to
  `.timeout`.
- [x] Verify tests do not read live Apple Notes or require automation
  permission.

**Deliverable**: Focused unit coverage for the new add-on behavior.

### 5. Add Example Workflow Bundle

**Status**: COMPLETED
**Write Scope**:
- `examples/apple-notes-list/workflow.json`
- `examples/apple-notes-list/nodes/node-workflow-output.json`
- `examples/apple-notes-list/README.md`
- `examples/README.md` only if the repository's example index requires it

**Tasks**:
- [x] Model the workflow shape on `examples/note-quick-memo`.
- [x] Add a worker node using `riela/apple-notes-list` and an output/display
  node.
- [x] Keep workflow validation offline: no live `apple-gateway` invocation at
  validate time.
- [x] Document installing or building `apple-gateway` outside this repository.
- [x] Document Notes permission request:
  `apple-gateway permissions request --domain notes`.
- [x] Document permission status check:
  `apple-gateway permissions status --json`.
- [x] Document `binaryPath` and `APPLE_GATEWAY_BIN` configuration.
- [x] Mention local path examples only in README, never committed Swift source.

**Deliverable**: A valid example bundle and README for local operator setup.

### 6. Refresh Design/Docs If Implementation Diverges

**Status**: COMPLETED
**Write Scope**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`

**Tasks**:
- [x] Update design docs only for intentional implementation divergences or
  newly confirmed upstream envelope details.
- [x] Do not reopen product/user QA unless implementation discovers a
  product-level decision.
- [x] Keep design docs aligned with the concrete default `first = 25`.

**Deliverable**: Design docs remain accurate after implementation.

### 7. Verification And Safety Audit

**Status**: COMPLETED
**Write Scope**: none, except progress-log updates

**Tasks**:
- [x] Run `swift test --filter AppleGateway`.
- [x] Run `swift build`.
- [x] Run `swift run riela workflow validate examples/apple-notes-list` or the
  repository-standard equivalent if the local binary path differs.
- [x] Run `git status --short`.
- [x] Confirm pre-existing dirty files
  `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift` were not
  modified by this implementation.
- [x] Confirm no committed source contains a hardcoded user-local
  apple-gateway binary path.

**Deliverable**: Verification command results recorded in the progress log.

---

## Dependencies

| Task | Depends On | Status |
| ---- | ---------- | ------ |
| Confirm upstream CLI contract | Accepted Step 3 design | Completed |
| Catalog and dispatch registration | Accepted Step 3 design | Completed |
| Add-on executor | Upstream CLI contract; dispatch registration | Completed |
| Fake executable unit tests | Add-on executor public/testable surface | Completed |
| Example workflow bundle | Built-in catalog registration | Completed |
| Design/doc refresh | Implementation decisions | Completed |
| Verification and safety audit | All implementation tasks | Completed |

## Parallelizable Tasks

| Task | Can Run In Parallel With | Reason |
| ---- | ------------------------ | ------ |
| Confirm upstream CLI contract | Example README drafting | Read-only external inspection and docs-only example work have disjoint write scopes |
| Catalog and dispatch registration | Initial example workflow files | Source registration and example bundle paths are disjoint |
| Fake executable test scaffolding | Example workflow README | Test target and example docs are disjoint |

Do not parallelize executor implementation with tests that edit the same
private helper names or test hooks; coordinate those changes in one sequence.
Do not parallelize any task with design-doc refresh if both are editing the same
accepted design files.

## Verification

Required commands:

```sh
swift test --filter AppleGateway
swift build
swift run riela workflow validate apple-notes-list --workflow-definition-dir examples
git status --short
rg -n "/Users/.+apple-gateway|APPLE_GATEWAY_BIN|riela/apple-notes-list|AdapterExecutionError|first" Sources Tests examples design-docs impl-plans
```

Optional non-Notes smoke commands against the local apple-gateway checkout:

```sh
<apple-gateway-checkout>/.build/debug/apple-gateway --help
<apple-gateway-checkout>/.build/debug/apple-gateway schema print
<apple-gateway-checkout>/.build/debug/apple-gateway permissions status --json
```

## Completion Criteria

- [x] `riela/apple-notes-list` is registered and passes node add-on validation.
- [x] The executor invokes only the external `apple-gateway` binary as a
  subprocess.
- [x] Binary resolution order is literal config `binaryPath`,
  `APPLE_GATEWAY_BIN`, then `PATH`.
- [x] `binaryPath` is not sourced from `addon.inputs`, workflow input, or
  upstream payloads.
- [x] The `apple-gateway` subprocess receives a minimal allowlisted
  environment instead of the full runtime environment.
- [x] Output is structured under `appleNotes`.
- [x] Malformed nested Apple Notes GraphQL data maps to `.invalidOutput`
  instead of publishing empty or partial success.
- [x] Error cases map to the accepted `AdapterExecutionError` categories.
- [x] stdout and stderr are drained while `apple-gateway` is running.
- [x] `AdapterExecutionContext.deadline` is enforced for the subprocess and
  timeout failures map to `.timeout`.
- [x] Unit tests pass with fake executables and no live Notes access.
- [x] `swift build` passes.
- [x] `examples/apple-notes-list` validates.
- [x] README documents installation, permissions, and binary configuration.
- [x] No unrelated dirty files are modified.

## Progress Log Expectations

Each implementation session must append:

- timestamp and actor
- tasks completed
- tasks in progress
- blockers or decisions
- verification commands run with pass/fail result
- files changed intentionally

### Session: 2026-07-07

**Tasks Completed**: Created implementation plan from accepted Step 3 design.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: Step 3 accepted the design with only low findings. This plan fixes
the implementation default for `first` at `25` and records explicit
`AdapterExecutionError` category mapping before coding starts.

### Session: 2026-07-07 Step 6 Implementation

**Tasks Completed**: Confirmed local `apple-gateway` CLI shape with `--help`,
`graphql --help`, `schema print`, and a non-Notes permission GraphQL query.
Implemented `riela/apple-notes-list`, catalog registration, dispatch, fake
executable tests, example workflow bundle, README, and gateway built-in docs.
Updated completion criteria to verified.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: Runtime tests live in `Tests/RielaCLITests` because
`BuiltinWorkflowAddonResolver` belongs to the `RielaCLI` target; catalog
contract coverage remains in `Tests/RielaAddonsTests`. Validation command uses
`swift run riela workflow validate apple-notes-list --workflow-definition-dir
examples`.
**Verification**:
- PASS `<apple-gateway-checkout>/.build/debug/apple-gateway --help`
- PASS `<apple-gateway-checkout>/.build/debug/apple-gateway graphql --help`
- PASS `<apple-gateway-checkout>/.build/debug/apple-gateway schema print`
- PASS `<apple-gateway-checkout>/.build/debug/apple-gateway graphql --query '{ permissions { notesAutomation } }'`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-notes-list --workflow-definition-dir examples`
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` with only two pre-existing warnings.
- PASS `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`; no committed user-local apple-gateway binary path is present.
- PASS `git status --short`; pre-existing timeline files remain dirty and unrelated.
**Files Changed Intentionally**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`
- `Tests/RielaCLITests/AppleGatewayAddonTests.swift`
- `examples/apple-notes-list/workflow.json`
- `examples/apple-notes-list/nodes/node-workflow-output.json`
- `examples/apple-notes-list/README.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `impl-plans/active/apple-notes-list-addon.md`

### Session: 2026-07-07 Step 6 Revision After Self-Review

**Tasks Completed**: Addressed the mid-severity review finding in
`AppleGatewayProcessRunner` by draining stdout and stderr on background queues
while `apple-gateway` is running. Added a fake-executable regression test that
emits large stderr and large valid stdout before exiting, proving the runner no
longer waits for process exit before reading pipe data.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: The pipe-drain helper is a private locked reference type marked
`@unchecked Sendable`; its shared data is protected by `NSLock` and synchronized
with a `DispatchGroup`.
**Verification**:
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-notes-list --workflow-definition-dir examples`
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` with only two pre-existing warnings.
- PASS `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`; no committed user-local apple-gateway binary path is present.
- PASS `git status --short`; pre-existing timeline files remain dirty and unrelated.
**Files Changed Intentionally**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- `Tests/RielaCLITests/AppleGatewayAddonTests.swift`
- `impl-plans/active/apple-notes-list-addon.md`

### Session: 2026-07-07 Step 6 Revision After Step 7 Review

**Tasks Completed**: Addressed the Step 7 mid-severity deadline finding by
threading `AdapterExecutionContext` through `executeAppleNotesList` into
`AppleGatewayProcessRunner`. The runner now waits only until
`context.deadline`, terminates the `apple-gateway` subprocess on timeout,
escalates to `SIGKILL` if needed, drains process pipes, and maps the failure to
`AdapterExecutionError(.timeout, ...)`. Added a fake-executable regression test
that sleeps past a short deadline and verifies the add-on returns promptly with
`.timeout`.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: Kept the process-runner behavior local to the Apple Gateway
bridge rather than introducing a broader abstraction; this keeps the revision
limited to the reviewed add-on path while preserving the existing large-output
pipe-drain fix.
**Verification**:
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-notes-list --workflow-definition-dir examples`
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` with only two pre-existing warnings.
- PASS `rg -n "/Users/.+apple-gateway|APPLE_GATEWAY_BIN|riela/apple-notes-list|AdapterExecutionError|first" Sources Tests examples design-docs impl-plans`; output is noisy for `first` and `AdapterExecutionError`, with no committed user-local apple-gateway binary path present.
- PASS `git status --short`; pre-existing timeline files remain dirty and unrelated.
**Files Changed Intentionally**:
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- `Tests/RielaCLITests/AppleGatewayAddonTests.swift`
- `impl-plans/active/apple-notes-list-addon.md`

### Session: 2026-07-07 Step 6 Revision After Adversarial Review

**Tasks Completed**: Addressed the two high-severity adversarial findings.
Executable resolution now reads `binaryPath` only as a literal
`addon.config.binaryPath`, then falls back to `APPLE_GATEWAY_BIN`, then `PATH`;
workflow input, upstream payloads, and `addon.inputs` no longer participate in
executable selection. The `apple-gateway` subprocess now receives only a
minimal allowlisted environment (`HOME`, locale keys, `LOGNAME`, `PATH`,
`TMPDIR`, `USER`, and `__CF_USER_TEXT_ENCODING`) instead of the full runtime
environment. Added fake-executable regressions for both the payload-driven
binary override path and secret-like environment stripping.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: Kept query filters templatable through the existing config/input
path, but made executable selection static and non-templated. Kept
`APPLE_GATEWAY_BIN` available only to the resolver; it is not forwarded to the
child process after resolution.
**Verification**:
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`; 10 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-notes-list --workflow-definition-dir examples`; `valid: true`.
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`; only two pre-existing warnings in `Sources/RielaCLI/RielaArgumentParserHelpers.swift` and `Sources/RielaCLI/WorkflowPackageParityCommands.swift`.
- PASS `rg -n "/Users/.+apple-gateway" Sources Tests examples design-docs impl-plans`; no committed user-local apple-gateway binary path is present.
- PASS `git status --short`; pre-existing timeline files remain dirty and unrelated.
**Files Changed Intentionally**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- `Tests/RielaCLITests/AppleGatewayAddonTests.swift`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
- `impl-plans/active/apple-notes-list-addon.md`

### Session: 2026-07-07 Step 6 Revision After Nested Envelope Review

**Tasks Completed**: Addressed the latest mid-severity adversarial finding in
GraphQL envelope parsing. The Apple Notes parser now rejects malformed nested
Notes data instead of synthesizing empty defaults or dropping malformed edges.
It requires `noteAccounts` and `noteFolders` arrays, a `notes` connection
object, `notes.edges` as an array, every edge as an object containing an object
`node`, an object `notes.pageInfo`, and numeric `notes.totalCount`. Added
fake-executable regressions proving malformed `notes.edges` and missing edge
nodes fail with `AdapterExecutionError(.invalidOutput, ...)`.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: Kept the strict validation local to the Apple Gateway response
mapping and preserved the upstream raw GraphQL data in successful outputs.
**Verification**:
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`; 11 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-notes-list --workflow-definition-dir examples`; `valid: true`, diagnostics empty.
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`; only two pre-existing warnings in `Sources/RielaCLI/RielaArgumentParserHelpers.swift` and `Sources/RielaCLI/WorkflowPackageParityCommands.swift`.
**Files Changed Intentionally**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- `Tests/RielaCLITests/AppleGatewayAddonTests.swift`
- `impl-plans/active/apple-notes-list-addon.md`

## Related Plans

- **Depends On**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- **Depends On**:
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
