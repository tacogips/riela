import Foundation
import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry

extension WorkflowDefinitionGraphQLProvider {
  public func workflowVersions(workflowName: String, scope: String?, limit: Int?, beforeSnapshotId: String?) async throws -> GraphQLWorkflowVersionsPayload {
    let count = limit ?? 100
    guard (1...1000).contains(count) else { throw versionError("INVALID_DEFINITION_INPUT", "limit must be between 1 and 1000") }
    let result = try WorkflowSnapshotService().list(versionRequest(workflowName, scope), limit: count, beforeSnapshotId: beforeSnapshotId)
    return GraphQLWorkflowVersionsPayload(workflowId: result.workflow.workflowId, snapshots: result.snapshots.map {
      GraphQLWorkflowBundleSnapshotSummary(snapshotId: $0.snapshotId, parentSnapshotId: $0.parentSnapshotId,
        createdAt: ISO8601DateFormatter().string(from: $0.createdAt), bundleDigest: $0.bundleDigest,
        createdBySessionId: $0.createdBySessionId, createdBeforeChangeSetId: $0.createdBeforeChangeSetId,
        createdBeforeRestoreId: $0.createdBeforeRestoreId, mutationReferences: $0.mutationReferences, restoreReferences: $0.restoreReferences)
    }, nextBeforeSnapshotId: result.nextBeforeSnapshotId)
  }

  public func workflowVersionDiff(workflowName: String, scope: String?, from: String, to: String, includeContent: Bool?) async throws -> GraphQLWorkflowVersionDiffPayload {
    let result = try WorkflowSnapshotService().diff(versionRequest(workflowName, scope), from: from, to: to, includeContent: includeContent ?? false)
    return GraphQLWorkflowVersionDiffPayload(workflowId: result.workflow.workflowId, from: result.from, to: result.to,
      differences: result.differences.map { item in
        GraphQLWorkflowVersionDifference(relativePath: item.relativePath, kind: item.kind.rawValue,
          content: item.content.map { GraphQLWorkflowVersionContentDiff(unified: $0.unified, binary: $0.binary, tooLarge: $0.tooLarge, limitBytes: $0.limitBytes) })
      })
  }

  public func restoreWorkflowVersion(input: RestoreWorkflowVersionInput) async throws -> GraphQLRestoreWorkflowVersionPayload {
    let request = try versionRequest(input.workflowName, input.scope)
    guard let kind = WorkflowDefinitionActorKind(rawValue: input.actorKind ?? "api"), kind == .api || kind == .user else {
      throw versionError("INVALID_DEFINITION_INPUT", "GraphQL actorKind must be api or user")
    }
    if let reason = input.reason, reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw versionError("INVALID_DEFINITION_INPUT", "reason must not be empty")
    }
    let service = WorkflowSnapshotService()
    do { _ = try service.show(request, snapshotId: input.snapshotId) } catch {
      throw versionError(WorkflowHistoryGraphQLErrorCode.workflowVersionNotFound, "workflow version not found: \(input.snapshotId)")
    }
    let actor = WorkflowDefinitionActor(kind: kind, id: input.actorId)
    let recorder = WorkflowDefinitionChangeRecorder(sessionStoreRoot: sessionStoreRoot, workingDirectory: workingDirectory,
      environment: environment, fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
    do {
      let preview = try service.restore(request, snapshotId: input.snapshotId, approved: false, reason: input.reason, actor: actor, recorder: recorder)
      var result = preview
      if input.apply == true {
        guard preview.dirtyConflicts.isEmpty else {
          throw versionError(WorkflowHistoryGraphQLErrorCode.workflowRestoreDirtyConflicts, preview.dirtyConflicts.joined(separator: ", "))
        }
        result = try service.restore(request, snapshotId: input.snapshotId, approved: true, reason: input.reason, actor: actor, recorder: recorder)
      }
      return GraphQLRestoreWorkflowVersionPayload(workflowId: result.workflow.workflowId, sourceSnapshotId: result.sourceSnapshotId,
        dryRun: result.dryRun, restored: result.restored, beforeBundleDigest: result.beforeBundleDigest,
        requestedBundleDigest: result.requestedBundleDigest, preRestoreSnapshotId: result.preRestoreSnapshotId,
        restoredFiles: result.restoredFiles, dirtyConflicts: result.dirtyConflicts, definitionVersionId: result.definitionVersionId,
        definitionAuditId: result.definitionAuditId, definitionWarnings: result.definitionWarnings)
    } catch let error as WorkflowRegistryError {
      switch error.code {
      case .immutableWorkflow: throw versionError(WorkflowHistoryGraphQLErrorCode.workflowImmutable, error.message)
      case .definitionSyncPending: throw versionError(WorkflowHistoryGraphQLErrorCode.definitionSyncPending, error.message)
      case .definitionSyncFailed: throw versionError(WorkflowHistoryGraphQLErrorCode.definitionSyncFailed, "files restored; definition history pending")
      default: throw error
      }
    } catch let error as CLIUsageError where error.message.hasPrefix("definition_sync_failed:") {
      throw versionError(WorkflowHistoryGraphQLErrorCode.definitionSyncFailed, "files restored; definition history pending")
    } catch let error as CLIUsageError where error.message.hasPrefix("workflow restore refused dirty conflicts:") {
      throw versionError(WorkflowHistoryGraphQLErrorCode.workflowRestoreDirtyConflicts, error.message)
    }
  }

  private func versionRequest(_ workflowName: String, _ scope: String?) throws -> WorkflowSnapshotTargetRequest {
    guard let parsed = WorkflowScope(rawValue: scope ?? "auto"), parsed != .direct else {
      throw versionError("INVALID_DEFINITION_INPUT", "invalid workflow scope")
    }
    return WorkflowSnapshotTargetRequest(workflowName: workflowName, scope: parsed, workflowDefinitionDir: nil, workingDirectory: workingDirectory)
  }
}

private func versionError(_ code: String, _ message: String) -> WorkflowDefinitionGraphQLError {
  WorkflowDefinitionGraphQLError(code: code, message: message)
}
