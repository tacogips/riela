import Foundation
import RielaCore

public struct GraphQLWorkflowDefinitionAuditRecord: Codable, Equatable, Sendable {
  public var auditId: String
  public var workflowName: String
  public var operation: String
  public var versionId: String
  public var previousVersionId: String?
  public var targetNodeId: String?
  public var targetField: String?
  public var beforeDigest: String?
  public var afterDigest: String
  public var reason: String
  public var evidence: [String]
  public var actor: GraphQLWorkflowDefinitionActor
  public var approvalState: String
  public var overwrittenChanges: GraphQLWorkflowDefinitionOverwrittenChanges?
  public var createdAt: String
  public var retained: Bool
  public init(
    auditId: String,
    workflowName: String,
    operation: String,
    versionId: String,
    previousVersionId: String?,
    targetNodeId: String?,
    targetField: String?,
    beforeDigest: String?,
    afterDigest: String,
    reason: String,
    evidence: [String],
    actor: GraphQLWorkflowDefinitionActor,
    approvalState: String,
    overwrittenChanges: GraphQLWorkflowDefinitionOverwrittenChanges?,
    createdAt: String,
    retained: Bool = true
  ) {
    self.auditId = auditId; self.workflowName = workflowName; self.operation = operation; self.versionId = versionId
    self.previousVersionId = previousVersionId; self.targetNodeId = targetNodeId; self.targetField = targetField
    self.beforeDigest = beforeDigest; self.afterDigest = afterDigest; self.reason = reason; self.evidence = evidence
    self.actor = actor; self.approvalState = approvalState; self.overwrittenChanges = overwrittenChanges; self.createdAt = createdAt
    self.retained = retained
  }
}

public struct GraphQLWorkflowDefinitionActor: Codable, Equatable, Sendable {
  public var kind: String
  public var id: String?
  public init(kind: String, id: String?) { self.kind = kind; self.id = id }
}

// This DTO name matches the pinned GraphQL contract.
// swiftlint:disable:next type_name
public struct GraphQLWorkflowDefinitionOverwrittenChanges: Codable, Equatable, Sendable {
  public var sinceVersionId: String
  public var auditIds: [String]
  public init(sinceVersionId: String, auditIds: [String]) { self.sinceVersionId = sinceVersionId; self.auditIds = auditIds }
}

public struct GraphQLWorkflowDefinitionVersion: Codable, Equatable, Sendable {
  public var versionId: String
  public var workflowName: String
  public var parentVersionId: String?
  public var documentDigest: String
  public var operation: String
  public var sourceDirectory: String
  public var sourceScope: String
  public var provenance: String
  public var actor: GraphQLWorkflowDefinitionActor
  public var createdAt: String
  public var documentJSON: String
  public var revision: Int?
  public init(
    versionId: String,
    workflowName: String,
    parentVersionId: String?,
    documentDigest: String,
    operation: String,
    sourceDirectory: String,
    sourceScope: String,
    provenance: String,
    actor: GraphQLWorkflowDefinitionActor,
    createdAt: String,
    documentJSON: String,
    revision: Int? = nil
  ) {
    self.versionId = versionId; self.workflowName = workflowName; self.parentVersionId = parentVersionId
    self.documentDigest = documentDigest; self.operation = operation; self.sourceDirectory = sourceDirectory
    self.sourceScope = sourceScope; self.provenance = provenance; self.actor = actor; self.createdAt = createdAt; self.documentJSON = documentJSON
    self.revision = revision
  }
}

public struct GraphQLWorkflowDefinitionDiffEntry: Codable, Equatable, Sendable {
  public var path: String
  public var op: String
  public var before: String?
  public var after: String?
  public init(path: String, op: String, before: String?, after: String?) { self.path = path; self.op = op; self.before = before; self.after = after }
}

public struct GraphQLWorkflowDefinitionFile: Codable, Equatable, Sendable {
  public var path: String
  public var content: String
  public init(path: String, content: String) { self.path = path; self.content = content }
}

public struct GraphQLWorkflowDefinitionImportPayload: Codable, Equatable, Sendable {
  public var outcome: String
  public var version: GraphQLWorkflowDefinitionVersion?
  public var diff: [GraphQLWorkflowDefinitionDiffEntry]
  public var audit: GraphQLWorkflowDefinitionAuditRecord?
  public init(outcome: String, version: GraphQLWorkflowDefinitionVersion?, diff: [GraphQLWorkflowDefinitionDiffEntry], audit: GraphQLWorkflowDefinitionAuditRecord?) {
    self.outcome = outcome; self.version = version; self.diff = diff; self.audit = audit
  }
}

public struct GraphQLWorkflowDefinitionExportPayload: Codable, Equatable, Sendable {
  public var files: [GraphQLWorkflowDefinitionFile]
  public var wroteToSource: Bool
  public init(files: [GraphQLWorkflowDefinitionFile], wroteToSource: Bool) { self.files = files; self.wroteToSource = wroteToSource }
}

public struct GraphQLWorkflowDefinitionMutationPayload: Codable, Equatable, Sendable {
  public var version: GraphQLWorkflowDefinitionVersion
  public var audit: GraphQLWorkflowDefinitionAuditRecord
  public init(version: GraphQLWorkflowDefinitionVersion, audit: GraphQLWorkflowDefinitionAuditRecord) { self.version = version; self.audit = audit }
}

public struct GraphQLWorkflowDefinitionUpdatePayload: Codable, Equatable, Sendable {
  public var outcome: String
  public var versionId: String
  public var digest: String
  public var version: GraphQLWorkflowDefinitionVersion?
  public var audit: GraphQLWorkflowDefinitionAuditRecord?
  public var diff: [GraphQLWorkflowDefinitionDiffEntry]
  public init(outcome: String, versionId: String, digest: String, version: GraphQLWorkflowDefinitionVersion?, audit: GraphQLWorkflowDefinitionAuditRecord?, diff: [GraphQLWorkflowDefinitionDiffEntry]) {
    self.outcome = outcome; self.versionId = versionId; self.digest = digest; self.version = version; self.audit = audit; self.diff = diff
  }
}

public struct UpdateWorkflowDefinitionInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var patchJSON: String?
  public var authoredFiles: [GraphQLWorkflowDefinitionFile]?
  public var expectedVersionId: String?
  public var reason: String?
  public var evidence: [String]?
  public var actorKind: String?
  public var actorId: String?
  public var storeScope: String?
  public var historyRetention: Int?
}

public struct UpdateWorkflowDefinitionPromptInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var nodeId: String
  public var field: String
  public var text: String
  public var reason: String?
  public var expectedVersionId: String?
  public var evidence: [String]?
  public var actorKind: String?
  public var actorId: String?
  public var storeScope: String?
  public var historyRetention: Int?
}

public struct RestoreWorkflowDefinitionInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var versionId: String
  public var reason: String?
  public var evidence: [String]?
  public var actorKind: String?
  public var actorId: String?
  public var storeScope: String?
  public var historyRetention: Int?
}

public struct UndoWorkflowDefinitionInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var storeScope: String?
  public var reason: String?
  public var expectedRevision: Int?
  public var expectedVersionId: String?
  public var evidence: [String]?
  public var actorKind: String?
  public var actorId: String?
}

public struct RedoWorkflowDefinitionInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var storeScope: String?
  public var reason: String?
  public var expectedRevision: Int?
  public var expectedVersionId: String?
  public var evidence: [String]?
  public var actorKind: String?
  public var actorId: String?
}

public struct ImportWorkflowDefinitionInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var scope: String?
  public var workflowDefinitionDir: String?
  public var force: Bool?
  public var reason: String?
  public var evidence: [String]?
  public var actorKind: String?
  public var actorId: String?
  public var storeScope: String?
  public var historyRetention: Int?
}

public struct ExportWorkflowDefinitionInput: Codable, Equatable, Sendable {
  public var workflowName: String
  public var versionId: String?
  public var writeToSource: Bool?
  public var storeScope: String?
}

public protocol WorkflowDefinitionGraphQLProviding: Sendable {
  func workflowDefinitionHistory(workflowName: String, nodeId: String?, limit: Int?, storeScope: String?) async throws -> [GraphQLWorkflowDefinitionAuditRecord]
  func workflowDefinition(workflowName: String, versionId: String?, storeScope: String?) async throws -> GraphQLWorkflowDefinitionVersion?
  func workflowDefinitionDiff(workflowName: String, fromVersionId: String?, toVersionId: String?, againstFile: Bool?, storeScope: String?) async throws -> [GraphQLWorkflowDefinitionDiffEntry]
  func updateWorkflowDefinition(input: UpdateWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionUpdatePayload
  func updateWorkflowDefinitionPrompt(input: UpdateWorkflowDefinitionPromptInput) async throws -> GraphQLWorkflowDefinitionMutationPayload
  func restoreWorkflowDefinition(input: RestoreWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionMutationPayload
  func undoWorkflowDefinition(input: UndoWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionMutationPayload
  func redoWorkflowDefinition(input: RedoWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionMutationPayload
  func importWorkflowDefinition(input: ImportWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionImportPayload
  func exportWorkflowDefinition(input: ExportWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionExportPayload
}

public extension WorkflowDefinitionGraphQLProviding {
  func undoWorkflowDefinition(input: UndoWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionMutationPayload {
    throw WorkflowDefinitionGraphQLError(code: "DEFINITION_OPERATION_UNSUPPORTED", message: "undoWorkflowDefinition is unsupported by this provider")
  }

  func redoWorkflowDefinition(input: RedoWorkflowDefinitionInput) async throws -> GraphQLWorkflowDefinitionMutationPayload {
    throw WorkflowDefinitionGraphQLError(code: "DEFINITION_OPERATION_UNSUPPORTED", message: "redoWorkflowDefinition is unsupported by this provider")
  }
}

public struct WorkflowDefinitionGraphQLError: Error, Equatable, Sendable {
  public var code: String
  public var message: String
  public var retainedVersionIds: [String]?
  public var retainedGenerations: Int?
  public init(code: String, message: String, retainedVersionIds: [String]? = nil, retainedGenerations: Int? = nil) {
    self.code = code; self.message = message; self.retainedVersionIds = retainedVersionIds; self.retainedGenerations = retainedGenerations
  }
}

// This executor name is pinned by the plan and referenced in every host chain.
// swiftlint:disable:next type_name
public struct WorkflowDefinitionGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  public static let queryFields: Set<String> = ["workflowDefinitionHistory", "workflowDefinition", "workflowDefinitionDiff"]
  public static let mutationFields: Set<String> = [
    "updateWorkflowDefinition", "updateWorkflowDefinitionPrompt", "restoreWorkflowDefinition",
    "importWorkflowDefinition", "exportWorkflowDefinition", "undoWorkflowDefinition", "redoWorkflowDefinition"
  ]

  public var provider: (any WorkflowDefinitionGraphQLProviding)?
  public var next: (any GraphQLDocumentExecuting)?

  public init(provider: (any WorkflowDefinitionGraphQLProviding)? = nil, next: (any GraphQLDocumentExecuting)? = nil) {
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
        guard let operation = try selectGraphQLOperation(
          parseGraphQLOperations(in: request.query, operationName: request.operationName, variables: request.variables, parseArguments: true),
          operationName: request.operationName
        ) else { return .notHandled }
        roots = operation.rootFields
      }
    } catch { return definitionGraphQLError(code: "INVALID_DEFINITION_INPUT", message: "invalid definition GraphQL document") }
    let selected = roots.filter { Self.supports($0.fieldName) }
    guard !selected.isEmpty else { return await next?.execute(request) ?? .notHandled }
    guard let provider else { return definitionGraphQLError(code: "DEFINITION_OPERATION_FAILED", message: "definition provider unavailable") }
    var data: JSONObject = [:]
    for root in selected {
      do {
        let result: JSONValue
        switch root.fieldName {
        case "workflowDefinitionHistory":
          guard let workflow = stringArg("workflowName", root.arguments) else { throw invalidInput("workflowName is required") }
          let records = try await provider.workflowDefinitionHistory(
            workflowName: workflow,
            nodeId: stringArg("nodeId", root.arguments),
            limit: intArg("limit", root.arguments),
            storeScope: stringArg("storeScope", root.arguments)
          )
          result = try definitionJSON(records)
        case "workflowDefinition":
          guard let workflow = stringArg("workflowName", root.arguments) else { throw invalidInput("workflowName is required") }
          result = try definitionJSON(try await provider.workflowDefinition(workflowName: workflow, versionId: stringArg("versionId", root.arguments), storeScope: stringArg("storeScope", root.arguments)))
        case "workflowDefinitionDiff":
          guard let workflow = stringArg("workflowName", root.arguments) else { throw invalidInput("workflowName is required") }
          let diff = try await provider.workflowDefinitionDiff(
            workflowName: workflow,
            fromVersionId: stringArg("fromVersionId", root.arguments),
            toVersionId: stringArg("toVersionId", root.arguments),
            againstFile: boolArg("againstFile", root.arguments),
            storeScope: stringArg("storeScope", root.arguments)
          )
          result = try definitionJSON(diff)
        case "updateWorkflowDefinition":
          result = try definitionJSON(try await provider.updateWorkflowDefinition(input: requiredInput("input", root.arguments)))
        case "updateWorkflowDefinitionPrompt":
          result = try definitionJSON(try await provider.updateWorkflowDefinitionPrompt(input: requiredInput("input", root.arguments)))
        case "restoreWorkflowDefinition":
          result = try definitionJSON(try await provider.restoreWorkflowDefinition(input: requiredInput("input", root.arguments)))
        case "undoWorkflowDefinition":
          result = try definitionJSON(try await provider.undoWorkflowDefinition(input: requiredInput("input", root.arguments)))
        case "redoWorkflowDefinition":
          result = try definitionJSON(try await provider.redoWorkflowDefinition(input: requiredInput("input", root.arguments)))
        case "importWorkflowDefinition":
          result = try definitionJSON(try await provider.importWorkflowDefinition(input: requiredInput("input", root.arguments)))
        case "exportWorkflowDefinition":
          result = try definitionJSON(try await provider.exportWorkflowDefinition(input: requiredInput("input", root.arguments)))
        default: continue
        }
        data[root.responseKey] = projectGraphQLValue(result, selections: root.selections)
      } catch let error as WorkflowDefinitionGraphQLError {
        return definitionGraphQLError(code: error.code, message: error.message, completedData: data,
          retainedVersionIds: error.retainedVersionIds, retainedGenerations: error.retainedGenerations)
      } catch {
        return definitionGraphQLError(code: "DEFINITION_OPERATION_FAILED", message: "definition operation failed: \(error)", completedData: data)
      }
    }
    return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
  }
}

extension WorkflowDefinitionGraphQLDocumentExecutor: GraphQLDocumentDomainPreflighting {
  func preflight(_ request: GraphQLDocumentRequest, rootFields: [ParsedGraphQLRootField]) async -> GraphQLDocumentExecutionResponse? {
    let otherRoots = rootFields.filter { !Self.supports($0.fieldName) }
    guard !otherRoots.isEmpty else { return nil }
    guard let preflighting = next as? any GraphQLDocumentDomainPreflighting else {
      return definitionGraphQLError(code: "INVALID_DEFINITION_INPUT", message: "mixed-domain preflight unavailable")
    }
    return await preflighting.preflight(request, rootFields: otherRoots)
  }
}

private func requiredInput<T: Decodable>(_ key: String, _ arguments: JSONObject) throws -> T {
  guard case let .object(value)? = arguments[key] else { throw invalidInput("\(key) is required") }
  do {
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(JSONValue.object(value)))
  } catch {
    throw invalidInput("invalid \(key)")
  }
}

private func definitionJSON<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func stringArg(_ key: String, _ arguments: JSONObject) -> String? {
  guard case let .string(value)? = arguments[key] else { return nil }; return value
}
private func intArg(_ key: String, _ arguments: JSONObject) -> Int? {
  guard case let .number(value)? = arguments[key] else { return nil }; return Int(value)
}
private func boolArg(_ key: String, _ arguments: JSONObject) -> Bool? {
  guard case let .bool(value)? = arguments[key] else { return nil }; return value
}
private func invalidInput(_ message: String) -> WorkflowDefinitionGraphQLError {
  WorkflowDefinitionGraphQLError(code: "INVALID_DEFINITION_INPUT", message: message)
}
private func definitionGraphQLError(code: String, message: String, completedData: JSONObject = [:],
                                    retainedVersionIds: [String]? = nil, retainedGenerations: Int? = nil) -> GraphQLDocumentExecutionResponse {
  var extensions: JSONObject = ["code": .string(code)]
  if let retainedVersionIds { extensions["retainedVersionIds"] = .array(retainedVersionIds.map(JSONValue.string)) }
  if let retainedGenerations { extensions["retainedGenerations"] = .number(Double(retainedGenerations)) }
  return GraphQLDocumentExecutionResponse(handled: true, body: [
    "data": completedData.isEmpty ? .null : .object(completedData),
    "errors": .array([.object(["message": .string(message), "extensions": .object(extensions)])])
  ])
}

public let workflowDefinitionGraphQLSchemaTypes = """
  type WorkflowDefinitionActor {
    kind: String!
    id: String
  }
  type WorkflowDefinitionVersion {
    versionId: String!
    workflowName: String!
    parentVersionId: String
    documentDigest: String!
    operation: String!
    sourceDirectory: String!
    sourceScope: String!
    provenance: String!
    actor: WorkflowDefinitionActor!
    createdAt: String!
    documentJSON: String!
    revision: Int
  }
  type WorkflowDefinitionDiffEntry { path: String! op: String! before: String after: String }
  type WorkflowDefinitionOverwrittenChanges { sinceVersionId: String! auditIds: [String!]! }
  type WorkflowDefinitionAuditRecord {
    auditId: String!
    workflowName: String!
    operation: String!
    versionId: String!
    previousVersionId: String
    targetNodeId: String
    targetField: String
    beforeDigest: String
    afterDigest: String!
    reason: String!
    evidence: [String!]!
    actor: WorkflowDefinitionActor!
    approvalState: String!
    overwrittenChanges: WorkflowDefinitionOverwrittenChanges
    createdAt: String!
    retained: Boolean!
  }
  input WorkflowDefinitionFileInput { path: String! content: String! }
  input UpdateWorkflowDefinitionInput {
    workflowName: String!
    patchJSON: String
    authoredFiles: [WorkflowDefinitionFileInput!]
    expectedVersionId: String
    reason: String!
    evidence: [String!]
    actorKind: String
    actorId: String
    storeScope: String
    historyRetention: Int
  }
  input UpdateWorkflowDefinitionPromptInput {
    workflowName: String!
    nodeId: String!
    field: String!
    text: String!
    reason: String!
    expectedVersionId: String
    evidence: [String!]
    actorKind: String
    actorId: String
    storeScope: String
    historyRetention: Int
  }
  input RestoreWorkflowDefinitionInput {
    workflowName: String!
    versionId: String!
    reason: String!
    evidence: [String!]
    actorKind: String
    actorId: String
    storeScope: String
    historyRetention: Int
  }
  input UndoWorkflowDefinitionInput { workflowName: String! storeScope: String reason: String! expectedRevision: Int expectedVersionId: String evidence: [String!] actorKind: String actorId: String }
  input RedoWorkflowDefinitionInput { workflowName: String! storeScope: String reason: String! expectedRevision: Int expectedVersionId: String evidence: [String!] actorKind: String actorId: String }
  input ImportWorkflowDefinitionInput {
    workflowName: String!
    scope: String
    workflowDefinitionDir: String
    force: Boolean
    reason: String
    evidence: [String!]
    actorKind: String
    actorId: String
    storeScope: String
    historyRetention: Int
  }
  input ExportWorkflowDefinitionInput { workflowName: String! versionId: String writeToSource: Boolean storeScope: String }
  type WorkflowDefinitionMutationPayload { version: WorkflowDefinitionVersion! audit: WorkflowDefinitionAuditRecord! }
  type WorkflowDefinitionUpdatePayload { outcome: String! versionId: String! digest: String! version: WorkflowDefinitionVersion audit: WorkflowDefinitionAuditRecord diff: [WorkflowDefinitionDiffEntry!]! }
  type WorkflowDefinitionImportPayload { outcome: String! version: WorkflowDefinitionVersion diff: [WorkflowDefinitionDiffEntry!]! audit: WorkflowDefinitionAuditRecord }
  type WorkflowDefinitionFile { path: String! content: String! }
  type WorkflowDefinitionExportPayload { files: [WorkflowDefinitionFile!]! wroteToSource: Boolean! }
"""
