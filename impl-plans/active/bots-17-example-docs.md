# bots-17-example-docs: example bundle `bot-routine-memory-upkeep` and user documentation

```json
{
  "planId": "bots-17-example-docs",
  "planPath": "impl-plans/active/bots-17-example-docs.md",
  "dependsOn": ["bots-16-jobs-surfaces"],
  "wave": 8,
  "writePaths": [
    "examples/bot-routine-memory-upkeep",
    "examples/README.md",
    "docs/bots.md",
    "Tests/RielaCLITests/RielaExampleCatalog.swift",
    "Tests/RielaCLITests/RielaExampleParityTests.swift",
    "Tests/RielaCLITests/BotExample",
    "impl-plans/progress/bots-17-example-docs.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Tests/RielaCLITests/RielaExampleCatalog.swift", "intendedEdit": "Insert \"bot-routine-memory-upkeep\" into rielaExampleWorkflowNames() at its alphabetical position."},
    {"path": "Tests/RielaCLITests/RielaExampleParityTests.swift", "intendedEdit": "ONE edit: ExampleCatalog.expectedMockScenarioCount (line 14) 53 becomes 54. Also add the workflow id mapping only if expectedWorkflowId(for:) needs an entry for names that differ from ids (it should not)."},
    {"path": "examples/README.md", "intendedEdit": "One list entry for the new example, in the style of neighbouring entries."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2. Runs in the same wave as
`bots-18-pairing-surfaces`; the two share no path.

## Intent and context

Design §13 and the acceptance criterion "a mock-scenario example bundle
demonstrates a bot with a routine, the overview and the memory-upkeep loop
and is registered wherever examples must be registered". Also the user-facing
documentation for the commands delivered by plans 09–16.

Current code: examples are directories under `examples/` with
`workflow.json`, `nodes/`, `prompts/`, `mock-scenario.json`,
`EXPECTED_RESULTS.md` (see `examples/routine-task-runner`). Registration:
`rielaExampleWorkflowNames()` (`Tests/RielaCLITests/RielaExampleCatalog.swift`)
must equal the discovered directory list, and
`testMockScenarioExamplesRunThroughSwiftCLI`
(`RielaExampleParityTests.swift:249-`) runs every example that has a mock
scenario and checks the count constant (`:14`).

## Non-goals

- No new CLI or runtime behaviour. If the example cannot be expressed with
  what plans 09–16 delivered, record `BLOCKED` in the progress log with the
  missing piece; do not change `Sources/`.
- No remote or pairing steps in the example. This plan writes the whole of
  `docs/bots.md`, including the pairing section; plans 18 and 19 do not touch
  `docs/`.
- No live backend calls.

## Changes

### `examples/bot-routine-memory-upkeep/`

- `workflow.json`: `workflowId: "bot-routine-memory-upkeep"`, one agent step
  `triage` (role worker) whose node reads the routine task from the workflow
  input and returns `{ summary, conditionMet: false }`. Keep it to one agent
  node so the parity test's generic mock run passes. Follow
  `examples/routine-task-runner/workflow.json` for shape and defaults.
- `nodes/node-triage.json`, `prompts/triage.md`: short prompt; backend and
  fields in the style of `examples/routine-task-runner/nodes/`.
- `mock-scenario.json`: one response for `triage`.
- `upkeep-mock-scenario.json`: one response for the upkeep job workflow's
  node id (read the id from `Sources/RielaCLI/BotJobs/BotJobWorkflows.swift`)
  whose payload `memoryMarkdown` keeps the instruction and merges the two
  notes created in the walkthrough.
- `memory-seed.md`: the Markdown used by `bot memory edit` in the walkthrough
  (one instruction, two notes, no id markers).
- `README.md`: what the example shows, in a few lines.
- `EXPECTED_RESULTS.md`: the walkthrough below with the expected outcome of
  each command. All commands use `--session-store`, `--routine-store`,
  `--memory-root` and `--artifact-root` under `tmp/bots-overview/example/`.

Walkthrough (commands must be copy-paste runnable from the repository root):

1. `riela bot create --name "Triage Bot" --backend codex-agent`
2. `riela routine create --name nightly-triage --task "..." --every 1d --workflow bot-routine-memory-upkeep --bot triage-bot` (plus the event root under `tmp/`)
3. `riela workflow run bot-routine-memory-upkeep --workflow-definition-dir examples --mock-scenario examples/bot-routine-memory-upkeep/mock-scenario.json --bot triage-bot`
4. `riela bot list` → one bot, last activity set, last-result line.
5. `riela bot show triage-bot` → the run under Closed, the routine with next
   run, one Planned item.
6. `riela bot memory edit triage-bot --file examples/bot-routine-memory-upkeep/memory-seed.md`
7. `riela bot job run triage-bot upkeep --force --mock-scenario examples/bot-routine-memory-upkeep/upkeep-mock-scenario.json`
8. `riela bot memory history triage-bot` → an `upkeep` change set after the
   edit; `riela bot memory show triage-bot` → merged note.
9. `riela bot memory undo triage-bot` → memory back to the seeded state.

The upkeep mock scenario must reference record ids. Ids are assigned at step
6, so the walkthrough states that a fresh memory root is required and the
seeded entries get ids 1, 2, 3 in file order; the test below verifies this.

### `docs/bots.md`

Sections, each short and command-led: what a bot is (thin identity over
routines, runs, Work tasks, riela memory); create and manage; linking runs
and routines (`--bot`); overview and board (group meanings, `activitySource`);
activity and answering permission requests (wait defaults, decline on
timeout); models and providers (`default`, warnings, passive refresh); list
management (pin, snooze, settle, limited); memory (Markdown format, rules:
no secrets, external content is a note, undo); jobs and suggestions (upkeep
schedule, look-around is read-only and opt-in); pairing and remotes (mint,
address rules, scopes, revoke, `riela remote`, origin and disconnected
state); storage (session store generation 13; memory databases unchanged).
Take every command and flag from the implemented help text
(`riela bot --help`, `riela remote --help`, ...) and the design. Plans 18 and 19 are not accepted yet when this plan runs
(18 is a sibling, 19 comes later): write the pairing and remotes section from
design §11 and plans 18 and 19 (commands `riela serve --pairing-address`,
`riela serve pairing mint|list|revoke`, `riela remote add|list|show|remove|use`,
`--remote`, `--all-remotes`) and start it with the line
"Requires the pairing commands (`riela serve pairing`, `riela remote`)."

### Tests (`Tests/RielaCLITests/BotExample/BotExampleWalkthroughTests.swift`)

Runs the walkthrough through `RielaCLIApplication` in a temporary directory
(copying nothing; using the repository `examples/` path):
- step 3 → exit success; a link row for `triage-bot`.
- step 4 JSON → `lastActivityAt` non-null.
- step 5 JSON → one Closed item, one routine, one Planned item.
- steps 6–8 → history has actors `cli` then `upkeep`; shown memory has two
  entries (one instruction, one merged note).
- step 9 → memory has three entries again.

## Pitfalls

- The example directory name, the `workflowId` and the catalog entry must be
  identical strings.
- `rielaExampleWorkflowNames()` is compared as an ordered list with the
  discovered names; insert in sorted position (after `apple-reminders-list`
  and before `brain-generated-workflow-loop`).
- Extra files in the example directory must not be mistaken for scenarios by
  the parity test: the generic test uses `mock-scenario.json` only; keep the
  upkeep scenario under a different file name.
- Do not write walkthrough output into the repository; only under `tmp/`.

## Verification

```
mkdir -p tmp/bots-overview/bots-17-example-docs tmp/bots-overview/example
arch -arm64 /bin/zsh -lc 'swift test --filter "BotExampleWalkthroughTests|RielaExampleParityTests/testAllRielaExampleWorkflowsArePortedAndValidateInSwift"' > tmp/bots-overview/bots-17-example-docs/test.log 2>&1
arch -arm64 /bin/zsh -lc '.build/debug/riela workflow run bot-routine-memory-upkeep --workflow-definition-dir examples --mock-scenario examples/bot-routine-memory-upkeep/mock-scenario.json --session-store tmp/bots-overview/example/sessions --artifact-root tmp/bots-overview/example/artifacts --output json' > tmp/bots-overview/bots-17-example-docs/mock-run.log 2>&1
```

Both exit 0; the mock-run log ends with a completed session. The full
`testMockScenarioExamplesRunThroughSwiftCLI` (all 54 examples) is run at the
wave gate, not here.

## Done criteria

- `ls examples/bot-routine-memory-upkeep` shows `workflow.json`, `mock-scenario.json`, `upkeep-mock-scenario.json`, `memory-seed.md`, `EXPECTED_RESULTS.md`, `README.md`, `nodes`, `prompts`.
- `grep -n "expectedMockScenarioCount = 54" Tests/RielaCLITests/RielaExampleParityTests.swift` prints one line.
- `git status --short Sources` shows no change made by this plan.
- Verification exits 0; progress log written.
