import Foundation
import XCTest
@testable import RielaCore

final class OpenModelProviderRoutingTests: XCTestCase {
  func testCustomBaseURLDecodesWithCustomModelAndRoundTrips() throws {
    let payload = try JSONDecoder().decode(AgentNodePayload.self, from: Data(#"""
      {
        "id": "worker",
        "executionBackend": "codex-agent",
        "baseURL": "https://api.kimi.example/v1",
        "apiKeyEnvironment": "KIMI_API_KEY"
      }
      """#.utf8))

    XCTAssertEqual(payload.baseURL, "https://api.kimi.example/v1")
    XCTAssertEqual(payload.apiKeyEnvironment, "KIMI_API_KEY")
    XCTAssertEqual(payload.model, "custom")
    XCTAssertTrue(validateAgentNodePayload(payload).isEmpty)

    let roundTrip = try JSONDecoder().decode(
      AgentNodePayload.self,
      from: JSONEncoder().encode(payload)
    )
    XCTAssertEqual(roundTrip, payload)
  }

  func testCustomBaseURLValidationRejectsInvalidCombinations() throws {
    let provider = try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://openrouter.ai/api/v1"
    )
    let withNamedProvider = AgentNodePayload(
      id: "worker",
      executionBackend: .codexAgent,
      model: "custom",
      baseURL: "https://api.kimi.example/v1",
      provider: provider
    )
    XCTAssertTrue(validateAgentNodePayload(withNamedProvider).contains {
      $0.path == "node.baseURL" && $0.message.contains("cannot be combined")
    })

    let unsupportedBackend = AgentNodePayload(
      id: "worker",
      executionBackend: .cursorCliAgent,
      model: "custom",
      baseURL: "https://api.kimi.example/v1"
    )
    XCTAssertTrue(validateAgentNodePayload(unsupportedBackend).contains {
      $0.path == "node.baseURL" && $0.message.contains("codex-agent")
    })

    let missingBaseURL = AgentNodePayload(
      id: "worker",
      executionBackend: .claudeCodeAgent,
      model: "custom",
      apiKeyEnvironment: "KIMI_API_KEY"
    )
    XCTAssertTrue(validateAgentNodePayload(missingBaseURL).contains {
      $0.path == "node.apiKeyEnvironment" && $0.message.contains("requires baseURL")
    })
  }

  func testProviderConfigurationDecodesEncodesAndForwards() throws {
    let payload = try decodePayload(providerFields: """
      "provider": {
        "name": "openrouter_1",
        "baseUrl": "https://openrouter.example/v1",
        "apiKeyEnv": "OPENROUTER_API_KEY"
      },
      "providerProxy": "codex",
      """)

    XCTAssertEqual(payload.provider?.name, "openrouter_1")
    XCTAssertEqual(payload.provider?.baseUrl, "https://openrouter.example/v1")
    XCTAssertEqual(payload.provider?.apiKeyEnv, "OPENROUTER_API_KEY")
    XCTAssertEqual(payload.providerProxy, .codex)

    let input = AdapterExecutionInput(node: payload, promptText: "hello")
    let roundTrip = try JSONDecoder().decode(
      AdapterExecutionInput.self,
      from: JSONEncoder().encode(input)
    )
    XCTAssertEqual(roundTrip.node.provider, payload.provider)
    XCTAssertEqual(roundTrip.node.providerProxy, .codex)
  }

  func testProviderConfigurationAcceptsLoopbackHTTPVariants() throws {
    for baseUrl in ["http://localhost:11434/v1", "http://127.0.0.1:8000/v1", "http://[::1]:8000/v1"] {
      XCTAssertNoThrow(try decodePayload(providerFields: providerJSON(baseUrl: baseUrl)))
    }
  }

  func testProviderConfigurationRejectsInvalidNamesURLsAndAPIKeyNames() {
    for name in ["Uppercase", "-leading", String(repeating: "a", count: 65)] {
      XCTAssertThrowsError(try decodePayload(providerFields: providerJSON(name: name)))
    }
    for baseUrl in [
      "relative/v1",
      "ftp://provider.example/v1",
      "http://provider.example/v1",
      "https://user:password@provider.example/v1",
      "https://provider.example/v1?token=inline-secret",
      "https://provider.example/v1#inline-secret"
    ] {
      XCTAssertThrowsError(try decodePayload(providerFields: providerJSON(baseUrl: baseUrl)))
    }
    for apiKeyEnv in ["INVALID-NAME", "RIELA_AGENT_BACKEND"] {
      XCTAssertThrowsError(try decodePayload(providerFields: providerJSON(apiKeyEnv: apiKeyEnv)))
    }
  }

  func testProviderProxyRequiresProviderAndOnlyAcceptsCodex() {
    XCTAssertThrowsError(try decodePayload(providerFields: #""providerProxy": "codex","#))
    XCTAssertThrowsError(try decodePayload(
      providerFields: providerJSON() + #""providerProxy": "other","#
    ))
  }

  func testSnakeCaseProviderProxyIsNotAnAliasAndAbsentFieldsStayAbsent() throws {
    let snakeCase = try decodePayload(
      providerFields: providerJSON() + #""provider_proxy": "codex","#
    )
    XCTAssertNil(snakeCase.providerProxy)

    let defaultPayload = try decodePayload(providerFields: "")
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultPayload)) as? [String: Any]
    )
    XCTAssertNil(object["provider"])
    XCTAssertNil(object["providerProxy"])
  }

  func testProviderBackendCompatibilityAndOverlapWarning() throws {
    let configuration = try AgentProviderConfiguration(name: "local", baseUrl: "https://provider.example/v1")
    for backend in [NodeExecutionBackend.cursorCliAgent, .officialCursorSDK] {
      let diagnostics = validateAgentNodePayload(AgentNodePayload(
        id: "worker",
        executionBackend: backend,
        model: "model",
        provider: configuration
      ))
      XCTAssertTrue(diagnostics.contains { $0.severity == .error && $0.path == "node.provider" })
    }
    for backend in [
      NodeExecutionBackend.officialOpenAISDK,
      .officialAnthropicSDK,
      .officialGeminiSDK
    ] {
      XCTAssertTrue(validateAgentNodePayload(AgentNodePayload(
        id: "worker",
        executionBackend: backend,
        model: "model",
        provider: configuration
      )).isEmpty)
    }

    let claudeProxyDiagnostics = validateAgentNodePayload(AgentNodePayload(
      id: "worker",
      executionBackend: .claudeCodeAgent,
      model: "model",
      provider: configuration,
      providerProxy: .codex
    ))
    XCTAssertTrue(claudeProxyDiagnostics.contains { $0.path == "node.providerProxy" })

    let overlapDiagnostics = validateAgentNodePayload(AgentNodePayload(
      id: "worker",
      executionBackend: .claudeCodeAgent,
      model: "model",
      agentEnvironment: ["ANTHROPIC_BASE_URL": AgentEnvironmentBinding(value: "https://old.example/v1")],
      provider: configuration
    ))
    XCTAssertEqual(overlapDiagnostics.first?.severity, .warning)
    XCTAssertTrue(validateAgentNodePayload(AgentNodePayload(
      id: "worker",
      executionBackend: .codexAgent,
      model: "model"
    )).isEmpty)
  }

  func testPublicProviderConstructionEnforcesDecodeInvariants() {
    XCTAssertThrowsError(try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://user:secret@provider.example/v1"
    ))
    XCTAssertThrowsError(try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://provider.example/v1?token=inline-secret"
    ))
    XCTAssertThrowsError(try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://provider.example/v1#inline-secret"
    ))
    XCTAssertThrowsError(try AgentProviderConfiguration(
      name: "Uppercase",
      baseUrl: "https://provider.example/v1"
    ))
    XCTAssertThrowsError(try AgentProviderConfiguration(
      name: "openrouter",
      baseUrl: "https://provider.example/v1",
      apiKeyEnv: "RIELA_AGENT_BACKEND"
    ))
  }

  func testProviderNameBackendEventMetadataRoundTrips() throws {
    let event = WorkflowRunEvent(
      type: .backendEvent,
      workflowId: "workflow",
      sessionId: "session",
      stepId: "step",
      nodeId: "worker",
      backendEventType: "turn.started",
      backendEventMetadata: ["provider_name": .string("openrouter")]
    )
    let roundTrip = try JSONDecoder().decode(
      WorkflowRunEvent.self,
      from: JSONEncoder().encode(event)
    )
    XCTAssertEqual(roundTrip.backendEventMetadata?["provider_name"], .string("openrouter"))

    let defaultEvent = WorkflowRunEvent(
      type: .backendEvent,
      workflowId: "workflow",
      sessionId: "session",
      stepId: "step",
      nodeId: "worker",
      backendEventType: "turn.started"
    )
    let defaultObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(defaultEvent)) as? [String: Any]
    )
    XCTAssertNil(defaultObject["backendEventMetadata"])
  }

  private func decodePayload(providerFields: String) throws -> AgentNodePayload {
    try JSONDecoder().decode(AgentNodePayload.self, from: Data("""
      {
        "id": "worker",
        "executionBackend": "codex-agent",
        "model": "model",
        \(providerFields)
        "variables": {}
      }
      """.utf8))
  }

  private func providerJSON(
    name: String = "openrouter",
    baseUrl: String = "https://provider.example/v1",
    apiKeyEnv: String? = nil
  ) -> String {
    let apiKeyField = apiKeyEnv.map { #", "apiKeyEnv": "\#($0)""# } ?? ""
    return #""provider": { "name": "\#(name)", "baseUrl": "\#(baseUrl)"\#(apiKeyField) },"#
  }
}
