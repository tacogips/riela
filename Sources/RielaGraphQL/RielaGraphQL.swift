import RielaCore

public struct GraphQLRequest: Codable, Equatable, Sendable {
  public var query: String
  public var variables: JSONObject?

  public init(query: String, variables: JSONObject? = nil) {
    self.query = query
    self.variables = variables
  }
}

public struct GraphQLRuntimeSnapshotQueryService: Sendable {
  public var loadSnapshot: @Sendable (String) throws -> WorkflowRuntimePersistenceSnapshot

  public init(loadSnapshot: @escaping @Sendable (String) throws -> WorkflowRuntimePersistenceSnapshot) {
    self.loadSnapshot = loadSnapshot
  }

  public init(store: SQLiteWorkflowRuntimePersistenceStore) {
    self.init { sessionId in
      try store.load(sessionId: sessionId)
    }
  }

  public init(fileStore: FileWorkflowRuntimePersistenceStore) {
    self.init { sessionId in
      try fileStore.load(sessionId: sessionId)
    }
  }

  public func inspectSession(_ request: GraphQLInspectSessionRequest) async -> GraphQLInspectSessionResult {
    do {
      let snapshot = try loadSnapshot(request.sessionId)
      guard snapshot.session.workflowId == request.workflowId else {
        return GraphQLInspectSessionResult(
          result: GraphQLControlPlaneResult(
            accepted: false,
            status: GraphQLLoopEvidenceQueryStatus.workflowMismatch.rawValue,
            diagnostics: [
              "session \(request.sessionId) belongs to workflow \(snapshot.session.workflowId), not \(request.workflowId)"
            ]
          )
        )
      }
      return GraphQLInspectSessionResult(
        result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
        session: GraphQLContractProjector.project(snapshot: snapshot)
      )
    } catch WorkflowRuntimePersistenceStoreError.notFound {
      return GraphQLInspectSessionResult(
        result: GraphQLControlPlaneResult(
          accepted: false,
          status: GraphQLLoopEvidenceQueryStatus.notFound.rawValue,
          diagnostics: ["runtime snapshot not found: \(request.sessionId)"]
        )
      )
    } catch WorkflowRuntimePersistenceStoreError.invalidSessionId(let sessionId) {
      return GraphQLInspectSessionResult(
        result: GraphQLControlPlaneResult(
          accepted: false,
          status: GraphQLLoopEvidenceQueryStatus.invalidRequest.rawValue,
          diagnostics: ["invalid session id: \(sessionId)"]
        )
      )
    } catch {
      return GraphQLInspectSessionResult(
        result: GraphQLControlPlaneResult(
          accepted: false,
          status: GraphQLLoopEvidenceQueryStatus.error.rawValue,
          diagnostics: [String(describing: error)]
        )
      )
    }
  }

  public func loopEvidence(_ request: GraphQLLoopEvidenceRequest) async -> GraphQLLoopEvidenceResult {
    let inspected = await inspectSession(request)
    guard inspected.result.accepted, let session = inspected.session else {
      return GraphQLLoopEvidenceResult(result: inspected.result)
    }
    guard let evidence = session.loopEvidence else {
      return GraphQLLoopEvidenceResult(
        result: GraphQLControlPlaneResult(
          accepted: false,
          status: GraphQLLoopEvidenceQueryStatus.noEvidence.rawValue,
          diagnostics: ["loop evidence not found for session \(request.sessionId)"]
        )
      )
    }
    return GraphQLLoopEvidenceResult(
      result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
      evidence: evidence,
      gates: session.loopGates,
      recovery: session.loopRecovery
    )
  }
}
