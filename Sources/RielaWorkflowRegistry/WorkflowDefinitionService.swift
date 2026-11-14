import Foundation
import RielaAddons
import RielaCore

public enum WorkflowDefinitionPromptField: Equatable, Sendable {
  public enum Kind: String, Sendable { case promptTemplate, systemPromptTemplate, sessionStartPromptTemplate }
  case node(Kind)
  case variant(key: String, Kind)

  public init(parsing value: String) throws {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 1, let kind = Kind(rawValue: parts[0]) {
      self = .node(kind)
    } else if parts.count == 3, parts[0] == "promptVariants", !parts[1].isEmpty, let kind = Kind(rawValue: parts[2]) {
      self = .variant(key: parts[1], kind)
    } else {
      throw WorkflowDefinitionServiceError(code: .invalidDefinition, message: "unsupported prompt field \(value)")
    }
  }

  fileprivate var tokens: [String] {
    switch self {
    case let .node(kind): [kind.rawValue]
    case let .variant(key, kind): ["promptVariants", key, kind.rawValue]
    }
  }

}

public struct WorkflowDefinitionServiceError: Error, Equatable, CustomStringConvertible, Sendable {
  public enum Code: String, Codable, Sendable {
    case reasonRequired = "reason_required"
    case definitionNotRegistered = "definition_not_registered"
    case definitionConflict = "definition_conflict"
    case invalidPatch = "invalid_patch"
    case invalidDefinition = "invalid_definition"
  }

  public var code: Code
  public var message: String

  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }

  public var description: String { message }
}

public enum WorkflowDefinitionUpdateSource: Equatable, Sendable {
  case patch(JSONValue)
  case authoredFiles([String: String])
  case fromDirectory(WorkflowResolutionOptions)
}

public enum WorkflowDefinitionUpdateOutcome: String, Codable, Equatable, Sendable { case updated, unchanged }

public struct WorkflowDefinitionUpdateResult: Codable, Equatable, Sendable {
  public var outcome: WorkflowDefinitionUpdateOutcome
  public var versionId: String
  public var digest: String
  public var version: WorkflowDefinitionVersion?
  public var audit: WorkflowDefinitionAuditRecord?
  public var diff: [WorkflowDefinitionDiffEntry]
}

public enum WorkflowDefinitionImportOutcome: String, Codable, Equatable, Sendable { case seeded, unchanged, differs, forceUpdated }

public struct WorkflowDefinitionImportResult: Codable, Equatable, Sendable {
  public var outcome: WorkflowDefinitionImportOutcome
  public var version: WorkflowDefinitionVersion?
  public var diff: [WorkflowDefinitionDiffEntry]
  public var audit: WorkflowDefinitionAuditRecord?
}

public enum WorkflowDefinitionExportTarget: Equatable, Sendable {
  case directory(String)
  case source(overwrite: Bool)
}

public struct WorkflowDefinitionExportedFile: Codable, Equatable, Sendable {
  public var path: String
  public var content: String
}

public struct WorkflowDefinitionService: Sendable {
  private struct AuthoredEditRequest {
    var workflowName: String
    var current: WorkflowDefinitionCurrent
    var currentDoc: WorkflowDefinitionDocument
    var newAuthoredFiles: [String: String]
    var operation: WorkflowDefinitionOperation
    var targetNodeId: String?
    var targetField: String?
    var reason: String
    var expected: String?
    var evidence: [WorkflowDefinitionEvidenceRef]
    var actor: WorkflowDefinitionActor
  }

  private let store: WorkflowDefinitionStore
  private let storeRoot: String
  private let fileResolver: any WorkflowBundleResolving

  public init(storeRoot: String, fileResolver: any WorkflowBundleResolving) {
    self.storeRoot = storeRoot
    self.store = WorkflowDefinitionStore(rootDirectory: storeRoot)
    self.fileResolver = fileResolver
  }

  public func lookup(workflowName: String) throws -> ResolvedWorkflowBundle? {
    guard let current = try store.current(workflowName: workflowName) else { return nil }
    return try document(current.document).resolvedBundle(head: current.head, version: current.version, storeRoot: storeRoot)
  }

  public func loadPinned(versionId: String) throws -> ResolvedWorkflowBundle {
    guard let version = try store.version(versionId: versionId), let data = try store.blob(digest: version.documentDigest) else {
      throw WorkflowDefinitionStoreError(code: .versionNotFound, message: "definition version \(versionId) was not found")
    }
    return try document(data).resolvedBundle(head: nil, version: version, storeRoot: storeRoot)
  }

  public func seedIfAbsent(
    fileBundle: ResolvedWorkflowBundle,
    workflowName: String,
    actor: WorkflowDefinitionActor
  ) throws -> ResolvedWorkflowBundle {
    let doc = try WorkflowDefinitionDocument.make(from: fileBundle)
    let data = try doc.canonicalData()
    let write = WorkflowDefinitionWrite(
      workflowName: workflowName,
      operation: .seed,
      documentData: data,
      documentDigest: JSONCanonical.sha256Hex(data),
      sourceDirectory: fileBundle.workflowDirectory,
      sourceScope: fileBundle.sourceScope.rawValue,
      provenance: fileBundle.provenance.rawValue,
      actor: actor,
      reason: "seeded from \(fileBundle.workflowDirectory) on first service run"
    )
    do {
      switch try store.commit(write) {
      case let .created(version, _): return doc.resolvedBundle(head: try store.head(workflowName: workflowName), version: version, storeRoot: storeRoot)
      case .alreadyRegistered:
        guard let current = try lookup(workflowName: workflowName) else { throw notRegistered(workflowName) }
        return current
      }
    } catch { throw map(error) }
  }

  public func importDefinition(
    resolution: WorkflowResolutionOptions,
    force: Bool,
    reason: String?,
    evidence: [WorkflowDefinitionEvidenceRef],
    actor: WorkflowDefinitionActor
  ) throws -> WorkflowDefinitionImportResult {
    if force { try requireReason(reason) }
    let bundle = try fileResolver.resolve(resolution)
    let fileDoc = try WorkflowDefinitionDocument.make(from: bundle)
    let fileData = try fileDoc.canonicalData()
    let digest = JSONCanonical.sha256Hex(fileData)
    guard let current = try store.current(workflowName: resolution.workflowName) else {
      if force { throw WorkflowDefinitionStoreError(code: .headMissing, message: "workflow is not registered; import without --force first") }
      let write = WorkflowDefinitionWrite(
        workflowName: resolution.workflowName,
        operation: .import,
        documentData: fileData,
        documentDigest: digest,
        sourceDirectory: bundle.workflowDirectory,
        sourceScope: bundle.sourceScope.rawValue,
        provenance: bundle.provenance.rawValue,
        actor: actor,
        reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "initial import from \(bundle.workflowDirectory)",
        evidence: evidence
      )
      do {
        guard case let .created(version, audit) = try store.commit(write) else {
          let raced = try show(workflowName: resolution.workflowName, versionId: nil)
          let latest = try store.current(workflowName: resolution.workflowName)
          return WorkflowDefinitionImportResult(outcome: raced.version.documentDigest == digest ? .unchanged : .differs, version: nil,
                                                diff: diffDocuments(try latest.map { try document($0.document) }, fileDoc), audit: nil)
        }
        return WorkflowDefinitionImportResult(outcome: .seeded, version: version, diff: [], audit: audit)
      } catch { throw map(error) }
    }
    let currentDoc = try document(current.document)
    let diff = diffDocuments(currentDoc, fileDoc)
    guard force else {
      return WorkflowDefinitionImportResult(outcome: current.version.documentDigest == digest ? .unchanged : .differs, version: current.version, diff: diff, audit: nil)
    }
    let overwrittenAudits = try store.auditRecords(workflowName: resolution.workflowName, afterVersionId: current.head.lastFileVersionId)
      .filter { [.updatePrompt, .update, .restore].contains($0.operation) }
    let baseline = try store.version(versionId: current.head.lastFileVersionId).flatMap { try store.blob(digest: $0.documentDigest) }
    let overwritten = WorkflowDefinitionOverwrittenChanges(
      sinceVersionId: current.head.lastFileVersionId,
      auditIds: overwrittenAudits.map(\.auditId),
      diff: baseline.map { diffDocuments(try? document($0), currentDoc) } ?? []
    )
    let write = WorkflowDefinitionWrite(
      workflowName: resolution.workflowName,
      operation: .forceUpdate,
      documentData: fileData,
      documentDigest: digest,
      sourceDirectory: bundle.workflowDirectory,
      sourceScope: bundle.sourceScope.rawValue,
      provenance: bundle.provenance.rawValue,
      actor: actor,
      reason: reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      evidence: evidence,
      diff: diff,
      overwrittenChanges: overwritten,
      expectedCurrentVersionId: current.head.currentVersionId
    )
    do {
      guard case let .created(version, audit) = try store.commit(write) else { throw WorkflowDefinitionStoreError(code: .staleHead, message: "definition changed during force import") }
      return WorkflowDefinitionImportResult(outcome: .forceUpdated, version: version, diff: diff, audit: audit)
    } catch { throw map(error) }
  }

  public func update(
    workflowName: String,
    source: WorkflowDefinitionUpdateSource,
    reason: String,
    expectedVersionId: String?,
    evidence: [WorkflowDefinitionEvidenceRef],
    actor: WorkflowDefinitionActor
  ) throws -> WorkflowDefinitionUpdateResult {
    try requireReason(reason)
    guard let current = try store.current(workflowName: workflowName) else { throw notRegistered(workflowName) }
    let currentDoc = try document(current.document)
    let files: [String: String]
    switch source {
    case let .patch(patch):
      files = try WorkflowDefinitionDocument.authoredFiles(
        fromView: WorkflowDefinitionJSONPatch.apply(patch, to: currentDoc.authoredView()),
        previous: currentDoc.authoredFiles
      )
    case let .authoredFiles(value): files = value
    case let .fromDirectory(options):
      let bundle = try fileResolver.resolve(options)
      guard bundle.workflow.workflowId == currentDoc.runtime.workflow.workflowId else {
        throw invalidDefinition("file workflowId does not match registered workflow")
      }
      files = try WorkflowDefinitionDocument.make(from: bundle).authoredFiles
    }
    return try commitAuthoredEdit(AuthoredEditRequest(
      workflowName: workflowName,
      current: current,
      currentDoc: currentDoc,
      newAuthoredFiles: files,
      operation: .update,
      targetNodeId: nil,
      targetField: nil,
      reason: reason,
      expected: expectedVersionId,
      evidence: evidence,
      actor: actor
    ))
  }

  public func authoredView(workflowName: String, versionId: String?) throws -> (version: WorkflowDefinitionVersion, view: JSONValue) {
    let (version, doc) = try selectedDocument(workflowName: workflowName, versionId: versionId)
    return (version, try doc.authoredView())
  }

  public func updatePrompt(
    workflowName: String,
    nodeId: String,
    field: WorkflowDefinitionPromptField,
    text: String,
    reason: String,
    expectedVersionId: String?,
    evidence: [WorkflowDefinitionEvidenceRef],
    actor: WorkflowDefinitionActor
  ) throws -> (WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord) {
    try requireReason(reason)
    guard let current = try store.current(workflowName: workflowName) else { throw notRegistered(workflowName) }
    let doc = try document(current.document)
    guard let registryNode = doc.runtime.workflow.nodeRegistry.first(where: { $0.id == nodeId }), registryNode.nodeRef == nil,
          let nodeFile = registryNode.nodeFile, let nodeText = doc.authoredFiles[nodeFile] else {
      throw invalidDefinition("node \(nodeId) has no authored node file")
    }
    let payload = try JSONDecoder().decode(AgentNodePayload.self, from: Data(nodeText.utf8))
    if case let .variant(key, _) = field, payload.promptVariants?[key] == nil { throw invalidDefinition("unknown prompt variant \(key)") }
    var files = doc.authoredFiles
    let referencedPath: String?
    switch field {
    case let .node(kind):
      referencedPath = switch kind {
      case .promptTemplate: payload.promptTemplateFile
      case .systemPromptTemplate: payload.systemPromptTemplateFile
      case .sessionStartPromptTemplate: payload.sessionStartPromptTemplateFile
      }
    case let .variant(key, kind):
      let variant = payload.promptVariants?[key]
      referencedPath = switch kind {
      case .promptTemplate: variant?.promptTemplateFile
      case .systemPromptTemplate: variant?.systemPromptTemplateFile
      case .sessionStartPromptTemplate: variant?.sessionStartPromptTemplateFile
      }
    }
    if let referencedPath {
      guard files[referencedPath] != nil else { throw invalidDefinition("prompt file is not authored: \(referencedPath)") }
      files[referencedPath] = text
    } else {
      let path = WorkflowDefinitionJSONPatch.pointer([nodeFile] + field.tokens)
      let patch: JSONValue = .array([.object(["op": .string("add"), "path": .string(path), "value": .string(text)])])
      let view = try WorkflowDefinitionJSONPatch.apply(patch, to: doc.authoredView())
      files = try WorkflowDefinitionDocument.authoredFiles(fromView: view, previous: doc.authoredFiles)
    }
    let result = try commitAuthoredEdit(AuthoredEditRequest(
      workflowName: workflowName,
      current: current,
      currentDoc: doc,
      newAuthoredFiles: files,
      operation: .updatePrompt,
      targetNodeId: nodeId,
      targetField: field.tokens.joined(separator: "."),
      reason: reason,
      expected: expectedVersionId,
      evidence: evidence,
      actor: actor
    ))
    guard let version = result.version, let audit = result.audit else { throw invalidDefinition("prompt unchanged") }
    return (version, audit)
  }

  public func restore(
    workflowName: String,
    versionId: String,
    reason: String,
    evidence: [WorkflowDefinitionEvidenceRef],
    actor: WorkflowDefinitionActor
  ) throws -> (WorkflowDefinitionVersion, WorkflowDefinitionAuditRecord) {
    try requireReason(reason)
    guard let current = try store.current(workflowName: workflowName) else { throw notRegistered(workflowName) }
    guard let target = try store.version(versionId: versionId), target.workflowName == workflowName,
          let data = try store.blob(digest: target.documentDigest) else {
      throw WorkflowDefinitionStoreError(code: .versionNotFound, message: "definition version \(versionId) was not found for \(workflowName)")
    }
    let targetDoc = try document(data)
    let diff = diffDocuments(try document(current.document), targetDoc)
    let write = WorkflowDefinitionWrite(
      workflowName: workflowName,
      operation: .restore,
      documentData: data,
      documentDigest: target.documentDigest,
      sourceDirectory: current.version.sourceDirectory,
      sourceScope: current.version.sourceScope,
      provenance: current.version.provenance,
      actor: actor,
      reason: reason,
      evidence: evidence,
      diff: diff,
      expectedCurrentVersionId: current.head.currentVersionId
    )
    do {
      guard case let .created(version, audit) = try store.commit(write) else { throw invalidDefinition("restore did not create a version") }
      return (version, audit)
    } catch { throw map(error) }
  }

  public func history(workflowName: String, nodeId: String?, limit: Int?) throws -> [WorkflowDefinitionAuditRecord] {
    try store.history(workflowName: workflowName, nodeId: nodeId, limit: limit)
  }

  // The plan-pinned API returns head, version, and document together.
  // swiftlint:disable:next large_tuple
  public func show(workflowName: String, versionId: String?) throws -> (head: WorkflowDefinitionHead, version: WorkflowDefinitionVersion, document: WorkflowDefinitionDocument) {
    guard let head = try store.head(workflowName: workflowName) else { throw notRegistered(workflowName) }
    let (version, doc) = try selectedDocument(workflowName: workflowName, versionId: versionId)
    return (head, version, doc)
  }

  public func diff(
    workflowName: String,
    fromVersionId: String?,
    toVersionId: String?,
    againstFile: WorkflowResolutionOptions?
  ) throws -> [WorkflowDefinitionDiffEntry] {
    guard let current = try store.current(workflowName: workflowName) else { throw notRegistered(workflowName) }
    let before = try versionDocument(versionId: fromVersionId ?? current.head.currentVersionId, workflowName: workflowName)
    let after: WorkflowDefinitionDocument
    if let toVersionId {
      after = try versionDocument(versionId: toVersionId, workflowName: workflowName)
    } else if let againstFile {
      after = try WorkflowDefinitionDocument.make(from: fileResolver.resolve(againstFile))
    } else if fromVersionId == nil {
      after = try WorkflowDefinitionDocument.make(from: fileResolver.resolve(WorkflowResolutionOptions(workflowName: workflowName)))
    } else {
      after = try document(current.document)
    }
    return diffDocuments(before, after)
  }

  public func export(
    workflowName: String,
    versionId: String?,
    target: WorkflowDefinitionExportTarget?
  ) throws -> [WorkflowDefinitionExportedFile] {
    let (version, doc) = try selectedDocument(workflowName: workflowName, versionId: versionId)
    let files = try doc.authoredFiles.keys.sorted().map { path -> WorkflowDefinitionExportedFile in
      let normalized = try WorkflowAuthoredFileOverlay.normalize(path)
      guard normalized == path else { throw invalidDefinition("authored path is not normalized: \(path)") }
      guard let content = doc.authoredFiles[path] else { throw invalidDefinition("missing authored file \(path)") }
      return WorkflowDefinitionExportedFile(path: path, content: content)
    }
    guard let target else { return files }
    let root: URL
    switch target {
    case let .directory(path):
      root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
      if FileManager.default.fileExists(atPath: root.path) {
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        guard contents.isEmpty else { throw invalidDefinition("export directory must be empty") }
      }
    case let .source(overwrite):
      guard overwrite else { throw invalidDefinition("source export requires overwrite=true") }
      root = URL(fileURLWithPath: version.sourceDirectory, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }
    for file in files {
      _ = try WorkflowDefinitionDocument.containedAuthoredURL(file.path, root: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for file in files {
      let destination = root.appendingPathComponent(file.path).standardizedFileURL
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      let temporary = destination.deletingLastPathComponent()
        .appendingPathComponent(destination.lastPathComponent + ".ds179-tmp-\(UUID().uuidString)")
      try Data(file.content.utf8).write(to: temporary)
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
    }
    return files
  }

  private func commitAuthoredEdit(_ request: AuthoredEditRequest) throws -> WorkflowDefinitionUpdateResult {
    let workflowName = request.workflowName
    let current = request.current
    let currentDoc = request.currentDoc
    let newAuthoredFiles = request.newAuthoredFiles
    let operation = request.operation
    let targetNodeId = request.targetNodeId
    let targetField = request.targetField
    let reason = request.reason
    let expected = request.expected
    let evidence = request.evidence
    let actor = request.actor
    try requireReason(reason)
    if let expected, expected != current.head.currentVersionId { throw conflict("expected version \(expected), current is \(current.head.currentVersionId)") }
    let overlay: WorkflowAuthoredFileOverlay
    do { overlay = try WorkflowAuthoredFileOverlay(files: newAuthoredFiles) } catch {
      throw WorkflowDefinitionServiceError(code: .invalidPatch, message: String(describing: error))
    }
    let sourceDirectory = URL(fileURLWithPath: current.head.sourceDirectory, isDirectory: true).standardizedFileURL
    let parent = sourceDirectory.deletingLastPathComponent()
    let options = WorkflowResolutionOptions(
      workflowName: sourceDirectory.lastPathComponent,
      scope: .direct,
      workflowDefinitionDir: parent.path,
      workingDirectory: parent.path,
      includeDeactivated: true,
      authoredOverlay: overlay
    )
    let resolved: ResolvedWorkflowBundle
    do { resolved = try fileResolver.resolve(options) } catch {
      throw invalidDefinition(error.localizedDescription)
    }
    let resolvedDirectory = URL(fileURLWithPath: resolved.workflowDirectory).resolvingSymlinksInPath().standardizedFileURL
    guard resolvedDirectory == sourceDirectory.resolvingSymlinksInPath().standardizedFileURL,
          resolved.workflow.workflowId == currentDoc.runtime.workflow.workflowId else {
      throw invalidDefinition("re-derived bundle does not match the registered source")
    }
    let newDoc: WorkflowDefinitionDocument
    do { newDoc = try WorkflowDefinitionDocument.make(from: resolved, authoredOverlay: overlay) } catch {
      throw invalidDefinition(error.localizedDescription)
    }
    let diagnostics = DefaultWorkflowValidator().validate(newDoc.runtime.workflow)
      + newDoc.runtime.nodePayloads.keys.sorted().flatMap { validateAgentNodePayload(newDoc.runtime.nodePayloads[$0]!, path: "nodes.\($0)") }
    guard !diagnostics.contains(where: { $0.severity == .error }) else {
      throw invalidDefinition(diagnostics.filter { $0.severity == .error }.map(\.message).joined(separator: "; "))
    }
    let data = try newDoc.canonicalData()
    let digest = JSONCanonical.sha256Hex(data)
    let diff = diffDocuments(currentDoc, newDoc)
    guard digest != current.version.documentDigest else {
      return WorkflowDefinitionUpdateResult(outcome: .unchanged, versionId: current.version.versionId,
                                            digest: current.version.documentDigest, version: nil, audit: nil, diff: [])
    }
    let write = WorkflowDefinitionWrite(
      workflowName: workflowName,
      operation: operation,
      documentData: data,
      documentDigest: digest,
      sourceDirectory: current.version.sourceDirectory,
      sourceScope: current.version.sourceScope,
      provenance: current.version.provenance,
      actor: actor,
      reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
      evidence: evidence,
      targetNodeId: targetNodeId,
      targetField: targetField,
      diff: diff,
      expectedCurrentVersionId: current.head.currentVersionId
    )
    do {
      guard case let .created(version, audit) = try store.commit(write) else { throw conflict("definition head changed during update") }
      return WorkflowDefinitionUpdateResult(outcome: .updated, versionId: version.versionId, digest: digest, version: version, audit: audit, diff: diff)
    } catch { throw map(error) }
  }

  private func selectedDocument(workflowName: String, versionId: String?) throws -> (WorkflowDefinitionVersion, WorkflowDefinitionDocument) {
    guard let current = try store.current(workflowName: workflowName) else { throw notRegistered(workflowName) }
    let id = versionId ?? current.head.currentVersionId
    return (try checkedVersion(versionId: id, workflowName: workflowName), try versionDocument(versionId: id, workflowName: workflowName))
  }

  private func checkedVersion(versionId: String, workflowName: String) throws -> WorkflowDefinitionVersion {
    guard let version = try store.version(versionId: versionId), version.workflowName == workflowName else {
      throw WorkflowDefinitionStoreError(code: .versionNotFound, message: "definition version \(versionId) was not found for \(workflowName)")
    }
    return version
  }

  private func versionDocument(versionId: String, workflowName: String) throws -> WorkflowDefinitionDocument {
    let version = try checkedVersion(versionId: versionId, workflowName: workflowName)
    guard let data = try store.blob(digest: version.documentDigest) else {
      throw WorkflowDefinitionStoreError(code: .versionNotFound, message: "definition blob \(version.documentDigest) was not found")
    }
    return try document(data)
  }

  private func document(_ data: Data) throws -> WorkflowDefinitionDocument { try WorkflowDefinitionDocument.decode(data) }

  private func diffDocuments(_ before: WorkflowDefinitionDocument?, _ after: WorkflowDefinitionDocument) -> [WorkflowDefinitionDiffEntry] {
    guard let before, let lhs = try? JSONDecoder().decode(JSONValue.self, from: (try? before.canonicalData()) ?? Data()),
          let rhs = try? JSONDecoder().decode(JSONValue.self, from: (try? after.canonicalData()) ?? Data()) else { return [] }
    return WorkflowDefinitionDiff.compute(before: lhs, after: rhs)
  }

  private func requireReason(_ reason: String?) throws {
    guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkflowDefinitionServiceError(code: .reasonRequired, message: "definition changes require a non-empty reason")
    }
  }

  private func notRegistered(_ workflowName: String) -> WorkflowDefinitionServiceError {
    WorkflowDefinitionServiceError(code: .definitionNotRegistered, message: "workflow \(workflowName) is not registered")
  }

  private func conflict(_ message: String) -> WorkflowDefinitionServiceError {
    WorkflowDefinitionServiceError(code: .definitionConflict, message: message)
  }

  private func invalidDefinition(_ message: String) -> WorkflowDefinitionServiceError {
    WorkflowDefinitionServiceError(code: .invalidDefinition, message: message)
  }

  private func map(_ error: Error) -> Error {
    guard let storeError = error as? WorkflowDefinitionStoreError else { return error }
    switch storeError.code {
    case .missingReason: return WorkflowDefinitionServiceError(code: .reasonRequired, message: storeError.message)
    case .headMissing: return WorkflowDefinitionServiceError(code: .definitionNotRegistered, message: storeError.message)
    case .staleHead: return WorkflowDefinitionServiceError(code: .definitionConflict, message: storeError.message)
    default: return storeError
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
