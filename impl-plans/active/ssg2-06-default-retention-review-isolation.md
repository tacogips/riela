# ssg2-06-default-retention-review-isolation: review/repair default retention + test isolation

**planId**: ssg2-06-default-retention-review-isolation
**dependsOn**: none (wave W1)
**Design**: `design-docs/specs/design-session-storage-efficiency-and-default-gc.md`
§1.1, §1.2 (test isolation defect), §4.1-4.5, §4.6 (review checklist), §5.1
("Working directory" parameter only), §11 (test isolation), §12 row (f); QA Q1-Q3
**Shared rules**: `impl-plans/active/ssg2-session-storage-gc.md` → "Shared execution rules"
**Progress log**: `impl-plans/progress/ssg2-06-default-retention-review-isolation.md` (new; do not read or continue `sgc-02`)
**Evidence root**: `tmp/ssg2/ssg2-06-default-retention-review-isolation/`

## Intent and context

Two things, delivered together because the review needs trustworthy tests:

1. **Review and repair** the uncommitted default-retention work (formerly
   sgc-02, never formally reviewed) against design §4. It is in
   `Sources/RielaCore/RielaRetentionConfiguration.swift`
   (`RielaRetentionPolicy.builtInDefault`, `RielaRetentionPolicySource`,
   `RielaRetentionPolicySources`, `RielaEffectiveRetentionPolicy`,
   `effectivePolicy(for:)`, `automaticOverride`),
   `Sources/RielaCore/RielaRetentionReport.swift` (`policySource`),
   `Sources/RielaCLI/RielaRetentionService.swift` (effective policy, sources,
   generated-sweep gate at ~line 292) and
   `Sources/RielaCLI/GarbageCollectionCommand.swift` (text and help). Repair
   in place; do not rewrite. `policy(for:)` stays optional (design §4.1).
2. **Test isolation** (design §11). Retention, gc, compact, doctor and hook
   tests currently read the developer's `~/.riela/config.json` and ambient
   `RIELA_*` variables (example:
   `StorageCompactCommandTests.testNoRetentionPolicyReportsDefaultAndKeepsSessionDatabase`,
   `Tests/RielaCLITests/StorageCompactCommandTests.swift:477-494`), and
   `AutomaticRetentionHook.runIfApplicable` uses the process working directory
   (`Sources/RielaCLI/AutomaticRetentionHook.swift:88`).

Isolation mechanism: `CLIRuntimeEnvironment.$captured`
(`Sources/RielaWorkflowRegistry/CLIRuntimeEnvironment.swift:4-16`) replaces
the whole process environment; `$overrides` only adds keys and is not enough.

**writePaths**: the four source files above, `Sources/RielaCLI/AutomaticRetentionHook.swift`,
`Tests/RielaCLITests/RielaCLIIsolatedEnvironment.swift` (new),
`Tests/RielaCLITests/AutomaticRetentionTests.swift`,
`Tests/RielaCLITests/GarbageCollectionCommandTests.swift`,
`Tests/RielaCLITests/RielaRetentionServiceTests.swift`,
`Tests/RielaCLITests/StorageCompactCommandTests.swift`,
`Tests/RielaCLITests/StorageDoctorCommandTests.swift`,
`Tests/RielaCLITests/TerminalRetentionTests.swift`,
`Tests/RielaCLITests/TerminalRetentionPolicyTests.swift`,
`Tests/RielaCLITests/RielaRetentionSchedulerTests.swift`,
`Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift`,
`Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift` (preserved
edits), `impl-plans/progress/ssg2-06-default-retention-review-isolation.md`.
**sharedPaths** (isolation-only edits, only if the proof run shows a leak):
`Tests/RielaCLITests/GitWorkflowAddonGarbageCollectionSafetyTests.swift`,
`Tests/RielaCLITests/SessionMessageRetentionAdmissionTests.swift`,
`Tests/RielaCLITests/RetentionReclamationTests.swift`,
`Tests/RielaCLITests/RetentionLogPrunerTests.swift`,
`Tests/RielaCLITests/RetentionTargetStateTests.swift`,
`Tests/RielaAppSupportTests/RielaAppRetentionStartTests.swift` (checkpoint
amendment round 1, IR-SSG2-06-APP-TEST-SCOPE: a required expectation update,
not isolation-only; see §4 below).

## Non-goals

- No maintenance changes: do not remove the `completedRoots` gate, do not
  touch `RunEndStorageMaintenance.swift` or `RunEndStorageMaintenanceTests.swift`
  (ssg2-05), and do not change explicit-store selection (ssg2-05).
- No generated-sweep removal or `workRemaining` changes (ssg2-07).
- No doctor output changes (ssg2-08).
- No new configuration keys, no behavior beyond design §4.

## Contract (pinned; later plans use them)

- `AutomaticRetentionHook.runIfApplicable(arguments:exitCode:cancelled:environment:service:currentDirectory:)`
  gains `currentDirectory: String = FileManager.default.currentDirectoryPath`,
  used instead of the process working directory when building the request.
- New test helper `Tests/RielaCLITests/RielaCLIIsolatedEnvironment.swift`:

```swift
struct RielaCLIIsolatedEnvironment {
  let root: URL, home: URL, project: URL           // realpath-resolved temporary dirs; home and project exist
  let environment: [String: String]                // HOME=home, PATH and TMPDIR copied, plus `extra`
  static func make(_ name: String, extra: [String: String] = [:]) throws -> RielaCLIIsolatedEnvironment
  func run<T>(_ body: () throws -> T) rethrows -> T                 // CLIRuntimeEnvironment.$captured.withValue(environment)
  func run<T>(_ body: () async throws -> T) async rethrows -> T
  func remove()
}
```

## File-level changes

### 1. Review (`RielaRetentionConfiguration.swift`, `RielaRetentionReport.swift`, `RielaRetentionService.swift`, `GarbageCollectionCommand.swift`)

Walk the design §4.6 checklist (rules 1-7). For each rule: find or write the
test, run it, and fix the source only if the rule fails. Record each rule with
its test name and verdict in the progress log. Known points to verify:

- per-category fill keeps `keepWorkflowIds` (rule 2);
- `RIELA_RETENTION_AUTOMATIC=0` with no config disables automatic passes
  through `automaticOverride` (rule 3);
- a flag sets `policySource: override` per category (rule 4);
- the generated sweep runs for a configured or flag `results.maxAgeDays` and
  not for the default (rule 5);
- `--dry-run` writes no tombstone, `last-run.json` or deletion (rule 6);
- protections under the default policy (rule 7): running, suspended, created,
  locked and tree-member families kept; 29-day terminal kept; 31-day removed.

### 2. `Sources/RielaCLI/AutomaticRetentionHook.swift`

Only the `currentDirectory` parameter above. Keep the existing `--scope`
selection code as is.

### 3. Test isolation (every file in `writePaths` under `Tests/`)

Audit each file with
`rg -n "RielaCLIApplication\(\)\.run|CommandRunner\(\)|runIfApplicable|runEndMaintenance|RielaRetentionRequest\(|RielaRetentionConfiguration\.load|ProcessInfo\.processInfo\.environment|currentDirectoryPath"`.
Every hit must:

- run CLI code inside `RielaCLIIsolatedEnvironment.run { ... }` (replace the
  three existing `$overrides` call sites in `StorageCompactCommandTests.swift`
  at lines ~52, ~68, ~325 too, keeping their `RIELA_RETENTION` value via
  `extra`);
- pass a temporary project directory (`--working-dir`, the `currentDirectory:`
  parameter, or an explicit `--session-store`);
- in direct `RielaRetentionRequest` / `RielaRetentionConfiguration.load`
  calls, pass the temporary home, project and an explicit environment
  dictionary, never `ProcessInfo.processInfo.environment`.

In `Tests/RielaCoreTests/RielaRetentionConfigurationTests.swift` the helper is
not available; pass explicit temporary directories and dictionaries.

### 4. `Tests/RielaAppSupportTests/RielaAppRetentionStartTests.swift` (amendment round 1)

Finding IR-SSG2-06-APP-TEST-SCOPE: `testMissingConfigurationDoesNotCreateRetentionState`
(lines ~51-64) asserts `report.targets.isEmpty` and an empty `.riela`
directory when no config exists. Under the accepted built-in defaults (design
§4.1-4.4) both assertions are obsolete, and the class is selected by this
plan's `Retention[A-Za-z]*Tests/` filter (`RielaAppRetentionStartTests/`), so
the normal and conflicting-HOME runs fail 2 assertions until it is updated.
This is a stale expectation, not a HOME leak (both runs fail identically).

- Rename it to `testMissingConfigurationAppliesBuiltInDefaults`.
- Arrange: temporary home with an empty `.riela`, plus one log file under
  `.riela/logs` whose mtime is 1 day before the injected clock (inject
  `clock:` as `testConfiguredLogsPolicyPrunesOnlyInjectedHome` does).
- Assert: exactly one target, `kind == .user`, `root` equals the temporary
  `.riela` path; the report's effective policy sources for `results` and
  `logs` are `.builtInDefault` (JSON `"default"`); the 1-day-old log still
  exists; every `target.root` has the temporary home as prefix. Read the
  report shape from `Sources/RielaCore/RielaRetentionReport.swift`; do not
  add report fields.
- Keep the explicit `environment: ["HOME": home.path]` request argument (the
  test target does not import the CLI test helper); do not read
  `ProcessInfo.processInfo.environment`.
- Leave the other two tests in the file unchanged.
- Do not change `RielaRetentionService` to skip retention without config, do
  not skip the test or narrow the filter, and do not edit
  `Sources/RielaApp/EntryPoint+Retention.swift` (ssg2-05).

## Pitfalls

- Built-in defaults make no-config tests destructive: every test store must be
  a temporary one.
- Do not "fix" an isolation failure by setting `RIELA_RETENTION` in the
  process; the proof run below sets a conflicting process environment on
  purpose.
- Keep every existing assertion's meaning. If a test asserted "no config means
  no deletion", it is obsolete; replace it with the §4.6 rule and record the
  replacement.
- Do not edit test files owned by other plans
  (`RunEndStorageMaintenanceTests.swift`, `RunEndStorageMaintenanceConversionTests.swift`,
  `RielaDataGarbageCollectorTests.swift`).

## Tests (to add where missing)

- no config → `effectivePolicy` gives `results`/`logs` `maxAgeDays: 30`
  `active`, `policySource: default`; messages `notConfigured` + `default`;
- `{"messages":{"maxAgeDays":7},"results":{"keepWorkflowIds":["w"]}}` →
  results 30 days with `keepWorkflowIds == ["w"]`, logs 30 days, messages
  configured;
- `{"results":{"keepForever":true}}` → results `keepForever`; logs defaulted;
- `RIELA_RETENTION_AUTOMATIC=0`, no config → automatic trigger skips;
  manual `riela gc` still prunes the 31-day family;
- `riela gc --results-max-age-days 5 --dry-run --output json` → results
  `policySource: override`;
- generated sweep: default policy → no `workflow-history` entry removed;
  configured `results.maxAgeDays` → old entry removed;
- `riela gc --dry-run --output json`, no config → `maxAgeDays: 30`,
  `policySource: default`, no `retention/` state written, nothing deleted;
- protections (rule 7) as listed in §1 above;
- RielaApp request, no config, 1-day-old log → one user target with
  `results`/`logs` source `.builtInDefault`, log kept, all roots under the
  temporary home (`RielaAppRetentionStartTests.testMissingConfigurationAppliesBuiltInDefaults`).

## Acceptance criteria

- `rg -n "currentDirectory: String = FileManager.default.currentDirectoryPath" Sources/RielaCLI/AutomaticRetentionHook.swift` → one match.
- `rg -n "CLIRuntimeEnvironment.\$overrides" Tests/RielaCLITests/StorageCompactCommandTests.swift` → no match.
- Progress log lists §4.6 rules 1-7, each with a passing test name.
- `rg -n "testMissingConfigurationDoesNotCreateRetentionState" Tests/RielaAppSupportTests` → no match; `rg -n "testMissingConfigurationAppliesBuiltInDefaults" Tests/RielaAppSupportTests/RielaAppRetentionStartTests.swift` → one match.
- The selection check exits 0: `tmp/ssg2/ssg2-06-default-retention-review-isolation/selected.txt` lists the selected tests and contains no `RunEndStorageMaintenance` entry.
- Both test commands below exit 0 with the same class-anchored filter (the second is the isolation proof).

## Verification (each must exit 0)

```
mkdir -p tmp/ssg2/ssg2-06-default-retention-review-isolation
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift build 2>&1 | tee tmp/ssg2/ssg2-06-default-retention-review-isolation/build.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-06-default-retention-review-isolation/build.log; exit $s'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test list 2>/dev/null | grep -E "Retention[A-Za-z]*Tests/|GarbageCollection[A-Za-z]*Tests/|StorageCompact[A-Za-z]*Tests/|StorageDoctor[A-Za-z]*Tests/" > tmp/ssg2/ssg2-06-default-retention-review-isolation/selected.txt; s=$?; [ $s -eq 0 ] || exit $s; ! grep -q RunEndStorageMaintenance tmp/ssg2/ssg2-06-default-retention-review-isolation/selected.txt'
HOME="$(mktemp -d)" arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "Retention[A-Za-z]*Tests/|GarbageCollection[A-Za-z]*Tests/|StorageCompact[A-Za-z]*Tests/|StorageDoctor[A-Za-z]*Tests/" 2>&1 | tee tmp/ssg2/ssg2-06-default-retention-review-isolation/test.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-06-default-retention-review-isolation/test.log; exit $s'
H="$(mktemp -d)" && mkdir -p "$H/.riela" && printf '%s' '{"retention":{"automatic":false,"results":{"keepForever":true},"messages":{"keepForever":true},"logs":{"keepForever":true}}}' > "$H/.riela/config.json" && HOME="$H" RIELA_RETENTION_AUTOMATIC=0 arch -arm64 /bin/zsh -lc 'set -o pipefail; swift test --filter "Retention[A-Za-z]*Tests/|GarbageCollection[A-Za-z]*Tests/|StorageCompact[A-Za-z]*Tests/|StorageDoctor[A-Za-z]*Tests/" 2>&1 | tee tmp/ssg2/ssg2-06-default-retention-review-isolation/isolation-proof.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-06-default-retention-review-isolation/isolation-proof.log; exit $s'
arch -arm64 /bin/zsh -lc 'set -o pipefail; swiftlint lint --strict Sources/RielaCore/RielaRetentionConfiguration.swift Sources/RielaCore/RielaRetentionReport.swift Sources/RielaCLI/RielaRetentionService.swift Sources/RielaCLI/GarbageCollectionCommand.swift Sources/RielaCLI/AutomaticRetentionHook.swift Tests/RielaCLITests/RielaCLIIsolatedEnvironment.swift Tests/RielaAppSupportTests/RielaAppRetentionStartTests.swift 2>&1 | tee tmp/ssg2/ssg2-06-default-retention-review-isolation/lint.log; s=$?; echo "exit=$s" >> tmp/ssg2/ssg2-06-default-retention-review-isolation/lint.log; exit $s'
```

Evidence: every log ends with `exit=0`; `selected.txt` is non-empty and
contains no `RunEndStorageMaintenance` line; `test.log` and
`isolation-proof.log` report the same executed test count with 0 failures.

**Why the filter is class-anchored.** `swift test --filter` is a regex
matched against `<target>.<class>/<method>`. A bare token such as `Retention`
also matches method names, for example
`RielaCLITests.RunEndStorageMaintenanceTests/testAutomaticHookSkipsMaintenanceWithoutCompletedRetentionPass`
(`Tests/RielaCLITests/RunEndStorageMaintenanceTests.swift:7`), the obsolete
no-config test that fails today and that ssg2-05 owns and replaces. Each
alternative therefore ends in `Tests/`, so it only matches class names: it
selects `AutomaticRetentionTests`, `RielaRetentionServiceTests`,
`RielaRetentionConfigurationTests`, `TerminalRetention*Tests`,
`WorkflowDefinitionRetentionTests`, `Retention*Tests`,
`GarbageCollectionCommandTests`, `GitWorkflowAddonGarbageCollectionSafetyTests`,
`StorageCompactCommandTests`, `StorageDoctorCommandTests` and
`RielaAppSupportTests.RielaAppRetentionStartTests` (amendment round 1), and excludes
`RunEndStorageMaintenanceTests`, ssg2-04's `RunEndStorageMaintenanceConversionTests`,
ssg2-07's `RielaDataGarbageCollectorTests`, and method-name-only matches in
unrelated suites. The `swift test list` check proves the exclusion. Do not
edit, skip or disable `RunEndStorageMaintenanceTests`. If a selected suite
outside `writePaths`/`sharedPaths` fails only because of isolation, record it
and report the plan blocked; do not edit it.

## Progress log

Record in `impl-plans/progress/ssg2-06-default-retention-review-isolation.md`:
pre/post sha256, the §4.6 rule table (rule, test, verdict, fix), every
isolated call site per file, commands with exit codes and log paths, and
reconciliation items.

Amendment round 1: also record that the earlier build blocker (UF-03,
`RuntimeReducedPayload` access control in
`SQLiteWorkflowRuntimePersistenceStore+SessionFamily.swift`) is resolved on
the combined tree (`tmp/ssg2/reconcile-wave-001/build.log`, exit 0), and the
before/after assertions of the renamed RielaApp test.
