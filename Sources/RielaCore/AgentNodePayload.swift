import Foundation

public struct AgentNodePayload: Codable, Equatable, Sendable {
  public var id: String
  public var description: String?
  public var nodeType: NodeType?
  public var executionBackend: NodeExecutionBackend?
  public var backendPolicy: WorkflowBackendPolicy?
  public var model: String
  public var modelFreeze: Bool
  public var effort: NodeReasoningEffort?
  public var workingDirectory: String?
  public var command: WorkflowCommandExecution?
  public var container: WorkflowContainerExecution?
  public var sleep: WorkflowSleepExecution?
  public var sandbox: WorkflowExecutionSandbox?
  public var agentSandbox: AgentSandboxMode?
  public var agentToolPolicy: AgentToolPolicy?
  public var agentEnvironment: [String: AgentEnvironmentBinding]
  public var baseURL: String?
  public var apiKeyEnvironment: String?
  public var provider: AgentProviderConfiguration?
  public var providerProxy: AgentProviderProxy?
  public var systemPromptTemplate: String?
  public var systemPromptTemplateFile: String?
  public var promptTemplate: String?
  public var promptTemplateFile: String?
  public var sessionStartPromptTemplate: String?
  public var sessionStartPromptTemplateFile: String?
  public var sessionPolicy: WorkflowStepSessionPolicy?
  public var promptVariants: [String: NodePromptVariant]?
  public var memories: [WorkflowMemoryDeclaration]?
  public var variables: JSONObject
  public var input: NodeInputContract?
  public var output: NodeOutputContract?

  public init(
    id: String,
    description: String? = nil,
    nodeType: NodeType? = nil,
    executionBackend: NodeExecutionBackend? = nil,
    backendPolicy: WorkflowBackendPolicy? = nil,
    model: String,
    modelFreeze: Bool = false,
    effort: NodeReasoningEffort? = nil,
    workingDirectory: String? = nil,
    command: WorkflowCommandExecution? = nil,
    container: WorkflowContainerExecution? = nil,
    sleep: WorkflowSleepExecution? = nil,
    sandbox: WorkflowExecutionSandbox? = nil,
    agentSandbox: AgentSandboxMode? = nil,
    agentToolPolicy: AgentToolPolicy? = nil,
    agentEnvironment: [String: AgentEnvironmentBinding] = [:],
    baseURL: String? = nil,
    apiKeyEnvironment: String? = nil,
    provider: AgentProviderConfiguration? = nil,
    providerProxy: AgentProviderProxy? = nil,
    systemPromptTemplate: String? = nil,
    systemPromptTemplateFile: String? = nil,
    promptTemplate: String? = nil,
    promptTemplateFile: String? = nil,
    sessionStartPromptTemplate: String? = nil,
    sessionStartPromptTemplateFile: String? = nil,
    sessionPolicy: WorkflowStepSessionPolicy? = nil,
    promptVariants: [String: NodePromptVariant]? = nil,
    memories: [WorkflowMemoryDeclaration]? = nil,
    variables: JSONObject = [:],
    input: NodeInputContract? = nil,
    output: NodeOutputContract? = nil
  ) {
    self.id = id
    self.description = description
    self.nodeType = nodeType
    self.executionBackend = executionBackend
    self.backendPolicy = backendPolicy
    self.model = model.isEmpty && baseURL != nil ? "custom" : model
    self.modelFreeze = modelFreeze
    self.effort = effort
    self.workingDirectory = workingDirectory
    self.command = command
    self.container = container
    self.sleep = sleep
    self.sandbox = sandbox
    self.agentSandbox = agentSandbox
    self.agentToolPolicy = agentToolPolicy
    self.agentEnvironment = agentEnvironment
    self.baseURL = baseURL
    self.apiKeyEnvironment = apiKeyEnvironment
    self.provider = provider
    self.providerProxy = providerProxy
    self.systemPromptTemplate = systemPromptTemplate
    self.systemPromptTemplateFile = systemPromptTemplateFile
    self.promptTemplate = promptTemplate
    self.promptTemplateFile = promptTemplateFile
    self.sessionStartPromptTemplate = sessionStartPromptTemplate
    self.sessionStartPromptTemplateFile = sessionStartPromptTemplateFile
    self.sessionPolicy = sessionPolicy
    self.promptVariants = promptVariants
    self.memories = memories
    self.variables = variables
    self.input = input
    self.output = output
  }

  enum CodingKeys: String, CodingKey {
    case id
    case description
    case nodeType
    case executionBackend
    case backendPolicy
    case model
    case modelFreeze
    case effort
    case workingDirectory
    case command
    case container
    case sleep
    case sandbox
    case agentSandbox
    case agentToolPolicy
    case agentEnvironment
    case baseURL
    case apiKeyEnvironment
    case provider
    case providerProxy
    case systemPromptTemplate
    case systemPromptTemplateFile
    case promptTemplate
    case promptTemplateFile
    case sessionStartPromptTemplate
    case sessionStartPromptTemplateFile
    case sessionPolicy
    case promptVariants
    case memories
    case variables
    case input
    case output
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.description = try container.decodeIfPresent(String.self, forKey: .description)
    self.nodeType = try container.decodeIfPresent(NodeType.self, forKey: .nodeType)
    self.executionBackend = try container.decodeIfPresent(NodeExecutionBackend.self, forKey: .executionBackend)
    self.backendPolicy = try container.decodeIfPresent(WorkflowBackendPolicy.self, forKey: .backendPolicy)
    self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
    self.apiKeyEnvironment = try container.decodeIfPresent(String.self, forKey: .apiKeyEnvironment)
    self.model = try container.decodeIfPresent(String.self, forKey: .model)
      ?? (baseURL == nil ? "" : "custom")
    self.modelFreeze = try container.decodeIfPresent(Bool.self, forKey: .modelFreeze) ?? false
    self.effort = try container.decodeIfPresent(NodeReasoningEffort.self, forKey: .effort)
    self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
    self.command = try container.decodeIfPresent(WorkflowCommandExecution.self, forKey: .command)
    self.container = try container.decodeIfPresent(WorkflowContainerExecution.self, forKey: .container)
    self.sleep = try container.decodeIfPresent(WorkflowSleepExecution.self, forKey: .sleep)
    self.sandbox = try container.decodeIfPresent(WorkflowExecutionSandbox.self, forKey: .sandbox)
    self.agentSandbox = try container.decodeIfPresent(AgentSandboxMode.self, forKey: .agentSandbox)
    self.agentToolPolicy = try container.decodeIfPresent(AgentToolPolicy.self, forKey: .agentToolPolicy)
    self.agentEnvironment = try container.decodeIfPresent(
      [String: AgentEnvironmentBinding].self,
      forKey: .agentEnvironment
    ) ?? [:]
    for key in agentEnvironment.keys {
      guard isValidEnvironmentVariableName(key) else {
        throw DecodingError.dataCorruptedError(
          forKey: .agentEnvironment,
          in: container,
          debugDescription: "agentEnvironment target '\(key)' must be a valid environment variable name"
        )
      }
      guard !reservedAgentEnvironmentNames.contains(key) else {
        throw DecodingError.dataCorruptedError(
          forKey: .agentEnvironment,
          in: container,
          debugDescription: "agentEnvironment target '\(key)' is reserved by Riela"
        )
      }
    }
    self.provider = try container.decodeIfPresent(AgentProviderConfiguration.self, forKey: .provider)
    self.providerProxy = try container.decodeIfPresent(AgentProviderProxy.self, forKey: .providerProxy)
    if providerProxy != nil, provider == nil {
      throw DecodingError.dataCorruptedError(
        forKey: .providerProxy,
        in: container,
        debugDescription: "providerProxy requires provider"
      )
    }
    self.systemPromptTemplate = try container.decodeIfPresent(String.self, forKey: .systemPromptTemplate)
    self.systemPromptTemplateFile = try container.decodeIfPresent(String.self, forKey: .systemPromptTemplateFile)
    self.promptTemplate = try container.decodeIfPresent(String.self, forKey: .promptTemplate)
    self.promptTemplateFile = try container.decodeIfPresent(String.self, forKey: .promptTemplateFile)
    self.sessionStartPromptTemplate = try container.decodeIfPresent(String.self, forKey: .sessionStartPromptTemplate)
    self.sessionStartPromptTemplateFile = try container.decodeIfPresent(String.self, forKey: .sessionStartPromptTemplateFile)
    self.sessionPolicy = try container.decodeIfPresent(WorkflowStepSessionPolicy.self, forKey: .sessionPolicy)
    self.promptVariants = try container.decodeIfPresent([String: NodePromptVariant].self, forKey: .promptVariants)
    self.memories = try container.decodeIfPresent([WorkflowMemoryDeclaration].self, forKey: .memories)
    self.variables = try container.decodeIfPresent(JSONObject.self, forKey: .variables) ?? [:]
    self.input = try container.decodeIfPresent(NodeInputContract.self, forKey: .input)
    self.output = try container.decodeIfPresent(NodeOutputContract.self, forKey: .output)
  }
}
