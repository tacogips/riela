import AppCore
import AppGraphQL
import Foundation
import RielaAddonSupport
import RielaCore

// `kaiba/note-graphql-document` runs a note GraphQL document against the local
// store through kaiba's library API. Talking to a running `kaiba serve` is a
// different node — `kaiba/note-graphql-remote` — because that surface is
// authenticated and library-scoped by kaiba, and it opens no local store.

func executeNoteGraphQLDocument(_ context: NoteAddonContext) async throws -> RielaCore.JSONObject {
  if context.string("endpoint") != nil {
    throw noteAddonInvalidInput(
      "\(context.input.addon.name) runs against the local note root; use \(KaibaRemoteGraphQLAddon.addonName) for a kaiba serve endpoint"
    )
  }
  let query = try context.requiredString("query", "document", fieldName: "query")
  let executor = NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: context.service))
  let response = await executor.execute(GraphQLDocumentRequest(
    query: query,
    variables: try kaibaJSONObject(noteGraphQLVariables(context)),
    operationName: context.string("operationName")
  ))
  return try kaibaGraphQLDocumentPayload(
    addonName: context.input.addon.name,
    responseBody: try rielaJSONObject(response.body),
    handled: response.handled,
    status: response.status,
    resolvedInputPayload: context.input.resolvedInputPayload
  )
}

/// Shared response projection: both GraphQL nodes surface the raw body plus a
/// flattened single-field payload, so a downstream node can read
/// `fieldPayload`/`value` without knowing which surface answered.
func kaibaGraphQLDocumentPayload(
  addonName: String,
  responseBody: RielaCore.JSONObject,
  handled: Bool,
  status: Int,
  resolvedInputPayload: RielaCore.JSONObject
) throws -> RielaCore.JSONObject {
  guard handled else {
    throw noteAddonInvalidInput("\(addonName) document was not handled")
  }
  if let errors = responseBody["errors"] {
    throw noteAddonInvalidInput("\(addonName) document failed: \(errors)")
  }
  guard (200...299).contains(status) else {
    throw noteAddonInvalidInput("\(addonName) endpoint returned status \(status)")
  }
  var payload: RielaCore.JSONObject = [
    "handled": .bool(handled),
    "statusCode": .number(Double(status)),
    "body": .object(responseBody)
  ]
  for (key, value) in resolvedInputPayload
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
