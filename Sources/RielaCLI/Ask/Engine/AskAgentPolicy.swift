import RielaCore

enum AskAgentPolicy {
  static func payload(
    resolved: AskResolvedModel, transport: AskToolTransport, workingDirectory: String
  ) throws -> (node: AgentNodePayload, limitedPolicy: Bool) {
    let backend = resolved.backend
    let policy = try toolPolicy(backend: backend, transport: transport)
    let proxy = resolved.providerProxy.flatMap(AgentProviderProxy.init(rawValue:))
    if proxy == .codex, backend != .codexAgent {
      throw AdapterExecutionError(.invalidInput, "The Codex provider proxy requires the Codex backend")
    }
    let provider = try providerConfiguration(resolved, usesNamedProxy: proxy != nil)
    let node = AgentNodePayload(
      id: "ask",
      executionBackend: backend,
      model: resolved.model ?? ModelSentinel.defaultModel,
      effort: resolved.effort.flatMap(NodeReasoningEffort.init(rawValue:)),
      workingDirectory: workingDirectory,
      agentSandbox: backend.cliAgentBackend == nil ? nil : .readOnly,
      agentToolPolicy: policy,
      apiKeyEnvironment: resolved.apiKeyEnvironment,
      provider: provider,
      providerProxy: proxy
    )
    return (node, backend == .cursorCliAgent)
  }

  private static func toolPolicy(backend: NodeExecutionBackend, transport: AskToolTransport) throws -> AgentToolPolicy? {
    if transport == .rounds {
      let supportsPreset = AgentToolPolicyPresetArguments.isSupported(.noTools, backend: backend)
      return try resolveAgentToolPolicy(
        supportsPreset ? AgentToolPolicy(preset: .noTools) : nil,
        executionBackend: backend, sessionReuse: false, variables: [:]
      )
    }

    guard var arguments = AgentToolPolicyPresetArguments.cliArguments(
      .noTools, backend: backend, sessionReuse: false, keepClientMCPServers: true
    ) else {
      throw AdapterExecutionError(.policyBlocked, "Unsupported Ask Riela tool transport")
    }
    if backend == .codexAgent {
      return AgentToolPolicy(mode: .backendArguments, codexArguments: arguments)
    }
    let allowed = AskToolSet.all.map { "mcp__\(AskToolServerHandoff.serverName)__\($0.name)" }.joined(separator: ",")
    arguments.append(contentsOf: ["--allowedTools", allowed])
    return AgentToolPolicy(mode: .backendArguments, claudeArguments: arguments)
  }

  private static func providerConfiguration(
    _ resolved: AskResolvedModel, usesNamedProxy: Bool
  ) throws -> AgentProviderConfiguration? {
    guard resolved.providerName != nil || resolved.providerProxy != nil else { return nil }
    let defaults: (name: String, baseURL: String) = switch resolved.backend {
    case .codexAgent, .officialOpenAISDK: ("openai", "https://api.openai.com/v1")
    case .claudeCodeAgent, .officialAnthropicSDK: ("anthropic", "https://api.anthropic.com/v1")
    case .cursorCliAgent, .officialCursorSDK: ("cursor-api", "https://api.cursor.com/v1")
    case .officialGeminiSDK: ("gemini", "https://generativelanguage.googleapis.com/v1beta")
    }
    let name = resolved.providerName ?? defaults.name
    let defaultURL = name == "openrouter" ? ModelCatalogService.openRouterBaseURL : defaults.baseURL
    return try AgentProviderConfiguration(
      name: name,
      baseUrl: (!usesNamedProxy ? resolved.providerProxy : nil) ?? defaultURL,
      apiKeyEnv: resolved.apiKeyEnvironment
    )
  }
}
