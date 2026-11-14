# NRE-02: Native remote execution

```json
{
  "planId": "NRE-02",
  "planPath": "impl-plans/completed/native-remote-02-strict-storage.md",
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
Mode: `issue-resolution`. Current Step 3 design acceptance is `comm-000004`,
source execution `step3-design-review-attempt-1-exec-4`, decision `accepted`,
with no findings. Issue reference: local request on
`feat/native-remote-workflow-execution`; no GitHub issue URL or number supplied.
Issue title: Implement native Riela remote workflow execution receiver.
Codex-agent references: none; Cursor/reference divergence: not applicable.
Preserve planning commit `9b1c935bc7e9fe4d586142e4ead035f84ef18ee7` and its
accepted strict-decoding correction. The earlier design's `comm-000004`
revision and `comm-000006` acceptance belong to the historical planning phase;
they are not the current Step 3 review decision.

This node revises plans only. Later implementation executes the source/test tasks
below under the effective issue-resolution input. Do not edit the separate P1
checkout or remove historical references. The runner-resolved workflow provenance
is authoritative; registry rediscovery/repair is not work.

Non-goals: another server, runner, queue, polling protocol, credential framework,
new library facade, legacy auto-improve compatibility, client timeout forwarding,
cleanup of historical references, deployment or branch integration. Preserve
ordinary local CLI runs, existing registry/session-control contracts and browser
security. P1 A2/A3 remains open until receiving tests pass on integrated source.
No external service is a dependency or publication target.

## Same-directory execution and evidence protocol

Before native Riela implementation/review fanout, Step 5 must accept this revised
plan set, and the serial workflow owner must commit the accepted design update
and all revised plans on `feat/native-remote-workflow-execution`, preserving
`9b1c935`. Before dispatch, the serial owner must non-force push this checkpoint
and verify that the live remote branch hash equals the accepted checkpoint hash.
Stop dispatch if the push fails, remote verification fails, or the hashes differ;
do not start implementation/review fanout with an unpublished checkpoint. Record
the checkpoint hash, verified remote hash, commands, complete log paths and
terminal exit statuses in the implementation handoff. This keeps the checkpoint
published before the final implementation commit, satisfying the final git-push
gate's limit of one unpublished commit. Do not rewrite the earlier planning
commit. This authoring node does not commit or push.

After the checkpoint commit, run these commands serially in the foreground:

```sh
git rev-parse HEAD
git push origin HEAD:refs/heads/feat/native-remote-workflow-execution
git ls-remote --exit-code origin refs/heads/feat/native-remote-workflow-execution
```

Require each command to exit 0; compare the single returned remote ref hash to
the recorded accepted checkpoint hash and confirm local HEAD still matches.
A successful push alone is insufficient evidence. Stop on any failure; never
force-push or dispatch workers while publication remains unverified.
Final reviewed code/docs are committed and non-force pushed by serial workflow
finalization after integration and review. No worktrees, private branches,
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
