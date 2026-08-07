import Foundation

/// Error surface shared by the GraphQL document parsing layer. The parsing
/// files retain their historical Note-prefixed names because the parser was
/// born in the note domain; the note executor itself now lives in kaiba.
enum NoteGraphQLDocumentExecutorError: Error, Equatable {
  case missingVariable(String)
  case invalidVariable(String)
  case invalidSelection(String)
  case operationFieldMismatch(operation: String, fieldName: String)
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
