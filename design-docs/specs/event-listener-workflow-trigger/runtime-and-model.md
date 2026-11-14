# Event Listener Workflow Trigger Design: Runtime and Event Model

This document defines an additive architecture for starting riela workflow
runs from external events.

## Overview

External events should enter riela through a trigger layer that is separate
from workflow execution. Event-specific code normalizes provider payloads into a
canonical event envelope, applies a binding-specific input mapping, records
idempotency state, and invokes the existing workflow execution boundary.

The workflow engine remains responsible only for workflow execution. It should
not learn Slack, Discord, cron, Telegram, Signal, or UI-specific semantics.

This document describes the current direct-trigger architecture and remains the
implementation baseline. The target architectural direction is refined further
in `design-docs/specs/design-event-external-mailbox-binding.md`: event sources
should conceptually bind to the runtime-owned external mailbox boundary, and
direct workflow starts should be treated as one consumer of external mailbox
input rather than as the fundamental event abstraction.

Recommended placement:

- `src/events/` owns event source configuration, normalization, dedupe, and
  trigger dispatch.
- `src/workflow/` continues to own workflow definitions, sessions, queues, and
  artifacts.
- `src/server/` may host event HTTP routes, but those routes should delegate to
  `src/events/` rather than embedding provider logic in the control plane.
- provider adapters live behind a small registry so adding a source does not
  require editing the workflow engine.

## Goals

- run workflows from external events by converting event input into workflow
  runtime input
- keep workflow JSON and the core engine loosely coupled from provider SDKs
- make new event sources easy to add through a stable adapter interface
- support cron and chat-oriented sources first
- support repository/object-storage file-created sources such as S3 object
  creation
- support local filesystem directory change sources for created, modified, and
  deleted files
- support ordered prompt-list sources that dispatch configured instructions one
  workflow execution at a time
- support webhook-style and provider event-notification sources
- preserve durable audit records for received events, mapping results, dedupe,
  and workflow execution ids
- acknowledge webhook events quickly and execute workflows asynchronously by
  default
- keep credentials, channel ids, signing secrets, and provider-specific runtime
  settings out of authored workflow bundles

## Non-Goals

- turning riela into a full chat bot framework
- adding provider-specific fields to `workflow.json`
- making a running workflow depend on a provider SDK after it starts
- requiring chat UI output streaming before event-to-workflow triggering works
- replacing the existing GraphQL and library workflow execution APIs
- solving distributed, multi-process scheduling in the first iteration
- downloading or parsing full repository file contents unless a source binding
  explicitly opts into that behavior
- shipping a cross-machine distributed filesystem watcher or synchronization
  service
- introducing workflow-engine branches or loops to model event-source list
  sequencing
- starting concurrent workflow executions for one ordered prompt list

## Relationship To Existing Runtime

The current public execution boundary already accepts arbitrary
`runtimeVariables` through:

- `runWorkflow()` in `src/workflow/engine.ts`
- `executeWorkflow()` and `createWorkflowExecutionClient()` in `src/lib.ts`
- GraphQL `executeWorkflow(input: ExecuteWorkflowInput!)`

The event trigger layer should call that boundary instead of constructing
sessions directly.

Canonical event-triggered runtime variables:

```typescript
interface EventTriggeredRuntimeVariables {
  readonly workflowInput: Readonly<Record<string, unknown>>;
  readonly event: ExternalEventMetadata;
  readonly humanInput?: Readonly<Record<string, unknown>>;
}
```

Rules:

- `workflowInput` is the canonical business input produced by the event binding.
- `event` contains source metadata needed for audit, routing, and replies.
- `humanInput` is a first-iteration compatibility mirror when the workflow
  expects the existing bootstrap mailbox behavior.
- provider raw payloads are not copied into runtime variables by default; they
  are stored as event artifacts and referenced by id/path.

This keeps event support compatible with existing workflows while establishing a
clearer long-term name for non-human triggers such as cron.

## Event Runtime Boundaries

### Components

```text
Provider SDK / Cron Timer / HTTP Webhook
  -> EventSourceAdapter
  -> ExternalEventEnvelope
  -> EventBindingMatcher
  -> InputMapper
  -> EventLedger
  -> WorkflowTriggerRunner or EventSupervisorRouter
  -> direct riela workflow execution or workflow supervisor control
```

### `EventSourceAdapter`

Provider-specific boundary.

Responsibilities:

- verify incoming webhook signatures when applicable
- subscribe to or receive provider events when webhook delivery is unavailable
- normalize provider payloads into `ExternalEventEnvelope`
- expose source lifecycle methods for `events serve`
- avoid importing `src/workflow/engine.ts`

Minimal interface:

```typescript
interface EventSourceAdapter {
  readonly kind: string;
  start(input: EventSourceStartInput): Promise<EventSourceHandle>;
  normalize(input: RawExternalEvent): Promise<ExternalEventEnvelope>;
}
```

Adapter packages may depend on provider SDKs. The central event runtime should
depend only on adapter interfaces.

### `ExternalEventEnvelope`

Canonical event shape passed to matching and input mapping.

```typescript
interface ExternalEventEnvelope {
  readonly sourceId: string;
  readonly eventId: string;
  readonly provider: string;
  readonly eventType: string;
  readonly occurredAt?: string;
  readonly receivedAt: string;
  readonly dedupeKey: string;
  readonly actor?: EventActor;
  readonly conversation?: EventConversation;
  readonly input: Readonly<Record<string, unknown>>;
  readonly rawRef?: EventArtifactRef;
}
```

Rules:

- `eventId` is the provider event id when available.
- `dedupeKey` is stable across webhook retries. If the provider lacks an id, it
  is a hash of source id, event type, occurrence time bucket, actor, and input.
- `input` is provider-neutral business data, such as text, command name,
  fields, selected button value, uploaded file refs, or cron schedule context.
- `rawRef` points to an artifact, not to a host absolute path.

### `EventBinding`

A binding connects normalized events to workflow execution.

Configuration should live outside workflow bundles. Recommended default layout:

```text
.riela-events/
  sources/
    slack-review.json
    nightly-cron.json
  bindings/
    slack-review-to-workflow.json
    nightly-cron-to-workflow.json
```

This avoids reserving names inside the workflow root, where every child
directory is currently a potential workflow bundle.

Minimal binding shape:

```typescript
interface EventBinding {
  readonly id: string;
  readonly enabled?: boolean;
  readonly sourceId: string;
  readonly match?: EventMatchRule;
  readonly workflowName: string;
  readonly inputMapping: EventInputMapping;
  readonly execution?: EventWorkflowExecutionPolicy;
}
```

Rules:

- bindings reference workflows by CLI workflow name, not by filesystem path
- omitted `enabled` means enabled
- omitted `execution.async` means true
- one event may match multiple bindings
- one direct binding starts at most one workflow run per accepted event
- one supervised binding dispatches at most one supervisor command per accepted
  event; that command may start, stop, restart, inspect, or deliver input to a
  supervised run

### `EventInputMapping`

The mapper converts a provider-neutral event envelope into workflow input.

First-iteration recommendation:

- support static JSON templates with simple variable interpolation from
  `event.*` and `source.*`
- support `mode: "event-input"` to pass `ExternalEventEnvelope.input` through
  unchanged
- do not support arbitrary JavaScript expressions in config

Example:

```json
{
  "mode": "template",
  "template": {
    "request": "{{event.input.text}}",
    "channel": "{{event.conversation.id}}",
    "user": "{{event.actor.displayName}}"
  },
  "mirrorToHumanInput": true
}
```

`mirrorToHumanInput` defaults to true for chat sources and false for cron and
repository-file sources. Operators can override it explicitly.

### `WorkflowTriggerRunner`

Execution boundary adapter.

Responsibilities:

- convert mapped input into `runtimeVariables`
- choose command, local library, or remote GraphQL execution
- set `async: true` by default
- persist workflow execution id against the event ledger record in direct mode
- persist supervisor command/run ids and target workflow execution ids against
  the event ledger record in supervised mode
- avoid provider-specific imports

Recommended in-process or remote call path:

```typescript
createWorkflowExecutionClient({
  workflowName: binding.workflowName,
  endpoint: configuredEndpoint,
  workflowRoot,
  artifactRoot,
  sessionStoreRoot,
}).execute({
  input: runtimeVariables,
  async: binding.execution?.async ?? true,
});
```

When `endpoint` is configured, the event process can run as a lightweight
listener that does not load or execute workflows locally.

For bindings that need long-lived lifecycle control, the trigger runner should
delegate to the supervised event control path instead of starting the target
workflow directly. In that mode, the listener maps the event into a structured
supervisor command and sends it to the workflow supervisor, which owns target
workflow start, stop, restart, status, and failure restart policy. See
`design-docs/specs/design-event-supervisor-control.md`.

Command dispatch is also a valid boundary for listener processes that should
only depend on the installed CLI:

```bash
riela workflow run document-review --variables @mapped-event-input.json
```

The command dispatcher must write the mapped runtime variables to a data-root
artifact first, then pass that file path to `riela workflow run`. Provider
payloads must not be shell-interpolated into command arguments.
