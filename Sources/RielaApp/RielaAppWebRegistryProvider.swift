#if os(macOS)
import Foundation
import RielaCore
import RielaGraphQL

struct RielaAppWebRegistryAuthorizer: WorkflowRegistryGraphQLAuthorizing {
  static let internalCredential = "riela-app-validated-local-web-request"
  static let principalId = "riela-app-local-web"

  func authorize(bearerCredential: String?) async throws -> WorkflowRegistryVerifiedPrincipal {
    guard bearerCredential == Self.internalCredential else {
      throw WorkflowRegistryError(code: .unauthenticated, message: "invalid local web provenance")
    }
    return WorkflowRegistryVerifiedPrincipal(
      principalId: Self.principalId,
      capabilities: [.readRegistry, .mutateRegistry]
    )
  }
}

struct RielaAppWebManagedReferenceResolver: WorkflowRegistryManagedReferenceResolver {
  func resolveManagedReference(_ reference: String) async throws -> URL {
    throw WorkflowRegistryError(
      code: .unsupportedBundleReference,
      message: "managed bundle references are unavailable from the web"
    )
  }
}
#endif
