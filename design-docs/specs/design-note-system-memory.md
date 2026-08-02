# Riela Note system memory and standalone-memory removal

Status: accepted after Step 3 review `comm-000285`; the confirmed Telegram SDK
decision is incorporated during Step 6 remediation after `comm-000322`

Issue reference: workflow execution
`codex-design-and-implement-review-loop-session-21`; intake `comm-000270`;
accepted-design revision `comm-000274`; Step 3 acceptance `comm-000277`; Step 4
plan `comm-000278`; Step 4 self-review `comm-000279`; latest Step 3 review
`comm-000282`; superseding Step 3 acceptance `comm-000285`; Step 7 implementation
review `comm-000308`; base commit `c967229`.

## Scope and outcome

This is one issue-resolution work package. Riela Note becomes the only durable
system-memory substrate. The standalone `Packages/RielaMemory` package, the
`riela memory` command, the workflow `memories` declaration, and every legacy
memory add-on are removed without aliases, compatibility decoding, or a
deprecation period.

The Note store gains a notebook-level `readOnly` default and automatically
contains one system-memory notebook. Ordinary Note callers respect the lock.
The two replacement persona add-ons used by the Slack, Telegram, Discord, and
Matrix agent trio-chat examples read and append notes through a narrow system
path. Their shared `shared-agent-trio-personas` workflow loses its memory
declarations and memory-root inputs and emits `noteEntries`. The web Notes
surface exposes the lock and a persisted Unlock action.

The standalone add-on IDs remain deleted. The confirmed operator decision adds
two narrow Note-backed generic successors, `riela/note-memory-save` and
`riela/note-memory-load`, for the retained Telegram SDK workflow. No successor
is provided for update, search, or raw/daily summarization. The
`examples/chat-memory-raw-and-daily-summary` example is deleted.

## Additional committed consumer disposition

The full-removal boundary applies to every live repository consumer, including
consumers missing from the original intake inventory. Their disposition is:

- `examples/matrix-agent-trio-chat/**` is retained and migrated exactly like
  Slack, Telegram, and Discord: remove workflow/node `memories`, replace its six
  read/write add-on IDs, use `noteEntries`, and update expected results and its
  mock scenario.
- `examples/shared-agent-trio-personas/**` is retained because the four
  provider-specific agent trio workflows reference it. Remove its workflow and
  node `memories`, `memoryRoot` inputs, legacy add-on descriptions, and
  `memoryEntries` schema/prompt language; the provider workers and agent adapter
  behavior otherwise remain unchanged.
- `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader+SharedNodeRefs.swift`,
  `Tests/RielaAdaptersTests/WorkflowStdioNodeExecutorTests.swift`,
  `Tests/RielaAppSupportTests/RielaAppSettingsSectionLayoutTests.swift`, and any
  other source/test matches are mechanical fallout repair: remove only dead
  memory model, root, mount, fixture, or expectation plumbing while preserving
  unrelated registry, stdio/container, and app behavior.
- `examples/catalog/chat-persona-and-agent-trio.md` and
  `examples/catalog/digest-gateway-and-reply.md` are updated together with the
  provider examples and shared persona workflow. Their storage, environment,
  payload, validation, and run instructions describe the Note-backed persona
  context contract and must not retain `persona-chat-memory`, memory-root, or
  `memoryEntries` guidance.
- `examples/event-sources/README.md` is a documentation-only consumer. Its
  Slack, Discord, Matrix, shared-persona, and Telegram SDK descriptions are
  updated to match the accepted example disposition. Event-source runtime,
  routing, and configuration behavior remain outside scope; only stale memory
  storage and environment guidance is removed or replaced.
- `examples/telegram-sdk-trio-chat/**` is retained under the confirmed operator
  decision in `design-docs/user-qa/qa-note-system-memory-telegram-sdk-example.md`.
  Its event stream is migrated to `riela/note-memory-save` and
  `riela/note-memory-load`; workflow/node `memories` declarations and standalone
  storage roots are removed while routing, SDK prompts, mocks, and parity remain.

## Record mapping

One stored system-memory entry is one note in the system-memory notebook. New
writers use the following mapping; this is a storage contract, not a legacy
API compatibility shape.

| Former memory concept | Note representation |
| --- | --- |
| `memoryId` | The system-memory notebook selected by its protected kind tag; the created `noteId` is the entry identifier. A supplied legacy identifier is retained only as `metaJSON.legacyMemoryId`. |
| `payload` | Human-readable primary content is `bodyMarkdown`. Structured fields that are not the primary text are stored under versioned `metaJSON`. |
| `tags` | Note tags. Persona entries always include `persona:<personaId>`; entry kind and importance may also be represented as classless tags. |
| `relatedRecordIds` | Resolvable note identifiers become `related` note links. Unresolvable external identifiers remain in `metaJSON.relatedRecordIds` and do not create placeholder notes. |
| `files` | Note file attachments using existing Note attachment validation, size limits, and local-path containment rules. |
| `workflowId` / `nodeId` | `metaJSON.workflowId` and `metaJSON.nodeId`; these are provenance, not notebook identity. |
| `registeredAt` | The note's `createdAt`; an explicitly supplied source timestamp is also retained as `metaJSON.recordedAt`. |

Persona-note metadata uses a versioned object with
`systemMemoryVersion`, `personaId`, `personaName`, `kind`, `importance`,
optional `source`, `workflowId`, `nodeId`, and `recordedAt`. Searchable content
stays in `bodyMarkdown`; metadata must not be the sole location of content the
persona reader needs to recall.

Existing `.riela/memory` databases and sidecar files are neither imported nor
deleted automatically. They become inert after the package and command are
removed. This follows the explicitly accepted breaking-change boundary and
avoids an implicit, unverified data conversion or destructive cleanup.

## Schema, identity, and bootstrap

`Sources/RielaNote/NoteStoreSchema.swift` appends schema migration v6:

```sql
ALTER TABLE notebooks ADD COLUMN read_only INTEGER NOT NULL DEFAULT 0;
```

The migration must not drop, rebuild, rename, or copy either `notebooks` or
`notes`. Fresh-schema creation includes the same column. Notebook hydration,
`Notebook`, GraphQL `Notebook`, and web `Notebook` expose it as `readOnly`.

`notebook-kind:system-memory` is appended to `systemNotebookKindTags`. During
`NoteService` bootstrap, after schema preparation and tag seeding, an
idempotent transaction looks up a notebook carrying that protected system tag.
If none exists, it creates `Riela System Memory` with `read_only = 1` and applies
the kind tag as a non-deletable system assignment. The tag is the stable
identity; callers must not depend on a generated notebook ID or the localized
title. If an existing tagged notebook is found, bootstrap preserves its stored
`readOnly` value so an explicit user unlock survives reopening the service.

The lookup and conditional creation occur in one write transaction. Multiple
matches are an invariant violation and must fail explicitly rather than choose
an arbitrary notebook.

## Read-only boundary

Notebook `readOnly` is a content and membership guard. By default, the service
rejects the following operations with `NoteServiceError.readOnly(notebookId)`:

- adding a note or ingesting pages into an existing read-only notebook;
- changing a contained note's body;
- deleting a contained note or deleting the notebook;
- attaching a file to a contained note or to the notebook; and
- changing note membership through any future move operation.

Note-level `readOnly` remains an independent, stricter guard for the individual
note. Unlocking a notebook does not unlock a note that is itself read-only.

The existing annotation and organization behavior remains available:
comments, note links, note tags, notebook tags, and notebook progress do not
alter page content and therefore keep their current policies. System kind tags
remain protected. Setting the notebook's own `readOnly` value is the explicit
lock-management operation and is not blocked by its current value.

The bypass is not a general Boolean exposed by `createNote`, ordinary Note
add-ons, CLI commands, GraphQL, or the web client. `NoteService` provides a
narrow system-memory append operation that resolves the protected notebook and
uses the shared insertion and attachment primitives under an internal system
write policy. Only `riela/note-persona-context-write` and the confirmed
`riela/note-memory-save` successor use this path. They bypass the notebook flag,
but do not bypass input validation, attachment limits, transactionality, or
note-level invariants.

## Additive API and web behavior

GraphQL additively exposes `Notebook.readOnly` and
`setNotebookReadOnly(notebookId:readOnly)`. All notebook query and mutation
projections include the field. The mutation persists the value, updates
`updatedAt`, returns the canonical notebook, and publishes the normal notebook
change notification.

The SolidJS notebook detail identifies the system-memory notebook from the
`notebook-kind:system-memory` tag and displays a Read-only badge when locked.
Content creation and edit controls are disabled while the notebook is locked.
An explicit `Unlock` button calls `setNotebookReadOnly(..., false)`; the
returned canonical notebook updates list, board, and detail state. An unlocked
system notebook offers `Lock` to restore the persisted default. Mutation
failure retains the prior canonical state and presents an error. The setting is
persisted per notebook, not session-local, so refresh and relaunch preserve the
user's choice.

Riela's system append path remains able to write whether the persisted value is
true or false.

## Trio-chat successor add-ons

These version-1 built-ins replace the example-facing persona behavior:

- `riela/note-persona-context-read`
- `riela/note-persona-context-write`

They live with the existing Note built-ins in
`Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift` and use the configured
Note root. They do not accept a memory root, memory database ID, or legacy
storage path.

The read add-on requires `personaId`, accepts `personaName` and a bounded
`limit`, resolves the system-memory notebook, and returns the newest matching
`persona:<personaId>` notes in deterministic order. A matching tag is accepted
only when the versioned metadata carries the same `personaId`, so generic or
manually tagged system-memory records cannot enter persona context. Its payload exposes
`notebookId`, `personaId`, `personaName`, `noteCount`, `notes`, bounded attachment
paths grouped by media type, `contextMarkdown`, `contextGuidance`, and the
existing bounded `handoffTrail`. Stored text is context only and never gains
priority over the user or system prompt.

The write add-on reads the persona worker's `noteEntries`, validates each entry,
and appends one note per entry through the narrow system path. Each entry has
non-empty `content` plus optional `kind`, `importance`, `source`, related note
IDs, and attachments. It returns `notebookId`, `entriesWritten`, `noteIds`, and
`recordedAt`, while preserving the existing provider-neutral reply and bounded
persona-handoff normalization needed by the trio-chat workflows. No write is
performed for an absent or empty `noteEntries` array.

The Slack, Telegram, Discord, and Matrix examples remove workflow-level and
node-level `memories` declarations and replace all six persona read/write node
add-on IDs and payload contracts. Shared persona nodes remove `memoryRoot` and
request `noteEntries`, not `memoryEntries`. The four mock scenarios, expected
results, shared persona prompts/schemas, both affected catalog entries,
`examples/event-sources/README.md`, `rielaExampleWorkflowNames()`, and parity
count change together. The event-source README change is documentation-only.

The Telegram SDK trio-chat uses two additional version-1 Note-backed operations:

- `riela/note-memory-save` renders a bounded payload, maps its readable summary
  to `bodyMarkdown`, stores the complete payload and workflow/node provenance in
  versioned `metaJSON`, applies stream/workflow/node tags, and copies bounded
  local attachments into the system-memory notebook through the narrow system
  append path. Requested attachment references fail closed when missing,
  malformed, or unsupported. Local-file containment compares symlink-resolved
  roots and targets so an in-root symlink cannot expose an out-of-root file.
- `riela/note-memory-load` selects only the requested stream and current
  workflow, applies a bounded newest-first limit, and returns records,
  `recordsText`, and materialized attachment paths. It never reads a standalone
  database or accepts a legacy storage root.

Internal persona/stream/workflow/node tag prefixes are reserved and cannot be
supplied as generic user tags. Loads require both the internal tags and matching versioned
metadata, so an extra or corrupted tag cannot cross a workflow, stream, or node
boundary. A save accepts at most 64 unique attachment references; overflow is
rejected before any referenced file is read or staged.

The logical `memoryId` input remains only as an alias for the Note stream ID;
the note ID is the stored record identity. No update or search operation is
added.

## Deletion and rollout constraints

Deletion includes `Packages/RielaMemory/**`, the CLI memory route and parsing,
legacy memory add-on files, `DeterministicWorkflowRunner+Memory.swift`,
`WorkflowMemoryValidation.swift`, every `WorkflowMemoryDeclaration` and
`memories` field/call site, the dedicated memory tests, the raw/daily example,
and `.riela/workflows/riela-memory-design-impl-review/**`.

`Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift` is split so its
workflow parsing remains. Shared test support is repaired rather than deleted.
The Matrix and shared-persona paths listed above are mandatory fallout repair.
The two affected example catalog documents and the event-source README are
mandatory documentation refreshes; this does not authorize event-source runtime
changes.
The confirmed Telegram SDK migration is part of this work package. Kanban
orchestration, graph-RAG, workflow registry internals, and event sources are
outside this design.

## Agent-backend reference boundary

Step 1 supplied no Codex reference repository root, URL, paths, commands, or
behavioral inputs (`codexAgentReferences` is empty), so this design does not
consult `../../codex-agent` or adopt reference-repository behavior. The existing
Codex-agent, Claude, and Cursor persona workers used by the trio-chat examples
remain unchanged; only their adjacent persona-context add-ons and payloads move
from memory-backed to Note-backed storage.

`Sources/CodexAgent/**`, `Sources/ClaudeCodeAgent/**`,
`Sources/CursorCLIAgent/**`, and official SDK adapter modules are outside the
file and behavior boundaries. Cursor-specific command construction, session
handling, model mapping, authentication, and stream normalization remain
isolated behind the existing Cursor adapter. There is no Cursor behavior mapping
or intentional divergence from a Codex reference for this work package.

## Validation and acceptance

Required verification, in order:

```bash
swift build
grep -rn 'RielaMemory\|riela/memory-\|chat-persona-memory\|WorkflowMemoryDeclaration\|persona-chat-memory\|memoryRoot\|RIELA_MEMORY_ROOT\|memoryEntries' Sources Tests Package.swift examples
swift test --filter RielaNoteTests
swift test --filter RielaCoreTests
swift test --filter RielaCLITests
riela workflow validate slack-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate telegram-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate discord-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate matrix-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate shared-agent-trio-personas --workflow-definition-dir ./examples
riela workflow run slack-agent-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/slack-agent-trio-chat/mock-scenario.json \
  --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run telegram-agent-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/telegram-agent-trio-chat/mock-scenario.json \
  --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run discord-agent-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/discord-agent-trio-chat/mock-scenario.json \
  --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run matrix-agent-trio-chat \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/matrix-agent-trio-chat/mock-scenario.json \
  --input '{"request":"Yui, give your opinion and ask Mika too"}'
cd web && bun run typecheck && bun run build && bun test src
```

The expanded grep command must produce no removed-contract output across source,
tests, package wiring, examples, catalog documentation, and event-source
documentation. Each trio-chat mock scenario, including Telegram SDK, must pass.
Focused
tests cover v5-to-v6 data preservation, fresh v6 creation,
idempotent bootstrap, duplicate-tagged-notebook rejection, notebook lock
enforcement, persisted lock/unlock, note-level lock independence, system append
bypass, persona read ordering/filtering, persona writes, and empty writes.

Do not run unfiltered `swift test`; the repository has known unrelated broad-
suite failures. Browser QA remains operator-owned and must use rebuilt release
and web artifacts.

## Risks

- Removing tolerant `memories` decoding intentionally makes authored workflows
  with that field invalid; the repository examples and fixtures must be fully
  updated in the same work package.
- A broad bypass would undermine notebook locking; review must verify that only
  the named system append API can bypass it.
- The v6 migration must be tested from a populated v5 fixture so a passing fresh
  schema test cannot hide data loss.
- Web state must adopt the mutation response and reject stale refreshes so an
  Unlock result is not reverted visually.
- Legacy memory data remains on disk but is no longer readable through Riela;
  this is accepted breaking behavior, not a migration failure.
- Catalog and event-source documentation can otherwise continue advertising
  removed memory roots and payloads; the expanded grep gate makes these
  documentation consumers part of the same atomic rollout.
- The Telegram SDK stream must remain workflow-isolated and bounded; a broad
  query or acceptance of a legacy storage root would silently restore the
  removed standalone-storage contract.

## Open questions

The five original questions and the Telegram SDK disposition are resolved
above. No open design question remains for this work package.
