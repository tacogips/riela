# bots-17-example-docs progress

## Implemented

- Added `examples/bot-routine-memory-upkeep/` with one mock triage step,
  the upkeep scenario and seed Markdown, and a nine-step walkthrough.
- Registered the bundle in `Tests/RielaCLITests/RielaExampleCatalog.swift`
  and `examples/README.md`. The expected and discovered mock counts are 54.
- Added `docs/bots.md` for the CLI commands from plans 09–16 and the
  pairing-dependent commands planned for 18–19. Linked it from `README.md`.
- `BotExampleWalkthroughTests` exercises the real CLI using isolated roots.
  It verifies completed run linkage, list last activity and result, the
  Closed run and Planned routine, record IDs 1–3, the audited upkeep change,
  consolidation, and restoration of the seeded entries.
- All 207 source hashes match the pre-node snapshot. The source status and
  the active plan and manifest are unchanged by this plan.

## Per-edit hashes

Full pre/post evidence and edit intentions are in
`tmp/bots-overview/bots-17-example-docs/edit-intentions.md`.

- `examples/bot-routine-memory-upkeep/workflow.json` pre `absent`. Add a single worker step with routine-task-runner defaults.
  Post `755d6cee4e8bc0d3a5c5b1a1763e1236ef33589db77ad5f5380e2791e6ffcfb2`.

- `examples/bot-routine-memory-upkeep/nodes/node-triage.json` pre `absent`. Declare a read-only triage node returning summary and conditionMet.
  Post `12b8b950e130001e4f3ed580b77daef761b3b3955dc7c8c4fba110e702babc86`.

- `examples/bot-routine-memory-upkeep/prompts/triage.md` pre `absent`. Read the routine task from workflowInput and request a summary without completing the routine.
  Post `6d274d3e02afc415e6b5d02272d7fcd36be9aa73d754c8808b67855fbd5458c7`.

- `examples/bot-routine-memory-upkeep/mock-scenario.json` pre `absent`. Mock the triage step with a stable result for the parity and standalone runs.
  Post `625b555ed8ec58dd7fee9ba739dd8576e983c6f55abfcfcd9b5cfed4856cbef3`.

- `examples/bot-routine-memory-upkeep/memory-seed.md` pre `absent`. Seed one instruction and two notes in deterministic ID order.
  Post `e1cabb7e0d6fb78533c3d27e3c4a2f9ac36f2b59cac94f8ec3c5d91f91f7fb0a`.

- `examples/bot-routine-memory-upkeep/upkeep-mock-scenario.json` pre `absent`. Mock upkeep Markdown preserving instruction ID 1 and merging notes under ID 2.
  Post `a13aec31910288157de6b054180c988c4ff7c079a3dd26d321ab9bf291f05eca`.

- `examples/bot-routine-memory-upkeep/README.md` pre `absent`. Introduce the bundle and link the reproducible walkthrough.
  Post `5e4e7d225206292c0fc355f0f3bb03aae58da4f6cc133784664949cebf7edd2d`.

- `Tests/RielaCLITests/RielaExampleCatalog.swift` pre `432a58acd8901bb022939303b6db5c13cfb63b48b196e5d66d8c1629477e672d`. Register the new workflow between apple-reminders-list and brain-generated-workflow-loop.
  Post `6fc5d916b09555a0b8685157ec895ff36c0669346469736abde3b28c89f25de5`.

- `Tests/RielaCLITests/RielaExampleParityTests.swift` pre `b400e82e6d62c6f8dbb8b35d7c8a3a77e4b5070555f7984a8859ad87e3d5de28`. Increase the mock scenario count from 53 to 54.
  Post `3d498c1a95bd5665b5f71d5496866628f41bdc9faca80a3356b086f44bac80ba`.

- `examples/README.md` pre `d8c37d7a9df3b29713520aace0dabec1feb4bcab9e6d64ed740bd1b7bc49fdb2`. Link the walkthrough in the example index.
  Post `78aa39f03b6f8a92215d7138ce50a82f36dae1d023ceb8306b68976616b8ac43`.

- `examples/bot-routine-memory-upkeep/EXPECTED_RESULTS.md` pre `absent`. Document the nine real CLI steps with isolated roots, stable expected results, and ID assumptions.
  Post `b9691c57529a227966b3980ba55ab54fde965967baa147aa8a8d041fe5abe08f`.

- `examples/bot-routine-memory-upkeep/EXPECTED_RESULTS.md` pre `b9691c57529a227966b3980ba55ab54fde965967baa147aa8a8d041fe5abe08f` (drift from snapshot). Use the supported six-field daily cron expression after CLI rejected 1d interval shorthand.
  Post `1778ca1d76722a29bbf1e822218726173e5803ef98427ee707c5cd0d50023143`.

- `Tests/RielaCLITests/BotExample/BotExampleWalkthroughTests.swift` pre `absent`. Exercise the checked-in mock walkthrough through real CLI commands, checking store linkage, both board groups, memory IDs, audited actors, consolidation and undo.
  Post `9658a0e7768d36cc8e1ef320aa59df7cce9dea8f1e817f048cd6e9a114284ad0`.

- `docs/bots.md` pre `absent`. Add command-led Bots documentation for plans 09–16 and a labeled pairing and remotes section from design §11 and plans 18–19.
  Post `e512b10576e70e40fb2f17251dbaa1b2ee18f3b02696c15fdca2c786a9327539`.

- `README.md` pre `096f8f126f9ebdade922d37777455ad991f47d6fbcd4c9261f79cd0a72122107`. Link the new Bots command reference and example before the routines section.
  Post `652d1ced3c8e7dd9d670dbc2790a7686fb4d9167b5840970ddd337abeb6f4111`.

## Verification

Logs are under `tmp/bots-overview/bots-17-example-docs/`. All listed
final-source commands exited 0.

| Command | Log | Result |
| --- | --- | --- |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "BotExampleWalkthroughTests\|RielaExampleParityTests/testAllRielaExampleWorkflowsArePortedAndValidateInSwift"'` | `test.log` | Executed 2 tests, with 0 failures (0 unexpected). |
| `arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate bot-routine-memory-upkeep --workflow-definition-dir examples --output json'` | `validate.log` | Valid. |
| `arch -arm64 /bin/zsh -lc '.build/debug/riela workflow inspect bot-routine-memory-upkeep --workflow-definition-dir examples --output json'` | `inspect.log` | One step, entry `triage`. |
| `arch -arm64 /bin/zsh -lc '.build/debug/riela workflow run bot-routine-memory-upkeep --workflow-definition-dir examples --mock-scenario examples/bot-routine-memory-upkeep/mock-scenario.json --session-store tmp/bots-overview/example/sessions --artifact-root tmp/bots-overview/example/artifacts --output json'` | `mock-run.log` | Completed session, expected summary, `conditionMet: false`. |
| `arch -arm64 /bin/zsh -lc 'zsh tmp/bots-overview/bots-17-example-docs/walkthrough.sh'` | `walkthrough-attempt2.log` | Ran the code blocks from the final walkthrough end to end. |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/bots-overview/bots-17-example-docs/changed-swift.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/bots-overview/bots-17-example-docs/changed-swift.nul; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` | `swiftlint.log` | Strict lint passed on the three changed Swift files. |
| `python3 tmp/bots-overview/bots-17-example-docs/check-scope.py` | `scope.log` | Bundle entries, mock count, source hashes, plan preservation, and JSON outputs verified. |
| `git diff --check` | `diff-check.log` | Clean. |

## Deviations

- The first walkthrough run exited 1 at routine creation because
  `--every 1d` is unsupported. The equivalent daily UTC cron expression
  passes in `walkthrough-attempt2.log`. The first run is preserved in
  `walkthrough-first.log`. The second edit to `EXPECTED_RESULTS.md`
  differs from the pre-node snapshot because it follows the file's creation
  by this plan.
- The walkthrough exports the isolated roots where commands lack matching
  flags. The standalone workflow run sets an artifact root explicitly.

## Open items

- Formal reviews and the cumulative wave gate, including the 54-example
  mock suite, belong to the downstream workflow steps.
- The operator deferred W6-U1-undeclared-redeem-literal to
  `bots-18-pairing-surfaces`. Its route parity test is excluded from the
  wave gate through plan 17. No production changes were needed here.
