import Foundation
import RielaCore
import RielaGraphQL
import RielaServer

extension ScopedParityCommandRunner {
  func serverResponse(options: CLICommandOptions, parsed: ParsedParityOptions) async throws -> ServerResponseDescriptor {
    if parsed.noteAPIEnabled {
      return try await noteAPIServeResponse(parsed: parsed)
    }
    let action = options.command ?? "status"
    let handler = DeterministicServerRouteHandler()
    switch action {
    case "status", "health":
      return await handler.route(
        ServerRequestEnvelope(method: "GET", path: "/healthz"),
        context: serverContext(parsed: parsed)
      )
    case "overview":
      return await handler.route(
        ServerRequestEnvelope(method: "GET", path: "/overview"),
        context: serverContext(parsed: parsed)
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
        context: serverContext(parsed: parsed)
      )
    default:
      let route = options.target ?? action
      return await DeterministicServerRouteHandler().route(
        ServerRequestEnvelope(method: "GET", path: route.hasPrefix("/") ? route : "/\(route)"),
        context: serverContext(parsed: parsed)
      )
    }
  }

  private func noteAPIServeResponse(parsed: ParsedParityOptions) async throws -> ServerResponseDescriptor {
    let noteRoot = resolvedNoteRoot(parsed: parsed)
    let server = RielaServerConfiguration(
      host: parsed.host ?? "127.0.0.1",
      port: parsed.port ?? 8787,
      noteAPIEnabled: true,
      noteRoot: noteRoot
    )
    let listener = try await InProcessWorkflowServeListenerFactory().startListener(
      for: WorkflowServeResolvedWorkflow(workflowId: "note-api", selectedIdentity: "note-api"),
      request: WorkflowServeStartRequest(selection: .scopedName("note-api"), server: server),
      generationId: "cli-note-api"
    )
    guard let inProcessListener = listener as? InProcessWorkflowServeListenerHandle else {
      throw CLIUsageError("serve --note-api requires the in-process serve listener")
    }
    guard let challenge = inProcessListener.registrationChallenge else {
      return ServerResponseDescriptor(status: 503, body: [
        "error": .string("note API registration challenge is not available")
      ])
    }
    return ServerResponseDescriptor(status: 200, body: [
      "endpoint": .string(listener.endpoint),
      "noteRoot": .string(noteRoot),
      "registration": try encodedJSONValue(challenge)
    ])
  }

  private func resolvedNoteRoot(parsed: ParsedParityOptions) -> String {
    let raw = parsed.noteRoot
      ?? CLIRuntimeEnvironment.mergedProcessEnvironment()["RIELA_NOTE_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
      ?? "\(NSHomeDirectory())/.riela/note"
    return (raw as NSString).expandingTildeInPath
  }

  private func serverContext(parsed: ParsedParityOptions) -> ServerRequestContext {
    ServerRequestContext(inheritedEnvironment: parsed.sessionStore.map { ["RIELA_MANAGER_SESSION_ID": $0] } ?? [:])
  }
}

private func encodedJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
