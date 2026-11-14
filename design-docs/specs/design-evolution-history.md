# Evolution history

Status: implemented and verified (2026-10-15).

## Required behavior

Track mutable memory, self prompts and workflow bundles through their owning
stores. Reconstruct every recorded version exactly, including deletion, empty
files, Unicode, binary attachments and executable permissions. A restore creates
a new version and never removes intervening history. Existing history remains
readable. Changes made before tracking was introduced cannot be invented.

Before this change, workflow snapshots contained complete per-snapshot object directories;
`WorkflowSelfImproveVersioning` records reviewed mutations through those
snapshots. Prompt files are included in the owned bundle inventory. Memory
`save` inserted records, while `update` overwrote payload/tags/references and
removed replaced attachment files. Neither operation previously recorded versions.

## Storage contract

For memory, keep the latest complete value and immutable reverse deltas. Each delta has
`schemaVersion`, `direction: next-to-previous`, `fromVersion` (newer),
`toVersion` (immediate predecessor), source/result SHA-256 hashes and byte
counts. Reconstruction starts at the stored head and follows decreasing version
numbers. Reject missing edges, wrong direction, unsupported formats, incorrect
version identities, malformed ranges and hash mismatches. Never ask an AI to
infer which way a patch applies.

The first codec is a deterministic byte splice: unchanged prefix and suffix
lengths plus the previous middle bytes. It runs in linear time, preserves binary
data, and stores small localized edits proportionally to the change. Distant
edits can retain a large middle span; a future codec may use multiple splices
without changing the directional/version contract. It makes no claim of minimal
diff size. Empty and identical values have valid representations.

Workflow and prompt snapshots use a different explicit format:
`schemaVersion: 2, storageFormat: content-addressed-chunks`. Their per-file
objects contain `sha256-chunks-v1` descriptors with ordered chunk hashes and a
byte count. Content-defined boundaries (2–16 KiB) resynchronize after insertions.
Immutable SHA-256 chunks are shared across versions, so unchanged content is
stored once; reconstruction concatenates the listed chunks and verifies the
complete file hash. There is no patch direction to infer in this format.
Compared with reverse chains, this preserves immutable snapshot publication and
bounded reconstruction work independent of the number of versions. Small files
occupy one chunk; a change to a small file stores its new content. Schema-v1 raw
objects remain readable. Existing historical bytes are not rewritten implicitly.

Chunk publication precedes atomic snapshot publication. A failed publication
can leave reusable unreferenced chunks, but cannot expose a partial snapshot.
Concurrent publication of identical chunks is accepted only after immutable
byte equality verification. There is no chunk garbage collector yet.

Atomicity is owned by persistence, not the codec. Head replacement and insertion
of its reverse delta must commit together, with serialized writers and expected
head checks. Reads reconstruct from one consistent transaction. Failure must
leave either the old head/history or the complete new head/history. Do not prune
edges required by retained versions. Latest reads must not replay history.

Memory versions include payload, tags, related record IDs and attachment
metadata. Attachment content remains at its retained unique stored path after
replacement; separate SHA-256 records bind those paths to exact bytes. History
read and restore verify attachments. Unchanged attachments are not copied per
version. The hash records commit with the corresponding record/delta changes.
Workflow versions include the full owned inventory (prompt/node/definition files
and modes); runtime session/step and reviewed change-set identifiers provide
provenance. Baseline existing values on their first tracked mutation.

Expose bounded history listing, version reconstruction and explicit restoration
through the existing memory/workflow command surfaces. Machine-readable outputs
must expose direction, source/target version IDs, timestamp and provenance.
Restoration must reuse existing validation and authorization boundaries.

## Completion evidence

Required gates: codec round trips and malformed input rejection; transactional
memory update/history rollback and concurrent writers; workflow and prompt
mutation integration; old-store compatibility; attachment retention; CLI list,
show and restore; storage-size assertions for repeated localized edits; focused
Swift suites, build, SwiftLint and a requirement-by-requirement completion review.

Store integration, command surfaces and integration gates are complete. See
`impl-plans/evolution-history-verification.md` for requirement-by-requirement
evidence and documented storage limits.
