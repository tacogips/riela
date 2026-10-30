# ssg2-03-fragment-release-benchmark: cascade release, switch on, ≥5x benchmark

**planId**: ssg2-03-fragment-release-benchmark
**dependsOn**: ssg2-02-fragment-hydration, ssg2-06-default-retention-review-isolation (wave W3; the 06 edge exists because this plan may make expectation-only edits in `Tests/RielaCLITests/TerminalRetentionTests.swift`, which ssg2-06 isolates first)
**writePaths**: `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`, `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`, `Tests/RielaCoreTests/RuntimePayloadReleaseTests.swift`, `Tests/RielaCoreTests/RuntimePayloadBenchmarkTests.swift`, `Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift`, `Tests/RielaCoreTests/RuntimePersistenceBoundedWriteTests.swift`, `impl-plans/progress/ssg2-03-fragment-release-benchmark.md`
**sharedPaths** (expectation-only edits caused by the switch flip): `Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift`, `Tests/RielaCLITests/TerminalRetentionTests.swift`, `Tests/RielaCoreTests/SQLiteWorkflowMessageLogTests.swift`
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§3.2 (Release → Cascade), §3.5 (write switch default becomes `true`), §3.6,
§9 (Release, Benchmark), §12 row (c)
**Shared rules**: `impl-plans/active/ssg2-session-storage-gc.md` → "Shared execution rules"
**Progress log**: `impl-plans/progress/ssg2-03-fragment-release-benchmark.md`
**Evidence root**: `tmp/ssg2/ssg2-03-fragment-release-benchmark/`

## Intent and context

After ssg2-01 (writer and guard) and ssg2-02 (expansion), fragments are never
deleted while referenced, but they can leak: when a reduced execution payload
is released, its `workflow_runtime_payload_refs` rows stay and keep its
fragments alive. This plan finishes reference-aware release, turns the
reduced form on for production (`writesReducedExecutionPayloadsByDefault = true`),
and proves the ≥5x saving with a benchmark test that prints both numbers.

Code to change: `+SessionFamily.swift:releasePayloadIfUnreferenced` (139-149)
and `releaseUnreferencedPayloads(rootSessionId:in:)` (151-184), both already
carrying the ssg2-01 guard. Callers that must keep working:
`writeExecutionRows` (old digest and truncation), `persistNestedReferences`
(removed nested refs), the run-end release
(`SQLiteWorkflowRuntimePersistenceStore.swift:873-874`) and the public
`releaseUnreferencedPayloads(rootSessionId:)` (`+SessionFamily.swift:511`).

## Non-goals

- No reader, encoder-rule or schema changes.
- No change to `TerminalRetentionExecutor` (it already deletes refs rows per
  root) or tombstone triggers.
- Do not weaken bounded-write tests: per-save cost must still not grow with
  store size.

## File-level changes

### 1. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`

- **`releasePayloadIfUnreferenced`.** Use `RETURNING digest` (or the change
  count) to know whether the row was deleted. Only then run
  `DELETE FROM workflow_runtime_payload_refs WHERE root_session_id=? AND parent_digest=? RETURNING digest`
  and call the same function for each returned child digest. Fragments carry
  no refs rows of their own, so recursion is one level deep.
- **`releaseUnreferencedPayloads`.** In one call: (1) delete unreferenced
  payloads (the guarded predicate), (2) delete refs rows of that root whose
  `parent_digest` no longer exists in `workflow_runtime_payloads`, (3) delete
  fragments that became unreferenced. Return the summed `byte_count` of every
  deleted payload row. Two fixed rounds; no unbounded loop.

### 2. `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`

Change only `writesReducedExecutionPayloadsByDefault` to `true`.

## Pitfalls

- **Shared fragments.** A fragment listed by two parents survives until both
  parents are gone. Never delete a fragment by `parent_digest` alone; always
  go through the guarded release.
- **Order inside the transaction.** Delete the parent payload first, then its
  refs rows, then release children. Never delete refs rows of a parent that
  still exists.
- **Expectation updates.** With the default on, existing tests that count
  payload rows, statements or `boundBytes` may change. Update only the
  numbers, explain each in the progress log, and keep the store-size
  independence assertions. If a test outside `writePaths`/`sharedPaths` fails,
  record it for reconciliation and report the plan as blocked rather than
  editing it.

## Tests

New `Tests/RielaCoreTests/RuntimePayloadReleaseTests.swift`:

- replace one execution's `inputSnapshot` and save → orphaned fragments and
  their refs rows are gone; fragments shared with another execution remain;
- truncate executions (save with fewer) → SQL invariants hold: every refs
  `parent_digest` exists in payloads for the root, and every fragment digest
  has at least one refs row or execution/nested reference;
- `releaseUnreferencedPayloads(rootSessionId:)` → returns the deleted byte
  total and leaves no orphan;
- nested invocation replaced → child fragments still referenced by the child's
  own rows survive; others are released;
- default switch (no override) → a new save writes refs rows (production now
  reduces).

New `Tests/RielaCoreTests/RuntimePayloadBenchmarkTests.swift` (design §9):

- synthetic loop session, ≥ 20 iterations × 2 steps; iteration k's
  `inputSnapshot` carries in `_rielaInput.messages` every prior upstream
  output, each a distinct object ≥ 4 KiB;
- `stored` = `SUM(length(bytes))` of the root's `workflow_runtime_payloads`
  rows + `SUM(length(root_session_id)+length(parent_digest)+length(digest))`
  of its refs rows;
- `baseline` = sum of UTF-8 lengths of the distinct `payloadJSON(execution)`
  texts;
- `print("ssg2 benchmark baseline=\(baseline) stored=\(stored) ratio=\(ratio)")`
  and assert `baseline >= 5 * stored`;
- `load` round-trips equal.

## Acceptance criteria

- `rg -n "writesReducedExecutionPayloadsByDefault = true" Sources/RielaCore` → one match.
- `rg -n "parent_digest" Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` → cascade deletes present.
- `test.log` contains the `ssg2 benchmark baseline=` line with ratio ≥ 5.

## Verification (each must exit 0)

```
mkdir -p tmp/ssg2/ssg2-03-fragment-release-benchmark
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/ssg2/ssg2-03-fragment-release-benchmark/build.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-03-fragment-release-benchmark/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "RuntimePayload|SchemaMigration|SQLiteRuntimeExecutionRows|RuntimePersistenceBoundedWrite|SQLiteWorkflowMessageLog|CLIWorkflowSessionEnvelope|SessionStore|TerminalRetentionTests|SessionMessageRetentionAdmission" 2>&1 | tee tmp/ssg2/ssg2-03-fragment-release-benchmark/test.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-03-fragment-release-benchmark/test.log; exit $s'
/bin/zsh -c 'grep -E "ssg2 benchmark baseline=[0-9]+ stored=[0-9]+" tmp/ssg2/ssg2-03-fragment-release-benchmark/test.log'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCore/RuntimePayloadFragmentEncoder.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Tests/RielaCoreTests/RuntimePayloadReleaseTests.swift Tests/RielaCoreTests/RuntimePayloadBenchmarkTests.swift 2>&1 | tee tmp/ssg2/ssg2-03-fragment-release-benchmark/lint.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-03-fragment-release-benchmark/lint.log; exit $s'
```

Evidence: logs end with `exit=0`; the grep prints the benchmark line; copy
`baseline`, `stored` and the ratio into the progress log.

## Progress log

Record in `impl-plans/progress/ssg2-03-fragment-release-benchmark.md`:
pre/post sha256, commands with exit codes and log paths, benchmark numbers,
every changed test expectation with its reason, and any reconciliation item.
