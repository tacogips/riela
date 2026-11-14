# Monja project task orchestration live acceptance

## Deployed system

Verified on 2026-09-14 against `https://monja-api.tacotest.workers.dev`.
Monja Worker version: `3695fdba-0d5f-42c0-b08b-3111ce4188c5`.
The eleven D1 migrations are applied. Project A owns its Kanban, with General,
service-a, and service-a/docs directories in the Riela Examples workspace.

| Resource | ID |
| --- | --- |
| Workspace | `01M2F80G8WXAPBR685SYQTT7QG` |
| Project A | `01M2F80GGGXVQ0D3SEK768EH3J` |
| Private notification channel | `01M2F80H1T93WQRSWZFBEMF1KY` |
| Dedicated Wrike folder | `MQAAAAEPp1HX` |

## Real task executions

Both runs used a real Codex planner and four executed nodes, all reporting
`gpt-5.6-luna`. Their Riela sessions completed and their final verification
outputs contained `verified: true` with concrete command evidence. The saved
temporary workflow was reconstructed from the Monja task comments and compared
exactly with the payload executed by Riela. Task descriptions contain the goal
and subtask decomposition; workflow comments were persisted before start.

| Evidence | First task | Automatic mirror task |
| --- | --- | --- |
| Monja task ID | `01M2F88107KHJPFCNHQ4X44933` | `01M2F8QA5BYJGTBE1TTBNJQ7KV` |
| Wrike API task ID | `MAAAAAEPp1Ph` | `MAAAAAEPp1r9` |
| Final Monja status | `done` | `done` |
| Final Wrike status | `Completed` | `Completed` |
| Artifact | `RESULT.md` | `AUTO-MIRROR.md` |
| Receipt chat message | `01M2F89SHHR0GF0H1A6Q76KBVB` | `01M2F8QEERNKATVJ8MJAA8H5M2` |
| Start chat message | `01M2F8A747KJCERC1WJMDK35YM` | `01M2F8QTH5NZNT7QVP04JH0E6G` |
| Completion chat message | `01M2F8FWTYVGTMETRYC3V3CGQF` | `01M2F8WM22ZJ16WDPC87EDHZCP` |

Each run also produced four progress messages in chat and Wrike. The first
Wrike completion comment is `IEAG4OENIMB42XYR`. The second task was registered
while the listener was running, with no per-task Wrike mapping. Its counterpart
was created automatically in the configured Wrike folder.

The first artifact was independently checked against its exact 80-byte expected
contents; the second against `Auto-created Wrike mirror verified.` plus newline.
Runtime evidence is retained under ignored `tmp/monja-project-task-orchestrator/`:
`live-state/runs/<task-id>:g1/`, `live-project/site/`, and `live-project.json`.
Session IDs use `monja-<task-id>-g1-session-1`.

The test listener was stopped after both executions and notifications completed.
The Cloudflare deployment and its data remain available. Run the example to
continue polling; no permanently installed local background service is implied.

### Resume the verified local configuration

The deployed admin username is `taco_admin`; its generated password is stored in
the Monja repository's Kinko scope as `MONJA_ADMIN_PASSWORD`. The bot token is
stored there as `MONJA_API_TOKEN`. Do not copy their values into configuration.
On this workstation, from the Monja repository, run:

```sh
kinko exec --env MONJA_API_TOKEN,RIELA_WRIKE_ACCESS_TOKEN -- bun -e '
const child = Bun.spawn(["bun", "main.ts", "../../tmp/monja-project-task-orchestrator/live-project.json"], {
  cwd: "/Users/taco/gits/tacogips/riela/examples/monja-project-task-orchestrator",
  env: {
    ...process.env,
    MONJA_API_URL: "https://monja-api.tacotest.workers.dev/api/v1",
    WRIKE_API_TOKEN: process.env.RIELA_WRIKE_ACCESS_TOKEN,
    RIELA_BIN: "/Users/taco/gits/tacogips/riela/.build/debug/riela",
    MONJA_ORCHESTRATOR_STATE: "/Users/taco/gits/tacogips/riela/tmp/monja-project-task-orchestrator/live-state"
  },
  stdout: "inherit", stderr: "inherit"
});
process.on("SIGINT", () => child.kill("SIGINT"));
process.on("SIGTERM", () => child.kill("SIGTERM"));
process.exit(await child.exited);
'
```

This workstation-specific command reuses the existing live configuration and
durable state. For a portable setup, follow the example README and replace local
paths and resource IDs with your own. Build the CLI first as described below.

## Cancellation prerequisite

Installed Riela 0.1.38 initially failed the actual cancellation test: SIGTERM
stopped the process but left its SQLite session running. Source fix `43edf93`
allows terminal persistence to finish outside the cancelled task context. The
new CLI regression and four neighboring cancellation tests passed. The rebuilt
CLI then passed the example's real SIGTERM verification with `failed` and
`failureKind: cancelled`, allowing pause-and-merge acknowledgment.

Use the source-built CLI containing that fix through `RIELA_BIN`. The second
live execution used this rebuilt CLI. The independent example review and
deterministic coordination/recovery cases are tracked in its implementation plan.

## Verification boundaries

Live evidence proves both external providers, real task discovery, automatic
Wrike creation, planning, persisted workflows, execution and completion. The
reproducible verifier separately exercises wait, merge, parallel execution and
recovery; those branches are not claimed to have all run against live providers.
Occasional Cloudflare 503 responses were retried by the listener without
restarting active work. Browser discovery was empty, so visual UI verification
is not claimed; rendered component tests and API tests passed in Monja.
No credentials are stored in this document or the example fixtures.

Final review iteration 2 approved the recovery fixes. Independent lint, strict
typecheck, 23 tests with 94 assertions, and real CLI execution/cancellation
verification passed (`run-Wo6rDT`). A final restart using `--once` against the
retained live state exited successfully, leaving both tasks succeeded at
generation 1, zero pending notifications, and no scheduler lease.
