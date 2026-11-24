import ACP
import AgentGateway
import AgentGatewayAppCore
import Foundation
import RielaCore

/// Environment variable selecting the ACP protocol version riela requests
/// from the in-process gateway agent: `1` (default) or `2`.
///
/// ACP v2 is in Preview upstream, so it is opt-in here; the gateway serves
/// both versions and a v2 request falls back to v1 when an agent only
/// speaks v1.
public let gatewayACPVersionEnvironmentKey = "RIELA_AGENT_GATEWAY_ACP_VERSION"

func gatewayACPVersion(environment: [String: String]) -> Int {
  guard let value = environment[gatewayACPVersionEnvironmentKey].flatMap({ Int($0) }),
        ACPProtocol.supportedVersions.contains(value) else {
    return ACPProtocol.versionV1
  }
  return value
}

/// Drives one prompt turn over ACP protocol version 2.
///
/// The v2 lifecycle differs from v1 in where completion lives: the
/// `session/prompt` response only acknowledges that the user message was
/// inserted, and the turn ends with an idle `state_update` carrying the
/// stop reason. A failure after insertion is reported there too, as the
/// `error` stop reason, not as an error response.
func consumeGatewayTurnV2(
  _ request: GatewayTurnRequest,
  client: ACPClientConnection,
  collector: GatewayACPUpdateCollector,
  backendEventHandler: AdapterBackendEventHandler?
) async throws -> GatewayACPTurn {
  let session = try await client.newSessionV2(
    ACPV2NewSessionRequest(
      cwd: request.workingDirectory ?? FileManager.default.currentDirectoryPath,
      meta: request.vendorSessionId.map {
        .object([GatewayACPMetaKey.v2: .object(["vendorSessionId": .string($0)])])
      }
    )
  )
  let watchdog = GatewayDeadlineWatchdog(deadline: request.deadline, client: client, sessionId: session.sessionId)
  defer { watchdog.cancel() }

  var finalState: ACPV2StateUpdate?
  let stream = client.promptTurn(ACPV2PromptRequest(sessionId: session.sessionId, prompt: request.promptBlocks))
  try await withTaskCancellationHandler {
    for try await event in stream {
      switch event {
      case .accepted:
        break
      case .update(let update):
        if let backendEvent = collector.consume(update) {
          await backendEventHandler?(backendEvent)
        }
      case .finished(let state):
        finalState = state
      }
    }
  } onCancel: {
    watchdog.cancelTurn()
  }
  if Task.isCancelled, !watchdog.deadlineExpired {
    throw CancellationError()
  }
  guard let finalState else {
    throw AdapterExecutionError(.invalidOutput, "agent-gateway stream ended without an idle state update")
  }
  if finalState.stopReason == .cancelled, watchdog.deadlineExpired {
    throw AdapterExecutionError(.timeout, "local agent process exceeded deadline and was terminated")
  }
  if finalState.stopReason == .error {
    // Same wording as a v1 error response, so failure classification and
    // diagnostics do not depend on the negotiated protocol version.
    let error = finalState.error ?? ACPError.internalError("agent-gateway turn failed")
    throw AdapterExecutionError(.providerError, "agent-gateway error \(error.code): \(error.message)")
  }
  // v2 stop reasons are an open set and may be absent; without a
  // recognized one the outcome of the turn is unknown, never success.
  guard let stopReason = finalState.stopReason.flatMap({ ACPStopReason(rawValue: $0.rawValue) }) else {
    throw AdapterExecutionError(
      .providerError,
      "agent-gateway turn ended with stop reason '\(finalState.stopReason?.rawValue ?? "unknown")'"
    )
  }
  return collector.turn(stopReason: stopReason, state: finalState)
}

extension GatewayACPUpdateCollector {
  /// Maps a v2 update to a riela backend event. Message and tool-call
  /// updates are upserts keyed by id: the first `tool_call_update` for an id
  /// creates the tool call, and a whole-message update replaces what chunks
  /// accumulated for that message.
  func consume(_ update: ACPV2SessionUpdate) -> AdapterBackendEvent? {
    lock.withLock {
      switch update {
      case .agentMessageChunk(let chunk):
        guard case .text(let text) = chunk.content else { return nil }
        messages.append(chunk)
        accumulatedText = messages.joinedText
        return chunkEvent(.agentMessageChunk, channel: .assistant, text: text.text)
      case .agentMessage(let message):
        messages.apply(message)
        accumulatedText = messages.joinedText
        // A whole message is output that did not arrive as chunks.
        guard case .set = message.content, let text = messages.text(of: message.messageId),
              !text.isEmpty else { return nil }
        return chunkEvent(.agentMessageChunk, channel: .assistant, text: text)
      case .agentThoughtChunk(let chunk):
        guard case .text(let text) = chunk.content else { return nil }
        return chunkEvent(.agentThoughtChunk, channel: .thinking, text: text.text)
      case .toolCallUpdate(let update):
        let isNew = seenToolCalls.insert(update.toolCallId).inserted
        return chunkEvent(
          isNew ? .toolCall : .toolCallUpdate,
          channel: .tool,
          text: nil,
          toolCall: GatewayToolCallEventMetadata(
            toolCallId: update.toolCallId,
            title: update.title.value,
            kind: update.kind.value.flatMap(ACPToolKind.init(rawValue:)),
            status: update.status.value.flatMap(ACPToolCallStatus.init(rawValue:))
          )
        )
      default:
        return nil
      }
    }
  }

  func turn(stopReason: ACPStopReason, state: ACPV2StateUpdate) -> GatewayACPTurn {
    lock.withLock { turn(stopReason: stopReason, meta: state.meta) }
  }
}
