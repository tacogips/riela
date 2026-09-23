# Workflow-private working table implementation plan

## Authority and execution boundary

- planId: `workflow-working-table-v1`
- planPath: `impl-plans/active/workflow-working-table.md`
- dependsOn: `[]`
- workflowMode: `planning-only` (`executionMode: design-plan-only`)
- Issue: `workflowInput: Workflow-scoped disposable JSON working table with bounded TTL`
- Accepted design: `design-docs/specs/design-workflow-working-table.md`
- Design acceptance: Step 3 `comm-000004`, reviewed `comm-000003`, intake
  `comm-000002`, execution `codex-design-and-implement-review-loop-session-1`.
  Decision: accepted, no findings or requested revisions.
- Plan status: accepted by independent Step 5 review; implementation not started.
- Codex-agent references / Cursor behavior mapping / intentional divergences: none.
- One author and one future implementation owner. No parallelizable tasks or fanout.

The user wants a disposable JSON cache private to one workflow in one workspace,
reused by later scheduled runs, so the Hacker News workflow can skip page fetches.
This run produces and reviews documents only. Do not execute the implementation
below or change Swift in this run. After plan/adversarial acceptance, finalization
may commit and push only the accepted design and this plan on
`design/workflow-working-table`. Do not merge main, alter unrelated worktrees, or
interfere with the active P1 session. A later implementation requires separate
authorization; the accepted documents must already be committed before it starts.
Do not create worktrees/private branches or perform concurrent Git operations.

## Repository context, ownership, and non-goals

The existing `RielaKeyValueStore` persists JSONB indefinitely under `.riela/kv`,
with `(scope,key)` identity; its adapter allows explicit cross-workflow sharing.
Keep those contracts unchanged. Reuse `MemoryJSONValue`, JSON encoding and bound
SQLite support without introducing a generic storage abstraction or migrating
old entries. New storage is `.riela/working-table.sqlite` under the trusted
canonical workspace root. No new CLI, namespace override, named tables, leases,
CAS, background cleanup, quotas, WAL tuning, automatic migration, new dependency,
lockfile generation, UI, or live HN network requirement is in scope.

Future implementation writePaths (exclusive to this plan):

- `Packages/RielaMemory/Sources/RielaMemory/RielaWorkingTableStore.swift` (new)
- `Packages/RielaMemory/Tests/RielaMemoryTests/RielaWorkingTableStoreTests.swift` (new)
- `Packages/RielaMemory/Tests/RielaMemoryTests/RielaWorkingTableConcurrencyTests.swift` (new)
- `Packages/RielaMemory/Tests/RielaMemoryTests/RielaWorkingTableFailureTests.swift` (new)
- `Packages/RielaMemory/Tests/RielaMemoryTests/RielaWorkingTableTestSupport.swift` (new)
- `Packages/RielaMemory/Tests/RielaMemoryTests/RielaKeyValueStoreTests.swift` (regressions only)
- `Sources/RielaCLI/ProductionNodeAdapter+WorkingTableAddon.swift` (new)
- `Tests/RielaCLITests/WorkingTableAddonTests.swift` (new)
- `Tests/RielaCLITests/KeyValueStoreAddonTests.swift` (regressions only)
- `impl-plans/progress/workflow-working-table-v1.json` (owner's future progress log)

sharedPaths (serial edits only, all included in this plan's authorized future scope):

- `Packages/RielaMemory/Sources/RielaMemory/SQLiteMemorySupport.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+StatefulAddonDispatch.swift`
- `Sources/RielaAddons/RielaAddons.swift`
- `README.md`

Do not edit existing durable store/adapter production behavior. Read
`MemoryEncodingSupport.swift`, `MemoryModels.swift`,
`Sources/RielaAddonSupport/WorkflowAddonSupport.swift`, and
`Sources/RielaCore/WorkflowAddonExecution.swift` for reusable types/helpers.
No package manifest change is needed: SwiftPM discovers sources in existing targets.
If a listed Swift file exceeds 1,000 lines, follow the local Swift coding skill's
responsibility-based split rule; record the exact necessary companion file before
editing and retain the same ownership. Do not undertake unrelated cleanup.

## Safe edit and progress protocol

Before future implementation, read applicable repository/Swift skill guidance,
accepted design, this plan, and current target files. Save an immutable intent
snapshot under `tmp/workflow-working-table-implementation/intent/` containing
accepted document bytes and SHA-256 digests, planId, exact owned paths, baseline
Git status/HEAD, and each target's SHA-256 or `absent` marker. Never overwrite that
snapshot; use numbered attempt directories for subsequent evidence.

Immediately before EVERY edit, fresh-read the file and compare its current hash
to the last recorded post-edit hash (initially the baseline). Record pre/post
hashes, task ID, and the purpose of the edit in the owner's progress log. For new
files verify continued absence. Unexpected drift requires stopping that edit,
reading the foreign change, and reconciling serially without restoring an old
snapshot over it. Retain foreign work; escalate incompatible intent rather than
silently overwriting. Before joining/final review, compare the entire intended
change against current files and reverify affected behavior after serial repair.

Only the owner edits `impl-plans/progress/workflow-working-table-v1.json`.
Include task status (`pending`, `running`, `blocked`, `complete`), dependencies,
changed paths/hashes, immutable intent snapshot paths, acceptance IDs, commands,
complete log paths, exit codes, test counts, findings and residual limitations.
No global progress indexes, other workers' logs, or plan archives are changed by
the worker. Shared indexes, any necessary lockfile regeneration, broad formatting
and global archiving are reserved for serial finalization; none is needed here.
Scratch fixtures/scripts/logs live under repository `tmp/`, never root/scripts.
Keep verification logs until downstream review consumes the evidence; remove
throwaway fixture databases/helpers after tests, never add scratch to Git.

## Serial task DAG

`WT1 -> WT2 -> WT3 -> WT4 -> WT5`. WT1 has no prerequisites. All subsequent tasks
depend on the immediately previous task. These are successive waves under one
plan, not independent worker assignments.

### WT1 — store contract, schema, and deterministic semantics

Changes: create `RielaWorkingTableStore.swift` and `RielaWorkingTableStoreTests.swift`;
make only the necessary numeric binding change in shared `SQLiteMemorySupport.swift`.

1. Bind store instances to trusted canonical workspace root and workflow ID at
   construction. Expose set/get/delete/list without per-call scope/root overrides.
   Add entry/list models in the new store file. Use an injectable sendable clock
   defaulting to UTC Unix seconds; no authored clock input. Reject empty runtime ID.
2. Implement schema `working_entries(workflow_id TEXT, key TEXT, value_json BLOB,
   written_at REAL, expires_at REAL)`, all NOT NULL, primary key `(workflow_id,key)`,
   JSONB validity check, and `(workflow_id,expires_at)` index. Serialize initial
   schema creation and subsequent operations with SQLite transactions. An existing
   incompatible schema must fail, not be dropped or silently reinitialized.
3. Add `SQLiteBinding.double(Double)` using `sqlite3_bind_double`. Existing cases
   and memory schema version stay unchanged. The shared query helper currently
   stringifies values: decode working-table times with `sqlite3_column_double` in
   a small store-local row reader to preserve exact stored Double precision. Reuse
   JSON encoding, binding, and statement error patterns, not an all-store rewrite.
4. Validate key exactly (nonempty, trimmed equality, <=1,024 UTF-8 bytes), finite
   JSON values, TTL and list arguments before opening/mutating storage. Default
   TTL=21,600; numeric finite `0 < ttl <= 2,592,000`, including fractions. Store
   methods enforce numerical bounds even when bypassing the adapter.
5. Missing-database get/list/delete return miss/empty/false without file creation.
   Otherwise use five-second busy timeout, BEGIN IMMEDIATE, one time sample after
   lock acquisition, own-workflow expired-row cleanup, operation, result construction,
   COMMIT, then return. Roll back on failure and close/finalize all handles/statements.
6. Set atomically replaces JSON and resets writtenAt/expiresAt; omitted TTL on
   overwrite resets to six hours. Read/list live predicate is `expires_at > now`;
   delete reports whether a live row was removed. List filters before BINARY key
   order and limit/offset. Never refresh TTL on reads. No automatic cross-workflow
   cleanup, vacuum, or filesystem deletion.

Acceptance A1: deterministic fake-clock tests cover each JSON type/null, key
boundaries, default/fractional/max/invalid numeric TTL, overwrite/reset, exact
before/equal/after expiry, smallest-positive rounding to immediate expiration,
read-without-refresh, live/expired/repeated delete, SQL-filter-before-pagination,
BINARY ordering, invalid pagination, missing file, reopen persistence, workflow
isolation, and physical cleanup scoped to the owner. Assert stored timestamp
round trips without precision loss. Clock forward/backward tests reproduce the
documented behavior, including uncollected rows becoming live after backward jumps.

Verification: V1 (below); record actual test names/counts, no sleep-based TTL tests.

### WT2 — transaction contention and failure evidence

Changes: create `RielaWorkingTableConcurrencyTests.swift`,
`RielaWorkingTableFailureTests.swift`, and `RielaWorkingTableTestSupport.swift`;
repair only WT1 files as failures require. Do not add a public failure-injection API.

Use test-owned SQLite connections and foreground-owned child test processes with
pipe/marker barriers and bounded deadlines, not timing sleeps or detached shell
jobs. Implement a helper entry in the test suite that re-enters the built XCTest
executable for the selected helper test with an explicit test-only environment
mode and fixture path; the parent waits for/reaps every child, kills/reaps on
failure, and records child output/exit. Keep all fixture files under repository
`tmp/workflow-working-table-implementation/fixtures/`. The helper must exercise the
real store methods; a second raw SQLite connection alone is insufficient evidence
for concurrent store first-open/write behavior.

Acceptance A2: separate processes racing first creation succeed coherently;
distinct-key writers retain both updates; controlled same-key set/delete ordering
matches last committed operation; each set returns its own value/deadline despite
a waiting writer; cleanup never deletes a later live update or another workflow's
rows. Use held writer locks to test waiting and five-second busy failure. Assert
the operation samples the fake clock only after acquisition, not before waiting.

Acceptance A3: exercise invalid JSONB/corrupt file and incompatible schema;
unwritable path; injected SQLite write/cleanup errors via fixture triggers; and
full-database behavior via fixture page limits. For commit failure, a separate
reader transaction under default rollback-journal mode can hold a shared lock:
writer reaches COMMIT, times out, and rolls back. Verify original rows remain,
failed cleanup leaves no partial mutation, errors are visible, and handles release
so a later valid operation works. Use deterministic fixture hooks/barriers only
where necessary to demonstrate process death before commit vs response loss after
commit. After-commit test discards the returned result and retries: reset TTL and
repeated-delete false are expected, not idempotency guarantees. Unsupported JSONB
must produce an explicit error; use a narrow internal test seam only if the host
SQLite cannot simulate capability failure. Document the seam and exercise real
capability probing on the host; never report an unexecuted branch as covered.

Verification: V1 and V2. Do not replace these scenarios with mocks of the store.

### WT3 — runtime adapter and serial registration

Changes: create `ProductionNodeAdapter+WorkingTableAddon.swift` and
`WorkingTableAddonTests.swift`. Serial edits to `ProductionNodeAdapter.swift`,
`ProductionNodeAdapter+StatefulAddonDispatch.swift`, and `RielaAddons.swift`.

1. Add an immutable working-table workspace property to the existing resolver,
   initialized once from its trusted `workingDirectory` with path standardization
   and symlink resolution. Do not change the workingDirectory behavior of other
   add-ons. Provide only the narrow internal clock seam needed for adapter tests.
2. Register/dispatch four version-1 `riela/working-table-{set,get,delete,list}` names;
   accept omitted version like existing built-ins and reject unsupported versions.
   Leave all existing descriptors and dispatch intact.
3. Read declared arguments only from config and explicit `input.addon.inputs`.
   Validate their key allowlists independently, then render explicit inputs with
   existing template helpers and merge config ahead of inputs by presence. Do not
   use `resolvedInputPayload`, `variables`, workflowInput, or environment as argument
   defaults. Existing merged variables may supply template context only. Identity
   ALWAYS comes directly from input.workflowId and the pinned workspace property.
4. Reject reserved selectors listed in the design and unknown fields in config or
   explicit inputs even if shadowed. Resolve value/valueTemplate by field presence
   then reject coexistence; render valueTemplate through existing JSON templates.
   Preserve literal value semantics. Accept only JSON numeric TTL, strict key
   strings and exact integer pagination (check representability before conversion).
   Null is valid value but invalid TTL/key/pagination, never an omission.
5. Emit exact design payloads: set saved/entry; get found/value and entry only on
   hit; delete deleted/key; list entries/count/limit/offset; standard status/addon/
   operation/stepId. Entries expose only key/value/writtenAt/expiresAt. Return
   numeric timestamps. Map failures to visible adapter errors without values or
   silent misses; do not expose caller-selectable namespace metadata.

Acceptance A4: adapter tests verify all four operations/output contracts, omitted
and invalid versions, template arrays/scalars/null, config precedence, conflicting
value fields, string/bool/null/nonfinite/out-of-bound TTL, unknown-field rejection,
TTL on wrong operation, and fractional/unrepresentable pagination rejection.
Override tests try every reserved selector in config and explicit inputs and prove
rejection; the same names in ambient variables/workflowInput/environment must have
no namespace effect. Poisoned ambient key/value/TTL do not become defaults.
Same workflow/different sessions share entries; different workflows/workspaces do
not. Symlink aliases resolve to one workspace. A called workflow uses its own ID.
Use actual resolver inputs, not only mocks, and no production path overrides.

Verification: V3 and V4.

### WT4 — cache example, compatibility, and user documentation

Changes: extend new adapter/store tests and the two existing KV test files; update
README.md immediately adjacent to its current durable KV section.

Acceptance A5: run a deterministic HN sequence with a fake page-fetch counter and
fake clock: first miss fetches/parses/sets; subsequent run at +21,599 reuses JSON;
+21,600 misses; failed fetch/parse creates no entry; another workflow misses;
overlapping misses may fetch twice and last committed JSON wins. Use fixed item
URLs from the design, no live network, authored registry changes, or new workflow
bundle. Test manual opt-in copy from a durable entry gets a fresh TTL without
changing/deleting its original durable/shared entry. Show durable KV remains
readable beyond thirty days in the clock-controlled test context, unchanged TTL-free
schema, explicit shared scopes/root/storeId still work, and new cleanup cannot
modify the durable database.

README must show the four new names, example config with key/value and optional
TTL, null/miss behavior, six-hour default/thirty-day bound, no caller namespace,
non-atomic fetch races, wall-clock/physical-cleanup limits, and additive opt-in
coexistence. Keep existing durable examples. Tests are the executable HN example;
do not create a separate example framework or require network credentials.

Verification: V1, V3, and documentation review against accepted design.

### WT5 — serial reconciliation and completion handoff

Depends on WT4. Fresh-read all edited/shared files, compare recorded hashes and
intent, preserve unrelated changes, and repair detected drift serially. Review
invariants below, all A1–A5 assertions, and README accuracy; do not globally format
or archive plans. Run V1–V6 on final content; rerun only affected gates if subsequent
repairs alter content. Finish only with zero unresolved high/mid findings and
complete logs/terminal exits. Record remaining low risks candidly in the owner's
progress log. No worker commit, push, branch switch, or registry discovery.

## Invariants and final verification

Namespace derives from trusted workspace/workflow identity alone. Exact TTL
predicate/reset rules match the design. No expired entries leak into pagination.
Cleanup cannot cross workflow boundaries. No failure silently becomes a miss.
Durable KV contracts/schema stay unchanged. No implementation is authorized by
this planning-only node. Implementation gates below are future commands, not
checks already passed by the author.

Run commands at repository root, in foreground, capturing complete stdout/stderr
and final exit status individually under
`tmp/workflow-working-table-implementation/verification/<gate>.log`. Use a small
foreground subprocess wrapper stored under tmp if needed; do not let tee or a
trailing echo mask exit status. Retain/poll tool session handles to terminal exit.
Zero selected tests, truncated logs, timeouts, unavailable tools, or unexecuted
failure branches are gaps, never passing evidence. No shell background jobs.

| Gate | Exact command | Required evidence |
| --- | --- | --- |
| V1 | `swift test --package-path Packages/RielaMemory --filter 'RielaWorkingTableStoreTests|RielaWorkingTableConcurrencyTests|RielaWorkingTableFailureTests|RielaKeyValueStoreTests'` | A1–A3 and durable store tests selected, passed, counts and child exits recorded |
| V2 | `swift test --package-path Packages/RielaMemory` | Shared Double-binding change preserves all memory-store tests |
| V3 | `swift test --filter 'WorkingTableAddonTests|KeyValueStoreAddonTests'` | A4–A5 and durable adapter behavior pass, nonzero counts |
| V4 | `swift build` | Swift typechecking and complete root integration build succeed |
| V5 | `swiftlint --quiet --no-cache` | Lint terminal outcome; distinguish pre-existing findings with baseline evidence, fix introduced diagnostics |
| V6 | `git diff --check` | No tracked patch whitespace errors; also inspect newly added files before staging |

The existing design's shorter store filter does not include the dedicated
concurrency/failure suites; V1 intentionally includes them. Swift build is the
required typecheck; there is no web/UI change requiring browser tests. No new
external dependency or package-digest refresh is needed for this document-only
run. A future source change must obey applicable package rules if it expands scope.

Completion requires A1–A5 and V1–V6 evidence, per-edit hashes and progress entries,
no unauthorized changed paths, serial reconciliation, and independent review of
actual code in a later authorized execution. The present deliverable is this plan
for Step 5 review, followed by the planning-only adversarial/finalization path.
No unresolved user decision or accepted design defect was found during authoring.
