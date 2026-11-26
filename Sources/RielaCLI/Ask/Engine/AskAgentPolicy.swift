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
      agentSandbox: sandbox(backend: backend, transport: transport),
      agentToolPolicy: policy,
      apiKeyEnvironment: resolved.apiKeyEnvironment,
      provider: provider,
      providerProxy: proxy
    )
    return (node, backend == .cursorCliAgent || backend == .antigravityAgent)
  }

  /// Claude Code maps the read-only sandbox to plan mode, which refuses MCP
  /// tool calls. On the `mcp` transport its built-in tools are already off
  /// (`--tools ""`), the MCP config is strict, and only the Ask tools are
  /// allowed, so the turn stays read-only without plan mode.
  private static func sandbox(backend: NodeExecutionBackend, transport: AskToolTransport) -> AgentSandboxMode? {
    guard backend.cliAgentBackend != nil else { return nil }
    return backend == .claudeCodeAgent && transport == .mcp ? nil : .readOnly
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
      // `codex exec` never prompts, so an MCP call that needs approval is
      // refused. Pre-approve the Ask server's tools; they are all read-only.
      arguments.append(contentsOf: [
        "-c", #"mcp_servers.\#(AskToolServerHandoff.serverName).default_tools_approval_mode="approve""#
      ])
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
    case .antigravityAgent, .officialGeminiSDK: ("gemini", "https://generativelanguage.googleapis.com/v1beta")
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
