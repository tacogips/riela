---
name: riela-workflow-reference
description: Use when integrating with Riela workflows from Swift, or when driving the Riela control plane over GraphQL. Covers the RielaLibrary facade (executeWorkflow, resumeSession, rerunSession, inspectWorkflow, sessionView, executeGraphQLDocument), the control-plane schema, and when to call the library instead of an endpoint.
---

# Riela integration reference

Riela is a Swift package. There is no TypeScript runtime: integrate either by
linking `RielaCLI` and calling the `RielaLibrary` facade, or by sending GraphQL
documents to a `riela serve` endpoint.

Every name in this document is checked against the source by
`SurfaceParityLibraryTests` and `SurfaceParitySkillTests`. If a name here does
not exist, the test suite fails — treat what follows as fact, not as a
best-effort listing.

## The library facade

`RielaLibrary` is the whole supported embedding surface. Each entry point
delegates to the same command the CLI runs, so results are identical to the
shell.

```swift
import RielaCLI

let riela = RielaLibrary(workingDirectory: "/path/to/project")

// Run a workflow to completion (same path as `riela workflow run`).
let run = await riela.executeWorkflow("fable-and-improve-opus", variables: #"{"goal":"ship"}"#)

// Inspect a bundle without running it (same path as `riela workflow inspect`).
let inspected = await riela.inspectWorkflow("fable-and-improve-opus", structure: true)

// Read a persisted session (same path as `riela session status`).
let view = await riela.sessionView("session-123")

// Continue a paused session (same path as `riela session resume`).
let resumed = await riela.resumeSession("session-123")

// Re-enter a session at a step (same path as `riela session rerun`).
let rerun = await riela.rerunSession("session-123", fromStepId: "review")

// Execute a control-plane document in this process.
let response = await riela.executeGraphQLDocument(
  "query Workflows { workflows { workflows { workflowId } errors { code message } } }"
)
```

`executeWorkflow`, `resumeSession`, `rerunSession`, `inspectWorkflow` and
`sessionView` return `CLICommandResult`: `exitCode`, `stdout` (JSON for these
entry points) and `stderr`. `executeGraphQLDocument` returns a
`GraphQLDocumentExecutionResponse` with `handled`, `status` and a `body`
containing `data` and, on failure, `errors`.

There is no other public library entry point. In particular there is no
`createWorkflowExecutionClient`, no `resumeWorkflow`, no `rerunWorkflow`, no
`getRuntimeSessionView`, no `callWorkflowStep` and no `createGraphqlSchema`:
those were names of a deleted TypeScript runtime.

## Local library call or remote endpoint?

Call the library when your process may run the workflow itself: it needs the
working directory, the workflow bundle and the session store on local disk.

Send GraphQL to a `riela serve` endpoint when the runtime lives elsewhere. The
control-plane schema is printed by:

```
riela graphql schema
```

For ordinary remote execution, POST `executeWorkflow(input: ExecuteWorkflowInput!)`
to the host's `/graphql` route with a bearer matching its startup
`RIELA_MANAGER_AUTH_TOKEN`. The synchronous payload contains
`workflowExecutionId`, `sessionId`, actual `status`, and actual `exitCode` after
the result is persisted. Query
`workflowExecution(workflowExecutionId: String!)` with the same bearer to read
its session, transitions, and node executions. A well-formed absent ID returns
null; corrupt persisted data returns an error. The host fixes the working
directory and session store. The bearer permits execution in that host context,
not registry writes. An ambiguous timeout can leave the run continuing, so a
retry may start a second run.

Session control is a local-host operation: `rerunSession`, `resumeSession`,
`stopSession` and `continueSession` are answered only by the process that runs
the sessions, and `stopSession` fails closed with `session_not_running` for a
session that process is not executing.

Two rules are easy to get wrong:

- `stopSession` takes the id of the session the run was **entered from**, not
  the new id a rerun reports. A rerun registers under the session it re-enters,
  because the new id does not exist until the rerun has already finished.
- `managerSessionId` on the three session-control inputs is carried for the
  manager control plane and is **not** verified. Access control is the local
  trust boundary plus the host's browser-provenance/Passkey gate. Every session
  control call does check that the session belongs to the `workflowId` you
  supply.

## Agent-node authoring contract

CLI agent nodes (`codex-agent`, `claude-code-agent`, `cursor-cli-agent`) must
declare `agentSandbox`; API-backed nodes must omit it. Add
`output.jsonSchema` when an add-on template consumes the agent payload or a
step drives labeled transitions. Payload references in add-on config/inputs
are strict and fail before the add-on side effect when absent, while optional
`event.*`, `workflowInput.*`, `runtime.*`, `upstream.*`, and `_rielaInput.*`
context remains lenient. Nodes with any `output` block default to two output
validation attempts; nodes without one publish the complete answer as a
`text` payload. See `docs/output-contracts.md` for the exact envelope,
classifier, and diagnostic contract.

## Command reference

<!-- surface-catalog:begin graphql -->
```
riela graphql schema
riela graphql execute
riela graphql document
riela graphql note-document
riela graphql session
riela graphql inspect-session
riela graphql workflow-session
riela graphql session-progress
riela graphql session-health
riela graphql manager-session
riela graphql send-manager-message
riela graphql replay-communication
riela graphql retry-communication-delivery
riela graphql retry-communication
riela gql
```
<!-- surface-catalog:end -->

<!-- surface-catalog:begin step -->
```
riela call-step
riela workflow-call
```
<!-- surface-catalog:end -->

## Task handover GraphQL fields

The `/graphql` task-handover control surface contains two queries and five
mutations. Remote requests require `Authorization: Bearer <manager token>`
matching the server's `RIELA_MANAGER_AUTH_TOKEN`. The client may also send
`X-Riela-Manager-Session-Id` to carry its manager session context. Local trusted
execution is available inside the server process.

```graphql
query Handover($taskId: String!, $handoverId: String) {
  taskHandover(taskId: $taskId, handoverId: $handoverId) {
    handover { handoverId taskId digest reasonKind resumeStepId brief packet }
    errors { code message }
  }
}

query Waiting($traits: [String!]) {
  tasksAwaitingHandover(traits: $traits) {
    tasks { taskId handoverId reasonKind requiredTraits needsAnswer questionText createdAt }
    errors { code message }
  }
}

mutation Request($input: RequestTaskHandoverInput!) {
  requestTaskHandover(input: $input) { taskId taskState decisionKind requestId errors { code message } }
}
mutation Answer($input: AnswerTaskInput!) {
  answerTask(input: $input) { taskId taskState decisionKind requestId errors { code message } }
}
mutation Takeover($input: TakeoverTaskInput!) {
  takeoverTask(input: $input) {
    attemptId sessionId fence expiresAt heartbeatToken heartbeatMs
    answer { questionId payload answeredBy answeredAt }
    packet { handoverId taskId digest resumeStepId brief packet }
    errors { code message }
  }
}
mutation Heartbeat($attemptId: String!, $token: String!) {
  heartbeatAttempt(attemptId: $attemptId, token: $token) { attemptId fence expiresAt fenced errors { code message } }
}
mutation Report($input: ReportAttemptInput!) {
  reportAttempt(input: $input) { attemptId taskState decisionKind handoverId errors { code message } }
}
```

Input shapes:

- `RequestTaskHandoverInput`: required `taskId`, `reason`; optional `immediate`, `target`, and `sinks`.
- `AnswerTaskInput`: required `taskId`, `questionId`, and JSON object `answer`; optional `principal`.
- `TakeoverTaskInput`: required `taskId`, `handoverId`, `hostId`, and `traits`; optional `backend` and `model`.
- `ReportAttemptInput`: required `attemptId`, `token`, JSON object `snapshot`, and JSON object list `deliverables`.

An answer is bound to the specific task handover and question. An answered S1
handover returns `answer` on `TakeoverTaskPayload`; an unanswered S1 handover
is rejected before the server reserves an attempt. The successor delivers the
answer as `handover.answer` and as a message to `resumeStepId`.

For remote takeover, use the `heartbeatToken` returned by `takeoverTask` as the
lease credential. Call `heartbeatAttempt(attemptId, token)` every returned
`heartbeatMs` while the successor runs. At terminal, call
`reportAttempt(input: {attemptId, token, snapshot, deliverables})` once; the
controller reconciles the report and runs its verification and director. Keep
the token secret. A fenced heartbeat or rejected report means this owner cannot
continue. Each lease credential authorizes at most one report, including when
reports race.
