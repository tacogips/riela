import Foundation
import RielaCore
import RielaGraphQL

// `riela graphql execute|document` — executes GraphQL documents against the
// workflow-registry executor. The note GraphQL domain moved to the kaiba
// package (`kaiba graphql` / the kaiba/note-graphql-document addon).
extension ScopedParityCommandRunner {
  func graphQLDocumentRecord(
    options: CLICommandOptions,
    parsed: ParsedParityOptions,
    action: String
  ) async throws -> String {
    let query = try graphQLDocumentQuery(parsed: parsed, action: action)
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let variables = try parsed.variables.map {
      try JSONReferenceLoader().object(from: $0, workingDirectory: workingDirectory)
    } ?? [:]
    let executor = WorkflowRegistryGraphQLDocumentExecutor(
      localProvider: FileWorkflowRegistryGraphQLProvider(workingDirectory: workingDirectory)
    )
    let response = await executor.execute(GraphQLDocumentRequest(
      query: query,
      variables: variables,
      operationName: parsed.graphQLOperationName,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment(),
      isLocallyTrusted: true,
      localWorkingDirectory: workingDirectory
    ))
    guard response.handled else {
      throw CLIUsageError("graphql \(action) document was not handled by the workflow-registry executor")
    }
    return try jsonString(response.body)
  }

  private func graphQLDocumentQuery(parsed: ParsedParityOptions, action: String) throws -> String {
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
