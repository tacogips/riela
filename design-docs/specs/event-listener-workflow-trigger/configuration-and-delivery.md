# Event Listener Workflow Trigger Design: Configuration, Persistence, and Delivery

## Configuration Model

### Source Config

```json
{
  "id": "slack-review",
  "kind": "chat-sdk",
  "provider": "slack",
  "adapter": {
    "tokenEnv": "SLACK_BOT_TOKEN",
    "signingSecretEnv": "SLACK_SIGNING_SECRET"
  }
}
```

```json
{
  "id": "nightly-maintenance",
  "kind": "cron",
  "schedule": "0 2 * * *",
  "timezone": "Asia/Tokyo"
}
```

```json
{
  "id": "incoming-docs",
  "kind": "s3-repository",
  "provider": "s3-compatible",
  "endpointUrlEnv": "DOC_REPOSITORY_S3_ENDPOINT",
  "region": "ap-northeast-1",
  "bucket": "team-docs",
  "rootPrefix": "incoming/",
  "eventReceiver": {
    "mode": "webhook-bridge",
    "signingSecretEnv": "DOC_REPOSITORY_EVENT_SECRET"
  },
  "objectAccess": {
    "mode": "metadata-only"
  },
  "filters": {
    "suffixes": [".md", ".json"]
  }
}
```

```json
{
  "id": "local-docs",
  "kind": "file-change",
  "directory": "./watched-docs",
  "changeTypes": ["create", "modify", "delete"],
  "recursive": false,
  "filters": {
    "suffixes": [".md", ".json"]
  }
}
```

```json
{
  "id": "team-matrix",
  "kind": "matrix",
  "provider": "matrix",
  "homeserverUrlEnv": "RIELA_MATRIX_HOMESERVER_URL",
  "accessTokenEnv": "RIELA_MATRIX_ACCESS_TOKEN",
  "userId": "@riela-bot:example.org",
  "rooms": [
    {
      "roomId": "!release-room:example.org",
      "alias": "#release:example.org"
    }
  ],
  "sync": {
    "pollTimeoutMs": 30000,
    "sinceTokenPath": "matrix/team-matrix/since.json"
  },
  "ignoreOwnMessages": true
}
```

### Binding Config

```json
{
  "id": "slack-review-to-release-workflow",
  "sourceId": "slack-review",
  "match": {
    "eventType": "chat.mention",
    "conversationId": "C0123456789"
  },
  "workflowName": "release-review",
  "inputMapping": {
    "mode": "template",
    "template": {
      "request": "{{event.input.text}}",
      "source": "slack",
      "channel": "{{event.conversation.id}}"
    },
    "mirrorToHumanInput": true
  },
  "execution": {
    "async": true,
    "dedupeWindowMs": 86400000,
    "maxConcurrentPerKey": 1,
    "concurrencyKey": "{{event.conversation.threadId}}"
  }
}
```

```json
{
  "id": "incoming-doc-to-review-workflow",
  "sourceId": "incoming-docs",
  "match": {
    "eventType": "repository.file.created",
    "pathPrefix": "plans/"
  },
  "workflowName": "document-review",
  "inputMapping": {
    "mode": "template",
    "template": {
      "request": "Review the new repository file.",
      "repository": "{{event.input.repository}}",
      "file": "{{event.input.file}}"
    },
    "mirrorToHumanInput": false
  },
  "execution": {
    "async": true,
    "dedupeWindowMs": 86400000,
    "maxConcurrentPerKey": 1,
    "concurrencyKey": "{{event.input.file.s3Key}}"
  }
}
```

```json
{
  "id": "matrix-release-chat-to-workflow",
  "sourceId": "team-matrix",
  "outputDestinations": ["release-matrix-chat"],
  "match": {
    "eventType": "chat.message",
    "conversationId": "!release-room:example.org"
  },
  "workflowName": "matrix-chat-reply",
  "inputMapping": {
    "mode": "event-input",
    "mirrorToHumanInput": true
  },
  "execution": {
    "async": true,
    "dedupeWindowMs": 86400000,
    "maxConcurrentPerKey": 1,
    "concurrencyKey": "{{event.sourceId}}:{{event.conversation.id}}:{{event.conversation.threadId}}"
  }
}
```

Supervised bindings extend the existing `execution` block with
`mode: "supervised"`. Omitted mode remains `"direct"`:

```json
{
  "id": "chat-controlled-review",
  "sourceId": "web-chat",
  "workflowName": "release-review",
  "inputMapping": {
    "mode": "event-input",
    "mirrorToHumanInput": true
  },
  "execution": {
    "mode": "supervised",
    "supervisorWorkflowName": "riela-default-workflow-supervisor",
    "maxRestartsOnFailure": 3,
    "autoImprove": false,
    "control": {
      "correlationKey": "{{event.sourceId}}:{{binding.id}}:{{event.conversation.id}}:{{event.conversation.threadId}}",
      "startOnFirstInput": true,
      "allowActions": ["start", "stop", "restart", "status", "input"]
    }
  }
}
```

In supervised mode, `workflowName` is still the target workflow. The event
listener maps each accepted event to a supervisor command and routes it through
the runtime supervisor control service (local library or remote GraphQL), which
owns supervised-run records and target lifecycle for the correlation key. Phase
1 implements that control plane directly over existing workflow execution APIs;
an authored `supervisorWorkflowName` workflow execution is not started yet, but
the name is recorded on supervised-run rows for forward-compatible Phase 2
routing. `supervisorWorkflowName` is the proposed event-layer field name;
implementation may translate it to existing `superviserWorkflowId` runtime
fields until naming is migrated deliberately.
Control-field templates may reference normalized `event.*`, `source.*`, and
`binding.*` values. `startOnFirstInput` lets chat/web-chat bindings treat the
first ordinary message in a conversation as a target workflow start instead of
requiring a separate `start` command.

## Runtime Persistence

Add an event ledger that records every accepted, skipped, duplicate, failed, and
dispatched event.

Recommended record:

```typescript
interface EventReceiptRecord {
  readonly receiptId: string;
  readonly sourceId: string;
  readonly bindingId?: string;
  readonly dedupeKey: string;
  readonly status:
    | "received"
    | "duplicate"
    | "skipped"
    | "mapped"
    | "accepted"
    | "dispatching"
    | "dispatched"
    | "failed";
  readonly workflowName?: string;
  readonly workflowExecutionId?: string;
  readonly rawRef?: EventArtifactRef;
  readonly normalizedRef?: EventArtifactRef;
  readonly inputRef?: EventArtifactRef;
  readonly error?: string;
  readonly receivedAt: string;
  readonly updatedAt: string;
}
```

Artifact layout:

```text
{RIELA_ARTIFACT_DIR}/events/{sourceId}/{yyyy-mm-dd}/{receiptId}/
  raw.json
  normalized.json
  workflow-input.json
  dispatch.json
  error.json
```

SQLite remains an index. Artifact files remain the durable evidence.

## Idempotency And Concurrency

Idempotency rules:

- dedupe before workflow execution
- write the event receipt before acknowledging external webhooks
- treat provider retries with the same `dedupeKey` as duplicates
- return success for duplicate webhook retries when the original event was
  accepted
- do not start a second workflow for the same binding and dedupe key inside the
  configured dedupe window

Concurrency rules:

- default concurrency key is the dedupe key
- chat bindings should usually use conversation/thread id as the concurrency key
- cron bindings should usually use source id plus scheduled time
- sequential-list bindings should use source id plus sequence run id, item id,
  and item index; the sequence controller, not only the generic per-key
  concurrency limit, is responsible for waiting on workflow completion before
  releasing the next item
- S3 repository bindings should usually use bucket plus object key, or bucket
  plus object key plus version id when parallel versions should run separately
- first iteration may reject or queue new events when `maxConcurrentPerKey` is
  exceeded; the policy must be explicit in config

Recommended policies:

- `reject-new`: persist skipped event and acknowledge provider
- `queue`: persist pending event and dispatch later
- `allow`: no per-key concurrency limit

Sticky manager-session reuse rules:

- sticky-session lookup must stay binding-local, even when multiple bindings
  target the same workflow and chat conversation
- the minimum sticky-session scope is
  `workflowId + sourceId + binding.id + conversation.id + conversation.threadId`
- sticky reuse may reopen a previously completed workflow session for the same
  binding conversation, because chat-shaped event bursts are modeled as one
  long-lived manager conversation across multiple dispatches
- failed or cancelled workflow sessions must not be reused by sticky dispatch
- while a sticky workflow session has pending user-action replies, new events for
  the same binding conversation must not start a parallel workflow; dispatch
  should be skipped (or queued by a later milestone) and the sticky pointer
  must remain unchanged
- a stored sticky record that does not match the current binding scope must be
  treated as absent rather than reused opportunistically
- sticky lookup should self-heal stale records that reference a missing
  workflow session or a session that is no longer reusable for the same
  binding conversation
- this preserves the event-layer contract that bindings remain distinct
  execution entrypoints with their own mapping and policy decisions

## Acknowledgement Semantics

Webhook providers expect fast acknowledgement. The listener should:

1. verify the request
2. normalize the event
3. persist the receipt and dedupe decision
4. enqueue or asynchronously dispatch workflow execution
5. acknowledge the provider

Workflow completion should not block the HTTP response unless a binding
explicitly opts into synchronous execution for a local-only source.

## Reply Semantics

Triggering a workflow and replying to an event are separate concerns.

The target direction in
`design-docs/specs/design-event-external-mailbox-binding.md` keeps that
separation, but moves the conceptual boundary outward: provider adapters bridge
to and from the runtime-owned external mailbox, while runtime or supervisor
logic decides whether to publish final output, progress, or control/status
messages.

First iteration:

- store reply target metadata in `runtimeVariables.event`
- let workflows produce final output as usual
- do not require automatic provider replies

Reply bridge:

- a runtime-owned reply dispatcher can post provider-neutral reply requests back
  to chat threads
- `riela/chat-reply-worker` is the workflow-visible built-in node add-on for
  creating such reply requests during a workflow run
- an optional `EventReplyPublisher` can still observe completed workflow runs
  and post configured summaries without requiring a reply node
- provider replies should use the same adapter registry but remain outside the
  workflow engine
- user-action nodes remain the correct mechanism for mid-run human decisions;
  event triggers are only the start-of-run ingestion path

Supporting design:
`design-docs/specs/design-node-addon-catalog-and-chat-reply-worker.md`.
