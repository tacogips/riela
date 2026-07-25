#if os(macOS)
import Foundation
import RielaCore
import RielaGraphQL
import RielaNote
import RielaServer

private struct RielaAppGraphQLExecutor: GraphQLDocumentExecuting {
  let noteExecutor: NoteGraphQLDocumentExecutor

  func execute(_ request: GraphQLDocumentRequest) async -> GraphQLDocumentExecutionResponse {
    let noteResponse = await noteExecutor.execute(request)
    guard !noteResponse.handled else {
      return noteResponse
    }
    return GraphQLDocumentExecutionResponse(
      handled: true,
      body: [
        "graphql": .object([
          "delegated": .bool(true),
          "query": .string(request.query),
          "variables": .object(request.variables),
          "operationName": request.operationName.map(JSONValue.string) ?? .null,
          "schema": .string(GraphQLContractProjector.schemaContract)
        ])
      ]
    )
  }
}

extension RielaApp {
  func webNoteGraphQLResponse(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    do {
      let profileName = daemonProfileName
      let root = noteRootURL(profileName: profileName)
      let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
      let executor = RielaAppGraphQLExecutor(
        noteExecutor: NoteGraphQLDocumentExecutor(
          service: GraphQLNoteGraphQLService(service: service)
        )
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
}
#endif
