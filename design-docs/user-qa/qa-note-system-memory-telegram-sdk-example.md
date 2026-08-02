# Telegram SDK trio-chat disposition for standalone-memory removal

## Issue reference

- Workflow: `codex-design-and-implement-review-loop-session-21`
- Intake: `comm-000270`
- Design/plan feedback: `comm-000279`
- Latest design-review feedback: `comm-000282`
- Branch/base: `feat/note-system-memory` at `c967229`
- Design: `design-docs/specs/design-note-system-memory.md`

## Decision required

What should happen to `examples/telegram-sdk-trio-chat/**` when the standalone
memory feature is deleted?

Recommended decision: delete the example in this work package and remove it
from `rielaExampleWorkflowNames()` and the expected mock-scenario count.

## Why confirmation is required

The example is a live parity-checked workflow with a mock scenario. Unlike the
Slack, Telegram Gateway, Discord, and Matrix agent trio examples, it does not
use persona read/write nodes or emit `noteEntries`. It:

1. saves every incoming Telegram event through `riela/memory-save`;
2. loads one shared recent-event stream through `riela/memory-load`; and
3. injects `recordsText` into plain-text SDK worker prompts.

The accepted design forbids a generic replacement for `riela/memory-save` and
`riela/memory-load`. Converting this example to existing Note add-ons would
change its data flow, payload contract, and conversation-context behavior; it
is not a mechanical rename to the two persona-context successors.

## Options

### A. Delete the example (recommended)

- Delete `examples/telegram-sdk-trio-chat/**`.
- Remove its parity name and decrement the expected mock-scenario count.
- Do not add a generic Note-backed memory successor.
- Preserve the separate Telegram Gateway agent trio example, which migrates to
  the accepted persona-context successors.

### B. Retain and redesign the example

- Pause this work package's deletion sweep.
- First add an accepted design for saving raw chat events and loading bounded
  shared conversation context through existing Note contracts.
- Specify notebook selection, event-to-note mapping, attachment handling,
  query ordering/filtering, prompt payload, and deterministic mocks.
- Do not recreate `riela/memory-save` or `riela/memory-load` under new names.

## Decision record

Status: CONFIRMED by operator 2026-08-01.

Selected option: NEITHER A nor B as written — operator chose a third option.

Operator decision (verbatim): 「riela note memory を storage として
memory-save, memory-load を可能とはするよ」

Interpretation, binding on this work package:

- Generic `memory-save` and `memory-load` capability is **retained**, not deleted.
- It is **re-implemented on top of Riela Note system memory as the storage
  backend** — the system-memory notebook is the store; there is no separate
  memory database, no `Packages/RielaMemory`, no `.riela/memory/*.sqlite`.
- Therefore `examples/telegram-sdk-trio-chat/**` is **NOT deleted**. It is
  migrated to the note-backed save/load add-ons, keeping its parity name and
  its mock-scenario count.
- The design statement that "the accepted design forbids a generic replacement
  for `riela/memory-save` and `riela/memory-load`" is **superseded** by this
  decision and must be revised in
  `design-docs/specs/design-note-system-memory.md`.

What still holds from the original scope: the standalone memory *feature*
(package, CLI route, memory SQLite store, `memories` workflow-schema
declaration, `WorkflowMemoryValidation`, `DeterministicWorkflowRunner+Memory`)
is still deleted outright. Only the save/load *add-on capability* survives, and
only as a thin note-backed successor.

Confirmed by / communication: operator answer relayed by the orchestrating
Claude Code session, 2026-08-01, in response to this QA file.
