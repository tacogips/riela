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

  /// Loop session overviews, projected from the same persisted snapshots the CLI
  /// reads (no GraphQL-only computation). Newest first, bounded by `limit`.
  public func loopSessions(
    workflowId: String? = nil,
    status: String? = nil,
    limit: Int? = nil
  ) async -> GraphQLLoopSessionsResult {
    do {
      let snapshots: [WorkflowRuntimePersistenceSnapshot] = try loadSnapshots()
      var overviews: [LoopSessionOverview] = snapshots.map(Self.overview(from:))
      if let workflowId {
        overviews = overviews.filter { $0.workflowId == workflowId }
      }
      if let status {
        overviews = overviews.filter { $0.sessionStatus == status }
      }
      overviews = Self.newestFirst(overviews)
      if let limit { overviews = Array(overviews.prefix(max(0, limit))) }
      return GraphQLLoopSessionsResult(
        result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
        sessions: overviews.map(GraphQLLoopSessionOverviewDTO.init)
      )
    } catch {
      return GraphQLLoopSessionsResult(result: GraphQLControlPlaneResult(
        accepted: false,
        status: GraphQLLoopEvidenceQueryStatus.error.rawValue,
        diagnostics: [String(describing: error)]
      ))
    }
  }

  /// Bounded-window loop statistics for a workflow, aggregated from the same
  /// persisted overviews the CLI uses.
  public func loopWorkflowStats(workflowId: String, limit: Int? = nil) async -> GraphQLLoopWorkflowStatsResult {
    do {
      let snapshots: [WorkflowRuntimePersistenceSnapshot] = try loadSnapshots()
      let allOverviews: [LoopSessionOverview] = snapshots.map(Self.overview(from:))
      let overviews = Self.newestFirst(allOverviews.filter { $0.workflowId == workflowId })
      let stats = LoopWorkflowStats.aggregate(
        workflowId: workflowId,
        overviews: overviews,
        limit: limit ?? 50
      )
      return GraphQLLoopWorkflowStatsResult(
        result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
        stats: GraphQLLoopWorkflowStatsDTO(stats: stats)
      )
    } catch {
      return GraphQLLoopWorkflowStatsResult(result: GraphQLControlPlaneResult(
        accepted: false,
        status: GraphQLLoopEvidenceQueryStatus.error.rawValue,
        diagnostics: [String(describing: error)]
      ))
    }
  }

  /// Evidence-level diff of two sessions' persisted manifests.
  public func loopEvidenceDiff(
    baseSessionId: String,
    targetSessionId: String
  ) async -> GraphQLLoopEvidenceDiffResult {
    do {
      guard let base = try loadSnapshot(baseSessionId).loopEvidence else {
        return Self.diffMissingEvidence(baseSessionId)
      }
      guard let target = try loadSnapshot(targetSessionId).loopEvidence else {
        return Self.diffMissingEvidence(targetSessionId)
      }
      let diff = LoopEvidenceDiffer.diff(base: base, target: target)
      return GraphQLLoopEvidenceDiffResult(
        result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
        diff: GraphQLLoopEvidenceDiffDTO(diff: diff)
      )
    } catch WorkflowRuntimePersistenceStoreError.notFound(let sessionId) {
      return GraphQLLoopEvidenceDiffResult(result: GraphQLControlPlaneResult(
        accepted: false,
        status: GraphQLLoopEvidenceQueryStatus.notFound.rawValue,
        diagnostics: ["runtime snapshot not found: \(sessionId)"]
      ))
    } catch {
      return GraphQLLoopEvidenceDiffResult(result: GraphQLControlPlaneResult(
        accepted: false,
        status: GraphQLLoopEvidenceQueryStatus.error.rawValue,
        diagnostics: [String(describing: error)]
      ))
    }
  }

  private static func diffMissingEvidence(_ sessionId: String) -> GraphQLLoopEvidenceDiffResult {
    GraphQLLoopEvidenceDiffResult(result: GraphQLControlPlaneResult(
      accepted: false,
      status: GraphQLLoopEvidenceQueryStatus.noEvidence.rawValue,
      diagnostics: ["loop evidence not found for session \(sessionId)"]
    ))
  }

  private static func newestFirst(_ overviews: [LoopSessionOverview]) -> [LoopSessionOverview] {
    overviews.sorted { lhs, rhs in
      lhs.updatedAt == rhs.updatedAt ? lhs.sessionId < rhs.sessionId : lhs.updatedAt > rhs.updatedAt
    }
  }

  private static func overview(from snapshot: WorkflowRuntimePersistenceSnapshot) -> LoopSessionOverview {
    let summary = snapshot.loopEvidence.map {
      LoopSessionSummary.make(manifest: $0, loopMetadata: snapshot.loopMetadata)
    }
    return LoopSessionOverview.make(session: snapshot.session, summary: summary)
  }
}

public struct GraphQLWorkflowInstanceService: Sendable {
  public var store: any WorkflowInstanceStoring

  public init(store: any WorkflowInstanceStoring) {
    self.store = store
  }

  public func workflowInstances(
    workflowId: String? = nil
  ) async -> GraphQLWorkflowInstanceQueryResult<[GraphQLWorkflowInstanceDTO]> {
    do {
      let instances = try store.list(workflowId: workflowId).map(GraphQLWorkflowInstanceDTO.init)
      return GraphQLWorkflowInstanceQueryResult(
        result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
        value: instances
      )
    } catch {
      return instanceQueryFailure(error)
    }
  }

  public func workflowInstance(
    identity: String,
    workflowId: String? = nil
  ) async -> GraphQLWorkflowInstanceQueryResult<GraphQLWorkflowInstanceDTO> {
    do {
      guard let instance = try store.find(identity: identity, workflowId: workflowId) else {
        return GraphQLWorkflowInstanceQueryResult(
          result: GraphQLControlPlaneResult(
            accepted: false,
            status: GraphQLLoopEvidenceQueryStatus.notFound.rawValue,
            diagnostics: ["workflow instance not found: \(identity)"]
          )
        )
      }
      return GraphQLWorkflowInstanceQueryResult(
        result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
        value: GraphQLWorkflowInstanceDTO(instance: instance)
      )
    } catch {
      return instanceQueryFailure(error)
    }
  }

  public func createWorkflowInstance(
    _ input: GraphQLWorkflowInstanceInput
  ) async -> GraphQLWorkflowInstanceMutationResult {
    await saveWorkflowInstance(input)
  }

  public func updateWorkflowInstance(
    _ input: GraphQLWorkflowInstanceInput
  ) async -> GraphQLWorkflowInstanceMutationResult {
    await saveWorkflowInstance(input)
  }

  public func deleteWorkflowInstance(
    identity: String,
    workflowId: String? = nil
  ) async -> GraphQLWorkflowInstanceMutationResult {
    do {
      let existing = try store.find(identity: identity, workflowId: workflowId)
      try store.remove(identity: identity, workflowId: workflowId)
      return GraphQLWorkflowInstanceMutationResult(
        result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
        instance: existing.map(GraphQLWorkflowInstanceDTO.init)
      )
    } catch WorkflowInstanceStoreError.notFound {
      return GraphQLWorkflowInstanceMutationResult(
        result: GraphQLControlPlaneResult(
          accepted: false,
          status: GraphQLLoopEvidenceQueryStatus.notFound.rawValue,
          diagnostics: ["workflow instance not found: \(identity)"]
        )
      )
    } catch {
      return GraphQLWorkflowInstanceMutationResult(result: instanceControlPlaneFailure(error))
    }
  }

  private func saveWorkflowInstance(
    _ input: GraphQLWorkflowInstanceInput
  ) async -> GraphQLWorkflowInstanceMutationResult {
    do {
      let definition = input.definition
      try store.save(definition)
      return GraphQLWorkflowInstanceMutationResult(
        result: GraphQLControlPlaneResult(accepted: true, status: GraphQLLoopEvidenceQueryStatus.found.rawValue),
        instance: GraphQLWorkflowInstanceDTO(instance: definition)
      )
    } catch {
      return GraphQLWorkflowInstanceMutationResult(result: instanceControlPlaneFailure(error))
    }
  }

  private func instanceQueryFailure<Value: Codable & Equatable & Sendable>(
    _ error: Error
  ) -> GraphQLWorkflowInstanceQueryResult<Value> {
    GraphQLWorkflowInstanceQueryResult(result: instanceControlPlaneFailure(error))
  }

  private func instanceControlPlaneFailure(_ error: Error) -> GraphQLControlPlaneResult {
    let status: String
    switch error {
    case WorkflowInstanceStoreError.invalidIdentity,
         WorkflowInstanceStoreError.ambiguousIdentity,
         WorkflowInstanceStoreError.unsupportedScope,
         WorkflowInstanceStoreError.duplicateIdentity:
      status = GraphQLLoopEvidenceQueryStatus.invalidRequest.rawValue
    case WorkflowInstanceStoreError.notFound:
      status = GraphQLLoopEvidenceQueryStatus.notFound.rawValue
    default:
      status = GraphQLLoopEvidenceQueryStatus.error.rawValue
    }
    return GraphQLControlPlaneResult(
      accepted: false,
      status: status,
      diagnostics: [String(describing: error)]
    )
  }
}

private enum GraphQLRuntimeSnapshotQueryError: Error {
  case invalidStatus(String)
}
