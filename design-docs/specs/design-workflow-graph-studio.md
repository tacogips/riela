# Workflow Graph Studio and Live Agent Authoring

Status: implemented and acceptance-verified, 2026-09-10.
Date: 2026-09-09
User request: extend Riela's existing web workflow graph with ComfyUI-inspired
GUI authoring and agent chat that shows generated workflows in real time.

## Existing behavior and reference

`web/src/ops/OpsWorkflowsView.tsx` already renders a Command deck, focused
workflow graphs, step inspection, and execution links. `OpsScene` provides
pan, zoom, and fit. `WorkflowsView` provides revision-checked mutable-registry
JSON editing. This work extends those surfaces; the graph is not a new concept.

The [ComfyUI interface](https://docs.comfy.org/interface/overview) informs the
node canvas, connections, node settings, workflow creation, and navigation.
Riela keeps its own step-addressed execution model and provider contracts.

## Required user journeys

1. Enter Workflow studio from Command deck. Create a workflow, add agent
   steps, connect/disconnect ports, edit prompts and settings, choose the entry
   step, save, and reopen the graph.
2. Select an existing discovered workflow and open an editable version with
   its node/prompt bundle intact. Package-owned definitions must not be
   overwritten behind the package manager. An explicit editable copy starts
   deactivated; duplicate mutable IDs are reported without overwriting.
3. Arrange nodes, pan, zoom, close and reopen. Layout survives independently
   of workflow definition saves and does not affect execution revisions.
4. Ask the editor agent to create or change a workflow. See intermediate
   generated definitions on the same canvas while the generation is running.
   Review, undo, edit, and explicitly save the result. Stop and error states
   must remain recoverable without losing the local draft.
5. Execute a saved workflow from the studio with explicit input variables.
   Keep the graph visible while showing the run's current step, status and
   logs. Selecting a step shows actual input/output JSON for the selected
   execution attempt, including failed attempts where recorded. These values
   must come from persisted runtime evidence, never inferred from the editor
   definition or replaced with summary-only placeholders.

## Definition and layout separation

The execution document contains workflow semantics only: nodes, steps,
transitions, defaults, prompts, and other existing fields. The editor performs
lossless transformations and retains fields it does not understand. A canvas
card represents a step, because multiple steps can reference one reusable
node. Layout is therefore keyed by step ID, not by an array index.

Layout is a separate versioned record:

```json
{"version":1,"positions":{"step-1":{"x":0,"y":0}},"camera":{"offsetX":0,"offsetY":0,"scale":1}}
```

The initial persistence adapter is browser local storage, namespaced by
profile identity and workflow origin. This is device/browser-local layout,
not shared cross-device state. Workflow JSON and GraphQL mutations never
contain layout. Layout writes never call a workflow save or change its
revision. Existing step positions survive AI changes; new steps receive
deterministic initial positions. Corrupt storage and quota denial are handled
without preventing editing, with a visible persistence warning on failure.

## Editing and persistence

Reuse `OpsScene` camera math and controls. Interactive nodes suppress scene
panning, and screen coordinates are transformed into graph coordinates for
dragging. Provide accessible port actions, step settings, Undo/Redo, and a
complete JSON escape hatch. Never silently drop fanout, cross-workflow,
manager, or unknown fields. Unsupported deletion dependencies need actionable
feedback. Run structural checks before save and honor server diagnostics.

Mutable saves retain the loaded definition revision. A conflict preserves the
draft and offers an explicit reload path. A successful save updates the target
revision without remounting the editor or restoring the original definition.
Profile changes and navigation must not let stale asynchronous responses apply
to another editor. Existing protected-value retain handles must remain opaque;
do not replace them through an empty prompt field.

The explicit, profile-checked editor-definition endpoint uses an authoring
projection: inline add-on name/version and prompt/model settings are visible
when the display-text policy permits them. Unknown configuration and environment
bindings remain opaque retain handles. The normal registry projection is
unchanged. A protected prompt/model is visibly marked as hidden and retained
unless the user types a replacement.

Registry mutation responses are metadata-only. Every successful save/activation
must fetch the current editor definition and revision before permitting another
write or run. This refresh replaces obsolete retain handles and starts a new
Undo history, without remounting the canvas or losing chat history/layout.
If refresh fails after a successful mutation, preserve the draft, disable
further mutation/launch, and offer an explicit reload; never retry registration
as though the accepted save had failed. Existing workflow identity is not an
inline rename field.

Retained values inside top-level nodes/steps follow the same stable ID when
an earlier element is deleted or the array is reordered. Authentication still
uses the original node/step's JSON pointer and the original revision, origin
and principal. Moving a handle into a different node or field remains invalid.
For retained transition fields (for example fanout configuration or a hidden
label), match the original authenticated fields within the same source step
and exact destination/resume route when array indices shift. A different route
cannot reuse that handle. Riela transitions do not have an authored `when`
condition field; preserve the actual transition schema.

File-backed agent nodes have an explicit settings dialog, available only for
a saved graph. Read the node payload and primary prompt asset under registry
coordination; require both the workflow revision and a digest of the loaded
assets on save. Preserve all other payload fields. Write a deterministic,
content-addressed derived node JSON and update `nodeFile` in one existing
registry workspace transaction. Replacing the primary prompt stores it inline
in the derived node and removes only its old `promptTemplateFile` reference.
Original resources remain intact; no existing shared file is overwritten.
The changed workflow reference produces a new definition revision. A normal
save/reopen reads the new canonical definition. Cancel confirms unsaved dialog
edits, while the modal prevents accidental edits to the underlying graph.
Editor text is returned byte-for-byte when permitted by redaction policy, not
as the display policy's whitespace-compacted summary.

## Agent architecture

Use the existing native assistant provider/model configuration and adapter
event stream. The authoring API creates a bounded, profile-owned generation
session. The agent receives the current draft and returns newline-delimited
JSON records: `message` for chat text and `definition` for a complete cumulative
definition after each meaningful change. Parse complete records as assistant
events arrive; incomplete records never become graph state.

The host performs at most 12 real provider rounds under one 600-second
deadline. Each round makes one meaningful edit and ends with a `continue`
boolean record. It publishes the current complete definition before asking
for the next edit. This supports vendor CLIs that buffer entire replies:
intermediate graphs are real results available while the next provider turn
runs, not a delayed animation of a finished graph. Assistant event records are
collected when the adapter's returned payload is only an extracted summary.
The entire generation is limited to 1 MiB of protocol output. The browser
includes at most 12 prior user/assistant messages for follow-up context.

The browser polls the session snapshot at a short interval while running and
renders only newer revisions. Polls are serialized, cancellable, and scoped to
the mounted editor. AI changes are drafts, not registry writes. During live
application, manual semantic edits must be disabled or protected by a draft
revision comparison. Preserve a single undo boundary for the generation.
Late completion after cancel/unmount/profile switch cannot replace local state.

API requests retain Host/Origin/CSRF checks and require the active profile.
Generation IDs are unguessable and profile checked. Bound concurrent sessions,
retention, request/response sizes, output accumulation, and provider execution
time. Cancellation marks the session terminal and cancels the provider task.
Do not expose thinking/tool events as chat messages. Provider failures appear
as user-facing errors without exposing environment values.

## Runtime input/output inspection

`WorkflowStepExecution.inputSnapshot` records prepared invocation data before
dispatch, separately for each execution attempt. Agent records include the
rendered prompt, available fresh/resumed prompt variants, system prompt,
arguments and merged variables. Stdio/add-on records include request variables
and their resolved input payload; output-projection records include their
resolved payload. Process credentials/environment are not copied into this
record. Older sessions retain `nil`, displayed as “not recorded”, rather than
reconstructing an input from a newer workflow definition.

The editor evidence API uses the active profile's read-only persisted runtime
store. Run summaries list up to the latest 500 attempts, with the total count
visible. Actual input and accepted output are retrieved for one execution ID
at a time through a separate profile-checked endpoint. A 512 KiB response
limit produces an explicit error, never a silently truncated value. Existing
summary APIs keep their redacted contracts. Failed attempts without accepted
output display that absence and their failure reason explicitly.

The inspector remains on the editor page, allows opening a session ID, and
filters attempts when a graph step is selected. Polling uses the existing
visibility-aware, cancellation-aware controller. The editor can also launch
the saved workflow and automatically open its session; attempt status appears
on graph cards while the run is observed.
Runs belonging to a different workflow remain inspectable but do not update
graph highlighting or use its step filter. The inspector warns that actual
recorded values may include sensitive workflow data.

Launch requires an exact active mutable origin, a saved definition revision,
an explicit working directory and a JSON input object. Unsaved changes disable
launch. `prepareEditorExecution` checks identity, activation and revision under
registry read coordination and captures the standard resolver's bundle. The
application links the existing `RielaCLI` runtime library and runs that bundle
through `WorkflowRunCommand` with the profile-owned session store. A bounded
launch registry captures the first root session ID from ordered CLI records
and exposes status; it never substitutes an in-memory mock for persisted I/O.
Deactivated workflows have an explicit Activate action before execution.

## Acceptance evidence

| Requirement | Evidence required |
| --- | --- |
| Existing graph entry and editing | Browser journey from Command deck through create/edit/save/reopen |
| Lossless definition transformations | Tests for extra fields, shared nodes, fanout/manager references, connections |
| Separate persisted layout | Tests plus drag/reopen browser check; saved definition contains no coordinates |
| Agent intermediate rendering | Incremental adapter/store test and browser test that sees changes before completion |
| Real provider integration | Live adapter generation with intermediate or terminal output, recorded separately from mocks |
| Concurrency and recovery | Conflict, cancellation, delayed response, profile isolation, invalid record tests |
| Execute inside editor | Real run launched from saved revision with caller inputs, terminal status and same-screen graph |
| Inspect actual I/O and logs | Real persisted step attempt input/output displayed beside graph, loading/empty/error states |
| Build and lint | Web typecheck/lint/test/build, relevant Playwright, Swift build/tests/SwiftLint |

## Acceptance result

The [acceptance audit](../user-qa/qa-workflow-graph-studio.md) records evidence
for every required journey and distinguishes mocked browser contracts from
real application-route, registry, runtime and provider verification. The final
gate passed 79 web unit tests, 28 browser tests and 38 focused Swift tests,
including a live one-step intermediate graph, two-step completion and real
registration/reopen. RielaApp and web production builds passed. No required
implementation work remains within this design. Deliberate limits (local
layout storage, bounded generation/inspection and protected settings) remain
documented rather than implied away.
