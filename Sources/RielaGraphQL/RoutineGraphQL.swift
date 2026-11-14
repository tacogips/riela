import Foundation
import RielaCore

// Routine management GraphQL domain. Like the configuration domain this is a
// local-trust surface: the provider mutates local stores and event files, so
// remote (non-locally-trusted) requests are refused.

public enum GraphQLRoutineStatus: String, Codable, Equatable, Sendable {
  case active = "ACTIVE"
  case disabled = "DISABLED"
  case completed = "COMPLETED"

  public init(_ status: RoutineStatus) {
    switch status {
    case .active:
      self = .active
    case .disabled:
      self = .disabled
    case .completed:
      self = .completed
    }
  }

  public var routineStatus: RoutineStatus {
    switch self {
    case .active:
      .active
    case .disabled:
      .disabled
    case .completed:
      .completed
    }
  }
}

public struct GraphQLRoutine: Codable, Equatable, Sendable {
  public var routineId: String
  public var name: String
  public var instruction: String?
  public var task: String
  public var schedule: String
  public var timezone: String?
  public var workflowName: String
  public var completionCriteria: String?
  public var status: GraphQLRoutineStatus
  public var createdAt: String
  public var updatedAt: String
  public var completedAt: String?
  public var completionNote: String?
  public var lastRunAt: String?
  public var runCount: Int
  public var eventRoot: String
  public var sourceId: String
  public var bindingId: String
  public var deactivateWorkflowOnCompletion: Bool
  public var origin: JSONObject?

  public init(_ record: RoutineRecord) {
    self.routineId = record.routineId
    self.name = record.name
    self.instruction = record.instruction
    self.task = record.task
    self.schedule = record.schedule
    self.timezone = record.timezone
    self.workflowName = record.workflowName
    self.completionCriteria = record.completionCriteria
    self.status = GraphQLRoutineStatus(record.status)
    self.createdAt = record.createdAt
    self.updatedAt = record.updatedAt
    self.completedAt = record.completedAt
    self.completionNote = record.completionNote
    self.lastRunAt = record.lastRunAt
    self.runCount = record.runCount
    self.eventRoot = record.eventRoot
    self.sourceId = record.sourceId
    self.bindingId = record.bindingId
    self.deactivateWorkflowOnCompletion = record.deactivateWorkflowOnCompletion
    self.origin = record.origin
  }
}

public struct GraphQLRoutineFilterInput: Codable, Equatable, Sendable {
  public var status: GraphQLRoutineStatus?
  public var workflowName: String?
  public var limit: Int?
  public var routineStoreRoot: String?

  public init(
    status: GraphQLRoutineStatus? = nil,
    workflowName: String? = nil,
    limit: Int? = nil,
    routineStoreRoot: String? = nil
  ) {
    self.status = status
    self.workflowName = workflowName
    self.limit = limit
    self.routineStoreRoot = routineStoreRoot
  }
}

public struct GraphQLCreateRoutineInput: Codable, Equatable, Sendable {
  public var name: String
  public var instruction: String?
  public var task: String
  public var schedule: String?
  public var every: String?
  public var timezone: String?
  public var workflowName: String
  public var completionCriteria: String?
  public var eventRoot: String?
  public var routineStoreRoot: String?
  public var deactivateWorkflowOnCompletion: Bool?
  public var origin: JSONObject?

  public init(
    name: String,
    instruction: String? = nil,
    task: String,
    schedule: String? = nil,
    every: String? = nil,
    timezone: String? = nil,
    workflowName: String,
    completionCriteria: String? = nil,
    eventRoot: String? = nil,
    routineStoreRoot: String? = nil,
    deactivateWorkflowOnCompletion: Bool? = nil,
    origin: JSONObject? = nil
  ) {
    self.name = name
    self.instruction = instruction
    self.task = task
    self.schedule = schedule
    self.every = every
    self.timezone = timezone
    self.workflowName = workflowName
    self.completionCriteria = completionCriteria
    self.eventRoot = eventRoot
    self.routineStoreRoot = routineStoreRoot
    self.deactivateWorkflowOnCompletion = deactivateWorkflowOnCompletion
    self.origin = origin
  }
}

public struct GraphQLCompleteRoutineInput: Codable, Equatable, Sendable {
  public var routineId: String
  public var note: String?
  public var routineStoreRoot: String?

  public init(routineId: String, note: String? = nil, routineStoreRoot: String? = nil) {
    self.routineId = routineId
    self.note = note
    self.routineStoreRoot = routineStoreRoot
  }
}

public struct GraphQLSetRoutineStatusInput: Codable, Equatable, Sendable {
  public var routineId: String
  public var status: GraphQLRoutineStatus
  public var routineStoreRoot: String?

  public init(routineId: String, status: GraphQLRoutineStatus, routineStoreRoot: String? = nil) {
    self.routineId = routineId
    self.status = status
    self.routineStoreRoot = routineStoreRoot
  }
}

public struct GraphQLDeleteRoutineInput: Codable, Equatable, Sendable {
  public var routineId: String
  public var routineStoreRoot: String?

  public init(routineId: String, routineStoreRoot: String? = nil) {
    self.routineId = routineId
    self.routineStoreRoot = routineStoreRoot
  }
}

public struct RoutineGraphQLError: Error, Codable, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct GraphQLRoutineListPayload: Codable, Equatable, Sendable {
  public var routines: [GraphQLRoutine]
  public var errors: [RoutineGraphQLError]

  public init(routines: [GraphQLRoutine], errors: [RoutineGraphQLError] = []) {
    self.routines = routines
    self.errors = errors
  }
}

public struct GraphQLRoutineQueryPayload: Codable, Equatable, Sendable {
  public var routine: GraphQLRoutine?
  public var errors: [RoutineGraphQLError]

  public init(routine: GraphQLRoutine?, errors: [RoutineGraphQLError] = []) {
    self.routine = routine
    self.errors = errors
  }
}

public struct GraphQLRoutineMutationPayload: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var routine: GraphQLRoutine?
  public var diagnostics: [String]
  public var errors: [RoutineGraphQLError]

  public init(
    accepted: Bool,
    routine: GraphQLRoutine? = nil,
    diagnostics: [String] = [],
    errors: [RoutineGraphQLError] = []
  ) {
    self.accepted = accepted
    self.routine = routine
    self.diagnostics = diagnostics
    self.errors = errors
  }
}

public protocol RoutineGraphQLProviding: Sendable {
  func routines(filter: GraphQLRoutineFilterInput?) async throws -> [GraphQLRoutine]
  func routine(routineId: String, routineStoreRoot: String?) async throws -> GraphQLRoutine
  func createRoutine(input: GraphQLCreateRoutineInput) async throws -> GraphQLRoutineMutationPayload
  func completeRoutine(input: GraphQLCompleteRoutineInput) async throws -> GraphQLRoutineMutationPayload
  func setRoutineStatus(input: GraphQLSetRoutineStatusInput) async throws -> GraphQLRoutineMutationPayload
  func deleteRoutine(input: GraphQLDeleteRoutineInput) async throws -> GraphQLRoutineMutationPayload
}

public struct RoutineGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  static let queryFields: Set<String> = ["routines", "routine"]
  static let mutationFields: Set<String> = [
    "createRoutine", "completeRoutine", "setRoutineStatus", "deleteRoutine"
  ]

  public var provider: (any RoutineGraphQLProviding)?

  public init(provider: (any RoutineGraphQLProviding)? = nil) {
    self.provider = provider
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
      return routineGraphQLError(code: "INVALID_ROUTINE", message: "\(error)")
    }
    let routineRoots = roots.filter { Self.supports($0.fieldName) }
    guard !routineRoots.isEmpty else { return .notHandled }
    guard request.isLocallyTrusted, let provider else {
      return routineGraphQLError(
        code: "ROUTINE_UNAVAILABLE",
        message: "routine GraphQL is available only from a locally trusted host"
      )
    }
    if let rejection = await preflight(request, rootFields: routineRoots) {
      return rejection
    }
    var data: JSONObject = [:]
    for root in routineRoots {
      do {
        let value = try await execute(root: root, provider: provider)
        data[root.responseKey] = projectGraphQLValue(value, selections: root.selections)
      } catch let error as RoutineGraphQLError {
        return routineGraphQLError(code: error.code, message: error.message, completedData: data)
      } catch is CancellationError {
        return routineGraphQLError(
          code: "ROUTINE_IO_FAILURE",
          message: "routine request was cancelled",
          completedData: data
        )
      } catch {
        return routineGraphQLError(
          code: "ROUTINE_IO_FAILURE",
          message: "routine provider failed: \(error)",
          completedData: data
        )
      }
    }
    return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
  }

  private func execute(
    root: ParsedGraphQLRootField,
    provider: any RoutineGraphQLProviding
  ) async throws -> JSONValue {
    switch root.fieldName {
    case "routines":
      let filter: GraphQLRoutineFilterInput? = try optionalRoutineInput("filter", arguments: root.arguments)
      return try routineJSONValue(GraphQLRoutineListPayload(routines: try await provider.routines(filter: filter)))
    case "routine":
      guard case let .string(routineId)? = root.arguments["routineId"] else {
        throw RoutineGraphQLError(code: "INVALID_ROUTINE", message: "routine requires routineId")
      }
      let routineStoreRoot: String?
      if case let .string(value)? = root.arguments["routineStoreRoot"] {
        routineStoreRoot = value
      } else {
        routineStoreRoot = nil
      }
      return try routineJSONValue(GraphQLRoutineQueryPayload(
        routine: try await provider.routine(routineId: routineId, routineStoreRoot: routineStoreRoot)
      ))
    case "createRoutine":
      let input: GraphQLCreateRoutineInput = try requiredRoutineInput("input", arguments: root.arguments)
      return try routineJSONValue(try await provider.createRoutine(input: input))
    case "completeRoutine":
      let input: GraphQLCompleteRoutineInput = try requiredRoutineInput("input", arguments: root.arguments)
      return try routineJSONValue(try await provider.completeRoutine(input: input))
    case "setRoutineStatus":
      let input: GraphQLSetRoutineStatusInput = try requiredRoutineInput("input", arguments: root.arguments)
      return try routineJSONValue(try await provider.setRoutineStatus(input: input))
    case "deleteRoutine":
      let input: GraphQLDeleteRoutineInput = try requiredRoutineInput("input", arguments: root.arguments)
      return try routineJSONValue(try await provider.deleteRoutine(input: input))
    default:
      throw RoutineGraphQLError(code: "INVALID_ROUTINE", message: "unsupported routine field")
    }
  }
}

extension RoutineGraphQLDocumentExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    guard request.isLocallyTrusted, provider != nil else {
      return routineGraphQLError(
        code: "ROUTINE_UNAVAILABLE",
        message: "routine GraphQL is available only from a locally trusted host"
      )
    }
    for root in rootFields {
      guard Self.supports(root.fieldName) else {
        return routineGraphQLError(code: "INVALID_ROUTINE", message: "unsupported routine root field")
      }
      let expectedOperation: GraphQLDocumentOperationType = Self.queryFields.contains(root.fieldName)
        ? .query
        : .mutation
      guard root.operationType == expectedOperation else {
        return routineGraphQLError(
          code: "INVALID_ROUTINE",
          message: "routine field '\(root.fieldName)' is not valid in this operation"
        )
      }
    }
    return nil
  }
}

/// Chains the routine executor in front of another local-domain fallback (the
/// configuration executor in the RielaApp composite). Lives in RielaGraphQL so
/// it can take part in the composite's domain preflight.
public struct RoutineAwareGraphQLFallbackExecutor: GraphQLDocumentExecuting {
  public var routine: RoutineGraphQLDocumentExecutor
  public var next: (any GraphQLDocumentExecuting)?

  public init(routine: RoutineGraphQLDocumentExecutor, next: (any GraphQLDocumentExecuting)? = nil) {
    self.routine = routine
    self.next = next
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let response = await routine.execute(request)
    if response.handled {
      return response
    }
    guard let next else {
      return .notHandled
    }
    return await next.execute(request)
  }
}

extension RoutineAwareGraphQLFallbackExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    let routineRoots = rootFields.filter { RoutineGraphQLDocumentExecutor.supports($0.fieldName) }
    let otherRoots = rootFields.filter { !RoutineGraphQLDocumentExecutor.supports($0.fieldName) }
    if !routineRoots.isEmpty,
       let rejection = await routine.preflight(request, rootFields: routineRoots) {
      return rejection
    }
    if !otherRoots.isEmpty {
      guard let preflighting = next as? any GraphQLDocumentDomainPreflighting else {
        return routineGraphQLError(
          code: "INVALID_ROUTINE",
          message: "mixed-domain fallback does not support preflight"
        )
      }
      return await preflighting.preflight(request, rootFields: otherRoots)
    }
    return nil
  }
}

public let routineGraphQLSchemaTypes = """
enum RoutineStatus { ACTIVE, DISABLED, COMPLETED }
type Routine {
  routineId: String!
  name: String!
  instruction: String
  task: String!
  schedule: String!
  timezone: String
  workflowName: String!
  completionCriteria: String
  status: RoutineStatus!
  createdAt: String!
  updatedAt: String!
  completedAt: String
  completionNote: String
  lastRunAt: String
  runCount: Int!
  eventRoot: String!
  sourceId: String!
  bindingId: String!
  deactivateWorkflowOnCompletion: Boolean!
  origin: JSONObject
}
type RoutineError { code: String!, message: String! }
type RoutineListPayload { routines: [Routine!]!, errors: [RoutineError!]! }
type RoutineQueryPayload { routine: Routine, errors: [RoutineError!]! }
type RoutineMutationPayload {
  accepted: Boolean!
  routine: Routine
  diagnostics: [String!]!
  errors: [RoutineError!]!
}
input RoutineFilter { status: RoutineStatus, workflowName: String, limit: Int, routineStoreRoot: String }
input CreateRoutineInput {
  name: String!
  instruction: String
  task: String!
  schedule: String
  every: String
  timezone: String
  workflowName: String!
  completionCriteria: String
  eventRoot: String
  routineStoreRoot: String
  deactivateWorkflowOnCompletion: Boolean
  origin: JSONObject
}
input CompleteRoutineInput { routineId: String!, note: String, routineStoreRoot: String }
input SetRoutineStatusInput { routineId: String!, status: RoutineStatus!, routineStoreRoot: String }
input DeleteRoutineInput { routineId: String!, routineStoreRoot: String }
"""

private func routineJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

func requiredRoutineInput<T: Decodable>(_ key: String, arguments: JSONObject) throws -> T {
  guard let value = arguments[key] else {
    throw RoutineGraphQLError(code: "INVALID_ROUTINE", message: "missing required input '\(key)'")
  }
  do {
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  } catch {
    throw RoutineGraphQLError(code: "INVALID_ROUTINE", message: "invalid input '\(key)': \(error)")
  }
}

func optionalRoutineInput<T: Decodable>(_ key: String, arguments: JSONObject) throws -> T? {
  guard let value = arguments[key], value != .null else { return nil }
  do {
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  } catch {
    throw RoutineGraphQLError(code: "INVALID_ROUTINE", message: "invalid input '\(key)': \(error)")
  }
}

private func routineGraphQLError(
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
