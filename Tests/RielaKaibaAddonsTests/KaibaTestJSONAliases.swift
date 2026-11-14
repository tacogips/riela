import RielaAddonSupport
import RielaCore

// Kaiba 0.1.7 exports its own JSONValue/JSONObject from AppCore, so the kaiba
// addon tests that import both modules would otherwise see an ambiguous
// unqualified spelling. Mirrors `KaibaJSONBridge` on the RielaCLI side.
typealias JSONValue = RielaCore.JSONValue
typealias JSONObject = RielaCore.JSONObject
