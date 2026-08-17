import AppCore
import Foundation
import RielaCore

// Kaiba 0.1.7 moved JSONValue/JSONObject out of AppGraphQL and into AppCore, so
// every kaiba addon file that imports AppCore next to RielaCore now sees two
// equally visible JSON models and an unqualified `JSONValue` is ambiguous.
// Declaring the alias in this module pins every unqualified spelling in
// RielaCLI to riela's own model, and the kaiba side is spelled `AppCore.JSON*`
// at the few boundaries that genuinely hand one over.
// Public because RielaCLI's own public API (session stores, findings export)
// already spells these types unqualified.
public typealias JSONValue = RielaCore.JSONValue
public typealias JSONObject = RielaCore.JSONObject

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
