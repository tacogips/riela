# Event Listener Workflow Trigger Design: Provider Source Types

## Provider Source Types

### Cron

Cron is an internal event source, not a workflow node type. Its next occurrence
should be registered through the shared scheduled event manager described in
`design-docs/specs/design-scheduled-sleep-node-runtime.md`, rather than through
adapter-owned long-lived timers.

Source config:

- `kind: "cron"`
- schedule expression
- timezone
- optional jitter
- optional missed-run behavior
- optional lock key for future distributed scheduling

Normalized input should include:

- schedule id
- scheduled time
- actual fired time
- timezone
- missed run count when known

First iteration may use a single-process scheduler. Distributed locking should
be an explicit later milestone because the current runtime is local-first.

Scheduled cron behavior:

- source startup registers the next due occurrence in the scheduled event pool
- event registration, cancellation, or replacement re-arms the manager's next
  due timer
- events whose scheduled time has passed execute promptly
- after a cron event fires, the next occurrence is computed and registered
  through the same manager
- the cron adapter preserves existing config, binding, input mapping, dedupe,
  and event receipt behavior

### Sequential List

Sequential list is a local event source for operators who want to preconfigure
an ordered set of instruction prompts and have riela dispatch each prompt as
one workflow input only after the previous workflow execution has completed.
The source is served by `events serve` and uses the same adapter, binding, input
mapping, receipt, dedupe, replay, sticky-session, and supervised execution
contracts as other event sources.

The source does not add list semantics to workflow JSON. It turns each list
entry into a normalized event:

```text
Configured prompt list
  -> SequentialListEventSourceAdapter
  -> ExternalEventEnvelope(eventType = sequential-list.item.ready)
  -> EventBinding
  -> WorkflowTriggerRunner
  -> riela workflow run / library client / GraphQL executeWorkflow / supervisor control
  -> completion observer
  -> next list item
```

Source config:

- `kind: "sequential-list"`
- `entries`, a non-empty ordered array of prompt entries
- each entry has a unique `id` and a non-empty `prompt`
- optional entry `metadata`, limited to JSON-serializable operator context
- optional `startPolicy`, defaulting to `on-serve-start`
- optional `onItemFailure`, defaulting to `stop`; `continue` may be supported
  only when failures are recorded before the next dispatch

Recommended source shape:

```json
{
  "id": "nightly-instruction-list",
  "kind": "sequential-list",
  "entries": [
    {
      "id": "summarize-backlog",
      "prompt": "Summarize the current backlog and identify blockers."
    },
    {
      "id": "draft-plan",
      "prompt": "Draft the next implementation plan from the summary."
    }
  ]
}
```

Normalized event type:

- `sequential-list.item.ready`

Normalized input should include:

- sequence source id
- stable config revision id
- sequence run id
- zero-based item index and total item count
- item id
- prompt text
- item metadata when configured
- prior item receipt id and workflow execution id when available

Recommended runtime variable shape after a binding maps the event:

```json
{
  "workflowInput": {
    "instruction": "Summarize the current backlog and identify blockers.",
    "sequence": {
      "sourceId": "nightly-instruction-list",
      "runId": "seq_20260522_001",
      "itemId": "summarize-backlog",
      "index": 0,
      "total": 2
    }
  }
}
```

State and completion rules:

- The event runtime owns a durable sequence state record under the event data
  root. It stores source id, config revision id, sequence run id, current item
  index, item statuses, active receipt id, active workflow execution id or
  supervised run id, timestamps, and last error.
- A served source resumes the current sequence for the same source/config
  revision. Completed items are not dispatched again on listener restart.
- The next item is eligible only after the previous item reaches a terminal
  workflow state: completed, failed, or cancelled. Paused, running, pending
  user-action, and unknown states are not complete.
- With `onItemFailure: "stop"`, failed or cancelled item execution marks the
  sequence failed and leaves later items pending. With `continue`, the failure
  is recorded and the next item may dispatch after terminal failure is observed.
- If the runtime cannot observe completion for the selected dispatch mode, it
  must fail the active item and stop the sequence rather than start the next
  item concurrently.
- Direct local execution can observe completion by awaiting or polling the
  workflow session. Endpoint-backed or supervisor-backed dispatch must poll the
  GraphQL/session or supervised-run status surface until terminal state.
- Sticky session reuse remains binding-local. If a binding continues an
  event-processing node session, the sequence still waits for that continued
  workflow execution/session to become terminal before dispatching the next
  item.

Receipt, dedupe, and replay rules:

- Each item creates one normal event receipt. The normalized event, workflow
  input artifact, and dispatch artifact include sequence source id, run id,
  item id, item index, total count, and config revision id.
- Dedupe keys include source id, config revision id, sequence run id, item id,
  item index, and binding id. Changing the authored entry id or prompt changes
  the config revision and starts a distinct sequence run.
- `events list` should expose sequence metadata so operators can inspect which
  item is active, completed, skipped, failed, or pending.
- `events replay <receipt-id>` replays one persisted item receipt. It must not
  reset the sequence cursor or enqueue later items unless an explicit future
  sequence reset/resume command is added.
- Read-only mode validates and records receipts/state transitions that do not
  dispatch workflow execution; it must not advance the durable cursor past an
  item that was not actually dispatched.

### S3 Repository File Creation

S3 repository file creation is an object-storage event source for S3-compatible
stores. The event runtime does not poll buckets. Instead, an object-store event
receiver accepts object-created notifications from the store's native event
mechanism, normalizes them, and dispatches matching bindings to workflow
execution.

The receiver is an abstraction layer between provider delivery and riela:

```text
S3-compatible store event notification
  -> S3RepositoryEventReceiver
  -> ExternalEventEnvelope(eventType = repository.file.created)
  -> EventBinding
  -> WorkflowTriggerRunner
  -> riela workflow run / library client / GraphQL executeWorkflow
```

Source config:

- `kind: "s3-repository"`
- provider, such as `aws-s3`, `minio`, or another S3-compatible store adapter
- endpoint URL for S3-compatible stores when not using AWS regional endpoints
- region when required by the provider
- bucket name
- optional repository id
- optional root prefix used to interpret object keys as repository paths
- optional key suffix filters such as `.md`, `.json`, or `.csv`
- event receiver configuration, such as EventBridge, SQS, SNS-to-webhook bridge,
  bucket notification webhook bridge, or provider-specific event stream
- credential environment variable names or ambient provider SDK credential chain
  selection when the receiver needs to verify or fetch object metadata
- object access policy, defaulting to metadata-only

Normalized event type:

- `repository.file.created`

Normalized input should include:

- provider, region, bucket, object key, and decoded repository-relative path
- event receiver id and delivery mechanism
- version id when available
- object size, eTag, sequencer, and content type when available
- creation event name or delivery reason, such as put, post, copy, or
  multipart completion
- user/request metadata when available from the event payload
- data-root file ref only when the binding explicitly downloads the object

Recommended runtime variable shape:

```json
{
  "workflowInput": {
    "repository": {
      "provider": "aws-s3",
      "bucket": "team-docs",
      "rootPrefix": "incoming/"
    },
    "file": {
      "path": "plans/release.md",
      "s3Key": "incoming/plans/release.md",
      "versionId": "3Lg...",
      "etag": "9b2cf535f27731c974343645a3985328",
      "size": 12842,
      "contentType": "text/markdown"
    }
  }
}
```

Rules:

- polling is not part of the S3 repository source design
- object keys are data, not filesystem paths; normalize and validate them before
  deriving repository-relative paths
- use bucket and prefix allow lists so one source cannot trigger workflows for
  unrelated objects
- default behavior passes metadata only; downloading object contents requires an
  explicit `objectAccess.mode`
- downloaded objects must be copied under the riela data root and exposed to
  workflows through data-root-relative file refs
- dedupe should prefer `(sourceId, bucket, key, versionId)` when versioning is
  available, otherwise `(sourceId, bucket, key, sequencer)` or a provider event
  id
- object-created delivery should be treated as at-least-once; duplicate
  notifications must not start duplicate workflows for the same binding

### Local File Change

Local file change is a filesystem event source for workflows that should react
when files in an operator-configured directory are created, modified, or
deleted. The source is local to the `events serve` process and should use the
same adapter, binding, input mapping, event receipt, dedupe, and workflow
dispatch contracts as webhook, cron, Matrix, Chat SDK, and S3 sources.

The adapter watches a configured directory and normalizes eligible filesystem
notifications into `ExternalEventEnvelope` records:

```text
Local filesystem watcher
  -> FileChangeEventSourceAdapter
  -> ExternalEventEnvelope(eventType = file.change.created|modified|deleted)
  -> EventBinding
  -> WorkflowTriggerRunner
  -> riela workflow run / library client / GraphQL executeWorkflow
```

Source config:

- `kind: "file-change"`
- `directory`, resolved from the event source config file location when
  relative, or accepted as an absolute path for local operator configuration
- `changeTypes`, a non-empty subset of `create`, `modify`, and `delete`
- optional `recursive`, defaulting to false
- optional `filters.suffixes` for simple extension or filename suffix
  filtering; entries must not contain path separators
- optional `stabilityWindowMs`, defaulting to a small runtime constant, to
  coalesce noisy write bursts before dispatching create or modify events. The
  supported range is `0` through `60000` milliseconds.

Normalized event types:

- `file.change.created`
- `file.change.modified`
- `file.change.deleted`

Normalized input should include:

- change type as `create`, `modify`, or `delete`
- source id and provider `local-fs`
- watched directory as an operator-facing configured path label
- normalized file path relative to the watched directory
- file name and extension when available
- current file metadata for create and modify events when available, including
  size and mtime
- deletion metadata only when known before the delete notification; missing
  metadata must not fail the event

Recommended runtime variable shape:

```json
{
  "workflowInput": {
    "change": {
      "type": "modify"
    },
    "file": {
      "path": "plans/release.md",
      "name": "release.md",
      "extension": ".md",
      "size": 12842,
      "mtime": "2026-05-19T00:00:00.000Z"
    },
    "watch": {
      "sourceId": "local-docs",
      "directory": "./watched-docs"
    }
  }
}
```

Rules:

- file contents are not read or copied by default; the first implementation
  passes metadata and a safe relative path only
- every emitted relative path must be non-empty, use forward slashes, and reject
  absolute paths, backslashes, `.` segments, and `..` segments
- `changeTypes` controls dispatch after normalization, so disabled change types
  do not create event receipts or workflow executions
- default `recursive: false` keeps startup behavior portable; recursive watch
  support may be added behind the explicit config flag only where the runtime
  can test it deterministically
- startup does not emit events for files that already exist; only observed
  changes after listener start are dispatched
- create and modify notifications may be duplicated by host filesystem
  watchers; the adapter should coalesce same-source, same-path, same-change
  notifications within `stabilityWindowMs`
- delete notifications may lack file metadata because the path may already be
  gone; this is expected and should be represented by absent metadata
- deterministic tests should use an injectable watcher abstraction or fixture
  event path rather than relying only on host-specific filesystem timing
- event receipt and dedupe keys should include source id, relative path, change
  type, and a stable event time or watcher sequence so replay stays auditable

### Chat SDK

Chat providers should initially be integrated through a Chat SDK adapter where
the provider is supported. Current Chat SDK documentation describes a unified
TypeScript API and adapter catalog for platforms including Slack, Teams, Google
Chat, Discord, Telegram, GitHub, Linear, WhatsApp, Messenger, and Web.

Riela should treat Chat SDK as one adapter family:

- `kind: "chat-sdk"`
- provider selected in source config from a closed allow-list
- normalized event types such as `chat.message`, `chat.mention`,
  `chat.command`, `chat.action`, and `chat.modal-submit`
- response target metadata for external-output chat replies
- generic webhook/send endpoint mode as the preferred first implementation

Source config should include only logical names and environment variable names,
not secret values. See
`design-docs/specs/design-chat-sdk-event-sources.md` for the full provider
matrix, validation rules, and direct dependency policy.

### Element / Matrix

Element is treated as a Matrix chat client, so the event source integrates with
Matrix protocol surfaces rather than Element-specific UI behavior. The source
kind is:

- `kind: "matrix"`
- `provider: "matrix"` by default
- receive path: Matrix Client-Server `/sync` long polling for configured rooms
- reply path: Matrix Client-Server `send` API for `m.room.message`
- normalized event type: `chat.message`

The first implementation slice should support plain Matrix room messages only:

- include `m.room.message` events with text-like `msgtype` values such as
  `m.text`, `m.notice`, and `m.emote`
- ignore membership events, reactions, redactions, edits, encrypted events, and
  state events. Text-compatible Matrix attachment messages are supported only
  when the source opts into bounded attachment text download; see
  `design-docs/specs/design-matrix-attachment-text.md`.
- filter messages sent by the configured bot user by default so reply dispatch
  does not trigger a workflow loop
- map the Matrix room id to `conversation.id`
- map Matrix thread root or reply target metadata to `conversation.threadId`
  when available
- prefer the Matrix `event_id` as `eventId`
- use `${sourceId}:${roomId}:${event_id}` as the dedupe key

Normalized input should include:

- `text` from `content.body`
- `html` from `content.formatted_body` when `format` is
  `org.matrix.custom.html`
- `roomId`
- `eventId`
- `sender`
- `msgtype`
- optional `attachmentText`
- optional `attachments`
- optional `replyToEventId`
- optional `threadRootEventId`

If `formatted_body` is present without `format: "org.matrix.custom.html"`, the
adapter should ignore the formatted body and keep only the plain `text` value.
This prevents unknown Matrix formatting modes from being treated as trusted
HTML.

Reply target metadata should be stored in `runtimeVariables.event` so the
existing chat reply worker and reply dispatcher can send Matrix replies without
workflow code learning Matrix API details. `dispatchChatReply` must construct a
Matrix `m.room.message` body and send it to:

```text
/_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}
```

`txnId` must be derived from the provider-neutral reply idempotency key so retry
attempts do not duplicate provider messages. If the reply target includes an
event id, the Matrix message should include `m.relates_to.m.in_reply_to`. If the
target includes a thread root, the message should include Matrix thread
relation metadata and still remain a plain text reply when the server does not
support richer thread display.

Configuration should reference credentials and homeserver values through
environment variable names. Access tokens, sync tokens, request authorization
headers, and provider response bodies containing sensitive data must not be
written to authored config, examples, reply dispatch records, or logs.

Matrix sync state is runtime state, not authored workflow data. If
`sync.sinceTokenPath` is configured, it must be a safe relative path resolved
under the event runtime state or artifact root for the source, never an absolute
path or a path that escapes with `..`. Sync failures should be surfaced through
operator diagnostics with source id, HTTP status when available, and normalized
error class only; they must not log authorization headers, access tokens, full
request URLs with sensitive query data, or raw provider error bodies.
Non-abort `/sync` failures must not disappear into silent retry loops: each
failed poll attempt should emit a sanitized diagnostic before bounded retry
logic continues.

#### Checked-In Matrix Sample And Local Synapse Verification

The Matrix example should be a runnable event-source sample, not only a mocked
fixture. Keep the authored event config under
`examples/event-sources/.riela-events/` so it remains part of the shared
event-source example root, keep the workflow bundle under
`examples/matrix-chat-reply/`, and put live Matrix verification support under
`examples/matrix-chat-reply/local-synapse/`.

Required checked-in assets:

- `examples/event-sources/.riela-events/sources/team-matrix.json` for the
  Matrix source config, with homeserver URL and access token referenced through
  environment variable names.
- `examples/event-sources/.riela-events/bindings/matrix-release-chat-to-workflow.json`
  for receive-to-workflow mapping. This binding must dispatch
  `workflowName: "matrix-chat-reply"` so the checked-in Matrix sample, event
  config, and local Synapse verification all exercise the same workflow.
- `examples/event-sources/.riela-events/destinations/release-matrix-chat.json`
  for explicit Matrix reply routing.
- `examples/event-sources/payloads/matrix-room-message.json` for deterministic
  no-server normalization checks.
- `examples/matrix-chat-reply/workflow.json`,
  `examples/matrix-chat-reply/README.md`, and
  `examples/matrix-chat-reply/EXPECTED_RESULTS.md` for the sample workflow and
  operator-facing expected behavior.
- `examples/matrix-chat-reply/local-synapse/compose.yaml` plus local setup and
  verification scripts for live Synapse receive/send verification.

The Docker Compose environment should start a localhost-only Synapse homeserver
with deterministic test configuration. The setup script owns local runtime
state: it may create a generated homeserver config, register the bot and sender
users, create or join a test room, and write transient token/room data under an
ignored runtime directory. Auth tokens and generated homeserver state must not
be committed.

The live verification script should prove the complete path:

```text
sender user posts Matrix room message
  -> team-matrix /sync listener receives m.room.message
  -> matrix-release-chat-to-workflow dispatches matrix-chat-reply
  -> riela/chat-reply-worker emits a provider-neutral chat reply
  -> release-matrix-chat sends the Matrix reply to the configured room
  -> verification observes the reply through the local Matrix server
```

Verification should be deterministic enough for local development: wait for
Synapse readiness, fail fast when Docker Compose is unavailable, use bounded
polling for `/sync` and room-message observation, and print exact cleanup
commands. The sample may remain local-only and should not require a public
Matrix homeserver, Element UI, or committed credentials.

Recent-change review closure requires these design and rollout invariants:

- the `matrix-release-chat-to-workflow` binding, sample documentation, and
  sample expected-results file all name `matrix-chat-reply`
- Matrix `/sync` diagnostics report only source id, HTTP status when available,
  and normalized error class
- Matrix diagnostics and tests prove access tokens, authorization headers, full
  sensitive URLs, and raw provider bodies are not emitted
- implementation-plan indexes mark `matrix-event-source` and
  `matrix-send-receive-synapse-sample` as completed, with paths under
  `impl-plans/completed/`
- verification preserves the local Synapse receive/send path via
  `./examples/matrix-chat-reply/local-synapse/run-local-matrix-sample.sh`

### Chat SDK Providers

Chat SDK-backed sources are designed in detail in
`design-docs/specs/design-chat-sdk-event-sources.md`. The shared source kind is
`chat-sdk`, with a closed provider allow-list covering Slack, Teams, Google
Chat, Discord, Telegram, GitHub, Linear, WhatsApp, Messenger, and Web.

The first implementation should prefer a secure generic Chat SDK deployment
boundary with webhook receive and send endpoint configuration. Direct
`@chat-adapter/*` package integration remains optional until dependency
stability, provider verification, and credential surface area are reviewed.

Minimum first-iteration event support:

- message or mention event
- slash command where the platform supports it
- action/button callback where available
- channel/conversation id
- actor id and display name when available
- text plus structured fields
- file attachments as data-root file refs when downloaded

The `chat-event-attachment-judgement` example extends this surface with
deterministic image and PDF attachment descriptors. The event trigger contract
still passes attachments through `event.input.attachments[]`; tests and example
fixtures may provide bounded `textContent`, `imageDescription`, or safe
`contentRef` values so workflows can classify attachment contents without live
provider downloads.

Provider-specific capabilities should stay in adapter capability metadata, not
in workflow bindings. For example, Slack scheduled messages or native streaming
support should not change the event trigger contract.

#### Shared Chat Source Review Invariants

The webhook-shaped mock chat source, chat reply webhook fixture, Matrix source,
and Chat SDK source should remain reviewable as one event-source family even
though each adapter owns different provider details.

Cross-source behavior:

- all four surfaces normalize chat input through `eventType: "chat.message"`
  unless a provider capability explicitly declares a narrower event type
- bindings should match provider-neutral fields such as event type,
  conversation id, thread id, actor, and input text rather than raw provider
  payload fields
- reply-capable examples should declare explicit `kind: "chat"` destinations
  so fallback-to-source reply routing is compatibility behavior, not the main
  documented path
- local examples must support deterministic `events emit` fixture runs without
  live webhook, Matrix, Chat SDK, GraphQL, or agent services
- live Matrix and Chat SDK flows are optional operator verification layers on
  top of the same checked-in source, binding, destination, and payload files

Review closure for changes in this family requires validating the shared
event-source root and the two chat reply workflows, then running the focused
adapter and reply-dispatch tests:

```bash
bun run src/main.ts events validate --workflow-definition-dir ./examples --event-root ./examples/event-sources/.riela-events
bun run src/main.ts workflow validate chat-reply-webhook --workflow-definition-dir ./examples
bun run src/main.ts workflow validate matrix-chat-reply --workflow-definition-dir ./examples
bun test src/events/adapters/webhook.test.ts src/events/adapters/matrix.test.ts src/events/adapters/chat-sdk.test.ts src/events/chat-reply-example.test.ts src/events/matrix-chat-reply-example.test.ts src/events/reply-dispatcher.test.ts
bun run typecheck
```

### Signal

Signal should be modeled as a separate provider adapter unless the chosen Chat
SDK version gains a maintained Signal adapter. The event runtime should not
special-case Signal in core code.

Recommended approach:

- `kind: "signal"`
- adapter owns the selected bridge/client implementation
- normalize Signal messages to the same `chat.message` event type
- document operational requirements separately because Signal delivery often
  depends on a bridge process or device-linked account

### Vercel Chat SDK / AI Elements UI

There are two distinct concerns:

- Chat SDK is useful for shipping the same bot logic across chat platforms.
- AI Elements are React UI primitives for chat interfaces built with the Vercel
  AI SDK.

For riela, the event-trigger layer should expose a provider-neutral HTTP/SDK
entrypoint that a web chat UI can call. A UI built with AI Elements can submit a
message as a `chat.message` event, then display workflow status and final output
through existing GraphQL session queries or future event reply APIs.

The UI should not be treated as a workflow engine dependency. It is another
source adapter:

- `kind: "web-chat"`
- transport: HTTP route or GraphQL mutation
- normalized event type: `chat.message`
- optional conversation id from the browser session
- optional attachments stored under the data-root file area
