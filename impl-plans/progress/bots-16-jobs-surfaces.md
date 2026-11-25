# bots-16-jobs-surfaces

Implementation complete at checkpoint `fcd006da53cf39864b7ea9ef948a7e30a8222715` on
`feat/bots-overview`. Dispatch admitted `bots-15-memory-surfaces`.
The slice implements design §§5.3 and 10.1–10.3.

## Implemented

- [x] Nightly and weekly evaluation claims the period before dispatch and settles the ledger with the runtime session ID.
      Manual jobs use independent keys. Paused and busy bots cannot start a job.
- [x] Upkeep uses a text-only turn and applies Markdown with the audited memory writer. Invalid or disproportionate
      removal proposals preserve memory. Instruction edits are ignored and recorded by the writer.
- [x] Look-around rejects workflows with non-agent work before dispatch. Agent dispatch forces the read-only sandbox
      and job sessions decline permission requests immediately. Recovery preserves both policies.
- [x] Suggestions stay open until accepted or dismissed. Acceptance without a run appears under Planned.
      An accepted action can start a named workflow linked to the bot.
- [x] Jobs and suggestions are available through the bot CLI and GraphQL. Both serve hosts tick and join their scheduler.
- [x] The override declaration and one use, one forced sandbox site and one tick per serve host are verified in `seams.log`.
      Linkage, activity, memory injection and surface parity regressions pass.

## Per-edit hashes

The logs in `tmp/bots-overview/bots-16-jobs-surfaces/` record each intended hunk and its pre- and post-edit SHA-256.

- `edit-intentions.md` for runtime, service, serve, generated SDL and progress.
- `cli-edits.md` for CLI and catalog surfaces and their tests.
- `graphql-edits.md` for GraphQL contracts, provider, schema and tests.
- `runner-tests-edits.md` for scheduler and sandbox dispatch tests.
- `scope-final.log` for the final changed-file hashes against the native pre-node snapshot.

## Verification

Logs and exit codes are in `tmp/bots-overview/bots-16-jobs-surfaces/`.

| Command | Exit | Log and outcome |
| --- | ---: | --- |
| `scripts/surface-parity/generate-sdl.sh` | 0 | `sdl-final.log`, 1 passed. Regeneration is byte-stable per `sdl-stability.log`. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "BotJobRunnerTests\|LookAroundReadOnlyTests\|ForcedReadOnlySandboxRunnerTests\|BotJobSchedulerTests\|BotJobsGraphQLTests\|BotJobDueTests\|BotMemoryCommandTests\|BotCommandTests\|BotRunLinkageTests\|BotActivityRuntimeTests\|BotMemoryInjectionTests\|DeterministicWorkflowRunnerTests\|SurfaceCatalogTests\|SurfaceParityCLITests\|SurfaceParityGraphQLTests\|SurfaceParityExecutorCoverageTests\|SurfaceParityDTOSchemaTests\|SurfaceParitySkillTests"'` | 0 | `test.log`, 124 selected, 123 passed, 1 SDL-generation-only skip, 0 failures. |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentPromptGuardTests\|BotJobLedgerTests\|BotSuggestionStoreTests\|LookAroundPolicyTests\|EventLiveServeTests\|ServeHTTPCommandTests\|SurfaceParityWebAPITests\|SurfaceParityConsoleReadTests\|SurfaceParityLibraryTests" --skip "SurfaceParityWebAPITests/testNoSourceServesAnUndeclaredAPIPath"'` | 0 | `regression.log`, 65 passed. |
| `arch -arm64 /bin/zsh -lc 'swift build'` | 0 | `build.log`. |
| `xargs -0 swiftlint lint --strict --quiet --no-cache` on `changed-swift.nul` in arm64 zsh | 0 | `swiftlint.log`. |
| `/bin/zsh tmp/bots-overview/bots-16-jobs-surfaces/verify-seams.zsh` | 0 | `seams.log`. |
| `git diff --check` | 0 | `diff-check.log`. |

The earlier CLI regression attempt in `test-cli-date-decoder.log` failed while decoding an ISO-8601 timestamp in the test.
The test now uses the CLI wire format and the complete plan filter passed again.

## Deviations

- Official text SDK jobs omit the authored sandbox setting required only by CLI backends.
  The runner still sets read-only at adapter dispatch. The Cursor SDK is refused because its remote repository agent
  has no read-only contract. Cursor CLI upkeep retains the existing fail-closed no-tools validation.

## Open items

- Formal reviews and the cumulative wave gate follow in the serial integration workflow.
- The operator kept W6-U1-undeclared-redeem-literal open for `bots-18-pairing-surfaces`. The supplemental gate
  applies the approved exclusion for `SurfaceParityWebAPITests/testNoSourceServesAnUndeclaredAPIPath`.
