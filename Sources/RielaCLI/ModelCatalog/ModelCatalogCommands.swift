import ArgumentParser
import Foundation
import RielaCore
import RielaGraphQL

struct ModelCatalogOptions: ParsableArguments, Sendable {
  @Option var provider: String?
  @Option var id: String?
  @Option var driver: String?
  @Option var label: String?
  @Option var account: String?
  @Option var providerName: String?
  @Option var providerProxy: String?
  @Option(name: .customLong("api-key-env")) var apiKeyEnvironment: String?
  @Option var customModel: [String] = []
  @Flag var clearCustomModels = false
  @Option var sessionStore: String?
  @Option var scope: String?
  @Option(name: .customLong("working-dir")) var workingDirectory: String?
  @Option var output: String?
  @OptionGroup var remotes: ParsedRemoteSelector

  func botService() throws -> BotsService {
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    guard let scope = WorkflowScope(rawValue: scope ?? "auto") else {
      throw CLIUsageError("--scope must be auto, project or user")
    }
    let root = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: sessionStore, scope: scope,
      workingDirectory: workingDirectory ?? FileManager.default.currentDirectoryPath, environment: environment
    )
    return BotsService(
      workingDirectory: workingDirectory ?? FileManager.default.currentDirectoryPath,
      sessionStoreRoot: root, environment: environment
    )
  }

  func saveInput(id: String) throws -> SaveProviderInstanceInput {
    guard !clearCustomModels || customModel.isEmpty else {
      throw CLIUsageError("--clear-custom-models cannot be combined with --custom-model")
    }
    var input = SaveProviderInstanceInput(instanceId: id)
    input.driver = driver
    input.label = label
    input.account = account
    input.providerName = providerName
    input.providerProxy = providerProxy
    input.apiKeyEnvironment = apiKeyEnvironment
    if clearCustomModels || !customModel.isEmpty { input.customModels = customModel }
    return input
  }
}

struct ModelCatalogCommands {
  var serviceOverride: ModelCatalogService?
  var remoteTransport = RemoteHTTP.production

  func run(kind: ScopedCommandKind, options: CLICommandOptions) async -> CLICommandResult {
    do {
      let parsed: ModelCatalogOptions
      do {
        parsed = try ModelCatalogOptions.parse(options.arguments)
      } catch {
        throw CLIUsageError(ModelCatalogOptions.message(for: error))
      }
      guard options.output == .text || options.output == .json else {
        throw CLIUsageError("\(kind.rawValue) --output must be json or text")
      }
      let action = options.command ?? "list"
      let location = try parsed.botService()
      if let remote = try parsed.remotes.client(for: location, transport: remoteTransport) {
        return try await runRemote(kind: kind, action: action, options: options, parsed: parsed, remote: remote)
      }
      let service = serviceOverride ?? location.modelCatalog
      if kind == .model, ModelClientAction(rawValue: action) == .list, options.target == nil {
        let providers = try parsed.provider.map { [try service.instance(id: $0)] } ?? service.instances()
        return try render(ModelCatalogPayload(providers: providers), options: options) {
          providers.map { header($0) + modelText($0.models) }.joined()
        }
      }
      guard kind == .provider, let providerAction = ProviderClientAction(rawValue: action) else {
        throw CLIUsageError("Unknown \(kind.rawValue) action '\(action)'")
      }
      return try await runProvider(providerAction, options: options, parsed: parsed, service: service)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: String(describing: error))
    }
  }

  private func runRemote(
    kind: ScopedCommandKind, action: String, options: CLICommandOptions,
    parsed: ModelCatalogOptions, remote: SelectedBotRemote
  ) async throws -> CLICommandResult {
    let provider = remote.provider
    let selector = remote.selector
    if kind == .model, action == "list", options.target == nil {
      let result = try await provider.modelCatalog(providerInstanceId: parsed.provider, remote: selector)
      return try render(result, options: options) {
        result.providers.map { header($0) + modelText($0.models) }.joined()
      }
    }
    guard kind == .provider, let command = ProviderClientAction(rawValue: action) else {
      throw CLIUsageError("Unknown \(kind.rawValue) action '\(action)'")
    }
    if command != .list { try remote.requireSingle() }
    switch command {
    case .list:
      guard options.target == nil else { throw CLIUsageError("provider list does not accept an instance id") }
      let result = try await provider.providers(remote: selector)
      return try renderProviders(result.providers, options: options)
    case .refresh:
      var input = RefreshProvidersInput(instanceId: options.target)
      input.remote = selector
      let result = try await provider.refreshProviders(input: input)
      return try renderProviders(result.providers, options: options)
    case .add:
      guard options.target == nil, let id = parsed.id, parsed.driver != nil else {
        throw CLIUsageError("provider add requires --id and --driver")
      }
      return try await saveRemoteProvider(id: id, parsed: parsed, options: options, remote: remote)
    case .show, .update, .remove:
      guard let id = options.target, !id.isEmpty, parsed.id == nil else {
        throw CLIUsageError("provider \(action) requires a positional instance id")
      }
      if command == .show {
        let result = try await provider.provider(instanceId: id, remote: selector)
        return try renderProvider(result.provider, options: options)
      }
      if command == .remove {
        var input = RemoveProviderInstanceInput(instanceId: id)
        input.remote = selector
        let result = try await provider.removeProviderInstance(input: input)
        return try renderProviders(result.providers, options: options)
      }
      _ = try await provider.provider(instanceId: id, remote: selector)
      return try await saveRemoteProvider(id: id, parsed: parsed, options: options, remote: remote)
    }
  }

  private func saveRemoteProvider(
    id: String, parsed: ModelCatalogOptions, options: CLICommandOptions, remote: SelectedBotRemote
  ) async throws -> CLICommandResult {
    var input = try parsed.saveInput(id: id)
    input.remote = remote.selector
    let result = try await remote.provider.saveProviderInstance(input: input)
    return try renderProvider(result.provider, options: options)
  }

  private func runProvider(
    _ action: ProviderClientAction, options: CLICommandOptions, parsed: ModelCatalogOptions, service: ModelCatalogService
  ) async throws -> CLICommandResult {
    switch action {
    case .list:
      guard options.target == nil else { throw CLIUsageError("provider list does not accept an instance id") }
      return try renderProviders(service.instances(), options: options)
    case .refresh:
      return try await renderProviders(service.refresh(instanceId: options.target), options: options)
    case .add:
      guard options.target == nil, let id = parsed.id, parsed.driver != nil else {
        throw CLIUsageError("provider add requires --id and --driver")
      }
      return try renderProvider(service.save(parsed.saveInput(id: id)), options: options)
    case .show, .update, .remove:
      guard let id = options.target, !id.isEmpty, parsed.id == nil else {
        throw CLIUsageError("provider \(action.rawValue) requires a positional instance id")
      }
      if action == .show { return try renderProvider(service.instance(id: id), options: options) }
      if action == .remove { return try renderProviders(service.remove(id: id), options: options) }
      _ = try service.configuredInstance(id: id)
      return try renderProvider(service.save(parsed.saveInput(id: id)), options: options)
    }
  }

  private func renderProvider(_ provider: GraphQLProviderInstance, options: CLICommandOptions) throws -> CLICommandResult {
    try render(ProviderPayload(provider: provider), options: options) {
      header(provider) + modelText(provider.models) + provider.failures.map { "  \($0)\n" }.joined()
    }
  }

  private func renderProviders(
    _ providers: [GraphQLProviderInstance], options: CLICommandOptions
  ) throws -> CLICommandResult {
    try render(ProviderListPayload(providers: providers), options: options) { providers.map(header).joined() }
  }

  private func render(
    _ payload: some Encodable, options: CLICommandOptions, text: () -> String
  ) throws -> CLICommandResult {
    CLICommandResult(
      exitCode: .success,
      stdout: options.output == .json ? try jsonString(BotSurfaceJSON.value(payload)) : text()
    )
  }

  private func header(_ item: GraphQLProviderInstance) -> String {
    let probe = item.probedAt.map { date in
      let age = max(0, item.origin.observedAt.timeIntervalSince(date))
      return RoutineStore.timestamp(date) + " (" + String(format: "%.0f", age) + "s ago)"
    } ?? "-"
    let fields = [
      item.instanceId, item.driver.rawValue, item.label, item.account,
      item.availability?.rawValue ?? "unknown", item.authentication?.rawValue ?? "unknown", item.version, probe
    ]
    return fields.compactMap { $0 }.joined(separator: "  ") + remoteHostText(item.origin) + "\n"
  }

  private func modelText(_ models: [GraphQLCatalogModel]) -> String {
    models.map { model in
      let fields = [
        model.id, model.sources.joined(separator: ","), model.reasoningEfforts.joined(separator: ","),
        model.serviceTiers.joined(separator: ","), model.modes.joined(separator: ","),
        model.observedAt.map(RoutineStore.timestamp) ?? "-"
      ]
      return "  " + fields.joined(separator: "  ") + "\n"
    }.joined()
  }
}
