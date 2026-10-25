import Foundation
import GoogleServiceGatewayCore
import RielaAddonSupport
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

struct GoogleServiceMutationValues: Sendable {
  var wait: Bool
  var waitError: AdapterExecutionError?
  var timeoutSeconds: Double
  var pollIntervalSeconds: Double
}

enum GoogleServiceOperationRequest: Sendable {
  case listServices(ListServicesRequest)
  case getService(project: String, service: String)
  case getOperation(name: String)
  case enable(project: String, service: String, mutation: GoogleServiceMutationValues)
  case disable(
    project: String,
    service: String,
    disableDependents: Bool,
    checkUsage: Bool,
    mutation: GoogleServiceMutationValues
  )
  case batchEnable(project: String, services: [String], mutation: GoogleServiceMutationValues)

  var deferredValueError: AdapterExecutionError? {
    switch self {
    case let .enable(_, _, mutation), let .batchEnable(_, _, mutation): mutation.waitError
    case let .disable(_, _, _, _, mutation): mutation.waitError
    case .listServices, .getService, .getOperation: nil
    }
  }
}

struct GoogleServiceGatewayAddonEngine {
  private static let accessTokenEnvironmentName = "GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN"

  static let operationArguments: [String: Set<String>] = [
    "services.list": ["project", "state", "pageSize", "pageToken", "allPages"],
    "services.get": ["project", "service"],
    "operations.get": ["operationName"],
    "services.enable": ["project", "service", "wait", "timeoutSeconds", "pollIntervalSeconds"],
    "services.disable": ["project", "service", "disableDependentServices", "checkUsage", "wait", "timeoutSeconds", "pollIntervalSeconds"],
    "services.batchEnable": ["project", "services", "wait", "timeoutSeconds", "pollIntervalSeconds"]
  ]

  static func requestShapeIssue(
    capability: BuiltinGoogleServiceGatewayAddon,
    config: JSONObject,
    inputs: JSONObject?,
    addonName: String
  ) throws {
    guard let operation = nonEmptyString(config["operation"]) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) config.operation is required")
    }
    try validate(operation: operation, capability: capability, addonName: addonName)
    guard config["arguments"] != nil else { return }
    guard Set(config.keys).isSubset(of: ["operation", "arguments"]), inputs?.isEmpty != false else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments cannot be combined with flat configuration or selection")
    }
    if BuiltinGatewayRequestChecks.isExactPlaceholder(config["arguments"]) { return }
    guard case let .object(arguments)? = config["arguments"] else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) arguments must be an object")
    }
    guard Set(arguments.keys).isSubset(of: operationArguments[operation] ?? []) else {
      throw AdapterExecutionError(.policyBlocked, "\(addonName) contains arguments outside its operation")
    }
  }

  static func parse(
    operation: String,
    values: GatewayAddonValues,
    addonName: String
  ) throws -> GoogleServiceOperationRequest {
    switch operation {
    case "services.list":
      let stateText = try values.optionalString("state") ?? "all"
      guard let state = ServiceListState(rawValue: stateText) else {
        throw AdapterExecutionError(.invalidInput, "\(addonName) state must be enabled, disabled, or all")
      }
      return .listServices(ListServicesRequest(
        project: try values.requiredString("project", addonName: addonName),
        state: state,
        pageSize: try values.optionalInt("pageSize") ?? 50,
        pageToken: try values.optionalString("pageToken"),
        allPages: try values.optionalBool("allPages") ?? false
      ))
    case "services.get":
      return .getService(
        project: try values.requiredString("project", addonName: addonName),
        service: try values.requiredString("service", addonName: addonName)
      )
    case "operations.get":
      return .getOperation(name: try values.requiredString("operationName", addonName: addonName))
    case "services.enable":
      let project = try values.requiredString("project", addonName: addonName)
      let service = try values.requiredString("service", addonName: addonName)
      return .enable(project: project, service: service, mutation: try mutationValues(values))
    case "services.disable":
      let project = try values.requiredString("project", addonName: addonName)
      let service = try values.requiredString("service", addonName: addonName)
      return .disable(
        project: project,
        service: service,
        disableDependents: try values.optionalBool("disableDependentServices") ?? false,
        checkUsage: try values.optionalBool("checkUsage") ?? false,
        mutation: try mutationValues(values)
      )
    case "services.batchEnable":
      let project = try values.requiredString("project", addonName: addonName)
      let services = try values.requiredStringArray("services", addonName: addonName)
      return .batchEnable(project: project, services: services, mutation: try mutationValues(values))
    default:
      throw AdapterExecutionError(.policyBlocked, "\(addonName) operation is not supported")
    }
  }

  private static func mutationValues(_ values: GatewayAddonValues) throws -> GoogleServiceMutationValues {
    let timeoutSeconds = try values.optionalDouble("timeoutSeconds") ?? 120
    let pollIntervalSeconds = try values.optionalDouble("pollIntervalSeconds") ?? 1
    let wait: Bool
    let waitError: AdapterExecutionError?
    do {
      wait = try values.optionalBool("wait") ?? true
      waitError = nil
    } catch let error as AdapterExecutionError {
      wait = true
      waitError = error
    } catch {
      throw error
    }
    return GoogleServiceMutationValues(
      wait: wait,
      waitError: waitError,
      timeoutSeconds: timeoutSeconds,
      pollIntervalSeconds: pollIntervalSeconds
    )
  }

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
    try Self.requestShapeIssue(
      capability: capability, config: config, inputs: input.addon.inputs, addonName: input.addon.name
    )
    let variables = try addonVariables(for: input)
    let values: GatewayAddonValues
    if config["arguments"] != nil {
      let arguments = try BuiltinGatewayJSONRequest.renderedArguments(config: config, variables: variables, addonName: input.addon.name)
      guard Set(arguments.keys).isSubset(of: Self.operationArguments[operation] ?? []) else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) contains arguments outside its operation")
      }
      values = GatewayAddonValues(config: arguments, variables: [:])
    } else {
      values = GatewayAddonValues(config: config, variables: variables)
    }
    let token = try accessToken(from: input)
    let client = clientFactory(token)
    let request = try Self.parse(operation: operation, values: values, addonName: input.addon.name)
    let result = try await invoke(
      request: request,
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

  private static func validate(
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
    request: GoogleServiceOperationRequest,
    client: any GoogleServiceGatewayAddonClient,
    context: AdapterExecutionContext,
    addonName: String
  ) async throws -> GoogleServiceGatewayCore.JSONValue {
    switch request {
    case let .listServices(request):
      return try await client.listServices(request)
    case let .getService(project, service):
      return try await client.getService(project: project, service: service)
    case let .getOperation(name):
      return try await client.getOperation(name)
    case let .enable(project, service, mutation):
      return try await client.enable(
        project: project,
        service: service,
        options: try Self.mutationOptions(values: mutation, context: context, addonName: addonName)
      )
    case let .disable(project, service, disableDependents, checkUsage, mutation):
      return try await client.disable(
        project: project,
        service: service,
        disableDependents: disableDependents,
        checkUsage: checkUsage,
        options: try Self.mutationOptions(values: mutation, context: context, addonName: addonName)
      )
    case let .batchEnable(project, services, mutation):
      return try await client.batchEnable(
        project: project,
        services: services,
        options: try Self.mutationOptions(values: mutation, context: context, addonName: addonName)
      )
    }
  }

  static func mutationOptions(
    values: GoogleServiceMutationValues,
    context: AdapterExecutionContext,
    addonName: String
  ) throws -> MutationOptions {
    var timeout = values.timeoutSeconds
    if let deadline = context.deadline {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else {
        throw AdapterExecutionError(.timeout, "\(addonName) deadline elapsed before execution")
      }
      timeout = min(timeout, remaining)
    }
    if let waitError = values.waitError { throw waitError }
    return MutationOptions(
      wait: values.wait,
      pollInterval: values.pollIntervalSeconds,
      timeout: timeout
    )
  }
}

struct GatewayAddonValues {
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
