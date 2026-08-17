import Foundation
import RielaAddonSupport
import RielaCore
import RielaWorkflowRegistry

// Environment plumbing for add-on execution: reading a process variable and
// resolving an `addon.env` binding block. Kept in RielaCLI because it reaches
// for the CLI's runtime environment; the template/JSON helpers add-on targets
// share live in RielaAddonSupport.
func environmentValue(
  _ key: String,
  environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment()
) -> String? {
  guard let value = environment[key], !value.isEmpty else { return nil }
  return value
}

func resolveAddonEnvironment(
  _ env: JSONObject?,
  runtimeEnvironment: [String: String]
) throws -> [String: String] {
  guard let env else { return [:] }
  var resolved: [String: String] = [:]
  for (targetName, bindingValue) in env {
    guard case let .object(binding) = bindingValue else {
      throw AdapterExecutionError(.policyBlocked, "addon.env.\(targetName) must be an object")
    }
    guard let sourceName = nonEmptyString(binding["fromEnv"]) else {
      throw AdapterExecutionError(.policyBlocked, "addon.env.\(targetName).fromEnv is required")
    }
    let required = boolValue(binding["required"]) ?? true
    guard let value = runtimeEnvironment[sourceName], !value.isEmpty else {
      if required {
        throw AdapterExecutionError(
          .policyBlocked,
          "required environment variable '\(sourceName)' is unavailable for addon.env.\(targetName)"
        )
      }
      continue
    }
    resolved[targetName] = value
  }
  return resolved
}

func resolveAddonEnvironmentOverlay(
  _ env: JSONObject?,
  runtimeEnvironment: [String: String]
) throws -> [String: String] {
  var resolved = runtimeEnvironment
  guard let env else { return resolved }
  for (targetName, bindingValue) in env {
    guard case let .object(binding) = bindingValue else {
      throw AdapterExecutionError(.policyBlocked, "addon.env.\(targetName) must be an object")
    }
    guard let sourceName = nonEmptyString(binding["fromEnv"]) else {
      throw AdapterExecutionError(.policyBlocked, "addon.env.\(targetName).fromEnv is required")
    }
    let required = boolValue(binding["required"]) ?? true
    guard let value = runtimeEnvironment[sourceName], !value.isEmpty else {
      if required {
        throw AdapterExecutionError(
          .policyBlocked,
          "required environment variable '\(sourceName)' is unavailable for addon.env.\(targetName)"
        )
      }
      resolved.removeValue(forKey: targetName)
      continue
    }
    resolved[targetName] = value
  }
  return resolved
}

