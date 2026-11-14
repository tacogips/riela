# gcc-02-concurrent-collector: full listing, concurrent thread reads, real early-stop stages

```json
{
  "planId": "gcc-02-concurrent-collector",
  "planPath": "impl-plans/active/gmail-collect-concurrency-02-concurrent-collector.md",
  "dependsOn": ["gcc-01-request-limiter"],
  "wave": "W2",
  "writePaths": [
    "Sources/RielaCLI/GmailCollection.swift",
    "Sources/RielaCLI/GmailCollectionCoordinator.swift",
    "Sources/RielaCLI/ProductionNodeAdapter+GmailCollect.swift",
    "Tests/RielaCLITests/GmailCollectionTests.swift",
    "impl-plans/progress/gcc-02-concurrent-collector.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

**User intent.** In `riela/gmail-collect`, `maxThreads` now means the maximum
number of concurrent per-thread reads. It is no longer a per-run cap on how
many threads are listed or processed. One run must list the whole query result
and process every listed thread. Today a 48h ART scan with more than 150
threads and `maxThreads: 150` stops every other run with failure stage
`budget`, which delays mail by about an hour.

**Source of truth.** design-docs/specs/design-native-source-collection.md, Gmail section:

- the `maxThreads` clause in the Options paragraph;
- subsection "Full listing, concurrent thread reads and early-stop reasons",
  including the stop table and the Swift 6 paragraph.

Accepted decisions D1-D10 from the design step apply.

**Current code (main 164d2b75).**

- `GmailCollection.swift:81-265` `GmailMailboxCollector.collectScan`:
  - the `read` helper is at lines 93-101;
  - the listing loop at 157-170 is capped by `options.maximum`;
  - the thread loop at 180-232 iterates `queue.prefix(options.maximum)`;
  - the generic `budget` fallback is at 248.
- `GmailCollectionCoordinator.swift:8-149` `collect`: captures
  `var usedProfile` at 88-91 to serve the profile it already read.
- `ProductionNodeAdapter+GmailCollect.swift:20-32`: a nested `fetch` runs one
  child `riela/gmail-gateway-reader` execution per call, with a 30s child
  deadline.

**Dependency.** gcc-01 provides `GmailCollectionRequestLimiter` (actor) and
`GmailCollectionDeadlineRefusal` in
`Sources/RielaCLI/GmailCollectionRequestLimiter.swift`. Use them exactly as
pinned in impl-plans/active/gmail-collect-concurrency-01-request-limiter.md.
Do not edit that file. If it is wrong, record the issue in the progress log
and stop.

## Non-goals (must not change)

- `GmailCollectionOptions` validation stays the same:
  - `maxThreads` keeps range 1...10000 and default 100;
  - the scope hash (`scopeContext`, lines 71-77) stays as is. `maxThreads`
    must NOT enter the scope.
- No change to the `pending_collection` key set (line 134) or the
  `listing["maximum"] == .integer(10_000)` check (line 137). No change to
  `advancePage`, `threadSelection`, `bodySelection`, `gmailIdentifier` or
  `gmailIDSet`.
- No change to `GmailMessageBodyCollector` (`GmailMessageBodyCollection.swift`),
  `GmailCollectionRetryBacklog.swift`, the X collector or any other collector.
- No change to coordinator behavior: scope archive, retry backlog, the
  `fresh-capacity` failure and the `complete=false` setting when the backlog
  is non-empty. Do NOT add a `budget`-style failure for the coordinator's
  backlog `complete=false` (line 127). That is existing, intentional behavior.
- Do not edit the design doc or the gcc-01 files. No README or docs changes;
  none reference `maxThreads`. No new dependencies. No `@unchecked Sendable`,
  `nonisolated(unsafe)` or `Mutex` in production code.

## File-level changes

### `Sources/RielaCLI/GmailCollection.swift`

1. **`GmailMailboxCollector` stored closures.**
   - `var clock: @Sendable () -> Date = { Date() }`
   - `var wait: @Sendable (Double) async throws -> Void = { ... }` (same body)

   With these, the struct is implicitly `Sendable` (internal struct, all
   stored properties Sendable). Keep `GmailCollectionOptions` free of
   non-Sendable members.
2. **`collectScan` signature.**
   ```swift
   func collectScan(prefetchedProfile: JSONObject? = nil,
                    fetch: @escaping @Sendable (String, JSONObject, [String]) async throws -> JSONObject) async throws -> JSONObject
   ```
   (`withoutActuallyEscaping` is an acceptable alternative to `@escaping`. The
   closure must be `@Sendable` either way.)
3. **Limiter.** Create one `GmailCollectionRequestLimiter(interval: options.interval, deadline: deadline, clock: clock, wait: wait)` per `collectScan`.
   - If `prefetchedProfile` is non-nil, call `recordPrefetchedGrant()` and use
     it as the profile.
   - Otherwise, `acquire()` then `fetch("profile", ...)`. A
     `GmailCollectionDeadlineRefusal` here maps to
     `throw AdapterExecutionError(.timeout, "Gmail collection execution budget exhausted")`.
     This is the current behavior: profile failures propagate.
   - Remove the old `read` helper and the `requests` counter.
   - `requestCount` in the result is `await limiter.grantedCount`, read after
     all thread tasks finish.
4. **Listing loop (157-170).**
   - Remove `beforeCount`/`options.maximum`. Set `remaining = 10_000 - selected`.
   - If `remaining <= 0`, record `failure("listing-limit")` and break. The
     loop only runs while `page["complete"] != true`.
   - Request `first: min(50, remaining)`.
   - Before each listing request, `try await limiter.acquire()`.
   - Catches:
     - `CancellationError` → rethrow;
     - `GmailCollectionDeadlineRefusal` → record `deadline` once, then break;
     - any other error → `failure("listing")`, then break (unchanged).
   - The thread phase still runs on the listed prefix after any listing stop.
5. **Thread phase (replaces 180-232).**
   - Effective concurrency `C = min(options.maximum, 16)`.
   - The `queue` construction (lines 175-179: fresh in listing order, then
     deferred rotated after `retryAfter`) stays exactly as is, but the
     `.prefix(options.maximum)` is removed.
   - Take an immutable snapshot of `versions` for the workers. Workers read
     only that snapshot. Each ID appears once in the queue.
   - Pass the worker the RAW stored value (`versions[id]`, a `JSONValue?`).
     Call `gmailVersion(...)` INSIDE the worker's error mapping. A malformed
     stored version must become `.failed` for that ID only, as the current
     per-item `do/catch` does. Never parse it on the parent in a way that
     aborts the whole scan.
   - **Worker.** Add a new `private` method (for example
     `readThread(id:previousVersion:limiter:fetch:) async throws -> GmailThreadReadOutcome`)
     that does what lines 184-205 do today:
     - the optional version check, only when `previousVersion != nil && options.bodyIDs.isEmpty`;
     - the full read;
     - identity and message checks;
     - `messageBodyBytes` for requested IDs, plus the body-complete check;
     - `_fetched_at` set via `clock()`.

     Call `try await limiter.acquire()` before EVERY `fetch`. Track whether at
     least one acquire for this ID was granted.
   - **Worker outcome enum** (private, `Sendable`):
     ```swift
     enum GmailThreadReadOutcome: Sendable {
       case unchanged
       case fetched(thread: JSONObject, stamp: String?, bodies: Set<String>)
       case failed
       case refusedBeforeStart
       case refusedAfterStart
     }
     ```
   - **Worker error mapping.**
     - `CancellationError` → rethrow.
     - `GmailCollectionDeadlineRefusal` → `.refusedBeforeStart` if no acquire
       was granted for this ID, else `.refusedAfterStart`.
     - Any other error (provider or validation) → `.failed`.
     - The worker must never touch the checkpoint, `completed`, `deferred`,
       `found`, `threads` or `invalidated`.
   - **Scheduler.** Use `withThrowingTaskGroup(of: (Int, GmailThreadReadOutcome).self)` on the parent.
     - Launch queue index `i` only while
       `launched < queue.count && launched - acceptCursor < C && !stopScheduling`.
     - Buffer outcomes by index. After each received outcome, accept every
       buffered outcome at `acceptCursor` in order, then top up launches.
     - Set `stopScheduling = true` when an outcome is `.refusedBeforeStart` or
       `.refusedAfterStart` (on receipt), or after an output-budget refusal
       (on accept).
     - After the group drains, every launched index has been accepted in order.
     - Indices never launched stay untouched: pending, neither completed nor deferred.
   - **In-order accept rules** (parent only, sequential). Keep today's
     `proposed` checkpoint construction verbatim (lines 206-222).
     - `.unchanged`: set `retryAfter = id`, `completed.insert(id)`, `deferred.remove(id)`.
     - `.fetched`:
       1. Set `retryAfter = id`.
       2. Build `proposed` exactly as today.
       3. If the reservation guard (`encode(projected).count + 65_536 <= outputByteBudget`)
          fails: record `failure("output-budget", id: id)`, `deferred.insert(id)`,
          set `stopScheduling = true`, and do not accept.
       4. Otherwise accept exactly as lines 224-226.
       5. If any other error is thrown while accepting, record
          `failure("thread", id: id)` and `deferred.insert(id)`, as today.
     - `.failed`: `retryAfter = id`, `failure("thread", id: id)`, `deferred.insert(id)`.
     - `.refusedAfterStart`: `retryAfter = id`, `deferred.insert(id)`, and record `deadline` once.
     - `.refusedBeforeStart`: record `deadline` once. Leave `retryAfter`,
       `completed` and `deferred` untouched.
   - Keep a single `deadlineRecorded` flag shared by the listing and thread
     phases, so the `deadline` failure appears once per scan.
   - Remove the old per-item deadline breaks (lines 181 and 230). The limiter
     replaces them.
6. **Completion (233-252).** Unchanged, except:
   - delete line 248 (`if failures.isEmpty { recordFailure(failure("budget")) }`);
   - keep the `requested-body` branch.
7. Failure records keep the existing shape:
   `{stage, code: "acquisition-unavailable", threadId?}`. The new stages are
   `"deadline"`, `"output-budget"` (with `threadId`) and `"listing-limit"`.

### `Sources/RielaCLI/GmailCollectionCoordinator.swift`

- `collect(fetch: @escaping @Sendable (String, JSONObject, [String]) async throws -> JSONObject)`.
- Delete `var usedProfile` and the wrapping closure (lines 88-92). Call
  `scan.collectScan(prefetchedProfile: profile, fetch: fetch)`.
- Nothing else changes. The coordinator's own direct `fetch("profile", ...)`
  at line 36 stays outside the limiter, as today.

### `Sources/RielaCLI/ProductionNodeAdapter+GmailCollect.swift`

- Mark the nested function `@Sendable func fetch(...)`. It captures only
  Sendable values: `input`, `context` and `self`
  (`BuiltinWorkflowAddonResolver: WorkflowAddonResolving: Sendable`).
- The two `collect(fetch: fetch)` calls stay. A `@Sendable` function converts
  to `GmailMessageBodyCollector.collect`'s non-Sendable parameter.
- No other change.

### `Tests/RielaCLITests/GmailCollectionTests.swift`

**Sendable fixtures.**

- Move the fixture helpers into a file-private `enum GmailFixture` with
  `static` funcs. The helpers are `options`, `input`, `profile`, `page`,
  `thread`, `object` and `invalid`. Inside `@Sendable` closures call
  `GmailFixture.page(...)`, never `self.page(...)`: capturing a non-Sendable
  `XCTestCase` `self` does not compile under Swift 6.
- Add one small file-private lock box, imitating `GmailCollectTransport`
  (line 439): `final class GmailLocked<Value>: @unchecked Sendable` with
  `NSLock` and `withLock`. Use it for every value a fetch, clock or wait
  closure mutates. That covers `instant`, `calls`, `seen`, `reads`,
  `fullReads`, `pages`, `attempts`, `attempt`, `freshReads` and the in-flight
  counters.
- Keep `GmailCollectTransport` as is.

**Deadline helper.** Build deadline stops with a lock-boxed fake clock:

- the collector gets `deadline: t0 + 1` and `clock: { box.now }`;
- the thread `fetch` advances `box.now` by 2;
- use `maxThreads: 1` whenever a test needs exactly one thread read per run.

With `C >= 2`, several reads acquire slots before the clock moves.

**Rewrite these tests.** Keep each test's name and the guarantee it protects.

- **`testSmallRunResumesExactListingCursorAndKeepsPreScanMailboxVersion`.**
  - Run 1: the first `threads` call asserts `first == 50`, returns
    `page(["a"], cursor: "continue-exactly")` and advances the clock past the
    deadline. Expect `complete == false`, a failure with stage `deadline`, and
    no `a` in completed.
  - Run 2 (profile 11): the `threads` call asserts
    `after == "continue-exactly"` and returns `page(["b"])`. Both threads are
    read. Expect `seen == ["profile","threads","thread","thread"]` (thread
    order between a and b may vary; assert the multiset of operations) and
    `complete == true`.
  - Checkpoint: `mailbox_version == "10"`, `thread_versions == {a:8, b:9}`,
    and no `pending_collection`.
- **`testFailedItemCannotMonopolizeOneItemRuns`.** `maxThreads: 1`.
  - Run 1: `threads` returns `page(["a"], cursor: "next-page")`. The second
    `threads` call (after `next-page`) throws (`listing` failure). Thread `a`
    throws.
  - Run 2: a deadline that allows one thread read. The listing resumes and
    returns `page(["b"])`. Only `b` is read (fresh before deferred).
  - Expect `invalidated == ["b"]`, `complete == false`,
    `pending.completed == ["b"]` and `pending.deferred == ["a"]`.
- **`testDeadlineContinuationDoesNotReadAlreadyCompletedThreadsAgain`.** Add
  `maxThreads: 1` and a lock-boxed clock. Additionally assert that run 1's
  failures contain stage `deadline` and that `pending.deferred` is empty
  (b was refused before start).
- **`testBudgetStopsBeforeAnotherProviderCallAndCancellationPropagates`.**
  Lock-boxed `instant`/`calls`. Keep `calls == 1` and `complete == false`.
  Additionally assert the failures contain stage `deadline` (it was `listing`
  before; this divergence is accepted). Keep the cancellation half unchanged.
- **`testBodyBudgetRetainsAcceptedPrefixAndDoesNotAcknowledgeOversizedItem`.**
  Keep the assertions and add one: the failures contain
  `{stage: "output-budget", threadId: "b"}`.
- **`testAllFailedItemsReceiveFairRetryTurnsAtOneItemBudget`.** `maxThreads: 1`.
  - Every turn uses a fresh clock box and a deadline that allows one thread read.
  - The listing returns `page(["a","b"])` (complete). All thread reads throw.
  - Expected `attempts == ["a","b","a","b","a","b"]`.
- **`testPoisonBacklogDoesNotBlockFreshMailAndPreservesExactOldCursor`,
  `testLongRunningScanKeepsDiscoveryFloorAndScopesSurviveBodyIntentSwitch`,
  `testDrainingOldCursorCannotRemoveAlreadyAcquiredFreshThreadVersions` and
  `testRequestedBodyFoundByFreshScanRemainsKnownWhenOldCursorDrains`.**
  - **Why they change.** In turn 0 (the first run) the collector now keeps
    listing past the first page. It sends a second listing request whose
    `after` equals the old cursor (`poison-cursor` / `literal-old-cursor` /
    `old`). Today that branch would return page `a` again.
  - **Rule.** ONLY in turn 0 must that old-cursor request THROW (a `listing`
    failure, so the old cursor stays saved). Every other turn keeps its
    current listing behavior exactly.
    - Turns that already throw keep throwing.
    - Turns that drain keep draining.
    - Do NOT make the old-cursor request throw in every turn.
  - **Per-test turn map:**
    - `testPoisonBacklog...`:
      - Turn 0 (fresh) returns `page(["a"], cursor: "poison-cursor")` for the
        request with no `after`. The request with `after == "poison-cursor"`
        throws (new).
      - Turn 1 (resume) asserts `after == "poison-cursor"` and throws
        (unchanged).
      - Turn 2 (fresh) asserts `after` is nil and returns `page(["new"])`
        (unchanged).
      - Restructure the closure: test `after == "poison-cursor"` first (throw),
        and keep `XCTAssertNil(input["after"])` only on the non-cursor branch.
    - `testLongRunning...`:
      - The first run's request with `after == "literal-old-cursor"` throws
        (new).
      - The body-intent run, the resumed run (asserts the old cursor, then
        throws) and the final fresh run (asserts `after` is nil) are unchanged.
    - `testDraining...` and `testRequestedBodyFound...`:
      - Turn 0: the request with `after == "old"` throws (new). The first
        request still returns `page(["a"], cursor: "old")`.
      - Turn 1 (resume) throws for every listing request (unchanged).
      - Turn 2 (fresh) returns `page(["b"])` (unchanged).
      - Turn 3 resumes the old scan: `fresh_profile_version` is 11, so
        `newProfile` is false. Its request with `after == "old"` MUST keep
        returning `page([])` (the existing `turn == 2 ? ["b"] : []` branch).
        The old scan then drains: `a` is read at version 8 and the scan
        completes.
  - Remove a turn-0 `XCTAssertNil(input["after"])` only where the second
    turn-0 request now carries the old cursor. Do this by branching on the old
    cursor first, not by deleting assertions for other turns.
  - Keep every other assertion unchanged:
    - the exact old cursor retained in `pending_scans` (`poison-cursor`);
    - `attempt == 1`;
    - the discovery floor `<= firstTime - 86_400` with nil `after`;
    - turn-3 `active_threads == [a,b]`, `thread_versions == {a:8, b:8}` and
      nil `mailbox_version`;
    - turn-3 `found_body_ids == ["message-b"]`, nil `pending_scans` and
      `complete == true`;
    - the final fresh `complete == true`.
  - `maxThreads` may stay or be dropped.
- **`testPermanentPoisonDoesNotAccumulateOneScanPerFreshProfile`.** Only the
  lock box for `freshReads` changes. `freshReads == 35` and
  `scans.count == 1` must still hold.
- **All other tests.** Mechanical changes only (fixtures and lock boxes).
- **Never edit or weaken** the scope goldens in
  `testWindowRewritesRelativeFiltersAndPreservesLegacyScopeIdentity`
  (`29b73447...`) and
  `testScopeMatchesLegacyCanonicalJSONAndCannotCrossAccountsOrQueries`
  (`c4ee206a...`).

**New tests** (`situation -> expected`):

- **`testOneRunListsEveryPageAtPageSizeFiftyWithOneThreadConcurrency`.**
  `maxThreads: 1`. Three pages: `["a","b"]` (cursor `p1`), then `["c","d"]`
  (cursor `p2`), then `["e"]`. Expect:
  - every `threads` request has `first == 50`;
  - `complete == true` and no `pending_collection`;
  - `invalidated == ["a","b","c","d","e"]`;
  - empty failures.
- **`testThreadReadConcurrencyIsBoundedAndResultsStayInListingOrder`.**
  `maxThreads: 4`, 12 listed IDs. The fetch for a thread increments a locked
  in-flight counter, records the high-water mark, sleeps
  (`Task.sleep(for: .milliseconds(...))`, longer for earlier IDs so they
  finish out of order), then decrements. Expect:
  - high-water mark `<= 4` and `>= 2`;
  - `invalidated` and the `threads` ids exactly in listing order;
  - `complete == true`.
- **`testThreadReadConcurrencyClampsAtSixteen`.** `maxThreads: 10000`, 40 IDs.
  Expect the high-water mark `<= 16` and `> 4`.
- **`testRequestStartsShareOneLimiterAcrossWorkers`.**
  - Setup: `minRequestIntervalSeconds: 2.5`, `maxThreads: 4`, a frozen clock
    and no deadline. `wait` records its durations in a lock box.
  - Expect `requestCount == n` (profile + listing + reads).
  - Expect the recorded waits sorted to equal `[2.5, 5.0, ..., 2.5*(n-1)]`.
- **`testListingLimitRecordsListingLimitStage`.**
  - Setup: the listing returns pages of 50 unique IDs, with a cursor
    `p<k>` that has a next page, forever. Thread reads throw (cheap).
  - Expect exactly 200 `threads` calls, each with `first == 50`.
  - Expect `complete == false` and a failure with stage `listing-limit`.
  - Expect `pending_collection.listing.maximum == 10000`.
  - Use fixture IDs such as `t00001`, which pass `gmailIdentifier`.
- **`testCoordinatorPrefetchedProfileKeepsRequestCount`.**
  - Setup: `collect(...)` with one listed thread, interval 0.
  - Expect the provider `profile` operation is called exactly once.
  - Expect `requestCount == 3` (prefetched profile + listing + thread).

## Invariants (verify by review and tests)

- `thread_versions`, `completed`, `found` and `invalidated` advance only on
  the parent's in-order accept path, never inside a worker task.
- `threads` and `invalidated` are a subsequence of queue order.
- No generic `"budget"` stage string remains:
  `grep -n '"budget"' Sources/RielaCLI/GmailCollection.swift` has no matches.
- `options.maximum` is used only to compute `C`:
  `grep -n "options.maximum" Sources/RielaCLI/GmailCollection.swift` shows a
  single `min(options.maximum, 16)` use.
- `CancellationError` from any worker or the parent propagates out of
  `collectScan` and `collect`. No partial result.
- The scope hash is unchanged (golden tests).

## Concurrent-edit hygiene

Before the first edit:

- Record the SHA-256 of each owned file in the progress log.
- Capture the guard baseline for the four files this plan must NOT modify. The
  design doc is an uncommitted modification and the limiter file is untracked,
  so git diff cannot guard them; use hashes:
  `mkdir -p tmp/gmail-collect-concurrency/gcc-02 && shasum -a 256 Sources/RielaCLI/GmailMessageBodyCollection.swift Sources/RielaCLI/GmailCollectionRetryBacklog.swift Sources/RielaCLI/GmailCollectionRequestLimiter.swift design-docs/specs/design-native-source-collection.md > tmp/gmail-collect-concurrency/gcc-02/guard-pre.sha256`
- Copy those four hashes into the progress log.

Read each file fresh before every edit. If a file's hash changed since your
last read, re-read it and reapply your intent; never overwrite blindly. Never
run git commands that change the index or the worktree (no checkout, stash,
reset or commit).

## Verification (logs under `tmp/gmail-collect-concurrency/gcc-02/`)

1. `mkdir -p tmp/gmail-collect-concurrency/gcc-02`
2. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/gmail-collect-concurrency/gcc-02/build.log 2>&1'`
   Must exit 0, with no `error:`/`warning:` lines for the four owned Swift files.
3. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter GmailCollection > tmp/gmail-collect-concurrency/gcc-02/test-gmail.log 2>&1'`
   Must exit 0, run GmailCollectionTests (all old plus 6 new methods) and
   GmailCollectionRequestLimiterTests, and report 0 failures.
4. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter RielaCLITests > tmp/gmail-collect-concurrency/gcc-02/test-rielacli.log 2>&1'`
   Must report no failures in Gmail* tests. For any other failure:
   - record its name;
   - re-run it alone with `--filter <TestClass>/<testMethod>` into
     `tmp/gmail-collect-concurrency/gcc-02/rerun-<name>.log`;
   - classify it as a pre-existing or known timing flake unrelated to the
     owned files, with evidence.

   New failures attributable to this change block completion.
5. `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/GmailCollection.swift Sources/RielaCLI/GmailCollectionCoordinator.swift "Sources/RielaCLI/ProductionNodeAdapter+GmailCollect.swift" Tests/RielaCLITests/GmailCollectionTests.swift > tmp/gmail-collect-concurrency/gcc-02/swiftlint.log 2>&1'`
   Must exit 0. Keep `collectScan` under the function_body_length warning (200
   lines) by extracting the worker and accept helpers.
6. `shasum -a 256 Sources/RielaCLI/GmailMessageBodyCollection.swift Sources/RielaCLI/GmailCollectionRetryBacklog.swift Sources/RielaCLI/GmailCollectionRequestLimiter.swift design-docs/specs/design-native-source-collection.md > tmp/gmail-collect-concurrency/gcc-02/guard-post.sha256 && diff tmp/gmail-collect-concurrency/gcc-02/guard-pre.sha256 tmp/gmail-collect-concurrency/gcc-02/guard-post.sha256`
   Must exit 0. This shows the four guarded files are byte-identical to the
   pre-edit baseline. It does not depend on whether they are committed,
   modified or untracked. Record the post hashes and the diff exit status in
   the progress log. Never commit, stash, checkout or reset to make this pass.
   If it fails, restore only your own accidental change from your recorded
   intent and report it.

## Done criteria

- Verification steps 2, 3, 5 and 6 exit 0 with complete logs. Step 4 shows no
  new failures, and any non-Gmail failures are classified with rerun logs.
- The grep invariants above hold:
  - no `"budget"`;
  - a single `options.maximum` use;
  - `GmailCollectionCoordinator.swift` has no `usedProfile`
    (`grep -n usedProfile` has no matches);
  - `ProductionNodeAdapter+GmailCollect.swift` contains `@Sendable func fetch`.
- `impl-plans/progress/gcc-02-concurrent-collector.md` lists:
  - the changes per file;
  - pre/post SHA-256 values;
  - every rewritten and new test, with the guarantee it protects;
  - a verification table with command, exitStatus, testsRun, failureCount and log path.
