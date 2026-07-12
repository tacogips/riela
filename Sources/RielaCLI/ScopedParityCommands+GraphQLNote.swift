import Foundation
import RielaCore
import RielaGraphQL
import RielaNote
import RielaNoteDispatch

extension ScopedParityCommandRunner {
  func noteGraphQLDocumentRecord(
    options: CLICommandOptions,
    parsed: ParsedParityOptions,
    action: String
  ) async throws -> String {
    let query = try noteGraphQLQuery(parsed: parsed, action: action)
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let variables = try parsed.variables.map {
      try JSONReferenceLoader().object(from: $0, workingDirectory: workingDirectory)
    } ?? [:]
    let noteRoot = parsed.noteRoot
      ?? CLIRuntimeEnvironment.mergedProcessEnvironment()["RIELA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "\(NSHomeDirectory())/.riela/note"
    let expandedNoteRoot = (noteRoot as NSString).expandingTildeInPath
    let noteService = try NoteService(
      driver: SQLiteNoteDatabaseDriver(noteRoot: expandedNoteRoot),
      autoActionDispatcher: NoteAutoActionWorkflowDispatcher(
        launcher: NoteAutoActionWorkflowCLILauncher(
          workingDirectory: workingDirectory,
          noteRoot: expandedNoteRoot
        )
      ),
      autoActionDiagnosticRecorder: StderrAutoActionFilterDiagnostics()
    )
    let executor = NoteGraphQLDocumentExecutor(
      service: GraphQLNoteGraphQLService(service: noteService),
      allowRawS3ProfileInput: true
    )
    let response = await executor.execute(GraphQLDocumentRequest(
      query: query,
      variables: variables,
      operationName: parsed.graphQLOperationName,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    ))
    guard response.handled else {
      throw CLIUsageError("graphql \(action) document was not handled by the note executor")
    }
    return try jsonString(response.body)
  }

  private func noteGraphQLQuery(parsed: ParsedParityOptions, action: String) throws -> String {
    if parsed.graphQLQuery != nil && parsed.graphQLQueryFile != nil {
      throw CLIUsageError("graphql \(action) accepts only one of --query or --query-file")
    }
    if let query = parsed.graphQLQuery {
      return query
    }
    if let queryFile = parsed.graphQLQueryFile {
      let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
      let url = absoluteURL(queryFile, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
      return try String(contentsOf: url, encoding: .utf8)
    }
    throw CLIUsageError("graphql \(action) requires --query or --query-file")
  }
}
