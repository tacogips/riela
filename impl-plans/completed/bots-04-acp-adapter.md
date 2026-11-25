# bots-04-acp-adapter: full ACP v1/v2 normalisation and answerable permission requests

```json
{
  "planId": "bots-04-acp-adapter",
  "planPath": "impl-plans/active/bots-04-acp-adapter.md",
  "dependsOn": ["bots-01-contracts"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaAdapters",
    "Tests/RielaAdaptersTests",
    "impl-plans/progress/bots-04-acp-adapter.md"
  ],
  "sharedPaths": []
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §6.2, §6.6 (adapter side), §6.8, §7.3 (sentinel), §14 (scripted agent
tests). The gateway adapter must turn every ACP `session/update` of both
protocol versions into an `AdapterActivityUpdate` (plan 01) and must hand
`session/request_permission` to the runtime instead of declining at once.

Current code:

- `GatewayACPUpdateCollector.consume(_: ACPSessionUpdate)`
  (`Sources/RielaAdapters/AgentGatewayNodeAdapter.swift:460-498`) drops
  `.plan`, `.userMessageChunk`, `.other`.
- `consume(_: ACPV2SessionUpdate)`
  (`Sources/RielaAdapters/AgentGatewayACPV2Turn.swift:96-131`) has a
  `default: return nil` for every other case.
- `runGatewayTurn` (`AgentGatewayNodeAdapter.swift:252-280`) hosts
  `GatewayACPAgent` with `GatewayClientPermissionResponder(policy: .cancel)`.
- The ACP library types are in `.build/checkouts/agent-gateway/Sources/ACP/`
  (`ACPSessionUpdate.swift`, `ACPV2SessionUpdate.swift`, `ACPV2ToolCalls.swift`,
  `ACPClient.swift:ACPClientDelegate`). Read them; do not edit them.
- The node model is resolved at `AgentGatewayNodeAdapter.swift:91-96` and
  passed to `GatewayAgentDefaults(model:)`.

The pinned in-process agent only emits message and thought chunks. The other
kinds are exercised here with a scripted agent.

## Non-goals

- No change to agent-gateway, `Package.swift` or the ACP version default
  (v1 stays the default; v2 stays opt-in).
- No persistence, no reducer (plan 03).
- No agent-id or vendor special cases in the mapping.
- Existing backend event types, channels and metadata keys do not change.

## Changes

### Collector (`AgentGatewayNodeAdapter.swift`, `AgentGatewayACPV2Turn.swift`, new `GatewayActivityMapping.swift`)

- Put the pure mapping in a new file `Sources/RielaAdapters/GatewayActivityMapping.swift`:
  `enum GatewayActivityMapping { static func update(from: ACPSessionUpdate) -> AdapterActivityUpdate?; static func update(from: ACPV2SessionUpdate) -> AdapterActivityUpdate?; static func stop(stopReason: String, meta: ACPJSONValue?, error: ACPError?) -> AdapterActivityUpdate; static func usage(meta: ACPJSONValue?) -> AdapterActivityUpdate?; static func reportedModel(meta: ACPJSONValue?) -> AdapterActivityUpdate? }`.
- Mapping table (design §6.2):

| v1 | v2 | update |
| --- | --- | --- |
| `agentMessageChunk` text | `agentMessageChunk`; `agentMessage` (`replace: true`, with its message id) | `.message` |
| `agentThoughtChunk` text | `agentThoughtChunk`, `agentThought` | `.thought` |
| `toolCall`, `toolCallUpdate` | `toolCallUpdate` | `.toolCall` (carry title, kind, status, locations; nil for absent or unchanged patch fields) |
| `plan` | `planUpdate` | `.plan` (v1 `planId = "default"`) |
| — | `planRemoved` | `.planRemoved` |
| `.other` with `sessionUpdate == "current_mode_update"` | config option of category `mode` inside `configOptionUpdate` | `.mode` |
| `.other` with `available_commands_update` | `availableCommandsUpdate` | `.commands` |
| — | `configOptionUpdate` | `.configOptions` (id, category, current value, values) and, when a `mode` option is present, a `.mode` too |
| — | `sessionInfoUpdate` | `.sessionInfo` |
| — | `usageUpdate` | `.usage` (`contextUsed`, `contextSize`, `cost`) |
| — | `notice` | `.notice` |
| — | `subagentUpdate` | `.subagent` |
| anything else, non-text content | `other`, terminal updates, tool-call content chunks, user messages, `replayComplete`, `stateUpdate` | `.other(updateKind:)` with the wire discriminator only |

- `consume` returns an array or emits several events when one ACP update maps
  to two activity updates. Updates that returned nil before now return a
  backend event whose `eventType` is the ACP discriminator, `channel` is
  `.tool` for tool data and `.lifecycle` otherwise (use the existing channel
  enum cases; read `AdapterBackendEventChannel`), `isDelta = false`, no
  content. Events that existed before keep their exact `eventType`,
  `channel`, `contentDelta` and `metadata`, and gain `activity`.
- At end of turn (`turn(stopReason:meta:)` for v1, the idle state for v2),
  emit through `backendEventHandler`, in this order: `.usage` when `_meta`
  has usage; `.reportedModel` when `_meta` has a model; `.stop`. Also emit
  `.stop` on the error paths before throwing (v1 `ACPError`, v2 `error` stop
  reason, missing or unrecognised stop reason) with the reason string that
  the thrown error reports.
- `limited`: `.stop(limited: true, limitedResetAt:)` only when the gateway
  `_meta` object or the ACP error data contains
  `limit: { kind: "rate_limit" | "usage_limit", resetAt?: <ISO-8601> }`.
  This key is riela's side of the upstream follow-up (design §15 item 4). No
  message-text matching.

### Permission requests (new `GatewayPermissionDelegate.swift`)

- `struct GatewayPermissionDelegate: ACPClientDelegate` holding
  `handler: AdapterPermissionRequestHandler?`.
  - `handleRequest(method:params:)`: for
    `ACPMethod.sessionRequestPermission`, decode the options and the tool
    call reference (id and title when present; same shape in v1 and v2),
    call the handler, encode `ACPRequestPermissionResponse` with
    `.selected(optionId:)` or `.cancelled`. With a nil handler answer
    `.cancelled` (today's behaviour). Any other method throws
    `ACPError.methodNotFound`.
  - If the handler returns an option id that the agent did not offer, answer
    `.cancelled`.
- `runGatewayTurn` gains `permissionRequestHandler: AdapterPermissionRequestHandler?`
  and an internal `agentFactory` parameter (default builds `GatewayACPAgent`
  as today) so tests can host a scripted agent on
  `ACPClientConnection.inProcess(v1:v2:delegate:)`. The node adapter passes
  `context.permissionRequestHandler`. `AgentGatewayTextClient.run` passes nil.

### `default` sentinel

Where the node model is resolved (`:91-96`), a model equal to
`ModelSentinel.defaultModel` is treated as "no model": it is not sent to the
gateway. Check how an empty model is represented at that point
(`gatewayVendorModel` / `gatewayResolvedModel`) and reuse that representation.
`AdapterExecutionOutput.model` then reports the model the turn returned, or
the sentinel when the turn returned none.

## Imitate

- `GatewayToolCallEventMetadata` (`AgentGatewayNodeAdapter.swift:407-432`) for
  small typed metadata helpers.
- `GatewayClientPermissionResponder` in
  `.build/checkouts/agent-gateway/Sources/AgentGatewayAppCore/GatewayACPClientRunner.swift:74-110`
  for decoding and encoding the permission request.
- `Tests/RielaAdaptersTests/AgentGatewayACPV2Tests.swift` for hosting a turn
  in tests.

## Pitfalls

- An unknown permission option `kind` must never be chosen automatically; the
  adapter only relays the handler's answer.
- When the turn is cancelled or the deadline fires while a permission request
  is waiting, the delegate must still answer `.cancelled` (the handler
  returns `.cancelled` on task cancellation; do not block the ACP read loop).
- v2 `ACPPatch` fields: `.unchanged` → nil in the update, not an empty string.
- Do not count or store non-text content bytes.
- Keep `accumulatedText` logic and the v2 message upsert untouched.
- The existing suites `AgentGatewayNodeAdapterTests`, `AgentGatewayACPV2Tests`,
  `AgentGatewayCancellationTests`, `BackendWaitSignalClassifierTests` must
  pass without edits to their assertions about existing events. If a test
  counts all backend events of a turn, the extra end-of-turn events may change
  the count: update only that count and say so in the progress log.

## Tests (new files in `Tests/RielaAdaptersTests/`)

`ActivityNormalizationTests` (mapping functions only):
- each v1 case and each v2 case in the table → the expected update.
- v1 `toolCallUpdate` with only a status → `.toolCall` with nil title, kind,
  locations.
- v2 `toolCallUpdate` with locations → locations carried with path and line.
- v1 `.other` with `current_mode_update` → `.mode`; unknown discriminator
  `foo_update` → `.other(updateKind: "foo_update")`.
- v2 `configOptionUpdate` with a `mode` and a `model` option →
  `.configOptions` plus `.mode`.
- plan entry with unknown priority `urgent` → kept as `urgent`.
- `_meta` with `limit.kind = "rate_limit"` and `resetAt` → `.stop(limited: true, limitedResetAt:)`;
  an error message containing "rate limit" without the key → `limited: false`.

`GatewayScriptedAgentTests` (scripted ACP agent through `agentFactory`, over
v1 and v2; fixtures as Swift constants in `ACPTranscriptFixtures.swift`):
- script: thought, message chunks, tool call pending → in_progress →
  completed, plan, plan replacement, usage, end turn → the collected
  activity updates are in script order and end with `.stop("end_turn")`.
- out-of-order script: `tool_call_update` before `tool_call` → both
  delivered, no crash.
- permission request with options `allow_once`, `reject_once` and a handler
  returning `.selected("allow-1")` → the agent receives `allow-1` unchanged.
- handler returns an id not offered → agent receives `cancelled`.
- nil handler → `cancelled`.
- turn cancelled while the handler waits → agent receives `cancelled`, the
  turn throws `CancellationError`, and `.stop` was emitted.
- vendor error → `.stop` emitted with the error reason, then the existing
  `providerError` is thrown.

`GatewayModelSentinelTests`:
- node model `default` → the gateway defaults carry no model; node model
  `gpt-x` → `gpt-x`.

## Verification

```
mkdir -p tmp/bots-overview/bots-04-acp-adapter
arch -arm64 /bin/zsh -lc 'swift test --filter "ActivityNormalizationTests|GatewayScriptedAgentTests|GatewayModelSentinelTests|AgentGatewayACPV2Tests|AgentGatewayNodeAdapterTests|AgentGatewayCancellationTests|BackendWaitSignalClassifierTests|GatewayTurnLifetimeTests"' > tmp/bots-overview/bots-04-acp-adapter/test.log 2>&1
```

Exit 0. Evidence: new suites pass; the existing gateway suites still pass, so
step results, session reuse, deadlines and cancellation are unchanged.

## Done criteria

- `grep -n "GatewayClientPermissionResponder" Sources/RielaAdapters/*.swift` prints nothing.
- `grep -n "default:" Sources/RielaAdapters/AgentGatewayACPV2Turn.swift` shows no `default: return nil` in `consume`.
- `git status --short .build Package.swift Package.resolved` prints nothing.
- Verification exits 0; progress log written.
