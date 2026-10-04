# Work handover and takeover

A Work Runtime handover moves a task attempt to a successor when work needs a person, an interactive host, or recovery after its owner disappears. The runtime builds a digest-sealed `HandoverPacket` from durable task, attempt, session and evidence records. A successor imports the accepted history, materializes published deliverables where possible, and resumes at the packet's `resumeStepId`.

## When a handover happens

The same packet and task workflow cover these cases:

- **S1, user input:** an agent returns a `handover` envelope with `reason: "userInputRequired"` and a question. The task waits for an answer. `task answer` records it; the server can continue locally with `task run`, or a successor can continue with `task takeover`.
- **S2, user presence:** an agent or classified backend wait signal requires a host with declared traits such as `userReachable`. The task waits until an eligible host takes it. Classified wait signals use typed tool-call status; unclassified events follow the inactivity policy.
- **S3, inactivity or owner loss:** `guard.handover.onWaitSignal` handles enabled wait signals; `director.deterministic.handoverOnInactivity` opts into inactivity handover. An expired owner lease can be fenced and recovered with `task takeover --force-orphan`, or reconciled first with `task reconcile --expired-leases`.
- **S4, operator move:** `task handover <taskId> --reason <text>` requests handover at a step boundary. Add `--now` to interrupt the active node; that node may be rerun by the successor.

Boundary handovers end the source session as `suspended`. A node interrupted during execution ends `failed(.stalled)` for inactivity/wait-signal interruption, `failed(.cancelled)` for `--now`, or `failed(.leaseLost)` when fenced. A suspended workflow run or resume returns exit code **5**. `session resume` can resume a suspended plain session on the same store.

## Agent contract

An agent can return the envelope in its normal output JSON:

```json
{
  "answer": {"summary": "Waiting for the operator's choice."},
  "handover": {
    "reason": "userInputRequired",
    "question": {
      "id": "deployment-target",
      "text": "Which deployment target should I use?",
      "options": [{"id": "staging", "label": "Staging"}, {"id": "production", "label": "Production"}],
      "answerSchema": {"type": "object", "required": ["option"], "properties": {"option": {"type": "string"}}}
    },
    "progressNote": "Build and validation passed; deployment has not started.",
    "resumeStepId": "deploy"
  }
}
```

`reason` is `userInputRequired` or `userPresenceRequired`; the former requires a non-empty question id and text, and the latter requires at least one presence trait. `progressNote` is limited to 8 KiB. `resumeStepId` must select the next supported step and may not target a fanout or cross-workflow transition.

For an add-on declaration, use `riela/handover-request@1`; `resumeStepId` is required by the add-on configuration:

```json
{
  "name": "riela/handover-request",
  "version": "1",
  "config": {
    "reason": "userInputRequired",
    "question": {"id": "deployment-target", "text": "Which target?"},
    "resumeStepId": "deploy"
  }
}
```

The runtime validates the envelope and builds the packet. Agents supply only the bounded progress note and question; they do not author packet state.

## Packet, history, and deliverables

The packet records the reason, task and attempt state, accepted progress, bounded history, question or presence instructions, deliverable states and locators, open findings, remaining budget, rendered brief, and a stable digest. Bounds include 2 MiB for history, 256 KiB for redacted variables, 64 KiB for the brief, 16 artifacts / 512 KiB for an artifact bundle, and 4 MiB for the whole packet. Truncated history cannot be imported as a bundle; read the canonical packet from the controller store instead.

The controller's `work_handovers` row is canonical. `store` is always present; configured `kaiba`, `gitRef`, `file`, or `command` sinks mirror the packet bytes. A serialized sink reference has the form `kind:locator#sha256:<64 lowercase hex digits>`. `task takeover --packet <locator-or-path>` reads an explicit packet; the runtime verifies its digest before use. Without `--packet`, takeover loads the packet from the local store or `--endpoint` controller.

Repository task attempts publish checkpoints on `riela/task/<taskId>/g<generation>`. Checkpoint commits use the `Riela-Checkpoint` trailer. Publication is limited to these task branches, never force-pushes, and happens before packet sealing. A task can report a repository deliverable as unpublished or checkpoint-failed; takeover refuses a checkpoint-failed repository before reserving a successor.

Plain-session adoption is intentionally read-only against the existing checkout. `session handover <sessionId> [--reason <text>]` records the repository at `HEAD` as unpublished and lists dirty paths; it never switches branches, commits, creates refs or pushes the user's checkout. Uncommitted adopted work stays in that checkout. A successor starts from `HEAD`, so commit the work before adoption if it must be transferred. `session resume <sessionId>` remains available for same-store continuation without adoption.

## Common recipes

### Answer on the server, then continue there

```sh
riela task answer <taskId> --question <questionId> --text "staging"
riela task run <taskId>
```

Use `--answer-json`, `--answer-file`, `--option`, or `--use-default` instead when appropriate. The answer is checked against `answerSchema` when present. The server binds an answer to the task, predecessor attempt, handover id and question. The takeover attempt receives it as `handover.answer` and as a delivered message at the resume step. For answered S1 over GraphQL, `takeoverTask` returns the answer; an unanswered S1 request fails with `conflict` before reservation.

### Take over on a laptop

```sh
riela task takeover <taskId> --endpoint https://controller.example/graphql --traits userReachable --clone-into /Users/me/work/project
```

`--clone-into` is for a published repository deliverable. `task serve --takeover --endpoint https://controller.example/graphql --traits userReachable` polls and runs eligible work unattended; it skips unanswered questions. Add `--once` for one poll. Remote calls use the manager bearer and manager-session authorization configured for `riela serve`; use `--auth-token-env` rather than putting a secret in shell history.

### Recover an orphan

Wait until the lease expires, then either take over directly:

```sh
riela task takeover <taskId> --force-orphan
```

or seal expired leases for operator review before taking one over:

```sh
riela task reconcile --expired-leases
riela task takeover <taskId>
```

The default lease is `guard.lease.ttlMs: 300000` (300 seconds) with `heartbeatMs: 15000` (15 seconds). A takeover increments the fence; an old owner that resumes cannot heartbeat or report successfully.

## Host traits and configuration

Declare traits; Riela does not probe for them. Configure the local profile's `hostTraits`, put `"traits": ["userReachable"]` in `worker.json`, or pass `--traits userReachable` to a takeover or takeover server for that invocation. Placement requires every trait requested by the handover. A host without them leaves the task waiting with `host-traits-unavailable`.

Task lease policy belongs under `guard.lease`. Handover sinks belong under `guard.handover.sinks` or top-level `handover.sinks` in the workflow; task settings take precedence when merged. There is no profile-level sink setting.

## Notifications and cleanup

To receive the handover event in a workflow loop, configure:

```json
{"loop": {"notifications": {"on": ["handover"]}}}
```

`riela gc` removes handover files and refs for terminal or absent tasks and retains those for non-terminal tasks. It fails closed if the database is missing or locked.

## Security notes

Packet variables, accepted outputs, history, response excerpts, and the agent progress note are redacted before storage and bounded: a bound secret value is replaced by `<redacted:ENV_NAME>` both when a value equals it exactly and wherever it appears inside free text (values shorter than 4 bytes are only matched exactly, so they cannot shred ordinary words). Sink writes publish data outside the canonical work store, so configure only sinks whose access and retention are appropriate. The digest detects changed packet bytes but does not provide confidentiality. Manager bearer tokens and lease heartbeat credentials are secrets: do not paste them into logs, workflow output, or shared shell history. Remote GraphQL task fields require a manager-authorized `/graphql` request; report and heartbeat calls require the lease credential returned when the attempt is reserved.

## Command options

The task commands accept `--scope auto|project|user`, `--working-dir` (also
`--working-directory`), and `--session-store` to select the work store; commands
that render a result also accept `--output`. `--principal` records the local
operator identity where available.

- `task handover`: required `--reason`; optional `--now`, `--to`, and `--sink`.
- `task answer`: required `--question` and exactly one of `--answer-json`, `--answer-file`, `--text`, `--option`, or `--use-default`.
- `task takeover`: optional `--packet`, `--handover-id`, `--force-orphan`, `--clone-into`, `--traits`, and `--sink`. Remote takeover adds `--endpoint`, `--auth-token` or `--auth-token-env` (default environment name `RIELA_MANAGER_AUTH_TOKEN`), and `--manager-session-id` (default environment name `RIELA_MANAGER_SESSION_ID`). `--endpoint` and `--force-orphan` cannot be combined.
- `task handovers`: optional `--output json`.
- `task reconcile`: requires `--expired-leases`; optional `--dry-run` and `--sink`.
- `task serve`: requires `--takeover`; optional `--endpoint`, `--traits`, `--once`, and `--poll-interval-ms` (default 5000), plus `--auth-token`, `--auth-token-env`, and `--manager-session-id` for remote polling.
- `session handover`: optional `--reason` (defaults to `operator handover`), `--task`, and `--sink`, plus the scope, working-directory, session-store, principal and output options. It creates a task adopting the existing session.
