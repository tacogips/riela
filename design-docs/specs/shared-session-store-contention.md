# Shared SQLite session stores

Default writable and read-only `SQLiteDatabase` connections wait for competing
processes to release their locks. They no longer abandon a run after three
seconds of ordinary lock contention. Explicit `SQLiteOpenOptions` retain their
bounded timeout unless `waitForLocks` is selected. A waiting CLI can be stopped
with Ctrl-C; OS locks are released when their owning process exits.

WAL initialization also follows this policy. SQLite can return `SQLITE_BUSY`
from `PRAGMA journal_mode=WAL` without invoking its busy handler, so this
idempotent initialization is retried separately. Other SQL failures are still
reported. Workflow actions and transaction bodies are never replayed.

Regression coverage includes rollback-journal/WAL initialization contention,
explicit zero and finite deadlines, three simultaneous connections, and WAL
initialization and write transactions held beyond three seconds. Record counts,
transaction-body invocation counts, cancellation, and database integrity are
checked. Both WAL initialization and SQLite's busy handler observe task
cancellation; a CLI Ctrl-C probe exited while another process still held the
write lock.

## Published SDK dependency

The previous Kaiba pin (`b436b91`) did not export `KaibaClient`; the SDK existed
only as uncommitted work in the adjacent checkout. Kaiba source release
[v0.1.13](https://github.com/tacogips/kaiba/releases/tag/v0.1.13), commit
`c6a669a3cce4ed3659370e4c8ab0d4d510bc8c40`, publishes that product and its server
support. Riela now pins that commit. The temporary SwiftPM editable dependency
used for diagnosis has been removed.

Kaiba's release verification passed 808 XCTest and 123 Swift Testing tests.
Its release also fixes two reproduced test blockers: nondeterministic PageRank
accumulation and a TCP reset that could hide the server's HTTP 429 response.

## Workflow verification scope

The representative mock workflows `worker-only-single-step`,
`same-node-session-echo`, and `node-combinations-showcase` completed concurrently
using one default session store and one artifact root. Their persisted sessions
were complete and SQLite reported `integrity_check = ok`.

The same three mock workflows also completed after an external `sqlite3`
process acquired `BEGIN IMMEDIATE` on their shared session database and held
it for eight seconds. Across three rounds, all nine records remained complete
and the database passed the integrity check. No per-run store or artifact-root
isolation was used.

With the GitHub dependency resolved (no editable package), Xcode's Swift
toolchain passed `swift build` and all 158 tests selected by:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test \
  --scratch-path tmp/sqlite-shared-store/xcode-build \
  --filter 'WorkflowRuntimePersistence|CLIWorkflowSession|LoopConcurrency|SQLite|WorkflowCommandScenario|Kaiba'
```

The separate scratch directory avoids a reproduced conflict with another
process using the mise toolchain in `.build`. SwiftLint on the changed SQLite
source and tests, and `git diff --check`, passed.

The three workflows in the original failure report were not identified in the
available request. These representative runs must not be described as reruns
of those original workflows.
