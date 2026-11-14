# Riela Note Notebook Expansion Implementation Plan

**Status**: Implemented; `comm-001444` adversarial revisions addressed and verified
**Workflow mode**: `issue-resolution` — one feature / one work package; no fan-out
**Issue reference**: `codex-design-and-implement-review-loop-session-614`
(communications `comm-001401`, `comm-001402`, `comm-001403`, `comm-001404`,
`comm-001405`, `comm-001406`, `comm-001407`, `comm-001408`, `comm-001409`,
`comm-001410`, `comm-001412`, `comm-001413`, `comm-001414`, `comm-001415`,
`comm-001416`, Step 7 review `comm-001432`, and adversarial reviews
`comm-001437` and `comm-001444`; no GitHub
repository, number, or URL)
**Design references**:
- `design-docs/specs/design-riela-note-notebook-expand.md` (D1–D6)
- `design-docs/specs/design-riela-note.md`
- `design-docs/user-qa/qa-riela-note-notebook-expand-seed-format.md`
**Design review**: accepted by Step 3 in `comm-001415`; no findings or feedback
**Codex-agent references**: `/root/adversarial_swift_review`,
`/root/step6_adversarial_fixes`, `/root/step6_plan_evidence_fix`,
`/root/step7_adversarial_audit`, `/root/step6_security_fixes`, and
`/root/step6_agent_state_fix`. `executionBackend: codex-agent` is also an
execution backend choice, not a source-repository reference.
**Created**: 2026-07-21
**Last updated**: 2026-07-21

## Outcome and boundaries

Add **Expand with Agent** to notebook rows in both note navigation surfaces.
The first expansion of a source revision compacts its ordered notes through the
new `note-notebook-compact` workflow and caches the compact summary in the
source notebook's `metaJSON`. The action creates a seeded
`notebook-kind:agent-conversation` notebook, opens an explicit expansion-mode
agent session, persists every later question/answer turn, and atomically links
each generated turn to every source note with AI `source-citation` provenance.

Implementation must preserve these accepted boundaries:

- Full source-note bodies are valid only in the compaction request. Answer
  requests contain only the compact summary and current question.
- Provider absence fails with `.notConfigured` before cache, notebook, or note
  mutation on cache-hit and cache-miss paths.
- Cache writes preserve unrelated `metaJSON` and the source `updatedAt`; source
  `updatedAt` plus note count invalidate the cache, and cache publication uses
  an atomic expected-marker compare-and-set.
- `saveConversation` and `appendConversationTurn` remain the creation seams;
  conversation/note creation and all source links commit or roll back together.
- Active expansion turns have stable persistence keys. A retry never
  regenerates an answer or duplicates a note; source notes deleted after the
  session began are recorded in turn metadata while surviving links persist.
- General Note Agent retrieval, selection Q&A, edit rewrite, ingestion,
  historical expansion-session reopening, remote sync, and background
  precomputation are out of scope.
- Work stays on `feat/riela-note-agent-expand`; do not push to `origin/main`.

## Task breakdown

### TASK-001 — Service metadata and atomic relation primitives

**Status**: Done
**Depends on**: —
**Write scope**: `Sources/RielaNote/NoteModels.swift`,
`Sources/RielaNote/NoteService+Relations.swift`,
`Sources/RielaNote/NoteService+NotebookExpansion.swift`, and
`Tests/RielaNoteTests/NoteServiceNotebookExpansionTests.swift`

**Deliverables**:

- Add a focused notebook-derived-metadata mutation that validates JSON, merges
  the namespaced `rielaNote.notebookCompact` object without dropping siblings,
  and deliberately does not change the notebook's source `updatedAt`.
- Define the optional source-link input used by conversation persistence:
  ordered source-note ids, link kind, and provenance.
- Extend `saveConversation` with defaulted notebook metadata and source-link
  inputs, and extend `appendConversationTurn` with the same defaulted
  source-link input, preserving all existing call behavior.
- Extract one database-scoped link upsert rule reused by public `linkNotes` and
  both conversation paths. Validate all source ids before inserts and keep
  notebook/turn plus generated-note/source-note fanout in one transaction.
- Add service tests for invalid metadata, unrelated-key preservation,
  `updatedAt` preservation, `.ai`/`source-citation` visibility through
  `listLinks`, all-source fanout, and rollback on an injected link failure.

**Completion criteria**:

- Existing relation callers compile without changes because new inputs default
  to `nil`.
- A failed source validation or link write leaves no notebook, turn, or partial
  links; a successful write returns links for every source id with `.ai`
  provenance.
- Expansion follow-up retries are idempotent. Missing source tolerance remains
  opt-in for that active-session path and records deleted source ids in the
  generated note metadata.

### TASK-002 — `note-notebook-compact` workflow bundle

**Status**: Done
**Depends on**: —
**Write scope**: `examples/note-notebook-compact/`

**Deliverables**:

- Add `workflow.json`, operation-aware worker node definitions, prompt files,
  output projection, deterministic mock scenario files, and
  `EXPECTED_RESULTS.md` under `examples/note-notebook-compact/`.
- Support exactly two discriminator values: `operation: "compact"` compacts an
  ordered source-note snapshot into non-empty Markdown key points with a
  version; `operation: "answer"` answers a question from only a compact
  summary.
- Use `executionBackend: codex-agent`; keep operation-specific input/output
  envelopes explicit so answer payloads have no source-body field.
- Record deterministic mock assertions for both operation shapes.

**Completion criteria**:

- Bundle validation succeeds, both mock operations complete, and the answer
  mock demonstrates summary-only input.
- Both codex-agent nodes use a read-only sandbox, ephemeral ignored user
  configuration, and an explicit policy disabling ambient execution, browser,
  search, app, plugin, multi-agent, and image capabilities. A prompt-injection
  canary verifies that note instructions remain data behind this boundary.

### TASK-003 — Expansion DTOs and subprocess provider

**Status**: Done
**Depends on**: TASK-002 contract names
**Write scope**:
`Sources/RielaNoteUI/RielaNoteNotebookExpansionModels.swift`,
`Sources/RielaNoteUI/RielaNoteWorkflowNotebookCompactProvider.swift`, and
`Tests/RielaNoteUITests/RielaNoteNotebookExpansionTests.swift`

**Deliverables**:

- Add the accepted compact request/source-note/draft and expansion
  request/answer DTOs plus `RielaNoteNotebookExpansionProviding` and
  `RielaNoteNotebookExpansionError`.
- Implement both provider methods against the one workflow bundle using an
  explicit operation discriminator.
- Reuse `RielaNoteWorkflowProviderSupport.swift` for trusted executable and
  workflow resolution, private variables files, environment sanitization,
  cancellation-safe subprocess termination, deadline handling, and final-valid
  JSONL `result.rootOutput` decoding.
- Give every invocation a mode-0700 working directory and private session
  store, remove the complete directory on every handled outcome, and launch the
  workflow in its own POSIX process group so timeout/cancellation reaches all
  descendants.
- Add provider tests for argv, environment allowlisting, cancellation/failure
  mapping, operation-specific decoding, and captured variables. A distinctive
  source-body sentinel must occur in compact input and be absent from answer
  input.

**Completion criteria**:

- The answer request type and serialized answer operation cannot carry notebook
  objects, source ids, note bodies, attachments, search results, or ambient Note
  Agent retrieval context.
- Answer-operation runtime variables contain exactly the operation, compact
  summary, and question envelope; `noteRoot` remains compaction-only.
- Full source-body variables and workflow runtime records do not survive the
  invocation, and non-`exec` descendants exit on timeout and cancellation.

### TASK-004 — Client integration, cache orchestration, and seeded conversation

**Status**: Done
**Depends on**: TASK-001, TASK-003
**Write scope**: `Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient+NotebookExpansion.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel+NotebookExpand.swift`, and
`Tests/RielaNoteUITests/RielaNoteNotebookExpansionTests.swift`

**Deliverables**:

- Inject one optional expansion provider into `NoteServiceRielaNoteUIClient`
  without breaking existing initializers or test doubles.
- Add client operations for provider availability, source snapshot/cache access,
  cache persistence, seeded conversation creation, and linked later-turn
  persistence through the TASK-001 service seams.
- Implement one in-flight expansion task per source notebook. Validate cache
  version, non-empty summary, source `updatedAt`, and note count; on a miss load
  the complete ordered snapshot and compact it. Recheck source markers before
  cache write, retry one stale result once, then return a recoverable error.
- On success, call `saveConversation` with the resolved fixed system-generated
  prompt and compact summary, `notebook-kind:agent-conversation` behavior,
  versioned `rielaNote.notebookExpansion` metadata, and all cached source ids as
  `.ai` `source-citation` inputs.
- Publish a one-shot `RielaNoteNotebookExpansionSession` containing the durable
  context needed by the root and Agent view model.
- Add tests for never-expanded untouched state, cache miss, reuse without a
  second compact call, invalidation by `updatedAt`, invalidation by note count,
  malformed cache, same-notebook single-flight, bounded stale-snapshot retry,
  and fail-fast `.notConfigured` with unchanged cache/notebook/note counts on
  both cache paths.

**Completion criteria**:

- Repeated expansion of the same unchanged source reuses the compact cache but
  creates a fresh seeded conversation; no cache or conversation mutation occurs
  when the provider is unavailable.
- A source mutation between verification and publication fails the atomic
  compare-and-set and enters the existing bounded retry path without writing a
  stale cache.

### TASK-005 — Expansion-mode Agent session and root routing

**Status**: Done
**Depends on**: TASK-004
**Write scope**: `Sources/RielaNoteUI/RielaNoteAgentModels.swift`,
`Sources/RielaNoteUI/RielaNoteAgentViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteRootView.swift`, and
`Tests/RielaNoteUITests/RielaNoteNotebookExpansionTests.swift`

**Deliverables**:

- Add explicit `.general` and `.notebookExpansion(session)` modes plus
  `beginNotebookExpansionSession(_:)`.
- In expansion mode, submit only `compactSummaryMarkdown` and the typed question
  to `answerNotebookExpansion`, then atomically persist and source-link the turn
  through `appendConversationTurn`.
- Prohibit expansion mode from calling `answerNoteAgentTurn`, FTS retrieval,
  current-note attachment composition, source-body loading, or silent fallback.
- Make `RielaNoteRootView` consume the one-shot expansion result, select the new
  notebook, start expansion mode, show the Agent tab, and focus its composer.
  Preserve current selection and expose a recoverable error on failure.
- Add tests proving summary-only requests, one persisted note per successful
  question/answer pair, every-source links, general-provider bypass, explicit
  new-conversation exit, and `.notConfigured` after a session has started.

**Completion criteria**:

- Every successful active-session turn is visible as a note in the created
  notebook and through `listLinks`; general Note Agent behavior is unchanged.
- A failed expansion-turn write remains visible and Save retries persistence
  only. A later question first flushes pending turns, and a new chat cannot
  discard an unsaved expansion answer.

### TASK-006 — Notebook-row actions on both UI surfaces

**Status**: Done
**Depends on**: TASK-004
**Write scope**: `Sources/RielaNoteUI/RielaNoteNotebookListView.swift`,
`Sources/RielaNoteUI/RielaNoteFileTreePane.swift`, and
`Tests/RielaNoteUITests/RielaNoteNotebookExpansionTests.swift`

**Deliverables**:

- Add the same **Expand with Agent** context-menu action to
  `RielaNoteNotebookRow` and `notebookRow`.
- Route both actions to the shared `expandNotebook(_:)` operation and disable
  duplicate activation only for the notebook whose task is active.
- Preserve existing row selection, paging, disclosure, drag/drop, and pending
  edit-navigation behavior.

**Completion criteria**:

- Both surfaces expose and dispatch the action; neither contains an independent
  cache, provider, or persistence implementation.

### TASK-007 — RielaApp provider construction

**Status**: Done
**Depends on**: TASK-003, TASK-004
**Write scope**: `Sources/RielaApp/NoteWindowController.swift` and
`Tests/RielaAppSupportTests/RielaAppNotesIntegrationTests.swift`

**Deliverables**:

- Construct `RielaNoteWorkflowNotebookCompactProvider.defaultProvider` using
  the established workflow-provider pattern and inject it into the note UI
  client.
- Keep absence nonfatal during window construction; user invocation surfaces
  `.notConfigured` through the accepted client/view-model path.

**Completion criteria**:

- A configured bundle is discoverable by the app, while an unconfigured app
  still opens the Notes window and fails only the requested expansion action.

### TASK-008 — Documentation, adversarial review, and final verification

**Status**: Done
**Depends on**: TASK-001 through TASK-007
**Write scope**: directly affected tests and documentation only

**Deliverables**:

- Run an adversarial review of cache self-invalidation, answer-payload leakage,
  transactional persistence, linear source-link fanout, provider environment,
  timeout, and cancellation behavior; fix all high/mid findings in scope.
- Refresh the Riela Note section of `README.md` with the action, cache behavior,
  summary-only grounding, and provider configuration. Review
  `.codex/skills/riela-impl-workflow/SKILL.md` and record whether its workflow
  contract needs a directly affected update.
- If a `riela-package.json` manifest covers any changed workflow, prompt,
  script, or skill file, refresh and verify its checksum/integrity values; if no
  manifest applies, record that verification gap as not applicable.
- Reconcile this plan's task status, checklists, dated progress log, changed
  file list, review decision, exact verification results, and any accepted gap.

**Completion criteria**:

- All acceptance criteria and targeted verification pass, no high/mid review
  finding remains, documentation matches shipped behavior, and unrelated dirty
  files are neither modified nor staged.

## Dependencies and safe parallel work

- TASK-001, TASK-002, and TASK-003 may run in parallel after the already listed
  `compact`/`answer` operation names and payload fields are treated as fixed.
  TASK-001 owns only the named `RielaNote` service/model files and service test;
  TASK-002 owns only `examples/note-notebook-compact/`; TASK-003 owns only the
  two named provider/model files and its provider test.
- TASK-004 joins the service and provider work and must follow TASK-001 and
  TASK-003.
- TASK-005 and TASK-006 may run in parallel after TASK-004 because every source
  and test file named in their write scopes is disjoint.
- TASK-007 may run alongside TASK-005/TASK-006 after the client initializer is
  stable because it owns only `NoteWindowController.swift` and
  `RielaAppNotesIntegrationTests.swift`; coordinate initializer signature
  changes through TASK-004 before parallel work starts.
- TASK-008 is the final serial gate. Parallel workers must not edit shared
  progress files or each other's listed test files.

## Verification

Run only the targeted gates requested by the accepted work package:

```bash
mkdir -p ./tmp/note-notebook-compact/note-root
swift build
swift test --filter RielaNoteTests
swift test --filter RielaNoteUITests
swift test --filter RielaAppNotesIntegrationTests
riela workflow validate note-notebook-compact --workflow-definition-dir ./examples
riela workflow run note-notebook-compact \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/note-notebook-compact/mock-scenario.json \
  --variables '{"noteRoot":"./tmp/note-notebook-compact/note-root","workflowInput":{"operation":"compact","notebookId":"notebook-1","notebookTitle":"Plan","sourceNotes":[{"noteId":"note-1","noteNumber":1,"bodyMarkdown":"SOURCE-BODY-SENTINEL: Draft the milestone."}]}}' \
  --output json
riela workflow run note-notebook-compact \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/note-notebook-compact/mock-scenario-answer.json \
  --variables '{"workflowInput":{"operation":"answer","compactSummaryMarkdown":"SUMMARY-SENTINEL: Draft the milestone.","questionMarkdown":"What is next?"}}' \
  --output json
git diff --check
```

Use narrower new test-case filters during iteration. Do not substitute a full
test-suite run for these required targeted results. Inspect the answer-operation
variables evidence and confirm it contains the compact-summary sentinel while
excluding the distinctive full-source-body sentinel.

Manual smoke check after automated gates: invoke **Expand with Agent** from each
notebook surface, verify the second invocation reuses cache, submit a later
question, inspect the created notebook notes and visible source links, then
repeat with no provider configured and confirm a recoverable error with no
mutation.

## Completion criteria

- Both notebook surfaces expose the shared action.
- Compaction is lazy, cached, reused, and invalidated by either accepted source
  marker; never-expanded notebooks remain untouched.
- A fresh agent-conversation notebook is seeded from the compact summary and
  every active-session question/answer pair is persisted as a note.
- Every generated note links to every compacted source note with `.ai`
  `source-citation` provenance while that source exists, queryable through
  `NoteService.listLinks`; deleted source ids remain auditable in turn metadata.
- Expansion provider input contains only the compact summary and question; no
  full source body reaches the answer operation or general Note Agent.
- Missing providers return `.notConfigured` without a crash or mutation.
- Targeted build, tests, workflow validation, deterministic mock runs, diff
  checks, adversarial review, and documentation refresh are recorded as passed.

### Step 6 completion evidence

- [x] Both notebook surfaces dispatch the shared **Expand with Agent** action.
- [x] Lazy cache creation, reuse, `updatedAt` invalidation, note-count
  invalidation, and never-expanded isolation are covered by tests.
- [x] Seed and later-turn notes are persisted and atomically linked to every
  source note with `.ai` `source-citation` provenance.
- [x] Answer variables are structurally summary/question-only and exclude the
  full-source-body sentinel and `noteRoot`.
- [x] Compact-cache publication compares the expected `updatedAt` and note
  count inside the service transaction; a deterministic race regression proves
  stale metadata is not written.
- [x] Expansion-turn persistence is idempotent and recoverable: Save performs a
  persistence-only retry, subsequent questions flush pending turns first, and
  deleted source ids are audited without dropping the generated answer.
- [x] Missing-provider paths fail before mutation.
- [x] Untrusted note content runs behind an explicit ephemeral no-ambient-tool
  codex-agent policy with a deterministic prompt-injection canary.
- [x] Each workflow run uses a private removable session store and POSIX
  process group; tests prove source-body runtime records are deleted and
  non-`exec` children terminate on timeout and cancellation.
- [x] Agent drafts, attachments, temporary turns, failed-persistence answers,
  and in-flight responses cannot be replaced by a new expansion without an
  explicit discard decision.
- [x] Swift build, note service tests, the 208-test aggregate note UI filter,
  the 17-test focused expansion filter, 19 app integration tests, bundle
  validation, both mock operations, SwiftLint, and diff checks pass.
- [x] README documentation is current; the reviewed implementation-workflow
  skill needs no change; no `riela-package.json` covers the new example.

## Progress-log expectations

During implementation, update each task from `Not started` to `In progress` to
`Done` and append dated entries here. Every entry must identify task ids,
changed file paths, key decisions, findings and their disposition, commands with
pass/fail results, and remaining risks or verification gaps. Do not mark a task
done from compilation alone; cite its task-specific tests. Preserve the issue
reference, Step 3 review decision, and empty Codex-agent reference set in the
final handoff.

## Progress log

### 2026-07-21 — Step 4 plan creation

- Created this plan from the Step 3-accepted design (`comm-001415`).
- No Step 5 feedback exists; `addressedFeedback` is empty.
- No implementation code or verification beyond plan/document checks was run
  in this step.

### 2026-07-21 — Step 4 self-review revision

- Addressed all `comm-001417` plan-only mid findings: named the exact service,
  provider, view-model, Agent, row-action, and RielaApp test paths; corrected
  the app integration target to
  `Tests/RielaAppSupportTests/RielaAppNotesIntegrationTests.swift`; and tied
  parallel work to disjoint named files.
- Replaced verification placeholders with complete operation-specific JSON and
  the repository-local `./tmp/note-notebook-compact/note-root` scratch path.
- No accepted design decision or implementation architecture changed.

### 2026-07-21 — Step 6 implementation and verification

- Completed TASK-001 through TASK-008 for issue-resolution workflow
  `codex-design-and-implement-review-loop-session-614`; Step 5 supplied no
  implementation feedback, so `addressedFeedback` remains empty.
- Added service metadata and atomic source-link persistence in
  `Sources/RielaNote/NoteModels.swift`,
  `Sources/RielaNote/NoteService+Relations.swift`, and
  `Sources/RielaNote/NoteService+NotebookExpansion.swift` with coverage in
  `Tests/RielaNoteTests/NoteServiceNotebookExpansionTests.swift`.
- Added expansion DTOs, subprocess provider, client/view-model orchestration,
  expansion-mode Agent routing, both row actions, root routing, and app
  injection in `Sources/RielaNoteUI/RielaNoteNotebookExpansionModels.swift`,
  `Sources/RielaNoteUI/RielaNoteWorkflowNotebookCompactProvider.swift`,
  `Sources/RielaNoteUI/RielaNoteUIClient.swift`,
  `Sources/RielaNoteUI/RielaNoteUIClient+NotebookExpansion.swift`,
  `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
  `Sources/RielaNoteUI/RielaNoteLibraryViewModel+NotebookExpand.swift`,
  `Sources/RielaNoteUI/RielaNoteAgentModels.swift`,
  `Sources/RielaNoteUI/RielaNoteAgentViewModel.swift`,
  `Sources/RielaNoteUI/RielaNoteNotebookListView.swift`,
  `Sources/RielaNoteUI/RielaNoteFileTreePane.swift`,
  `Sources/RielaNoteUI/RielaNoteRootView.swift`, and
  `Sources/RielaApp/NoteWindowController.swift`; consolidated focused coverage
  lives in `Tests/RielaNoteUITests/RielaNoteNotebookExpansionTests.swift`.
- Added the complete `examples/note-notebook-compact/` bundle: `workflow.json`,
  `nodes/node-notebook-compact.json`, `nodes/node-workflow-output.json`,
  `prompts/notebook-compact.md`, `mock-scenario.json`,
  `mock-scenario-answer.json`, and `EXPECTED_RESULTS.md`.
- Refreshed `README.md`. The accepted design artifacts remain
  `design-docs/specs/design-riela-note-notebook-expand.md`,
  `design-docs/specs/design-riela-note.md`, and
  `design-docs/user-qa/qa-riela-note-notebook-expand-seed-format.md`.
- Adversarial review found and fixed one maintainability/coverage issue: split
  notebook-expansion client methods into a focused file to keep every changed
  Swift file below 1,000 lines, then added direct provider tests for private
  variables-file cleanup, last-valid JSONL parsing, environment sanitization,
  nonzero failure mapping, timeout, and cancellation before launch. No high or
  mid implementation finding remains.
- Passed `swift build`; `swift test --filter RielaNoteTests`;
  `swift test --filter RielaNoteUITests` (197 tests); focused
  `swift test --filter RielaNoteNotebookExpansionTests` (10 tests);
  `swift test --filter RielaAppNotesIntegrationTests` (18 tests);
  `riela workflow validate note-notebook-compact --workflow-definition-dir ./examples`;
  both planned deterministic `riela workflow run` commands; targeted
  SwiftLint; and `git diff --check`.
- Built and launched the current direct debug executable for UI inspection and
  captured `tmp/rielaapp-ui-review/sidebar-window-2.png`; the isolated process
  was terminated. Static UI dispatch and current-executable rendering are
  verified, but the two context menus were not interactively invoked in that
  smoke session.
- `rg --files -g 'riela-package.json' -g '!tmp/**'` returned no applicable
  manifest, so package digest refresh is not applicable. Temporary test and UI
  evidence remains only under ignored `tmp/` and is not staged.

### 2026-07-21 — Step 6 self-review revision (`comm-001422`)

- Addressed the three mid self-review findings without changing the accepted
  design or work-package scope.
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel+NotebookExpand.swift` now
  awaits an existing same-notebook expansion task instead of returning early;
  its concurrency test proves the duplicate caller remains pending and only
  one compaction/conversation is produced.
- `Sources/RielaNote/NoteService+NotebookExpansion.swift` now rejects a
  non-object existing `rielaNote` namespace without mutation, preserving user
  metadata; `Tests/RielaNoteTests/NoteServiceNotebookExpansionTests.swift`
  covers the collision.
- Completed the previously missing plan coverage in
  `Tests/RielaNoteUITests/RielaNoteNotebookExpansionTests.swift`: malformed
  cache miss, one-retry success and two-change failure, cache-hit and cache-miss
  `.notConfigured` immutability, expansion/general provider routing, explicit
  mode exit, provider loss after session start, both surface action dispatches,
  serialized compact/answer payload separation, auth allowlisting, and
  prelaunch/mid-run cancellation. Added provider discovery/absence coverage to
  `Tests/RielaAppSupportTests/RielaAppNotesIntegrationTests.swift`.
- Final revision results: focused service tests 4/4, expansion tests 17/17,
  app integration tests 19/19, full targeted `RielaNoteTests` passed, and the
  aggregate `RielaNoteUITests` retry passed 208/208 after one signal-11 runner
  exit. The initial test-only cancellation marker race and timestamp-based
  stale-test nondeterminism were corrected before these final results.

### 2026-07-21 — Step 7 review revision (`comm-001432`)

- Addressed the Step 7 mid finding in
  `Sources/RielaNoteUI/RielaNoteRootView.swift`: expansion completion now routes
  through `requestSelection(.notebook(...))`, waits behind the existing
  unsaved-edit confirmation, starts the expansion Agent session only after an
  immediate or confirmed selection, and leaves the draft/current selection
  unchanged when the user chooses Keep Editing.
- Added the focused Discard/Keep Editing regression in
  `Tests/RielaNoteUITests/RielaNoteNotebookExpansionTests.swift`; the expansion
  filter passed 19/19.
- Closed the low rollback-coverage finding in
  `Tests/RielaNoteTests/NoteServiceNotebookExpansionTests.swift` with a
  deterministic SQLite trigger that aborts the AI link insert after generated
  note creation; database counts prove notebook, note, and link rollback. The
  service filter passed 4/4.
- Removed implementation-plan trailing whitespace that the earlier untracked
  file check missed. `git diff --check adc2eb1f` and `git diff --check` now pass
  for the complete feature range and current revision.
- Revalidated
  `.build/arm64-apple-macosx/debug/riela workflow validate note-notebook-compact
  --workflow-definition-dir ./examples` with `valid=true` and no diagnostics.
  Targeted SwiftLint passed for the three changed Swift files; the broader lint
  output contained only the repository's existing warnings outside them.
- The Xcode toolchain built the current direct
  `.build/arm64-apple-macosx/debug/RielaApp` executable successfully, and the
  isolated executable launched its Notes window. Screenshot capture was not
  available: `screencapture` lacked capture permission, ScreenCaptureKit
  returned `SCStreamErrorDomain -3811`, and the Computer Use fallback timed
  out. No app bundle was used. Automated route-state coverage is the final UI
  evidence for this non-layout behavior revision.

### 2026-07-21 — Adversarial Step 7 revision (`comm-001437`)

- Addressed all three mid findings from Codex-agent reference
  `/root/adversarial_swift_review` without feature fan-out or design-scope
  expansion.
- `Sources/RielaNoteUI/RielaNoteAgentViewModel.swift`,
  `Sources/RielaNoteUI/RielaNoteUIClient.swift`, and
  `Sources/RielaNoteUI/RielaNoteUIClient+NotebookExpansion.swift` now carry a
  stable turn id through expansion persistence, expose Save as a
  persistence-only retry, flush pending turns before generating a later answer,
  and prevent New chat from discarding an unsaved expansion answer.
- `Sources/RielaNote/NoteModels.swift` and
  `Sources/RielaNote/NoteService+Relations.swift` preserve strict source-link
  validation by default while allowing only expansion follow-ups to survive a
  source deleted after session start. Missing source ids are recorded in the
  turn's `rielaNote.conversationTurn` metadata; stable idempotency keys return
  the existing note and do not redispatch note-created auto actions.
- `Sources/RielaNoteUI/RielaNoteWorkflowNotebookCompactProvider.swift` and
  `Sources/RielaNoteUI/RielaNoteNotebookExpansionModels.swift` remove
  `noteRoot` from the answer provider boundary. The serialized answer variables
  test asserts that the complete runtime envelope contains only
  `workflowInput`, whose exact keys are `operation`, `compactSummaryMarkdown`,
  and `questionMarkdown`.
- `Sources/RielaNote/NoteService+NotebookExpansion.swift` and
  `Sources/RielaNoteUI/RielaNoteLibraryViewModel+NotebookExpand.swift` publish
  compact metadata only when the expected source `updatedAt` and note count
  still match inside the database transaction. Compare-and-set failure uses the
  existing one-retry stale-source path.
- Added deterministic regression coverage in
  `Tests/RielaNoteTests/NoteServiceNotebookExpansionTests.swift`,
  `Tests/RielaNoteUITests/RielaNoteAgentViewModelTests.swift`, and
  `Tests/RielaNoteUITests/RielaNoteNotebookExpansionTests.swift` for atomic
  cache publication, service idempotency, persistence-only retry, pending-turn
  flush ordering, and deleted-source recovery.
- Final adversarial-revision verification passed:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteServiceNotebookExpansionTests`
  (6/6) and
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteNotebookExpansionTests`
  (21/21); the explicit Xcode-toolchain
  `swift build --product RielaApp`; targeted SwiftLint across every changed
  Swift file; `.build/arm64-apple-macosx/debug/riela workflow validate
  note-notebook-compact --workflow-definition-dir ./examples` with
  `valid=true` and no diagnostics; and `git diff --check adc2eb1f && git diff
  --check`.

### 2026-07-21 — Step 6 self-review revision (`comm-001439`)

- Corrected the authoritative answer-operation mock command so its variables
  contain only `workflowInput` with `operation`, `compactSummaryMarkdown`, and
  `questionMarkdown`; `noteRoot` is absent from the answer boundary.
- Verified the corrected command with
  `.build/arm64-apple-macosx/debug/riela workflow run note-notebook-compact
  --workflow-definition-dir ./examples --mock-scenario
  ./examples/note-notebook-compact/mock-scenario-answer.json --variables
  '{"workflowInput":{"operation":"answer","compactSummaryMarkdown":"SUMMARY-SENTINEL:
  Draft the milestone.","questionMarkdown":"What is next?"}}' --output json`;
  it completed with assistant output. Then
  `git -c core.fsmonitor=false diff --check adc2eb1f && git -c
  core.fsmonitor=false diff --check` passed.

### 2026-07-21 — Adversarial Step 7 revision (`comm-001444`)

- Addressed all four mid findings without feature fan-out. Codex-agent
  references were `/root/adversarial_swift_review`,
  `/root/step6_adversarial_fixes`, `/root/step6_plan_evidence_fix`,
  `/root/step7_adversarial_audit`, `/root/step6_security_fixes`, and
  `/root/step6_agent_state_fix`.
- `examples/note-notebook-compact/nodes/node-notebook-compact.json` and
  `nodes/node-workflow-output.json` now enforce read-only, ephemeral,
  ignored-user-config execution and disable ambient command, browser, search,
  app, plugin, multi-agent, and image capabilities. The focused provider suite
  includes an explicitly named prompt-injection canary.
- `Sources/RielaNoteUI/RielaNoteWorkflowProviderSupport.swift` and
  `Sources/RielaNoteUI/RielaNoteWorkflowNotebookCompactProvider.swift` now use
  a private mode-0700 per-invocation working directory, a private
  `--session-store`, mode-0600 variables, and deterministic POSIX process-group
  launch/termination. Cleanup and non-`exec` descendant tests cover success,
  failure, timeout, and cancellation.
- `Sources/RielaNoteUI/RielaNoteAgentViewModel.swift` and
  `Sources/RielaNoteUI/RielaNoteRootView.swift` preserve drafts, attachments,
  temporary chats, failed-persistence expansion answers, and in-flight replies.
  The root offers **Discard and expand** or **Keep current conversation**, and
  replacement fails closed while a response is loading.
- Verification passed: Xcode-toolchain `swift build` reported `Build complete`;
  `swift test --skip-build --filter NoteServiceNotebookExpansionTests` passed
  6/6; `swift test --skip-build --filter RielaNoteNotebookExpansionTests`
  passed 23/23; `swift test --skip-build --filter
  RielaNoteAgentViewModelTests` passed 15/15; and workflow validation returned
  `valid=true` with no diagnostics. SwiftLint reported only eight pre-existing
  warnings outside this feature. `jq` confirmed both worker nodes carry the
  explicit sandbox/ephemeral policy, all changed Swift files remain below
  1,000 lines, and `git -c core.fsmonitor=false diff --check adc2eb1f` passed.
  Some SwiftPM/lint command wrappers remained alive after their successful
  output; this is recorded as a tooling gap, not a test-suite failure.
- Updated `README.md` and
  `design-docs/specs/design-riela-note-notebook-expand.md`. The implementation
  workflow and Swift skills required no change, and no applicable
  `riela-package.json` exists.

## Risks carried into implementation

- Derived cache writes could self-invalidate if they accidentally update source
  `updatedAt`.
- Operation serialization could leak source bodies into the answer path despite
  type separation.
- Extending conversation persistence could leave partial notebooks, turns, or
  links if transaction boundaries diverge.
- Linking every generated turn to every source note has intentional linear
  write fanout and must not be silently capped.
- Abrupt process death outside handled success/failure/timeout/cancellation can
  leave an operating-system temporary invocation directory for later cleanup;
  handled outcomes remove it deterministically.
- The source-link fanout remains intentionally linear in generated-note count
  times source-note count; no silent cap was introduced.
- The final current-executable smoke session did not invoke both context menus
  end to end; automated construction/dispatch coverage, aggregate UI tests, and
  direct source inspection are the verification evidence for those actions.
