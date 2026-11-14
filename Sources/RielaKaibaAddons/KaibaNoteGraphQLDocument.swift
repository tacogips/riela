import Foundation
import RielaCore

/// The first-party client exposes decoded `data`, never a raw HTTP envelope.
/// Reconstruct the legacy compatibility envelope deterministically for both
/// registered GraphQL names.
func kaibaGraphQLDocumentPayload(
  responseData: RielaCore.JSONValue,
  resolvedInputPayload: RielaCore.JSONObject
) -> RielaCore.JSONObject {
  let safeResponseData = kaibaSafeGraphQLValue(responseData)
  var payload: RielaCore.JSONObject = [
    "handled": .bool(true),
    "statusCode": .number(200),
    "body": .object(["data": safeResponseData])
  ]
  for (key, value) in resolvedInputPayload
    where payload[key] == nil && key != "runtime" && key != "upstream" {
    payload[key] = value
  }
  guard case let .object(data) = safeResponseData, data.count == 1, let field = data.keys.first else {
    return payload
  }
  payload["fieldName"] = .string(field)
  let fieldValue = data[field] ?? .null
  payload["fieldPayload"] = fieldValue
  if case let .object(fieldPayload) = fieldValue {
    for (key, value) in fieldPayload {
      payload[key] = value
    }
  }
  return payload
}

private let kaibaUnsafeGraphQLPayloadKeys: Set<String> = [
  "authorization", "databasepath", "diagnostics", "localpath", "noteroot", "token"
]

private func kaibaSafeGraphQLValue(_ value: RielaCore.JSONValue) -> RielaCore.JSONValue {
  switch value {
  case let .array(values):
    return .array(values.map(kaibaSafeGraphQLValue))
  case let .object(values):
    return .object(values.reduce(into: [:]) { result, entry in
      guard !kaibaUnsafeGraphQLPayloadKeys.contains(entry.key.lowercased()) else { return }
      result[entry.key] = kaibaSafeGraphQLValue(entry.value)
    })
  default:
    return value
  }
}
