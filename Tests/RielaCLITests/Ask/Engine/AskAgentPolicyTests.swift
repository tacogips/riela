import RielaAppSupport
import RielaCore
import Testing
@testable import RielaCLI

struct AskAgentPolicyTests {
  private static let workingDirectory = "/ask-scratch"

  @Test func cliPresetsExpandToNoToolsArguments() throws {
    let codex = try payload(for: .codexCLI)
    let claude = try payload(for: .claudeCodeCLI)

    #expect(codex.node.agentToolPolicy?.codexArguments ==
      AgentToolPolicyPresetArguments.cliArguments(.noTools, backend: .codexAgent, sessionReuse: false))
    #expect(claude.node.agentToolPolicy?.claudeArguments ==
      AgentToolPolicyPresetArguments.cliArguments(.noTools, backend: .claudeCodeAgent, sessionReuse: false))
    for result in [codex, claude] {
      #expect(result.node.agentSandbox == .readOnly)
      #expect(result.node.agentToolPolicy?.preset == nil)
      #expect(!result.limitedPolicy)
    }
  }

  @Test(arguments: [RielaAppAssistantVendor.openAIAPI, .anthropicAPI])
  func apiPresetsStayInThePayload(_ vendor: RielaAppAssistantVendor) throws {
    let result = try payload(for: vendor)

    #expect(result.node.agentToolPolicy?.preset == .noTools)
    #expect(result.node.agentSandbox == nil)
    #expect(!result.limitedPolicy)
  }

  @Test func claudeMCPAllowsOnlyAskTools() throws {
    let result = try payload(for: .claudeCodeCLI, transport: .mcp)
    let policy = try #require(result.node.agentToolPolicy)
    let allowed = try #require(policy.claudeArguments.firstIndex(of: "--allowedTools"))
    #expect(policy.claudeArguments.dropFirst(allowed + 1).first ==
      AskToolSet.all.map { "mcp__riela-ask__\($0.name)" }.joined(separator: ","))
    #expect(policy.preset == nil)
    #expect(policy.claudeArguments.contains("--strict-mcp-config"))
    #expect(!policy.claudeArguments.contains("--mcp-config"))
    // Plan mode would refuse the Ask MCP tools; built-in tools are off instead.
    #expect(result.node.agentSandbox == nil)
    #expect(policy.claudeArguments.starts(with: ["--tools", ""]))
  }

  @Test func codexMCPPreapprovesTheAskServerTools() throws {
    let result = try payload(for: .codexCLI, transport: .mcp)
    let arguments = try #require(result.node.agentToolPolicy?.codexArguments)
    // `codex exec` refuses an MCP call that would need an approval prompt.
    #expect(arguments.contains(#"mcp_servers.riela-ask.default_tools_approval_mode="approve""#))
    #expect(!arguments.contains("mcp_servers={}"))
    #expect(result.node.agentSandbox == .readOnly)
  }

  @Test func cursorCLIUsesLimitedReadOnlyPolicy() throws {
    let result = try payload(for: .cursorCLI)

    #expect(result.node.agentToolPolicy == nil)
    #expect(result.node.agentSandbox == .readOnly)
    #expect(result.limitedPolicy)
  }

  @Test(arguments: [RielaAppAssistantVendor.codexCLI, .claudeCodeCLI, .cursorCLI, .openAIAPI, .anthropicAPI])
  func backendPayloadUsesGivenDirectoryAndNoAgentEnvironment(_ vendor: RielaAppAssistantVendor) throws {
    let result = try payload(for: vendor)

    #expect(result.node.executionBackend == vendor.executionBackend)
    #expect(result.node.workingDirectory == Self.workingDirectory)
    #expect(result.node.agentEnvironment.isEmpty)
    #expect(result.node.model == ModelSentinel.defaultModel)
    #expect(result.node.provider == nil)
  }

  @Test func chosenModelEffortAndCustomProviderReachThePayload() throws {
    let resolved = AskResolvedModel(
      vendor: .openAIAPI, backend: .officialOpenAISDK, providerInstanceId: "team/openai",
      model: "team-model", effort: "high", providerName: "team",
      providerProxy: "https://fixture.invalid/v1", apiKeyEnvironment: "TEAM_KEY", warnings: []
    )
    let result = try AskAgentPolicy.payload(
      resolved: resolved, transport: .rounds, workingDirectory: Self.workingDirectory
    )

    #expect(result.node.model == "team-model")
    #expect(result.node.effort == .high)
    #expect(result.node.provider?.name == "team")
    #expect(result.node.provider?.baseUrl == "https://fixture.invalid/v1")
    #expect(result.node.provider?.apiKeyEnv == "TEAM_KEY")
    #expect(result.node.apiKeyEnvironment == "TEAM_KEY")
    #expect(result.node.agentEnvironment.isEmpty)
  }

  private func payload(
    for vendor: RielaAppAssistantVendor, transport: AskToolTransport = .rounds
  ) throws -> (node: AgentNodePayload, limitedPolicy: Bool) {
    let backend = vendor.executionBackend
    let resolved = AskResolvedModel(
      vendor: vendor, backend: backend, providerInstanceId: backend.rawValue, model: nil,
      effort: nil, providerName: nil, providerProxy: nil, apiKeyEnvironment: nil, warnings: []
    )
    return try AskAgentPolicy.payload(resolved: resolved, transport: transport, workingDirectory: Self.workingDirectory)
  }
}
