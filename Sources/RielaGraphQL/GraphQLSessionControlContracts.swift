import Foundation
import RielaCore

/// Session control over GraphQL: rerun, resume, stop and continue (design 2.6,
/// delta D3). Remote operation of a session without a shell is the point of the
/// control plane, so these mutations reuse the same runner paths the CLI uses.

public struct GraphQLRerunSessionInput: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var stepId: String
  /// Carried for the manager control plane; not verified. See
  /// `GraphQLStopSessionInput.managerSessionId`.
  public var managerSessionId: String?

  public init(workflowId: String, sessionId: String, stepId: String, managerSessionId: String? = nil) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.stepId = stepId
    self.managerSessionId = managerSessionId
  }
}

public struct GraphQLResumeSessionInput: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  /// Carried for the manager control plane; not verified. See
  /// `GraphQLStopSessionInput.managerSessionId`.
  public var managerSessionId: String?

  public init(workflowId: String, sessionId: String, managerSessionId: String? = nil) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.managerSessionId = managerSessionId
  }
}

/// `sessionId` is the id the run was **entered from**, not the id a rerun
/// reports back. `rerunSession` registers its running task under the session it
/// re-enters, because the new session id does not exist until the rerun
/// finishes; by then there is nothing left to stop.
public struct GraphQLStopSessionInput: Codable, Equatable, Sendable {
  public var workflowId: String
  public var sessionId: String
  public var reason: String?
  /// Carried for the manager control plane. **It is not an authenticator**:
  /// nothing in the tree verifies it. Access control for these mutations is
  /// `isLocallyTrusted` plus the host's browser-provenance/Passkey gate.
  public var managerSessionId: String?

  public init(workflowId: String, sessionId: String, reason: String? = nil, managerSessionId: String? = nil) {
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.reason = reason
    self.managerSessionId = managerSessionId
  }
}

/// The lineage record a rerun or resume produces, so a CLI run and a GraphQL
/// run of the same operation can be compared field for field.
public struct GraphQLSessionLineageDTO: Codable, Equatable, Sendable {
  public var sessionId: String
  public var parentSessionId: String?
  public var rootSessionId: String
  public var entryMode: String
  public var sourceStepId: String?

  public init(
    sessionId: String,
    parentSessionId: String? = nil,
    rootSessionId: String,
    entryMode: String,
    sourceStepId: String? = nil
  ) {
    self.sessionId = sessionId
    self.parentSessionId = parentSessionId
    self.rootSessionId = rootSessionId
    self.entryMode = entryMode
    self.sourceStepId = sourceStepId
  }
}

public struct GraphQLSessionMutationPayload: Codable, Equatable, Sendable {
  public var result: GraphQLControlPlaneResult
  public var sessionId: String?
  public var status: String?
  public var lineage: GraphQLSessionLineageDTO?

  public init(
    result: GraphQLControlPlaneResult,
    sessionId: String? = nil,
    status: String? = nil,
    lineage: GraphQLSessionLineageDTO? = nil
  ) {
    self.result = result
    self.sessionId = sessionId
    self.status = status
    self.lineage = lineage
  }
}

public struct GraphQLSessionControlError: Error, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  /// Fail-closed answer for a stop request aimed at a session this process is
  /// not executing. There is no cross-process kill (delta D3).
  public static func sessionNotRunning(_ sessionId: String) -> GraphQLSessionControlError {
    .init(code: "SESSION_NOT_RUNNING", message: "session_not_running: \(sessionId)")
  }
}

/// Implemented in `RielaCLI` against the same commands `riela session rerun`,
/// `riela session resume` and `riela session continue` run.
public protocol GraphQLSessionControlProviding: Sendable {
  func rerunSession(_ input: GraphQLRerunSessionInput) async throws -> GraphQLSessionMutationPayload
  func resumeSession(_ input: GraphQLResumeSessionInput) async throws -> GraphQLSessionMutationPayload
  func stopSession(_ input: GraphQLStopSessionInput) async throws -> GraphQLSessionMutationPayload
  func continueSession(_ input: GraphQLContinueSessionRequest) async throws -> GraphQLControlPlaneResult
}

public struct SessionControlGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  /// The fields this executor answers. Public so surface gates outside this
  /// module can compare them with the catalog.
  public static let queryFields: Set<String> = []
  public static let mutationFields: Set<String> = [
    "rerunSession", "resumeSession", "stopSession", "continueSession"
  ]

  public var provider: (any GraphQLSessionControlProviding)?
  public var next: (any GraphQLDocumentExecuting)?

  public init(
    provider: (any GraphQLSessionControlProviding)? = nil,
    next: (any GraphQLDocumentExecuting)? = nil
  ) {
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
      return sessionControlGraphQLError(code: "INVALID_SESSION_CONTROL", message: "\(error)")
    }
    let controlRoots = roots.filter { Self.supports($0.fieldName) }
    guard !controlRoots.isEmpty else {
      guard let next else { return .notHandled }
      return await next.execute(request)
    }
    if let rejection = await preflight(request, rootFields: controlRoots) {
      return rejection
    }
    guard let provider else {
      return sessionControlGraphQLError(
        code: "SESSION_CONTROL_UNAVAILABLE",
        message: "session control GraphQL is available only from a host that runs sessions"
      )
    }
    var data: JSONObject = [:]
    for root in controlRoots {
      do {
        let value = try await execute(root: root, provider: provider)
        data[root.responseKey] = projectGraphQLValue(value, selections: root.selections)
      } catch let error as GraphQLSessionControlError {
        return sessionControlGraphQLError(code: error.code, message: error.message, completedData: data)
      } catch {
        return sessionControlGraphQLError(
          code: "SESSION_CONTROL_FAILURE",
          message: "\(error)",
          completedData: data
        )
      }
    }
    return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
  }

  private func execute(
    root: ParsedGraphQLRootField,
    provider: any GraphQLSessionControlProviding
  ) async throws -> JSONValue {
    switch root.fieldName {
    case "rerunSession":
      let input: GraphQLRerunSessionInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try sessionControlJSONValue(await provider.rerunSession(input))
    case "resumeSession":
      let input: GraphQLResumeSessionInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try sessionControlJSONValue(await provider.resumeSession(input))
    case "stopSession":
      let input: GraphQLStopSessionInput = try requiredRegistryInput("input", arguments: root.arguments)
      return try sessionControlJSONValue(await provider.stopSession(input))
    case "continueSession":
      let input: GraphQLContinueSessionRequest = try requiredRegistryInput("input", arguments: root.arguments)
      return try sessionControlJSONValue(await provider.continueSession(input))
    default:
      throw GraphQLSessionControlError(code: "INVALID_SESSION_CONTROL", message: "unsupported session control field")
    }
  }
}

extension SessionControlGraphQLDocumentExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(
    _ request: GraphQLDocumentRequest,
    rootFields: [ParsedGraphQLRootField]
  ) async -> GraphQLDocumentExecutionResponse? {
    let controlRoots = rootFields.filter { Self.supports($0.fieldName) }
    let otherRoots = rootFields.filter { !Self.supports($0.fieldName) }
    if !controlRoots.isEmpty {
      // Session control changes runtime state, so it keeps the same local-host
      // rule `continueSession` was specified with: the answering process must
      // be the trusted local host, never a forwarded remote document.
      guard request.isLocallyTrusted, provider != nil else {
        return sessionControlGraphQLError(
          code: "SESSION_CONTROL_UNAVAILABLE",
          message: "session control GraphQL is available only from the local host that runs sessions"
        )
      }
      for root in controlRoots where root.operationType != .mutation {
        return sessionControlGraphQLError(
          code: "INVALID_SESSION_CONTROL",
          message: "session control field '\(root.fieldName)' is a mutation"
        )
      }
    }
    if !otherRoots.isEmpty {
      guard let preflighting = next as? any GraphQLDocumentDomainPreflighting else {
        return sessionControlGraphQLError(
          code: "INVALID_SESSION_CONTROL",
          message: "mixed-domain fallback does not support preflight"
        )
      }
      return await preflighting.preflight(request, rootFields: otherRoots)
    }
    return nil
  }
}

private func sessionControlJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func sessionControlGraphQLError(
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
