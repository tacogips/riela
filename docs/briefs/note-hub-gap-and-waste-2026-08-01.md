# Riela Note hub gap-and-waste analysis (2026-08-01)

## Decision context

Riela Note already owns durable notebooks, notes, tags, links, attachments,
comments, search, GraphQL/REST access, workflow add-ons, and the SolidJS
workspace. The accepted system-memory brief and D20-D24 make Note the single
knowledge substrate: standalone RielaMemory is removed without touching stored
`.riela/memory/` data, and new system memory is stored as notes in one reserved
read-only notebook.

## Missing capabilities

| Capability | Evidence | Rationale | Decision | Value | Risk | Disposition |
| --- | --- | --- | --- | --- | --- | --- |
| Reserved system-memory notebook | Note schema v5 has no system-memory kind or notebook-level lock | Agents need a stable Note-owned knowledge target that humans can inspect | add | high | medium | Implement D20-D24 in this work package |
| Notebook-level content lock | Only notes have `read_only` | A system notebook needs a durable default lock while retaining organization metadata | add | high | medium | Add schema v6 and NoteService enforcement |
| Capability-shaped system writes | Ordinary Note writes cannot safely bypass a locked notebook | Agent memory writes must work while locked without exposing a public bypass | add | high | medium | Add narrow system-memory save/update service operations |
| Note-backed memory add-ons | Trio workflows depend on legacy memory add-ons | Workflow agents need exact, testable Note contracts for save/update/load/search and persona context | add | high | medium | Add six exact `riela/note-*memory*` successors |
| Human lock control | Web notebooks cannot persist a notebook-level lock | Humans need an explicit, durable unlock/relock action | add | high | low | Add GraphQL, same-origin REST, and SolidJS controls |
| Unified hub capture and retrieval ergonomics | Note has several ingestion/search surfaces but no single operator-facing capability map | Missing discoverability makes an otherwise complete hub feel fragmented | simplify | medium | low | Document current entry points; defer broader UX work |
| Revision history | Note updates overwrite content | Hub users may eventually need audit/rollback | add | medium | medium | Follow-up; out of this bounded work package |
| Vector retrieval | Current search is FTS/tag based | Semantic retrieval may help large knowledge stores | add | medium | high | Follow-up behind the existing graph-RAG design boundary |

## Waste and redundancy

| Surface | Evidence | Rationale | Decision | Value | Risk | Disposition |
| --- | --- | --- | --- | --- | --- | --- |
| `Packages/RielaMemory` | Separate package, SQLite schema, file sidecars, and root SwiftPM dependency | Duplicates Note persistence, search, metadata, relationships, and attachments | remove | high | high | Delete package and dependency links; leave operator data untouched |
| `riela memory` CLI | Separate command/parser/models and injected runner | Duplicates Note's GraphQL-backed CLI and preserves a second storage concept | remove | high | medium | Delete without compatibility command |
| Legacy memory add-ons and prefix dispatch | Four generic, two persona, and one raw-summary add-on plus `riela/memory-` catch-all | Prefix dispatch is broad and every operation duplicates Note boundaries | remove | high | high | Replace required behavior with six exact Note ids |
| Workflow `memories:` schema/runtime | Declarations thread through model, validation, runner, publication, persistence, prompts, and test support | Storage configuration embedded in workflow schema is redundant once add-ons resolve Note roots | remove | high | high | Delete fields and repair shared callers atomically |
| Raw/daily-summary example | Dedicated example exists only for the removed legacy adapter | Demonstrates an unsupported storage surface | remove | medium | low | Delete example and catalog/parity entries |
| Duplicate memory configuration terminology | Examples and mocks use memory-root/database vocabulary | Conflicts with the Note-owned contract and obscures notebook/note identity | simplify | medium | medium | Move surviving examples to note-root/notebook/note terminology |
| Multiple broad Note facades | NoteService and some adapters are large | Splitting during deletion would increase regression scope | keep | low | medium | Keep current boundaries; record responsibility extraction as follow-up |
| Existing Note metadata features | Tags, comments, links, progress, search, graph-RAG | These are complementary hub primitives, not redundant memory features | keep | high | low | Preserve behavior unchanged |

## Ranked implementation decision

1. Implement the memory-to-Note fold, schema-v6 lock, system-write capability,
   six successor add-ons, migrated examples, and synchronized API/web lock UI.
2. Remove every standalone-memory code/schema/example seam and verify no live
   references remain.
3. Defer revision history, semantic/vector retrieval, broader capture UX, and
   NoteService responsibility extraction. They are not small enough to add
   safely before the required Phase 2 gates are green.

## Guardrails and verification

- Use only additive `ALTER TABLE notebooks ADD COLUMN read_only ...` migration.
- Never enumerate, migrate, rewrite, or delete `.riela/memory/` data.
- Preserve allowed metadata/navigation operations on locked notebooks.
- Keep the privileged bypass internal to typed system-memory operations.
- Keep example names, mock counts, catalog entries, and parity fixtures atomic.
- Require Swift build and focused Note/CLI/Core tests, example validation,
  independent TypeScript typecheck, web tests/build, source deletion audit,
  SwiftLint, clean diff, logical local commits, and clean final status.
