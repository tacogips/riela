import Foundation
import RielaCore

public struct GraphQLConfigurationModelCatalog: Codable, Equatable, Sendable {
  public var vendor: String
  public var models: [String]

  public init(vendor: String, models: [String]) {
    self.vendor = vendor
    self.models = models
  }
}

public struct GraphQLAssistantConfiguration: Codable, Equatable, Sendable {
  public var assistance: String
  public var vendor: String
  public var model: String
  public var modelCatalogs: [GraphQLConfigurationModelCatalog]

  public init(
    assistance: String,
    vendor: String,
    model: String,
    modelCatalogs: [GraphQLConfigurationModelCatalog]
  ) {
    self.assistance = assistance
    self.vendor = vendor
    self.model = model
    self.modelCatalogs = modelCatalogs
  }
}

public struct GraphQLAppearanceConfiguration: Codable, Equatable, Sendable {
  public var colorScheme: String
  public var options: [String]

  public init(colorScheme: String, options: [String]) {
    self.colorScheme = colorScheme
    self.options = options
  }
}

public struct GraphQLHTTPServerConfiguration: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var configuredPort: Int
  public var boundPort: Int?
  public var restartRequired: Bool
  public var state: String

  public init(
    isEnabled: Bool,
    configuredPort: Int,
    boundPort: Int?,
    restartRequired: Bool,
    state: String
  ) {
    self.isEnabled = isEnabled
    self.configuredPort = configuredPort
    self.boundPort = boundPort
    self.restartRequired = restartRequired
    self.state = state
  }
}

public struct GraphQLRielaConfiguration: Codable, Equatable, Sendable {
  public var profile: String
  public var revision: Int
  public var assistant: GraphQLAssistantConfiguration
  public var appearance: GraphQLAppearanceConfiguration
  public var server: GraphQLHTTPServerConfiguration
  public var profiles: [String]
  public var workflowDirectories: [String]

  public init(
    profile: String,
    revision: Int,
    assistant: GraphQLAssistantConfiguration,
    appearance: GraphQLAppearanceConfiguration,
    server: GraphQLHTTPServerConfiguration,
    profiles: [String] = [],
    workflowDirectories: [String] = []
  ) {
    self.profile = profile
    self.revision = revision
    self.assistant = assistant
    self.appearance = appearance
    self.server = server
    self.profiles = profiles
    self.workflowDirectories = workflowDirectories
  }
}

public struct GraphQLConfigurationRevision: Codable, Equatable, Sendable {
  public var profile: String
  public var revision: Int

  public init(profile: String, revision: Int) {
    self.profile = profile
    self.revision = revision
  }
}

public struct GraphQLProfileConfigurationInput: Codable, Equatable, Sendable {
  public var expectedRevision: Int
  public var expectedProfile: String
  public var name: String
}

public struct GraphQLWorkflowDirConfigInput: Codable, Equatable, Sendable {
  public var expectedRevision: Int
  public var expectedProfile: String
  public var path: String
}

public struct GraphQLWorkflowInstanceConfigInput: Codable, Equatable, Sendable {
  public var expectedRevision: Int
  public var expectedProfile: String
  public var identity: String
  public var workingDirectory: String?
  public var environmentFilePath: String?
  public var environmentVariableUpdates: [String: String]?
  public var environmentVariablesToClear: [String]?
  public var workflowVariables: JSONObject?
}

public struct GraphQLEventSourceConfigurationInput: Codable, Equatable, Sendable {
  public var expectedRevision: Int
  public var expectedProfile: String
  public var identity: String
  public var source: JSONObject
  public var binding: JSONObject
}

public struct GraphQLUpdateAssistantConfigurationInput: Codable, Equatable, Sendable {
  public var expectedRevision: Int
  public var expectedProfile: String
  public var assistance: String?
  public var vendor: String?
  public var model: String?

  public init(
    expectedRevision: Int,
    expectedProfile: String,
    assistance: String? = nil,
    vendor: String? = nil,
    model: String? = nil
  ) {
    self.expectedRevision = expectedRevision
    self.expectedProfile = expectedProfile
    self.assistance = assistance
    self.vendor = vendor
    self.model = model
  }
}

public struct GraphQLUpdateAppearanceConfigInput: Codable, Equatable, Sendable {
  public var expectedRevision: Int
  public var expectedProfile: String
  public var colorScheme: String

  public init(expectedRevision: Int, expectedProfile: String, colorScheme: String) {
    self.expectedRevision = expectedRevision
    self.expectedProfile = expectedProfile
    self.colorScheme = colorScheme
  }
}

public struct GraphQLUpdateHTTPServerConfigInput: Codable, Equatable, Sendable {
  public var expectedRevision: Int
  public var configuredPort: Int?
  public var isEnabled: Bool?

  public init(expectedRevision: Int, configuredPort: Int? = nil, isEnabled: Bool? = nil) {
    self.expectedRevision = expectedRevision
    self.configuredPort = configuredPort
    self.isEnabled = isEnabled
  }
}

public protocol RielaConfigurationGraphQLProviding: Sendable {
  func configuration() async throws -> GraphQLRielaConfiguration
  func updateAssistant(
    input: GraphQLUpdateAssistantConfigurationInput
  ) async throws -> GraphQLRielaConfiguration
  func updateAppearance(
    input: GraphQLUpdateAppearanceConfigInput
  ) async throws -> GraphQLRielaConfiguration
  func updateHTTPServer(
    input: GraphQLUpdateHTTPServerConfigInput
  ) async throws -> GraphQLRielaConfiguration
  func createProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration
  func removeProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration
  func switchProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration
  func addWorkflowDirectory(
    input: GraphQLWorkflowDirConfigInput
  ) async throws -> GraphQLConfigurationRevision
  func updateWorkflowInstance(
    input: GraphQLWorkflowInstanceConfigInput
  ) async throws -> GraphQLConfigurationRevision
  func registerEventSource(
    input: GraphQLEventSourceConfigurationInput
  ) async throws -> GraphQLConfigurationRevision
}

public extension RielaConfigurationGraphQLProviding {
  func createProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration {
    throw unsupportedConfigurationMutation("createProfileConfiguration")
  }

  func removeProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration {
    throw unsupportedConfigurationMutation("removeProfileConfiguration")
  }

  func switchProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration {
    throw unsupportedConfigurationMutation("switchProfileConfiguration")
  }

  func addWorkflowDirectory(
    input: GraphQLWorkflowDirConfigInput
  ) async throws -> GraphQLConfigurationRevision {
    throw unsupportedConfigurationMutation("addWorkflowDirectoryConfiguration")
  }

  func updateWorkflowInstance(
    input: GraphQLWorkflowInstanceConfigInput
  ) async throws -> GraphQLConfigurationRevision {
    throw unsupportedConfigurationMutation("updateWorkflowInstanceConfiguration")
  }

  func registerEventSource(
    input: GraphQLEventSourceConfigurationInput
  ) async throws -> GraphQLConfigurationRevision {
    throw unsupportedConfigurationMutation("registerEventSourceConfiguration")
  }

  private func unsupportedConfigurationMutation(_ name: String) -> RielaConfigurationGraphQLError {
    RielaConfigurationGraphQLError(
      code: "CONFIGURATION_UNAVAILABLE",
      message: "configuration provider does not support \(name)"
    )
  }
}

public struct RielaConfigurationGraphQLError: Error, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct RielaConfigGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  static let queryFields: Set<String> = ["configuration"]
  static let mutationFields: Set<String> = [
    "updateAssistantConfiguration",
    "updateAppearanceConfiguration",
    "updateHTTPServerConfiguration",
    "createProfileConfiguration",
    "removeProfileConfiguration",
    "switchProfileConfiguration",
    "addWorkflowDirectoryConfiguration",
    "updateWorkflowInstanceConfiguration",
    "registerEventSourceConfiguration"
  ]

  public var provider: (any RielaConfigurationGraphQLProviding)?

  public init(provider: (any RielaConfigurationGraphQLProviding)? = nil) {
    self.provider = provider
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let roots: [ParsedGraphQLRootField]
    do {
      if let parsed = request.parsedRootFields {
        roots = parsed
      } else {
        guard let selected = try selectGraphQLOperation(
          parseGraphQLOperations(
            in: request.query,
            operationName: request.operationName,
            variables: request.variables,
            parseArguments: true
          ),
          operationName: request.operationName
        ) else { return .notHandled }
        roots = selected.rootFields
      }
    } catch {
      return configurationGraphQLError(code: "INVALID_CONFIGURATION", message: "\(error)")
    }
    let configurationRoots = roots.filter { Self.supports($0.fieldName) }
    guard !configurationRoots.isEmpty else { return .notHandled }
    guard request.isLocallyTrusted, let provider else {
      return configurationGraphQLError(
        code: "CONFIGURATION_UNAVAILABLE",
        message: "configuration GraphQL is available only from the local RielaApp host"
      )
    }
    if let rejection = await preflight(request, rootFields: configurationRoots) {
      return rejection
    }
    var data: JSONObject = [:]
    for root in configurationRoots {
      do {
        let value = try await execute(root: root, provider: provider)
        data[root.responseKey] = projectGraphQLValue(value, selections: root.selections)
      } catch let error as RielaConfigurationGraphQLError {
        return configurationGraphQLError(code: error.code, message: error.message, completedData: data)
      } catch is CancellationError {
        return configurationGraphQLError(
          code: "CONFIGURATION_IO_FAILURE",
          message: "configuration request was cancelled",
          completedData: data
        )
      } catch {
        return configurationGraphQLError(
          code: "CONFIGURATION_IO_FAILURE",
          message: "configuration provider failed",
          completedData: data
        )
      }
    }
    return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
  }

  private static func supports(_ field: String) -> Bool {
    queryFields.contains(field) || mutationFields.contains(field)
  }

  private func execute(
    root: ParsedGraphQLRootField,
    provider: any RielaConfigurationGraphQLProviding
  ) async throws -> JSONValue {
    switch root.fieldName {
    case "configuration":
      return try configurationJSONValue(await provider.configuration())
    case "updateAssistantConfiguration":
      let input: GraphQLUpdateAssistantConfigurationInput = try requiredRegistryInput(
        "input",
        arguments: root.arguments
      )
      return try configurationJSONValue(await provider.updateAssistant(input: input))
    case "updateAppearanceConfiguration":
      let input: GraphQLUpdateAppearanceConfigInput = try requiredRegistryInput(
        "input",
        arguments: root.arguments
      )
      return try configurationJSONValue(await provider.updateAppearance(input: input))
    case "updateHTTPServerConfiguration":
      let input: GraphQLUpdateHTTPServerConfigInput = try requiredRegistryInput(
        "input",
        arguments: root.arguments
      )
      return try configurationJSONValue(await provider.updateHTTPServer(input: input))
    case "createProfileConfiguration":
      let input: GraphQLProfileConfigurationInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try configurationJSONValue(await provider.createProfile(input: input))
    case "removeProfileConfiguration":
      let input: GraphQLProfileConfigurationInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try configurationJSONValue(await provider.removeProfile(input: input))
    case "switchProfileConfiguration":
      let input: GraphQLProfileConfigurationInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try configurationJSONValue(await provider.switchProfile(input: input))
    case "addWorkflowDirectoryConfiguration":
      let input: GraphQLWorkflowDirConfigInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try configurationJSONValue(await provider.addWorkflowDirectory(input: input))
    case "updateWorkflowInstanceConfiguration":
      let input: GraphQLWorkflowInstanceConfigInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try configurationJSONValue(await provider.updateWorkflowInstance(input: input))
    case "registerEventSourceConfiguration":
      let input: GraphQLEventSourceConfigurationInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try configurationJSONValue(await provider.registerEventSource(input: input))
    default:
      throw RielaConfigurationGraphQLError(
        code: "INVALID_CONFIGURATION",
        message: "unsupported configuration field"
      )
    }
  }
}

extension RielaConfigGraphQLDocumentExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    guard request.isLocallyTrusted, provider != nil else {
      return configurationGraphQLError(
        code: "CONFIGURATION_UNAVAILABLE",
        message: "configuration GraphQL is available only from the local RielaApp host"
      )
    }
    for root in rootFields {
      guard Self.supports(root.fieldName) else {
        return configurationGraphQLError(
          code: "INVALID_CONFIGURATION",
          message: "unsupported configuration root field"
        )
      }
      let expectedOperation: GraphQLDocumentOperationType = Self.queryFields.contains(root.fieldName)
        ? .query
        : .mutation
      guard root.operationType == expectedOperation else {
        return configurationGraphQLError(
          code: "INVALID_CONFIGURATION",
          message: "configuration field '\(root.fieldName)' is not valid in this operation"
        )
      }
    }
    return nil
  }
}

private func configurationJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func configurationGraphQLError(
  code: String,
  message: String,
  completedData: JSONObject = [:]
) -> GraphQLDocumentExecutionResponse {
  GraphQLDocumentExecutionResponse(
    handled: true,
    body: [
      "data": completedData.isEmpty ? .null : .object(completedData),
      "errors": .array([.object([
        "message": .string(message),
        "extensions": .object(["code": .string(code)])
      ])])
    ]
  )
}
