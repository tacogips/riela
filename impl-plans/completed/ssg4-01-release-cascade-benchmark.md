# ssg4-01-release-cascade-benchmark: release cascade tests, ≥5x benchmark, reduced writes by default

**Status**: Completed (2026-10-30; accepted by the session-566 test-integrity, adversarial and integration reviews; progress `impl-plans/progress/ssg4-01-release-cascade-benchmark.md`)
**planId**: ssg4-01-release-cascade-benchmark
**dependsOn**: none (wave 1). Accepted dependencies already in the tree:
`ssg2-01` writer, `ssg2-02` hydration, `ssg2-06` test isolation (archived in
`impl-plans/completed/`, accepted in sessions 562/563).
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§1.3, §3.2 (Release, Cascade, Release invariants), §3.5 (Write switch), §3.6,
§9 (`RuntimePayloadReleaseTests`, `RuntimePayloadBenchmarkTests`, Writer test
review, gate commands), §13 row `ssg4-01`
**Supersedes**: `impl-plans/completed/ssg3-01-release-cascade-benchmark.md`
(never implemented) and `impl-plans/completed/ssg2-03-fragment-release-benchmark.md`
(its progress log `impl-plans/progress/ssg2-03-fragment-release-benchmark.md`
is history; do not continue it)
**Progress log**: `impl-plans/progress/ssg4-01-release-cascade-benchmark.md` (new)
**Evidence root**: `tmp/ssg4/ssg4-01-release-cascade-benchmark/` (gitignored)

**Build outputs**: SwiftPM/Xcode build products and caches under .build/, .swiftpm/ and the temporary HOME, and evidence logs under tmp/ssg4/<planId>/, are authorized untracked outputs of every plan's verification commands; artifactRoots stays [] and these writes are never an implementation blocker.

**writePaths**:
- `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`
- `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`
- `Tests/RielaCoreTests/RuntimePayloadFragmentWriterTests.swift`
- `Tests/RielaCoreTests/RuntimePayloadHydrationTests.swift`
- `Tests/RielaCoreTests/RuntimePayloadReleaseTests.swift` (new)
- `Tests/RielaCoreTests/RuntimePayloadBenchmarkTests.swift` (new)
- `Tests/RielaCLITests/RuntimePayloadReadParityTests.swift`
- `Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift`
- `Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift`
- `Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift`
- `impl-plans/progress/ssg4-01-release-cascade-benchmark.md`

**sharedPaths**: none

## Intent and context

The session store now writes execution payloads in the reduced form: large
`inputSnapshot` subtrees become content-addressed fragment rows in
`workflow_runtime_payloads`, linked by `workflow_runtime_payload_refs(root_session_id,
parent_digest, digest)`. Two pieces of the previous plan `ssg2-03` are
already in the working tree but have never been tested:

1. `SQLiteWorkflowRuntimePersistenceStore.writesReducedExecutionPayloadsByDefault = true`
   (`Sources/RielaCore/RuntimePayloadFragmentEncoder.swift:148-154`, next to
   the task-local `writesReducedExecutionPayloadsOverride`). The only reader
   is `executionPayload` (`+SessionFamily.swift:243-247`).
2. The reference-aware cascade:
   `releasePayloadIfUnreferenced(rootId:digest:in:)` (`+SessionFamily.swift:136-159`)
   and `releaseUnreferencedPayloads(rootSessionId:in:)` (`+SessionFamily.swift:161-197`);
   the public wrapper is `releaseUnreferencedPayloads(rootSessionId:)` (~line 587).

The operator renamed `testDefaultWritesFullPayloadAndNestedWritesReduced` to
`testFullPayloadModeWritesFullPayloadAndNestedWritesReduced`
(`RuntimePayloadFragmentWriterTests.swift:58-88`). It pins the override to
`false` for the root save and `true` for the nested reservation. Evidence
from session 562 (`tmp/ssg2/reconcile-session-562-wave-002/reconcile-summary.json`):
with the default already `true`, the old version of that test was the only
failure. `SQLiteRuntimeExecutionRowsTests`, `RuntimePersistenceBoundedWriteTests`,
`CLIWorkflowSessionEnvelopeTests`, `RuntimePayloadReadParityTests`,
`RuntimePayloadHydrationTests`, `TerminalRetentionTests` and
`SQLiteWorkflowMessageLogTests` all passed.

This plan proves the cascade with tests, keeps the default `true`, reviews
the operator's edit, and adds the ≥5x benchmark. Design §3.2 "Cascade
review" already explains why the cascade should hold for fragments shared
by several parents; the tests here are the proof.

The previous plan (`ssg3-01`) was never run: session 564 stopped because it
treated `.build/` writes as unauthorized. Building and testing is required
and authorized (see **Build outputs** above). Do not report SwiftPM cache,
`.build/`, `.swiftpm/`, temporary HOME or `tmp/ssg4/` writes as a blocker or
as out-of-writePaths changes.

## Non-goals

- Do not change the encoder rule (1024-byte threshold, `$rielaPayloadRef`,
  `_rielaPayloadRefs`), hydration, schema or migrations.
- Do not touch `TerminalRetentionExecutor`, tombstone triggers, the doctor, docs,
  any file under `Sources/RielaCLI`, or any accepted `ssg2` file outside
  writePaths.
- Do not add a user setting, environment variable or configuration for the
  write switch.
- Do not change production code unless a test in this plan shows that a
  §3.2 invariant is violated, meaning a referenced row was deleted or an
  orphan row was left. A row that survives because something still
  references it is never a violation. If you do change it, keep the change
  minimal and record the failing case in the progress log. A production
  change must never weaken a `NOT EXISTS` guard, and none is authorized for
  `testNestedRefReplacementKeepsFragmentsSharedWithRootRows`.
- Do not edit `RuntimePayloadReadParityTests.swift`,
  `SQLiteRuntimeExecutionRowsTests.swift`, `RuntimePersistenceBoundedWriteTests.swift`,
  `RuntimePayloadHydrationTests.swift` or `SQLiteRuntimeSchemaMigrationTests.swift` unless one of their assertions fails
  because of the default form. The only allowed edit is wrapping the affected
  save in `writesReducedExecutionPayloadsOverride.withValue(<form>)`. Never
  loosen an assertion.
- No commit, stash, checkout, reset or restore. No version bump.

## Invariants (design §3.2), checked after every step in the release tests

Within one `root_session_id`:

1. A payload row referenced by `workflow_runtime_executions.payload_digest`,
   `workflow_nested_invocation_refs.digest` or `workflow_runtime_payload_refs.digest`
   is never deleted.
2. No refs row lacks its parent payload row (`parent_digest`) or its child
   payload row (`digest`).
3. After saving a terminal root, or after `releaseUnreferencedPayloads`, no
   payload row is unreferenced by all three tables.
4. A release in one root never changes another root's rows.

Implement the checks as one private test helper that runs three SQL
`SELECT count(*)` queries: dangling parent, dangling child, and unreferenced
payload. Use the predicate from `releaseUnreferencedPayloads`. Each count must
be 0.

## File-level changes

### 1. `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`

- Expected: no change. Confirm `static let writesReducedExecutionPayloadsByDefault = true`
  is present, and record that in the progress log.

### 2. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`

- Review only. Keep these properties:
  - The parent is deleted under all three `NOT EXISTS` guards before its refs
    rows are deleted by `parent_digest`.
  - Children are released through the same guarded function, never deleted
    directly.
  - The sweep runs in two fixed rounds with no unbounded loop, and returns the
    summed `byte_count` of every deleted row.
- Change it only if a release test fails, and record the case.
- `persistNestedReferences` (same file, ~line 199) is the nested caller of
  the release and is also in scope. The other caller,
  `+NestedInvocations.swift:599`, is **not** in writePaths. If the nested
  test fails because of that file, stop and report it as blocked with the
  failing case; do not edit it.

### 3. `Tests/RielaCoreTests/RuntimePayloadFragmentWriterTests.swift`

- Keep `testFullPayloadModeWritesFullPayloadAndNestedWritesReduced` unchanged.
  It is correct: it pins both forms explicitly, so it does not depend on the
  default.
- Add `testDefaultWritesReducedPayloads`. With no override, saving one execution
  whose `inputSnapshot` holds a 2048-byte string writes at least one
  `workflow_runtime_payload_refs` row, and the execution's stored JSON contains
  `_rielaPayloadRefs`. Reuse the file's `makeRoot`, `database` and `execution`
  helpers.

### 4. `Tests/RielaCoreTests/RuntimePayloadReleaseTests.swift` (new, `final class RuntimePayloadReleaseTests: XCTestCase`)

Imitate `RuntimePayloadFragmentWriterTests` (temporary root under
`NSTemporaryDirectory()` + UUID, removed in `defer`; fixed
`Date(timeIntervalSince1970: 1_700_000_000)`; `@testable import RielaCore`;
`SQLiteDatabase.open(... .writableRuntimeStoreDefault)` for SQL checks).
Every case wraps its writes in
`SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(true)`.
Build large values from distinct deterministic strings of at least 2048
bytes, for example `String(repeating: "a", count: 2048)`. The
`inputSnapshot` object that holds the references stays under 1024 bytes, so
only the strings are hoisted. Cases:

- `testRewrittenExecutionReleasesOnlyItsUniqueFragment`: executions E1
  `{shared: S, unique: U1}` and E2 `{shared: S, unique: U2}` are saved
  `running`. E1 is rewritten to `{shared: S, unique: U3}` and saved again.
  Expected: E1's `payload_digest` changed, the old parent row is gone, U1's
  fragment row and its refs rows are gone, and S, U2 and U3 exist. The
  invariant helper passes and `load` equals the saved session.
- `testTruncationReleasesFragmentsOfRemovedExecutions`: saved with 3
  executions (each with a unique value, two sharing S), then saved with only
  the first. Expected: only the fragments referenced solely by executions 2
  and 3 are gone. The invariant helper passes.
- `testNestedRefReplacementKeepsFragmentsSharedWithRootRows`:
  - **Shared root.** Root session `R` (`sessionId: "root"`). The child
    `WorkflowSession` sets `sessionId: "child"`, `parentSessionId: "root"` and
    `rootSessionId: "root"`, so the child's execution rows, nested refs and
    fragments all live under `root_session_id = "root"`. Build the
    reservation as in `Tests/RielaCLITests/StorageDoctorCommandTests.swift:117-126`
    (`WorkflowNestedInvocationReservation(parentSessionId:parentStepId:resumeStepId:sourceStepExecutionId:branchId:childSnapshot:)`).
    Filter every row assertion by `root_session_id = 'root'`.
  - (a) `R` saves E1 `{shared: S}`.
  - (b) `reserveNestedInvocation` with a child execution
    `{shared: S, unique: N1}`. This also saves the child snapshot as
    `workflow_runtime_executions` rows
    (`+NestedInvocations.swift:150`, `save(reservation.childSnapshot, in: db)`)
    and writes the reservation's nested refs. Read the invocation key from
    `workflow_nested_invocations`.
  - (c) Inside one transaction from `store.openDatabase()`, call
    `persistNestedReferences(_:invocationKey:role:in:)` for that key with
    `role: "reservation"` and a child execution `{shared: S, unique: N2}`.
    This is the path legacy conversion uses; a second
    `reserveNestedInvocation` returns the existing record and rewrites
    nothing. Expected: **S, N1 and N2 all exist.** N1 stays because the
    child session's `workflow_runtime_executions` row still references the
    `{S, N1}` parent (invariant 1). The invariant helper passes.
  - (d) Call `persistNestedReferences` again, same key and role, with
    `{shared: S, unique: N3}`. Expected: **N2 is gone** (only the replaced
    nested refs used it), its parent payload row and refs rows are gone, N3
    exists, and S and N1 stay. The invariant helper passes.
- `testTerminalRunEndReleaseKeepsReferencedFragments`: save `running`, then
  `completed`. Expected: the fragment rows (digest, `json(bytes)`,
  `byte_count`) are identical before and after, invariant 3 holds, and `load`
  round-trips.
- `testSweepRemovesLeakedRefsAndFragments`: after a normal save, SQL-insert
  a fragment row L and a refs row `(root, "missing-parent", L)` whose parent
  payload does not exist. Also insert `(root, "missing-parent", S)` for a
  fragment S that a live parent still references. Call
  `store.releaseUnreferencedPayloads(rootSessionId:)`. Expected: L's row and
  both orphan refs rows are gone, S stays, and the returned bytes are at least
  L's `byte_count`. The invariant helper passes. Insert L with
  `bytes = jsonb(?)` (text JSON bound as the parameter), because
  `workflow_runtime_payloads.bytes` has `CHECK (json_valid(bytes, 8))`
  (`SQLiteRuntimeExecutionRowsSchema.swift:32`); a raw text or blob insert
  fails the check. Set `byte_count` to the UTF-8 length of that text.
- `testReleaseIsIsolatedPerRoot`: roots A and B store the same S. Truncate
  root A to zero executions and call `releaseUnreferencedPayloads(rootSessionId: "A")`.
  Expected: B's payload and refs rows are byte-identical before and after.
  If root A has no other references, its S row is gone.

### 5. `Tests/RielaCoreTests/RuntimePayloadBenchmarkTests.swift` (new, `final class RuntimePayloadBenchmarkTests: XCTestCase`)

`testReducedPayloadsAreAtLeastFiveTimesSmallerForLoopSession`, deterministic:

- Use 24 executions with fixed ids `exec-01` … `exec-24` and fixed dates.
  Output *i* is a distinct 16,384-byte string, for example a two-digit
  index prefix padded with a repeated letter. Execution *k*'s `inputSnapshot`
  is `{"upstream": {"exec-01": out1, …, "exec-(k-1)": out(k-1)}}`.
- For each mode, use a fresh temporary root. Wrap every save in
  `withValue(false)` for the baseline (generation-11 full payloads, the
  pre-change canonical format) or `withValue(true)` for the reduced store.
  Save after appending each execution while `running`, then save once as
  `completed`.
- Measure `bytes(root)` as `SELECT coalesce(sum(length(bytes)),0) FROM
  workflow_runtime_payloads WHERE root_session_id=?`. For the reduced root
  only, add `SELECT coalesce(sum(length(root_session_id)+length(parent_digest)+length(digest)),0)
  FROM workflow_runtime_payload_refs WHERE root_session_id=?`. Both sides use
  stored JSONB length.
- Print exactly one line:
  `print("ssg4 benchmark baselineBytes=\(baseline) reducedBytes=\(reduced) ratio=\(String(format: "%.2f", ratio))")`.
- Assert `baseline >= 5 * reduced`, and that `load` from both roots returns
  equal `WorkflowSession` values.
- The expected result is about 4.9 MB against about 0.5–0.8 MB (about 6–9x;
  only `inputSnapshot` is hoisted, so any per-execution value outside it stays
  inline). If the ratio is under 5, do not lower the threshold. Report it as
  blocked with both numbers.

### 6. Conditional default-dependent files

`RuntimePayloadReadParityTests.swift`, `SQLiteRuntimeExecutionRowsTests.swift`,
`RuntimePersistenceBoundedWriteTests.swift`, `RuntimePayloadHydrationTests.swift`
and `SQLiteRuntimeSchemaMigrationTests.swift` are edited only under the rule
in Non-goals. Record "no edit needed" or the
exact pin you added.

## Pitfalls

- Never delete a fragment by `parent_digest` alone. Shared fragments survive
  until their last parent is gone.
- `reserveNestedInvocation` also persists the child snapshot as execution
  rows. A fragment (or parent payload) still referenced by those rows must
  survive nested-ref replacement. Seeing it survive is the correct behavior,
  not a cascade defect. No production change is authorized for the nested
  case. If that case fails for any other reason, stop and report blocked;
  never weaken a `NOT EXISTS` guard to make a test pass.
- Root-scoped keys: every SQL check must filter by `root_session_id`.
- Do not read the benchmark baseline from `payloadJSON` text lengths. Measure
  the stored rows on both sides.
- Do not use `Date()`, `UUID()` or random content inside the stored session
  values. Temporary directory names may use `UUID()`.
- Tests must not touch `~/.riela` or the repository's `.riela`. They use only
  temporary store roots, and the commands below run with a temporary `HOME`.
- Before editing a file, record its sha256 in
  `tmp/ssg4/ssg4-01-release-cascade-benchmark/pre.sha256`. Read it fresh before
  every edit. Record `post.sha256` at the end. If a file changed unexpectedly
  between your read and your edit, stop and record the drift.

## Acceptance criteria (mechanically checkable)

- `grep -n "writesReducedExecutionPayloadsByDefault = true" Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`
  prints one line.
- `Tests/RielaCoreTests/RuntimePayloadReleaseTests.swift` defines the six test
  methods named above. `RuntimePayloadBenchmarkTests.swift` defines
  `testReducedPayloadsAreAtLeastFiveTimesSmallerForLoopSession`.
- `RuntimePayloadFragmentWriterTests.swift` contains
  `testFullPayloadModeWritesFullPayloadAndNestedWritesReduced` and
  `testDefaultWritesReducedPayloads`.
- `test.log` contains `ssg4 benchmark baselineBytes=` with `ratio=` ≥ 5.00.
  The gate and extra test logs end with `exit=0` and report 0 failures.

## Verification (each must exit 0)

Run from the repository root. The swift binary is the absolute path from
`mise which swift`, resolved with the real `HOME`. The first command checks
that it has not changed.

```
mkdir -p tmp/ssg4/ssg4-01-release-cascade-benchmark
test "$(mise which swift)" = /Users/taco/.local/share/mise/installs/swift/6.3.3/bin/swift
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -c 'set -o pipefail; /Users/taco/.local/share/mise/installs/swift/6.3.3/bin/swift build 2>&1 | tee tmp/ssg4/ssg4-01-release-cascade-benchmark/build.log; s=$?; echo "exit=$s" >> tmp/ssg4/ssg4-01-release-cascade-benchmark/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -c 'set -o pipefail; /Users/taco/.local/share/mise/installs/swift/6.3.3/bin/swift test --filter "Retention|GarbageCollection|StorageCompact|StorageDoctor|RunEndStorageMaintenance|AutomaticRetention|EventLiveServe|RuntimePayload|SchemaMigration|SQLiteRuntimeExecutionRows" 2>&1 | tee tmp/ssg4/ssg4-01-release-cascade-benchmark/test.log; s=$?; echo "exit=$s" >> tmp/ssg4/ssg4-01-release-cascade-benchmark/test.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -c 'set -o pipefail; /Users/taco/.local/share/mise/installs/swift/6.3.3/bin/swift test --filter "RuntimePersistenceBoundedWrite|CLIWorkflowSessionEnvelope" 2>&1 | tee tmp/ssg4/ssg4-01-release-cascade-benchmark/test-layout.log; s=$?; echo "exit=$s" >> tmp/ssg4/ssg4-01-release-cascade-benchmark/test-layout.log; exit $s'
/bin/zsh -c 'grep -E "ssg4 benchmark baselineBytes=[0-9]+ reducedBytes=[0-9]+ ratio=([5-9]|[1-9][0-9]+)\.[0-9]+" tmp/ssg4/ssg4-01-release-cascade-benchmark/test.log'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCore/RuntimePayloadFragmentEncoder.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Tests/RielaCoreTests/RuntimePayloadFragmentWriterTests.swift Tests/RielaCoreTests/RuntimePayloadReleaseTests.swift Tests/RielaCoreTests/RuntimePayloadBenchmarkTests.swift 2>&1 | tee tmp/ssg4/ssg4-01-release-cascade-benchmark/lint.log; s=$?; echo "exit=$s" >> tmp/ssg4/ssg4-01-release-cascade-benchmark/lint.log; exit $s'
```

If you edit any conditional file from §6, append it to the swiftlint file
list and record the extended command in the progress log.

Evidence each command must establish:

- build.log, test.log and test-layout.log end with `exit=0`. The test logs
  show `with 0 failures` on the final `Executed` line, and test.log lists
  `RuntimePayloadReleaseTests` and `RuntimePayloadBenchmarkTests` as passed.
- The grep prints the benchmark line with a ratio of at least 5.
- lint.log ends with `exit=0`.

## Progress log

Write `impl-plans/progress/ssg4-01-release-cascade-benchmark.md` with:

- status;
- pre and post sha256 for every touched file;
- the review conclusion for the cascade and for the operator's writer-test
  edit;
- each command with its exit code and log path;
- the benchmark numbers and ratio;
- every conditional-file decision;
- any reconciliation item, such as a failure in a file outside writePaths.
  Report that as blocked; do not edit the file.
