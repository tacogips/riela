#if os(macOS)
import Foundation
import RielaWorkflowRegistry
import RielaCore
import RielaGraphQL
import RielaNote
import RielaServer

private struct RielaAppGraphQLExecutor: GraphQLDocumentExecuting {
  let executor: CompositeGraphQLDocumentExecutor
  let registryWorkingDirectory: String

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    var trustedRequest = request
    trustedRequest.transportCredential = GraphQLTransportCredential(
      RielaAppWebRegistryAuthorizer.internalCredential
    )
    trustedRequest.localWorkingDirectory = registryWorkingDirectory
    return await executor.execute(trustedRequest)
  }
}

extension RielaApp {
  func webNoteGraphQLResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    guard request.headers["x-riela-profile"] == daemonProfileName.rawValue else {
      return webGraphQLProfileConflictResponse()
    }
    do {
      let profileName = daemonProfileName
      let root = noteRootURL(profileName: profileName)
      let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
      let executor = RielaAppGraphQLExecutor(
        executor: CompositeGraphQLDocumentExecutor(
          workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(
            configuration: WorkflowRegistryGraphQLServerConfig(
              provider: FileWorkflowRegistryGraphQLProvider(
                workingDirectory: NSHomeDirectory(),
                webPrincipalId: RielaAppWebRegistryAuthorizer.principalId
              ),
              authorizer: RielaAppWebRegistryAuthorizer(),
              managedReferenceResolver: RielaAppWebManagedReferenceResolver()
            )
          ),
          fallback: NoteGraphQLDocumentExecutor(
            service: GraphQLNoteGraphQLService(service: service)
          )
        ),
        registryWorkingDirectory: NSHomeDirectory()
      )
      return await DeterministicServerHTTPAdapter(
        routeHandler: DeterministicServerRouteHandler(
          graphQLExecutor: executor,
          allowUnauthenticatedNoteAPI: true
        ),
        context: ServerRequestContext(serviceName: "riela-app")
      ).response(for: request)
    } catch {
      return .json(status: 503, .object([
        "error": .string("note_graphql_unavailable"),
        "message": .string("The active profile's Notes service is unavailable.")
      ]))
    }
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
