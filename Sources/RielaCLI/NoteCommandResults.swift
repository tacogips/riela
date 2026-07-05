import Foundation
import RielaGraphQL
import RielaNote

struct NoteTagCommandResult: Encodable {
  var applied: [GraphQLNoteMutationResult]
  var removed: [GraphQLNoteMutationResult]

  var accepted: Bool {
    firstRejected == nil
  }

  var firstRejected: GraphQLNoteMutationResult? {
    (applied + removed).first { !$0.result.accepted }
  }
}

func noteCommandGraphQLResult(for error: Error) -> GraphQLControlPlaneResult {
  switch error {
  case NoteServiceError.notFound:
    return .init(accepted: false, status: "not_found", diagnostics: [String(describing: error)])
  case NoteServiceError.readOnly, NoteServiceError.protectedTag:
    return .init(accepted: false, status: "rejected", diagnostics: [String(describing: error)])
  case NoteServiceError.invalidInput:
    return .init(accepted: false, status: "invalid_request", diagnostics: [String(describing: error)])
  default:
    return .init(accepted: false, status: "error", diagnostics: [String(describing: error)])
  }
}
