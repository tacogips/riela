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
