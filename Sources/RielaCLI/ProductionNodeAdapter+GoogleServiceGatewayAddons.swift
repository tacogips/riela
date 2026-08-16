import Foundation
import GoogleServiceGatewayCore
import RielaCore

enum BuiltinGoogleServiceGatewayAddon: String {
  case read = "riela/google-service-gateway-read"
  case write = "riela/google-service-gateway-write"
}

protocol GoogleServiceGatewayAddonClient: Sendable {
  func listServices(_ request: ListServicesRequest) async throws -> GoogleServiceGatewayCore.JSONValue
  func getService(project: String, service: String) async throws -> GoogleServiceGatewayCore.JSONValue
  func getOperation(_ operation: String) async throws -> GoogleServiceGatewayCore.JSONValue
  func enable(project: String, service: String, options: MutationOptions) async throws
    -> GoogleServiceGatewayCore.JSONValue
  func disable(
    project: String,
    service: String,
    disableDependents: Bool,
    checkUsage: Bool,
    options: MutationOptions
  ) async throws -> GoogleServiceGatewayCore.JSONValue
  func batchEnable(project: String, services: [String], options: MutationOptions) async throws
    -> GoogleServiceGatewayCore.JSONValue
}

struct LiveGoogleServiceGatewayAddonClient: GoogleServiceGatewayAddonClient {
  private let client: GoogleServiceGatewayClient

  init(accessToken: String) {
    self.client = GoogleServiceGatewayClient(tokenProvider: StaticAccessTokenProvider(token: accessToken))
  }

  func listServices(_ request: ListServicesRequest) async throws -> GoogleServiceGatewayCore.JSONValue {
    try await client.listServices(request).gatewayJSONValue()
  }

  func getService(project: String, service: String) async throws -> GoogleServiceGatewayCore.JSONValue {
    try await client.getService(project: project, service: service).gatewayJSONValue()
  }

  func getOperation(_ operation: String) async throws -> GoogleServiceGatewayCore.JSONValue {
    try await client.getOperation(operation).gatewayJSONValue()
  }

  func enable(
    project: String,
    service: String,
    options: MutationOptions
  ) async throws -> GoogleServiceGatewayCore.JSONValue {
    try await client.enable(project: project, service: service, options: options).gatewayJSONValue()
  }

  func disable(
    project: String,
    service: String,
    disableDependents: Bool,
    checkUsage: Bool,
    options: MutationOptions
  ) async throws -> GoogleServiceGatewayCore.JSONValue {
    try await client.disable(
      project: project,
      service: service,
      disableDependents: disableDependents,
      checkUsage: checkUsage,
      options: options
    ).gatewayJSONValue()
  }

  func batchEnable(
    project: String,
    services: [String],
    options: MutationOptions
  ) async throws -> GoogleServiceGatewayCore.JSONValue {
    try await client.batchEnable(project: project, services: services, options: options).gatewayJSONValue()
  }
}

extension BuiltinWorkflowAddonResolver {
  func executeGoogleServiceGatewayAddon(
    _ input: WorkflowAddonExecutionInput,
    capability: BuiltinGoogleServiceGatewayAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    do {
      return try await GoogleServiceGatewayAddonEngine(
        environment: environment,
        clientFactory: googleServiceGatewayClientFactory
      ).execute(input, capability: capability, context: context)
    } catch let error as GatewayError {
      throw googleServiceAdapterError(error, addonName: input.addon.name)
    }
  }
}

private struct GoogleServiceGatewayAddonEngine {
  private static let accessTokenEnvironmentName = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"

  var environment: [String: String]
  var clientFactory: GoogleServiceGatewayAddonClientFactory

  func execute(
    _ input: WorkflowAddonExecutionInput,
    capability: BuiltinGoogleServiceGatewayAddon,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(
        .policyBlocked,
        "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'"
      )
    }
    let config = input.addon.config ?? [:]
    guard let operation = nonEmptyString(config["operation"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) config.operation is required")
    }
    try validate(operation: operation, capability: capability, addonName: input.addon.name)
    let token = try accessToken(from: input)
    let values = GatewayAddonValues(config: config, variables: addonVariables(for: input))
    let client = clientFactory(token)
    let result = try await invoke(
      operation: operation,
      values: values,
      client: client,
      context: context,
      addonName: input.addon.name
    )
    guard case let .object(data) = try rielaJSON(from: result) else {
      throw AdapterExecutionError(.invalidOutput, "\(input.addon.name) returned a non-object result")
    }
    return AdapterExecutionOutput(
      provider: "google-service-gateway",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: [
        "status": .string("ok"),
        "addon": .string(input.addon.name),
        "stepId": .string(input.stepId),
        "operation": .string(operation),
        "data": .object(data)
      ]
    )
  }

  private func accessToken(from input: WorkflowAddonExecutionInput) throws -> String {
    guard let bindings = input.addon.env,
      bindings[Self.accessTokenEnvironmentName] != nil else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(input.addon.name) requires addon.env.\(Self.accessTokenEnvironmentName)"
      )
    }
    for target in bindings.keys where target != Self.accessTokenEnvironmentName {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(input.addon.name) addon.env target '\(target)' is not supported"
      )
    }
    let resolved = try resolveAddonEnvironment(bindings, runtimeEnvironment: environment)
    guard let token = resolved[Self.accessTokenEnvironmentName], !token.isEmpty else {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) access token is unavailable")
    }
    return token
  }

  private func validate(
    operation: String,
    capability: BuiltinGoogleServiceGatewayAddon,
    addonName: String
  ) throws {
    let allowed: Set<String>
    switch capability {
    case .read:
      allowed = ["services.list", "services.get", "operations.get"]
    case .write:
      allowed = ["services.enable", "services.disable", "services.batchEnable"]
    }
    guard allowed.contains(operation) else {
      throw AdapterExecutionError(
        .policyBlocked,
        "\(addonName) does not allow operation '\(operation)'"
      )
    }
  }

  private func invoke(
    operation: String,
    values: GatewayAddonValues,
    client: any GoogleServiceGatewayAddonClient,
    context: AdapterExecutionContext,
    addonName: String
  ) async throws -> GoogleServiceGatewayCore.JSONValue {
    switch operation {
    case "services.list":
      let stateText = try values.optionalString("state") ?? "all"
      guard let state = ServiceListState(rawValue: stateText) else {
        throw AdapterExecutionError(.invalidInput, "\(addonName) state must be enabled, disabled, or all")
      }
      return try await client.listServices(ListServicesRequest(
        project: try values.requiredString("project", addonName: addonName),
        state: state,
        pageSize: try values.optionalInt("pageSize") ?? 50,
        pageToken: try values.optionalString("pageToken"),
        allPages: try values.optionalBool("allPages") ?? false
      ))
    case "services.get":
      return try await client.getService(
        project: try values.requiredString("project", addonName: addonName),
        service: try values.requiredString("service", addonName: addonName)
      )
    case "operations.get":
      return try await client.getOperation(try values.requiredString("operationName", addonName: addonName))
    case "services.enable":
      return try await client.enable(
        project: try values.requiredString("project", addonName: addonName),
        service: try values.requiredString("service", addonName: addonName),
        options: try mutationOptions(values: values, context: context, addonName: addonName)
      )
    case "services.disable":
      return try await client.disable(
        project: try values.requiredString("project", addonName: addonName),
        service: try values.requiredString("service", addonName: addonName),
        disableDependents: try values.optionalBool("disableDependentServices") ?? false,
        checkUsage: try values.optionalBool("checkUsage") ?? false,
        options: try mutationOptions(values: values, context: context, addonName: addonName)
      )
    case "services.batchEnable":
      return try await client.batchEnable(
        project: try values.requiredString("project", addonName: addonName),
        services: try values.requiredStringArray("services", addonName: addonName),
        options: try mutationOptions(values: values, context: context, addonName: addonName)
      )
    default:
      throw AdapterExecutionError(.policyBlocked, "\(addonName) operation is not supported")
    }
  }

  private func mutationOptions(
    values: GatewayAddonValues,
    context: AdapterExecutionContext,
    addonName: String
  ) throws -> MutationOptions {
    let configuredTimeout = try values.optionalDouble("timeoutSeconds") ?? 120
    let pollInterval = try values.optionalDouble("pollIntervalSeconds") ?? 1
    var timeout = configuredTimeout
    if let deadline = context.deadline {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else {
        throw AdapterExecutionError(.timeout, "\(addonName) deadline elapsed before execution")
      }
      timeout = min(timeout, remaining)
    }
    return MutationOptions(
      wait: try values.optionalBool("wait") ?? true,
      pollInterval: pollInterval,
      timeout: timeout
    )
  }
}

private struct GatewayAddonValues {
  var config: JSONObject
  var variables: JSONObject

  func requiredString(_ key: String, addonName: String) throws -> String {
    guard let value = try optionalString(key) else {
      throw AdapterExecutionError(.invalidInput, "\(addonName) \(key) is required")
    }
    return value
  }

  func optionalString(_ key: String) throws -> String? {
    guard let value = value(key) else { return nil }
    guard case let .string(text) = value, !text.isEmpty else {
      throw AdapterExecutionError(.invalidInput, "\(key) must be a non-empty string")
    }
    return text
  }

  func optionalBool(_ key: String) throws -> Bool? {
    guard let value = value(key) else { return nil }
    guard case let .bool(flag) = value else {
      throw AdapterExecutionError(.invalidInput, "\(key) must be a boolean")
    }
    return flag
  }

  func optionalInt(_ key: String) throws -> Int? {
    guard let value = value(key) else { return nil }
    guard let integer = value.asInt64, let result = Int(exactly: integer) else {
      throw AdapterExecutionError(.invalidInput, "\(key) must be an integer")
    }
    return result
  }

  func optionalDouble(_ key: String) throws -> Double? {
    guard let value = value(key) else { return nil }
    guard let result = value.asDouble, result.isFinite, result > 0 else {
      throw AdapterExecutionError(.invalidInput, "\(key) must be a finite positive number")
    }
    return result
  }

  func requiredStringArray(_ key: String, addonName: String) throws -> [String] {
    guard let value = value(key) else {
      throw AdapterExecutionError(.invalidInput, "\(addonName) \(key) is required")
    }
    guard case let .array(items) = value else {
      throw AdapterExecutionError(.invalidInput, "\(key) must be an array of strings")
    }
    let strings = try items.map { item -> String in
      guard case let .string(text) = item, !text.isEmpty else {
        throw AdapterExecutionError(.invalidInput, "\(key) must contain non-empty strings")
      }
      return text
    }
    return strings
  }

  private func value(_ key: String) -> RielaCore.JSONValue? {
    variables[key] ?? config[key]
  }
}

private func rielaJSON(
  from value: GoogleServiceGatewayCore.JSONValue
) throws -> RielaCore.JSONValue {
  switch value {
  case .null:
    return .null
  case let .bool(flag):
    return .bool(flag)
  case let .string(text):
    return .string(text)
  case let .array(items):
    return .array(try items.map(rielaJSON))
  case let .object(object):
    return .object(try object.mapValues(rielaJSON))
  case let .number(text):
    if let integer = Int64(text) { return .integer(integer) }
    guard let number = Double(text), number.isFinite else {
      throw AdapterExecutionError(.invalidOutput, "google-service-gateway returned an unsupported JSON number")
    }
    return .number(number)
  }
}

private func googleServiceAdapterError(
  _ error: GatewayError,
  addonName: String
) -> AdapterExecutionError {
  let code: AdapterExecutionErrorCode
  switch error.code {
  case .invalidArgument, .configurationError, .authRequired:
    code = .invalidInput
  case .operationTimeout:
    code = .timeout
  default:
    code = .providerError
  }
  return AdapterExecutionError(code, "\(addonName): \(error.code.rawValue): \(error.message)")
}
