import ACP
import AgentGateway
import AgentGatewayAppCore
import Foundation
import Testing
@testable import RielaAdapters
import RielaCore

@Suite struct GatewayScriptedAgentTests {
  private static let versions = [ACPProtocol.versionV1, ACPProtocol.versionV2]

  @Test(arguments: versions) func orderedActivity(_ version: Int) async throws {
    let recorder = ScriptedGatewayEvidence()
    let turn = try await Self.run(version, recorder: recorder, script: .updates)
    #expect(turn.text == "Authoritative answer")
    #expect(turn.model == "actual-model")
    let events = await recorder.events
    let transcript = version == ACPProtocol.versionV1 ? ACPTranscriptFixtures.v1 : ACPTranscriptFixtures.v2
    let state = AdapterActivityUpdate.other(updateKind: "state_update")
    let expectedUpdates = version == ACPProtocol.versionV1
      ? transcript.flatMap(\.activity) : [state] + transcript.flatMap(\.activity) + [state]
    #expect(events.compactMap(\.activity) == expectedUpdates + [
      .usage(["inputTokens": .integer(4), "outputTokens": .integer(2)]),
      .reportedModel("actual-model"),
      .stop(stopReason: "end_turn", limited: false, limitedResetAt: nil)
    ])
    #expect(events.compactMap(\.sequence) == Array(1...events.count))
    let terminals = events.filter { ["terminal_update", "terminal_output_chunk", "tool_call_content_chunk"].contains($0.eventType) }
    #expect(terminals.allSatisfy { $0.channel == .tool && $0.metadata == nil && $0.contentDelta == nil && !$0.isDelta })
  }

  @Test(arguments: versions) func sessionNewCarriesMCPServers(_ version: Int) async throws {
    let server = AdapterMCPServer(name: "riela-ask", command: "/opt/bin/riela", arguments: ["ask", "tool-server"],
      environment: ["XDG_DATA_HOME": "/fixture/data", "HOME": "/fixture/home"])
    let recorder = ScriptedGatewayEvidence()
    _ = try await Self.run(version, recorder: recorder, script: .updates, mcpServers: [server])
    let environment = [ACPEnvVariable(name: "HOME", value: "/fixture/home"),
      ACPEnvVariable(name: "XDG_DATA_HOME", value: "/fixture/data")]
    if version == ACPProtocol.versionV1 {
      #expect(await recorder.v1Session?.mcpServers == [
        ACPMCPServer(name: server.name, command: server.command, args: server.arguments, env: environment)
      ])
    } else {
      #expect(await recorder.v2Session?.mcpServers == [
        .stdio(.init(name: server.name, command: server.command, args: server.arguments, env: environment))
      ])
    }

    let empty = ScriptedGatewayEvidence()
    _ = try await Self.run(version, recorder: empty, script: .updates)
    if version == ACPProtocol.versionV1 {
      #expect(await empty.v1Session?.mcpServers == [])
    } else {
      #expect(await empty.v2Session?.mcpServers == [])
    }
  }

  @Test(arguments: versions) func permissionPassesNativeOptionsAndValidatesSelection(_ version: Int) async throws {
    let recorder = ScriptedGatewayEvidence()
    _ = try await Self.run(version, recorder: recorder, script: .permission) { request in
      await recorder.record(request)
      return .selected(optionId: "allow-1")
    }
    let requests = await recorder.requests
    let replies = await recorder.replies
    #expect(requests == [.init(toolCallId: "call", title: "Read", options: [
      .init(optionId: "allow-1", name: "Allow", kind: "allow_once"),
      .init(optionId: "reject-1", name: "Reject", kind: "reject_once"),
      .init(optionId: "custom-1", name: "Ask later", kind: "future")
    ])])
    #expect(replies == [.selected(optionId: "allow-1")])

    let invalid = ScriptedGatewayEvidence()
    _ = try await Self.run(version, recorder: invalid, script: .permission) { _ in .selected(optionId: "unoffered") }
    #expect(await invalid.replies == [.cancelled])

    let absent = ScriptedGatewayEvidence()
    _ = try await Self.run(version, recorder: absent, script: .permission)
    #expect(await absent.replies == [.cancelled])
  }

  @Test(arguments: versions) func cancelledTurnRepliesToWaitingAgent(_ version: Int) async throws {
    let recorder = ScriptedGatewayEvidence()
    let (entered, ready) = AsyncStream<Void>.makeStream()
    let (replies, response) = AsyncStream<ACPRequestPermissionResponse.Outcome>.makeStream()
    let handler: AdapterPermissionRequestHandler = { _ in
      ready.yield(())
      ready.finish()
      try? await Task.sleep(for: .seconds(30))
      // Cancellation takes precedence even if the handler returns a valid ID.
      return .selected(optionId: "allow-1")
    }
    let turn = Task {
      defer { ready.finish() }
      return try await Self.run(version, recorder: recorder, script: .permission, reply: response, handler: handler)
    }
    var readiness = entered.makeAsyncIterator()
    if await readiness.next() == nil {
      _ = await turn.result
      Issue.record("turn ended before the permission handler started")
      return
    }
    turn.cancel()
    await #expect(throws: CancellationError.self) { try await turn.value }
    var outcomes = replies.makeAsyncIterator()
    #expect(await outcomes.next() == .cancelled)
    #expect(await recorder.events.last?.activity == .stop(stopReason: "cancelled", limited: false, limitedResetAt: nil))
  }

  @Test(arguments: versions) func deadlineRepliesToWaitingAgent(_ version: Int) async throws {
    let recorder = ScriptedGatewayEvidence()
    let deadline = Date().addingTimeInterval(1)
    let timeout = AdapterExecutionError(.timeout, "local agent process exceeded deadline and was terminated")
    await #expect(throws: timeout) {
      try await Self.run(version, recorder: recorder, script: .permission, deadline: deadline) { request in
        await recorder.record(request)
        try? await Task.sleep(for: .seconds(30))
        return .selected(optionId: "allow-1")
      }
    }
    #expect(await recorder.requests.count == 1)
    #expect(await recorder.replies == [.cancelled])
    #expect(await recorder.events.last?.activity == .stop(stopReason: "cancelled", limited: false, limitedResetAt: nil))
  }

  @Test(arguments: versions) func providerErrorEmitsStructuredStop(_ version: Int) async throws {
    let recorder = ScriptedGatewayEvidence()
    let message = "agent-gateway error -32001: provider exhausted"
    await #expect(throws: AdapterExecutionError(.providerError, message)) {
      try await Self.run(version, recorder: recorder, script: .error)
    }
    #expect(await recorder.events.last?.activity == .stop(stopReason: message, limited: true, limitedResetAt: nil))
  }

  @Test(arguments: ["_unknown_stop", nil]) func v2UnrecognizedOrMissingStopIsFailure(reason: String?) async throws {
    let recorder = ScriptedGatewayEvidence()
    let raw = reason ?? "unknown"
    await #expect(throws: AdapterExecutionError(.providerError, "agent-gateway turn ended with stop reason '\(raw)'")) {
      try await Self.run(ACPProtocol.versionV2, recorder: recorder, script: .unrecognized(reason))
    }
    #expect(await recorder.events.last?.activity == .stop(stopReason: raw, limited: false, limitedResetAt: nil))
  }

  private static func run(
    _ version: Int,
    recorder: ScriptedGatewayEvidence,
    script: ScriptedGatewayAgent.Script,
    reply: AsyncStream<ACPRequestPermissionResponse.Outcome>.Continuation? = nil,
    deadline: Date? = nil,
    mcpServers: [AdapterMCPServer] = [],
    handler: AdapterPermissionRequestHandler? = nil
  ) async throws -> GatewayACPTurn {
    try await runGatewayTurn(
      GatewayTurnRequest(defaults: .init(vendor: .codex, model: "fixture"), environment: [:], promptBlocks: [.text("test")],
        deadline: deadline, acpVersion: version, mcpServers: mcpServers),
      executorFactory: { _ in ScriptedGatewayExecutor() },
      backendEventHandler: { event in await recorder.record(event) },
      permissionRequestHandler: handler,
      agentFactory: { _, _ in ScriptedGatewayAgent(script: script, recorder: recorder, reply: reply) }
    )
  }
}

private actor ScriptedGatewayEvidence {
  private(set) var events: [AdapterBackendEvent] = []
  private(set) var requests: [AdapterPermissionRequest] = []
  private(set) var replies: [ACPRequestPermissionResponse.Outcome] = []
  private(set) var v1Session: ACPNewSessionRequest?
  private(set) var v2Session: ACPV2NewSessionRequest?

  func record(_ event: AdapterBackendEvent) { events.append(event) }
  func record(_ request: AdapterPermissionRequest) { requests.append(request) }
  func record(_ reply: ACPRequestPermissionResponse.Outcome) { replies.append(reply) }
  func record(_ request: ACPNewSessionRequest) { v1Session = request }
  func record(_ request: ACPV2NewSessionRequest) { v2Session = request }
}

private struct ScriptedGatewayAgent: ACPAgent, ACPV2Agent {
  enum Script: Sendable {
    case updates, permission, error, unrecognized(String?)
  }

  let script: Script
  let recorder: ScriptedGatewayEvidence
  let reply: AsyncStream<ACPRequestPermissionResponse.Outcome>.Continuation?
  private let sessionId = "fixture-session"
  private let implementation = ACPImplementation(name: "scripted", version: "1")
  private let error = ACPError(code: -32_001, message: "provider exhausted",
    data: .object(["limit": .object(["kind": .string("usage_limit")])]))

  func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
    ACPInitializeResponse(agentInfo: implementation)
  }

  func initialize(_ request: ACPV2InitializeRequest) async throws -> ACPV2InitializeResponse {
    ACPV2InitializeResponse(info: implementation, capabilities: .init(session: .init()))
  }

  func newSession(
    _ request: ACPNewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPNewSessionResponse {
    await recorder.record(request)
    return ACPNewSessionResponse(sessionId: sessionId)
  }

  func newSession(
    _ request: ACPV2NewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPV2NewSessionResponse {
    await recorder.record(request)
    return ACPV2NewSessionResponse(sessionId: sessionId)
  }

  func prompt(_ request: ACPPromptRequest, connection: ACPAgentSideConnection) async throws -> ACPPromptResponse {
    defer { reply?.finish() }
    switch script {
    case .updates:
      for fixture in ACPTranscriptFixtures.v1 {
        await connection.sendUpdate(.init(sessionId: request.sessionId, update: try fixture.v1()))
      }
    case .permission:
      let params = V1PermissionParams(sessionId: sessionId, toolCall: .init(toolCallId: "call", title: "Read"),
        options: ACPTranscriptFixtures.permissionOptions)
      let response: ACPRequestPermissionResponse = try await connection.sendRequest(method: ACPMethod.sessionRequestPermission, params: params)
      await recordPermission(response.outcome)
      if response.outcome == .cancelled { return .init(stopReason: .cancelled) }
    case .error, .unrecognized:
      throw error
    }
    return .init(stopReason: .endTurn, meta: ACPTranscriptFixtures.meta(version: ACPProtocol.versionV1))
  }

  func submitPrompt(
    _ request: ACPV2PromptRequest, connection: ACPAgentSideConnection
  ) async -> ACPV2PromptSubmission {
    ACPV2PromptSubmission {
      defer { reply?.finish() }
      let sessionId = request.sessionId
      let meta = ACPTranscriptFixtures.meta(version: ACPProtocol.versionV2)
      connection.sendUpdate(.stateUpdate(.running()), sessionId: sessionId)
      let final: ACPV2StateUpdate
      switch script {
      case .updates:
        for fixture in ACPTranscriptFixtures.v2 {
          connection.sendUpdate(try fixture.v2(), sessionId: sessionId)
        }
        final = .idle(stopReason: .endTurn, meta: meta)
      case .permission:
        let response = try await connection.requestPermission(
          .init(sessionId: sessionId, title: "Read", subject: .toolCall(.init(toolCallId: "call", title: .set("Inner title"))),
            options: ACPTranscriptFixtures.permissionOptions)
        )
        await recordPermission(response.outcome)
        final = .idle(stopReason: response.outcome == .cancelled ? .cancelled : .endTurn)
      case .error:
        final = .idle(stopReason: .error, error: error)
      case .unrecognized(let reason):
        final = .idle(stopReason: reason.map(ACPV2StopReason.init(rawValue:)))
      }
      connection.sendUpdate(.stateUpdate(final), sessionId: sessionId)
      return ACPV2PromptResponse(messageId: "user")
    }
  }

  private func recordPermission(_ outcome: ACPRequestPermissionResponse.Outcome) async {
    reply?.yield(outcome)
    await recorder.record(outcome)
  }

  func resumeSession(
    _ request: ACPV2ResumeSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPV2ResumeSessionResponse { .init() }

  func listSessions(
    _ request: ACPListSessionsRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPListSessionsResponse { .init(sessions: []) }

  func closeSession(_ request: ACPSessionRequest, connection: ACPAgentSideConnection) async throws {}
  func cancel(_ notification: ACPCancelNotification) async {}
  func cancel(_ notification: ACPCancelNotification, connection: ACPAgentSideConnection) async {}

  private struct ToolCallReference: Encodable {
    let toolCallId: String
    let title: String
  }

  private struct V1PermissionParams: Encodable {
    let sessionId: String
    let toolCall: ToolCallReference
    let options: [ACPPermissionOption]
  }
}

private struct ScriptedGatewayExecutor: GatewayExecuting {
  func execute(_ params: GatewayExecuteParams, emit: @escaping GatewayEventEmitter) async throws -> GatewayExecuteResult {
    Issue.record("the scripted agent must use only ACP")
    throw CancellationError()
  }
}
