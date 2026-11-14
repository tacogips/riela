# Progress: ar-07-cli-service-gc-docs

Workflow mode: `issue-resolution`
Issue: `workflowInput:automatic-config-driven-retention` (no GitHub issue URL/number)
Codex-agent reference: `/root` (Codex), Step 6 implementation
Plan: `impl-plans/completed/automatic-retention-07-cli-service-gc-docs.md`
Branch: `feat/automatic-retention`
Accepted dependencies: `ar-05-cli-executor`, `ar-06-cli-targets-logs` (both present in runtime-owned `acceptedPlanIds`).

## Implemented scope

Implemented the public `RielaRetentionService` request, override and report API; policy precedence/overrides; no-config automatic skip; unsafe-target skip before lock creation; throttle and nonblocking lock handling; target-level warning/failure reports; executor/log/generated sweep/finalize orchestration; and manual GC parsing, exit mapping, JSON/text rendering. Updated the GC help line and passthrough parser case, replaced the README GC section with the retention policy guide, updated terminal-retention reclamation guidance, and added the workflow-run skill section.

Added 14 service tests and 8 GC command tests. Service coverage includes no-config state, pruning/stamps/throttle, disabled policy, lock contention, keep-forever overrides and category independence, dry-run state, project precedence, unsafe roots, corrupt project store isolation, and manual overrides. Command coverage includes dry-run JSON, old flag rejection, removed config error, keepForever override, help, text output, human byte sizes, and invalid formats.

The GC parser passthrough case uses `--results-max-age-days 30`. Other shared-path content was left unchanged.

## Acceptance status

- Service and manual GC behavior: implemented; the 14 service tests and 8 command tests pass.
- Docs and help: updated, including the keep-forever results/messages example and capped log example.
- Required dependency suites: pass.
- Strict changed-file SwiftLint: pass with an empty log.
- Required aggregate focused command: **not green**. It ran 52 tests with one failure in `CommandParsingTests.testArgumentParserRegistersEveryTopLevelClientCommand`. The current router reports additional `cache` and `gateway` subcommands absent from that test's expected set. The plan's shared-path note authorizes only changing the GC passthrough case, so this implementation did not edit the inventory assertion.
- Executor seam: `TerminalRetentionExecutor.runPolicy` performs reclamation internally and `finalize` performs it again. The service initializer's injected `freeSpace` closure cannot control either internal call. Correcting this requires changing `Sources/RielaCLI/TerminalRetentionExecutor.swift`, outside this plan's `writePaths`. This is handed to serial integration for an ownership/scope decision; no claim is made that injected reclamation or single-pass reclamation is verified.

## Verification

| Command | exitStatus | testsRun | failureCount | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaRetentionServiceTests|GarbageCollectionCommandTests|CommandParsingTests" > tmp/automatic-retention/ar-07-cli-service-gc-docs/test-final-003.log 2>&1'` | 1 | 52 | 1 | Full log: `tmp/automatic-retention/ar-07-cli-service-gc-docs/test-final-003.log`; the only failure is the command inventory assertion. The GC passthrough case passed. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaRetentionServiceTests" > tmp/automatic-retention/ar-07-cli-service-gc-docs/service-rerun-002.log 2>&1'` | 0 | 14 | 0 | Full log: `tmp/automatic-retention/ar-07-cli-service-gc-docs/service-rerun-002.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaRetentionServiceTests|GarbageCollectionCommandTests" > tmp/automatic-retention/ar-07-cli-service-gc-docs/test-rerun-002.log 2>&1'` | 0 | 18 | 0 | Full log: `tmp/automatic-retention/ar-07-cli-service-gc-docs/test-rerun-002.log`; this preceded the four added service integration cases. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetention|RetentionTargetState|RetentionLogPruner|RielaDataGarbageCollector" > tmp/automatic-retention/ar-07-cli-service-gc-docs/deps.log 2>&1'` | 0 | 66 | 0 | Full log: `tmp/automatic-retention/ar-07-cli-service-gc-docs/deps.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "CommandParsingTests/testParsesGarbageCollectionCommand" > tmp/automatic-retention/ar-07-cli-service-gc-docs/command-parsing-gc.log 2>&1'` | 0 | 1 | 0 | Full log: `tmp/automatic-retention/ar-07-cli-service-gc-docs/command-parsing-gc.log`. |
| `if [ -s tmp/automatic-retention/ar-07-cli-service-gc-docs/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-07-cli-service-gc-docs/changed-swift-files.nul > tmp/automatic-retention/ar-07-cli-service-gc-docs/swiftlint-final.log 2>&1; else printf '%s\\n' 'No Swift files changed; selected-file SwiftLint not run.'; fi` | 0 | 0 | 0 | Strict lint log is empty; manifest is `tmp/automatic-retention/ar-07-cli-service-gc-docs/changed-swift-files.nul`. |
| `grep -n '"keepForever": true' README.md Resources/skills/riela-workflow-run/SKILL.md` | 0 | 0 | 0 | Matches present in both files. |
| `grep -n "retention-days\\|RIELA_GC_RETENTION_DAYS" README.md docs/terminal-retention.md Resources/skills/riela-workflow-run/SKILL.md Sources/RielaCLI/RielaCLIApplication.swift Sources/RielaCLI/GarbageCollectionCommand.swift` | 0 | 0 | 0 | Sole match is the README removal sentence; no old flag appears in docs/help/command code. |
| `grep -n 'RielaGarbageCollectionConfiguration' Sources/RielaCLI/GarbageCollectionCommand.swift` | 1 | 0 | 0 | No match, as required. |
| `grep -n 'public func run(_ request: RielaRetentionRequest) throws -> RielaRetentionReport' Sources/RielaCLI/RielaRetentionService.swift` | 0 | 0 | 0 | Required public signature matched at line 135. |
| `git show HEAD:Tests/RielaCLITests/CommandParsingTests.swift | sed -n '31,43p' > tmp/automatic-retention/ar-07-cli-service-gc-docs/baseline-command-inventory.log; git show HEAD:Sources/RielaCLI/RielaClientCommandRouter.swift | rg -n '"cache"|"gateway"|CacheRoute|GatewayRoute' >> tmp/automatic-retention/ar-07-cli-service-gc-docs/baseline-command-inventory.log` | 0 | 0 | 0 | The committed test expects a command set without `cache`/`gateway`; committed router registers `CacheRoute` and `GatewayRoute`. This establishes that the mismatch is unrelated to the two-line GC case edit, but it is not an accepted baseline disposition. Evidence: `tmp/automatic-retention/ar-07-cli-service-gc-docs/baseline-command-inventory.log`. |
| `git diff --check > tmp/automatic-retention/ar-07-cli-service-gc-docs/diff-check.log 2>&1` | 0 | 0 | 0 | No whitespace errors; complete log is empty at `tmp/automatic-retention/ar-07-cli-service-gc-docs/diff-check.log`. |

## Prior attempts

- `test.log` exited 1 during compilation because `GarbageCollectionCommand.swift` accessed throwing `parsed.overrides` without `try`; fixed and superseded by later builds.
- `test-rerun-001.log` exited 1 with 48 tests and 2 failures: the stale dry-run assertion expected an optional `capAchieved` without a byte cap, and the command inventory assertion. The dry-run fixture now includes a byte cap; the latest aggregate has only the command inventory failure. The inventory mismatch is also visible in committed HEAD source, as shown in the preceding row; it remains undispositioned.
- `swiftlint.log` exited 1 on style diagnostics. They were corrected; the final exact-file strict lint is clean.
- `service-rerun-001.log` exited 1 during test compilation due unescaped JSON quotes in a SQL test string; fixed and superseded by `service-rerun-002.log` (14/0).

## Resume criteria

Serial integration should resolve ownership for the executor reclamation seam (single-pass ordering and injected free-space handling) and authorize or disposition the unrelated command inventory test mismatch. Then rerun the exact aggregate verification command. Until those points are resolved, this plan's implementation remains incomplete and is not submitted as an accepted review result.

## Final source SHA-256

- `Sources/RielaCLI/RielaRetentionService.swift`: `b820f4e7690ada648782abbc55e32d5de49f0434046fb0117262b66277226fdd`
- `Sources/RielaCLI/GarbageCollectionCommand.swift`: `281bc5c44a31e9a10df450ad00c185e757fe9da043292d6f608660b2cc1a6647`
- `Sources/RielaCLI/RielaCLIApplication.swift`: `45a47560b98b6dd679bb260f23dbfee38368376b629a54eb2c4c6e5739d9fafa`
- `Tests/RielaCLITests/RielaRetentionServiceTests.swift`: `7f72e6976231e66555b1847165f172b0b92b916279931a32a1d49e9fbe9634b9`
- `Tests/RielaCLITests/GarbageCollectionCommandTests.swift`: `718e7abc13895539e2b554f9c78c7c60b1836ead69c312740bd33a5d8b7cdbdb`
- `Tests/RielaCLITests/CommandParsingTests.swift`: `55664759a0ab8dfe4bd4eb933b756204c21229033a7bcb9b96882a69454f7a7e`

## Operator resolution of session 452 blockers (2026-10-19)

- Command inventory: `cache` and `gateway` were added to the expected set in
  `CommandParsingTests.testArgumentParserRegistersEveryTopLevelClientCommand` (pre-existing
  main mismatch). The aggregate `RielaRetentionServiceTests|GarbageCollectionCommandTests|CommandParsingTests`
  command now exits 0.
- Reclamation seam: fixed in `TerminalRetentionExecutor` (commit 10e9aa6e) and wired in
  `RielaRetentionService` through `makeExecutor()`, which forwards the injected `freeSpace` to
  the executor's reclaimer. Regression test:
  `RielaRetentionServiceTests.testManualRunReclaimsRuntimeDatabaseOnceThroughInjectedFreeSpace`.
- Operator verification: 164 focused tests, 0 failures (tmp/automatic-retention/manual-fix/focused.log);
  strict SwiftLint on the 6 touched files exited 0.

## Step 6 continuation (2026-10-19)

The operator resolutions above were confirmed on the current tree. This record supersedes
the earlier resume criteria and unresolved acceptance status:

- The GC parser now accepts only `--output text|json`, matching the assigned command
  contract; `--output jsonl` is covered as a usage error. The top-level help lists the
  same supported formats.
- Service orchestration, manual overrides, target reporting, dry-run behavior, generated
  sweep, orphan-lock finalization, and reclamation remain implemented. The injected
  free-space regression passes with a single manual reclamation result.
- Documentation retains the results/messages keep-forever example, log age/byte cap,
  config precedence, and low-level `session prune` description. Legacy configuration and
  flag names occur in the README removal sentence only.

### Current-source verification

| Command | exitStatus | testsRun | failureCount | Evidence |
|---|---:|---:|---:|---|
| `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaRetentionServiceTests|GarbageCollectionCommandTests|CommandParsingTests" > tmp/automatic-retention/ar-07-cli-service-gc-docs/test-final-005.log 2>&1'` | 0 | 53 | 0 | Full log: `tmp/automatic-retention/ar-07-cli-service-gc-docs/test-final-005.log`; includes 25 command parsing, 8 GC command, 15 retention service, and 5 task parsing tests. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "TerminalRetention|RetentionTargetState|RetentionLogPruner|RielaDataGarbageCollector" > tmp/automatic-retention/ar-07-cli-service-gc-docs/deps-final-001.log 2>&1'` | 0 | 66 | 0 | Full log: `tmp/automatic-retention/ar-07-cli-service-gc-docs/deps-final-001.log`. |
| `if [ -s tmp/automatic-retention/ar-07-cli-service-gc-docs/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/automatic-retention/ar-07-cli-service-gc-docs/changed-swift-files.nul > tmp/automatic-retention/ar-07-cli-service-gc-docs/swiftlint-final-001.log 2>&1; else printf '%s\\n' 'No Swift files changed; selected-file SwiftLint not run.'; fi` | 0 | 0 | 0 | Strict selected-file SwiftLint log is empty. Manifest: `tmp/automatic-retention/ar-07-cli-service-gc-docs/changed-swift-files.nul`. |
| `grep -n '"keepForever": true' README.md Resources/skills/riela-workflow-run/SKILL.md` | 0 | 0 | 0 | Example found in both files. |
| `grep -n 'retention-days\\|RIELA_GC_RETENTION_DAYS' README.md docs/terminal-retention.md Resources/skills/riela-workflow-run/SKILL.md Sources/RielaCLI/RielaCLIApplication.swift Sources/RielaCLI/GarbageCollectionCommand.swift` | 0 | 0 | 0 | Only match is the README removal sentence. |
| `rg -n 'RielaGarbageCollectionConfiguration|retentionDays|RIELA_GC_RETENTION_DAYS|--retention-days' Sources/RielaCLI/GarbageCollectionCommand.swift Sources/RielaCLI/RielaRetentionService.swift docs/terminal-retention.md Resources/skills/riela-workflow-run/SKILL.md README.md` | 0 | 0 | 0 | Matches are only the legacy README removal text and the internal `RielaDataGarbageCollector.collect(retentionDays:)` parameter; the GC command has no old configuration type or flag reference. |
| `git diff --check > tmp/automatic-retention/ar-07-cli-service-gc-docs/diff-check-final.log 2>&1` | 0 | 0 | 0 | No whitespace errors; complete log: `tmp/automatic-retention/ar-07-cli-service-gc-docs/diff-check-final.log`. |

Prior failed aggregate logs remain preserved above and are superseded by the current-source
53/0 aggregate. Implementation-phase acceptance criteria for this plan are complete;
formal review, review-dependent shared documentation/index updates, and serial local commit
remain downstream workflow steps. No blocker remains within this plan's assigned paths.

### Current source SHA-256

Refreshed during serial reconciliation (2026-10-19) after the test-integrity and adversarial
self-repairs. The adversarial self-repair added the `sessionStoreActive` gate in
`RielaRetentionService.runTarget`, so a manual or automatic pass with no config, logs only or
keepForever only leaves the session store alone. It also added the regression tests
`testManualWithoutPolicyLeavesSessionStoreUntouched` and `testLogsOnlyPolicyDoesNotTouchSessionStore`,
and switched `testCorruptProjectStoreDoesNotStopUserTarget` and `testBusyReclamationIsWarningNotFailure`
to results-active configs. Post-repair focused verification:
`tmp/automatic-retention/ar-07-cli-service-gc-docs/adversarial/verify-test.log` (exitStatus 0, testsRun 59, failureCount 0).

- `Sources/RielaCLI/RielaRetentionService.swift`: `8801fbefeaf04e649f1537cc6909ccfd409f8f9576470870820ea904162e64fa`
- `Sources/RielaCLI/GarbageCollectionCommand.swift`: `2818252050a80b28afc85ce91eedea47f5eb072ac8a39388001a890a2ed4d14d`
- `Tests/RielaCLITests/GarbageCollectionCommandTests.swift`: `03a30cfd9dbefd877907b52692bb18445aa2fb4df558838ea8c9f6fddf672a1e`
- `Tests/RielaCLITests/RielaRetentionServiceTests.swift`: `bd90f06e74ec31d79b6884b30672d82705838fa228be9d3e746477986ac9e01b`
