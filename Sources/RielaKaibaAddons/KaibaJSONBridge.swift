import AppCore
import Foundation
import RielaCore

// Kaiba exports its own JSONValue/JSONObject from AppCore, so inside this
// target — the only one importing both models — an unqualified `JSONValue`
// would be ambiguous. The alias pins every unqualified spelling to riela's own
// model, and the kaiba side is spelled `AppCore.JSON*` at the few boundaries
// that genuinely hand one over. The aliases stay internal: the catalog's public
// API speaks RielaCore types by their own names.
typealias JSONValue = RielaCore.JSONValue
typealias JSONObject = RielaCore.JSONObject

/// Re-encodes a riela JSON payload as kaiba's structurally identical model.
func kaibaJSONValue(_ value: RielaCore.JSONValue) throws -> AppCore.JSONValue {
  try JSONDecoder().decode(AppCore.JSONValue.self, from: JSONEncoder().encode(value))
}

/// Re-encodes a riela JSON object as kaiba's structurally identical model.
func kaibaJSONObject(_ object: RielaCore.JSONObject) throws -> AppCore.JSONObject {
  try JSONDecoder().decode(AppCore.JSONObject.self, from: JSONEncoder().encode(object))
}

/// Re-encodes a kaiba JSON payload as riela's structurally identical model.
func rielaJSONValue(_ value: AppCore.JSONValue) throws -> RielaCore.JSONValue {
  try JSONDecoder().decode(RielaCore.JSONValue.self, from: JSONEncoder().encode(value))
}

/// Re-encodes a kaiba JSON object as riela's structurally identical model.
func rielaJSONObject(_ object: AppCore.JSONObject) throws -> RielaCore.JSONObject {
  try JSONDecoder().decode(RielaCore.JSONObject.self, from: JSONEncoder().encode(object))
}
