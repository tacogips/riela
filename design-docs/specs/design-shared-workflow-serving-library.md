# macOS App Client And Shared Workflow Serving Library

This document defines the feature-local design for extracting workflow serving
into reusable Swift library APIs shared by the command-line client and a new
macOS menu bar client.

## Overview

`riela serve` currently presents serving as a CLI-scoped behavior. The requested
macOS client needs the same long-lived workflow serving capability without
launching or scripting the CLI process. The shared boundary should live in the
Swift library layer so the CLI and the macOS app are peers over the same
serving controller.

The serving controller owns workflow selection, validation, listener startup,
event-source startup, lifecycle state, restart, and update-driven reload. The
macOS app is implemented in this issue as a separate Riela client that presents
menu bar UI, stores user preferences, starts at user request, selects a
workflow, calls the library to serve it, and calls reload after an update. It
must not own workflow runtime internals or duplicate `riela serve` command
logic.

Step 1 intake source:

- Workflow mode: `issue-resolution`
- Issue reference: `macOS app client / workflow serving`
- Requested behavior: add a command-line-independent macOS menu bar app that
  can select and serve a workflow, reload and restart after update, and keep
  scheduled events and chat event sources running continuously by calling the
  command-version runtime as a library.
- Review mode: adversarial, high risk.
- Reference repository root established by Step 1: this repository checkout.
- No external Codex reference repository was selected for this issue. The
  workflow input explicitly points reference behavior at the local Riela
  checkout, so the usual `../../codex-agent` fallback is not used.

## Goals

- Expose workflow serving as reusable Swift APIs importable by `RielaCLI` and a
  macOS app target.
- Add a minimal macOS menu bar app client target that can select a workflow,
  start serving, show status, stop, restart, and update/reload.
- Keep CLI behavior as a thin adapter over the library, preserving current
  command names and output contracts.
- Allow a client to select a workflow or manifest entry, start serving it,
  inspect state, stop it, restart it, and reload it after an update.
- Support long-lived event sources, including scheduled and chat event sources,
  under the same serving lifecycle as GraphQL/HTTP workflow execution.
- Make update reload atomic: invalid updated workflow definitions must not tear
  down the currently running generation.
- Keep workflow execution, event-source normalization, and provider-specific
  credentials behind existing `RielaCore`, `RielaEvents`, `RielaGraphQL`, and
  `RielaServer` target boundaries.

## Non-Goals

- Adding launch-at-login, notification, Sparkle, or App Store packaging
  behavior.
- Adding advanced macOS preferences, onboarding, embedded logs, update
  scheduling, or packaging notarization beyond the minimum app-client target
  needed to run as a separate macOS app.
- Replacing workflow package installation, checkout, or update commands.
- Running more than one served workflow generation for the same controller in
  the first iteration.
- Adding provider-specific chat UI behavior to the serving layer.
- Moving Codex, Claude, or Cursor adapter behavior into the server target.

## Target Boundary

The reusable serving API should extend the existing `RielaServer` library
product. `RielaServer` is already a public Swift package product and is the
natural boundary for HTTP/GraphQL server contracts. New serving orchestration
should stay provider-neutral and may depend on `RielaCore`, `RielaGraphQL`, and
`RielaEvents` only where necessary.

Recommended ownership:

- `RielaServer`: serving controller, lifecycle state, listener handles, served
  workflow catalog resolution, reload/restart orchestration, and public DTOs.
- shared runtime composition library: production node adapter construction and
  provider adapter wiring that are currently CLI-owned but must become
  importable by both `RielaCLI` and the macOS app without importing CLI command
  parsing or rendering.
- `RielaCLI`: argument parsing, text/table/JSON rendering, process signal
  handling, and backwards-compatible command errors.
- `RielaEvents`: event source config validation, event listener handles,
  schedules, chat gateway adapters, receipts, and reply dispatch records.
- `RielaGraphQL`: GraphQL schema and request/response contracts used by the
  server listener.
- `RielaApp` macOS app target: app lifecycle, menu bar UI, user
  preferences, selection dialogs, update button, status presentation, and calls
  into `RielaServer`.

`RielaServer` must not import `RielaCLI`, `CodexAgent`, `ClaudeCodeAgent`, or
`CursorCLIAgent`. Agent execution remains reachable through `RielaCore` node
adapter injection and shared production adapter construction performed by the
CLI or app composition root.

`RielaApp` must not import `RielaCLI`; this is the concrete guardrail
that keeps the app an independent client instead of a GUI wrapper around CLI
commands. It may import the shared runtime composition library and the agent
adapter products needed to build production execution dependencies.

## Agent Adapter Boundary Mapping

This design does not change `codex-agent`, `claude-code-agent`, or
`cursor-cli-agent` execution semantics. The shared serving controller is
provider-neutral orchestration: it accepts already constructed runtime
dependencies and starts listeners/event sources that dispatch workflow
executions through existing adapter injection.

Cursor CLI behavior remains isolated behind `CursorCLIAgent` and any
Cursor-specific readiness helpers. The serving API must not expose Cursor mode,
stream format, auth-probe behavior, model-effort mapping, or official Cursor
SDK compatibility as public serving concepts. Those settings may be present in
workflow node payloads and adapter configuration, but they cross the serving
boundary only as provider-neutral execution dependencies.

Codex CLI behavior remains isolated behind `CodexAgent` and shared production
adapter construction. The macOS app may build the same production dependency
graph as the CLI through a composition library, but it must not call Codex
agent commands directly or reinterpret Codex JSONL output inside UI code.

There is no intentional behavior divergence from the local Riela reference for
agent execution. The intentional architectural divergence is only at the
client boundary: `RielaCLI` and `RielaApp` become peer clients over the
same serving library instead of the app shelling out to `riela serve`.

## Public API Shape

The first implementation should introduce a small asynchronous controller API.
Names are illustrative but define the required contract.

```swift
public actor WorkflowServingController {
  public init(dependencies: WorkflowServingDependencies)
  public func start(_ request: WorkflowServeStartRequest) async throws -> WorkflowServeState
  public func stop() async throws -> WorkflowServeState
  public func restart() async throws -> WorkflowServeState
  public func reload(_ request: WorkflowServeReloadRequest) async throws -> WorkflowServeState
  public func currentState() async -> WorkflowServeState
}
```

Required request and state concepts:

- `WorkflowServeSelection`: workflow chosen by direct workflow directory,
  manifest entry id, package/catalog id, or scoped workflow name.
- `WorkflowServeStartRequest`: selection, host, port, working directory,
  artifact root, session store root, event root, runtime limits, default
  variables, auto-improve policy, auth policy, and whether event sources start.
- `WorkflowServeReloadRequest`: update mode, optional replacement selection,
  and restart policy.
- `WorkflowServeState`: stopped, starting, running, reloading, stopping,
  failed; each running state includes generation id, selected workflow id,
  listener endpoint, event listener status, session store root, and last
  validation summary.
- `WorkflowServeHandle`: internal listener/event-source handles with an
  idempotent async shutdown method.

The controller should be an `actor` so menu actions, CLI signals, and update
callbacks cannot race start/stop/reload operations.

## Workflow Selection And Validation

Selection must reuse existing workflow resolution and manifest validation
behavior rather than invent a macOS-specific catalog.

Resolution rules:

1. Direct workflow directory validates `workflow.json` and node payloads using
   the same model loader used by `workflow run` and `workflow manifest
   validate`.
2. Manifest selection uses the manifest entry id as the served workflow identity
   and preserves the authored workflow id as metadata.
3. Scoped project/user/package selections resolve to a concrete workflow
   directory before listener startup.
4. A reload validates the replacement generation completely before old handles
   are stopped.

Validation errors must identify the selection, manifest path or workflow
directory, and failing entry id when available. Errors must not include
credential values, environment dumps, or raw chat payloads.

## Lifecycle Semantics

`start` transitions from `stopped` to `starting`, validates the selection,
creates a generation, starts the GraphQL/HTTP listener, starts configured event
sources, and returns `running`.

`stop` shuts down event sources before the HTTP/GraphQL listener, records a
terminal state, and is idempotent.

`restart` stops the current generation and starts a new generation from the
last accepted request. If startup fails after shutdown, the controller returns
`failed` with the previous generation unavailable.

`reload` is update-oriented. It validates the updated workflow first. When
validation passes, it starts a replacement generation, switches current state to
that generation, and then shuts down the previous generation. When validation or
replacement startup fails, the previous generation keeps running and the
returned state includes the reload failure diagnostics.

The reload path is the behavior the macOS app should call after its Update
action refreshes workflow package or checkout contents.

## Event Source Lifecycle

Long-lived event sources are part of serving, not a detached background job. A
served generation may start schedules, webhooks, chat gateways, and reply
dispatchers using the existing event-source contracts.

Rules:

- Event sources start only after workflow selection validation succeeds.
- Event source handles are scoped to the served generation id.
- Event receipts, schedules, and reply dispatch records are written under the
  configured event root.
- Chat and scheduled events trigger workflow execution through the same library
  execution boundary used by GraphQL starts.
- Reload stops old event source handles so scheduled/chat sources do not double
  trigger after update.
- Provider credentials are referenced by environment-variable names and are
  never copied into `WorkflowServeState`.

## CLI And macOS Client Integration

`riela serve` should parse arguments exactly as it does today and then build a
`WorkflowServeStartRequest`. CLI-specific concerns remain in `RielaCLI`:

- process signal handling and terminal wait loop
- stdout/stderr rendering
- exit-code mapping
- command-line option compatibility
- environment fallback parsing

The macOS menu bar app should call the same controller from its app model:

- Select Workflow opens a workflow, package, or manifest-entry selector and
  builds `WorkflowServeSelection`.
- Serve calls `start`.
- Stop calls `stop`.
- Restart calls `restart`.
- Update performs the package/checkout refresh outside the serving library and
  then calls `reload`.
- Status reads `currentState`.

This keeps the macOS app an independent Riela client while still using the
command-version runtime as a library.

The initial app UI should be deliberately small: a menu bar status item with
workflow selection, Serve, Stop, Restart, Update, Status, and Quit actions is
enough. The app should persist only the selected workflow reference and serving
options required to rebuild `WorkflowServeStartRequest` on user action. It must
not auto-start serving on login or background launch unless a future design adds
that policy explicitly.

## macOS App Registration And Rollout

The issue requires Riela to be usable as a command-line-independent macOS app.
Implementation should therefore add a source-level macOS app target and the
minimum bundle metadata needed for local build/install validation. Distribution
packaging, notarization, Sparkle updates, and Homebrew cask integration remain
outside this issue.

The initial implementation registers the app in SwiftPM as the
`RielaApp` executable product and provides
`scripts/build-riela-menu-bar-app.sh` to create a local
`.build/<configuration>/RielaApp.app` bundle with `LSUIElement` enabled. The app
imports `RielaServer`, not `RielaCLI`, and calls the shared controller directly
for Select Workflow, Serve, Stop, Restart, Update/reload, and status actions.

Rollout constraints:

- The app target must be separate from the `riela` executable and must have its
  own entry point.
- The app must compile on the package's declared macOS platform baseline
  `.macOS(.v14)`.
- If SwiftPM cannot directly produce the final `.app` bundle shape required by
  the chosen implementation, add the smallest committed packaging/build wrapper
  needed for deterministic local validation.
- App status must degrade to a visible failed state when serving dependencies
  cannot be constructed; it must not silently fall back to shelling out to
  `riela serve`.
- No app preference or state file may store provider credentials, bearer
  tokens, webhook secrets, or raw chat payloads.

## Error Handling And Observability

Errors returned from the serving library should be structured and renderable:

- validation errors
- listener bind errors
- event-source startup errors
- runtime dependency errors
- shutdown errors
- reload replacement errors

The state model should expose non-secret diagnostics, generation id, endpoint,
selected workflow metadata, and event source status. It should not expose raw
environment values, bearer tokens, webhook signing secrets, absolute paths in
remote responses, or unredacted provider payloads.

The menu bar app should map library states directly:

- `stopped`: no served generation and app actions may select or serve.
- `starting`/`reloading`/`stopping`: transient disabled actions except Quit and
  Status.
- `running`: shows selected workflow id, endpoint, event-source summary, and
  last accepted generation id.
- `failed`: shows redacted diagnostics and preserves the last selected request
  for retry when safe.

## Security Considerations

- Reject unsafe workflow names, manifest ids, and path traversal before serving.
- Keep HTTP listener defaults local-only unless the user explicitly binds a
  wider host.
- Require the existing GraphQL/server auth policy for remote management when
  configured.
- Redact environment variables and credentials from state, reload errors, and
  macOS UI-facing DTOs.
- Ensure reload cannot leave duplicate schedule/chat listeners active.
- Ensure the macOS app cannot bypass workflow validation by constructing a
  partially resolved runtime.
- Ensure the app does not persist secrets in preferences or logs.
- Ensure app-triggered update/reload cannot widen listener host binding beyond
  the last explicit user selection.

## Testing Requirements

Required tests:

- controller starts and stops a valid direct workflow selection
- CLI serve request construction delegates to the shared controller
- macOS-style client can start, inspect, reload, and stop through library APIs
  without importing CLI types
- app target compiles without importing `RielaCLI`
- app model maps menu actions to `start`, `stop`, `restart`, `reload`, and
  `currentState`
- local app bundle/build validation proves the app can run as a separate macOS
  app artifact, even though distribution packaging is out of scope
- reload keeps the old generation running when updated workflow validation
  fails
- successful reload stops old event-source handles and starts exactly one new
  generation
- event-source startup failure returns structured diagnostics without leaking
  secret values
- manifest-entry selection preserves manifest id and authored workflow id
- concurrent start/stop/reload calls serialize through the actor

## Review Notes

Self-review found an initial risk that reload could be implemented as stop then
start, which would make update failures interrupt scheduled and chat sources.
The accepted design requires validate-and-start replacement before old
generation shutdown.

Independent review found an initial risk that putting lifecycle code in the
macOS app would fork CLI behavior. The accepted design keeps lifecycle in
`RielaServer` and restricts the app to client/UI responsibilities.

Step 2 rerun corrected the initial design scope because Step 1 requires a
command-line-independent macOS menu bar app, not only a future app contract.
The design now includes a minimal app target, app registration/build rollout
constraints, and the shared runtime composition boundary needed to keep the app
from importing `RielaCLI`.
