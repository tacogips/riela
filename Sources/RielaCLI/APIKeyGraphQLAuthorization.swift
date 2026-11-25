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
      var authorized = request
      authorized.isLocallyTrusted = true
      guard let credential = request.transportCredential else {
        let accepted = try store.authorizeClient(token: nil)
        guard request.isLocallyTrusted || accepted else {
          return failure(code: "UNAUTHENTICATED")
        }
        return await next.execute(authorized)
      }

      guard let record = try credential.validate(using: { try store.authenticate($0, purpose: .client) }) else {
        return failure(code: "UNAUTHENTICATED")
      }
      if record.effectiveScope != .admin {
        guard let roots = try? request.authorizationRootFields(), !roots.isEmpty else {
          return failure(code: "scope_insufficient", message: "The credential cannot authorize this GraphQL document")
        }
        if let field = RielaAPIScopePolicy.violation(scope: record.effectiveScope, roots: roots) {
          return failure(code: "scope_insufficient", message: "The credential cannot access \(field)")
        }
      }
      try store.touch(id: record.id, now: Date())
      let grant = BotsRequestGrant(targetsLocalByDefault: record.pairing != nil) {
        (try? credential.validate { try store.authenticate($0, purpose: .client) != nil }) == true
      }
      return await BotsRequestGrant.$current.withValue(grant) {
        await next.execute(authorized)
      }
    } catch {
      return failure(code: "AUTH_UNAVAILABLE")
    }
  }

  private func failure(
    code: String, message: String = "API key authentication failed"
  ) -> GraphQLDocumentExecutionResponse {
    GraphQLDocumentExecutionResponse(handled: true, body: [
      "data": .null,
      "errors": .array([.object([
        "message": .string(message),
        "extensions": .object(["code": .string(code)])
      ])])
    ])
  }
}

func serverAPIKeyStore(homeDirectory: URL) -> RielaAPIKeyStore {
  RielaAPIKeyStore(root: RielaAppProfileStore.defaultAppRootURL(homeDirectory: homeDirectory)
    .appendingPathComponent("api-auth", isDirectory: true))
}
