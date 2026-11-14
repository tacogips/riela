import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let recordManifestRegistration = BuiltinAddonHandlerRegistration(name: "riela/record-manifest", bindsCLIVariablesAsInputs: false) { resolver, input, _ in
    try resolver.executeRecordManifest(input)
  }

  func executeRecordManifest(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys) == ["action", "value"], let action = nonEmptyString(config["action"]),
      case let .object(value)? = config["value"] else {
      throw AdapterExecutionError(.invalidInput, "invalid record-manifest configuration")
    }
    let payload: JSONObject
    do { payload = try RecordManifest.execute(action: action, value: value) } catch {
      throw AdapterExecutionError(.invalidInput, "invalid record-manifest metadata or recovery partition")
    }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true,
      payload: payload)
  }
}
