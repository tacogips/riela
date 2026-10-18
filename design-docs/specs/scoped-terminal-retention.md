# Scoped terminal payload retention

Status: implemented for 0.2.16; independent source review and focused regression gates passed.

The retrieval cache bounds its own database. Workflow snapshots, message logs,
artifact snapshots and automatic inbox/outbox journals can independently contain
retrieved content. They require an explicit terminal-session policy. Existing
`gc` must not be used for this purpose because its age selection does not protect
running or suspended sessions.

## Command contract

`riela session prune --session-store PATH --artifact-root PATH --memory-root PATH
--workflow-id ID [--workflow-id ID ...] --retention-hours 24
--max-payload-bytes 268435456 [--dry-run] --output json`

All roots and at least one workflow ID are explicit. The command has no provider
calls, workflow execution, resume or implicit orphan termination. Missing roots
are empty; foreign schemas, symlinked managed paths and ambiguous lineage fail
closed. The policy applies only to selected workflow families. It does not apply
to durable user memory, persona records, checkpoints or export receipts.

## Eligibility and concurrency

Read metadata to construct complete root/parent session families. A family is
eligible only when every observed member is completed or failed, all observed
status projections agree, every parent/root reference resolves, and its root
workflow is explicitly allowed. Created, running, suspended, unknown or locked
families are protected. Unknown work/supervisor ownership must also be protected.
Age uses the newest persisted update in the family. A cap selects oldest eligible
families first, but cannot force deletion of protected data.

Acquire existing kernel-backed execution locks for every member in sorted order;
then re-read membership, terminal statuses and timestamps inside the runtime
SQLite transaction. A changed family is skipped. This prevents a resumed session
from racing deletion. Never infer that a session is terminal because a container
or process appears absent.

## Deletion and recovery

Commit compact payload-free tombstones before removing secondary copies. They
preserve session identity reservations and make an interrupted cleanup resumable.
Canonical runtime snapshot/message payloads, nested invocation payloads whose
entire family is selected, exact managed artifact snapshots/message rows, and
automatic memory rows marked `source=riela-node-manager` with matching workflow
and session IDs are the only eligible payloads. User-authored memory is excluded
regardless of age or root directory.

Secondary SQLite cleanup is transactional and idempotent. Filesystem cleanup is
limited to known generated relative paths below the explicit artifact root; no
recursive deletion based on payload-supplied paths. Attachment references are not
authority to delete external files. Physical SQLite reclamation follows successful
cleanup and does not truncate another writer's WAL. Interrupted cleanup remains
reported pending and is retried under the same execution locks.

The JSON report includes selected and removed families, pending cleanup,
protected families/reasons, charged payload bytes before/after, and whether the requested cap was achieved. Dry-run
performs no persistent writes or deletion. Tombstones contain no body text,
images, credentials, arbitrary diagnostic text or provider payloads.

## Required verification

Deterministic fake-clock tests cover age and cap ordering; paused/running/mixed
families; missing lineage; locked sessions; transaction recheck; interrupted
secondary cleanup and repeated cleanup; tombstone ID reservation; unrelated
memory/persona preservation; exact automatic journal deletion; artifact symlink
and traversal rejection; and physical SQLite reclamation. Independent review is
required before release. No real provider writes are needed for these tests.
