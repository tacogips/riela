# Evolution history

Riela memory records keep a bounded history in the shared `VersionedHistory`
format. Each version stores either a compressed full value or a compressed
splice; neither encoding uses base64. Splices preserve exact bytes and verify
their source and result with SHA-256. Binary data and Unicode round-trip without
text patch heuristics. Legacy reverse-delta rows remain readable until their
record is written or `riela storage compact --apply` converts them.

Saving a record creates version 1. Updates to payload, tags, related record IDs
or attachments append a version in the same SQLite transaction. Identical
updates do not append a version. Replaced attachments remain available to older
versions. Attachment hashes are recorded in the same transaction and checked
when reading or restoring historical records; missing, replaced, or corrupt
attachment bytes cause failure. An existing schema-v3 database migrates in place; its first update
records the value immediately before that update as version 1. Changes made
before migration cannot be reconstructed.

```sh
riela memory history chat-memory --record-id 1 --limit 30 --output json
riela memory history chat-memory --record-id 1 --before-version 20 --output json
riela memory show-version chat-memory --record-id 1 --version 2 --output json
riela memory restore-version chat-memory --record-id 1 --version 2 --expected-head-version 7 --output json
```

Use `--memory-root <directory>` for a custom store. History returns newest first;
`--before-version` is an exclusive cursor. `show-version` only reads. Restoration
creates a new version, including when restoring the current value, and preserves
all intervening versions. It rejects a stale expected head rather than losing a
concurrent update. Read the latest history before choosing the expected head.

Memory history retention defaults to 2 versions and accepts 1...1000. The
`riela/snapshot-store` writes used for runtime state retain 1; workflow memory
declarations and CLI `save`, `update`, and `restore-version` can set
`historyRetention` or `--history-retention <n>`. A revision is the compare-and-
swap sequence number for the current head. A value version identifies a stored
value. They advance together for ordinary writes, but undo and redo move the
head to an existing value and advance the revision without creating a value
version.

Undo and redo require the current revision so a stale client cannot move a newer
head:

```sh
riela memory undo chat-memory --record-id 1 --expected-head-version 7
riela memory redo chat-memory --record-id 1 --expected-head-version 8
```

`show-version --diff-against <version|head>` and workflow-definition diffs use
the same structured diff representation. Requests for a known version outside
the retained window fail with `version_not_retained`; they do not silently
return a nearby value.

The Swift API exposes `RielaMemoryStore.evolutionHistory`, `recordVersion` and
`restoreRecordVersion`. History refers to Riela short-term record changes.
Kaiba long-term notes are owned by Kaiba; memory metadata and the separate KV
store do not currently use this record history.

Reading the head does not replay history. Reconstructing an old value uses one
database read transaction. Do not delete history rows or retained attachments
independently: older versions depend on them. Retention removes old versions
through the shared engine and reclaims database pages in bounded increments.

Workflow/prompt snapshots now use `content-addressed-chunks`: each file records
an ordered list of SHA-256 chunk references. Unchanged chunks are stored once
across versions. This format reconstructs a snapshot directly, with no forward
or backward patch traversal. Schema-v1 raw snapshots remain readable. Existing
`workflow versions`, `workflow version show`, `workflow version diff` and
`workflow restore` commands use the same snapshot identities and validation.
Do not remove the shared `chunks/` directory independently of snapshots.

Reviewed self-improvement and mutable registry/editor publication use the same
snapshot store. Registry updates and overwrite registrations capture the old
bundle before publication and the new bundle before transaction cleanup. Initial
registration captures the initial bundle; deletion captures the last bundle.
Snapshots named `registry-before-<transaction-id>` record the observed old value,
including a mutation attempt that later fails. `registry-after-<transaction-id>`
records a published replacement. Recovery verifies an existing snapshot with the
same ID before proceeding. Workflow definitions, prompt files, node files and
executable permissions are included by the existing bundle inventory contract.

Authored workflow contract-version changes remain in the same history owner.
Package identity/version checks remain exact. Direct filesystem edits outside
Riela's mutation APIs are observed at the next snapshot; Riela does not watch
arbitrary files continuously.

For mutable registry workflows, the first selected history location is recorded
in registry state. Later changes to `loop.selfEvolution.historyRoot` do not move
that existing lineage. This also preserves an existing custom location when the
workflow first enters automatic tracking. Moving history to another location is
an explicit migration, not a side effect of editing a workflow definition.

Workflow listing defaults to 100 snapshots, with at most 1,000 per request:

```sh
riela workflow versions my-workflow --scope user --limit 25 --output json
riela workflow versions my-workflow --scope user --limit 25 --before-snapshot <last-snapshot-id> --output json
```

`nextBeforeSnapshotId` provides the next cursor; a final full page can yield an
empty following page. Listing checks manifest integrity to order the history,
then verifies file/chunk bodies only for the returned page. Snapshot headers are
still scanned, so header traversal remains linear in the number of versions.
