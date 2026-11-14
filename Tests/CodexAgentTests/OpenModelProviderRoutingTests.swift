import XCTest
@testable import CodexAgent
@testable import RielaAdapters
@testable import RielaCore

final class CodexOpenModelProviderRoutingTests: XCTestCase {
  func testDefaultCommandArgumentsRemainExact() throws {
    let command = try CodexAgentCommandBuilder().buildCommand(for: input())
    XCTAssertEqual(command.configuration.arguments, [
      "codex", "exec", "--json", "--model", "model", "--disable", "unified_exec", "--", "-"
    ])
    XCTAssertEqual(command.configuration.environment, ["RIELA_AGENT_BACKEND": "codex-agent"])
    XCTAssertTrue(command.metadata.isEmpty)
  }

  func testProviderOverridesPrecedeUserArgumentsAndContainNoSecretValue() throws {
    let secret = "provider-secret-value"
    let builder = CodexAgentCommandBuilder(additionalArguments: ["-c", "model_provider=user-override"])
    let command = try builder.buildCommand(for: input(
      effort: .high,
      provider: try AgentProviderConfiguration(
        name: "openrouter",
        baseUrl: "https://provider.example/v1",
        apiKeyEnv: "CUSTOM_PROVIDER_CREDENTIAL"
      ),
      agentEnvironment: ["CUSTOM_PROVIDER_CREDENTIAL": secret]
    ))

    XCTAssertEqual(command.configuration.arguments, [
      "codex", "exec", "--json", "--model", "model",
      "-c", #"model_reasoning_effort="high""#,
      "-c", "model_provider=openrouter",
      "-c", "model_providers.openrouter.name=openrouter",
      "-c", "model_providers.openrouter.base_url=https://provider.example/v1",
      "-c", "model_providers.openrouter.env_key=CUSTOM_PROVIDER_CREDENTIAL",
      "-c", "model_provider=user-override",
      "--disable", "unified_exec", "--", "-"
    ])
    XCTAssertFalse(command.configuration.arguments.contains { $0.contains(secret) })
    XCTAssertEqual(command.metadata["provider_name"], .string("openrouter"))
  }

  func testProgrammaticProviderProxyWithoutProviderIsRejected() {
    XCTAssertThrowsError(try CodexAgentCommandBuilder().buildCommand(for: AdapterExecutionInput(
      node: AgentNodePayload(
        id: "worker",
        executionBackend: .codexAgent,
        model: "model",
        providerProxy: .codex
      ),
      promptText: "hello"
    ))) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput)
    }
  }

  private func input(
    effort: NodeReasoningEffort? = nil,
    provider: AgentProviderConfiguration? = nil,
    agentEnvironment: [String: String] = [:]
  ) -> AdapterExecutionInput {
    AdapterExecutionInput(
      node: AgentNodePayload(
        id: "worker",
        executionBackend: .codexAgent,
        model: "model",
        effort: effort,
        provider: provider
      ),
      promptText: "hello",
      agentEnvironment: agentEnvironment
    )
  }
}
