import Foundation
import RielaCore

/// Console reads on GraphQL (design 2.4, delta D8). These mirror what the web
/// and desktop consoles used to read from `/api/v1/instances` and
/// `/api/v1/ops/overview`; those routes are deleted.

public struct GraphQLConsoleEnvironmentVariableDTO: Codable, Equatable, Sendable {
  public var name: String
  public var isSet: Bool
  public var masked: String

  public init(name: String, isSet: Bool, masked: String) {
    self.name = name
    self.isSet = isSet
    self.masked = masked
  }
}

public struct GraphQLConsoleRequiredEnvironmentDTO: Codable, Equatable, Sendable {
  public var name: String
  public var description: String?
  public var required: Bool
  public var secret: Bool
  public var source: String
  public var present: Bool

  public init(
    name: String,
    description: String? = nil,
    required: Bool = true,
    secret: Bool,
    source: String,
    present: Bool
  ) {
    self.name = name
    self.description = description
    self.required = required
    self.secret = secret
    self.source = source
    self.present = present
  }
}

public struct GraphQLConsoleInstanceEventSourceDTO: Codable, Equatable, Sendable {
  public var id: String
  public var kind: String

  public init(id: String, kind: String) {
    self.id = id
    self.kind = kind
  }
}

public struct GraphQLConsoleInstanceDTO: Codable, Equatable, Sendable {
  public var id: String
  public var sourceId: String
  public var isDefault: Bool
  public var name: String
  public var workflowId: String
  public var source: String
  public var sourceKind: String
  public var status: String
  public var statusDetail: String
  public var active: Bool
  public var enabledAtLaunch: Bool
  public var workingDirectory: String?
  public var environmentFilePath: String?
  public var environmentVariables: [GraphQLConsoleEnvironmentVariableDTO]
  public var requiredEnvironment: [GraphQLConsoleRequiredEnvironmentDTO]
  public var workflowVariables: JSONObject
  public var nodePatchCount: Int
  public var nodePatches: JSONObject
  public var eventSources: [GraphQLConsoleInstanceEventSourceDTO]

  public init(
    id: String,
    sourceId: String,
    isDefault: Bool,
    name: String,
    workflowId: String,
    source: String,
    sourceKind: String,
    status: String,
    statusDetail: String,
    active: Bool,
    enabledAtLaunch: Bool,
    workingDirectory: String? = nil,
    environmentFilePath: String? = nil,
    environmentVariables: [GraphQLConsoleEnvironmentVariableDTO] = [],
    requiredEnvironment: [GraphQLConsoleRequiredEnvironmentDTO] = [],
    workflowVariables: JSONObject = [:],
    nodePatchCount: Int = 0,
    nodePatches: JSONObject = [:],
    eventSources: [GraphQLConsoleInstanceEventSourceDTO] = []
  ) {
    self.id = id
    self.sourceId = sourceId
    self.isDefault = isDefault
    self.name = name
    self.workflowId = workflowId
    self.source = source
    self.sourceKind = sourceKind
    self.status = status
    self.statusDetail = statusDetail
    self.active = active
    self.enabledAtLaunch = enabledAtLaunch
    self.workingDirectory = workingDirectory
    self.environmentFilePath = environmentFilePath
    self.environmentVariables = environmentVariables
    self.requiredEnvironment = requiredEnvironment
    self.workflowVariables = workflowVariables
    self.nodePatchCount = nodePatchCount
    self.nodePatches = nodePatches
    self.eventSources = eventSources
  }
}

public struct GraphQLConsoleInstanceListPayload: Codable, Equatable, Sendable {
  public var profile: String
  public var revision: Int
  public var items: [GraphQLConsoleInstanceDTO]

  public init(profile: String, revision: Int, items: [GraphQLConsoleInstanceDTO]) {
    self.profile = profile
    self.revision = revision
    self.items = items
  }
}

public struct GraphQLConsoleInstancePayload: Codable, Equatable, Sendable {
  public var profile: String
  public var revision: Int
  public var item: GraphQLConsoleInstanceDTO?

  public init(profile: String, revision: Int, item: GraphQLConsoleInstanceDTO? = nil) {
    self.profile = profile
    self.revision = revision
    self.item = item
  }
}

public struct GraphQLOpsOverviewTransitionDTO: Codable, Equatable, Sendable {
  public var toStepId: String
  public var label: String?
  public var fanoutJoinStepId: String?

  public init(toStepId: String, label: String? = nil, fanoutJoinStepId: String? = nil) {
    self.toStepId = toStepId
    self.label = label
    self.fanoutJoinStepId = fanoutJoinStepId
  }
}

public struct GraphQLOpsOverviewStepDTO: Codable, Equatable, Sendable {
  public var id: String
  public var nodeId: String
  public var role: String?
  public var description: String?
  public var transitions: [GraphQLOpsOverviewTransitionDTO]

  public init(
    id: String,
    nodeId: String,
    role: String? = nil,
    description: String? = nil,
    transitions: [GraphQLOpsOverviewTransitionDTO] = []
  ) {
    self.id = id
    self.nodeId = nodeId
    self.role = role
    self.description = description
    self.transitions = transitions
  }
}

public struct GraphQLOpsOverviewNodeDTO: Codable, Equatable, Sendable {
  public var id: String
  public var kind: String?
  public var role: String?
  public var addon: String?

  public init(id: String, kind: String? = nil, role: String? = nil, addon: String? = nil) {
    self.id = id
    self.kind = kind
    self.role = role
    self.addon = addon
  }
}

public struct GraphQLOpsOverviewWorkflowDTO: Codable, Equatable, Sendable {
  public var sourceId: String
  public var name: String
  public var workflowId: String
  public var scope: String
  public var sourceKind: String
  public var description: String
  public var entryStepId: String
  public var managerStepId: String?
  public var steps: [GraphQLOpsOverviewStepDTO]
  public var nodes: [GraphQLOpsOverviewNodeDTO]
  public var stepsTruncated: Bool

  public init(
    sourceId: String,
    name: String,
    workflowId: String,
    scope: String,
    sourceKind: String,
    description: String,
    entryStepId: String,
    managerStepId: String? = nil,
    steps: [GraphQLOpsOverviewStepDTO] = [],
    nodes: [GraphQLOpsOverviewNodeDTO] = [],
    stepsTruncated: Bool = false
  ) {
    self.sourceId = sourceId
    self.name = name
    self.workflowId = workflowId
    self.scope = scope
    self.sourceKind = sourceKind
    self.description = description
    self.entryStepId = entryStepId
    self.managerStepId = managerStepId
    self.steps = steps
    self.nodes = nodes
    self.stepsTruncated = stepsTruncated
  }
}

public struct GraphQLOpsOverviewInstanceDTO: Codable, Equatable, Sendable {
  public var id: String
  public var sourceId: String
  public var isDefault: Bool
  public var name: String
  public var workflowId: String
  public var status: String
  public var active: Bool

  public init(
    id: String,
    sourceId: String,
    isDefault: Bool,
    name: String,
    workflowId: String,
    status: String,
    active: Bool
  ) {
    self.id = id
    self.sourceId = sourceId
    self.isDefault = isDefault
    self.name = name
    self.workflowId = workflowId
    self.status = status
    self.active = active
  }
}

public struct GraphQLOpsOverviewRunDTO: Codable, Equatable, Sendable {
  public var instanceId: String
  public var sessionId: String
  public var workflowId: String
  public var status: String
  public var currentStepId: String?
  public var activeStepIds: [String]
  public var updatedAt: String

  public init(
    instanceId: String,
    sessionId: String,
    workflowId: String,
    status: String,
    currentStepId: String? = nil,
    activeStepIds: [String] = [],
    updatedAt: String
  ) {
    self.instanceId = instanceId
    self.sessionId = sessionId
    self.workflowId = workflowId
    self.status = status
    self.currentStepId = currentStepId
    self.activeStepIds = activeStepIds
    self.updatedAt = updatedAt
  }
}

public struct GraphQLOpsOverviewPayload: Codable, Equatable, Sendable {
  public var profile: String
  public var revision: Int
  public var workflows: [GraphQLOpsOverviewWorkflowDTO]
  public var workflowsTruncated: Bool
  public var instances: [GraphQLOpsOverviewInstanceDTO]
  public var runs: [GraphQLOpsOverviewRunDTO]
  public var runsTruncated: Bool
  public var diagnostics: [String]

  public init(
    profile: String,
    revision: Int,
    workflows: [GraphQLOpsOverviewWorkflowDTO] = [],
    workflowsTruncated: Bool = false,
    instances: [GraphQLOpsOverviewInstanceDTO] = [],
    runs: [GraphQLOpsOverviewRunDTO] = [],
    runsTruncated: Bool = false,
    diagnostics: [String] = []
  ) {
    self.profile = profile
    self.revision = revision
    self.workflows = workflows
    self.workflowsTruncated = workflowsTruncated
    self.instances = instances
    self.runs = runs
    self.runsTruncated = runsTruncated
    self.diagnostics = diagnostics
  }
}

public struct GraphQLConsoleError: Error, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

/// Implemented in `RielaAppSupport` and shared by `riela serve` and the desktop
/// host, so both consoles read one projection (delta D8).
public protocol GraphQLConsoleProviding: Sendable {
  func consoleInstances() async throws -> GraphQLConsoleInstanceListPayload
  func consoleInstance(identity: String) async throws -> GraphQLConsoleInstancePayload
  func opsOverview() async throws -> GraphQLOpsOverviewPayload
}

public struct ConsoleGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  /// The fields this executor answers. Public so surface gates outside this
  /// module can compare them with the catalog.
  public static let queryFields: Set<String> = ["consoleInstances", "consoleInstance", "opsOverview"]
  public static let mutationFields: Set<String> = []

  public var provider: (any GraphQLConsoleProviding)?
  public var next: (any GraphQLDocumentExecuting)?

  public init(provider: (any GraphQLConsoleProviding)? = nil, next: (any GraphQLDocumentExecuting)? = nil) {
    self.provider = provider
    self.next = next
  }

  static func supports(_ field: String) -> Bool {
    queryFields.contains(field) || mutationFields.contains(field)
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
      return consoleGraphQLError(code: "INVALID_CONSOLE_READ", message: "\(error)")
    }
    let consoleRoots = roots.filter { Self.supports($0.fieldName) }
    guard !consoleRoots.isEmpty else {
      guard let next else { return .notHandled }
      return await next.execute(request)
    }
    if let rejection = await preflight(request, rootFields: consoleRoots) {
      return rejection
    }
    guard let provider else {
      return consoleGraphQLError(
        code: "CONSOLE_UNAVAILABLE",
        message: "console GraphQL is available only from the local console host"
      )
    }
    var data: JSONObject = [:]
    for root in consoleRoots {
      do {
        let value = try await execute(root: root, provider: provider)
        data[root.responseKey] = projectGraphQLValue(value, selections: root.selections)
      } catch let error as GraphQLConsoleError {
        return consoleGraphQLError(code: error.code, message: error.message, completedData: data)
      } catch {
        return consoleGraphQLError(code: "CONSOLE_READ_FAILURE", message: "\(error)", completedData: data)
      }
    }
    return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
  }

  private func execute(
    root: ParsedGraphQLRootField,
    provider: any GraphQLConsoleProviding
  ) async throws -> JSONValue {
    switch root.fieldName {
    case "consoleInstances":
      return try consoleJSONValue(await provider.consoleInstances())
    case "consoleInstance":
      guard case let .string(identity)? = root.arguments["identity"] else {
        throw GraphQLConsoleError(code: "INVALID_CONSOLE_READ", message: "consoleInstance requires identity")
      }
      return try consoleJSONValue(await provider.consoleInstance(identity: identity))
    case "opsOverview":
      return try consoleJSONValue(await provider.opsOverview())
    default:
      throw GraphQLConsoleError(code: "INVALID_CONSOLE_READ", message: "unsupported console field")
    }
  }
}

extension ConsoleGraphQLDocumentExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    let consoleRoots = rootFields.filter { Self.supports($0.fieldName) }
    let otherRoots = rootFields.filter { !Self.supports($0.fieldName) }
    if !consoleRoots.isEmpty {
      guard request.isLocallyTrusted, provider != nil else {
        return consoleGraphQLError(
          code: "CONSOLE_UNAVAILABLE",
          message: "console GraphQL is available only from the local console host"
        )
      }
      for root in consoleRoots where root.operationType != .query {
        return consoleGraphQLError(
          code: "INVALID_CONSOLE_READ",
          message: "console field '\(root.fieldName)' is a query"
        )
      }
    }
    if !otherRoots.isEmpty {
      guard let preflighting = next as? any GraphQLDocumentDomainPreflighting else {
        return consoleGraphQLError(
          code: "INVALID_CONSOLE_READ",
          message: "mixed-domain fallback does not support preflight"
        )
      }
      return await preflighting.preflight(request, rootFields: otherRoots)
    }
    return nil
  }
}

private func consoleJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func consoleGraphQLError(
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
