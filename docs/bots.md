# Bots

A bot is a saved identity for related runs, routines, Work tasks and riela
memory. The runtime uses those records to show what the bot is doing and
what needs your attention.

## Create and manage bots

```sh
riela bot create --name "Triage Bot" --backend codex-agent
riela bot update triage-bot --purpose "Review the incoming queue" --workspace support
riela bot pause triage-bot
riela bot resume triage-bot
riela bot remove triage-bot
```

Set `--id` at creation to choose an ID. Create and update also accept
`--persona`, `--backend`, `--provider`, `--model`, `--workspace`,
`--memory-upkeep`, `--look-around` and `--permission-wait-ms`. A bot's backend
and model defaults apply to bot jobs. Workflow nodes use their own settings.

## Link runs and routines

```sh
riela workflow run <workflow> --bot triage-bot
riela routine create --name nightly-triage --task "Review the incoming queue" \
  --schedule '0 0 0 * * *' --timezone UTC --workflow <workflow> --bot triage-bot
```

A routine carries its bot ID into each scheduled run. The bot and its linked
work must be visible in the selected runtime store. Follow the
[mock walkthrough](../examples/bot-routine-memory-upkeep/EXPECTED_RESULTS.md)
to try both commands with isolated storage.

## Read the overview and board

```sh
riela bot list --group-by workspace --output json
riela bot show triage-bot --output json
```

The overview includes task counts, active workflow steps with backend, model
and elapsed time, last activity, and a last-result line. The detail includes
routines with their next run, suggestions, and a memory summary.

| Board group | What belongs there |
| --- | --- |
| Needs you | A permission request, handover question, or other item that needs your decision |
| In progress | Work currently running |
| Waiting | Work waiting with a reason, such as a limit, child, or retry |
| Planned | Scheduled routines, queued work, or accepted suggestions awaiting a run |
| Closed | Recent completed, failed, or otherwise terminal work |

`activitySource: acp` identifies ACP-backed detail. `activitySource: session`
identifies session and step status, including mock runs.

## Follow activity and answer permissions

```sh
riela bot activity triage-bot --after 0 --limit 50
riela bot activity --session <session-id> --follow --output jsonl
riela bot answer <request-id> --option <option-id>
riela bot answer <request-id> --decline
```

Continue from the last sequence to replay the retained stream. Following waits
for new events. Use an option ID from the pending request. A linked run waits
up to five minutes by default, bounded by the step deadline. Set
`--permission-wait-ms` on the bot to change the wait. Zero declines without
waiting, and a request still pending at the deadline is declined.

## Browse models and provider instances

```sh
riela model list --provider <instance-id>
riela provider list
riela provider show <instance-id>
riela provider refresh <instance-id>
riela provider add --id <instance-id> --driver codex-agent --custom-model <model-id>
riela provider update <instance-id> --custom-model <model-id>
riela provider remove <instance-id>
```

Provider instances describe a driver and its configuration. The catalog merges
bundled models, models reported by the provider and custom entries. Use
`--clear-custom-models` on update to clear custom entries. Refresh checks
health and credentials passively without starting an agent session. Model
`default` leaves selection to the provider. An unknown model emits a
`model_unknown` warning and allows the command to proceed.

## Organize the list

```sh
riela bot pin triage-bot
riela bot move triage-bot --position 1
riela bot snooze triage-bot --for 2h
riela bot unsnooze triage-bot
riela bot settle triage-bot --item session:<session-id>
riela bot unsettle triage-bot --item session:<session-id>
riela bot unpin triage-bot
```

Each command also accepts `--item session:<id>` or `--item task:<id>`.
Snooze accepts an ISO 8601 timestamp via `--until` in place of `--for`.
Needs-you work and new failures can wake snoozed items early. Busy items
cannot be settled. Closed items can settle automatically after seven days.
The server projects list order, including the Working group and which items
move toward the top after finishing, failing or needing attention. A
`limited` item appears in Waiting with its reset time when available.

## Edit and audit riela memory

```sh
riela bot memory show triage-bot
riela bot memory export triage-bot --out memory.md
riela bot memory edit triage-bot --file memory.md --reason "Update triage criteria"
riela bot memory history triage-bot
riela bot memory diff triage-bot <change-id>
riela bot memory undo triage-bot <change-id>
```

Use `## Instructions` and `## Notes` with optional `### topic` headings and
one list item per entry. Preserve trailing `<!-- id:N -->` markers on entries
you keep. Unmarked items are new, and omitting an existing entry requests
its removal. Undo defaults to the latest change and records a new audit entry.

Keep secrets out of memory. The runtime applies secret redaction and records
entry provenance. Store external content as notes. User-authored instructions
and corrections can guide later runs. Review and upkeep content can update
notes. The runtime adds memory to linked agent prompts within the prompt budget.

## Run jobs and decide suggestions

```sh
riela bot update triage-bot --memory-upkeep nightly --look-around off
riela bot job run triage-bot upkeep --force
riela bot job list triage-bot --job upkeep
riela bot update triage-bot --look-around weekly
riela bot job run triage-bot look-around
riela bot suggestion list triage-bot --status open
riela bot suggestion accept <suggestion-id> --run
riela bot suggestion dismiss <suggestion-id> --reason "Already handled"
riela bot feedback triage-bot --session <session-id> --text "Check the queue first." --from-findings
```

Upkeep defaults to nightly, and both jobs accept `nightly`, `weekly` or
`off`. While serving, Riela checks for due jobs and can catch up missed
periods when a bot is active and idle. Upkeep asks the agent for Markdown
with tools disabled and applies it as an audited memory change. Look-around
is opt-in and enforced as read-only by the runtime. Accept a suggestion to
put it under Planned, or pass `--run` to start its proposed workflow.
Feedback captures a correction or recorded findings from a finished session
or Work task in the same memory history.

## Pair a remote server

```sh
riela serve --pairing-address <url> --pairing-scope operate
riela serve pairing mint --address <url> --pairing-scope operate
riela serve pairing list
riela remote add --name team --code <pairing-code>
riela remote list
riela remote show team
riela remote use team
riela bot list --all-remotes
riela bot show triage-bot --remote team
riela workflow run <workflow> --remote team --bot triage-bot
riela remote use local
riela remote remove team
riela serve pairing revoke --grant <grant-id>
```

Use an absolute HTTPS address, or plain HTTP with a literal private-network
IP address. Loopback, unspecified and wildcard addresses are refused. A
pairing code is a bearer secret that expires after ten minutes and can be
redeemed once. Keep it out of logs. The default scope is `operate`.
`read` permits queries, `operate` also permits routine operations and other
non-admin mutations, and `admin` includes credential and configuration
management. Revoking a grant closes access. Removing a remote only removes
the locally stored registration and token.

Adding a remote leaves the active selection as it was. Per-command
`--remote` overrides the active selection, including when starting a workflow
or creating a routine. The overview labels the server that owns each item.
A missing or mismatched identity is unverifiable. A disconnected server
shows its last-known overview and observation time when available.

## Use the web console

Open **Bots** in the console served by `riela serve` (`#/bots`). The bot list
stays on the left and the selected bot shows on the right: board, live
activity, pending answers, routines, memory, suggestions and jobs. With no
selection the first active bot is shown; `#/bots/<bot-id>` selects one bot.
On a narrow window the list and the detail show one at a time.

- Click a Needs you, In progress or Waiting item that has a session to open
  its workflow run screen (`#/runs/<session-id>`). The **Activity** button
  keeps the activity pane one click away.
- The memory panel edits the same Markdown as `riela bot memory edit`, lists
  changes with their diff, and can undo the newest change. A draft is kept
  when a save fails.
- Suggestion cards accept or dismiss a suggestion; job controls run upkeep or
  look-around; the feedback box records a correction.
- The remote switcher selects one paired server or all of them, adds a server
  from a pairing code, and labels each row with its host. A disconnected
  server is listed apart with its last-seen time and no actions. Rows whose
  server identity is unverifiable offer no actions.
- **Models** (`#/models`) lists provider instances and their models.

For a run on a paired server, the run screen shows the forwarded activity
only; the full graph and execution evidence stay on that server's console.

## Storage

Bot records, links and audit metadata are stored in the generation 13
runtime session database. Each bot's Markdown entries use memory ID
`bot-<bot-id>` and the existing riela memory schema. Remote registrations
and their credentials use the Riela credential directory, which defaults to
`${XDG_STATE_HOME:-~/.local/state}/riela/credentials`.
