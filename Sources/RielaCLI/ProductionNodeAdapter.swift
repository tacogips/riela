import ClaudeCodeAgent
import CodexAgent
import CursorCLIAgent
import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
import RielaMemory

func makeProductionNodeAdapter(
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) -> any NodeAdapter {
  DispatchingNodeAdapter(
    configuration: DispatchingNodeAdapterConfiguration(
      registry: [
        .codexAgent: {
          CodexAgentAdapter(
            executableName: environmentValue("RIELA_CODEX_AGENT_EXECUTABLE", environment: environment) ?? "codex"
          )
        },
        .claudeCodeAgent: {
          ClaudeCodeAgentAdapter(
            executableName: environmentValue("RIELA_CLAUDE_CODE_AGENT_EXECUTABLE", environment: environment) ?? "claude"
          )
        },
        .cursorCliAgent: {
          CursorCLIAgentAdapter(
            executableName: environmentValue("RIELA_CURSOR_CLI_AGENT_EXECUTABLE", environment: environment) ?? "cursor-agent"
          )
        }
      ]
    )
  )
}

func makeScenarioBackedNodeAdapter(
  scenarioPath: String?,
  workingDirectory: String,
  autoImprove: Bool = false,
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) throws -> any NodeAdapter {
  guard let scenarioPath else {
    return makeProductionNodeAdapter(environment: environment)
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
  let fallback = try await makeProductionAddonResolver(workingDirectory: workingDirectoryURL, environment: environment)
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
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) async throws -> any WorkflowAddonResolving {
  let builtin = BuiltinWorkflowAddonResolver(environment: environment)
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

  init(scenario: WorkflowMockScenario, fallback: any WorkflowStdioNodeExecuting) {
    self.scenario = scenario
    self.fallback = fallback
  }

  func execute(
    _ input: WorkflowStdioNodeExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> WorkflowStdioNodeExecutionResult {
    guard let sequence = scenario.responses[input.nodeId] else {
      return try await fallback.execute(input, context: context)
    }
    let count = (counts[input.nodeId] ?? 0) + 1
    counts[input.nodeId] = count
    let response = sequence.isEmpty ? MockNodeResponse() : sequence[min(count - 1, sequence.count - 1)]
    if response.fail == true {
      throw AdapterExecutionError(.providerError, "scenario forced failure for stdio node '\(input.nodeId)'")
    }
    return WorkflowStdioNodeExecutionResult(payload: response.payload ?? [:])
  }
}

actor ScenarioWorkflowAddonResolver: WorkflowAddonResolving {
  private let scenario: WorkflowMockScenario
  private let fallback: any WorkflowAddonResolving
  private var counts: [String: Int] = [:]

  init(scenario: WorkflowMockScenario, fallback: any WorkflowAddonResolving) {
    self.scenario = scenario
    self.fallback = fallback
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard let sequence = scenario.responses[input.nodeId] else {
      return try await fallback.execute(input, context: context)
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
}

typealias GeminiAddonAdapterFactory = @Sendable (OfficialSDKAdapterConfiguration) async throws -> any NodeAdapter
typealias OpenAIAddonAdapterFactory = @Sendable (OfficialSDKAdapterConfiguration) async throws -> any NodeAdapter
typealias AnthropicAddonAdapterFactory = @Sendable (AnthropicSDKAdapterConfiguration) async throws -> any NodeAdapter
typealias CursorAddonAdapterFactory = @Sendable ([String: String]) async throws -> any NodeAdapter

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
      OpenAiSDKAdapter.provider
    case .claude:
      AnthropicSDKAdapter.provider
    case .cursor:
      "official-cursor-sdk"
    }
  }
}

struct BuiltinWorkflowAddonResolver: WorkflowAddonResolving {
  var environment: [String: String]
  var openAIAdapterFactory: OpenAIAddonAdapterFactory
  var anthropicAdapterFactory: AnthropicAddonAdapterFactory
  var cursorAdapterFactory: CursorAddonAdapterFactory
  var geminiAdapterFactory: GeminiAddonAdapterFactory

  init(
    environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
    openAIAdapterFactory: @escaping OpenAIAddonAdapterFactory = { configuration in
      OpenAiSDKAdapter(configuration: configuration)
    },
    anthropicAdapterFactory: @escaping AnthropicAddonAdapterFactory = { configuration in
      AnthropicSDKAdapter(configuration: configuration)
    },
    cursorAdapterFactory: @escaping CursorAddonAdapterFactory = { environment in
      CursorCLIAgentAdapter(environment: environment)
    },
    geminiAdapterFactory: @escaping GeminiAddonAdapterFactory = { configuration in
      GeminiSDKAdapter(configuration: configuration)
    }
  ) {
    self.environment = environment
    self.openAIAdapterFactory = openAIAdapterFactory
    self.anthropicAdapterFactory = anthropicAdapterFactory
    self.cursorAdapterFactory = cursorAdapterFactory
    self.geminiAdapterFactory = geminiAdapterFactory
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.name.hasPrefix("riela/") else {
      throw AdapterExecutionError(.providerError, "missing add-on resolver for '\(input.addon.name)'")
    }
    if input.addon.name == "riela/gemini-sdk-worker" {
      return try await executeGeminiSDKWorker(input, context: context)
    }
    if let sdkWorker = BuiltinSDKWorker(rawValue: input.addon.name) {
      return try await executeSDKWorker(input, sdkWorker: sdkWorker, context: context)
    }
    if input.addon.name == "riela/chat-persona-router" {
      return executeChatPersonaRouter(input)
    }
    if input.addon.name == "riela/chat-reply-worker" {
      return try executeChatReplyWorker(input)
    }
    if input.addon.name == "riela/chat-memory-raw-daily-summary" {
      return try executeChatMemoryRawDailySummary(input)
    }
    if input.addon.name == "riela/chat-persona-memory-read" {
      return try executeChatPersonaMemoryRead(input)
    }
    if input.addon.name == "riela/chat-persona-memory-write" {
      return try executeChatPersonaMemoryWrite(input)
    }
    if input.addon.name == "riela/x-digest" {
      return try executeXDigest(input)
    }
    if input.addon.name == "riela/gmail-digest" {
      return try executeGmailDigest(input)
    }
    if input.addon.name == "riela/time-signal" {
      return try executeTimeSignal(input)
    }
    if let noteAddon = BuiltinNoteAddon(rawValue: input.addon.name) {
      return try await executeNoteAddon(input, operation: noteAddon)
    }
    if let memoryAddon = BuiltinMemoryAddon(rawValue: input.addon.name) {
      return try executeMemoryAddon(input, operation: memoryAddon)
    }
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
    let adapterInput = AdapterExecutionInput(
      node: AgentNodePayload(
        id: input.nodeId,
        nodeType: .addon,
        executionBackend: sdkWorker.executionBackend,
        model: model,
        variables: objectValue(config["variables"]) ?? [:]
      ),
      promptText: promptText,
      systemPromptText: systemPromptText,
      arguments: input.variables,
      mergedVariables: variables
    )
    let adapter = try await sdkAdapter(for: sdkWorker, config: config, environment: resolvedEnvironment)
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

  private func sdkAdapter(
    for sdkWorker: BuiltinSDKWorker,
    config: JSONObject,
    environment: [String: String]
  ) async throws -> any NodeAdapter {
    let officialConfiguration = OfficialSDKAdapterConfiguration(
      apiKeyEnv: nonEmptyString(config["apiKeyEnv"]),
      baseURL: nonEmptyString(config["baseURL"]).flatMap(URL.init(string:)),
      environment: environment
    )
    switch sdkWorker {
    case .codex:
      return try await openAIAdapterFactory(officialConfiguration)
    case .claude:
      let maxTokens = intValue(config["maxTokens"]) ?? 1024
      return try await anthropicAdapterFactory(AnthropicSDKAdapterConfiguration(
        officialSDK: officialConfiguration,
        maxTokens: maxTokens
      ))
    case .cursor:
      return try await cursorAdapterFactory(environment)
    }
  }

  private func executeChatPersonaRouter(_ input: WorkflowAddonExecutionInput) -> AdapterExecutionOutput {
    let personas = chatPersonas(from: input.addon.config ?? [:])
    let defaultPersonaId = nonEmptyString(input.addon.config?["defaultPersonaId"]) ?? personas.first?.id ?? "yui"
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
    let knownTargetIds = Set(personas.map(\.id) + ["yui", "mika", "rina"])
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
      return [
        ChatPersona(id: "yui", aliases: ["yui", "codex"]),
        ChatPersona(id: "mika", aliases: ["mika", "maki", "claude"]),
        ChatPersona(id: "rina", aliases: ["rina", "cursor"])
      ]
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
      if id == "mika" {
        aliases.append("maki")
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

  private func executeMemoryAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinMemoryAddon
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }

    let config = input.addon.config ?? [:]
    let variables = addonVariables(for: input)
    let memoryId = nonEmptyString(config["memoryId"]) ?? nonEmptyString(variables["memoryId"]) ?? "chat-memory"
    let nodeId = nonEmptyString(config["nodeId"]) ?? nonEmptyString(variables["memoryNodeId"]) ?? input.nodeId
    let limit = intValue(config["limit"]) ?? intValue(variables["limit"]) ?? 30
    let workflowInput = memoryAddonJSONObject(variables["workflowInput"])
    let memoryRoot = nonEmptyString(config["memoryRoot"])
      ?? nonEmptyString(variables["memoryRoot"])
      ?? nonEmptyString(workflowInput["memoryRoot"])
    let store = RielaMemoryStore(
      rootDirectory: memoryRoot ?? RielaMemoryStore.defaultRootDirectory()
    )

    switch operation {
    case .save:
      let payload = try memoryPayload(config: config, variables: variables, input: input)
      let tags = try memoryTags(config: config, variables: variables)
      let relatedRecordIds = try memoryRelatedRecordIds(config: config, variables: variables)
      let files = try memoryFileReferences(config: config, variables: variables)
      let record = try store.save(
        memoryId: memoryId,
        workflowId: input.workflowId,
        nodeId: nodeId,
        tags: tags,
        relatedRecordIds: relatedRecordIds,
        files: files,
        payload: payload
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: [
          "saved": .bool(true),
          "record": memoryRecordJSON(record)
        ]
      )
    case .update:
      let recordId = try requiredMemoryRecordId(config: config, variables: variables)
      let payload = try memoryPayload(config: config, variables: variables, input: input)
      let tags = try memoryTags(config: config, variables: variables)
      let relatedRecordIds = try memoryRelatedRecordIds(config: config, variables: variables)
      let files = try memoryUpdateFileReferences(config: config, variables: variables)
      let record = try store.update(
        memoryId: memoryId,
        recordId: recordId,
        workflowId: input.workflowId,
        nodeId: optionalNodeScope(config: config, variables: variables),
        tags: tags,
        relatedRecordIds: relatedRecordIds,
        files: files,
        payload: payload
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: [
          "updated": .bool(true),
          "record": memoryRecordJSON(record)
        ]
      )
    case .load:
      let records = try store.load(
        memoryId: memoryId,
        workflowId: input.workflowId,
        nodeId: optionalNodeScope(config: config, variables: variables),
        limit: limit
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: memoryRecordsPayload(records: records).merging([
          "records": .array(records.map(memoryRecordJSON)),
          "recordsText": .string(memoryRecordsText(records)),
          "limit": .number(Double(limit))
        ]) { _, new in new }
      )
    case .search:
      let patterns = memoryMatchPatterns(config: config, variables: variables)
      let tags = try memoryTags(config: config, variables: variables)
      let relatedRecordIds = try memoryRelatedRecordIds(config: config, variables: variables)
      let records = try store.search(
        memoryId: memoryId,
        options: MemorySearchOptions(
          workflowId: input.workflowId,
          nodeId: optionalNodeScope(config: config, variables: variables),
          matchPatterns: patterns,
          tags: tags,
          relatedRecordIds: relatedRecordIds,
          limit: limit
        )
      )
      return memoryAddonOutput(
        input: input,
        operation: operation,
        memoryId: memoryId,
        databasePath: try store.databasePath(memoryId: memoryId),
        payload: memoryRecordsPayload(records: records).merging([
          "records": .array(records.map(memoryRecordJSON)),
          "recordsText": .string(memoryRecordsText(records)),
          "matchPatterns": .array(patterns.map { .string($0) }),
          "tags": .array(tags.map { .string($0) }),
          "relatedRecordIds": .array(relatedRecordIds.map { .number(Double($0)) }),
          "limit": .number(Double(limit))
        ]) { _, new in new }
      )
    }
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

    let adapter = try await geminiAdapterFactory(
      OfficialSDKAdapterConfiguration(
        apiKeyEnv: apiKeyEnv,
        environment: resolvedEnvironment
      )
    )
    let node = AgentNodePayload(
      id: input.nodeId,
      nodeType: .addon,
      executionBackend: .officialGeminiSDK,
      model: model
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
