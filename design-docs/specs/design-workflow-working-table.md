# Workflow-private disposable JSON working table

Status: accepted by independent Step 3 design review; the 2026-09-23
storage-layout amendment was re-reviewed against the existing KV source.
Implementation pending.
Mode: planning-only (`executionMode: design-plan-only`).
Issue: workflowInput: Workflow-scoped disposable JSON working table with bounded TTL
(no issue URL or number supplied). Intake: `comm-000002`, from
`step1-issue-intake`, execution `codex-design-and-implement-review-loop-session-1`.
No codex-agent reference input or Cursor CLI behavior applies.

## Scope and current behavior

Provide a small workflow-scoped JSON cache in a workspace, shared by successive
scheduled runs. Support set/get/delete and list, with default six-hour expiration
and a hard thirty-day maximum. This document specifies future behavior only.
No Swift changes, implementation fanout, or main merge belong to this run.

`Packages/RielaMemory/Sources/RielaMemory/RielaKeyValueStore.swift` currently
stores JSONB in `.riela/kv/<storeId>.sqlite`, keyed by `(scope, key)`, without TTL.
`Sources/RielaCLI/ProductionNodeAdapter+KeyValueStoreAddon.swift` defaults scope
to `input.workflowId`, but accepts `scope`, `storeId`, and `kvRoot` overrides.
`Sources/RielaAddons/RielaAddons.swift` advertises the four `riela/kv-*` built-ins.
`Tests/RielaCLITests/KeyValueStoreAddonTests.swift` explicitly tests shared scope;
`Packages/RielaMemory/Tests/RielaMemoryTests/RielaKeyValueStoreTests.swift` covers
JSON round trips, overwrite, deletion, isolation, listing, and validation.
Adding TTL or removing scope overrides from those APIs would break their contract.
Storage amendment review confirmed the current adapter defaults `storeId` to
`workflow-kv`, `RielaKeyValueStore.databasePath` appends `.sqlite` under
`.riela/kv`, and its schema creation targets only `kv_entries`. The new table
name and fixed default path therefore preserve the existing KV API boundary;
the plan requires tests for either initialization order and shared-file use.

## Namespace and trust boundary

The namespace is the pair (runtime workspace root, runtime workflow ID).
Use the resolver's trusted execution working directory as workspace root,
canonicalized once with standardized path and resolved symlinks. Do not use a
node shell's current directory, session ID, step ID, package version, or supplied
workflow input to select the namespace. All calls in one execution retain that
root; scheduled executions must supply the same workspace root to reuse data.
Use the exact nonempty `WorkflowAddonExecutionInput.workflowId`, bound as SQL
text, never interpolated into paths. Missing runtime identity is an error.
Called workflows use their own executing workflow ID, not their caller's ID.

A workflow ID is the workflow identity within that workspace: editing/upgrading
its definition keeps entries; renaming its ID starts an empty namespace. Two
definitions deliberately run under the same ID in the same workspace are the
same identity for this API. Distinct workspaces/worktrees have separate database
files; moving a workspace together with its state preserves the cache, whereas
copying the workspace also copies its then-current cache as independent state.

The API exposes no scope, store ID, root directory, workflow ID, or namespace
selector. Reject these reserved override fields in add-on config and explicit
add-on inputs, including `scope`, `storeId`, `kvRoot`, `rootDirectory`,
`workflowId`, `workspaceRoot`, and `namespace`. Read only the operation's declared
fields; never consult merged workflowInput/environment for storage selectors.
Unrelated fields in the broader workflow input have no effect. Test override
attempts from config, inputs, workflowInput, and environment. Privacy is API
namespace isolation, not a sandbox against code with direct filesystem access.

## Public operations and validation

Introduce `riela/working-table-set`, `riela/working-table-get`,
`riela/working-table-delete`, and `riela/working-table-list`, version `1`.
Do not add a new CLI command, sharing mode, named tables, locks, or lease API.
Resolve declared config fields ahead of explicit add-on inputs by field presence;
explicit null is a value, not an instruction to fall through to a default.
Use existing JSON template rendering for `valueTemplate`; reject supplying both
`value` and `valueTemplate`. Never discover operation arguments from ambient
workflow state. Unknown config/explicit input fields are validation errors.

| Operation | Fields | Successful payload beyond standard status/addon/operation/stepId |
| --- | --- | --- |
| set | required key and value or valueTemplate; optional ttlSeconds | saved:true, entry |
| get | required key | found:boolean, value; entry only when found |
| delete | required key | deleted:boolean, key |
| list | optional limit (100), offset (0) | entries, count, limit, offset |

Entries contain `key`, decoded JSON `value`, `writtenAt`, and `expiresAt`.
Timestamps are numeric UTC Unix seconds, not caller-supplied metadata. A missing
get returns `found:false,value:null`; a stored JSON null returns
`found:true,value:null`. List count is the returned page size, not a total.
Keys retain existing KV validation: nonempty, no leading/trailing whitespace,
at most 1,024 UTF-8 bytes; do not silently trim or rewrite them. Values may be
any JSON type, including null, arrays, and scalar values; reject invalid or
nonfinite JSON numbers before storage. List limit must be an integer > 0 and
offset an integer >= 0; reject strings, booleans, null, and fractional pagination
values. No prefix/default-value feature is needed for the accepted use case.

`ttlSeconds` is an optional finite JSON number: omission means 21,600 seconds.
Accept exactly `0 < ttlSeconds <= 2,592,000` (30 * 24 hours), including fractional
seconds. Reject null, strings, booleans, zero, negative, nonfinite, and over-limit
values; do not clamp, coerce, or treat invalid input as omission. TTL is a set-only
argument and is validated before database mutation.

## Time, expiration, and cleanup

Use the runtime wall clock in UTC, with a store-level injectable clock for tests,
never a workflow-controlled clock. Store numeric time with the runtime's Double
precision in SQLite REAL. Every operation samples time once after acquiring its
database transaction; that instant is its logical observation time. The exact
boundary is `now >= expiresAt`: expired entries are indistinguishable from absent
entries on get and list. Timestamp arithmetic uses the same precision for writes
and comparisons; extremely small positive fractional TTLs can round to the write
time and therefore expire immediately. No minimum TTL beyond positivity is added.

Set replaces the complete JSON value atomically and writes
`writtenAt = now`, `expiresAt = now + ttlSeconds`. TTL starts at the successful
write transaction's time sample, not fetch start or workflow start. A slow commit
consumes TTL; success need not imply the entry is still live when delivered.
Every successful set, including identical-value retries, resets TTL. Omitting TTL
on overwrite uses six hours, not the previous TTL. Get/list never refresh TTL.
Delete returns true only if a live entry existed at its observation time; deleting
an expired/missing entry returns false and may remove expired physical data.

Get/list always filter expiration in SQL before ordering/pagination. List orders
by key using SQLite BINARY collation and observes one transaction snapshot.
Separate pages are separate observations; concurrent changes can shift offset
pages. There is no multi-page snapshot or cross-operation transaction API.

On each operation against an existing store, delete expired rows for the owning
workflow within the same transaction, using the same sampled time. Index
`(workflow_id, expires_at)` for this deletion. Missing-database get/list/delete
return miss/empty/false without creating it. No background janitor, public cleanup
operation, or deletion of another workflow's rows is needed. Inactive workflows
may retain expired physical rows until next use; expiration bounds visibility,
not disk retention or secure erasure. SQLite reuses freed pages; automatic vacuum
and storage quotas are out of scope.

Persisted wall-clock deadlines survive process restarts. Clock jumps forward can
expire data early relative to elapsed real time; backward jumps can delay expiry
or make an uncollected row visible again. This cache is not a security deadline or
strict monotonic retention mechanism. A persistent monotonic-clock service is
outside this scope.

## Storage, concurrency, and failures

Add a dedicated working-table store in RielaMemory, backed by the existing
default durable-KV database at `<workspace>/.riela/kv/workflow-kv.sqlite`.
Create one additional table, `working_entries`, in that database. Do not create
a database or SQL table per workflow: `workflow_id` separates its rows. The new
adapter uses this fixed trusted path regardless of durable-KV `kvRoot`/`storeId`
overrides, and neither API can read the other's table. `working_entries` contains
`workflow_id TEXT`, `key TEXT`, `value_json BLOB`, `written_at REAL`, and
`expires_at REAL`, all NOT NULL; primary key `(workflow_id, key)` and the expiry
index above. Use SQLite JSONB validation like the current KV store. Reuse
`MemoryJSONValue`, encoding and bound-SQL helpers from
`MemoryEncodingSupport.swift` and `SQLiteMemorySupport.swift`; do not wrap the
public durable store or generalize both stores behind a new framework.
Durable KV retains its `kv_entries` table and existing explicit root/store/scope
overrides. Those selectors may point to this same SQLite file but cannot select
`working_entries` through the KV API. Working-table initialization must coexist
with an existing `kv_entries` table or an empty database, and must not alter the
durable schema or its data.

Use SQLite transactions and its existing five-second busy timeout, not an
in-process-only lock. Acquire `BEGIN IMMEDIATE` for cleanup plus the operation,
sample time, execute bound statements, construct the result inside the same
transaction, then commit before reporting success. This deliberately serializes
operations within one workspace database; the expected small cache does not need
WAL tuning or a new concurrency service. Durable-KV writes may contend on the
same file; the existing busy timeout applies and failures remain visible.
Distinct keys retain both committed updates. For the same key, the last
serialized successful set wins; delete/set
follow their transaction order. Reads never observe partially replaced JSON.
Atomic schema initialization must also tolerate simultaneous first opens.

Get-then-fetch-then-set is not atomic: overlapping scheduled runs may both fetch
the same page, which is acceptable for this cache. No exactly-once fetching,
compare-and-swap, distributed lock, merge, or deduplication guarantee is implied.
Do not copy the existing KV set's separate unprotected upsert/readback sequence;
return this transaction's own entry even when another writer is waiting.

Validation failures change nothing. Busy timeout, permission failure, full disk,
unsupported JSONB, corrupt data/schema, and read/commit/cleanup errors fail the
operation visibly through the existing adapter error mechanism, not as a cache
miss or success. Roll back when possible, close the handle, and never silently
reset/delete a corrupt database or fall back to durable KV. Cleanup failure fails
the transaction. A process crash before commit leaves no partial operation; a
crash or response loss after commit may leave an applied operation whose success
was not received. Caller retry follows normal semantics (set resets TTL; repeated
delete can return false). Diagnostics identify operation/error without dumping
stored values. Workflow authors choose whether a failed cache step aborts or
continues to fetch; the built-in never silently treats a storage error as absence.

## Hacker News cache example

A periodic `hn-digest` workflow in a fixed workspace derives a stable key from
each canonical page URL, for example `hn:item:12345`. It gets that key before
fetching. On a hit it skips the network fetch and uses cached JSON such as
`{"url":"https://news.ycombinator.com/item?id=12345","title":"Example","text":"..."}`.
On a miss it fetches/parses the page, then sets the key only after successful
fetch and parse, omitting TTL for six hours. Failed fetches create no marker.
A run at write time + 21,599 seconds hits; at + 21,600 it misses. A hit does not
extend this window. Different workflow IDs do not see that entry. Simultaneous
misses may fetch twice and the last committed result wins. Cached page JSON is
disposable; durable progress cursors continue using `riela/kv-*` where appropriate.

## Coexistence, implementation handoff, and acceptance

Choose additive coexistence, with no automatic migration or reinterpretation of
existing durable data. Keep `RielaKeyValueStore`, `.riela/kv` schemas, `riela/kv-*`
names, durable TTL-free behavior, and explicit shared scopes unchanged. Authors
opt into new built-ins. Moving a cache manually means reading selected old keys
and setting new entries with fresh TTL; do not bulk-import shared scopes or delete
old keys automatically. Reverting a workflow to durable KV leaves the disposable
store unused; no downgrade migration is required.

The downstream plan should sequence: (1) store/schema/clock and deterministic
store tests; (2) a dedicated working-table adapter plus registration in
`Sources/RielaAddons/RielaAddons.swift` and dispatch in
`Sources/RielaCLI/ProductionNodeAdapter+StatefulAddonDispatch.swift`; (3) adapter
isolation and scheduled-run/cache examples; (4) durable-KV regression verification.
Proposed new files are
`Packages/RielaMemory/Sources/RielaMemory/RielaWorkingTableStore.swift`,
`Sources/RielaCLI/ProductionNodeAdapter+WorkingTableAddon.swift`,
`Packages/RielaMemory/Tests/RielaMemoryTests/RielaWorkingTableStoreTests.swift`,
and `Tests/RielaCLITests/WorkingTableAddonTests.swift`.
These are handoff targets, not files created in Step 2.

Acceptance must cover every JSON type; six-hour default; positive fractional and
30-day TTL; all rejected TTL forms; just-before/equal/after expiration; reset on
same-value set and omitted TTL; null vs miss; expired rows removed before page
selection; repeated delete; missing database; workflow/workspace isolation;
same-ID successive executions; override rejection; clock jumps; first-open race;
separate-process competing writes/cleanup/delete; transaction-local return values;
rollback, busy, corrupt-store and lost-response behavior; and the HN sequence.
Keep durable shared-scope and TTL-free regression assertions alongside new tests,
including either API creating the file first, and both operating on one database
file without changing each other's rows.
Use a fake clock instead of sleeps for TTL tests and controlled database/process
coordination for concurrency/failure tests.

Future implementation verification commands (not executed in this design step):

- `swift test --package-path Packages/RielaMemory --filter 'RielaWorkingTableStoreTests|RielaKeyValueStoreTests'`
- `swift test --filter 'WorkingTableAddonTests|KeyValueStoreAddonTests'`
- `swift build`
- `swiftlint --quiet --no-cache`
- `git diff --check`

Independent design review precedes implementation-plan acceptance and adversarial
review. Commit/push only accepted design/plan documents on
`design/workflow-working-table`; do not merge main or touch unrelated worktrees or
the active P1 implementation session. No implementation checks are claimed here.

## Open questions and reference mapping

No unresolved user decision is needed for this bounded design. Review may reject
specific choices, but storage, namespace, expiry, concurrency, and coexistence
have explicit defaults above. No Codex reference repository was supplied; this
feature has no codex-agent or Cursor CLI behavior mapping or divergence.
