import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeJSONRoute(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["value", "cases", "payload"]),
      case let .string(value)? = config["value"],
      case let .array(rawCases)? = config["cases"], (1...32).contains(rawCases.count),
      case let .object(payload)? = config["payload"]
    else { throw AdapterExecutionError(.invalidInput, "invalid json-route configuration") }
    let cases = try rawCases.map { item -> String in
      guard case let .string(name) = item,
        name.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression) != nil else {
        throw AdapterExecutionError(.invalidInput, "invalid json-route case")
      }
      return name
    }
    guard Set(cases).count == cases.count, cases.contains(value),
      !(payload["when"] != nil && payload["payload"] != nil),
      try JSONEncoder().encode(payload).count <= 8_000_000 else {
      throw AdapterExecutionError(.invalidInput, "json-route value is outside its declared cases or payload limit")
    }
    return AdapterExecutionOutput(provider: "riela-builtin-addon", model: input.addon.name,
      promptText: "", completionPassed: true, when: [value: true], payload: payload)
  }
}
