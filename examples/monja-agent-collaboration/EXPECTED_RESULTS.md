# Expected deterministic results

Build the source-checkout CLI, then run:

```sh
.build/debug/riela workflow validate monja-agent-collaboration --workflow-definition-dir ./examples
.build/debug/riela workflow inspect monja-agent-collaboration --workflow-definition-dir ./examples --output json
bun examples/monja-agent-collaboration/verify-workflow.ts
cd examples/monja-agent-collaboration
bun run lint
bun run typecheck
bun test --coverage
```

## Stable assertions

- Native validation succeeds; default inspection orders architect, skeptic,
  integrator with three nodes/steps and fresh sessions.
- The deterministic default run completes with three executions and two
  transitions. Each accepted payload matches its native node schema.
- The next inbox's latest payload exactly equals the preceding accepted
  payload. Flat priorTurns preserve every preceding persona/message/details
  without recursively nesting handoff history.
- Final output is solved, has no unresolved blockers, and includes acceptance
  evidence. All configured published turns match canonical Monja identity,
  content, author and parent before task completion.
- Four-role execution adds operator between skeptic and integrator and
  publishes one root plus four ordered replies without runner source edits.
- Failed-final recovery after compatible prompt repair retains source lineage,
  root and earlier replies. Deliberately invalid earlier fixture outputs prove
  those earlier model adapters are not invoked during preserved recovery.
- Restart creates no new model launch or message. An interrupted initial or
  recovery session-ID save reconciles the logged existing session.
- Missing/ambiguous launch identity stops without a second launch.
- Root/reply requests retain the same idempotency key, original content and
  parent after uncertain responses. Canonical tampering prevents completion.
- Invalid participant shape/order/final ownership/token names fail before
  external writes. Missing tokens do not fall back. Participant authors must
  be distinct.
- A state-wide SQLite lock excludes competing runners and releases after
  process crash.
- Both model-runner and verifier children exclude every MONJA credential.
- Failure or unsolved output never completes an open task.

The mock model fixtures and in-memory HTTP API are explicitly deterministic
local tests. They do not claim production deployment, real model reasoning
quality, or D1 persistence verification.

## Combined real D1 acceptance

From the sibling Monja checkout, run:

```sh
bun test tests/collaboration-acceptance/acceptance.test.ts
bunx --no-install tsc -p tests/collaboration-acceptance/tsconfig.json
```

Six tests combine the real API composition and Miniflare D1 schema with the
unchanged Bun example process and Swift CLI. Only realtime delivery and model
responses use explicit deterministic fixtures. Default and four-role runs
create four and five messages respectively, one task link, and distinct
participant authors. Recovery creates a new native session with two imported
prefix executions and one fresh final execution; accepted payloads and final
inbox ordering remain equal, and the failed source stays unchanged.

Discarded successful root/reply responses become HTTP 503 after D1 commit.
New runner PIDs preserve the root and messages; a root retry exercises native
same-key POST replay, while a reply can reconcile through the existing thread.
A test-only preload exits before saving the session ID and restart adopts the
single existing native launch. Concurrent first creation under capacity for
one message produces one receipt, FTS row and mention notification, and exactly
one UTF-8 content storage increment. Conflicting reuse returns 409.

Each case retains exact generated identities and database evidence in Riela
`tmp/collaboration-d1-*/acceptance.json`, without credentials. This verifies
local D1 persistence and runner recovery; the API/database do not restart,
model reasoning is mocked, and nothing is deployed.

## Reproduction record

A takeover session on 2026-09-15 rebuilt the CLI from the current worktree
(`swift build --product riela`) and re-ran every command in this file against
that binary:

- `workflow validate` reported `valid: true` with no diagnostics.
- `workflow inspect --output json` reported three nodes and three steps ordered
  `architect, skeptic, integrator`, each with a native `output.jsonSchema`.
- `verify-workflow.ts` passed.
- `bun run lint` checked 28 files with no diagnostics; `bun run typecheck` was
  clean.
- `bun test --coverage` produced **86 pass, 0 fail, 249 assertions in 29.99 s**,
  with 100% functions and 99.27% lines across the example sources.

The combined real-D1 acceptance suite in the sibling Monja checkout produced
**6 pass, 0 fail, 130 assertions in 45.07 s** against the same binary, with its
dedicated TypeScript and Biome checks clean. The per-scenario artifacts for that
run are `tmp/collaboration-d1-JtwLUK` (default roles and reply loss), `d7iNeq`
(four participants), `IISNoB` (failed-final repair), `qzxY1g` (root loss),
`8Lch9p` (session-ID save crash) and `WICPSJ` (concurrent first creation). The
limits stated above are unchanged.

### Swift package test registration

Adding this example to `examples/` made
`RielaExampleParityTests.testAllRielaExampleWorkflowsArePortedAndValidateInSwift`
fail on the whole-package `swift test` run: that test asserts that the workflows
discovered under `examples/` are exactly the names listed in
`Tests/RielaCLITests/RielaExampleCatalog.swift`, and `monja-agent-collaboration`
was discovered but not listed. The accompanying
`testMockScenarioExamplesRunThroughSwiftCLI` counts mock scenarios and needed the
same bump.

The registration was added (`rielaExampleWorkflowNames()` gained
`"monja-agent-collaboration"`, and `ExampleCatalog.expectedMockScenarioCount`
went from 38 to 39; `expectedNodeMockScenarioCount` stays 0 because this example
ships `nodes/` and `prompts/` rather than a `scripts/` Node runtime). After the
change, `swift test --filter RielaExampleParityTests` reports **9 tests, 0
failures (0 unexpected) in 143.588 s**, including both affected tests.

The whole package suite was then re-run end to end: 2,218 tests, 1 skipped, 17
failures (2 unexpected), with `RielaExampleParityTests` no longer among the
failing cases. The remaining failures are six AppKit `RielaAppSupportTests`
cases and one deterministic `RielaAppSupport` daemon-state case belonging to
concurrent desktop work, plus two that pass when re-run in isolation and are
load-sensitive under full-suite parallelism.

## Unstable fields

Session, execution, and communication IDs are generated. Assert their
relationships/uniqueness, not fixed values. Timestamps, temporary/artifact paths,
and wall-clock duration are also unstable.
