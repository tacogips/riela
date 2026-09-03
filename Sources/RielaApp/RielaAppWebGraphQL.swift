#if os(macOS)
import Foundation
import RielaCore
import RielaGraphQL
import RielaServer
import RielaWorkflowRegistry

// Workflow-registry GraphQL for the web dashboard. The note GraphQL surface
// that used to share this route moved to the kaiba package.
private struct RielaAppGraphQLExecutor: GraphQLDocumentExecuting {
  let executor: CompositeGraphQLDocumentExecutor
  let registryWorkingDirectory: String

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    var trustedRequest = request
    trustedRequest.transportCredential = GraphQLTransportCredential(
      RielaAppWebRegistryAuthorizer.internalCredential
    )
    trustedRequest.isLocallyTrusted = true
    trustedRequest.localWorkingDirectory = registryWorkingDirectory
    return await executor.execute(trustedRequest)
  }
}

extension RielaApp {
  func webGraphQLResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    guard request.headers["x-riela-profile"] == daemonProfileName.rawValue else {
      return webGraphQLProfileConflictResponse()
    }
    let executor = RielaAppGraphQLExecutor(
      executor: CompositeGraphQLDocumentExecutor(
        workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(
          localProvider: FileWorkflowRegistryGraphQLProvider(
            workingDirectory: appHomeDirectory.path,
            webPrincipalId: RielaAppWebRegistryAuthorizer.principalId
          ),
          localManagedReferenceResolver: RielaAppWebManagedReferenceResolver()
        ),
        fallback: RoutineAwareGraphQLFallbackExecutor(
          routine: RoutineGraphQLDocumentExecutor(
            provider: FileRoutineGraphQLProvider(workingDirectory: appHomeDirectory.path)
          ),
          next: RielaConfigGraphQLDocumentExecutor(
            provider: RielaAppConfigurationGraphQLProvider(app: self)
          )
        )
      ),
      registryWorkingDirectory: appHomeDirectory.path
    )
    return await DeterministicServerHTTPAdapter(
      routeHandler: DeterministicServerRouteHandler(graphQLExecutor: executor),
      context: ServerRequestContext(serviceName: "riela-app")
    ).response(for: request)
  }

  private func webGraphQLProfileConflictResponse() -> RielaHTTPResponse {
    let message = "The active profile changed after this view was loaded"
    return .json(status: 409, .object([
      "error": .string("profile_conflict"),
      "errors": .array([.object([
        "message": .string(message),
        "extensions": .object(["code": .string("PROFILE_CONFLICT")])
      ])])
    ]))
  }
}
#endif
