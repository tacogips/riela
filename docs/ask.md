# Ask Riela

Ask Riela is a chat that answers questions about this riela server from its
runtime records: runs, steps, logs, bots, routines, workflows, the model
catalog and remotes. The same chat creates and edits workflows. It is
available on the CLI (`riela ask`), GraphQL and the web console.

## Ask a question

```sh
riela ask "which runs failed today?"
riela ask --session <sessionId> "what is the state of this run?"
riela ask --bot <botId> "why is this bot waiting?"
riela ask --workflow <workflowId> "what does this workflow do?"
```

`--session`, `--bot` and `--workflow` set the context so "this run" resolves
without naming it; pass at most one. The server resolves the reference, and an
unknown id is an error.

Text output streams the answer, prints one line per tool call, then a
`Records:` list of the records the answer used, a `Proposed:` list of actions
waiting for your decision, and the conversation id. `--output json` prints the
final conversation payload once. A failed turn exits non-zero with the error
on stderr and never produces an answer.

Continue or manage a conversation:

```sh
riela ask --conversation <conversationId> "and the step before that?"
riela ask list
riela ask show <conversationId> [--follow]
riela ask cancel <conversationId>
riela ask remove <conversationId>
```

A message that equals a verb (`list`, `show`, `cancel`, `confirm`, `dismiss`,
`remove`) is passed after `--`. Without a server the CLI runs the turn in its
own process against the local store; `--session-store`, `--scope` and
`--working-dir` select it as for other commands.

## Vendor and model

The default vendor and model come from the assistant settings (web console
**Settings**). Override them when starting a conversation:

```sh
riela ask --provider <instanceId> --model <modelId> --effort <value> "..."
```

Values come from the model catalog (`riela provider list`, `riela model
list`). An unlisted model still runs and reports a `model_unknown` warning (its
own stderr line for text output, `warnings` for JSON). The selection is fixed
for the conversation. `automatic` keeps its resolution order.

Ask does not run on the `official/cursor-sdk` backend; a turn that resolves to
it is refused with `ask_provider_unsupported` before anything is written.

## Read-only, with confirmed actions

The chat model has a fixed set of read tools. It cannot change runtime state,
write files, run commands or search the web. Records and logs are treated as
information, never as instructions, and secrets are redacted before they reach
the model.

When an operation would help, the model proposes a typed action and you
decide:

| Action | Effect on confirm |
| --- | --- |
| `stopSession` | stops a run |
| `rerunSession` | reruns a run from a step |
| `answerBotRequest` | answers a bot's permission request |
| `setBotPaused` | pauses or resumes a bot |
| `applyWorkflow` | registers or updates a workflow, or loads an editor draft |

```sh
riela ask confirm <conversationId> <actionId>
riela ask dismiss <conversationId> <actionId>
```

Confirm runs the existing mutation with your authority. The target is checked
again at confirm; an invalid target fails with `action_target_invalid` and
changes nothing. An action can be decided once and expires after 24 hours. The
action record is the audit record.

## Create and edit workflows

Ask for a workflow in the same chat ("create a workflow that ..."). The model
proposes a complete definition, the server validates it, and a valid one
becomes an `applyWorkflow` action. Nothing is applied until you confirm.

- From the CLI or the global panel, confirm registers a new mutable workflow,
  or updates the mutable workflow the proposal was based on. An existing id is
  never overwritten, and an update fails with the registry's conflict error if
  the workflow changed after the proposal. Immutable workflows cannot be
  edited this way.
- From the workflow editor (**Ask** in the editor toolbar), the current draft
  is sent with each message. Confirm loads the proposed definition into the
  editor draft and saves nothing; publish with **Save** as usual. The graph
  changes on confirm, not while the model works.

Protected values that the editor hides (retain handles) are preserved through
a proposal. A `promptTemplate` longer than 2048 characters is retained as a
handle, so the model cannot read or edit it through Ask.

The former workflow-editor generation chat and its
`/api/v1/workflow-editor/generations` routes are removed.

## Web console

The **Ask** panel is a collapsible side panel available from every view. It
shows a context chip for the current run, bot or workflow, the vendor and
model picker, the streamed answer with tool calls, links to cited records, and
proposed-action cards with **Confirm** and **Dismiss**. **Ask** buttons in the
run view, the Bots detail view and the workflow editor open it with that item
as context.

## Paired remotes

With a remote selected (`--remote <name>`, the active remote, or the remote of
the current web view) the chat runs on that riela server: its records, its
model credentials and its confirmed actions. The origin is shown. Chatting and
deciding actions need the `operate` pairing scope; reading conversations needs
`read`. An unreachable remote is an error, never an answer.

`riela ask --no-follow` returns as soon as the turn is started. It is accepted
only when the turn runs on a paired remote; for a local turn it is a usage
error, because the CLI process owns the turn.

## Limits

Per conversation: 50 turns, 400 tool calls and 200 messages. Per turn: 24 tool
calls and a 10 minute deadline (`ask_timeout`). Tool results are capped at
16 KiB each and marked when truncated. One turn runs at a time per
conversation (`ask_turn_running`). A turn whose host process died is settled as
`ask_interrupted`.

## Tool transport

For codex and claude backends the tools are offered through a local stdio MCP
server that the vendor CLI starts (`riela ask tool-server`; not for direct
use). Other backends use a host-run tool loop. Set
`RIELA_ASK_TOOL_TRANSPORT=rounds` to force the host loop for every backend.

## GraphQL

`Mutation.startAsk`, `sendAskMessage`, `cancelAsk`, `confirmAskAction`,
`dismissAskAction`, `removeAskConversation`; `Query.askConversations`,
`askConversation`, `askActivity` (long-poll, same event model as bot
activity). Every field takes an optional `remote`. There are no REST routes.

## Try it without a model

The [ask-run-status example](../examples/ask-run-status/EXPECTED_RESULTS.md)
runs a mock workflow and asks about it with a scripted backend
(`RIELA_ASK_SCRIPTED_BACKEND`), with no model credentials.

Design: [design-ask-riela-chat](../design-docs/specs/design-ask-riela-chat.md).
