# Workflow Graph Studio — Implementation Plan

Status: COMPLETE — acceptance verified 2026-09-10
Created: 2026-09-09
Design: `design-docs/specs/design-workflow-graph-studio.md`
Task: extend the existing web workflow graph with GUI authoring and live agent chat.
Commit/push: not requested.

Final audit: `design-docs/user-qa/qa-workflow-graph-studio.md`.
Pending/next statements in the historical evidence log below describe earlier
stages and are superseded by this completed checklist and the final audit.

## Execution sequence

- [x] Inspect existing Command deck, graph camera, mutable registry, assistant
  adapter events, and relevant source/test contracts.
- [x] Document the design and this plan, including the user's explicit
  requirement to manage workflow definitions separately from node coordinates.
- [x] Implement lossless graph operations, node settings, connections, entry
  selection, deletion safeguards, Undo/Redo, validation, and JSON fallback.
  Includes retained-value rebasing and semantic-reference deletion guards.
- [x] Persist layout separately by profile/origin; verify drag/reopen and
  confirm coordinate changes never issue registry writes.
- [x] Connect studio to existing Command deck selection and mutable workflows.
  Preserve bundle resources on editable-copy creation and revision-check all
  saves. Verify duplicate, protected-field, and conflict behavior.
- [x] Implement profile-bound agent generation API over existing assistant
  adapters, incremental record parsing, bounded sessions, and cancellation.
  Store/routes build and focused tests pass, including repeated revisions.
- [x] Add chat UI and live canvas application with draft isolation, one undo
  boundary, cleanup, and recoverable failures.
- [x] Add execution from the studio with explicit input JSON and a saved
  revision, followed by same-screen graph status and log inspection.
- [x] Expose and render actual persisted input/output per step execution
  attempt. Verify running/completed/failed cases against real runtime data.
- [x] Run browser creation/edit/save/reopen, node drag/connect, live generation,
  cancellation, conflict, and narrow viewport journeys.
- [x] Run an actual configured-provider generation and inspect a real saved
  workflow using isolated test state. Mocked tests do not close this item.
- [x] Review implementation against every acceptance criterion; update README
  and evidence below, resolve all failures introduced by the change.

## Final verification

- Full web gate: typecheck, lint, 79 unit tests, production build, 28 browser
  tests passed.
- Focused Swift gate with `RIELA_TEST_LIVE_EDITOR_AGENT=1`: 38 tests passed.
  The strengthened live test requires an actual one-step graph while running,
  a two-step final graph, real registry validation/registration and reopen.
  It passed twice after the progressive-round fix (27.247s and 33.523s).
- The strengthened audit initially exposed buffered-provider output and a
  summary-only adapter result. `WorkflowEditorAuthoringRounds` now performs
  bounded real editing rounds and collects framed assistant event records;
  it publishes a round before invoking the next one. Deterministic tests cover
  this contract without simulating a token-by-token provider.
- RielaApp build passed (3.25s); repository-wide SwiftLint exited zero with
  unrelated baseline warnings; changed authoring files lint cleanly.
  `git diff --check` passed. All changed Swift files are below 1,000 lines.
- README, design and acceptance evidence are refreshed. No commit, push,
  installation or unrelated worktree changes were performed.

## Verification commands

```sh
cd web
bun run typecheck
bun run lint
bun run test
bun run build
bun run test:e2e
```

From repository root, use Xcode's Swift toolchain:

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowEditorGenerationTests|RielaAppWebAPIRouteTests|RielaAppWebRegistryProviderTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swiftlint --quiet --no-cache
git diff --check
```

## 2026-09-10 file-backed editing and retained-route follow-up

- Retained transition fields now survive removing an earlier transition,
  authenticating against the original source step and exact routing target.
  The real registry test removes one of two same-target transitions and proves
  the surviving hidden label is retained. Earlier references to “conditions”
  meant retained transition fields, not a nonexistent authored `when` field.
- Added the file-backed node settings dialog and profile-checked load/save API.
  It edits primary prompt/model without rewriting original resources, preserves
  unknown payload fields, and updates a content-addressed node reference in the
  registry's atomic workspace transaction. Save checks definition and asset
  revisions. The editor adopts the new canonical definition/revision.
- Real API/resource test passed: load a prompt file, refuse stale assets after
  an external edit, save a derived node, load it through the production bundle
  loader, prove the edited prompt is used, prove original files unchanged, and
  reject stale workflow-revision replay.
- That test exposed display-text whitespace compaction. Authoring text now
  preserves original newlines/spacing when it is not redacted. The inline-node
  test also explicitly checks a multiline prompt.
- Full web gate passed: 77 unit tests, 28 browser tests, typecheck, lint and
  production build. Focused Swift editor/registry/route gate passed 33 tests.
  Changed-file SwiftLint passed; app build succeeded. Inspected the rendered
  file-backed settings dialog screenshot under repository `tmp/`.
- Still required before completion: final requirement-by-requirement acceptance
  audit, including referenced-step definitions and editing configuration
  variants. Do not infer broad completion from the focused settings tests.

Keep all disposable evidence under repository-root `tmp/workflow-graph-studio/`.
Preserve unrelated user changes (app menu/icon and Monja example/design files).
Do not claim completion from a successful build alone.

## Evidence log

- Initial graph editor TypeScript typecheck and focused ESLint passed.
- Initial editable-copy API/RielaApp build passed before agent API work.
- First agent-store build found an unavailable `CLIUsageError` dependency;
  replace with an error owned by the editor support module and rerun.
- Live agent, real editable-copy route, and end-to-end real-registry persistence
  evidence are still pending. Browser coverage uses controlled API fixtures.
- Agent store tests passed (3 tests): intermediate state before completion,
  profile isolation, cancellation/late output, and non-assistant event filtering.
- Browser live-generation test passed. Layout reopen test exposed an old-key
  migration overwriting newer layout on a second save; fixed and rerun passed.
- Full web gate passed: lint/source audit, typecheck, 76 unit tests, production
  build, and all 22 browser tests (including both new studio journeys).
- Focused Swift gate passed: 28 tests covering existing web routes/registry
  contracts plus generation state. Changed-file SwiftLint and `git diff --check`
  passed. App build passed. Existing redundant-public warning remains in
  `RielaAppDaemonWorkflowPreference.swift` outside this change.
- Next: implement same-screen execution and real per-attempt I/O persistence,
  then verify live provider and real saved workflow journeys before completion.
- 2026-09-09 continuation: added per-attempt input snapshots to the runner and
  runtime store, preserving legacy decode behavior. Added profile-checked
  read-only run/attempt evidence endpoints and an in-editor inspector for
  actual input, accepted output, response text and failure details.
- Studio browser suite now passes 3 tests, including switching failed/successful
  attempts and verifying that old values disappear without leaving the graph.
  Web lint/typecheck/build and changed Swift-file lint passed. New Swift
  runner/store and real SQLite evidence-route tests passed, followed by the
  59-test focused runner/runtime-store/evidence regression gate, with no failures.
- Remaining launch work: resolve an exact saved mutable origin/revision,
  capture an execution bundle under registry coordination, run with explicit
  inputs/working directory through the existing CLI runtime, then open its
  persisted session in the inspector automatically. Do not bypass deactivation
  or execute unsaved edits while labeling them as the saved revision.
- Launch implementation now complete: exact active mutable origin and revision
  are checked under registry coordination; `WorkflowRunCommand` executes the
  captured bundle with explicit input/cwd and a profile session store. Studio
  opens the captured session automatically and reflects step statuses on cards.
- Real registry/runtime test passed: stale launch refused before creating a
  job, valid stored sleep workflow executed without mocks, real session and
  input/output verified in SQLite. The default inline agent shape also passed
  real web-registry registration validation.
- Real registration exposed invalid empty workflow defaults. Fixed `newGraph`
  and the agent protocol to supply required nodeTimeoutMs/maxLoopIterations;
  graph validation now reports missing defaults before save.
- Latest full web gate: lint, typecheck, 76 unit tests, build, 24 browser tests
  passed. Focused web API/registry/editor Swift gate: 30 tests passed. Swift
  app build passed after explicitly linking RielaCLI for canonical execution.
- Remaining completion work includes actual configured-provider generation,
  protected existing-node configuration and connection edge-case review,
  conflict recovery, visual QA, and documentation refresh. The goal remains
  active; successful mocked chat playback is not proof of a live agent.
- Live Codex verification passed via `RIELA_TEST_LIVE_EDITOR_AGENT=1 swift test
  --filter WorkflowEditorLiveAgentTests`: a running intermediate revision and
  a completed two-step generated definition were observed (20.271 seconds).
- Follow-up focused Swift gate passed 8 tests: generation revisions, real
  saved-workflow execution, SQLite evidence API and actual runner invocation
  snapshots, including legacy records and failed/retried attempts.
- Inspector now distinguishes another workflow's run from the current graph,
  preventing false status overlays while keeping its actual values readable.
  README documents saved-revision execution, same-page logs, separate layout,
  recorded-data sensitivity, and explicit evidence limits.
- Latest execution/log verification: 77 web unit tests and all 25 Playwright
  tests passed; the focused Swift suites passed 33 tests (8 editor/runtime
  tests plus 25 web route/registry tests). RielaApp build, changed-file
  SwiftLint, web typecheck/lint/build and `git diff --check` passed.
- Inspected desktop and 390px-width screenshots from the saved-run browser
  journey under `tmp/web-dashboard-e2e/playwright-results/`. Fixed editor zoom
  controls inheriting the command deck's sidebar offset and excessive fit
  padding. Fit view now uses editor-specific padding and actual node bounds;
  adding/removing steps refits the canvas without changing stored positions.
  Narrow layouts stack actual input/output and have no page-wide overflow.
- Remaining broader authoring work: protected existing-node configuration,
  retained-value structural edits, direct editable-copy API coverage, and
  studio-specific conflict recovery tests. Execution/log support is verified;
  the overall graph-authoring goal is not yet complete.
- 2026-09-10: inspection of the real provider exposed a metadata-only mutation
  response contract missed by the original browser fixtures. Studio now reads
  the canonical authoring definition/revision after save and activation,
  refreshes retain handles, and clears obsolete Undo history without remounting
  the canvas/chat. Browser fixtures now mirror metadata-only responses.
- Added explicit authoring projection/API for inline add-on prompt/model
  settings; normal registry redaction is unchanged and other configuration/env
  stays opaque. Hidden settings have an explicit retained/replacement message.
- Node/step retain expansion follows stable IDs after index shifts. A real
  registry/API test verifies editing a prompt, deleting an earlier node/step,
  preserving the surviving hidden values, rejecting a cross-node rebound,
  reading a new revision and saving it again. Profile mismatch is rejected.
- Browser conflict test passes for preserving the draft, cancelling reload,
  and explicit discard/reload. A post-save refresh-failure test passes for
  blocking further writes/runs and recovery without duplicate registration.
- Latest full web gate passed: typecheck, lint, 77 unit tests, build and all
  27 browser tests. Focused Swift editor/registry/route gate passed 32 tests.
  Changed-file SwiftLint and `git diff --check` passed.
- Remaining: file-backed node settings, retained transition-condition index
  shifts, and final requirement-by-requirement authoring review. Do not mark
  the broader goal complete yet.
- Additional real editable-copy API test passed: source definition, node file
  and prompt file are byte-preserved; the copy starts deactivated; duplicate
  creation fails without overwriting; profile mismatch is rejected. Both
  `WorkflowEditorDefinitionTests` now pass. RielaApp build also passed.

Latest Swift commands (repository root):

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'WorkflowEditorDefinitionTests|RielaAppWebRegistryProviderTests|WorkflowEditorLaunchTests|WorkflowEditorGenerationTests|WorkflowEditorRunEvidenceTests|RielaAppWebAPIRouteTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowEditorDefinitionTests
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --product RielaApp
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swiftlint lint --quiet --no-cache Sources/RielaWorkflowRegistry/WorkflowRegistryGraphQLProvider.swift Sources/RielaApp/RielaAppWebAPI.swift Sources/RielaApp/RielaAppWebWorkflowEditor.swift Tests/RielaAppSupportTests/WorkflowEditorDefinitionTests.swift
git diff --check
```
