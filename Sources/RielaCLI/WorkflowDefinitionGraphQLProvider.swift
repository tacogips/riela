import Foundation
import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry

public struct WorkflowDefinitionGraphQLProvider: WorkflowDefinitionGraphQLProviding {
  private let workingDirectory: String
  private let sessionStoreRoot: String?
  private let environment: [String: String]
  private let resolver = FileSystemWorkflowBundleResolver()

  public init(workingDirectory: String, sessionStoreRoot: String?, environment: [String: String]) {
    self.workingDirectory = workingDirectory
    self.sessionStoreRoot = sessionStoreRoot
    self.environment = environment
  }

  public func workflowDefinitionHistory(workflowName: String, nodeId: String?, limit: Int?, storeScope: String?) async throws -> [GraphQLWorkflowDefinitionAuditRecord] {
    try mapDefinitionErrors {
      try service(workflowName: workflowName, storeScope: storeScope).history(workflowName: workflowName, nodeId: nodeId, limit: limit).map(auditDTO)
    }
  }

  public func workflowDefinition(workflowName: String, versionId: String?, storeScope: String?) async throws -> GraphQLWorkflowDefinitionVersion? {
    let service = try service(workflowName: workflowName, storeScope: storeScope)
    let result = try mapDefinitionErrors { try service.show(workflowName: workflowName, versionId: versionId) }
    let documentJSON = try definitionDocumentJSON(result.document)
    return versionDTO(result.version, documentJSON: documentJSON)
  }

  public func workflowDefinitionDiff(workflowName: String, fromVersionId: String?, toVersionId: String?, againstFile: Bool?, storeScope: String?) async throws -> [GraphQLWorkflowDefinitionDiffEntry] {
    let options = againstFile == true ? resolution(workflowName: workflowName) : nil
    return try mapDefinitionErrors {
      try service(workflowName: workflowName, storeScope: storeScope)
        .diff(workflowName: workflowName, fromVersionId: fromVersionId, toVersionId: toVersionId, againstFile: options).map(diffDTO)
    }
  }

  public func updateWorkflowDefinition(input: UpdateWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionUpdatePayload {
    let actor = try actor(kind: input.actorKind, id: input.actorId)
    let reason = try requiredReason(input.reason)
    guard (input.patchJSON != nil) != (input.authoredFiles != nil) else {
      throw graphError("INVALID_DEFINITION_INPUT", "provide exactly one of patchJSON or authoredFiles")
    }
    let source: WorkflowDefinitionUpdateSource
    if let patch = input.patchJSON {
      guard let data = patch.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        throw graphError("DEFINITION_INVALID_PATCH", "patchJSON must contain valid JSON")
      }
      source = .patch(json)
    } else if let files = input.authoredFiles {
      var authored: [String: String] = [:]
      for file in files {
        guard authored.updateValue(file.content, forKey: file.path) == nil else {
          throw graphError("INVALID_DEFINITION_INPUT", "authoredFiles contains duplicate path \(file.path)")
        }
      }
      source = .authoredFiles(authored)
    } else { throw graphError("INVALID_DEFINITION_INPUT", "missing update source") }
    let result = try mapDefinitionErrors {
      try service(workflowName: input.workflowName, storeScope: input.storeScope).update(
        workflowName: input.workflowName, source: source, reason: reason,
        expectedVersionId: input.expectedVersionId, evidence: try evidence(input.evidence), actor: actor
      )
    }
    let doc = try result.version.map { try service(workflowName: input.workflowName, storeScope: input.storeScope).show(workflowName: input.workflowName, versionId: $0.versionId).document }
    return GraphQLWorkflowDefinitionUpdatePayload(
      outcome: result.outcome.rawValue, versionId: result.versionId, digest: result.digest,
      version: try zipOptional(result.version, doc).map { versionDTO($0.0, documentJSON: try definitionDocumentJSON($0.1)) },
      audit: result.audit.map(auditDTO), diff: result.diff.map(diffDTO)
    )
  }

  public func updateWorkflowDefinitionPrompt(input: UpdateWorkflowDefinitionPromptInput) async throws -> GraphQLWorkflowDefinitionMutationPayload {
    let actor = try actor(kind: input.actorKind, id: input.actorId)
    let reason = try requiredReason(input.reason)
    let field: WorkflowDefinitionPromptField
    do { field = try WorkflowDefinitionPromptField(parsing: input.field) } catch {
      throw graphError("INVALID_DEFINITION_INPUT", "unsupported prompt field")
    }
    let (version, audit) = try mapDefinitionErrors {
      try service(workflowName: input.workflowName, storeScope: input.storeScope).updatePrompt(
        workflowName: input.workflowName, nodeId: input.nodeId, field: field, text: input.text, reason: reason,
        expectedVersionId: input.expectedVersionId, evidence: try evidence(input.evidence), actor: actor
      )
    }
    let doc = try service(workflowName: input.workflowName, storeScope: input.storeScope).show(workflowName: input.workflowName, versionId: version.versionId).document
    return GraphQLWorkflowDefinitionMutationPayload(
      version: versionDTO(version, documentJSON: try definitionDocumentJSON(doc)),
      audit: auditDTO(audit)
    )
  }

  public func restoreWorkflowDefinition(input: RestoreWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionMutationPayload {
    let actor = try actor(kind: input.actorKind, id: input.actorId)
    let reason = try requiredReason(input.reason)
    let (version, audit) = try mapDefinitionErrors {
      try service(workflowName: input.workflowName, storeScope: input.storeScope).restore(
        workflowName: input.workflowName, versionId: input.versionId, reason: reason,
        evidence: try evidence(input.evidence), actor: actor
      )
    }
    let doc = try service(workflowName: input.workflowName, storeScope: input.storeScope).show(workflowName: input.workflowName, versionId: version.versionId).document
    return GraphQLWorkflowDefinitionMutationPayload(
      version: versionDTO(version, documentJSON: try definitionDocumentJSON(doc)),
      audit: auditDTO(audit)
    )
  }

  public func importWorkflowDefinition(input: ImportWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionImportPayload {
    let actor = try actor(kind: input.actorKind, id: input.actorId)
    if input.force == true && (input.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
      throw graphError("DEFINITION_REASON_REQUIRED", "force import requires a reason")
    }
    let options = resolution(workflowName: input.workflowName, scope: input.scope, directory: input.workflowDefinitionDir)
    let storeScope = try workflowScope(input.storeScope)
    let root: String
    if let existing = try WorkflowDefinitionStoreSelection.rootWithHead(
      workflowName: input.workflowName, sessionStore: sessionStoreRoot,
      scope: storeScope, workingDirectory: workingDirectory, environment: environment
    ) { root = existing } else {
      let file = try resolver.resolve(options)
      root = WorkflowDefinitionStoreSelection.seedRoot(sessionStore: sessionStoreRoot, resolution: options, fileBundle: file, environment: environment)
    }
    let service = WorkflowDefinitionService(storeRoot: root, fileResolver: resolver)
    let result = try mapDefinitionErrors {
      try service.importDefinition(
        resolution: options, force: input.force ?? false, reason: input.reason,
        evidence: try evidence(input.evidence), actor: actor
      )
    }
    let version: GraphQLWorkflowDefinitionVersion?
    if let source = result.version {
      let doc = try service.show(workflowName: input.workflowName, versionId: source.versionId).document
      version = versionDTO(source, documentJSON: try definitionDocumentJSON(doc))
    } else { version = nil }
    return GraphQLWorkflowDefinitionImportPayload(outcome: result.outcome.rawValue, version: version, diff: result.diff.map(diffDTO), audit: result.audit.map(auditDTO))
  }

  public func exportWorkflowDefinition(input: ExportWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionExportPayload {
    let service = try service(workflowName: input.workflowName, storeScope: input.storeScope)
    let files = try mapDefinitionErrors {
      try service.export(workflowName: input.workflowName, versionId: input.versionId, target: input.writeToSource == true ? .source(overwrite: true) : nil)
    }
    return GraphQLWorkflowDefinitionExportPayload(files: files.map { GraphQLWorkflowDefinitionFile(path: $0.path, content: $0.content) }, wroteToSource: input.writeToSource == true)
  }

  private func service(workflowName: String, storeScope: String?) throws -> WorkflowDefinitionService {
    let scope = try workflowScope(storeScope)
    guard let root = try WorkflowDefinitionStoreSelection.rootWithHead(
      workflowName: workflowName, sessionStore: sessionStoreRoot, scope: scope,
      workingDirectory: workingDirectory, environment: environment
    ) else { throw graphError("DEFINITION_NOT_REGISTERED", "workflow \(workflowName) is not registered") }
    return WorkflowDefinitionService(storeRoot: root, fileResolver: resolver)
  }

  private func resolution(workflowName: String, scope: String? = nil, directory: String? = nil) -> WorkflowResolutionOptions {
    WorkflowResolutionOptions(workflowName: workflowName, scope: (try? workflowScope(scope)) ?? .auto,
      workflowDefinitionDir: directory, workingDirectory: workingDirectory)
  }

  private func workflowScope(_ value: String?) throws -> WorkflowScope {
    guard let value else { return .auto }
    guard let scope = WorkflowScope(rawValue: value), scope != .direct else {
      throw graphError("INVALID_DEFINITION_INPUT", "invalid store scope")
    }
    return scope
  }

  private func actor(kind: String?, id: String?) throws -> WorkflowDefinitionActor {
    let raw = kind ?? "api"
    guard let actorKind = WorkflowDefinitionActorKind(rawValue: raw), actorKind == .api || actorKind == .user else {
      throw graphError("INVALID_DEFINITION_INPUT", "GraphQL actorKind must be api or user")
    }
    return WorkflowDefinitionActor(kind: actorKind, id: id)
  }

  private func evidence(_ refs: [String]?) throws -> [WorkflowDefinitionEvidenceRef] {
    do { return try (refs ?? []).map(WorkflowDefinitionEvidenceRef.parse) } catch {
      throw graphError("INVALID_DEFINITION_INPUT", "invalid evidence reference")
    }
  }

  private func requiredReason(_ reason: String?) throws -> String {
    guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
      throw graphError("DEFINITION_REASON_REQUIRED", "definition changes require a non-empty reason")
    }
    return reason
  }
}

private func mapDefinitionErrors<T>(_ operation: () throws -> T) throws -> T {
  do {
    return try operation()
  } catch let error as WorkflowDefinitionGraphQLError { throw error } catch let error as WorkflowDefinitionServiceError {
    let code: String
    switch error.code {
    case .reasonRequired: code = "DEFINITION_REASON_REQUIRED"
    case .definitionNotRegistered: code = "DEFINITION_NOT_REGISTERED"
    case .definitionConflict: code = "DEFINITION_STALE"
    case .invalidPatch: code = "DEFINITION_INVALID_PATCH"
    case .invalidDefinition: code = "DEFINITION_INVALID"
    }
    throw graphError(code, error.message)
  } catch let error as WorkflowDefinitionStoreError {
    let code: String
    switch error.code {
    case .headMissing: code = "DEFINITION_NOT_REGISTERED"
    case .staleHead: code = "DEFINITION_STALE"
    case .versionNotFound: code = "DEFINITION_VERSION_NOT_FOUND"
    case .missingReason: code = "DEFINITION_REASON_REQUIRED"
    case .invalidEvidence: code = "INVALID_DEFINITION_INPUT"
    default: code = "DEFINITION_OPERATION_FAILED"
    }
    throw graphError(code, error.message)
  }
}

private func graphError(_ code: String, _ message: String) -> WorkflowDefinitionGraphQLError { .init(code: code, message: message) }

private func versionDTO(_ version: WorkflowDefinitionVersion, documentJSON: String) -> GraphQLWorkflowDefinitionVersion {
  GraphQLWorkflowDefinitionVersion(versionId: version.versionId, workflowName: version.workflowName,
    parentVersionId: version.parentVersionId, documentDigest: version.documentDigest, operation: version.operation.rawValue,
    sourceDirectory: version.sourceDirectory, sourceScope: version.sourceScope, provenance: version.provenance,
    actor: GraphQLWorkflowDefinitionActor(kind: version.actor.kind.rawValue, id: version.actor.id),
    createdAt: ISO8601DateFormatter().string(from: version.createdAt), documentJSON: documentJSON)
}

private func auditDTO(_ audit: WorkflowDefinitionAuditRecord) -> GraphQLWorkflowDefinitionAuditRecord {
  GraphQLWorkflowDefinitionAuditRecord(auditId: audit.auditId, workflowName: audit.workflowName,
    operation: audit.operation.rawValue, versionId: audit.versionId, previousVersionId: audit.previousVersionId,
    targetNodeId: audit.targetNodeId, targetField: audit.targetField, beforeDigest: audit.beforeDigest,
    afterDigest: audit.afterDigest, reason: audit.reason,
    evidence: audit.evidence.map { "\($0.kind.rawValue):\($0.id)" },
    actor: GraphQLWorkflowDefinitionActor(kind: audit.actor.kind.rawValue, id: audit.actor.id),
    approvalState: audit.approvalState.rawValue,
    overwrittenChanges: audit.overwrittenChanges.map { .init(sinceVersionId: $0.sinceVersionId, auditIds: $0.auditIds) },
    createdAt: ISO8601DateFormatter().string(from: audit.createdAt))
}

private func diffDTO(_ diff: WorkflowDefinitionDiffEntry) -> GraphQLWorkflowDefinitionDiffEntry {
  GraphQLWorkflowDefinitionDiffEntry(path: diff.path, op: diff.op.rawValue,
    before: diff.before.map(jsonString), after: diff.after.map(jsonString))
}

private func jsonString(_ value: JSONValue) -> String {
  guard let data = try? JSONEncoder().encode(value) else { return "null" }
  return String(bytes: data, encoding: .utf8) ?? "null"
}

private func definitionDocumentJSON(_ document: WorkflowDefinitionDocument) throws -> String {
  guard let text = String(bytes: try document.canonicalData(), encoding: .utf8) else {
    throw graphError("DEFINITION_OPERATION_FAILED", "definition document was not valid UTF-8")
  }
  return text
}

private func zipOptional<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
  guard let first, let second else { return nil }; return (first, second)
}
