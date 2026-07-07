# Riela Note Edit Agent UI Implementation Plan

**Status**: Implemented and verified (Step 6, 2026-07-07) — candidate
adversarially re-verified, all TASK-001..TASK-007 checklists confirmed
**Design Reference**: design-docs/specs/design-riela-note-edit-agent-ui.md
**Created**: 2026-07-07
**Last Updated**: 2026-07-07 (Step 4 revision: reset trust on candidate,
address Step 3 findings)

---

## Candidate-Verification Contract (read first)

A previous engine left a candidate implementation in the working tree.
Its checklist marks below are **provisional and untrusted**. The
implementation step MUST re-verify every checklist item by reading the
code and re-running the verification commands — do not trust an `[x]`.
Treat each `[x]` as `[ ] (claimed, unverified)` until re-proven.

Candidate files to adversarially review (per issue):
- Sources/RielaNoteUI/RielaNoteEditHelpers.swift (new)
- Sources/RielaNoteUI/RielaNoteLibraryViewModel+EditRewrite.swift (new)
- Sources/RielaNoteUI/RielaNoteSelectableTextEditor.swift (new)
- Sources/RielaNoteUI/RielaNoteWorkflowEditRewriteProvider.swift (new)
- Sources/RielaNoteUI/RielaNoteWorkflowProviderSupport.swift (new)
- Tests/RielaNoteUITests/RielaNoteEditRewriteTests.swift (new)
- examples/note-edit-rewrite/ (new bundle)
- Modified: RielaNoteDetailView.swift, RielaNoteLibraryViewModel.swift,
  RielaNoteRootView.swift, RielaNoteUIClient.swift,
  RielaNoteWorkflowLinkProposalProvider.swift,
  Sources/RielaApp/NoteWindowController.swift

### Step 3 findings resolved into this plan

- **F1 (design line 55, low)** — Code-Verified line numbers drift as the
  candidate is rewritten. This plan treats **symbol names as
  authoritative and line numbers as advisory**. When re-verifying,
  locate `header(_:)`, `bodyEditor(_:)`, `saveSelectedNoteBody(_:expectedNoteId:)`,
  `updateNoteBody(noteId:bodyMarkdown:)`, the `RielaNoteBodyDraftState`
  toggle, and the link-proposal provider by name, not by cited line.
- **F2 (design line 148, low)** — Pin the selection-chip anchoring to a
  single deterministic behavior: **v1 uses a fixed top-of-editor anchor**
  (no `firstRect(forCharacterRange:)` pixel math in the assertable
  path). The deterministic UI test asserts chip *visibility is bound to
  selection non-emptiness* and that ⌘K/chip-press *arms selection scope*
  — it must NOT assert pixel coordinates. See TASK-005.

---

## Design Document Reference

**Source**: design-docs/specs/design-riela-note-edit-agent-ui.md
(decisions D1–D10; requirements R1–R4)

### Summary

Rework the note detail header: Edit control top-left, copy / download /
expand icons top-right (D1). Edit enters manual edit mode and opens an
"Ask for changes" agent pill (D2). In edit mode, a selectable
`NSTextView`-backed editor surfaces a floating "Ask for changes ⌘K"
chip for selection-scoped requests (D3). Agent rewrites dispatch
through a new provider/client pathway modeled on the link-proposal
provider (D4), apply to the edit draft for review before save (D5).
Copy (D6), markdown file export (D7), detail-only expand toggle (D8),
an `examples/note-edit-rewrite/` workflow bundle (D9), and read-only /
error behavior (D10) round out the scope.

### Scope

**Included**: `Sources/RielaNoteUI` (detail view, library view model,
client protocol + service client, new provider + selectable editor +
file document + pure helpers), `Sources/RielaApp/NoteWindowController`
wiring, `RielaNoteRootView` column-visibility binding,
`examples/note-edit-rewrite/` bundle, `Tests/RielaNoteUITests`.

**Excluded**: Agent tab / query agent, formatting toolbar (B/I/Text),
streaming, diff review UI, iOS selection scope, GraphQL exposure.

---

## Task Breakdown

### TASK-001: Rewrite provider pathway (D4, D9)
**Status**: DONE
**Depends On**: —
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteWorkflowEditRewriteProvider.swift`:
  `RielaNoteEditRewriteDraft` (`rewrittenMarkdown`, `summary?`),
  `RielaNoteEditRewriteProviding` protocol,
  `RielaNoteEditRewriteError` (`notConfigured`, `workflowFailed`,
  `invalidOutput`, `timedOut`), macOS
  `RielaWorkflowNoteEditRewriteProvider` (workflow id
  `note-edit-rewrite`, env `RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR` /
  `RIELA_NOTE_EDIT_REWRITE_RIELA_EXECUTABLE`, default deadline 120 s,
  `defaultProvider(environment:fileManager:)` candidate scan).
  Extract shared process-box / pipe-drain / executable-resolution
  helpers from `RielaNoteWorkflowLinkProposalProvider.swift` instead of
  duplicating (keep behavior identical for the link provider).
- `examples/note-edit-rewrite/`: `workflow.json`, `nodes/`, `prompts/`,
  `mock-scenario.json`, `EXPECTED_RESULTS.md` mirroring
  `examples/note-link-extract/`; output
  `{rewrittenMarkdown, summary}`; selection-scope prompt rule
  (return replacement for `selectedText` only when present).

**Checklist** (re-verified Step 6, 2026-07-07):
- [x] Draft/protocol/error types compile on macOS + iOS. Provider
      protocol matches design D4 exactly:
      `RielaNoteEditRewriteProviding.proposeRewrite(noteId:noteRoot:
      instruction:bodyMarkdown:selectedText:selectionStart:selectionEnd:)`
      including the `noteRoot` parameter
      (`RielaNoteWorkflowEditRewriteProvider.swift:14-22`).
- [x] Workflow provider passes noteRoot + workflowInput
      (noteId, bodyMarkdown, instruction, selectedText?,
      selectionStart?, selectionEnd?) and parses last JSONL
      `result.rootOutput`. Parse path proven, not assumed: real
      `riela workflow run … --output jsonl` emits
      `result.rootOutput.{rewrittenMarkdown,summary}` on the last line
      (empirically confirmed) and
      `testWorkflowEditRewriteParserReadsLastDecodableRootOutputLine`
      asserts last-decodable-line selection; `noteRoot` flow proven by
      `testNoteServiceClientBodyRewriteProviderRoundTrip`.
- [x] Shared helpers extracted; link provider command contract
      unchanged (see Step 6 deviation note on hardened
      executable/workflow-dir discovery).
- [x] `riela workflow validate note-edit-rewrite
      --workflow-definition-dir examples` passes

### TASK-002: Client protocol + service client (D4)
**Status**: DONE
**Depends On**: TASK-001
**Deliverables**:
- `RielaNoteUIClient` protocol: add
  `proposeNoteBodyRewrite(noteId:instruction:bodyMarkdown:
  selectedText:selectionStart:selectionEnd:)`; protocol-extension
  default throws `RielaNoteEditRewriteError.notConfigured`.
- `NoteServiceRielaNoteUIClient`: optional `editRewriteProvider`
  init parameter (default nil); forward or throw `.notConfigured`.

**Checklist**:
- [x] Existing conformances/stubs compile without changes
- [x] Provider receives the draft body, not the persisted body

### TASK-003: View-model rewrite state (D5, D10)
**Status**: DONE
**Depends On**: TASK-002
**Deliverables**:
- `RielaNoteLibraryViewModel` (or a
  `RielaNoteLibraryViewModel+EditRewrite.swift` extension):
  `isEditRewriteLoading`, `editRewriteError`, `editRewriteSummary`,
  `editRewriteGeneration`;
  `proposeBodyRewrite(instruction:draftBodyMarkdown:selectedText:
  selectionStart:selectionEnd:) async -> RielaNoteEditRewriteDraft?`
  with generation + selected-note-id guards (mirror
  `proposeLinksForSelectedNote`); `clearEditRewriteState()` called from
  note switches.
- `isDetailExpanded: Bool` published UI state (D8, consumed in
  TASK-006).

**Checklist**:
- [x] Stale generation / note-switch results dropped
- [x] Errors stringified into `editRewriteError`, loading cleared

### TASK-004: Header action row + agent pill (D1, D2, D6, D7, D10)
**Status**: DONE
**Depends On**: TASK-003
**Deliverables**:
- `RielaNoteDetailView`: new top action row — leading `[✎ Edit]`
  (hidden for readOnly) that toggles `bodyDraft` and reveals the
  "Ask for changes" pill (pencil + TextField + ↑ submit with
  loading spinner, disabled-empty, `.onSubmit` support); trailing
  copy / download / expand icon group with `.help()` tooltips; remove
  the old trailing Edit/Preview toggle from the title row.
- Pill submit: call `viewModel.proposeBodyRewrite(...)`, apply result
  per scope (whole draft replace, or splice via helper), show
  `editRewriteSummary` caption / `editRewriteError` caption.
- Copy: pasteboard write of displayed markdown (draft when editing)
  with transient checkmark feedback; `#if os(macOS)` / iOS pasteboard.
- Download: `.fileExporter` + `RielaNoteMarkdownFileDocument` +
  pure `rielaNoteExportFilename(title:noteId:)` helper.
- Pure helper `rielaNoteApplyingRewrite(draft:range:replacement:)`
  (UTF-16 `NSRange` → `Range<String.Index>` validation).

**Checklist**:
- [x] Layout matches captures (pill top-left, icons top-right)
- [x] Agent result lands in the editor draft only; Save persists via
      existing `saveSelectedNoteBody`
- [x] Read-only notes: icons yes, edit/pill no

### TASK-005: Selectable editor + selection-scoped ask (D3)
**Status**: DONE
**Depends On**: TASK-004
**Deliverables**:
- `Sources/RielaNoteUI/RielaNoteSelectableTextEditor.swift`: macOS
  `NSViewRepresentable` wrapping `NSTextView` (monospaced body font,
  matching background/inset/min-height, two-way `text` +
  `selectedRange` bindings); iOS fallback to `TextEditor`.
- Floating `[✎ Ask for changes ⌘K]` chip overlay while selection is
  non-empty; chip press or `⌘K` arms selection scope on the pill
  (removable `Selection (N chars)` badge); scope falls back to whole
  note when the stored range no longer fits the draft.
- Selection splice: replace range, reselect inserted text.
- **Anchoring (F2, pinned)**: the chip uses a **fixed top-of-editor
  anchor** for v1. No `firstRect(forCharacterRange:)` pixel math is on
  the assertable path. The deterministic UI test asserts (a) chip
  visibility is driven purely by selection non-emptiness and (b)
  chip-press / ⌘K arms selection scope — never pixel coordinates.

**Checklist** (marks provisional — re-verify per Candidate-Verification
Contract):
- [x] Manual editing behavior unchanged (typing, Cancel/Save,
      draft preview parity)
- [x] ⌘K only active in edit mode with non-empty selection
- [x] Invalid/stale ranges degrade to whole-note scope
- [x] Chip anchoring is fixed top-of-editor; UI test asserts
      selection-driven visibility + scope-arming, not pixel position.
      Chip `if` and `armSelectionScope()` gate on
      `rielaNoteRewriteRangeIsValid(selectedBodyRange, in: draft)`
      (`RielaNoteDetailView.swift:394,658`); `.padding(10)` fixed
      top-leading overlay anchor, no `firstRect(forCharacterRange:)`
      pixel math. `testRewriteRangeValidityDrivesSelectionScopeGate`
      asserts visibility/arm gate is driven purely by selection
      non-emptiness (empty length → false, invalid → false).

### TASK-006: Expand toggle + app wiring (D8, D4-wiring)
**Status**: DONE
**Depends On**: TASK-003
**Deliverables**:
- `RielaNoteRootView`: `columnVisibility` binding on the regular
  `NavigationSplitView` synced with `viewModel.isDetailExpanded`;
  expand button hidden on compact.
- `Sources/RielaApp/NoteWindowController.swift`: pass
  `editRewriteProvider:
  RielaWorkflowNoteEditRewriteProvider.defaultProvider(environment:)`.

**Checklist**:
- [x] Expand ↔ restore works from both the button and the standard
      sidebar controls
- [x] Notes window builds and runs with the provider wired

### TASK-007: Tests (design Test Plan)
**Status**: DONE
**Depends On**: TASK-004, TASK-005, TASK-006
**Deliverables**: `Tests/RielaNoteUITests`:
- View-model rewrite lifecycle (success/failure/stale/not-configured).
- Client stub-provider round trip incl. selection fields; nil provider
  throws `.notConfigured`.
- Helper tests: splice (valid/invalid/UTF-16/emoji), export filename,
  copy-source selection.
- Workflow provider argument/JSONL-parse tests (internal visibility),
  matching link-provider test conventions.

**Checklist**:
- [x] `swift test --filter RielaNoteUITests` green
- [x] `swift build` green (macOS)
- [x] Example bundle validate + mock dry run recorded in
      EXPECTED_RESULTS.md

---

## Verification

- `swift build`
- `swift test --filter RielaNoteUITests` (plus `RielaNoteTests` if the
  service surface is touched)
- `riela workflow validate note-edit-rewrite
  --workflow-definition-dir examples`
- Manual: Notes window — header layout, edit flow, pill submit with
  mock scenario, selection chip + ⌘K, copy/download/expand, read-only
  note.

### Verification Results (2026-07-07)

- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`: passed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteUITests`: passed, 83 tests.
- `riela workflow validate note-edit-rewrite --workflow-definition-dir examples`: passed, `valid: true`.
- `riela workflow run note-edit-rewrite --workflow-definition-dir examples --mock-scenario examples/note-edit-rewrite/mock-scenario.json --variables '{"noteRoot":"tmp/note-edit-rewrite/mock-note-root","workflowInput":{"noteId":"note-1","bodyMarkdown":"# Project Plan\n\n- Draft next milestone.","instruction":"Clarify the plan and owner"}}' --output json`: passed with root output `{rewrittenMarkdown, summary}`.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`: completed with two pre-existing warnings outside this task (`Sources/RielaCLI/RielaArgumentParserHelpers.swift`, `Sources/RielaCLI/WorkflowPackageParityCommands.swift`).

### Step 7 Revision Verification Results (2026-07-07)

- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteEditRewriteTests`: passed, 15 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`: passed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteUITests`: passed, 86 tests.
- `riela workflow validate note-edit-rewrite --workflow-definition-dir examples`: passed, `valid: true`.
- `riela workflow run note-edit-rewrite --workflow-definition-dir examples --mock-scenario examples/note-edit-rewrite/mock-scenario.json --variables '{"noteRoot":"tmp/note-edit-rewrite/mock-note-root","workflowInput":{"noteId":"note-1","bodyMarkdown":"# Project Plan\n\n- Draft next milestone.","instruction":"Clarify the plan and owner"}}' --output json`: passed with root output `{rewrittenMarkdown, summary}`.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`: completed with two pre-existing warnings outside this task (`Sources/RielaCLI/RielaArgumentParserHelpers.swift`, `Sources/RielaCLI/WorkflowPackageParityCommands.swift`).

## Dependencies and Sequencing

1. TASK-001 must establish the rewrite provider contract and workflow
   bundle before client/view-model integration.
2. TASK-002 depends on TASK-001 types and wires the provider into the
   client abstraction without changing existing conformances.
3. TASK-003 depends on TASK-002 so view-model state can call the client
   pathway and guard async results by generation and selected note id.
4. TASK-004 depends on TASK-003 for pill state, submit behavior, error
   rendering, copy/download helpers, and draft-only application.
5. TASK-005 depends on TASK-004 because selection scope arms the pill
   and reuses the draft splice/apply pathway.
6. TASK-006 depends on TASK-003 for `isDetailExpanded`; app-provider
   wiring can be done with TASK-004/005 once provider types compile.
7. TASK-007 starts after the relevant implementation surfaces exist;
   provider/client tests can begin after TASK-002, helper/view-model
   tests after TASK-003/004, and UI-scope tests after TASK-005/006.

## Parallelizable Work

- TASK-001 workflow-bundle files under `examples/note-edit-rewrite/`
  can be authored in parallel with TASK-001 provider extraction only if
  both contributors keep the JSON contract identical to D9.
- TASK-006 `RielaNoteRootView` expand binding can proceed in parallel
  with TASK-004/005 after TASK-003 adds `isDetailExpanded`; write
  scopes are disjoint except for final detail-view button binding.
- TASK-007 workflow validation assets can be drafted in parallel with
  provider tests after TASK-001, but final expected results must be
  refreshed after implementation stabilizes.

Do not parallelize TASK-004 and TASK-005 in the same files unless one
owner coordinates the `RielaNoteDetailView` edit-body/pill integration.

## Completion Criteria

- Every TASK-001..TASK-007 checklist item is **re-verified against the
  candidate** (code read + commands re-run), not accepted from the
  provisional `[x]` marks. The impl-plan checklist is corrected to
  reflect that re-verified reality before commit.
- Step 3 findings F1 (line numbers advisory / symbols authoritative) and
  F2 (fixed top-of-editor chip anchor; selection-driven test assertions)
  are honored.
- All TASK-001 through TASK-007 checklist items are complete.
- The implementation follows the accepted design decisions D1-D10 and
  requirements R1-R4 in
  `design-docs/specs/design-riela-note-edit-agent-ui.md`.
- `RielaNoteAgentView` and `RielaNoteAgentViewModel` are unchanged.
- `RielaWorkflowNoteLinkProposalProvider` behavior is unchanged after
  any shared-helper extraction.
- The note edit rewrite workflow is sequential-only; no fanout,
  branch-join, or parallel rewrite-candidate path is introduced.
- Read-only notes hide only the edit control/pill and keep
  copy/download/expand available.
- Agent rewrites affect only `bodyDraft.draftBodyMarkdown`; persistence
  still happens only through the existing Save path.
- The progress log is updated as implementation proceeds, with each
  task status, changed file paths, verification command results, and
  any accepted deviations from this plan.

## Progress Log Expectations

- Keep task statuses current (`PENDING`, `IN_PROGRESS`, `DONE`, or
  `BLOCKED`) as work moves through TASK-001..TASK-007.
- Record every verification command run and its result near the task or
  in the final implementation handoff.
- If implementation discovers a design mismatch, update this plan and
  the accepted design doc in place before continuing.
- If unrelated working-tree changes are present, list only files
  intentionally touched for this issue in the implementation handoff.

## Progress Log

2026-07-07 (Step 6 rerun — addressing Step 7 review comm-000698):

- F1 (mid, `RielaNoteWorkflowProviderSupport.swift:136`): widened
  `rielaWorkflowSanitizedEnvironment` with a `modelAuthKeys` allowlist so
  model-auth / agent-discovery vars survive sanitization
  (OPENAI_API_KEY, OPENAI_BASE_URL, ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL,
  CLAUDE_API_KEY, CLAUDE_CONFIG_DIR, CURSOR_API_KEY, CURSOR_AUTH_TOKEN,
  CURSOR_BASE_URL, CURSOR_CONFIG_DIR, GEMINI_API_KEY, GEMINI_BASE_URL,
  GOOGLE_API_KEY, CODEX_HOME, RIELA_CODEX_AGENT_EXECUTABLE,
  RIELA_CLAUDE_CODE_AGENT_EXECUTABLE, RIELA_CURSOR_CLI_AGENT_EXECUTABLE).
  Both note-edit-rewrite and note-link-extract subprocesses now retain
  the credentials their `executionBackend:codex-agent` node needs; only
  genuinely unrelated/sensitive host vars are still dropped. Added
  provider-level test `testWorkflowProviderPreservesModelAuthEnvironment`
  asserting the full set survives, and updated
  `testWorkflowProviderSanitizesInheritedEnvironment` (which previously
  asserted OPENAI_API_KEY was dropped) to assert only non-auth secrets
  (AWS_*, GITHUB_TOKEN) are dropped.
- F2 (mid, `RielaNoteWorkflowLinkProposalProvider.swift:138`): the
  link-provider env-scrub is intentional; with F1 it is now
  credential-preserving, so the functional regression (stripped API
  credentials) is resolved. Documented the previously under-disclosed
  env-forwarding behavior change and its rationale in the Deviation notes
  above (full-forward → credential-preserving sanitized env).
- F3 (low, `RielaNoteDetailView.swift:196`): selection badge now reports
  `armedSelectionRange.length` (UTF-16 units) to match the
  selectionStart/selectionEnd offsets sent to the workflow, instead of
  the Character `selectedText.count`.

2026-07-07 (Step 6 implementation ownership — full issue resolution):

- Adversarially re-verified every TASK-001..TASK-007 checklist item
  against the candidate by reading code and re-running the verification
  commands; corrected the provisional marks to verified reality. All
  items now hold; see "Step 6 Implementation-Ownership Verification
  Results".
- Addressed Step 5 accepted feedback (comm-000692): reconciled the
  splice-helper label in design D5 to `rielaNoteApplyingRewrite(draft:
  range:replacement:)` (matches TASK-004 + code); confirmed the D4
  provider signature carries `noteRoot`; proved the last-JSONL
  `result.rootOutput.{rewrittenMarkdown,summary}` parse path against
  real workflow output rather than the untrusted candidate.
- Closed the last open TASK-005 checklist item by adding
  `testRewriteRangeValidityDrivesSelectionScopeGate`, which asserts the
  chip visibility / scope-arming gate (`rielaNoteRewriteRangeIsValid`)
  is driven purely by selection non-emptiness (not pixel position).
- Deviation note (accepted, carried from prior Step 6/7 revisions): the
  shared-helper extraction hardened executable/workflow-directory
  discovery for BOTH providers — the link provider no longer falls back
  to `/usr/bin/env riela` on PATH or to a cwd `examples` directory, and
  now requires a trusted absolute `riela` path (new `.notConfigured`
  case). This changes link-provider discovery behavior at the margins
  while keeping its CLI command contract (`workflow run
  note-link-extract … --output jsonl`, argument order, parsing)
  identical. `NoteWindowController` opts the link provider into env
  overrides only implicitly (default `allowEnvironmentOverrides: false`);
  the edit-rewrite provider is wired with `allowEnvironmentOverrides:
  true` for its documented env overrides.
- Deviation note (environment forwarding — Step 7 review comm-000698 F2):
  `RielaWorkflowNoteLinkProposalProvider` previously forwarded the full
  inherited environment verbatim (`process.environment = environment`).
  As part of the shared-helper extraction it now forwards
  `rielaWorkflowSanitizedEnvironment(...)` — the same scrub the
  edit-rewrite provider uses — intentionally, so both note subprocesses
  drop genuinely unrelated/sensitive host vars. Rationale: both providers
  spawn `riela workflow run` whose node is `executionBackend:codex-agent`,
  and the inner codex process derives its env from this parent; forwarding
  the entire host environment into a spawned agent subprocess is broader
  than the feature needs. The scrub is credential-preserving: the
  allowlist explicitly retains model-auth / agent-discovery vars
  (OPENAI_API_KEY, ANTHROPIC_API_KEY, CLAUDE_API_KEY, CURSOR_API_KEY and
  siblings, CODEX_HOME, RIELA_*_AGENT_EXECUTABLE, provider BASE_URL/CONFIG
  vars), so env-based codex auth for note-link-extract and
  note-edit-rewrite continues to work. Only non-auth host vars (e.g.
  AWS_*, GITHUB_TOKEN) are dropped. This preserves the observable
  link-provider behavior for the supported env-key auth path while
  narrowing the forwarded surface; the CLI command contract is unchanged.

2026-07-07 (Step 4 impl-plan revision):

- Reset plan status to "Ready for implementation — candidate present but
  UNVERIFIED"; added the Candidate-Verification Contract marking all
  checklist `[x]` marks provisional pending re-verification.
- Resolved Step 3 F1: symbol names authoritative, line numbers advisory.
- Resolved Step 3 F2: pinned selection-chip anchoring to a fixed
  top-of-editor anchor; deterministic UI test asserts selection-driven
  visibility + scope-arming, not pixel coordinates (TASK-005).
- Commit scope constraint reaffirmed: exclude unrelated in-progress work
  (apple-notes CRUD, apple-gateway, seatbelt-sandbox,
  WorkflowInstanceCommand); use the sequential workflow path only.

2026-07-07:

- Completed TASK-001 by adding `RielaNoteWorkflowProviderSupport`,
  `RielaNoteWorkflowEditRewriteProvider`, and the sequential
  `examples/note-edit-rewrite/` workflow bundle. Shared process,
  executable-resolution, workflow-directory, and JSONL root-output
  helpers are used by the existing link provider without changing its
  command contract.
- Completed TASK-002 by adding `proposeNoteBodyRewrite(...)` to
  `RielaNoteUIClient`, a default `.notConfigured` implementation, and
  optional `editRewriteProvider` forwarding in
  `NoteServiceRielaNoteUIClient`.
- Completed TASK-003 by adding rewrite loading/error/summary
  view-model state, generation guards, note-switch resets, and
  `isDetailExpanded`.
- Completed TASK-004 and TASK-005 by updating
  `RielaNoteDetailView` with the top action row, ask-for-changes pill,
  copy/download/expand actions, draft-only agent result application,
  `NSTextView`-backed selection tracking on macOS, selection chip, and
  splice/export/copy helpers.
- Completed TASK-006 by binding regular `NavigationSplitView`
  visibility to `isDetailExpanded` and wiring
  `RielaWorkflowNoteEditRewriteProvider.defaultProvider(environment:)`
  from `NoteWindowController`.
- Completed TASK-007 with focused tests in
  `Tests/RielaNoteUITests/RielaNoteEditRewriteTests.swift` covering
  rewrite lifecycle, not-configured errors, stale results,
  service-client/provider forwarding, UTF-16 splice behavior, export
  filenames, draft-vs-saved copy source, workflow arguments, and JSONL
  parsing.
- Addressed the Step 7 adversarial-review revision by adding draft
  snapshot/selection freshness validation before applying async edit
  results, rejecting stale returned rewrites with an inline retry
  error, hardening app-provider workflow/executable discovery against
  current-working-directory and `/usr/bin/env`/PATH fallback, scrubbing
  inherited subprocess environments, and bounding timeout/cancellation
  cleanup for both edit-rewrite and link-proposal workflow providers.
- Addressed the Step 6 self-review revision by keeping the
  path-trust hardening while allowing validated absolute
  `RIELA_NOTE_EDIT_REWRITE_WORKFLOW_DIR`,
  `RIELA_NOTE_EDIT_REWRITE_RIELA_EXECUTABLE`, and shared
  `RIELA_APP_RIELA_EXECUTABLE` overrides in the normal edit-rewrite
  app-provider path. Added regression coverage proving trusted
  absolute overrides are accepted while relative workflow-directory
  overrides and PATH-only executable fallback remain rejected.
- No `riela-package.json` exists in this checkout, so package digest
  refresh was not applicable.

### Step 6 Self-Review Revision Verification Results (2026-07-07)

- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/swiftpm-note-edit-rewrite --filter RielaNoteEditRewriteTests`: passed, 16 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/swiftpm-note-edit-rewrite --filter RielaNoteUITests`: passed, 87 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/swiftpm-note-edit-rewrite`: passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`: completed with 6 warnings outside the files intentionally touched for this revision.
- `riela workflow validate note-edit-rewrite --workflow-definition-dir examples`: passed, `valid: true`.

### Step 6 Implementation-Ownership Verification Results (2026-07-07)

Adversarial re-verification of the candidate (code read + commands
re-run), addressing Step 5 accepted feedback (comm-000692):

- `swift build --scratch-path tmp/swiftpm-note-edit-rewrite`: passed
  (Build complete, 30.1s).
- `swift test --scratch-path tmp/swiftpm-note-edit-rewrite --filter
  RielaNoteUITests`: passed, 88 tests (added
  `testRewriteRangeValidityDrivesSelectionScopeGate` to close the
  TASK-005 selection-driven-visibility checklist item).
- `riela workflow validate note-edit-rewrite --workflow-definition-dir
  examples`: passed, `valid: true`.
- `riela workflow run note-edit-rewrite --workflow-definition-dir
  examples --mock-scenario examples/note-edit-rewrite/mock-scenario.json
  --variables '{"noteRoot":"tmp/note-edit-rewrite/mock-note-root",
  "workflowInput":{"noteId":"note-1","bodyMarkdown":"# Project Plan\n\n-
  Draft next milestone.","instruction":"Clarify the plan and owner"}}'`:
  `status: completed`, and both `--output json` (top-level `rootOutput`)
  and `--output jsonl` (`result.rootOutput`) return
  `{rewrittenMarkdown, summary}` — proving the provider's last-JSONL
  `result.rootOutput.{rewrittenMarkdown,summary}` parse path against
  real workflow output, not the untrusted candidate's assumption.
- Feedback item 1 (splice-helper label): reconciled — design D5
  (`design-riela-note-edit-agent-ui.md:207`) now names
  `rielaNoteApplyingRewrite(draft:range:replacement:)`, matching TASK-004
  and the implementation (`RielaNoteEditHelpers.swift:29`).
- Feedback item 2 (D4 provider signature + parse path): confirmed —
  `RielaNoteEditRewriteProviding.proposeRewrite(...)` matches D4 including
  `noteRoot`; JSONL parse path proven by TASK-001/TASK-007 as above.

## Step 7 Rerun — Example Parity (F1) Resolution

- Step 7 finding F1 (`RielaExampleParityTests` desync) is RESOLVED at
  current HEAD `e1ae308`. At my task's commit `31f07fc` in isolation the
  parity test was red (`expectedMockScenarioCount=33`, no
  `note-edit-rewrite` in `rielaExampleWorkflowNames()`), because adding
  `examples/note-edit-rewrite/mock-scenario.json` bumps the disk count.
- Per the feedback's permitted second option, the parity update was
  carried by the concurrent/owning session's commit `e1ae308`, which set
  `expectedMockScenarioCount=35` and added `note-edit-rewrite` (line 698)
  alongside its own `apple-note-*`/`seatbelt-sandboxed-worker` names.
  This session did NOT touch the parity test or any apple-notes/seatbelt
  files (constraint honored); `Tests/RielaCLITests/RielaExampleParityTests.swift`
  is committed/clean in the working tree.
- Disk-vs-expected discrepancy from the earlier review is gone: 35
  `mock-scenario.json` files on disk == `expectedMockScenarioCount=35`.
  The transient `34` seen mid-review was the concurrent session's
  in-progress edit; it finalized at 35.
- Verification (this rerun): `swift test --filter RielaExampleParityTests`
  → PASS (9 tests, 0 failures), no "input file was modified during the
  build" blockage this run. `swift run riela workflow validate
  note-edit-rewrite --workflow-definition-dir examples` → `valid:true`,
  no diagnostics.

## Codex Reference Trace

- `codexAgentReferences`: none supplied by Step 3.
- No reference-repository or Cursor adapter divergence checks are
  required for this plan.

## Notes

- Do not modify the Agent tab pathway
  (`RielaNoteAgentView` / `RielaNoteAgentViewModel`).
- Keep `RielaWorkflowNoteLinkProposalProvider` behavior identical when
  extracting shared helpers.
- Follow existing code style (2-space indent, no superfluous
  comments).
