# ssg2-02-fragment-hydration: fail-closed expansion and read parity

**Archived 2026-10-30 (session 564)**: accepted in the integration review of
sessions 562/563. Progress log: `impl-plans/progress/ssg2-02-fragment-hydration.md`.

**planId**: ssg2-02-fragment-hydration
**dependsOn**: ssg2-01-fragment-writer (wave W2)
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§3.3, §3.4 (reads and the public read-path table), §3.5 (write switch; terminal
tests rely on the ssg2-01 guard), §9 (Round-trip, Fail closed, Nested,
`RuntimePayloadReadParityTests`), §12 row (b)
**Shared rules**: `impl-plans/active/ssg2-session-storage-gc.md` → "Shared execution rules"
**Progress log**: `impl-plans/progress/ssg2-02-fragment-hydration.md`
**Evidence root**: `tmp/ssg2/ssg2-02-fragment-hydration/`
**writePaths**: `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`, `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`, `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift`, `Tests/RielaCoreTests/RuntimePayloadHydrationTests.swift` (new), `Tests/RielaCLITests/RuntimePayloadReadParityTests.swift` (new), `impl-plans/progress/ssg2-02-fragment-hydration.md`
**sharedPaths**: none

## Intent and context

ssg2-01 writes reduced execution payloads (switch on in tests only). This plan
makes every public read path expand them, verifying each fragment's sha256 and
failing closed. Design §3.4 maps every public read path to one of two
expansion points:

- `assembledSessionData` (`+SessionFamily.swift:369-392`) serves `load`,
  `loadStrictReadOnly`, `loadAll`, rollup, family hydration and
  `loadWebSessionDetail` (`+WebSummaries.swift:191`), which backs the GraphQL
  and web session views, session status/export/logs/progress and
  resume/rerun/continue admission;
- `hydratedNestedSnapshot` (`+NestedInvocations.swift:~670-720`) serves nested
  invocation records and reservations.

SQL `json_extract` readers (`+WebSummaries.swift:251-256`,
`CLIWorkflowSessionStore.swift:509-515`) read top-level fields that are never
hoisted; do not touch them.

## Non-goals

- No writer, release or switch-default changes (ssg2-01 / ssg2-03).
- No changes to `+WebSummaries.swift`, `CLIWorkflowSessionStore.swift`,
  `Sources/RielaGraphQL`, or any `Sources/RielaCLI` file.
- No new public API.

## Contract (add to `RuntimePayloadFragmentEncoder.swift`)

```swift
static func expand(_ execution: inout JSONValue, fragments: [String: String]) throws
// fragments: digest -> fragment JSON text as read back via json(bytes)
```

Missing or mismatched fragments throw
`WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime payload fragment missing or corrupt: <digest>")`.

## File-level changes

### 1. `Sources/RielaCore/RuntimePayloadFragmentEncoder.swift`

Add `expand`: verify `sha256(text) == digest` (`JSONCanonical.sha256Hex`) for
every fragment it uses, parse it, substitute every
`{"$rielaPayloadRef": d}` object recursively (fragments can reference deeper
fragments), then remove the top-level `_rielaPayloadRefs`. A reference object
is exactly an object with the single key `$rielaPayloadRef` and a string
value.

### 2. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift` (`assembledSessionData` only)

- After the existing SQL assembly: if the assembled text does not contain
  `_rielaPayloadRefs`, return it unchanged (no parse; today's bytes).
- Otherwise parse the session, collect the digests listed by every execution
  that has the top-level marker, and fetch
  `SELECT digest, json(bytes) AS payload FROM workflow_runtime_payloads WHERE root_session_id=? AND digest IN (...)`
  in chunks of at most 500 bindings on the same `db` (same read transaction).
  The root id is `SELECT root_session_id FROM workflow_runtime_executions WHERE workflow_execution_id=? LIMIT 1`.
- Expand each marked execution, re-encode the session with a sorted-keys
  encoder, and return the data for the existing `WorkflowSession` decode.

### 3. `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift` (`hydratedNestedSnapshot` only)

Keep the existing digest check of each execution payload. If the payload has
the marker, fetch its fragments under the nested ref row's `root_session_id`
and `expand` before appending.

## Pitfalls

- **Fail closed.** Never return an execution with unexpanded references or a
  partial session. One missing or corrupt fragment fails the whole load.
- **Same transaction.** Fetch fragments with the `db` passed in; do not open a
  second connection.
- **No double work.** The no-marker path must not parse JSON (legacy and
  generation-11 stores keep their current cost).
- **Do not trust the marker alone.** Only executions whose top-level object
  has `_rielaPayloadRefs` are expanded; a user string containing that text
  must not change anything (the fast-path check is only a hint).
- **Integers stay integers** through parse and re-encode.

## Tests

Run reduced saves inside
`SQLiteWorkflowRuntimePersistenceStore.$writesReducedExecutionPayloadsOverride.withValue(true)`.
Use `false` to build generation-11 fixtures.

New `Tests/RielaCoreTests/RuntimePayloadHydrationTests.swift`:

- reduced session (running, and `completed` saved as a terminal root) →
  `load(sessionId:)` returns a `WorkflowSession` equal to the input;
  `loadWebSessionDetail` returns the same executions;
- one fragment row deleted with raw SQL → `load` throws an error containing
  `runtime payload fragment missing or corrupt`;
- one fragment row's bytes replaced with different valid JSON → throws the
  same error;
- nested invocation with a reduced child execution → the nested record and
  reservation hydrate equal to the saved child snapshot, and the child
  fragments are shared with the child's own execution rows (no duplicate
  `(root, digest)` row);
- generation-11 full payload row (switch false) and legacy inline
  `session_json` (as in `SQLiteRuntimeExecutionRowsTests.testLegacyInlineSessionLoadsAndConvertsOnFirstSave`)
  → both still load equal;
- a session whose user data contains the string `_rielaPayloadRefs` inside an
  output value but no reduced execution → loads equal.

New `Tests/RielaCLITests/RuntimePayloadReadParityTests.swift` (`@testable import RielaCore`,
`@testable import RielaCLI`). Build one session with a nested invocation and
large repeated `inputSnapshot` values, then write it to three temporary stores:
reduced (switch true, saved as `completed`), generation-11 (switch false), and
legacy inline plus legacy CLI copy (imitate
`Tests/RielaCLITests/CLIWorkflowSessionEnvelopeTests.swift:insertLegacy`).
Assert the reduced store has `workflow_runtime_payload_refs` rows. Then:

- `session status`, `session export`, `session logs`, `session progress` with
  `--session-store <store> --output json`, run through `RielaCLIApplication().run`
  inside `CLIWorkflowSessionEnvelopeTests`-style isolation (temporary `HOME`
  via `CLIRuntimeEnvironment.$captured`) → equal exit codes and byte-identical
  stdout after replacing each store path with a placeholder;
- `CLIWorkflowSessionStore.load`, `SQLiteWorkflowRuntimePersistenceStore.load`
  and `loadWebSessionDetail` (resume/rerun admission inputs and the GraphQL /
  web session view source, design §3.4) → equal across the three stores.

## Acceptance criteria

- `rg -n "func expand" Sources/RielaCore/RuntimePayloadFragmentEncoder.swift` → one match.
- `rg -n "runtime payload fragment missing or corrupt" Sources/RielaCore` → matches.
- Both new test classes pass, including terminal reduced sessions.

## Verification (each must exit 0)

```
mkdir -p tmp/ssg2/ssg2-02-fragment-hydration
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/ssg2/ssg2-02-fragment-hydration/build.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-02-fragment-hydration/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "RuntimePayload|SQLiteRuntimeExecutionRows|SQLiteWorkflowMessageLog|CLIWorkflowSessionEnvelope|SessionStore" 2>&1 | tee tmp/ssg2/ssg2-02-fragment-hydration/test.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-02-fragment-hydration/test.log; exit $s'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCore/RuntimePayloadFragmentEncoder.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift Tests/RielaCoreTests/RuntimePayloadHydrationTests.swift Tests/RielaCLITests/RuntimePayloadReadParityTests.swift 2>&1 | tee tmp/ssg2/ssg2-02-fragment-hydration/lint.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-02-fragment-hydration/lint.log; exit $s'
```

Evidence: all three logs end with `exit=0`; `test.log` shows
`RuntimePayloadHydrationTests`, `RuntimePayloadReadParityTests` and the
ssg2-01 `RuntimePayloadFragmentWriterTests` executed with 0 failures.

## Progress log

Record in `impl-plans/progress/ssg2-02-fragment-hydration.md`: pre/post
sha256, commands with exit codes and log paths, acceptance items, and any
out-of-plan failure for reconciliation.
