import RielaAppSupport
import RielaCore

struct AskModelRequest: Equatable, Sendable {
  var vendor: String?
  var providerInstanceId: String?
  var model: String?
  var effort: String?
}

struct AskResolvedModel: Equatable, Sendable {
  let vendor: RielaAppAssistantVendor
  let backend: NodeExecutionBackend
  let providerInstanceId: String
  let model: String?
  let effort: String?
  let providerName: String?
  let providerProxy: String?
  let apiKeyEnvironment: String?
  let warnings: [String]
}

struct AskSelectionError: Error, Equatable, Sendable {
  let code: String
  let message: String
}

enum AskModelSelection {
  static func resolve(
    settings: RielaAppAssistantSettings, request: AskModelRequest, catalog: [CatalogInstance],
    environment: [String: String], requiresAvailability: Bool = true
  ) throws -> AskResolvedModel {
    let vendor: RielaAppAssistantVendor
    let entry: CatalogInstance
    let defaultModel: String?
    if let instanceId = request.providerInstanceId {
      guard let match = catalog.first(where: { $0.instance.instanceId == instanceId }) else {
        throw missingInstance(instanceId)
      }
      guard let matchingVendor = RielaAppAssistantVendor.selectableVendors.first(where: {
        $0.executionBackend == match.instance.driver
      }) else {
        throw AskSelectionError(
          code: "ask_provider_unsupported", message: "Ask Riela does not support \(match.instance.driver.rawValue)"
        )
      }
      vendor = matchingVendor
      entry = match
      defaultModel = match.models.first?.id
    } else {
      vendor = try resolveVendor(request.vendor, fallback: settings.vendor, environment: environment, requiresAvailability: requiresAvailability)
      let backend = vendor.executionBackend
      guard let match = catalog.first(where: { $0.instance.builtIn && $0.instance.driver == backend }) else {
        throw missingInstance(backend.rawValue)
      }
      entry = match
      defaultModel = settings.selectedModel(for: vendor)
    }

    let selectedModel = request.model ?? defaultModel
    let model = selectedModel == "" || selectedModel == ModelSentinel.defaultModel ? nil : selectedModel
    let options = entry.models.first { $0.id == model }?.options
    if let effort = request.effort, let allowed = options?.reasoningEfforts,
      !allowed.isEmpty && !allowed.contains(effort) {
      throw AskSelectionError(
        code: "ask_option_unsupported", message: "Reasoning effort '\(effort)' is not supported for \(model ?? "this model")"
      )
    }

    let instance = entry.instance
    let apiKeyEnvironment = requiresAvailability
      ? try availableKey(for: vendor, instance: instance, environment: environment)
      : instance.apiKeyEnvironment
    let warnings = if let model, options == nil {
      [BotsService.unknownModelWarning(model, driver: instance.driver)]
    } else {
      [String]()
    }
    return AskResolvedModel(
      vendor: vendor, backend: instance.driver, providerInstanceId: instance.instanceId,
      model: model, effort: request.effort, providerName: instance.providerName, providerProxy: instance.providerProxy,
      apiKeyEnvironment: apiKeyEnvironment, warnings: warnings
    )
  }

  private static func resolveVendor(
    _ rawVendor: String?, fallback: RielaAppAssistantVendor, environment: [String: String], requiresAvailability: Bool
  ) throws -> RielaAppAssistantVendor {
    let vendor: RielaAppAssistantVendor
    if let rawVendor {
      guard let requested = RielaAppAssistantVendor(rawValue: rawVendor) else {
        throw AskSelectionError(code: "ask_vendor_unknown", message: "Unknown assistant vendor '\(rawVendor)'")
      }
      vendor = requested
    } else {
      vendor = fallback
    }
    do {
      return try RielaWebAssistantProvider.resolve(vendor, environment: environment)
    } catch {
      if !requiresAvailability { return .openAIAPI }
      throw AskSelectionError(
        code: "ask_vendor_unavailable", message: (error as? AdapterExecutionError)?.message ?? String(describing: error)
      )
    }
  }

  private static func availableKey(
    for vendor: RielaAppAssistantVendor, instance: ProviderInstance, environment: [String: String]
  ) throws -> String? {
    if let executable = vendor.executableName {
      guard RielaWebAssistantProvider.executablePath(named: executable, environment: environment) != nil else {
        throw AskSelectionError(
          code: "ask_vendor_unavailable", message: "Assistant executable '\(executable)' was not found on PATH"
        )
      }
      return instance.apiKeyEnvironment
    }
    let names = instance.apiKeyEnvironment.map { [$0] } ?? vendor.apiKeyEnvironmentNames
    guard let key = names.first(where: { environment[$0]?.isEmpty == false }) else {
      throw AskSelectionError(
        code: "ask_vendor_unavailable", message: "Set \(names.joined(separator: " or ")) to use \(vendor.displayName)"
      )
    }
    return instance.apiKeyEnvironment ?? (key == vendor.apiKeyEnvironmentNames.first ? nil : key)
  }

  private static func missingInstance(_ id: String) -> AskSelectionError {
    AskSelectionError(code: "provider_instance_not_found", message: "Provider instance '\(id)' was not found")
  }
}
