# Monja project task orchestrator

Register an open task in Project A and this example discovers it, sends a receipt
to the configured Monja chat channel, reconciles current work, and asks Riela to
plan and execute a temporary workflow. The planner and every generated agent node
explicitly use `codex-agent` with `gpt-5.6-luna`. Production workflows can select
the nodes and models appropriate to their tasks.

The example is a Bun program alongside Riela's Swift CLI. It uses the current
CLI syntax, `riela workflow run <temporary-payload.json>`, and inspects persisted
Riela sessions. A successful process exit alone does not complete a Monja task:
all planned steps and the verification step must complete with verification
evidence. Goal, decomposition, and workflow JSON are persisted in Monja before
the task starts; large workflow JSON is split into task comments.

## Project A and its directories

`fixtures/project.json` maps one Monja project to two real local directories:
`fixtures/project-a/api` and `fixtures/project-a/site`. They represent subprojects
in one project Kanban. Its optional GitHub repository URLs are illustrative;
replace them with actual repository URLs, or use an empty `repositories` array.
The runner uses existing local directories and does not clone those URLs.

Copy this configuration into your repository's ignored `tmp/` directory for live
credentials-free configuration. Replace `projectId`, `channelId`, and the Wrike
configuration with actual API IDs. Directory paths resolve against the example's working
directory; use absolute local checkout paths when working elsewhere. Scope keys
identify write ownership: shared files must belong to a shared scope. Do not map
overlapping checkouts as independent scopes.

Monja exposes todo as `open`, doing as `in_progress`, and completion as `done`.
`fixtures/task-created.json` is a reproducible registration event with these API
values. Its IDs and timestamp are fixture data, not live resources.

## Run against Monja and Wrike

Install Bun and build this checkout's Riela CLI with `swift build --product riela`
from the repository root. Set `RIELA_BIN` to the absolute path of the resulting
`.build/debug/riela`. The CLI must include cancellation fix `43edf93`: installed
Riela 0.1.38 can exit on SIGTERM without persisting terminal acknowledgment and
does not satisfy this example's pause/merge contract. Then ensure Codex
authentication is ready.
The worker's environment contains execution credentials only; the Monja and
Wrike tokens stay in the orchestrator process. Supply secrets through your
existing `kinko exec` environment rather than committing them.

From this directory:

```sh
kinko exec --all -- bun main.ts ../../tmp/monja-project-task-orchestrator/project.json
```

Configure these environment variables in that secret-backed execution context:

| Variable | Value |
| --- | --- |
| `MONJA_API_URL` | Monja origin plus `/api/v1` |
| `MONJA_API_TOKEN` | API token authorized for the project and notification channel |
| `WRIKE_API_URL` | Optional regional API base; defaults to `https://www.wrike.com/api/v4` |
| `WRIKE_API_TOKEN` | Wrike token authorized for the mapped tasks |
| `MONJA_ORCHESTRATOR_STATE` | Absolute path under the Riela repository's `tmp/` directory |
| `RIELA_BIN` | Absolute path to the source-built CLI containing cancellation fix `43edf93` |

For the recorded deployment, `MONJA_API_TOKEN` is stored in the Monja checkout's
Kinko scope. The shared Wrike secret is named `RIELA_WRIKE_ACCESS_TOKEN`; map it
to the process variable `WRIKE_API_TOKEN` in the secret-backed launcher. Resolve
both scopes before invoking the example; running Kinko only in an unrelated
directory does not implicitly make project-scoped secrets available.

Set `wrikeFolderId` to the Wrike folder that receives automatically created task
counterparts. With this configuration, registering a new Monja task is enough:
the adapter reconciles a stable Monja marker before creating its Wrike mirror.
An optional `wrikeTasks` map links existing counterparts using Wrike **API** task
IDs, not numeric IDs from browser permalinks. Explicit mappings take precedence.
Restart the listener after changing configuration, preserving the same state
directory.

The process polls every five seconds, so task registration triggers execution
without requiring outbound webhook delivery. This is also the supported path
when a Cloudflare deployment has intentionally disabled webhook egress until its
VPC policy is configured. Polling reconciles task state after missed events.
`--once` performs one scheduler tick for diagnosis; continuous operation is
required to observe and deliver later progress and completion.

Receipt and start notifications go to Monja chat; execution progress and
completion are mirrored to the mapped Wrike task. Completion updates the Wrike
status through its API. The adapter uses Wrike's
[task update endpoint](https://developers.wrike.com/reference/puttaskssingle).

For a local real-Monja smoke run, point `MONJA_API_URL` at the local API's
`http://127.0.0.1:<port>/api/v1`, create a real project/channel/task, and use that
configuration with the same command. The live planner still runs through Riela
and Codex. A fake-provider fixture pass is recorded separately from this smoke
run and from a deployed acceptance run.

## Scheduling and recovery

The scheduler reconciles todo and doing work before dispatch. Unfinished
dependencies wait. Independent tasks with disjoint write scopes can run in
parallel. Tasks that overlap existing work wait unless they share a merge goal
and the current execution can acknowledge cancellation. Unknown or externally
started doing work waits because its write scope and stop contract are unknown.

For a merge, the actual Riela subprocess receives SIGTERM. A replacement
generation can begin only after the process exits and its session records
`failed` with `failureKind: cancelled`. The merged task retains absorbed task
links, updates its description and goal, persists a new temporary workflow, and
starts a new generation. A replan failure leaves a durable merge intent for the
next tick. After a listener restart, execution that the process cannot safely
cancel waits for completion.

SQLite stores task generations, event receipts, outgoing notifications, and the
single-host scheduler lease. Keep one state directory per project. Retain this
directory across restarts: deleting it discards deduplication and execution
ownership. Session observation failures are retried; silence alone never proves
execution stopped. Reserved launch generations are not automatically replayed
when launch completion is ambiguous.

Notifications use a durable outbox. An ambiguous provider response may produce
duplicate messages, each carrying its stable notification marker. This is
at-least-once delivery: Monja and Wrike do not expose an atomic cross-provider
notification transaction. Inspect marker and session evidence when reconciling
an ambiguous failure.

## Verification and acceptance

See `EXPECTED_RESULTS.md` for executable checks and stable assertions. Generated
runtime evidence belongs under the repository's ignored `tmp/` directory. Do not
treat fixture success as evidence of deployment, live Codex execution, or real
Wrike delivery.

A deployed acceptance run must record the deployment URL/version and migrations,
project/channel/task IDs, receipt/start/progress/completion message IDs, generated
workflow and Riela session ID, successful verification output, Wrike update
evidence, and final Monja status. Credentials must never appear in this record.

The [2026-09-14 live acceptance record](../../design-docs/specs/design-monja-project-task-live-acceptance.md)
contains two completed runs against the deployed Monja service and real Wrike,
including a new registration with automatic Wrike counterpart creation. It also
records the source-built Riela cancellation prerequisite and which coordination
branches were verified through reproducible fixtures.
