import Foundation
import RielaCore
import RielaNote

public struct GraphQLDocumentRequest: Equatable, Sendable {
  public var query: String
  public var variables: JSONObject
  public var operationName: String?
  public var environment: [String: String]
  public var authenticatedClientId: String?

  public init(
    query: String,
    variables: JSONObject = [:],
    operationName: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    authenticatedClientId: String? = nil
  ) {
    self.query = query
    self.variables = variables
    self.operationName = operationName
    self.environment = environment
    self.authenticatedClientId = authenticatedClientId
  }
}

public struct GraphQLDocumentExecutionResponse: Equatable, Sendable {
  public var handled: Bool
  public var status: Int
  public var body: JSONObject

  public init(handled: Bool, status: Int = 200, body: JSONObject = [:]) {
    self.handled = handled
    self.status = status
    self.body = body
  }

  public static let notHandled = GraphQLDocumentExecutionResponse(handled: false)
}

public protocol GraphQLDocumentExecuting: Sendable {
  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse
}

public struct NoteGraphQLDocumentExecutor: GraphQLDocumentExecuting {
  public static let defaultRawS3EnvironmentAllowlist: Set<String> = [
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN"
  ]

  public var service: GraphQLNoteGraphQLService
  public var s3HTTPClient: any S3HTTPClient
  public var s3Profiles: [S3StorageProfile]
  public var allowRawS3ProfileInput: Bool
  public var rawS3EnvironmentAllowlist: Set<String>

  public init(
    service: GraphQLNoteGraphQLService,
    s3HTTPClient: any S3HTTPClient = URLSessionS3HTTPClient(),
    s3Profiles: [S3StorageProfile] = [],
    allowRawS3ProfileInput: Bool = false,
    rawS3EnvironmentAllowlist: Set<String> = Self.defaultRawS3EnvironmentAllowlist
  ) {
    self.service = service
    self.s3HTTPClient = s3HTTPClient
    self.s3Profiles = s3Profiles
    self.allowRawS3ProfileInput = allowRawS3ProfileInput
    self.rawS3EnvironmentAllowlist = rawS3EnvironmentAllowlist
  }

  public func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let rootField: ParsedNoteGraphQLRootField
    do {
      guard let parsed = try parseNoteGraphQLRootField(
        in: request.query,
        operationName: request.operationName,
        variables: request.variables,
        parseArguments: true
      ) else {
        return .notHandled
      }
      rootField = parsed
    } catch {
      let responseKey = noteGraphQLRootFieldName(in: request.query) ?? "noteGraphQL"
      return GraphQLDocumentExecutionResponse(
        handled: true,
        body: [
          "data": .object([responseKey: .null]),
          "errors": .array([.object(["message": .string(graphQLNotePublicDiagnostic(for: error))])])
        ]
      )
    }
    guard supportedNoteGraphQLFields.contains(rootField.fieldName) else {
      return .notHandled
    }
    do {
      try validateOperationType(rootField.operationType, fieldName: rootField.fieldName)
      try validateSelections(rootField.selections, rootFieldName: rootField.fieldName)
      var routedRequest = request
      routedRequest.variables = rootField.arguments
      let data = try await execute(fieldName: rootField.fieldName, request: routedRequest)
      let rootType = noteGraphQLRootSelectionTypes[rootField.fieldName] ?? "NoteMutationPayload"
      let projected = try projectGraphQLValue(data, selections: rootField.selections, typeName: rootType)
      return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object([rootField.responseKey: projected])])
    } catch {
      return GraphQLDocumentExecutionResponse(
        handled: true,
        body: [
          "data": .object([rootField.responseKey: .null]),
          "errors": .array([.object(["message": .string(graphQLNotePublicDiagnostic(for: error))])])
        ]
      )
    }
  }

  private func execute(fieldName: String, request: GraphQLDocumentRequest) async throws -> JSONValue {
    let variables = request.variables
    switch fieldName {
    case "note":
      return try await encodedJSONValue(service.note(noteId: requiredString("noteId", variables: variables)))
    case "notebook":
      return try await encodedJSONValue(service.notebook(notebookId: requiredString("notebookId", variables: variables)))
    case "notebooks":
      return try await encodedJSONValue(service.notebooks(
        limit: boundedLimit(try optionalInt("limit", variables: variables), defaultValue: 50),
        offset: boundedOffset(try optionalInt("offset", variables: variables)),
        tagFilter: try optionalStringArray("tagFilter", variables: variables) ?? [],
        sort: try optionalString("sort", variables: variables),
        createdAfter: try optionalString("createdAfter", variables: variables),
        createdBefore: try optionalString("createdBefore", variables: variables)
      ))
    case "notes":
      return try await encodedJSONValue(service.notes(
        limit: boundedLimit(try optionalInt("limit", variables: variables), defaultValue: 50),
        offset: boundedOffset(try optionalInt("offset", variables: variables)),
        notebookId: try optionalString("notebookId", variables: variables),
        tagFilter: try optionalStringArray("tagFilter", variables: variables) ?? []
      ))
    case "searchNotes":
      return try await encodedJSONValue(service.searchNotes(
        query: requiredString("query", variables: variables),
        tagFilter: try optionalStringArray("tagFilter", variables: variables) ?? [],
        classFilter: try optionalStringArray("classFilter", variables: variables) ?? [],
        sort: try optionalString("sort", variables: variables),
        createdAfter: try optionalString("createdAfter", variables: variables),
        createdBefore: try optionalString("createdBefore", variables: variables),
        includeLinked: try optionalBool("includeLinked", variables: variables) ?? false,
        limit: boundedLimit(try optionalInt("limit", variables: variables), defaultValue: 20),
        offset: boundedOffset(try optionalInt("offset", variables: variables))
      ))
    case "proposeNoteLinks":
      return try await encodedJSONValue(service.proposeNoteLinks(
        noteId: requiredString("noteId", variables: variables),
        limit: boundedLimit(try optionalInt("limit", variables: variables), defaultValue: 8)
      ))
    case "tags":
      return try await encodedJSONValue(service.tags())
    case "tagClasses":
      return try await encodedJSONValue(service.tagClasses())
    case "noteFile":
      return try await encodedJSONValue(service.noteFile(fileId: requiredString("fileId", variables: variables)))
    case "autoActions":
      return try await encodedJSONValue(service.autoActions())
    default:
      return try await executeMutation(fieldName: fieldName, request: request)
    }
  }

  private func executeMutation(fieldName: String, request: GraphQLDocumentRequest) async throws -> JSONValue {
    let variables = request.variables
    switch fieldName {
    case "createNote":
      var input: GraphQLCreateNoteInput = try requiredInput("input", variables: variables)
      input.assignedBy = noteAPIAssignedBy(input.assignedBy, request: request)
      return try await encodedJSONValue(service.createNote(input))
    case "createNotebook":
      return try await encodedJSONValue(service.createNotebook(requiredInput("input", variables: variables)))
    case "defineNoteTagClass":
      return try await encodedJSONValue(service.defineTagClass(requiredInput("input", variables: variables)))
    case "defineNoteTag":
      return try await encodedJSONValue(service.defineTag(requiredInput("input", variables: variables)))
    case "scaffoldNoteIngestionWorkflow":
      var input: GraphQLScaffoldNoteWorkflowInput = try requiredInput("input", variables: variables)
      input.assignedBy = noteAPIAssignedBy(input.assignedBy, request: request)
      return try await encodedJSONValue(service.scaffoldIngestionWorkflow(input))
    case "updateNote":
      let input: GraphQLUpdateNoteInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.updateNote(
        noteId: input.noteId,
        bodyMarkdown: input.bodyMarkdown,
        originatingActionId: input.originatingActionId
      ))
    case "deleteNote":
      return try await encodedJSONValue(service.deleteNote(noteId: requiredString("noteId", variables: variables)))
    case "deleteNotebook":
      return try await encodedJSONValue(service.deleteNotebook(notebookId: requiredString("notebookId", variables: variables)))
    case "applyNotebookTags":
      var input: GraphQLApplyNotebookTagsInput = try requiredInput("input", variables: variables)
      input.assignedBy = noteAPIAssignedBy(input.assignedBy, request: request)
      return try await encodedJSONValue(service.applyNotebookTags(input))
    case "removeNotebookTag":
      return try await encodedJSONValue(service.removeNotebookTag(
        notebookId: requiredString("notebookId", variables: variables),
        tagName: requiredString("tagName", variables: variables),
        provenance: try optionalString("provenance", variables: variables) ?? "human"
      ))
    case "setNoteReadOnly":
      return try await encodedJSONValue(service.setReadOnly(
        noteId: requiredString("noteId", variables: variables),
        readOnly: requiredBool("readOnly", variables: variables)
      ))
    case "applyNoteTags":
      let input: GraphQLApplyNoteTagsInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.applyTags(
        noteId: input.noteId,
        tags: input.tags,
        provenance: input.provenance ?? "ai",
        assignedBy: noteAPIAssignedBy(input.assignedBy, request: request)
      ))
    case "removeNoteTag":
      return try await encodedJSONValue(service.removeTag(
        noteId: requiredString("noteId", variables: variables),
        tagName: requiredString("tagName", variables: variables),
        provenance: try optionalString("provenance", variables: variables) ?? "human"
      ))
    case "addNoteComment":
      let input: GraphQLAddNoteCommentInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.addComment(
        noteId: input.noteId,
        bodyMarkdown: input.bodyMarkdown,
        author: input.author ?? noteAPIAssignedBy(nil, request: request) ?? "user"
      ))
    case "linkNotes":
      let input: GraphQLLinkNotesInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.linkNotes(
        from: input.fromNoteId,
        to: input.toNoteId,
        linkKind: input.linkKind ?? "related",
        provenance: input.provenance ?? "human"
      ))
    case "attachNoteFile":
      let input: GraphQLAttachNoteFileInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.attachFile(
        noteId: input.noteId,
        contentBase64: input.contentBase64,
        role: input.role ?? "related",
        mediaType: input.mediaType,
        originalFilename: input.originalFilename,
        position: input.position ?? 0
      ))
    case "configureNoteAutoAction":
      let input: GraphQLConfigureNoteAutoActionInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.configureAutoAction(
        actionId: input.actionId,
        trigger: input.trigger,
        workflowId: input.workflowId,
        filterJSON: input.filterJSON,
        enabled: input.enabled ?? true,
        position: input.position ?? 0
      ))
    case "deleteNoteAutoAction":
      return try await encodedJSONValue(service.deleteAutoAction(actionId: requiredString("actionId", variables: variables)))
    case "saveNoteConversation":
      let input: GraphQLSaveNoteConversationInput = try requiredInput("input", variables: variables)
      return try await encodedJSONValue(service.saveConversation(
        title: input.title,
        transcript: input.transcript.map(\.noteTurn),
        assignedBy: noteAPIAssignedBy(input.assignedBy, request: request),
        originatingActionId: input.originatingActionId
      ))
    case "migrateNoteFileStorage":
      let input: GraphQLMigrateNoteFileStorageInput = try requiredInput("input", variables: variables)
      do {
        let migrated = try service.service.migrateFileStorage(
          fileId: input.fileId,
          to: try input.storageProfile(
            allowedProfiles: s3Profiles,
            environment: request.environment,
            allowRawInput: allowRawS3ProfileInput,
            rawEnvironmentAllowlist: rawS3EnvironmentAllowlist
          ),
          httpClient: s3HTTPClient
        )
        return try encodedJSONValue(GraphQLNoteFileMigrationResult(
          result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
          migrated: [GraphQLNoteFileDTO(file: migrated)]
        ))
      } catch {
        return try encodedJSONValue(GraphQLNoteFileMigrationResult(
          result: noteFileMigrationControlResult(for: error, hasMigratedFiles: false),
          failures: [
            GraphQLNoteFileMigrationFailureDTO(
              NoteFileMigrationFailure(fileId: input.fileId, message: graphQLNotePublicDiagnostic(for: error))
            )
          ]
        ))
      }
    case "migrateAllNoteFiles":
      let input: GraphQLMigrateAllNoteFilesInput = try requiredInput("input", variables: variables)
      let migrated = try service.service.migrateAllLocalFiles(
        to: try input.storageProfile(
          allowedProfiles: s3Profiles,
          environment: request.environment,
          allowRawInput: allowRawS3ProfileInput,
          rawEnvironmentAllowlist: rawS3EnvironmentAllowlist
        ),
        httpClient: s3HTTPClient
      )
      return try encodedJSONValue(GraphQLNoteFileMigrationResult(
        result: noteFileMigrationControlResult(migrated),
        migrated: migrated.migrated.map(GraphQLNoteFileDTO.init),
        failures: migrated.failures.map { failure in
          GraphQLNoteFileMigrationFailureDTO(
            NoteFileMigrationFailure(fileId: failure.fileId, message: "note file migration failed")
          )
        }
      ))
    default:
      return .null
    }
  }
}

private func noteAPIAssignedBy(_ explicit: String?, request: GraphQLDocumentRequest) -> String? {
  explicit ?? request.authenticatedClientId.map { "client:\($0)" }
}

public func noteGraphQLRootFieldName(in query: String, operationName: String? = nil) -> String? {
  guard
    let fieldName = try? parseNoteGraphQLRootField(
      in: query,
      operationName: operationName,
      variables: [:],
      parseArguments: false
    )?.fieldName,
    supportedNoteGraphQLFields.contains(fieldName)
  else {
    return nil
  }
  return fieldName
}

public func noteGraphQLRootFieldNames(in query: String, operationName: String? = nil) throws -> [String] {
  try parseNoteGraphQLRootFields(
    in: query,
    operationName: operationName,
    variables: [:],
    parseArguments: false
  )?.map(\.fieldName) ?? []
}

public func noteGraphQLRequiresAuthentication(in query: String, operationName: String? = nil) -> Bool {
  do {
    return try noteGraphQLRootFieldNames(in: query, operationName: operationName)
      .contains { supportedNoteGraphQLFields.contains($0) }
  } catch {
    return true
  }
}

public func noteGraphQLOperationTypeName(in query: String, operationName: String? = nil) -> String {
  guard
    let operationType = try? parseNoteGraphQLRootFields(
      in: query,
      operationName: operationName,
      variables: [:],
      parseArguments: false
    )?.first?.operationType
  else {
    return "unknown"
  }
  switch operationType {
  case .query:
    return "query"
  case .mutation:
    return "mutation"
  }
}

let supportedNoteGraphQLFields: Set<String> = [
  "note",
  "notebook",
  "notebooks",
  "notes",
  "searchNotes",
  "proposeNoteLinks",
  "tags",
  "tagClasses",
  "noteFile",
  "autoActions",
  "createNote",
  "createNotebook",
  "defineNoteTagClass",
  "defineNoteTag",
  "scaffoldNoteIngestionWorkflow",
  "updateNote",
  "deleteNote",
  "deleteNotebook",
  "applyNotebookTags",
  "removeNotebookTag",
  "setNoteReadOnly",
  "applyNoteTags",
  "removeNoteTag",
  "addNoteComment",
  "linkNotes",
  "attachNoteFile",
  "configureNoteAutoAction",
  "deleteNoteAutoAction",
  "saveNoteConversation",
  "migrateNoteFileStorage",
  "migrateAllNoteFiles"
]

private let noteGraphQLQueryFields: Set<String> = [
  "note",
  "notebook",
  "notebooks",
  "notes",
  "searchNotes",
  "proposeNoteLinks",
  "tags",
  "tagClasses",
  "noteFile",
  "autoActions"
]

private let noteGraphQLMutationFields = supportedNoteGraphQLFields.subtracting(noteGraphQLQueryFields)

private func validateOperationType(_ operationType: GraphQLDocumentOperationType, fieldName: String) throws {
  switch operationType {
  case .query:
    guard noteGraphQLQueryFields.contains(fieldName) else {
      throw NoteGraphQLDocumentExecutorError.operationFieldMismatch(operation: "query", fieldName: fieldName)
    }
  case .mutation:
    guard noteGraphQLMutationFields.contains(fieldName) else {
      throw NoteGraphQLDocumentExecutorError.operationFieldMismatch(operation: "mutation", fieldName: fieldName)
    }
  }
}

private func validateSelections(
  _ selections: [ParsedNoteGraphQLSelectionField],
  rootFieldName: String
) throws {
  guard !selections.isEmpty else {
    return
  }
  let rootType = noteGraphQLRootSelectionTypes[rootFieldName] ?? "NoteMutationPayload"
  try validateSelections(selections, typeName: rootType, path: rootFieldName)
}

private func validateSelections(
  _ selections: [ParsedNoteGraphQLSelectionField],
  typeName: String,
  path: String
) throws {
  guard let fields = noteGraphQLSelectionFields[typeName] else {
    guard selections.isEmpty else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("\(path) does not support nested selections")
    }
    return
  }
  guard !selections.isEmpty else {
    throw NoteGraphQLDocumentExecutorError.invalidSelection("\(path) requires nested selections")
  }
  for selection in selections {
    if selection.fieldName == "__typename" {
      guard selection.selections.isEmpty else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("\(path).__typename does not support nested selections")
      }
      continue
    }
    guard let childType = fields[selection.fieldName] else {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("unsupported field '\(path).\(selection.fieldName)'")
    }
    if let childType {
      try validateSelections(selection.selections, typeName: childType, path: "\(path).\(selection.fieldName)")
    } else if !selection.selections.isEmpty {
      throw NoteGraphQLDocumentExecutorError.invalidSelection("\(path).\(selection.fieldName) does not support nested selections")
    }
  }
}

private func projectGraphQLValue(
  _ value: JSONValue,
  selections: [ParsedNoteGraphQLSelectionField],
  typeName: String
) throws -> JSONValue {
  switch value {
  case let .array(values):
    return .array(try values.map { try projectGraphQLValue($0, selections: selections, typeName: typeName) })
  case let .object(object):
    guard let fields = noteGraphQLSelectionFields[typeName] else {
      return value
    }
    var projected: JSONObject = [:]
    for selection in selections {
      if selection.fieldName == "__typename" {
        projected[selection.responseKey] = .string(typeName)
        continue
      }
      guard let childType = fields[selection.fieldName] else {
        continue
      }
      let childValue = object[selection.fieldName] ?? .null
      if let childType {
        projected[selection.responseKey] = try projectGraphQLValue(
          childValue,
          selections: selection.selections,
          typeName: childType
        )
      } else {
        projected[selection.responseKey] = childValue
      }
    }
    return .object(projected)
  case .null:
    return .null
  case .bool, .integer, .number, .string:
    return value
  }
}

private let noteGraphQLRootSelectionTypes: [String: String] = [
  "note": "NoteQueryPayload",
  "notebook": "NotebookQueryPayload",
  "notebooks": "NotebooksQueryPayload",
  "notes": "NotesQueryPayload",
  "searchNotes": "NoteSearchQueryPayload",
  "proposeNoteLinks": "NoteLinkProposalQueryPayload",
  "tags": "NoteTagsQueryPayload",
  "tagClasses": "NoteTagClassesQueryPayload",
  "noteFile": "NoteFileQueryPayload",
  "autoActions": "NoteAutoActionsQueryPayload",
  "deleteNote": "ControlPlaneResult",
  "deleteNotebook": "ControlPlaneResult",
  "deleteNoteAutoAction": "ControlPlaneResult",
  "migrateNoteFileStorage": "NoteFileMigrationPayload",
  "migrateAllNoteFiles": "NoteFileMigrationPayload"
]

let noteGraphQLSelectionFields: [String: [String: String?]] = [
  "ControlPlaneResult": [
    "accepted": nil,
    "status": nil,
    "diagnostics": nil
  ],
  "NoteQueryPayload": noteGraphQLQueryPayloadFields(valueType: "Note"),
  "NotebookQueryPayload": noteGraphQLQueryPayloadFields(valueType: "Notebook"),
  "NotebooksQueryPayload": noteGraphQLQueryPayloadFields(valueType: "Notebook"),
  "NotesQueryPayload": noteGraphQLQueryPayloadFields(valueType: "Note"),
  "NoteSearchQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteSearchResult"),
  "NoteLinkProposalQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteLinkProposal"),
  "NoteTagsQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteTag"),
  "NoteTagClassesQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteTagClass"),
  "NoteFileQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteFile"),
  "NoteAutoActionsQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteAutoAction"),
  "NoteMutationPayload": [
    "result": "ControlPlaneResult",
    "note": "Note",
    "notebook": "Notebook",
    "notes": "Note",
    "tag": "NoteTag",
    "tagClass": "NoteTagClass",
    "file": "NoteFile",
    "comment": "NoteComment",
    "link": "NoteLink",
    "autoAction": "NoteAutoAction",
    "workflowScaffold": "NoteWorkflowScaffold"
  ],
  "NoteFileMigrationPayload": [
    "result": "ControlPlaneResult",
    "migrated": "NoteFile",
    "failures": "NoteFileMigrationFailure"
  ],
  "Note": [
    "noteId": nil,
    "notebookId": nil,
    "noteNumber": nil,
    "title": nil,
    "bodyMarkdown": nil,
    "readOnly": nil,
    "createdAt": nil,
    "updatedAt": nil,
    "metaJSON": nil,
    "tags": "NoteTagAssignment"
  ],
  "Notebook": [
    "notebookId": nil,
    "title": nil,
    "createdAt": nil,
    "updatedAt": nil,
    "metaJSON": nil,
    "tags": "NoteTagAssignment",
    "firstNotePreview": nil,
    "noteCount": nil
  ],
  "NoteTagAssignment": [
    "tag": "NoteTag",
    "provenance": nil,
    "assignedBy": nil,
    "deletable": nil,
    "createdAt": nil
  ],
  "NoteTag": [
    "tagId": nil,
    "name": nil,
    "classId": nil,
    "isSystem": nil,
    "createdAt": nil
  ],
  "NoteTagClass": [
    "classId": nil,
    "label": nil,
    "description": nil,
    "isSystem": nil,
    "createdAt": nil
  ],
  "NoteFile": [
    "fileId": nil,
    "storageKind": nil,
    "localPath": nil,
    "s3Profile": nil,
    "s3Bucket": nil,
    "s3Key": nil,
    "mediaType": nil,
    "byteSize": nil,
    "sha256": nil,
    "originalFilename": nil,
    "createdAt": nil,
    "migratedAt": nil
  ],
  "NoteComment": [
    "commentId": nil,
    "noteId": nil,
    "bodyMarkdown": nil,
    "author": nil,
    "createdAt": nil
  ],
  "NoteLink": [
    "fromNoteId": nil,
    "toNoteId": nil,
    "linkKind": nil,
    "provenance": nil,
    "createdAt": nil
  ],
  "NoteSearchResult": [
    "note": "Note",
    "snippet": nil,
    "rank": nil,
    "matchedTags": "NoteTag",
    "isLinkedNeighbor": nil
  ],
  "NoteLinkProposal": [
    "targetNote": "Note",
    "targetNoteId": nil,
    "linkKind": nil,
    "reason": nil,
    "source": nil
  ],
  "NoteAutoAction": [
    "actionId": nil,
    "trigger": nil,
    "workflowId": nil,
    "filterJSON": nil,
    "enabled": nil,
    "position": nil,
    "createdAt": nil
  ],
  "NoteWorkflowScaffoldFile": [
    "relativePath": nil,
    "path": nil
  ],
  "NoteWorkflowScaffold": [
    "workflowId": nil,
    "workflowRoot": nil,
    "workflowPath": nil,
    "files": "NoteWorkflowScaffoldFile"
  ],
  "NoteFileMigrationFailure": [
    "fileId": nil,
    "message": nil
  ]
]

private func noteGraphQLQueryPayloadFields(valueType: String) -> [String: String?] {
  [
    "result": "ControlPlaneResult",
    "value": valueType
  ]
}

private func noteFileMigrationControlResult(_ result: NoteFileMigrationResult) -> GraphQLControlPlaneResult {
  guard !result.failures.isEmpty else {
    return GraphQLControlPlaneResult(accepted: true, status: "ok")
  }
  return GraphQLControlPlaneResult(
    accepted: false,
    status: result.migrated.isEmpty ? "failed" : "partial",
    diagnostics: result.failures.map { "\($0.fileId): \($0.message)" }
  )
}

private func noteFileMigrationControlResult(
  for error: Error,
  hasMigratedFiles: Bool
) -> GraphQLControlPlaneResult {
  GraphQLControlPlaneResult(
    accepted: false,
    status: hasMigratedFiles ? "partial" : "failed",
    diagnostics: [graphQLNotePublicDiagnostic(for: error)]
  )
}

enum NoteGraphQLDocumentExecutorError: Error, Equatable {
  case missingVariable(String)
  case invalidVariable(String)
  case invalidSelection(String)
  case operationFieldMismatch(operation: String, fieldName: String)
}

private func encodedJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func requiredInput<T: Decodable>(_ key: String, variables: JSONObject) throws -> T {
  guard let value = variables[key], value != .null else {
    throw NoteGraphQLDocumentExecutorError.missingVariable(key)
  }
  return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

private func requiredString(_ key: String, variables: JSONObject) throws -> String {
  guard case let .string(value)? = variables[key] else {
    throw NoteGraphQLDocumentExecutorError.missingVariable(key)
  }
  guard !value.isEmpty else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must not be empty")
  }
  return value
}

private func optionalString(_ key: String, variables: JSONObject) throws -> String? {
  guard let value = variables[key], value != .null else {
    return nil
  }
  guard case let .string(string) = value else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be a string")
  }
  return string.isEmpty ? nil : string
}

private func requiredBool(_ key: String, variables: JSONObject) throws -> Bool {
  guard case let .bool(value)? = variables[key] else {
    throw NoteGraphQLDocumentExecutorError.missingVariable(key)
  }
  return value
}

private func optionalBool(_ key: String, variables: JSONObject) throws -> Bool? {
  guard let value = variables[key], value != .null else {
    return nil
  }
  guard case let .bool(bool) = value else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be a boolean")
  }
  return bool
}

private func optionalInt(_ key: String, variables: JSONObject) throws -> Int? {
  if case let .integer(value)? = variables[key] {
    return Int(value)
  }
  guard case let .number(value)? = variables[key] else {
    return nil
  }
  guard value.rounded(.towardZero) == value else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be an integer")
  }
  return Int(value)
}

private func boundedLimit(_ value: Int?, defaultValue: Int, maximum: Int = 200) -> Int {
  min(max(value ?? defaultValue, 1), maximum)
}

private func boundedOffset(_ value: Int?) -> Int {
  max(value ?? 0, 0)
}

private func optionalStringArray(_ key: String, variables: JSONObject) throws -> [String]? {
  guard let value = variables[key], value != .null else {
    return nil
  }
  guard case let .array(values) = value else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be an array of strings")
  }
  return try values.map { value in
    guard case let .string(string) = value else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be an array of strings")
    }
    return string
  }
}
