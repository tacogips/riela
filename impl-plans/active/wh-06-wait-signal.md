# wh-06: Backend wait-signal classifier

```json
{
  "planId": "wh-06-wait-signal",
  "planPath": "impl-plans/active/wh-06-wait-signal.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaAdapters/BackendWaitSignalClassifier.swift",
    "Tests/RielaAdaptersTests/BackendWaitSignalClassifierTests.swift",
    "impl-plans/progress/wh-06-wait-signal.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-06-wait-signal.md"
}
```

## Intent and context

This plan tells "the agent waits for the user on this machine" (S2) apart from plain silence, using typed
backend event data only and never free text. Design §6.2 and §17. Every CLI agent backend runs through
`AgentGatewayNodeAdapter`. It relays `agent_message_chunk`, `agent_thought_chunk`, `tool_call` and
`tool_call_update` events (`GatewayBackendEventType`, `AgentGatewayNodeAdapter.swift:360`). For tool
calls, `metadata` carries `toolCallId`, `title`, `kind` and `status` (`GatewayToolCallEventMetadata`). The persisted
record is `WorkflowBackendEventRecord` (`RuntimeSession.swift:~290`: `eventType, channel, content, toolName,
metadata, at`). The execution's backend is `WorkflowStepExecution.backend`.

Non-goals: wiring into the task observer (wh-14), the session observability verdict (dropped), and adapter changes.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-06-wait-signal/`,
writePaths only, arm64 logs, no git state changes, own progress log).

## Deliverables — pinned API

```swift
public struct BackendWaitSignal: Equatable, Sendable { public var presence: PresenceRequirement; public var eventType: String; public var observedAt: Date }
public struct BackendWaitSignalRule: Equatable, Sendable { public var eventTypes: Set<String>; public var metadataStatus: String }
public protocol BackendWaitSignalClassifying: Sendable {
  func classify(_ event: WorkflowBackendEventRecord, backend: NodeExecutionBackend) -> BackendWaitSignal?
}
public struct TableBackendWaitSignalClassifier: BackendWaitSignalClassifying {
  public init(table: [NodeExecutionBackend: [BackendWaitSignalRule]])
  public static let `default`: TableBackendWaitSignalClassifier
  /// The signal only if the *last* event is classified; any later event means progress.
  public func latestSignal(in events: [WorkflowBackendEventRecord], backend: NodeExecutionBackend) -> BackendWaitSignal?
}
```

- A rule matches when `event.eventType ∈ eventTypes` and `event.metadata["status"] == .string(metadataStatus)`.
  The signal's presence is `PresenceRequirement(traits: [.interactive, .userReachable], instructions:
  "Approve or answer the pending tool call '<metadata.title ?? toolName ?? "unknown">' on this host")`.
- The default table is for `.codexAgent`, `.claudeCodeAgent` and `.cursorCliAgent`: eventTypes `{tool_call, tool_call_update}` and
  `metadataStatus` = the raw value of the ACP tool-call status that means "waiting for permission or pending".
  **Read `ACPToolCallStatus` in the resolved `agent-gateway` checkout** (`.build/checkouts/agent-gateway`, after a
  build) and use the exact raw value (for example `pending`). If ACP has no such status, leave that backend's
  rule list empty and record the finding in the progress log. Do not invent a status.
- All official SDK backends get an empty list (exempt, design §6.2).

## Pitfalls

- Never inspect `content` or any text. A test must prove that a text containing "waiting for input" is not a signal.
- `latestSignal` looks only at the final event. Reordering events by `sequence` or `at` is the caller's
  responsibility. Document that the list is expected in persisted order.

## Tests (`BackendWaitSignalClassifierTests`)

- codex `tool_call_update` with the pending status → signal with traits `[interactive, userReachable]` and a title in the instructions
- the same with status completed → nil; an `agent_message_chunk` whose content says "waiting for input" → nil
- an official SDK backend with the pending status → nil
- `latestSignal`: [pending tool call, message chunk] → nil; [message chunk, pending tool call] → signal
- an empty table → nil everywhere

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-06-wait-signal/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-06-wait-signal/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "BackendWaitSignalClassifierTests" > tmp/work-handover/wh-06-wait-signal/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-06-wait-signal/focused.log'
git diff --check
```

Both must end with exit=0, and the executed count must be > 0.

## Done criteria

- [ ] The classifier matches the pinned API, and the default table is derived from the real ACP enum (evidence in the progress log)
- [ ] The tests pass
