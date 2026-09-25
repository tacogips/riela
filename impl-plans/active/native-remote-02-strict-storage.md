# NRE-02: Native remote execution

```json
{
  "planId": "NRE-02",
  "planPath": "impl-plans/active/native-remote-02-strict-storage.md",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCLI/CLIWorkflowSessionStore.swift",
    "Tests/RielaCLITests/CLIWorkflowSessionStoreResilienceTests.swift",
    "impl-plans/active/native-remote-nre-02-progress.md"
  ],
  "sharedPaths": [],
  "progressLogPath": "impl-plans/active/native-remote-nre-02-progress.md"
}
```

## Intent, authority and boundaries

Implement the smallest Riela-owned receiving path for the existing remote CLI,
using the accepted design at `design-docs/specs/design-native-remote-workflow-execution.md`.
Design acceptance is `comm-000006`, Step 3, decision `accepted`, no findings,
execution `codex-design-and-implement-review-loop-session-1`. Issue reference:
none supplied; title: Move remote workflow execution receiving boundary into
Riela. Codex-agent references: none; Cursor/reference divergence: not applicable.
The accepted strict-decoding revision from `comm-000004` is mandatory.

This artifact is authored in planning-only mode. All source/test tasks below
are deferred to implementation. Do not edit Swift, tests, README, historical
docs or the separate A1 checkout during this planning run. The runner-resolved
workflow provenance is authoritative; registry rediscovery/repair is not work.

Non-goals: another server, runner, queue, polling protocol, credential framework,
new library facade, legacy auto-improve compatibility, client timeout forwarding,
cleanup of historical references, deployment or branch integration. Preserve
ordinary local CLI runs, existing registry/session-control contracts and browser
security. P1 A2/A3 remains open until receiving tests pass on integrated source.
No external service is a dependency or publication target.

## Same-directory execution and evidence protocol

Before native Riela implementation/review fanout, independent reviewers must
accept this entire plan set and the accepted design plus all plans must be
committed and non-force pushed on `feat/native-remote-workflow-execution`.
This authoring step does not commit or push. No worktrees, private branches,
concurrent Git operations or worker commits. Wave 1 comprises NRE-01 and NRE-02;
wave 2 comprises NRE-03 after both pass their assigned gates. One integration
owner runs all serial reconciliation and finalization.

Before each edit, freshly read the target and dependency interfaces, record
SHA-256 before/after (ABSENT for a new file), and save an immutable intent snapshot
under `tmp/native-remote-implementation/<planId>/<attempt>/` containing accepted
requirements, intended patch, baseline HEAD and file hashes. Do not overwrite
snapshots. Recheck the current hash immediately before applying an edit. If it
changed, reread/reconcile rather than restoring an old full-file copy. Report
drift and affected paths. After join, NRE-03 compares each worker's post-hashes
and required behaviors against the actual tree, repairs lost edits serially,
and reruns affected tests. Hash equality alone is not behavioral verification.

Each worker writes only its own progress log (path in metadata), with task ID,
state pending/in_progress/complete/blocked, changed paths, intent snapshot path,
pre/post hashes, command, log path, terminal exit status, test counts and remaining
findings. Do not mark a task complete from a partial log or skipped test. Scratch
fixtures and command logs belong under repository `tmp/`; never stage them.
The workflow is ongoing until evidence handoff; remove disposable scratch only
after its evidence is consumed. Preserve complete logs until handoff.

Run foreground commands, redirect complete stdout/stderr to a per-command log
under the attempt directory, capture the real command exit status separately
and record it with the command. Do not mask failures with pipelines. Retain and
poll any yielded session through exit. Use sequential SwiftPM commands on this
shared checkout even when source work is independent: the integration owner
serializes build/test access to `.build`. Do not start a detached test/server.
Tests own and stop their listener and await all tasks before returning.

Reserve surface catalog/index edits, lockfiles, broad formatting, global plan
archiving and final Git operations for NRE-03 serial reconciliation. No dependency
or lockfile change is expected. Keep formatting limited to changed Swift files;
follow applicable Swift skill instructions during implementation. If a required
check is blocked, report its actual error and leave completion open.

## Context and deliverables

`CLIWorkflowSessionStore.load(sessionId:strictReadOnly:)` currently catches record
decoding failures and throws notFound even in strictReadOnly mode. Existing
resilience tests intentionally depend on that tolerant behavior. A receiving
summary must distinguish absent IDs from corruption without changing those
callers. Deliver one narrow strict-decoding read plus its regression tests.
This task is independent of NRE-01's GraphQL types.

## Tasks in order

1. **S1 — Strict read seam.** Add
   `CLIWorkflowSessionStore.loadStrictReadOnly(sessionId:) throws -> PersistedCLIWorkflowSession`.
   Reuse the existing query/decoder via a small private shared read helper with
   an explicit strict-decoding choice. Existing load defaults and loadAll/list
   behavior remain unchanged. Strict mode validates session ID, opens the
   database strictly read-only and never repairs/migrates/rewrites records.
   Absent database/table/row yields notFound. Distinguish rows.first absence
   from an existing row with absent/null record_json; the latter is sqliteFailed.
   Invalid JSON SQL failures, incompatible record shape, decode failures and
   stored/requested session-ID mismatch yield bounded sqliteFailed messages
   without raw record values. Propagate database open/query failures as storage
   errors. No schema migration or duplicated SQL path.
2. **S2 — Corruption versus absence fixtures.** Extend
   CLIWorkflowSessionStoreResilienceTests.swift using its test-owned SQLite store.
   Insert a row with safe known ID and valid JSON `{}` so SQL json() succeeds but
   PersistedCLIWorkflowSession decoding fails. Assert new strict read throws
   sqliteFailed. Query another absent safe ID in the same database and assert
   notFound. Test valid record, invalid ID, absent database/table, null text where
   the schema permits it, malformed JSON/query failure and mismatched stored ID.
   Retain existing tolerant load/loadAll warning-and-skip assertions. Verify rows
   and stored record bytes remain unchanged and no missing store is created by
   strict reads. Avoid permission-based failure fixtures that vary with UID;
   use deterministic malformed database/schema fixtures for open/query errors.

## Invariants and acceptance

strictReadOnly in the old API must not silently acquire new decoding semantics.
Only the new seam guarantees error preservation. It is a storage API, not an
authorization layer. It must not scan other roots. NRE-03 alone maps strict read
errors to GraphQL and verifies canonical runtime snapshots.

S1–S2 complete after all resilience tests pass, including the legacy targeted
corruption behavior. Deliver the new method signature and hash evidence to
NRE-03; no provider work or historical documentation edits belong here.

## Verification commands and evidence

```sh
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter CLIWorkflowSessionStoreResilienceTests
git diff --check
```

Record nonzero test count, zero failures and terminal exits/log paths. The
corrupt JSON fixture must exercise decoding failure rather than only SQL syntax
failure. NRE-03's GraphQL pair is an additional acceptance gate, not replaced by
these store-unit tests.
