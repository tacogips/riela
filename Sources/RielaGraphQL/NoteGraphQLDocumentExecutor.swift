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
    let rootFields: [ParsedNoteGraphQLRootField]
    do {
      guard let parsed = try parseNoteGraphQLRootFields(
        in: request.query,
        operationName: request.operationName,
        variables: request.variables,
        parseArguments: true
      ), !parsed.isEmpty else {
        return .notHandled
      }
      rootFields = parsed
    } catch {
      // The document failed to parse. Routing only dispatches note documents to
      // this executor, so surface the explicit parse error rather than falling
      // through. Use the note root field as the response key when it can still be
      // identified by the directive-tolerant scan.
      let responseKey = noteGraphQLRootFieldName(in: request.query, operationName: request.operationName) ?? "noteGraphQL"
      return errorResponse(responseKeys: [responseKey], error: error)
    }
    // This executor owns the document only when every root selection is a note
    // field. A document with no note fields belongs to another executor.
    guard rootFields.contains(where: { supportedNoteGraphQLFields.contains($0.fieldName) }) else {
      return .notHandled
    }
    do {
      var data: JSONObject = [:]
      for rootField in rootFields {
        guard supportedNoteGraphQLFields.contains(rootField.fieldName) else {
          throw NoteGraphQLDocumentExecutorError.invalidSelection("unsupported root field '\(rootField.fieldName)'")
        }
        try validateOperationType(rootField.operationType, fieldName: rootField.fieldName)
        try validateSelections(rootField.selections, rootFieldName: rootField.fieldName)
        var routedRequest = request
        routedRequest.variables = rootField.arguments
        guard data[rootField.responseKey] == nil else {
          throw NoteGraphQLDocumentExecutorError.invalidSelection("duplicate response key '\(rootField.responseKey)'")
        }
        let value = try await execute(fieldName: rootField.fieldName, request: routedRequest)
        let rootType = noteGraphQLRootSelectionTypes[rootField.fieldName] ?? "NoteMutationPayload"
        data[rootField.responseKey] = try projectGraphQLValue(value, selections: rootField.selections, typeName: rootType)
      }
      return GraphQLDocumentExecutionResponse(handled: true, body: ["data": .object(data)])
    } catch {
      return errorResponse(responseKeys: rootFields.map(\.responseKey), error: error)
    }
  }

  private func errorResponse(responseKeys: [String], error: Error) -> GraphQLDocumentExecutionResponse {
    var data: JSONObject = [:]
    for responseKey in responseKeys {
      data[responseKey] = .null
    }
    return GraphQLDocumentExecutionResponse(
      handled: true,
      body: [
        "data": .object(data),
        "errors": .array([.object(["message": .string(graphQLNotePublicDiagnostic(for: error))])])
      ]
    )
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
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 50),
        offset: validatedOffset(try optionalInt("offset", variables: variables)),
        tagFilter: try optionalStringArray("tagFilter", variables: variables) ?? [],
        sort: try optionalString("sort", variables: variables),
        createdAfter: try optionalString("createdAfter", variables: variables),
        createdBefore: try optionalString("createdBefore", variables: variables)
      ))
    case "notes":
      return try await encodedJSONValue(service.notes(
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 50),
        offset: validatedOffset(try optionalInt("offset", variables: variables)),
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
        depth: try optionalInt("depth", variables: variables) ?? 1,
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 20),
        offset: validatedOffset(try optionalInt("offset", variables: variables))
      ))
    case "noteGraphNeighbors":
      return try await encodedJSONValue(service.noteGraphNeighbors(
        noteIds: try optionalStringArray("noteIds", variables: variables) ?? [],
        depth: try optionalInt("depth", variables: variables) ?? NoteGraphPolicy.defaultMaxDepth,
        limit: validatedLimit(
          try optionalInt("limit", variables: variables),
          defaultValue: NoteGraphPolicy.defaultLimit
        )
      ))
    case "proposeNoteLinks":
      return try await encodedJSONValue(service.proposeNoteLinks(
        noteId: requiredString("noteId", variables: variables),
        limit: validatedLimit(try optionalInt("limit", variables: variables), defaultValue: 8)
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
      input.assignedBy = try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request)
      return try await encodedJSONValue(service.createNote(input))
    case "createNotebook":
      return try await encodedJSONValue(service.createNotebook(requiredInput("input", variables: variables)))
    case "defineNoteTagClass":
      return try await encodedJSONValue(service.defineTagClass(requiredInput("input", variables: variables)))
    case "defineNoteTag":
      return try await encodedJSONValue(service.defineTag(requiredInput("input", variables: variables)))
    case "scaffoldNoteIngestionWorkflow":
      var input: GraphQLScaffoldNoteWorkflowInput = try requiredInput("input", variables: variables)
      input.assignedBy = try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request)
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
      input.assignedBy = try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request)
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
        assignedBy: try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request)
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
        author: try noteAPIAssignedBy(input.author, field: "author", request: request) ?? "user"
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
        assignedBy: try noteAPIAssignedBy(input.assignedBy, field: "assignedBy", request: request),
        originatingActionId: input.originatingActionId
      ))
    case "migrateNoteFileStorage":
      let input: GraphQLMigrateNoteFileStorageInput = try requiredInput("input", variables: variables)
      do {
        let migrated = try service.service.migrateFileStorageOutcome(
          fileId: input.fileId,
          to: try input.storageProfile(
            allowedProfiles: s3Profiles,
            environment: request.environment,
            allowRawInput: allowRawS3ProfileInput,
            rawEnvironmentAllowlist: rawS3EnvironmentAllowlist
          ),
          httpClient: s3HTTPClient,
          verifyRemoteRead: false
        )
        return try encodedJSONValue(GraphQLNoteFileMigrationResult(
          result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
          migrated: [GraphQLNoteFileDTO(file: migrated.record)],
          cleanupFailures: migrated.cleanupFailure.map {
            [GraphQLNoteFileMigrationFailureDTO(
              NoteFileMigrationFailure(fileId: $0.fileId, message: noteFileMigrationFailureMessage)
            )]
          } ?? []
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
            NoteFileMigrationFailure(fileId: failure.fileId, message: noteFileMigrationFailureMessage)
          )
        },
        cleanupFailures: migrated.cleanupFailures.map { failure in
          GraphQLNoteFileMigrationFailureDTO(
            NoteFileMigrationFailure(fileId: failure.fileId, message: noteFileMigrationFailureMessage)
          )
        }
      ))
    case "reclaimNoteFileStorage":
      let input: GraphQLReclaimNoteFileStorageInput = try requiredInput("input", variables: variables)
      if let graceHours = input.graceHours, graceHours < 0 {
        throw NoteGraphQLDocumentExecutorError.invalidVariable("graceHours must not be negative")
      }
      let profile = try input.optionalStorageProfile(
        allowedProfiles: s3Profiles,
        environment: request.environment,
        allowRawInput: allowRawS3ProfileInput,
        rawEnvironmentAllowlist: rawS3EnvironmentAllowlist
      )
      let reclaimed = try service.service.reclaimUnreferencedFiles(
        olderThan: TimeInterval(input.graceHours ?? 24) * 60 * 60,
        s3Profiles: profile.map { [$0] } ?? [],
        httpClient: s3HTTPClient
      )
      return try encodedJSONValue(GraphQLNoteFileReclamationResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        deletedFileIds: reclaimed.deletedFileIds,
        sweptPaths: reclaimed.sweptPaths
      ))
    default:
      return .null
    }
  }
}

/// Resolves the audit-attribution identity (`assignedBy`/`author`) for a note
/// mutation.
///
/// On the authenticated HTTP note API (`authenticatedClientId` non-nil) the
/// identity is always the bearer-verified `client:<id>`; any explicit value in
/// the request is rejected so attribution cannot be forged. On the local
/// operator path (`authenticatedClientId` nil) the explicit value is honored.
private func noteAPIAssignedBy(
  _ explicit: String?,
  field: String,
  request: GraphQLDocumentRequest
) throws -> String? {
  guard let clientId = request.authenticatedClientId else {
    return explicit
  }
  guard explicit == nil else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "\(field) cannot be set by an authenticated note API client"
    )
  }
  return "client:\(clientId)"
}

public func noteGraphQLRootFieldName(in query: String, operationName: String? = nil) -> String? {
  guard
    let fieldName = try? parseNoteGraphQLRootFields(
      in: query,
      operationName: operationName,
      variables: [:],
      parseArguments: false
    )?.first(where: { supportedNoteGraphQLFields.contains($0.fieldName) })?.fieldName
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
  "noteGraphNeighbors",
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
  "migrateAllNoteFiles",
  "reclaimNoteFileStorage"
]

private let noteGraphQLQueryFields: Set<String> = [
  "note",
  "notebook",
  "notebooks",
  "notes",
  "searchNotes",
  "noteGraphNeighbors",
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
        guard projected[selection.responseKey] == nil else {
          throw NoteGraphQLDocumentExecutorError.invalidSelection("duplicate response key '\(selection.responseKey)'")
        }
        projected[selection.responseKey] = .string(typeName)
        continue
      }
      guard let childType = fields[selection.fieldName] else {
        continue
      }
      guard projected[selection.responseKey] == nil else {
        throw NoteGraphQLDocumentExecutorError.invalidSelection("duplicate response key '\(selection.responseKey)'")
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
  "noteGraphNeighbors": "NoteGraphNeighborsQueryPayload",
  "proposeNoteLinks": "NoteLinkProposalQueryPayload",
  "tags": "NoteTagsQueryPayload",
  "tagClasses": "NoteTagClassesQueryPayload",
  "noteFile": "NoteFileQueryPayload",
  "autoActions": "NoteAutoActionsQueryPayload",
  "deleteNote": "ControlPlaneResult",
  "deleteNotebook": "ControlPlaneResult",
  "deleteNoteAutoAction": "ControlPlaneResult",
  "migrateNoteFileStorage": "NoteFileMigrationPayload",
  "migrateAllNoteFiles": "NoteFileMigrationPayload",
  "reclaimNoteFileStorage": "NoteFileReclamationPayload"
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
  "NoteGraphNeighborsQueryPayload": noteGraphQLQueryPayloadFields(valueType: "NoteGraphNeighbor"),
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
    "failures": "NoteFileMigrationFailure",
    "cleanupFailures": "NoteFileMigrationFailure"
  ],
  "NoteFileReclamationPayload": [
    "result": "ControlPlaneResult",
    "deletedFileIds": nil,
    "sweptPaths": nil
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
  "NoteGraphNeighbor": [
    "seedNoteId": nil,
    "note": "Note",
    "edgeKind": nil,
    "weight": nil,
    "hopCount": nil,
    "pathNoteIds": nil
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
    // Redact per-file diagnostics with the same fixed message as the `failures`
    // list; `$0.message` is raw `String(describing: error)` and would otherwise
    // disclose paths, SQL, or S3 endpoints in a client-selectable field.
    diagnostics: result.failures.map { "\($0.fileId): \(noteFileMigrationFailureMessage)" }
  )
}

/// Fixed, redacted message reported for every note file migration failure in
/// the `failures` list so that raw storage errors (paths, SQL, S3 endpoints)
/// never reach a response body.
let noteFileMigrationFailureMessage = "note file migration failed"

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
  guard !string.isEmpty else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must not be empty")
  }
  return string
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
  guard let value = variables[key], value != .null else {
    return nil
  }
  switch value {
  case let .integer(integer):
    guard let converted = Int(exactly: integer) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) is out of range")
    }
    return converted
  case let .number(number):
    guard let converted = Int(exactly: number) else {
      throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be an integer")
    }
    return converted
  default:
    throw NoteGraphQLDocumentExecutorError.invalidVariable("\(key) must be an integer")
  }
}

/// The maximum page size accepted by `limit` on every list/search field.
/// Mirrored in the SDL contract text (`GraphQLNoteSchemaContract.swift`).
let noteGraphQLMaximumLimit = 200
/// The maximum `offset` accepted on every list/search field.
let noteGraphQLMaximumOffset = 1_000_000

private func validatedLimit(_ value: Int?, defaultValue: Int) throws -> Int {
  guard let value else {
    return defaultValue
  }
  guard (0...noteGraphQLMaximumLimit).contains(value) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "limit must be between 0 and \(noteGraphQLMaximumLimit)"
    )
  }
  return value
}

private func validatedOffset(_ value: Int?) throws -> Int {
  guard let value else {
    return 0
  }
  guard (0...noteGraphQLMaximumOffset).contains(value) else {
    throw NoteGraphQLDocumentExecutorError.invalidVariable(
      "offset must be between 0 and \(noteGraphQLMaximumOffset)"
    )
  }
  return value
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
