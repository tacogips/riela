# Fresh run identity hydration

Issue: https://github.com/tacogips/riela/issues/156

New workflow executions previously decoded every CLI session and canonical runtime
snapshot, then hydrated canonical history again. Unrelated retained payloads could
consume most of an outer process budget before the new parent session existed.

For fresh runs only, initialize the execution cache with no historical sessions.
Read persisted session/tombstone identities, execution IDs, and communication IDs
as SQLite scalar metadata to advance the existing monotonic generator. Keep the
same lock-reserving generator and persisted-existence probes. No payloads are
rewritten or removed. Reserved nested children created by the current execution
continue to enter the cache through the existing canonical commit boundary.
Resume, rerun, and explicit recovery keep their current history hydration path.

Verification uses an isolated synthetic store containing multi-megabyte execution
and message payloads, a canonical-only reservation, an unreadable CLI identity,
and an active execution lock. It checks ID high-water marks, unchanged histories,
absence of unrelated hydrated sessions, and a provider-free command workflow.
Compare metadata-only startup against legacy hydration without a fragile timing
assertion. Run focused session recovery and nested-publication tests, build, and
changed-file SwiftLint on arm64 macOS. No live API or Notes operations are needed.
