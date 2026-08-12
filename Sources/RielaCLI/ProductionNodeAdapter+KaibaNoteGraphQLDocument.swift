import AppCore
import AppGraphQL
import Foundation
import RielaCore

// The only kaiba addon code that touches AppGraphQL. Kept in its own file so
// the rest of the addon layer resolves JSONValue/JSONObject to RielaCore
// without ambiguity; RielaCore's JSON model is written fully qualified here.

func executeNoteGraphQLDocument(_ context: NoteAddonContext) async throws -> RielaCore.JSONObject {
  let query = try context.requiredString("query", "document", fieldName: "query")
  let variables = try noteGraphQLVariables(context)
  let responseBody: RielaCore.JSONObject
  let handled: Bool
  let status: Int
  if let endpoint = context.string("endpoint") {
    // Remote mode: execute against a running `kaiba serve` note API using an
    // API key issued by `kaiba client issue` (read from the env var named by
    // `apiKeyEnv`; defaults to KAIBA_API_KEY).
    guard let baseURL = URL(string: endpoint), baseURL.scheme != nil else {
      throw noteAddonInvalidInput("kaiba endpoint must be an absolute URL, got: \(endpoint)")
    }
    let client = GraphQLHTTPDocumentClient(
      endpoint: GraphQLHTTPDocumentClient.endpointURL(from: baseURL),
      bearerToken: try remoteKaibaAPIKey(context)
    )
    let response = await client.execute(GraphQLDocumentRequest(
      query: query,
      variables: try bridgedKaibaJSONObject(variables),
      operationName: context.string("operationName")
    ))
    responseBody = try bridgedRielaJSONObject(response.body)
    handled = response.handled
    status = response.status
  } else {
    let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: context.service))
    let response = await executor.execute(GraphQLDocumentRequest(
      query: query,
      variables: try bridgedKaibaJSONObject(variables),
      operationName: context.string("operationName")
    ))
    responseBody = try bridgedRielaJSONObject(response.body)
    handled = response.handled
    status = response.status
  }
  guard handled else {
    throw noteAddonInvalidInput("\(context.input.addon.name) document was not handled")
  }
  if let errors = responseBody["errors"] {
    throw noteAddonInvalidInput("\(context.input.addon.name) document failed: \(errors)")
  }
  guard (200...299).contains(status) else {
    throw noteAddonInvalidInput("\(context.input.addon.name) endpoint returned status \(status)")
  }
  var payload: RielaCore.JSONObject = [
    "handled": .bool(handled),
    "statusCode": .number(Double(status)),
    "body": .object(responseBody)
  ]
  for (key, value) in context.input.resolvedInputPayload
    where payload[key] == nil && key != "runtime" && key != "upstream" {
    payload[key] = value
  }
  let data = noteObject(responseBody["data"])
  if data.count == 1, let field = data.keys.first {
    payload["fieldName"] = .string(field)
    let fieldValue = data[field] ?? .null
    payload["fieldPayload"] = fieldValue
    if case let .object(fieldPayload) = fieldValue {
      for (key, value) in fieldPayload {
        payload[key] = value
      }
    }
  }
  return payload
}

// The RielaCore and AppGraphQL JSON models are structurally identical; bridge
// via their Codable representations at the note GraphQL document boundary.
private func bridgedKaibaJSONObject(_ object: RielaCore.JSONObject) throws -> AppGraphQL.JSONObject {
  try JSONDecoder().decode(AppGraphQL.JSONObject.self, from: JSONEncoder().encode(object))
}

private func bridgedRielaJSONObject(_ object: AppGraphQL.JSONObject) throws -> RielaCore.JSONObject {
  try JSONDecoder().decode(RielaCore.JSONObject.self, from: JSONEncoder().encode(object))
}

private func remoteKaibaAPIKey(_ context: NoteAddonContext) throws -> String? {
  let envName = context.string("apiKeyEnv") ?? "KAIBA_API_KEY"
  if let key = context.environment[envName], !key.isEmpty {
    return key
  }
  guard context.bool("allowUnauthenticated", default: false) else {
    throw noteAddonInvalidInput(
      "kaiba endpoint mode requires the API key env var '\(envName)' (issue one with `kaiba client issue`) or allowUnauthenticated: true"
    )
  }
  return nil
}
