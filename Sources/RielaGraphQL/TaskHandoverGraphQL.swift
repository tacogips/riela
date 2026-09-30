import Foundation
import RielaCore

public struct TaskHandoverGraphQLError: Error, Codable, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct GraphQLHandoverPacket: Codable, Equatable, Sendable {
  public var handoverId: String
  public var taskId: String
  public var digest: String
  public var reasonKind: String
  public var resumeStepId: String
  public var brief: String
  public var packet: JSONObject

  public init(handoverId: String, taskId: String, digest: String, reasonKind: String, resumeStepId: String, brief: String, packet: JSONObject) {
    self.handoverId = handoverId
    self.taskId = taskId
    self.digest = digest
    self.reasonKind = reasonKind
    self.resumeStepId = resumeStepId
    self.brief = brief
    self.packet = packet
  }
}

public struct GraphQLTaskHandoverSummary: Codable, Equatable, Sendable {
  public var taskId: String
  public var handoverId: String
  public var reasonKind: String
  public var requiredTraits: [String]
  public var needsAnswer: Bool
  public var questionText: String?
  public var createdAt: String

  public init(taskId: String, handoverId: String, reasonKind: String, requiredTraits: [String], needsAnswer: Bool, questionText: String?, createdAt: String) {
    self.taskId = taskId
    self.handoverId = handoverId
    self.reasonKind = reasonKind
    self.requiredTraits = requiredTraits
    self.needsAnswer = needsAnswer
    self.questionText = questionText
    self.createdAt = createdAt
  }
}

public struct GraphQLRequestTaskHandoverInput: Codable, Equatable, Sendable {
  public var taskId: String
  public var reason: String
  public var immediate: Bool?
  public var target: String?
  public var sinks: [String]?

  public init(taskId: String, reason: String, immediate: Bool? = nil, target: String? = nil, sinks: [String]? = nil) {
    self.taskId = taskId
    self.reason = reason
    self.immediate = immediate
    self.target = target
    self.sinks = sinks
  }
}

public struct GraphQLAnswerTaskInput: Codable, Equatable, Sendable {
  public var taskId: String
  public var questionId: String
  public var answer: JSONObject
  public var principal: String?

  public init(taskId: String, questionId: String, answer: JSONObject, principal: String? = nil) {
    self.taskId = taskId
    self.questionId = questionId
    self.answer = answer
    self.principal = principal
  }
}

public struct GraphQLTakeoverTaskInput: Codable, Equatable, Sendable {
  public var taskId: String
  public var handoverId: String
  public var hostId: String
  public var traits: [String]
  public var backend: String?
  public var model: String?

  public init(taskId: String, handoverId: String, hostId: String, traits: [String], backend: String? = nil, model: String? = nil) {
    self.taskId = taskId
    self.handoverId = handoverId
    self.hostId = hostId
    self.traits = traits
    self.backend = backend
    self.model = model
  }
}

public struct GraphQLTakeoverTaskPayload: Codable, Equatable, Sendable {
  public var attemptId: String?
  public var sessionId: String?
  public var fence: Int?
  public var expiresAt: String?
  public var heartbeatToken: String?
  public var heartbeatMs: Int?
  public var packet: GraphQLHandoverPacket?
  public var errors: [TaskHandoverGraphQLError]

  public init(
    attemptId: String? = nil,
    sessionId: String? = nil,
    fence: Int? = nil,
    expiresAt: String? = nil,
    heartbeatToken: String? = nil,
    heartbeatMs: Int? = nil,
    packet: GraphQLHandoverPacket? = nil,
    errors: [TaskHandoverGraphQLError] = []
  ) {
    self.attemptId = attemptId
    self.sessionId = sessionId
    self.fence = fence
    self.expiresAt = expiresAt
    self.heartbeatToken = heartbeatToken
    self.heartbeatMs = heartbeatMs
    self.packet = packet
    self.errors = errors
  }
}

public struct GraphQLLeaseStatePayload: Codable, Equatable, Sendable {
  public var attemptId: String
  public var fence: Int
  public var expiresAt: String?
  public var fenced: Bool
  public var errors: [TaskHandoverGraphQLError]

  public init(attemptId: String, fence: Int, expiresAt: String?, fenced: Bool, errors: [TaskHandoverGraphQLError] = []) {
    self.attemptId = attemptId
    self.fence = fence
    self.expiresAt = expiresAt
    self.fenced = fenced
    self.errors = errors
  }
}

public struct GraphQLReportAttemptInput: Codable, Equatable, Sendable {
  public var attemptId: String
  public var token: String
  public var snapshot: JSONObject
  public var deliverables: [JSONObject]

  public init(attemptId: String, token: String, snapshot: JSONObject, deliverables: [JSONObject]) {
    self.attemptId = attemptId
    self.token = token
    self.snapshot = snapshot
    self.deliverables = deliverables
  }
}

public struct GraphQLReportAttemptPayload: Codable, Equatable, Sendable {
  public var attemptId: String?
  public var taskState: String?
  public var decisionKind: String?
  public var handoverId: String?
  public var errors: [TaskHandoverGraphQLError]

  public init(attemptId: String? = nil, taskState: String? = nil, decisionKind: String? = nil, handoverId: String? = nil, errors: [TaskHandoverGraphQLError] = []) {
    self.attemptId = attemptId
    self.taskState = taskState
    self.decisionKind = decisionKind
    self.handoverId = handoverId
    self.errors = errors
  }
}

public struct GraphQLTaskHandoverMutationPayload: Codable, Equatable, Sendable {
  public var taskId: String?
  public var taskState: String?
  public var decisionKind: String?
  public var requestId: String?
  public var errors: [TaskHandoverGraphQLError]

  public init(taskId: String? = nil, taskState: String? = nil, decisionKind: String? = nil, requestId: String? = nil, errors: [TaskHandoverGraphQLError] = []) {
    self.taskId = taskId
    self.taskState = taskState
    self.decisionKind = decisionKind
    self.requestId = requestId
    self.errors = errors
  }
}

public struct GraphQLTaskHandoverPayload: Codable, Equatable, Sendable {
  public var handover: GraphQLHandoverPacket?
  public var errors: [TaskHandoverGraphQLError]

  public init(handover: GraphQLHandoverPacket? = nil, errors: [TaskHandoverGraphQLError] = []) {
    self.handover = handover
    self.errors = errors
  }
}

public struct GraphQLTasksAwaitingHandoverPayload: Codable, Equatable, Sendable {
  public var tasks: [GraphQLTaskHandoverSummary]
  public var errors: [TaskHandoverGraphQLError]

  public init(tasks: [GraphQLTaskHandoverSummary] = [], errors: [TaskHandoverGraphQLError] = []) {
    self.tasks = tasks
    self.errors = errors
  }
}

public protocol TaskHandoverGraphQLProviding: Sendable {
  func taskHandover(taskId: String, handoverId: String?, context: GraphQLDocumentRequest) async throws -> GraphQLHandoverPacket?
  func tasksAwaitingHandover(traits: [String]?, context: GraphQLDocumentRequest) async throws -> [GraphQLTaskHandoverSummary]
  func requestTaskHandover(_ input: GraphQLRequestTaskHandoverInput, context: GraphQLDocumentRequest) async throws -> GraphQLTaskHandoverMutationPayload
  func answerTask(_ input: GraphQLAnswerTaskInput, context: GraphQLDocumentRequest) async throws -> GraphQLTaskHandoverMutationPayload
  func takeoverTask(_ input: GraphQLTakeoverTaskInput, context: GraphQLDocumentRequest) async throws -> GraphQLTakeoverTaskPayload
  func heartbeatAttempt(attemptId: String, token: String, context: GraphQLDocumentRequest) async throws -> GraphQLLeaseStatePayload
  func reportAttempt(_ input: GraphQLReportAttemptInput, context: GraphQLDocumentRequest) async throws -> GraphQLReportAttemptPayload
}

public struct TaskHandoverGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  static let queryFields: Set<String> = ["taskHandover", "tasksAwaitingHandover"]
  static let mutationFields: Set<String> = ["requestTaskHandover", "answerTask", "takeoverTask", "heartbeatAttempt", "reportAttempt"]
  public var provider: (any TaskHandoverGraphQLProviding)?
  public var next: (any GraphQLDocumentExecuting)?

  public init(provider: (any TaskHandoverGraphQLProviding)?, next: (any GraphQLDocumentExecuting)? = nil) {
    self.provider = provider
    self.next = next
  }

  static func supports(_ field: String) -> Bool { queryFields.contains(field) || mutationFields.contains(field) }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let roots: [ParsedGraphQLRootField]
    do {
      if let parsed = request.parsedRootFields {
        roots = parsed
      } else {
        guard let selected = try selectGraphQLOperation(
          parseGraphQLOperations(in: request.query, operationName: request.operationName, variables: request.variables, parseArguments: true),
          operationName: request.operationName
        ) else { return .notHandled }
        roots = selected.rootFields
      }
    } catch {
      return handoverGraphQLFailure(code: "invalid_input", message: "invalid GraphQL document: \(error)")
    }
    let taskRoots = roots.filter { Self.supports($0.fieldName) }
    guard !taskRoots.isEmpty else { return await next?.execute(request) ?? .notHandled }
    if let rejection = await preflight(request, rootFields: taskRoots) { return rejection }
    guard let provider else {
      return handoverGraphQLFailure(code: "internal", message: "task handover provider unavailable")
    }
    var data: JSONObject = [:]
    for root in taskRoots {
      do {
        let value = try await execute(root: root, provider: provider, context: request)
        data[root.responseKey] = projectGraphQLValue(value, selections: root.selections)
      } catch let error as TaskHandoverGraphQLError {
        data[root.responseKey] = failurePayload(for: root.fieldName, error: error)
      } catch is CancellationError {
        data[root.responseKey] = failurePayload(
          for: root.fieldName,
          error: TaskHandoverGraphQLError(code: "internal", message: "request was cancelled")
        )
      } catch {
        data[root.responseKey] = failurePayload(
          for: root.fieldName,
          error: TaskHandoverGraphQLError(code: "internal", message: "task handover provider failed")
        )
      }
    }
    return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
  }

  private func execute(root: ParsedGraphQLRootField, provider: any TaskHandoverGraphQLProviding, context: GraphQLDocumentRequest) async throws -> JSONValue {
    switch root.fieldName {
    case "taskHandover":
      guard case let .string(taskId)? = root.arguments["taskId"] else { throw invalid("taskHandover requires taskId") }
      let handoverId: String? = stringArgument("handoverId", root.arguments)
      return try handoverJSONValue(GraphQLTaskHandoverPayload(handover: try await provider.taskHandover(taskId: taskId, handoverId: handoverId, context: context)))
    case "tasksAwaitingHandover":
      let traits: [String]? = try optionalHandoverInput("traits", arguments: root.arguments)
      return try handoverJSONValue(GraphQLTasksAwaitingHandoverPayload(tasks: try await provider.tasksAwaitingHandover(traits: traits, context: context)))
    case "requestTaskHandover":
      let input: GraphQLRequestTaskHandoverInput = try requiredHandoverInput("input", arguments: root.arguments)
      return try handoverJSONValue(try await provider.requestTaskHandover(input, context: context))
    case "answerTask":
      let input: GraphQLAnswerTaskInput = try requiredHandoverInput("input", arguments: root.arguments)
      return try handoverJSONValue(try await provider.answerTask(input, context: context))
    case "takeoverTask":
      let input: GraphQLTakeoverTaskInput = try requiredHandoverInput("input", arguments: root.arguments)
      return try handoverJSONValue(try await provider.takeoverTask(input, context: context))
    case "heartbeatAttempt":
      guard case let .string(attemptId)? = root.arguments["attemptId"], case let .string(token)? = root.arguments["token"] else {
        throw invalid("heartbeatAttempt requires attemptId and token")
      }
      return try handoverJSONValue(try await provider.heartbeatAttempt(attemptId: attemptId, token: token, context: context))
    case "reportAttempt":
      guard let inputValue = root.arguments["input"] else { throw invalid("missing required input 'input'") }
      guard try JSONEncoder().encode(inputValue).count <= Self.maximumReportBytes else {
        throw TaskHandoverGraphQLError(code: "invalid_input", message: "reportAttempt input exceeds 4 MiB")
      }
      let input: GraphQLReportAttemptInput = try decodeHandoverInput(inputValue, key: "input")
      return try handoverJSONValue(try await provider.reportAttempt(input, context: context))
    default:
      throw invalid("unsupported task handover field")
    }
  }

  private func stringArgument(_ key: String, _ arguments: JSONObject) -> String? {
    guard case let .string(value)? = arguments[key] else { return nil }
    return value
  }

  private func invalid(_ message: String) -> TaskHandoverGraphQLError {
    TaskHandoverGraphQLError(code: "invalid_input", message: message)
  }

  static let maximumReportBytes = 4 * 1024 * 1024
}

extension TaskHandoverGraphQLDocumentExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(_ request: GraphQLDocumentRequest, rootFields: [ParsedGraphQLRootField]) async -> GraphQLDocumentExecutionResponse? {
    let taskRoots = rootFields.filter { Self.supports($0.fieldName) }
    let otherRoots = rootFields.filter { !Self.supports($0.fieldName) }
    if !taskRoots.isEmpty {
      guard request.isLocallyTrusted, provider != nil else {
        return handoverGraphQLFailure(code: "unauthorized", message: "task handover GraphQL is available only from a locally trusted host")
      }
      for root in taskRoots {
        let expected: GraphQLDocumentOperationType = Self.queryFields.contains(root.fieldName) ? .query : .mutation
        guard root.operationType == expected else {
          return handoverGraphQLFailure(code: "invalid_input", message: "task handover field '\(root.fieldName)' is not valid in this operation")
        }
      }
    }
    if !otherRoots.isEmpty {
      guard let preflighting = next as? any GraphQLDocumentDomainPreflighting else {
        return handoverGraphQLFailure(code: "invalid_input", message: "mixed-domain fallback does not support preflight")
      }
      return await preflighting.preflight(request, rootFields: otherRoots)
    }
    return nil
  }
}

public let taskHandoverGraphQLSchemaTypes = """
type TaskHandoverGraphQLError { code: String!, message: String! }
type HandoverPacket { handoverId: String!, taskId: String!, digest: String!, reasonKind: String!, resumeStepId: String!, brief: String!, packet: JSONObject! }
type TaskHandoverSummary { taskId: String!, handoverId: String!, reasonKind: String!, requiredTraits: [String!]!, needsAnswer: Boolean!, questionText: String, createdAt: String! }
type TaskHandoverPayload { handover: HandoverPacket, errors: [TaskHandoverGraphQLError!]! }
type TasksAwaitingHandoverPayload { tasks: [TaskHandoverSummary!]!, errors: [TaskHandoverGraphQLError!]! }
type TaskHandoverMutationPayload { taskId: String, taskState: String, decisionKind: String, requestId: String, errors: [TaskHandoverGraphQLError!]! }
type TakeoverTaskPayload { attemptId: String, sessionId: String, fence: Int, expiresAt: String, heartbeatToken: String, heartbeatMs: Int, packet: HandoverPacket, errors: [TaskHandoverGraphQLError!]! }
type LeaseStatePayload { attemptId: String!, fence: Int!, expiresAt: String, fenced: Boolean!, errors: [TaskHandoverGraphQLError!]! }
type ReportAttemptPayload { attemptId: String, taskState: String, decisionKind: String, handoverId: String, errors: [TaskHandoverGraphQLError!]! }
input RequestTaskHandoverInput { taskId: String!, reason: String!, immediate: Boolean, target: String, sinks: [String!] }
input AnswerTaskInput { taskId: String!, questionId: String!, answer: JSONObject!, principal: String }
input TakeoverTaskInput { taskId: String!, handoverId: String!, hostId: String!, traits: [String!]!, backend: String, model: String }
input ReportAttemptInput { attemptId: String!, token: String!, snapshot: JSONObject!, deliverables: [JSONObject!]! }
"""

private func handoverJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func decodeHandoverInput<T: Decodable>(_ value: JSONValue, key: String) throws -> T {
  do { return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)) } catch {
    throw TaskHandoverGraphQLError(code: "invalid_input", message: "invalid input '\(key)'")
  }
}

private func requiredHandoverInput<T: Decodable>(_ key: String, arguments: JSONObject) throws -> T {
  guard let value = arguments[key] else { throw TaskHandoverGraphQLError(code: "invalid_input", message: "missing required input '\(key)'") }
  return try decodeHandoverInput(value, key: key)
}

private func optionalHandoverInput<T: Decodable>(_ key: String, arguments: JSONObject) throws -> T? {
  guard let value = arguments[key], value != .null else { return nil }
  return try decodeHandoverInput(value, key: key)
}

private func failurePayload(for field: String, error: TaskHandoverGraphQLError) -> JSONValue {
  let payload: any Encodable
  switch field {
  case "taskHandover": payload = GraphQLTaskHandoverPayload(errors: [normalizedHandoverError(error)])
  case "tasksAwaitingHandover": payload = GraphQLTasksAwaitingHandoverPayload(errors: [normalizedHandoverError(error)])
  case "takeoverTask": payload = GraphQLTakeoverTaskPayload(errors: [normalizedHandoverError(error)])
  case "heartbeatAttempt": payload = GraphQLLeaseStatePayload(attemptId: "", fence: 0, expiresAt: nil, fenced: false, errors: [normalizedHandoverError(error)])
  case "reportAttempt": payload = GraphQLReportAttemptPayload(errors: [normalizedHandoverError(error)])
  default: payload = GraphQLTaskHandoverMutationPayload(errors: [normalizedHandoverError(error)])
  }
  return (try? handoverJSONValue(payload)) ?? .null
}

private func normalizedHandoverError(_ error: TaskHandoverGraphQLError) -> TaskHandoverGraphQLError {
  let allowed = Set(["not_found", "invalid_input", "conflict", "unauthorized", "internal"])
  return allowed.contains(error.code) ? error : TaskHandoverGraphQLError(code: "internal", message: error.message)
}

private func handoverGraphQLFailure(code: String, message: String) -> GraphQLDocumentExecutionResponse {
  GraphQLDocumentExecutionResponse(handled: true, body: ["data": .null, "errors": .array([.object([
    "message": .string(message), "extensions": .object(["code": .string(code)])
  ])])])
}
