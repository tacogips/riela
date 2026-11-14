import XCTest
@testable import ClaudeCodeAgent
@testable import RielaAdapters
@testable import RielaCore

final class ClaudeOpenModelProviderRoutingTests: XCTestCase {
  func testDefaultCommandEnvironmentRemainsExact() throws {
    let command = try ClaudeCodeAgentCommandBuilder().buildCommand(for: input())
    XCTAssertEqual(command.configuration.environment, ["RIELA_AGENT_BACKEND": "claude-code-agent"])
    XCTAssertTrue(command.metadata.isEmpty)
  }

  func testProviderEnvironmentOverridesNodeBindingsAndResolvesToken() throws {
    let command = try ClaudeCodeAgentCommandBuilder().buildCommand(for: input(
      provider: try AgentProviderConfiguration(
        name: "openrouter",
        baseUrl: "https://provider.example/v1",
        apiKeyEnv: "CUSTOM_PROVIDER_CREDENTIAL"
      ),
      agentEnvironment: [
        "ANTHROPIC_BASE_URL": "https://old.example/v1",
        "CUSTOM_PROVIDER_CREDENTIAL": "provider-secret-value"
      ]
    ))

    XCTAssertEqual(command.configuration.environment["ANTHROPIC_BASE_URL"], "https://provider.example/v1")
    XCTAssertEqual(command.configuration.environment["ANTHROPIC_AUTH_TOKEN"], "provider-secret-value")
    XCTAssertEqual(command.configuration.environment["RIELA_AGENT_BACKEND"], "claude-code-agent")
    XCTAssertEqual(command.metadata["provider_name"], .string("openrouter"))
    XCTAssertFalse(command.configuration.arguments.contains { $0.contains("provider-secret-value") })
  }

  func testProviderWithoutAPIKeyAndMissingRequiredRuntimeValue() throws {
    let noKey = try ClaudeCodeAgentCommandBuilder().buildCommand(for: input(
      provider: try AgentProviderConfiguration(name: "local", baseUrl: "http://localhost:11434/v1")
    ))
    XCTAssertEqual(noKey.configuration.environment["ANTHROPIC_BASE_URL"], "http://localhost:11434/v1")
    XCTAssertNil(noKey.configuration.environment["ANTHROPIC_AUTH_TOKEN"])

    XCTAssertThrowsError(try ClaudeCodeAgentCommandBuilder().buildCommand(for: input(
      provider: try AgentProviderConfiguration(
        name: "openrouter",
        baseUrl: "https://provider.example/v1",
        apiKeyEnv: "MISSING_PROVIDER_CREDENTIAL"
      )
    ))) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("MISSING_PROVIDER_CREDENTIAL") == true)
    }
  }

  func testProgrammaticProviderProxyWithoutProviderIsRejected() {
    XCTAssertThrowsError(try ClaudeCodeAgentCommandBuilder().buildCommand(for: AdapterExecutionInput(
      node: AgentNodePayload(
        id: "worker",
        executionBackend: .claudeCodeAgent,
        model: "model",
        providerProxy: .codex
      ),
      promptText: "hello"
    ))) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput)
    }
  }

  private func input(
    provider: AgentProviderConfiguration? = nil,
    agentEnvironment: [String: String] = [:]
  ) -> AdapterExecutionInput {
    AdapterExecutionInput(
      node: AgentNodePayload(
        id: "worker",
        executionBackend: .claudeCodeAgent,
        model: "model",
        provider: provider
      ),
      promptText: "hello",
      agentEnvironment: agentEnvironment
    )
  }
}
