import Foundation
import RielaCore
import RielaGraphQL
import RielaNote
import RielaServer

public struct NoteCommandRunner: Sendable {
  public init() {}

  public func run(_ command: NoteCommand) async -> CLICommandResult {
    do {
      switch command.kind {
      case .add:
        return try await add(command.options)
      case .edit:
        return try await edit(command.options)
      case .delete:
        return try await delete(command.options)
      case .show:
        return try await show(command.options)
      case .list:
        return try await list(command.options)
      case .search:
        return try await search(command.options)
      case .tag:
        return try await tag(command.options)
      case .comment:
        return try await comment(command.options)
      case .attach:
        return try await attach(command.options)
      case .readonly:
        return try await readonly(command.options)
      case .notebook:
        return try await notebook(command.options)
      case .storage:
        return try await storage(command.options)
      case .client:
        return try await client(command.options)
      }
    } catch let error as CLIUsageError {
      return failure(error.message, output: command.options.output)
    } catch {
      return failure("\(error)", output: command.options.output)
    }
  }

  private func add(_ options: CLICommandOptions) async throws -> CLICommandResult {
    if let target = options.target {
      throw CLIUsageError("note add does not accept positional argument '\(target)'")
    }
    let parsed = try NoteCommandOptions(options)
    let body = try parsed.requiredBody(command: "note add")
    let output: GraphQLNoteMutationResult = try await executeNoteDocument(
      field: "createNote",
      query: NoteCommandGraphQLDocuments.createNote,
      variables: [
        "input": try jsonValue(GraphQLCreateNoteInput(
          notebookId: parsed.notebookId,
          notebookTitle: parsed.notebookTitle,
          title: parsed.title,
          bodyMarkdown: body,
          readOnly: parsed.readOnly,
          tags: parsed.tags.map { GraphQLNoteTagInput(name: $0, classId: parsed.tagClassId) },
          provenance: parsed.provenance,
          assignedBy: parsed.assignedBy
        ))
      ],
      options: parsed
    )
    guard output.result.accepted else {
      return try render(output, accepted: false, options: options, text: { _ in output.result.diagnostics.joined(separator: "\n") + "\n" })
    }
    return try render(output, options: options) { result in
      guard let note = result.note else {
        return ""
      }
      return "created note \(note.noteId) in notebook \(note.notebookId)\n"
    }
  }

  private func edit(_ options: CLICommandOptions) async throws -> CLICommandResult {
    let parsed = try NoteCommandOptions(options)
    guard let noteId = options.target else {
      throw CLIUsageError("note edit requires a note id")
    }
    let newBody = try parsed.requiredBody(command: "note edit")
    let body: String
    if parsed.appendBody {
      let existing: GraphQLNoteQueryResult<GraphQLNoteDTO> = try await executeNoteDocument(
        field: "note",
        query: "query Note($noteId: String!) { note(noteId: $noteId) { result { \(NoteCommandGraphQLDocuments.controlResult) } value { \(NoteCommandGraphQLDocuments.note) } } }",
        variables: ["noteId": .string(noteId)],
        options: parsed
      )
      guard existing.result.accepted, let note = existing.value else {
        return try render(existing, accepted: false, options: options) { result in
          result.result.diagnostics.joined(separator: "\n") + "\n"
        }
      }
      body = appendedNoteBody(existing: note.bodyMarkdown, addition: newBody)
    } else {
      body = newBody
    }
    let output: GraphQLNoteMutationResult = try await executeNoteDocument(
      field: "updateNote",
      query: NoteCommandGraphQLDocuments.updateNote,
      variables: [
        "input": try jsonValue(GraphQLUpdateNoteInput(noteId: noteId, bodyMarkdown: body, originatingActionId: nil))
      ],
      options: parsed
    )
    return try renderNoteMutation(output, options: options, verb: "updated")
  }

  private func delete(_ options: CLICommandOptions) async throws -> CLICommandResult {
    let parsed = try NoteCommandOptions(options)
    if let notebookId = parsed.notebookId {
      guard options.target == nil else {
        throw CLIUsageError("note delete cannot combine a note id with --notebook")
      }
      let output: GraphQLControlPlaneResult = try await executeNoteDocument(
        field: "deleteNotebook",
        query: "mutation DeleteNotebook($notebookId: String!) { deleteNotebook(notebookId: $notebookId) { accepted status diagnostics } }",
        variables: ["notebookId": .string(notebookId)],
        options: parsed
      )
      return try render(output, accepted: output.accepted, options: options) { result in
        guard result.accepted else {
          return result.diagnostics.joined(separator: "\n") + "\n"
        }
        return "deleted notebook \(notebookId)\n"
      }
    }
    guard let noteId = options.target else {
      throw CLIUsageError("note delete requires a note id")
    }
    let output: GraphQLControlPlaneResult = try await executeNoteDocument(
      field: "deleteNote",
      query: "mutation DeleteNote($noteId: String!) { deleteNote(noteId: $noteId) { accepted status diagnostics } }",
      variables: ["noteId": .string(noteId)],
      options: parsed
    )
    return try render(output, accepted: output.accepted, options: options) { result in
      guard result.accepted else {
        return result.diagnostics.joined(separator: "\n") + "\n"
      }
      return "deleted note \(noteId)\n"
    }
  }

  private func show(_ options: CLICommandOptions) async throws -> CLICommandResult {
    guard let noteId = options.target else {
      throw CLIUsageError("note show requires a note id")
    }
    let parsed = try NoteCommandOptions(options)
    let output: GraphQLNoteQueryResult<GraphQLNoteDTO> = try await executeNoteDocument(
      field: "note",
      query: "query Note($noteId: String!) { note(noteId: $noteId) { value { \(NoteCommandGraphQLDocuments.note) } result { \(NoteCommandGraphQLDocuments.controlResult) } } }",
      variables: ["noteId": .string(noteId)],
      options: parsed
    )
    return try render(output, accepted: output.result.accepted, options: options) { result in
      guard let note = result.value else {
        return result.result.diagnostics.joined(separator: "\n") + "\n"
      }
      return "# \(note.title ?? note.noteId)\n\n\(note.bodyMarkdown)\n"
    }
  }

  private func list(_ options: CLICommandOptions) async throws -> CLICommandResult {
    let parsed = try NoteCommandOptions(options)
    let output: GraphQLNoteQueryResult<[GraphQLNoteDTO]> = try await executeNoteDocument(
      field: "notes",
      query: NoteCommandGraphQLDocuments.notes,
      variables: parsed.noteListVariables(),
      options: parsed
    )
    return try render(output, accepted: output.result.accepted, options: options) { result in
      guard result.result.accepted else {
        return result.result.diagnostics.joined(separator: "\n") + "\n"
      }
      return (result.value ?? []).map { note in
        "\(note.createdAt) \(note.noteId) \(note.title ?? "")"
      }.joined(separator: "\n") + ((result.value ?? []).isEmpty ? "" : "\n")
    }
  }

  private func search(_ options: CLICommandOptions) async throws -> CLICommandResult {
    let parsed = try NoteCommandOptions(options)
    let query = parsed.query ?? options.target
    guard let query, !query.isEmpty else {
      throw CLIUsageError("note search requires a query")
    }
    let output: GraphQLNoteQueryResult<[GraphQLNoteSearchResultDTO]> = try await executeNoteDocument(
      field: "searchNotes",
      query: NoteCommandGraphQLDocuments.searchNotes,
      variables: [
        "query": .string(query),
        "tagFilter": .array(parsed.tags.map { .string($0) }),
        "classFilter": .array(parsed.classFilter.map { .string($0) }),
        "limit": .integer(Int64(parsed.limit)),
        "offset": .integer(Int64(parsed.offset))
      ],
      options: parsed
    )
    return try render(output, accepted: output.result.accepted, options: options) { result in
      guard result.result.accepted else {
        return result.result.diagnostics.joined(separator: "\n") + "\n"
      }
      return (result.value ?? []).map { searchResult in
        "\(searchResult.note.noteId) \(searchResult.note.title ?? "") \(searchResult.snippet)"
      }.joined(separator: "\n") + ((result.value ?? []).isEmpty ? "" : "\n")
    }
  }

  private func tag(_ options: CLICommandOptions) async throws -> CLICommandResult {
    guard let noteId = options.target else {
      throw CLIUsageError("note tag requires a note id")
    }
    let parsed = try NoteCommandOptions(options)
    guard !parsed.tags.isEmpty || !parsed.removeTags.isEmpty else {
      throw CLIUsageError("note tag requires --tag, --add, or --remove")
    }
    guard parsed.tags.isEmpty || parsed.removeTags.isEmpty else {
      throw CLIUsageError("note tag cannot combine add/apply and remove operations")
    }
    let output = NoteTagCommandResult(
      applied: try await applyTags(parsed.tags, noteId: noteId, parsed: parsed),
      removed: try await removeTags(parsed.removeTags, noteId: noteId, parsed: parsed)
    )
    return try render(output, accepted: output.accepted, options: options) { result in
      if let failed = result.firstRejected {
        return failed.result.diagnostics.joined(separator: "\n") + "\n"
      }
      return "tagged \(result.applied.count) and removed \(result.removed.count) tag(s) from note \(noteId)\n"
    }
  }

  private func applyTags(
    _ tagNames: [String],
    noteId: String,
    parsed: NoteCommandOptions
  ) async throws -> [GraphQLNoteMutationResult] {
    guard !tagNames.isEmpty else {
      return []
    }
    let result: GraphQLNoteMutationResult = try await executeNoteDocument(
      field: "applyNoteTags",
      query: NoteCommandGraphQLDocuments.applyNoteTags,
      variables: [
        "input": try jsonValue(GraphQLApplyNoteTagsInput(
          noteId: noteId,
          tags: tagNames.map { GraphQLNoteTagInput(name: $0, classId: parsed.tagClassId) },
          provenance: parsed.provenance,
          assignedBy: parsed.assignedBy
        ))
      ],
      options: parsed
    )
    return [result]
  }

  private func removeTags(
    _ tagNames: [String],
    noteId: String,
    parsed: NoteCommandOptions
  ) async throws -> [GraphQLNoteMutationResult] {
    var results: [GraphQLNoteMutationResult] = []
    for tagName in tagNames {
      let result: GraphQLNoteMutationResult = try await executeNoteDocument(
        field: "removeNoteTag",
        query: NoteCommandGraphQLDocuments.removeNoteTag,
        variables: [
          "noteId": .string(noteId),
          "tagName": .string(tagName),
          "provenance": .string(parsed.provenance)
        ],
        options: parsed
      )
      results.append(result)
      guard result.result.accepted else {
        return results
      }
    }
    return results
  }

  private func comment(_ options: CLICommandOptions) async throws -> CLICommandResult {
    guard let noteId = options.target else {
      throw CLIUsageError("note comment requires a note id")
    }
    let parsed = try NoteCommandOptions(options)
    let body = try parsed.requiredBody(command: "note comment")
    let output: GraphQLNoteMutationResult = try await executeNoteDocument(
      field: "addNoteComment",
      query: NoteCommandGraphQLDocuments.addNoteComment,
      variables: [
        "input": try jsonValue(GraphQLAddNoteCommentInput(
          noteId: noteId,
          bodyMarkdown: body,
          author: parsed.author ?? parsed.assignedBy ?? "user"
        ))
      ],
      options: parsed
    )
    return try render(output, accepted: output.result.accepted, options: options) { result in
      guard result.result.accepted, let comment = result.comment else {
        return result.result.diagnostics.joined(separator: "\n") + "\n"
      }
      return "added comment \(comment.commentId) to note \(comment.noteId)\n"
    }
  }

  private func attach(_ options: CLICommandOptions) async throws -> CLICommandResult {
    guard let noteId = options.target else {
      throw CLIUsageError("note attach requires a note id")
    }
    let parsed = try NoteCommandOptions(options)
    guard let filePath = parsed.filePath ?? parsed.firstPositional else {
      throw CLIUsageError("note attach requires a file path or --file")
    }
    let fileURL = absoluteURL(filePath, relativeTo: URL(fileURLWithPath: parsed.workingDirectory, isDirectory: true))
    let output = localAttachNoteFile(noteId: noteId, fileURL: fileURL, parsed: parsed)
    return try render(output, accepted: output.result.accepted, options: options) { result in
      guard result.result.accepted, let file = result.file else {
        return result.result.diagnostics.joined(separator: "\n") + "\n"
      }
      return "attached file \(file.fileId) to note \(noteId)\n"
    }
  }

  private func readonly(_ options: CLICommandOptions) async throws -> CLICommandResult {
    guard let noteId = options.target else {
      throw CLIUsageError("note readonly requires a note id")
    }
    let parsed = try NoteCommandOptions(options)
    guard parsed.readOnlyValueCount == 1 else {
      throw CLIUsageError("note readonly requires exactly one of --on, --off, or --value")
    }
    let output: GraphQLNoteMutationResult = try await executeNoteDocument(
      field: "setNoteReadOnly",
      query: NoteCommandGraphQLDocuments.setNoteReadOnly,
      variables: ["noteId": .string(noteId), "readOnly": .bool(parsed.readOnly)],
      options: parsed
    )
    return try renderNoteMutation(output, options: options, verb: "updated")
  }

  private func notebook(_ options: CLICommandOptions) async throws -> CLICommandResult {
    let parsed = try NoteCommandOptions(options)
    switch options.target {
    case "list":
      let output: GraphQLNoteQueryResult<[GraphQLNotebookDTO]> = try await executeNoteDocument(
        field: "notebooks",
        query: """
        query Notebooks($limit: Int, $offset: Int, $tagFilter: [String!]) {
          notebooks(limit: $limit, offset: $offset, tagFilter: $tagFilter) {
            value { \(NoteCommandGraphQLDocuments.notebook) }
            result { \(NoteCommandGraphQLDocuments.controlResult) }
          }
        }
        """,
        variables: [
          "limit": .integer(Int64(parsed.limit)),
          "offset": .integer(Int64(parsed.offset)),
          "tagFilter": .array(parsed.tags.map { .string($0) })
        ],
        options: parsed
      )
      return try render(output, accepted: output.result.accepted, options: options) { result in
        (result.value ?? []).map { notebook in
          "\(notebook.createdAt) \(notebook.notebookId) \(notebook.title)"
        }.joined(separator: "\n") + ((result.value ?? []).isEmpty ? "" : "\n")
      }
    case "show":
      guard let notebookId = parsed.firstPositional else {
        throw CLIUsageError("note notebook show requires a notebook id")
      }
      let output: GraphQLNoteQueryResult<GraphQLNotebookDTO> = try await executeNoteDocument(
        field: "notebook",
        query: "query Notebook($notebookId: String!) { notebook(notebookId: $notebookId) { value { \(NoteCommandGraphQLDocuments.notebook) } result { \(NoteCommandGraphQLDocuments.controlResult) } } }",
        variables: ["notebookId": .string(notebookId)],
        options: parsed
      )
      return try render(output, accepted: output.result.accepted, options: options) { result in
        guard let notebook = result.value else {
          return result.result.diagnostics.joined(separator: "\n") + "\n"
        }
        return "\(notebook.notebookId) \(notebook.title)\n"
      }
    case "create":
      guard let title = parsed.title ?? parsed.firstPositional else {
        throw CLIUsageError("note notebook create requires a title")
      }
      let output: GraphQLNoteMutationResult = try await executeNoteDocument(
        field: "createNotebook",
        query: NoteCommandGraphQLDocuments.createNotebook,
        variables: [
          "input": try jsonValue(GraphQLCreateNotebookInput(title: title, kindTagName: parsed.kindTagName))
        ],
        options: parsed
      )
      return try render(output, accepted: output.result.accepted, options: options) { result in
        guard result.result.accepted, let notebook = result.notebook else {
          return result.result.diagnostics.joined(separator: "\n") + "\n"
        }
        return "created notebook \(notebook.notebookId)\n"
      }
    case "delete":
      guard let notebookId = parsed.firstPositional else {
        throw CLIUsageError("note notebook delete requires a notebook id")
      }
      let output: GraphQLControlPlaneResult = try await executeNoteDocument(
        field: "deleteNotebook",
        query: "mutation DeleteNotebook($notebookId: String!) { deleteNotebook(notebookId: $notebookId) { accepted status diagnostics } }",
        variables: ["notebookId": .string(notebookId)],
        options: parsed
      )
      return try render(output, accepted: output.accepted, options: options) { result in
        guard result.accepted else {
          return result.diagnostics.joined(separator: "\n") + "\n"
        }
        return "deleted notebook \(notebookId)\n"
      }
    default:
      throw CLIUsageError("unsupported note notebook subcommand '\(options.target ?? "")'")
    }
  }

  private func storage(_ options: CLICommandOptions) async throws -> CLICommandResult {
    let parsed = try NoteCommandOptions(options)
    switch options.target {
    case "migrate":
      let migrateSingleFile = parsed.firstPositional != nil
      guard migrateSingleFile != parsed.migrateAll else {
        if migrateSingleFile {
          throw CLIUsageError("note storage migrate cannot combine a file id with --all")
        }
        throw CLIUsageError("note storage migrate requires a file id or --all")
      }
      _ = try parsed.s3StorageProfile()
      let output: GraphQLNoteFileMigrationResult
      if let fileId = parsed.firstPositional {
        output = try await executeNoteDocument(
          field: "migrateNoteFileStorage",
          query: NoteCommandGraphQLDocuments.migrateNoteFileStorage,
          variables: ["input": try jsonValue(parsed.migrateFileInput(fileId: fileId))],
          options: parsed
        )
      } else {
        output = try await executeNoteDocument(
          field: "migrateAllNoteFiles",
          query: NoteCommandGraphQLDocuments.migrateAllNoteFiles,
          variables: ["input": try jsonValue(parsed.migrateAllInput())],
          options: parsed
        )
      }
      return try render(output, accepted: output.result.accepted && output.failures.isEmpty, options: options) { result in
        var lines = ["migrated \(result.migrated.count) file(s)"]
        if !result.failures.isEmpty {
          lines.append("failed \(result.failures.count) file(s)")
          lines.append(contentsOf: result.failures.map { "\($0.fileId): \($0.message)" })
        }
        return lines.joined(separator: "\n") + "\n"
      }
    default:
      throw CLIUsageError("unsupported note storage subcommand '\(options.target ?? "")'")
    }
  }

  private func client(_ options: CLICommandOptions) async throws -> CLICommandResult {
    let parsed = try NoteCommandOptions(options)
    let noteService = try service(parsed)
    switch options.target {
    case "register":
      let displayName = parsed.displayName ?? parsed.firstPositional ?? "Riela Note client"
      let output = try await registerClient(
        displayName: displayName,
        noteService: noteService,
        noteRoot: parsed.noteRoot,
        direct: parsed.directRegistration
      )
      return try render(output, options: options) { output in
        """
        registered client \(output.client.clientId)
        bearer token: \(output.bearerToken)

        """
      }
    case "list":
      let clients = try noteService.listAPIClients(includeRevoked: parsed.includeRevoked)
      return try render(clients, output: options.output) { clients in
        clients.map { client in
          let state = client.revokedAt == nil ? "active" : "revoked"
          return "\(client.clientId) \(state) \(client.displayName)"
        }.joined(separator: "\n") + (clients.isEmpty ? "" : "\n")
      }
    case "revoke":
      guard let clientId = parsed.firstPositional else {
        throw CLIUsageError("note client revoke requires a client id")
      }
      let revoked = try noteService.revokeAPIClient(clientId: clientId)
      return try render(revoked, output: options.output) { client in
        "revoked client \(client.clientId)\n"
      }
    default:
      throw CLIUsageError("unsupported note client subcommand '\(options.target ?? "")'")
    }
  }

  private func registerClient(
    displayName: String,
    noteService: NoteService,
    noteRoot: String,
    direct: Bool
  ) async throws -> NoteClientRegistrationOutput {
    if direct {
      let token = try makeNoteAPIBearerToken()
      let client = try noteService.registerAPIClient(displayName: displayName, bearerToken: token)
      return NoteClientRegistrationOutput(client: client, bearerToken: token, registrationMode: .direct)
    }
    let authenticator = QRClientRegistrationAuthenticator(
      service: noteService,
      registrationScope: URL(fileURLWithPath: noteRoot, isDirectory: true).standardizedFileURL.path
    )
    let challenge = try await authenticator.createRegistrationChallenge(publicBaseURL: "http://127.0.0.1:8787")
    let credential = try await authenticator.redeemRegistrationCode(
      code: challenge.code,
      displayName: displayName
    )
    guard let client = try noteService.listAPIClients(includeRevoked: true).first(where: {
      $0.clientId == credential.clientId
    }) else {
      throw CLIUsageError("registered note API client was not persisted")
    }
    return NoteClientRegistrationOutput(client: client, bearerToken: credential.bearerToken, registrationMode: .challenge)
  }

  private func renderNoteMutation(
    _ result: GraphQLNoteMutationResult,
    options: CLICommandOptions,
    verb: String
  ) throws -> CLICommandResult {
    try render(result, accepted: result.result.accepted, options: options) { result in
      guard result.result.accepted, let note = result.note else {
        return result.result.diagnostics.joined(separator: "\n") + "\n"
      }
      return "\(verb) note \(note.noteId)\n"
    }
  }

  private func localAttachNoteFile(
    noteId: String,
    fileURL: URL,
    parsed: NoteCommandOptions
  ) -> GraphQLNoteMutationResult {
    do {
      guard let role = NoteFileRole(rawValue: parsed.role) else {
        return GraphQLNoteMutationResult(result: GraphQLControlPlaneResult(
          accepted: false,
          status: "invalid_request",
          diagnostics: ["unsupported note file role: \(parsed.role)"]
        ))
      }
      let attachment = try service(parsed).attachFile(
        noteId: noteId,
        fileURL: fileURL,
        role: role,
        mediaType: parsed.mediaType ?? "application/octet-stream",
        originalFilename: parsed.filename ?? fileURL.lastPathComponent,
        position: parsed.position
      )
      return GraphQLNoteMutationResult(
        result: GraphQLControlPlaneResult(accepted: true, status: "ok"),
        file: GraphQLNoteFileDTO(file: attachment.file)
      )
    } catch {
      return GraphQLNoteMutationResult(result: noteCommandGraphQLResult(for: error))
    }
  }

  private func service(_ options: NoteCommandOptions) throws -> NoteService {
    try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: options.noteRoot),
      autoActionDispatcher: NoteAutoActionWorkflowDispatcher(
        workingDirectory: options.workingDirectory,
        noteRoot: options.noteRoot
      ),
      autoActionDiagnosticRecorder: StderrAutoActionFilterDiagnostics()
    )
  }

  private func graphQLExecutor(_ options: NoteCommandOptions) throws -> NoteGraphQLDocumentExecutor {
    NoteGraphQLDocumentExecutor(
      service: GraphQLNoteGraphQLService(service: try service(options)),
      allowRawS3ProfileInput: true,
      rawS3EnvironmentAllowlist: options.rawS3EnvironmentAllowlist
    )
  }

  private func executeNoteDocument<T: Decodable>(
    field: String,
    query: String,
    variables: JSONObject,
    options: NoteCommandOptions
  ) async throws -> T {
    let response = try await graphQLExecutor(options).execute(GraphQLDocumentRequest(
      query: query,
      variables: variables,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    ))
    guard response.handled else {
      throw CLIUsageError("note GraphQL document was not handled: \(field)")
    }
    if let errors = response.body["errors"] {
      throw CLIUsageError("note GraphQL document failed: \(errors)")
    }
    guard
      case let .object(data)? = response.body["data"],
      let payload = data[field],
      payload != .null
    else {
      throw CLIUsageError("note GraphQL document returned no payload for \(field)")
    }
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(payload))
  }

  private func render<T: Encodable>(
    _ value: T,
    output: WorkflowOutputFormat,
    text: (T) -> String
  ) throws -> CLICommandResult {
    switch output {
    case .json, .jsonl:
      return CLICommandResult(exitCode: .success, stdout: try jsonString(value))
    case .text, .table:
      return CLICommandResult(exitCode: .success, stdout: text(value))
    }
  }

  private func render<T: Encodable>(
    _ value: T,
    accepted: Bool = true,
    options: CLICommandOptions,
    text: (T) -> String
  ) throws -> CLICommandResult {
    let rendered = try render(value, output: options.output, text: text)
    return CLICommandResult(exitCode: accepted ? .success : .failure, stdout: rendered.stdout, stderr: rendered.stderr)
  }

  private func failure(_ message: String, output: WorkflowOutputFormat) -> CLICommandResult {
    if output.isStructured {
      let payload = CLIUnsupportedCommandResult(
        scope: "note",
        command: nil,
        target: nil,
        exitCode: CLIExitCode.failure.rawValue,
        error: message
      )
      return CLICommandResult(exitCode: .failure, stdout: (try? jsonString(payload)) ?? "")
    }
    return CLICommandResult(exitCode: .failure, stderr: message)
  }
}
