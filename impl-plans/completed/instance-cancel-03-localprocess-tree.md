# instance-cancel-03: LocalProcess cancellation reclaims the whole process tree

**planId**: instance-cancel-03-localprocess-tree
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-instance-cancel.md §2 (LocalProcess and nested-riela rows, the counterexample), §3 C8, §5 RielaAdaptersTests, §7
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/instance-cancel-03-localprocess-tree.md
**Evidence root**: tmp/instance-cancel/instance-cancel-03-localprocess-tree/

## Intent and context

Each command spawned by `LocalProcess` leads its own process group
(`Sources/RielaAdapters/LocalProcess.swift:653-669`), so the groups of a
nested `riela workflow run` are different groups.

Today a Task cancellation behaves like this:
- `cancelConfiguredProcess` (about lines 413-423) sends SIGTERM to the owned
  group only and schedules a SIGKILL 1 s later;
- the leader-exit observer (about lines 804-813) calls
  `processHandle.killGroupOrProcess()` as soon as the leader exits.

So a wrapper that exits on SIGTERM gets its group SIGKILLed at once. That
group includes the nested `riela`, which is still cleaning up its inner groups
cooperatively, and the inner groups then survive. This plan implements C8:
track the tree across groups and escalate only after a grace, returning only
when the tree is gone.

## Non-goals (must stay byte-for-byte behaviorally unchanged)

- Spawn flags and `spawnProcess`.
- The normal-exit path: no cancellation means the immediate
  `killGroupOrProcess()` after leader exit stays.
- The deadline-timeout work item (about lines 844-858, still
  `scheduleKillIfRunning(after: 1)`).
- The `await-owner` policy (`signalOwner`, no escalation, no tracking).
- The public `LocalProcessRunning` API.
- `Sources/RielaAppSupport/RuntimeEnvironmentProcessRunner.swift` and
  `Sources/RielaCLI/ProductionNodeAdapter+GitProcess.swift`.

## File-level changes

### Sources/RielaAdapters/LocalProcessTree.swift (new)

- `struct LocalProcessTreeEntry: Equatable, Sendable { pid: pid_t; ppid: pid_t; pgid: pid_t; startTime: UInt64 }`.
  Darwin: `startTime` is `p_starttime` seconds*1e6+usec. Linux: field 22.
- `protocol LocalProcessTreeSnapshotting: Sendable { func snapshot() -> [LocalProcessTreeEntry] }`
- `struct SystemLocalProcessTreeSnapshotter: LocalProcessTreeSnapshotting`.
  On Darwin it calls `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0])` twice:
  once for the size, then once for the data, retrying while `ENOMEM`; it reads
  `kp_proc.p_pid`, `kp_eproc.e_ppid`, `kp_eproc.e_pgid`,
  `kp_proc.p_starttime`. On Linux it reads `/proc/[0-9]*/stat`, parsing after
  the **last** `)` (the comm field may contain spaces or parentheses), fields
  ppid(4), pgrp(5) and starttime(22). Unreadable entries are skipped. Any
  error gives an empty array, never a throw.
- `func localProcessDescendants(of roots: Set<pid_t>, in entries: [LocalProcessTreeEntry]) -> [LocalProcessTreeEntry]`:
  the transitive closure over ppid. A root pid itself is excluded.

### Sources/RielaAdapters/LocalProcess.swift (edit)

- Add internal constants on `FoundationLocalProcessRunner` or as file-level
  values: `cancellationGrace = 5.0 s`, `cancellationHardBound = 5.0 s` and
  `cancellationScanInterval = 0.1 s`. Make them overridable through the
  existing internal init or test seam, together with a snapshotter, so tests
  can shorten the grace. Default values must equal the design.
- `LocalProcessHandle`: add a cancellation driver, used **only** when
  `cancellationPolicy == .terminateGroup` and the cancel comes from Task
  cancellation (`cancelConfiguredProcess`):
  1. Snapshot while the leader is unreaped. Track `(pid, startTime)` for every
     descendant of the leader pid. Do this **before** any signal.
  2. SIGTERM the owned group through the existing `signalGroupOrProcess`.
     For each tracked pid whose pgid ≠ the owned group, re-snapshot and send
     `kill(pid, SIGTERM)` only if that pid is present with the same
     startTime.
  3. Every scan interval until the grace ends or the tracked set is empty:
     re-snapshot; add descendants of any tracked process that is still alive
     and SIGTERM them; drop entries that are gone (pid absent, or startTime
     changed).
  4. Then SIGKILL the owned group (only while `processId != nil`, matching
     `killScheduledProcessGroup`) and every tracked live entry, rechecking
     startTime each time. Repeat each scan interval until the set is empty or
     the hard bound passes.
  5. Signal completion on a `DispatchSemaphore` or `DispatchGroup` that
     `outputGroup.notify` waits on **before** `reapAfterOutput` when
     `completion.cancelled()`.

  Survivors at the hard bound: write one line `process_tree_survivors <n>\n`
  to `FileHandle.standardError` through an injectable
  `survivorReporter: @Sendable (Int) -> Void` and still finish. RielaAdapters
  has no telemetry handle; this is the agreed safe-code report.
- `cancelConfiguredProcess`: for `.terminateGroup`, start the driver on a
  global utility queue instead of
  `terminateGroupOrProcess()` + `scheduleKillIfRunning(after: 1)`. For
  `.awaitOwner`, keep the existing calls.
- Leader-exit observer (about line 806): `if ownsExitedChild { processHandle.killGroupOrProcess() }`
  becomes: skip the immediate kill when `completion.cancelled()` and the
  policy is `.terminateGroup`, because the driver owns escalation. Keep it
  otherwise.
- The race when the leader exits before the cancel arrives: if `didExit` or
  the pid is already gone, the driver snapshots what remains. A normal
  completion that already resumed must not be affected. The existing
  `completion.cancelled()` / `markCancelled` ordering decides; do not resume
  the continuation twice.

Pitfalls:
- Never signal a pid that is not a tracked descendant with a matching
  startTime.
- Never `killpg` a group other than the owned one.
- Never call `waitpid` on the leader before the driver finishes. The
  `WNOWAIT` pin is the safety basis.
- Do not hold `LocalProcessHandle.lock` while sleeping or snapshotting.
- On Linux, do not fail the build if Darwin symbols are missing: use
  `#if canImport(Darwin)`.

## Tests: Tests/RielaAdaptersTests/LocalProcessCancellationTreeTests.swift (new)

Imitate the process setup in
`Tests/RielaAdaptersTests/LocalProcessForegroundLifetimeTests.swift`.
Fixtures:
- write pids and ready files into a temp dir;
- wait for readiness with a bounded loop of at most 10 s;
- `tearDown` sends `kill(pid, SIGKILL)` to every recorded pid.

Cases:
- **Same group.** `/bin/sh -c 'sleep 300 & echo $! > gc; touch ready; wait'`.
  After ready, cancel the Task → it throws `CancellationError`, and at return
  `kill(leader,0)` and `kill(gc,0)` both fail with ESRCH.
- **Separate group with early leader exit.** The leader is
  `sh -c 'trap "exit 0" TERM; set -m; sh -c "trap \"\" TERM; echo \$\$ > g2; sleep 300" & touch ready; wait'`.
  Cancel → the g2 pid is ESRCH at return. This test must fail against the
  pre-change code (record that run in the progress log: build the test first
  or reason from the stash-free diff). Elapsed time ≤ grace + hard bound + 2 s.
- **Cooperative cleanup not preempted.** The inner `set -m` group process does
  `trap "sleep 2; touch cleaned; exit 0" TERM` and sleeps; the leader exits at
  once on TERM. Cancel → the `cleaned` file exists at return, and the inner
  pid is ESRCH.
- **PID-reuse guard.** Unit-test the driver's selection logic with a fake
  snapshotter. A tracked `(pid 4242, start 1)` reappears as `(4242, start 2)`
  → it is not signalled. Inject a recording signal function: the existing
  `LocalProcessSignal` seam on `LocalProcessHandle`.
- **Descendants computation.** `localProcessDescendants` over a fake table
  with a multi-level chain and an unrelated branch → only the chain.
- **Unchanged paths.** The existing `LocalProcessForegroundLifetimeTests` (normal-exit
  background child, deadline) and `LocalProcessAdmissionTests` pass unchanged.

## Verification (arm64 shell; tee to the evidence root)

- `swift build` → exit 0.
- `swift test --filter "LocalProcessCancellationTreeTests|LocalProcessForegroundLifetimeTests|LocalProcessAdmissionTests|LocalProcessWallDeadlineTests"`
  → exit 0, 0 failures, no leftover `sleep 300` processes
  (`pgrep -f "sleep 300"` before and after, logged).
- `swiftlint lint Sources/RielaAdapters/LocalProcess.swift Sources/RielaAdapters/LocalProcessTree.swift Tests/RielaAdaptersTests/LocalProcessCancellationTreeTests.swift`
  → no new violations.

## Done criteria

- All cases pass.
- The diff is limited to the 2 sources plus 1 test.
- The progress log has exit codes, log paths and the before/after `pgrep`
  output.

## Drift protocol

Re-read before each edit and record pre/post sha256. Stop on unexpected
drift.

## Amendment 2026-11-11 (integration-paths-outside-writePaths, round 1)

Source: integration review comm-000054 (IR-SCOPE-FIXTURE-ROOTS), routed by
dispatch-plans comm-000056 (`amendment_required`). This is a bounded scope
amendment only; there is no design change.

- **Fixture root.** `tmp/specialist-supervisor/process-lifetime` is added to
  writePaths **and** artifactRoots, for verification only.
  `LocalProcessForegroundLifetimeTests` writes its fixtures there
  (`Tests/RielaAdaptersTests/LocalProcessForegroundLifetimeTests.swift:53`). Do
  not edit that test.
- **Still open from wave 2, still required.** See the progress log.
  - The hard-bound loop must SIGKILL the owned group on **every** iteration,
    not only once.
  - Test teardown must trim the trailing newline when it parses PID files.
  - The tests must assert that the leader has disappeared and that elapsed
    time is at most grace + hard bound + 2 s.
- **Transient test byproducts.** Some existing suites create
  `tmp/<prefix>-<UUID>` directories and delete them themselves. Those are
  authorized byproducts of verification. Do not edit those tests.
- **Shared build output.** The worktree `.build` written by `swift build` and
  `swift test` from the worktree root is authorized shared build output. It is
  untracked and does not count as a write-scope violation. A private
  `--scratch-path` may be used in addition to the plan commands, never instead
  of them.
- **Dispatch manifest.** `impl-plans/active/instance-cancel-dispatch.json` is
  regenerated by the dispatch flow. Workers never edit it.

## Amendment 2026-11-11 (integration-paths-outside-writePaths, round 2)

Source: dispatch-plans comm-000064, checkpoint c262d69b, amendmentRound 1.
The only remaining `unmatchedPaths` entry is
`impl-plans/active/instance-cancel-dispatch.json`. The integration finding
IR-SCOPE-FIXTURE-ROOTS was filed against that file. The finding's actual
repair (the fixture roots) is already assigned in round 1. This plan owns the
largest share of that finding (plans 03, 06, 07 and 08), so it now takes
nominal ownership of the manifest. This is a bounded ownership assignment
only. It does not change the design or the scope.

- `impl-plans/active/instance-cancel-dispatch.json` is in this plan's
  writePaths for **ownership/readback only**.
- **The worker MUST NOT edit, rewrite, format or regenerate this file.** The
  workflow's dispatch/checkpoint flow regenerates it.
- The worker records its sha256 at start and at end in the progress log.
  Drift during the worker run is a stop-and-report condition, not something
  to repair.
- No source, test or verification change follows from this round.
