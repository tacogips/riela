import Foundation
import RielaAppSupport
import RielaGraphQL
import RielaServer

/// Uniform authentication for every native GraphQL root, before local trust is granted.
struct APIKeyGraphQLAuthorization: GraphQLDocumentExecuting {
  let store: RielaAPIKeyStore
  let next: any GraphQLDocumentExecuting

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    do {
      let accepted = try request.transportCredential.map { credential in
        try credential.validate { try store.authorizeClient(token: $0) }
      } ?? store.authorizeClient(token: nil)
      guard request.isLocallyTrusted || accepted else {
        return failure(code: "UNAUTHENTICATED")
      }
      var authorized = request
      authorized.isLocallyTrusted = true
      return await next.execute(authorized)
    } catch {
      return failure(code: "AUTH_UNAVAILABLE")
    }
  }

  private func failure(code: String) -> GraphQLDocumentExecutionResponse {
    GraphQLDocumentExecutionResponse(handled: true, body: [
      "data": .null,
      "errors": .array([.object([
        "message": .string("API key authentication failed"),
        "extensions": .object(["code": .string(code)])
      ])])
    ])
  }
}

func serverAPIKeyStore(homeDirectory: URL) -> RielaAPIKeyStore {
  RielaAPIKeyStore(root: RielaAppProfileStore.defaultAppRootURL(homeDirectory: homeDirectory)
    .appendingPathComponent("api-auth", isDirectory: true))
}
