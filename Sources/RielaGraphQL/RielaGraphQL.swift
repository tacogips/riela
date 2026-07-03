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
  public var loadSnapshots: @Sendable () throws -> [WorkflowRuntimePersistenceSnapshot]
  public var sessionStore: String?

  public init(
    loadSnapshot: @escaping @Sendable (String) throws -> WorkflowRuntimePersistenceSnapshot,
    loadSnapshots: @escaping @Sendable () throws -> [WorkflowRuntimePersistenceSnapshot] = {
      throw WorkflowRuntimePersistenceStoreError.notFound("workflow session discovery is unavailable")
    },
    sessionStore: String? = nil
  ) {
    self.loadSnapshot = loadSnapshot
    self.loadSnapshots = loadSnapshots
    self.sessionStore = sessionStore
  }

  public init(store: SQLiteWorkflowRuntimePersistenceStore) {
    self.init(
      loadSnapshot: { sessionId in try store.load(sessionId: sessionId) },
      loadSnapshots: { try store.loadAll() },
      sessionStore: store.rootDirectory
    )
  }

  public init(fileStore: FileWorkflowRuntimePersistenceStore) {
    self.init(
      loadSnapshot: { sessionId in try fileStore.load(sessionId: sessionId) },
      loadSnapshots: { try fileStore.loadAll() },
      sessionStore: fileStore.rootDirectory
    )
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

  public func workflowSessions(_ request: GraphQLWorkflowSessionsRequest) async -> GraphQLWorkflowSessionsResult {
    do {
      let status = try request.status.map { rawStatus in
        guard let parsedStatus = WorkflowSessionStatus(rawValue: rawStatus) else {
          throw GraphQLRuntimeSnapshotQueryError.invalidStatus(rawStatus)
        }
        return parsedStatus
      }
      let limit = max(1, min(request.limit ?? 10, 100))
      let sessions = try loadSnapshots()
        .map(\.session)
        .filter { session in
          if let workflowName = request.workflowName, session.workflowId != workflowName {
            return false
          }
          if let status, session.status != status {
            return false
          }
          return true
        }
        .sorted {
          if $0.updatedAt == $1.updatedAt {
            return $0.sessionId < $1.sessionId
          }
          return $0.updatedAt > $1.updatedAt
        }
        .prefix(limit)
        .map {
          GraphQLContractProjector.projectSessionSummary(
            session: $0,
            workflowName: $0.workflowId,
            sessionStore: sessionStore
          )
        }
      return GraphQLWorkflowSessionsResult(
        result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
        sessions: Array(sessions)
      )
    } catch GraphQLRuntimeSnapshotQueryError.invalidStatus(let status) {
      return GraphQLWorkflowSessionsResult(
        result: GraphQLControlPlaneResult(
          accepted: false,
          status: GraphQLLoopEvidenceQueryStatus.invalidRequest.rawValue,
          diagnostics: ["invalid workflow session status: \(status)"]
        )
      )
    } catch {
      return GraphQLWorkflowSessionsResult(
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

private enum GraphQLRuntimeSnapshotQueryError: Error {
  case invalidStatus(String)
}
