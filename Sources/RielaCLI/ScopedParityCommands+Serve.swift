import Foundation
import RielaCore
import RielaGraphQL
import RielaServer

extension ScopedParityCommandRunner {
  func serverResponse(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> ServerResponseDescriptor {
    let action = options.command ?? "status"
    let handler = DeterministicServerRouteHandler()
    switch action {
    case "status", "health":
      return await handler.route(
        ServerRequestEnvelope(method: "GET", path: "/healthz"),
        context: serveRequestContext(parsed: parsed)
      )
    case "overview":
      return await handler.route(
        ServerRequestEnvelope(method: "GET", path: "/overview"),
        context: serveRequestContext(parsed: parsed)
      )
    case "graphql":
      let bodyObject: JSONObject
      if let target = options.target {
        bodyObject = try JSONReferenceLoader().object(
          from: target,
          workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
        )
      } else {
        bodyObject = ["query": .string(GraphQLContractProjector.schemaContract), "variables": .object([:])]
      }
      let body = try JSONEncoder().encode(JSONValue.object(bodyObject))
      return await handler.route(
        ServerRequestEnvelope(method: "POST", path: "/graphql", body: body),
        context: serveRequestContext(parsed: parsed)
      )
    default:
      let route = options.target ?? action
      return await DeterministicServerRouteHandler().route(
        ServerRequestEnvelope(method: "GET", path: route.hasPrefix("/") ? route : "/\(route)"),
        context: serveRequestContext(parsed: parsed)
      )
    }
  }

}
