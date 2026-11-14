# ssg2-05-maintenance-host-wiring: automatic maintenance in every host + vacuum caps

**Archived 2026-10-30 (session 564)**: accepted in the integration review of
sessions 562/563. Progress log: `impl-plans/progress/ssg2-05-maintenance-host-wiring.md`.

**planId**: ssg2-05-maintenance-host-wiring
**dependsOn**: ssg2-04-legacy-conversion, ssg2-06-default-retention-review-isolation (wave W2)
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§5.1 (entry points, target selection, explicit store equal to a scoped store,
working directory), §5.2 (single flight), §5.3 Step 2 (vacuum caps), §5.4
(ordering), §9 (`RunEndStorageMaintenanceTests`, `EventLiveServeTests`,
runEnd selection), §12 row (e); QA Q4, Q8
**Shared rules**: `impl-plans/active/ssg2-session-storage-gc.md` → "Shared execution rules"
**Progress log**: `impl-plans/progress/ssg2-05-maintenance-host-wiring.md`
**Evidence root**: `tmp/ssg2/ssg2-05-maintenance-host-wiring/`
**writePaths**: `Sources/RielaCLI/RunEndStorageMaintenance.swift`, `Sources/RielaCLI/AutomaticRetentionHook.swift`, `Sources/RielaApp/EntryPoint+Retention.swift`, `Tests/RielaCLITests/RunEndStorageMaintenanceTests.swift`, `Tests/RielaCLITests/AutomaticRetentionTests.swift`, `Tests/RielaCLITests/EventLiveServeMaintenanceTests.swift` (new), `impl-plans/progress/ssg2-05-maintenance-host-wiring.md`
**sharedPaths**: none

## Intent and context

Today maintenance only vacuums 128 pages, and only for a target whose
retention pass reported `completed`
(`Sources/RielaCLI/AutomaticRetentionHook.swift:96-101`,
`Sources/RielaCLI/RunEndStorageMaintenance.swift:7`). Scheduler hosts
(`events serve` at `EventLiveServe.swift:1114-1137`, `serve` at
`ServeHTTPCommand.swift:108-123`) call `AutomaticRetentionHook.runAutomaticPass`,
which does retention only; RielaApp calls `RielaRetentionService().run`
directly (`Sources/RielaApp/EntryPoint+Retention.swift`). This plan makes
every automatic host run: retention → ssg2-04 legacy conversion → bounded
incremental vacuum, under the target's `automatic.lock`.

Inputs from earlier plans:

- ssg2-04: `StorageMaintenanceConversion.run(sessionStoreRoot:stateDirectory:profile:now:observe:)`,
  `StorageMaintenanceProfile` (`.runEnd`, `.scheduled`, `vacuumPageCap`
  4096 / 65536). Caller holds the lock.
- ssg2-06: `runIfApplicable(..., currentDirectory:)` and the test helper
  `RielaCLIIsolatedEnvironment` (`Tests/RielaCLITests/RielaCLIIsolatedEnvironment.swift`).

Existing APIs: `RetentionTargetLock.tryAcquire(stateDirectory:)`
(`Sources/RielaCLI/RetentionTargetState.swift:14`, returns `nil` when busy),
`RetentionTargetResolver.resolve` and `RetentionTarget`
(`Sources/RielaCLI/RetentionTargets.swift`; de-duplicates an explicit store
equal to a scoped store at line 39), `RielaRetentionConfiguration.load` and
`effectivePolicy(for:)`, `RielaRetentionScheduler`
(`Sources/RielaCLI/RielaRetentionScheduler.swift`).

## Non-goals

- Do not edit `EventLiveServe.swift`, `ServeHTTPCommand.swift`,
  `RielaCLIApplication.swift`, `EntryPoint.swift` (RielaCLI) or `Package.swift`.
- No full `VACUUM`, no conversion of `auto_vacuum=NONE` databases, never
  unlink DB/WAL/SHM files.
- No change to conversion behavior (ssg2-04) or retention rules (ssg2-06).
- No stdout output; exit codes and jsonl streams never change.

## Contract (pinned)

```swift
// Sources/RielaCLI/AutomaticRetentionHook.swift
public enum RielaAutomaticStoragePass {
  public static func runScheduled(_ request: RielaRetentionRequest) -> [String]   // stderr warning lines
}
// Sources/RielaCLI/RunEndStorageMaintenance.swift
static func run(targets: [RetentionTarget], profile: StorageMaintenanceProfile,
                now: @escaping () -> Date = Date.init) -> [String]
```

## File-level changes

### 1. `Sources/RielaCLI/RunEndStorageMaintenance.swift`

Replace `run(sessionStoreRoots:)` with the contract signature. For each target
with a `sessionStoreRoot`, an existing session database and no
`unsafeReason`:

1. `RetentionTargetLock.tryAcquire(stateDirectory:)`; `nil` → skip silently;
   a thrown error → one `riela retention warning:` line, skip.
2. Step 1: `StorageMaintenanceConversion.run(sessionStoreRoot:stateDirectory:profile:now:)`.
3. Step 2: keep the current vacuum body (open with `enableWAL: false`,
   `busyTimeoutMilliseconds: 0`, `waitForLocks: false`; only when
   `auto_vacuum = 2` and `freelist_count >= 128`; `SQLITE_BUSY` skipped;
   `PRAGMA wal_checkpoint(PASSIVE)` after) with
   `incremental_vacuum(min(freelist, profile.vacuumPageCap))`. Delete the
   `maximumVacuumPages = 128` constant.
4. Release the lock on every path.

Never throw out of `run`.

### 2. `Sources/RielaCLI/AutomaticRetentionHook.swift`

- **`runIfApplicable`.** Run the retention pass as today. Then load
  `RielaRetentionConfiguration.load(homeDirectory:projectDirectory:environment:)`
  from the request; on error, skip maintenance silently (the retention pass
  already warned). If a target is selected and
  `effectivePolicy(for: target.kind).policy.automatic` is true, return
  retention warnings + `RunEndStorageMaintenance.run(targets: [target], profile: .runEnd)`.
  Remove the `completedRoots` gating (and the now-unused set if nothing else
  needs it).
- **Explicit-store selection** (`selectedSessionStoreRoot`): with an explicit
  store (`--session-store` or `RIELA_SESSION_STORE`), pick the target whose
  standardized `sessionStoreRoot` equals the standardized explicit root,
  whatever its kind (resolve a relative store against the request's project
  directory, as `RetentionTargetResolver` does). Keep the `session
  resume|rerun|continue --scope` and `workflow run` branches unchanged.
- **`RielaAutomaticStoragePass.runScheduled(_:)`** (public): run the retention
  pass (existing `runAutomaticPassWithReport`), load the config (on error,
  return the retention warnings only), resolve targets with
  `RetentionTargetResolver.resolve(...)` from the request, and for every
  target whose effective policy is automatic, run
  `RunEndStorageMaintenance.run(targets:profile: .scheduled)`. Return all
  warnings. Make `runAutomaticPass` return `RielaAutomaticStoragePass.runScheduled(request)`.

### 3. `Sources/RielaApp/EntryPoint+Retention.swift`

In the scheduler closure, replace the `RielaRetentionService().run` block with
`RielaAutomaticStoragePass.runScheduled(request)`. Write each returned line to
stderr as `RielaApp retention warning: <text>` (strip a leading
`riela retention warning: `). Keep `runImmediately: true` and
`rielaAppRetentionRequest` unchanged.

## Pitfalls

- Maintenance must run **without** any retention config (default
  `automatic: true`) and must **not** run with `"automatic": false` or
  `RIELA_RETENTION_AUTOMATIC=0`.
- Order inside a pass: retention, then conversion, then vacuum (design §5.4).
  Retention releases `automatic.lock` before maintenance takes it.
- `automatic.lock` busy → skip the whole maintenance pass silently, not an
  error.
- Never block on a lock; never write stdout.
- RielaApp is `#if os(macOS)`; keep the file compiling on Linux.

## Tests (use `RielaCLIIsolatedEnvironment` for every hook/CLI call)

`Tests/RielaCLITests/RunEndStorageMaintenanceTests.swift`:

- replace `testAutomaticHookSkipsMaintenanceWithoutCompletedRetentionPass`
  with `testAutomaticHookRunsMaintenanceWithoutRetentionConfig`: incremental
  store with free pages, no config → after `RielaCLIMain.runEndMaintenance`
  the `freelist_count` and file size decrease; stdout, stderr and exit code
  unchanged;
- `RIELA_RETENTION_AUTOMATIC=0` (in the isolated environment) → freelist
  unchanged;
- incremental store with > 4096 free pages → one `.runEnd` pass reclaims
  exactly 4096 pages; one `.scheduled` pass reclaims all of them (≤ 65536);
- `auto_vacuum = NONE` store → `auto_vacuum` stays 0 and freelist unchanged;
- `automatic.lock` held by the test → nothing converted or vacuumed;
- legacy inline row in a terminal session → converted by the run-end hook.

`Tests/RielaCLITests/AutomaticRetentionTests.swift` (runEnd selection; pass
`currentDirectory:` = the isolated project):

- `session resume <id>` without an explicit store → project store maintained;
- `session resume <id> --scope user` → user store maintained;
- `--session-store <project>/.riela/sessions` (equal to the project store) →
  that store maintained (de-duplication case);
- `--session-store <other>` → the explicit store maintained.

New `Tests/RielaCLITests/EventLiveServeMaintenanceTests.swift`:

- legacy row in a temporary project store → one
  `RielaAutomaticStoragePass.runScheduled(request)` converts it and vacuums;
- `AutomaticRetentionHook.runAutomaticPass(request)` (what `events serve` and
  `serve` call) → same result;
- `RielaRetentionScheduler` with a very short interval running that pass →
  after the first tick the row is converted; `stop()` ends the loop.

## Acceptance criteria

- `rg -n "maximumVacuumPages = 128" Sources` → no match.
- `rg -n "completedRoots" Sources/RielaCLI/AutomaticRetentionHook.swift` → no gating use.
- `rg -n "RielaAutomaticStoragePass.runScheduled" Sources` → used in
  `AutomaticRetentionHook.swift` and `Sources/RielaApp/EntryPoint+Retention.swift`.
- All tests above pass.

## Verification (each must exit 0)

```
mkdir -p tmp/ssg2/ssg2-05-maintenance-host-wiring
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/ssg2/ssg2-05-maintenance-host-wiring/build.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-05-maintenance-host-wiring/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "RunEndStorageMaintenance|AutomaticRetention|EventLiveServeMaintenance|RielaRetentionScheduler|RetentionTargetState" 2>&1 | tee tmp/ssg2/ssg2-05-maintenance-host-wiring/test.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-05-maintenance-host-wiring/test.log; exit $s'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCLI/RunEndStorageMaintenance.swift Sources/RielaCLI/AutomaticRetentionHook.swift Sources/RielaApp/EntryPoint+Retention.swift Tests/RielaCLITests/RunEndStorageMaintenanceTests.swift Tests/RielaCLITests/EventLiveServeMaintenanceTests.swift 2>&1 | tee tmp/ssg2/ssg2-05-maintenance-host-wiring/lint.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-05-maintenance-host-wiring/lint.log; exit $s'
```

Evidence: logs end with `exit=0`; `test.log` shows `RunEndStorageMaintenanceTests`,
`RunEndStorageMaintenanceConversionTests`, `AutomaticRetentionTests` and
`EventLiveServeMaintenanceTests` executed with 0 failures; `build.log` includes
the RielaApp target (macOS).

## Progress log

Record in `impl-plans/progress/ssg2-05-maintenance-host-wiring.md`: pre/post
sha256, the replaced test and why, commands with exit codes and log paths,
and reconciliation items.
