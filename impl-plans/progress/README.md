# Progress State Shards

`impl-plans/PROGRESS.json` remains a compact compatibility snapshot for existing `jq` commands.
The same state is split here into metadata, phase state, and one JSON file per plan so the
repository no longer stores the progress state as a 1000+ line source file.

- `meta.json` lists the shard layout and IDs.
- `phases.json` contains phase status values.
- `plans-index.json` lists `{id, file}` entries that map plan IDs to shard files.
- `plans/` contains one plan record per file, preserving the original plan IDs by path.
