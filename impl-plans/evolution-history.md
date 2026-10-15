# Evolution history implementation plan

Status: completed and verified (2026-10-15).

1. Inspected existing reviewed workflow snapshots and memory update paths.
2. Implemented a direction-checked, SHA-256-checked reverse byte delta for memory.
3. Added schema-v4 transactional memory history, historical reconstruction,
   attachment retention/integrity and restore with expected-head checking.
4. Added memory history/show-version/restore-version CLI commands.
5. Moved workflow snapshot persistence into RielaWorkflowRegistry and added
   schema-v2 shared content-defined SHA-256 chunks, retaining v1 readability.
6. Captured registry registration/update/delete observations and successful
   publications under existing locks, with transaction-bound recovery IDs.
7. Preserved history ownership across authored contract changes and anchored the
   first selected history root across later definition changes.
8. Added workflow history paging and returned-page body verification.
9. Updated documentation and verified memory, prompt, workflow, CLI, editor,
   corruption, storage efficiency, migration and interruption/recovery behavior.

Evidence: 33 standalone memory tests and 94 focused integration tests passed.
The RielaCLI target build, changed-file SwiftLint, feature diff checks and a real
executable memory save/update/history/show/restore smoke passed. See
[evolution-history-verification.md](evolution-history-verification.md) for the
requirement matrix, commands, source consistency check and limits.

Implementation files are grouped under Packages/RielaMemory, RielaCore history
models, RielaWorkflowRegistry history/registry publication, and the CLI memory
and workflow version surfaces. Existing unrelated sandbox/container work was
preserved. No commit or publication is part of this requested work package.

Storage intentionally retains history indefinitely. Snapshot chunks can remain
unreferenced after an interrupted publication. Small workflow files use one
chunk; memory's single-splice codec is not a minimum-edit algorithm. Workflow
listing scans headers but reconstructs only the requested page. These limits do
not prevent exact version reconstruction and are documented for operators.
