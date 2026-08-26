import Foundation
import GoogleServiceGatewayCore
import RielaAdapters
import RielaAddonSupport
import RielaAddons
import RielaCore
import RielaKaibaAddons
import RielaMemory

func makeProductionNodeAdapter(
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
  codexSupervisorModeEnabled: Bool = false
) -> any NodeAdapter {
  let gatewayFactory: NodeAdapterFactory = {
    AgentGatewayNodeAdapter(
      executableName: environmentValue("RIELA_AGENT_GATEWAY_EXECUTABLE", environment: environment)
        ?? "agent-gateway",
      environment: environment,
      codexSupervisorModeEnabled: codexSupervisorModeEnabled
    )
  }
  return DispatchingNodeAdapter(
    configuration: DispatchingNodeAdapterConfiguration(
      registry: [
        .codexAgent: gatewayFactory,
        .claudeCodeAgent: gatewayFactory,
        .cursorCliAgent: gatewayFactory,
        .officialOpenAISDK: gatewayFactory,
        .officialAnthropicSDK: gatewayFactory,
        .officialGeminiSDK: gatewayFactory,
        .officialCursorSDK: gatewayFactory
      ]
    )
  )
}

func makeScenarioBackedNodeAdapter(
  scenarioPath: String?,
  workingDirectory: String,
  autoImprove: Bool = false,
  codexSupervisorModeEnabled: Bool = false,
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) throws -> any NodeAdapter {
  guard let scenarioPath else {
    return makeProductionNodeAdapter(
      environment: environment,
      codexSupervisorModeEnabled: codexSupervisorModeEnabled
    )
  }
  let fallback = DeterministicLocalNodeAdapter()
  let scenario = try WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
    scenarioPath,
    relativeTo: URL(fileURLWithPath: workingDirectory)
  ).path)
  return autoImprove
    ? SupervisedScenarioNodeAdapter(scenario: scenario, fallback: fallback)
    : ScenarioNodeAdapter(scenario: scenario, fallback: fallback)
}

func makeScenarioBackedStdioNodeExecutor(
  scenarioPath: String?,
  workingDirectory: String
) throws -> any WorkflowStdioNodeExecuting {
  let fallback = LocalWorkflowStdioNodeExecutor()
  guard let scenarioPath else {
    return fallback
  }
  let scenario = try WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
    scenarioPath,
    relativeTo: URL(fileURLWithPath: workingDirectory)
  ).path)
  return ScenarioWorkflowStdioNodeExecutor(scenario: scenario, fallback: fallback)
}

func makeScenarioBackedAddonResolver(
  scenarioPath: String?,
  workingDirectory: String,
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) async throws -> any WorkflowAddonResolving {
  let workingDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
  let fallback = try await makeProductionAddonResolver(
    workingDirectory: workingDirectoryURL,
    environment: environment,
    mockScenarioPath: scenarioPath
  )
  guard let scenarioPath else {
    return fallback
  }
  let scenario = try WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
    scenarioPath,
    relativeTo: URL(fileURLWithPath: workingDirectory)
  ).path)
  return ScenarioWorkflowAddonResolver(scenario: scenario, fallback: fallback)
}

func makeProductionAddonResolver(
  workingDirectory: URL,
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
  mockScenarioPath: String? = nil
) async throws -> any WorkflowAddonResolving {
  let workflowTaskExecutor = DefaultGeneratedWorkflowTaskExecutor(
    runner: CommandGeneratedWorkflowTaskRunner(mockScenarioPath: mockScenarioPath)
  )
  let builtin = BuiltinWorkflowAddonResolver(
    environment: environment,
    workingDirectory: workingDirectory,
    workflowTaskExecutor: workflowTaskExecutor
  )
  let registrations = try await installedContainerAddonRegistrations(workingDirectory: workingDirectory)
  guard !registrations.isEmpty else {
    return builtin
  }
  let container = ContainerWorkflowAddonResolver(
    registrations: registrations,
    workingDirectory: workingDirectory,
    environment: environment
  )
  return CompositeWorkflowAddonResolver(primary: builtin, fallback: container)
}

func installedContainerAddonRegistrations(workingDirectory: URL) async throws -> [ContainerAddonRegistration] {
  let loader = FileWorkflowPackageManifestLoader()
  let parsed = try ParsedParityOptions(["--scope", "auto", "--working-dir", workingDirectory.path])
  var registrations: [ContainerAddonRegistration] = []
  var seen = Set<String>()
  for root in packageRoots(parsed: parsed, workingDirectory: workingDirectory)
    where FileManager.default.fileExists(atPath: root.path) {
    for manifestURL in try packageManifestURLs(in: root) {
      let packageRoot = manifestURL.deletingLastPathComponent()
      let manifest = try await loader.loadManifest(from: manifestURL)
      appendContainerAddonRegistrations(
        manifest: manifest,
        packageRoot: packageRoot,
        registrations: &registrations,
        seen: &seen
      )
    }
  }
  for manifestURL in try sharedAddonManifestURLs() {
    let packageRoot = manifestURL.deletingLastPathComponent()
    let manifest = try await loader.loadManifest(from: manifestURL)
    appendContainerAddonRegistrations(
      manifest: manifest,
      packageRoot: packageRoot,
      registrations: &registrations,
      seen: &seen
    )
  }
  return registrations
}

private func appendContainerAddonRegistrations(
  manifest: WorkflowPackageManifest,
  packageRoot: URL,
  registrations: inout [ContainerAddonRegistration],
  seen: inout Set<String>
) {
  for addon in manifest.nodeAddons {
    guard addon.execution?.kind == .container,
      let contentDigest = addon.contentDigest
    else {
      continue
    }
    let execution = addon.execution
    guard execution?.image != nil || execution?.containerfilePath != nil else {
      continue
    }
    let identity = "\(addon.name)\u{0}\(addon.version)\u{0}\(contentDigest)"
    guard seen.insert(identity).inserted else {
      continue
    }
    registrations.append(ContainerAddonRegistration(
      packageName: manifest.name,
      addonName: addon.name,
      version: addon.version,
      packageRoot: packageRoot,
      addonRoot: packageRoot.appendingPathComponent(addon.sourcePath, isDirectory: true).standardizedFileURL,
      entrypoint: execution?.entrypoint,
      containerfilePath: execution?.containerfilePath,
      image: execution?.image,
      imageDigest: execution?.imageDigest,
      contentDigest: contentDigest,
      capabilities: addon.capabilities
    ))
  }
}

actor ScenarioWorkflowStdioNodeExecutor: WorkflowStdioNodeExecuting {
  private let scenario: WorkflowMockScenario
  private let fallback: any WorkflowStdioNodeExecuting
  private var counts: [String: Int] = [:]
  private let requiresScenarioResponse: Bool

  init(
    scenario: WorkflowMockScenario,
    fallback: any WorkflowStdioNodeExecuting,
    requiresScenarioResponse: Bool = false
  ) {
    self.scenario = scenario
    self.fallback = fallback
    self.requiresScenarioResponse = requiresScenarioResponse
  }

  func execute(
    _ input: WorkflowStdioNodeExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> WorkflowStdioNodeExecutionResult {
    guard let sequence = scenario.responses[input.nodeId] else {
      if requiresScenarioResponse {
        throw AdapterExecutionError(.invalidOutput, "mock scenario is missing a response for stdio node '\(input.nodeId)'")
      }
      return try await fallback.execute(input, context: context)
    }
    guard !sequence.isEmpty || !requiresScenarioResponse else {
      throw AdapterExecutionError(.invalidOutput, "mock scenario response sequence is empty for stdio node '\(input.nodeId)'")
    }
    let count = (counts[input.nodeId] ?? 0) + 1
    counts[input.nodeId] = count
    let response = sequence.isEmpty ? MockNodeResponse() : sequence[min(count - 1, sequence.count - 1)]
    if response.fail == true {
      throw AdapterExecutionError(.providerError, "scenario forced failure for stdio node '\(input.nodeId)'")
    }
    return WorkflowStdioNodeExecutionResult(payload: response.payload ?? [:])
  }

  func consumedResponseCounts() -> [String: Int] { counts }
}

actor ScenarioWorkflowAddonResolver: WorkflowAddonResolving, WorkflowAddonFinalizationAcknowledging,
  WorkflowAddonTerminalRecording {
  private let scenario: WorkflowMockScenario
  private let fallback: any WorkflowAddonResolving
  private var counts: [String: Int] = [:]
  private let requiresScenarioResponse: Bool

  init(
    scenario: WorkflowMockScenario,
    fallback: any WorkflowAddonResolving,
    requiresScenarioResponse: Bool = false
  ) {
    self.scenario = scenario
    self.fallback = fallback
    self.requiresScenarioResponse = requiresScenarioResponse
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard let sequence = scenario.responses[input.nodeId] else {
      if requiresScenarioResponse {
        throw AdapterExecutionError(.invalidOutput, "mock scenario is missing a response for add-on node '\(input.nodeId)'")
      }
      return try await fallback.execute(input, context: context)
    }
    guard !sequence.isEmpty || !requiresScenarioResponse else {
      throw AdapterExecutionError(.invalidOutput, "mock scenario response sequence is empty for add-on node '\(input.nodeId)'")
    }
    let count = (counts[input.nodeId] ?? 0) + 1
    counts[input.nodeId] = count
    let response = sequence.isEmpty ? MockNodeResponse() : sequence[min(count - 1, sequence.count - 1)]
    if response.fail == true {
      throw AdapterExecutionError(.providerError, "scenario forced failure for add-on node '\(input.nodeId)'")
    }
    return AdapterExecutionOutput(
      provider: response.provider ?? "scenario-mock",
      model: response.model ?? input.addon.name,
      promptText: response.promptText ?? "",
      completionPassed: response.completionPassed ?? true,
      when: response.when ?? ["always": true],
      payload: response.payload ?? [:]
    )
  }

  func consumedResponseCounts() -> [String: Int] { counts }

  func acknowledgeAcceptedFinalization(_ token: WorkflowAddonFinalizationToken) async throws {
    guard let acknowledger = fallback as? any WorkflowAddonFinalizationAcknowledging else {
      return
    }
    try await acknowledger.acknowledgeAcceptedFinalization(token)
  }

  func recordTerminalFinalization(
    workflowExecutionId: String,
    stepExecutionIds: [String]
  ) async throws {
    guard let recorder = fallback as? any WorkflowAddonTerminalRecording else {
      return
    }
    try await recorder.recordTerminalFinalization(
      workflowExecutionId: workflowExecutionId,
      stepExecutionIds: stepExecutionIds
    )
  }
}

typealias GeminiAddonAdapterFactory = @Sendable (AgentGatewayAdapterConfiguration) async throws -> any NodeAdapter
typealias OpenAIAddonAdapterFactory = @Sendable (AgentGatewayAdapterConfiguration) async throws -> any NodeAdapter
typealias AnthropicAddonAdapterFactory = @Sendable (AgentGatewayAdapterConfiguration) async throws -> any NodeAdapter
typealias CursorAddonAdapterFactory = @Sendable (AgentGatewayAdapterConfiguration) async throws -> any NodeAdapter
typealias GoogleServiceGatewayAddonClientFactory = @Sendable (String) -> any GoogleServiceGatewayAddonClient

private enum BuiltinSDKWorker: String {
  case codex = "riela/codex-sdk-worker"
  case claude = "riela/claude-sdk-worker"
  case cursor = "riela/cursor-sdk-worker"

  var executionBackend: NodeExecutionBackend {
    switch self {
    case .codex:
      .officialOpenAISDK
    case .claude:
      .officialAnthropicSDK
    case .cursor:
      .officialCursorSDK
    }
  }

  var provider: String {
    switch self {
    case .codex:
      "openai"
    case .claude:
      "anthropic"
    case .cursor:
      "cursor-api"
    }
  }
}

private struct SDKWorkerProviderDefaults {
  var name: String
  var baseURL: String
  var apiKeyEnvironment: String
}

struct BuiltinWorkflowAddonResolver: WorkflowAddonResolving {
  var environment: [String: String]
  var workingDirectory: URL
  var workflowTaskExecutor: any GeneratedWorkflowTaskExecuting
  var openAIAdapterFactory: OpenAIAddonAdapterFactory
  var anthropicAdapterFactory: AnthropicAddonAdapterFactory
  var cursorAdapterFactory: CursorAddonAdapterFactory
  var geminiAdapterFactory: GeminiAddonAdapterFactory
  var gitCommandRunner: any GitCommandRunning
  var gitExecutableURL: URL
  var gitExecutablePolicy: GitExecutablePolicy
  var gitFinalizationStore: GitFinalizationStore
  var gitFailureInjector: any GitFinalizationFailureInjecting
  var gitPushTransportPolicy: any GitPushTransportValidating
  var googleServiceGatewayClientFactory: GoogleServiceGatewayAddonClientFactory

  init(
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    workflowTaskExecutor: any GeneratedWorkflowTaskExecuting = DefaultGeneratedWorkflowTaskExecutor(),
    openAIAdapterFactory: @escaping OpenAIAddonAdapterFactory = { $0.makeAdapter() },
    anthropicAdapterFactory: @escaping AnthropicAddonAdapterFactory = { $0.makeAdapter() },
    cursorAdapterFactory: @escaping CursorAddonAdapterFactory = { $0.makeAdapter() },
    geminiAdapterFactory: @escaping GeminiAddonAdapterFactory = { $0.makeAdapter() },
    gitCommandRunner: any GitCommandRunning = FoundationGitCommandRunner(),
    gitExecutableURL: URL = GitExecutablePolicy.versionOneURL,
    gitExecutablePolicy: GitExecutablePolicy = GitExecutablePolicy(),
    gitFinalizationStore: GitFinalizationStore = GitFinalizationStore(),
    gitFailureInjector: any GitFinalizationFailureInjecting = NoGitFinalizationFailureInjector(),
    gitPushTransportPolicy: any GitPushTransportValidating = VersionOneGitPushTransportPolicy(),
    googleServiceGatewayClientFactory: @escaping GoogleServiceGatewayAddonClientFactory = {
      LiveGoogleServiceGatewayAddonClient(accessToken: $0)
    }
  ) {
    self.environment = environment
    self.workingDirectory = workingDirectory.standardizedFileURL
    self.workflowTaskExecutor = workflowTaskExecutor
    self.openAIAdapterFactory = openAIAdapterFactory
    self.anthropicAdapterFactory = anthropicAdapterFactory
    self.cursorAdapterFactory = cursorAdapterFactory
    self.geminiAdapterFactory = geminiAdapterFactory
    self.gitCommandRunner = gitCommandRunner
    self.gitExecutableURL = gitExecutableURL
    self.gitExecutablePolicy = gitExecutablePolicy
    self.gitFinalizationStore = gitFinalizationStore
    self.gitFailureInjector = gitFailureInjector
    self.gitPushTransportPolicy = gitPushTransportPolicy
    self.googleServiceGatewayClientFactory = googleServiceGatewayClientFactory
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.name.hasPrefix("riela/") || input.addon.name.hasPrefix("kaiba/") else {
      throw AdapterExecutionError(.providerError, "missing add-on resolver for '\(input.addon.name)'")
    }
    if input.addon.name == "riela/gemini-sdk-worker" {
      return try await executeGeminiSDKWorker(input, context: context)
    }
    if let sdkWorker = BuiltinSDKWorker(rawValue: input.addon.name) {
      return try await executeSDKWorker(input, sdkWorker: sdkWorker, context: context)
    }
    if input.addon.name == "riela/chat-persona-router" {
      return try executeChatPersonaRouter(input)
    }
    if input.addon.name == "riela/chat-reply-worker" {
      return try executeChatReplyWorker(input)
    }
    if input.addon.name == "riela/chat-persona-memory-read" {
      return try executeChatPersonaMemoryRead(input)
    }
    if input.addon.name == "riela/chat-persona-memory-write" {
      return try executeChatPersonaMemoryWrite(input)
    }
    if input.addon.name == "riela/workflow-create-register-run" {
      return try await executeWorkflowCreateRegisterRun(input)
    }
    if let gitAddon = BuiltinGitAddon(rawValue: input.addon.name) {
      return try executeGitAddon(input, operation: gitAddon, deadline: context.deadline)
    }
    if input.addon.name == "riela/x-digest" {
      return try executeXDigest(input)
    }
    if let wrikeGatewayAddon = BuiltinWrikeGatewayAddon(rawValue: input.addon.name) {
      return try executeWrikeGatewayAddon(input, operation: wrikeGatewayAddon, context: context)
    }
    if let googleServiceGatewayAddon = BuiltinGoogleServiceGatewayAddon(rawValue: input.addon.name) {
      return try await executeGoogleServiceGatewayAddon(
        input,
        capability: googleServiceGatewayAddon,
        context: context
      )
    }
    if let gmailGatewayCLIAddon = BuiltinGmailGatewayCLIAddon(rawValue: input.addon.name) {
      return try executeGmailGatewayCLIAddon(input, operation: gmailGatewayCLIAddon, context: context)
    }
    if let googleAnalyticsGatewayAddon = BuiltinGoogleAnalyticsGatewayAddon(rawValue: input.addon.name) {
      return try executeGoogleAnalyticsGatewayAddon(input, operation: googleAnalyticsGatewayAddon, context: context)
    }
    if let googleDocumentsGatewayAddon = BuiltinGoogleDocumentsGatewayAddon(rawValue: input.addon.name) {
      return try executeGoogleDocumentsGatewayAddon(input, operation: googleDocumentsGatewayAddon, context: context)
    }
    if input.addon.name == "riela/gmail-digest" {
      return try await executeGmailDigest(input)
    }
    if input.addon.name == "riela/time-signal" {
      return try executeTimeSignal(input)
    }
    if input.addon.name == FileMarkdownAddon.name {
      return try executeFileMarkdownConvert(input, context: context)
    }
    if input.addon.name == "riela/apple-notes-list" {
      return try executeAppleNotesList(input, context: context)
    }
    if input.addon.name == "riela/apple-mail-list" || input.addon.name == "riela/apple-mail-message" {
      return try executeAppleMailAddon(input, context: context)
    }
    if input.addon.name == "riela/apple-notifications-list" {
      return try executeAppleNotificationsList(input, context: context)
    }
    if input.addon.name == "riela/apple-notification-post" {
      return try executeAppleNotificationPost(input, context: context)
    }
    if input.addon.name == "riela/apple-notifications-dismiss" {
      return try executeAppleNotificationsDismiss(input, context: context)
    }
    if [
      "riela/apple-note-get",
      "riela/apple-note-create",
      "riela/apple-note-update-body",
      "riela/apple-note-delete",
      "riela/apple-note-move"
    ].contains(input.addon.name) {
      return try executeAppleNotesCrud(input, context: context)
    }
    if BuiltinAppleReminderAddon(rawValue: input.addon.name) != nil {
      return try executeAppleReminderAddon(input, context: context)
    }
    if let calendarAddon = BuiltinCalendarAddon(rawValue: input.addon.name) {
      return try executeCalendarAddon(input, operation: calendarAddon, context: context)
    }
    if AppleClockAlarmOperation(addonName: input.addon.name) != nil {
      return try executeAppleClockAlarm(input, context: context)
    }
    if let appleGatewayAdminAddon = BuiltinAppleGatewayAdminAddon(rawValue: input.addon.name) {
      return try executeAppleGatewayAdmin(input, operation: appleGatewayAdminAddon, context: context)
    }
    // Kaiba add-ons live in their own target; nothing kaiba-typed crosses back.
    if KaibaAddonCatalog.handles(input.addon.name) {
      return try await KaibaAddonCatalog.execute(input, environment: environment)
    }
    if let memoryAddon = BuiltinMemoryAddon(rawValue: input.addon.name) {
      return try executeMemoryAddon(input, operation: memoryAddon)
    }
    if let keyValueAddon = BuiltinKeyValueAddon(rawValue: input.addon.name) {
      return try executeKeyValueAddon(input, operation: keyValueAddon)
    }
    if Self.deferredContainerAddons.contains(input.addon.name) {
      return AdapterExecutionOutput(
        provider: "riela-builtin-addon",
        model: input.addon.name,
        promptText: "",
        completionPassed: true,
        payload: [
          "status": .string("ok"),
          "addon": .string(input.addon.name),
          "stepId": .string(input.stepId)
        ]
      )
    }
    if let renamed = Self.renamedAddons[input.addon.name] {
      throw AdapterExecutionError(
        .providerError,
        "add-on '\(input.addon.name)' was renamed to '\(renamed)'; update the workflow node to use the new add-on name"
      )
    }
    throw AdapterExecutionError(
      .providerError,
      "missing add-on resolver for '\(input.addon.name)'"
    )
  }

  private static let deferredContainerAddons: Set<String> = [
    "riela/gmail-gateway-read",
    "riela/x-gateway-read"
  ]

  private static let renamedAddons: [String: String] = [
    "riela/mail-gateway-read": "riela/gmail-gateway-read",
    "riela/mail-gateway": "riela/gmail-gateway"
  ]

  private func executeSDKWorker(
    _ input: WorkflowAddonExecutionInput,
    sdkWorker: BuiltinSDKWorker,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    guard let model = nonEmptyString(config["model"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) config.model is required")
    }
    guard let promptTemplate = nonEmptyString(config["promptTemplate"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) config.promptTemplate is required")
    }

    let variables = addonVariables(for: input)
    let promptText = renderPromptTemplate(promptTemplate, variables: variables)
    let systemPromptText = nonEmptyString(config["systemPromptTemplate"]).map {
      renderPromptTemplate($0, variables: variables)
    }
    let resolvedEnvironment = try resolveAddonEnvironmentOverlay(input.addon.env, runtimeEnvironment: environment)
    var nodeVariables = objectValue(config["variables"]) ?? [:]
    if let maxTokens = config["maxTokens"] {
      nodeVariables["maxTokens"] = maxTokens
    }
    let adapterInput = AdapterExecutionInput(
      node: AgentNodePayload(
        id: input.nodeId,
        nodeType: .addon,
        executionBackend: sdkWorker.executionBackend,
        model: model,
        provider: try sdkWorkerProvider(sdkWorker, config: config),
        variables: nodeVariables
      ),
      promptText: promptText,
      systemPromptText: systemPromptText,
      arguments: input.variables,
      mergedVariables: variables
    )
    let adapter = try await sdkAdapter(for: sdkWorker, environment: resolvedEnvironment)
    let output = try await adapter.execute(adapterInput, context: context)
    let text = (nonEmptyString(output.payload["text"]) ?? nonEmptyString(output.payload["replyText"]) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) returned empty reply text")
    }

    var payload = output.payload
    payload["status"] = .string("ok")
    payload["addon"] = .string(input.addon.name)
    payload["stepId"] = .string(input.stepId)
    payload["executionBackend"] = .string(sdkWorker.executionBackend.rawValue)
    payload["text"] = .string(text)
    payload["replyText"] = .string(text)
    payload["liveExecution"] = .bool(true)
    payload.removeValue(forKey: "inputFilterSkipped")

    return AdapterExecutionOutput(
      provider: output.provider,
      model: output.model,
      promptText: output.promptText,
      completionPassed: output.completionPassed,
      when: output.when,
      payload: payload,
      usage: output.usage
    )
  }

  private func sdkWorkerProvider(
    _ worker: BuiltinSDKWorker,
    config: JSONObject
  ) throws -> AgentProviderConfiguration {
    let defaults: SDKWorkerProviderDefaults = switch worker {
    case .codex: SDKWorkerProviderDefaults(
      name: "openai",
      baseURL: "https://api.openai.com/v1",
      apiKeyEnvironment: "OPENAI_API_KEY"
    )
    case .claude: SDKWorkerProviderDefaults(
      name: "anthropic",
      baseURL: "https://api.anthropic.com/v1",
      apiKeyEnvironment: "ANTHROPIC_API_KEY"
    )
    case .cursor: SDKWorkerProviderDefaults(
      name: "cursor-api",
      baseURL: "https://api.cursor.com/v1",
      apiKeyEnvironment: "CURSOR_API_KEY"
    )
    }
    return try AgentProviderConfiguration(
      name: defaults.name,
      baseUrl: nonEmptyString(config["baseURL"]) ?? defaults.baseURL,
      apiKeyEnv: nonEmptyString(config["apiKeyEnv"]) ?? defaults.apiKeyEnvironment
    )
  }

  private func sdkAdapter(
    for sdkWorker: BuiltinSDKWorker,
    environment: [String: String]
  ) async throws -> any NodeAdapter {
    switch sdkWorker {
    case .codex:
      return try await openAIAdapterFactory(.init(processEnvironment: environment))
    case .claude:
      return try await anthropicAdapterFactory(.init(processEnvironment: environment))
    case .cursor:
      return try await cursorAdapterFactory(.init(processEnvironment: environment))
    }
  }

  private func executeChatPersonaRouter(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    let personas = chatPersonas(from: input.addon.config ?? [:])
    guard let firstPersonaId = personas.first?.id else {
      throw AdapterExecutionError(
        .policyBlocked,
        "riela/chat-persona-router config.personas must contain at least one persona"
      )
    }
    let defaultPersonaId = nonEmptyString(input.addon.config?["defaultPersonaId"]) ?? firstPersonaId
    guard personas.contains(where: { $0.id == defaultPersonaId }) else {
      throw AdapterExecutionError(
        .policyBlocked,
        "riela/chat-persona-router config.defaultPersonaId must reference a configured persona"
      )
    }
    let request = routerRequestText(input)
    var matchedPersonaId: String?
    var matchedLocation: Int?
    for persona in personas {
      guard let location = persona.matchLocation(in: request) else {
        continue
      }
      if let currentLocation = matchedLocation {
        if location < currentLocation || (location == currentLocation && persona.id < (matchedPersonaId ?? persona.id)) {
          matchedPersonaId = persona.id
          matchedLocation = location
        }
      } else {
        matchedPersonaId = persona.id
        matchedLocation = location
      }
    }
    let target = matchedPersonaId ?? defaultPersonaId
    let knownTargetIds = Set(personas.map(\.id))
    var when = Dictionary(uniqueKeysWithValues: knownTargetIds.map { ("target_\($0)", $0 == target) })
    when["always"] = true
    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "target": .string(target),
      "reason": .string(target == defaultPersonaId ? "No persona alias matched, so the default persona was selected." : "Persona alias matched the incoming chat text.")
    ]
    for (key, value) in when {
      payload[key] = .bool(value)
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private struct ChatPersona {
    var id: String
    var aliases: [String]

    func matchLocation(in request: String) -> Int? {
      let normalizedRequest = request.lowercased()
      return aliases.compactMap { alias in
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedAlias.isEmpty,
          let range = normalizedRequest.range(of: normalizedAlias)
        else {
          return nil
        }
        return normalizedRequest.distance(from: normalizedRequest.startIndex, to: range.lowerBound)
      }.min()
    }
  }

  private func chatPersonas(from config: JSONObject) -> [ChatPersona] {
    guard case let .array(personaValues)? = config["personas"] else {
      return []
    }
    return personaValues.compactMap { value in
      guard case let .object(persona) = value,
        let id = nonEmptyString(persona["id"])
      else {
        return nil
      }
      var aliases = [id]
      if let name = nonEmptyString(persona["name"]) {
        aliases.append(name)
      }
      if case let .array(aliasValues)? = persona["aliases"] {
        aliases.append(contentsOf: aliasValues.compactMap(nonEmptyString))
      }
      return ChatPersona(id: id, aliases: aliases)
    }
  }

  private func routerRequestText(_ input: WorkflowAddonExecutionInput) -> String {
    for object in [
      input.resolvedInputPayload,
      objectValue(input.variables["humanInput"]) ?? [:],
      objectValue(input.variables["workflowInput"]) ?? [:],
      objectValue(objectValue(input.variables["event"])?["input"]) ?? [:]
    ] {
      if let request = nonEmptyString(object["request"]) ?? nonEmptyString(object["text"]) {
        return request
      }
    }
    return ""
  }

  private func executeChatReplyWorker(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported riela/chat-reply-worker version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    guard let textTemplate = nonEmptyString(config["textTemplate"]) else {
      throw AdapterExecutionError(.policyBlocked, "riela/chat-reply-worker config.textTemplate is required")
    }

    var variables = addonVariables(for: input)
    variables["inbox"] = .object([
      "latest": .object([
        "output": .object([
          "payload": .object(input.resolvedInputPayload)
        ])
      ])
    ])
    let renderedText = renderPromptTemplate(textTemplate, variables: variables)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let text = renderedText.isEmpty ? (chatReplyFallbackText(input.resolvedInputPayload) ?? "") : renderedText
    guard !text.isEmpty else {
      throw AdapterExecutionError(.invalidOutput, "riela/chat-reply-worker rendered empty reply text")
    }

    let replyAs = nonEmptyString(config["replyAsTemplate"]).map {
      renderPromptTemplate($0, variables: variables)
    }?.trimmingCharacters(in: .whitespacesAndNewlines)

    var payload = input.resolvedInputPayload
    payload.removeValue(forKey: "runtime")
    payload["status"] = .string("ok")
    payload["addon"] = .string(input.addon.name)
    payload["stepId"] = .string(input.stepId)
    payload["text"] = .string(text)
    payload["replyText"] = .string(text)
    payload["dispatchStatus"] = .string("intent-only")
    if let replyAs, !replyAs.isEmpty {
      payload["replyAs"] = .string(replyAs)
    }

    var when: [String: Bool] = ["always": true]
    for (key, value) in input.resolvedInputPayload {
      if case let .bool(flag) = value {
        when[key] = flag
      }
    }

    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      when: when,
      payload: payload
    )
  }

  private func chatReplyFallbackText(_ payload: JSONObject) -> String? {
    if let text = nonEmptyString(payload["replyText"]) ?? nonEmptyString(payload["text"]) {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if case let .object(nested)? = payload["payload"] {
      return nonEmptyString(nested["replyText"]) ?? nonEmptyString(nested["text"])
    }
    return nil
  }

  private func executeGeminiSDKWorker(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported riela/gemini-sdk-worker version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    guard let model = nonEmptyString(config["model"]) else {
      throw AdapterExecutionError(.policyBlocked, "riela/gemini-sdk-worker config.model is required")
    }
    guard let promptTemplate = nonEmptyString(config["promptTemplate"]) else {
      throw AdapterExecutionError(.policyBlocked, "riela/gemini-sdk-worker config.promptTemplate is required")
    }

    let resolvedEnvironment = try resolveAddonEnvironment(input.addon.env, runtimeEnvironment: environment)
    let apiKeyEnv = resolvedEnvironment["GOOGLE_API_KEY"]?.isEmpty == false ? "GOOGLE_API_KEY" : "GEMINI_API_KEY"
    guard resolvedEnvironment[apiKeyEnv]?.isEmpty == false else {
      throw AdapterExecutionError(.policyBlocked, "riela/gemini-sdk-worker requires addon.env.GEMINI_API_KEY or addon.env.GOOGLE_API_KEY")
    }

    var variables = addonVariables(for: input)
    if let inlineDataParts = config["inlineDataParts"] {
      variables["geminiInlineDataParts"] = inlineDataParts
    }

    let adapter = try await geminiAdapterFactory(.init(processEnvironment: resolvedEnvironment))
    let node = AgentNodePayload(
      id: input.nodeId,
      nodeType: .addon,
      executionBackend: .officialGeminiSDK,
      model: model,
      provider: try AgentProviderConfiguration(
        name: "gemini",
        baseUrl: nonEmptyString(config["baseURL"]) ?? "https://generativelanguage.googleapis.com/v1beta",
        apiKeyEnv: apiKeyEnv
      )
    )
    return try await adapter.execute(
      AdapterExecutionInput(
        node: node,
        promptText: renderPromptTemplate(promptTemplate, variables: variables),
        systemPromptText: nonEmptyString(config["systemPromptTemplate"]).map {
          renderPromptTemplate($0, variables: variables)
        },
        arguments: input.variables,
        mergedVariables: variables
      ),
      context: context
    )
  }
}
