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
    let (body, httpStatus) = try await executeRemoteKaibaGraphQL(
      endpoint: endpoint,
      apiKey: remoteKaibaAPIKey(context),
      query: query,
      variables: variables,
      operationName: context.string("operationName")
    )
    responseBody = body
    handled = true
    status = httpStatus
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

private func executeRemoteKaibaGraphQL(
  endpoint: String,
  apiKey: String?,
  query: String,
  variables: RielaCore.JSONObject,
  operationName: String?
) async throws -> (RielaCore.JSONObject, Int) {
  guard let base = URL(string: endpoint), base.scheme != nil else {
    throw noteAddonInvalidInput("kaiba endpoint must be an absolute URL, got: \(endpoint)")
  }
  let url = base.appendingPathComponent("graphql")
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  if let apiKey {
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
  }
  var envelope: RielaCore.JSONObject = ["query": .string(query), "variables": .object(variables)]
  if let operationName {
    envelope["operationName"] = .string(operationName)
  }
  request.httpBody = try JSONEncoder().encode(RielaCore.JSONValue.object(envelope))
  let (data, urlResponse) = try await URLSession.shared.data(for: request)
  let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
  guard let value = try? JSONDecoder().decode(RielaCore.JSONValue.self, from: data),
    case let .object(body) = value else {
    throw noteAddonInvalidInput("kaiba endpoint returned a non-JSON response (status \(statusCode))")
  }
  guard (200...299).contains(statusCode) else {
    let message: String
    if case let .string(error)? = body["error"] {
      message = error
    } else {
      message = "status \(statusCode)"
    }
    throw noteAddonInvalidInput("kaiba endpoint rejected the document: \(message)")
  }
  return (body, statusCode)
}
