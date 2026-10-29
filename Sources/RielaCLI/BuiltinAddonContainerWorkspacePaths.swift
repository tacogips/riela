import Foundation
import RielaCore

enum BuiltinAddonContainerWorkspacePaths {
  static let guestWorkspaceDirectory = "/workspace"

  private static let pathKeys: Set<String> = [
    "path", "sourcePath", "audioPath", "imagePaths", "outputDir", "downloadDir"
  ]

  static func mapInput(
    _ input: WorkflowAddonExecutionInput,
    from hostRoot: URL,
    to guestRoot: String = guestWorkspaceDirectory
  ) -> WorkflowAddonExecutionInput {
    var mapped = input
    mapped.variables = mapObject(input.variables, from: hostRoot.path, to: guestRoot)
    mapped.resolvedInputPayload = mapObject(input.resolvedInputPayload, from: hostRoot.path, to: guestRoot)
    if let config = input.addon.config {
      mapped.addon.config = mapObject(config, from: hostRoot.path, to: guestRoot)
    }
    if let inputs = input.addon.inputs {
      mapped.addon.inputs = mapObject(inputs, from: hostRoot.path, to: guestRoot)
    }
    return mapped
  }

  static func mapOutput(
    _ output: AdapterExecutionOutput,
    from guestRoot: String = guestWorkspaceDirectory,
    to hostRoot: URL
  ) -> AdapterExecutionOutput {
    var mapped = output
    mapped.payload = mapObject(output.payload, from: guestRoot, to: hostRoot.path)
    return mapped
  }

  private static func mapObject(_ object: JSONObject, from source: String, to destination: String) -> JSONObject {
    Dictionary(uniqueKeysWithValues: object.map { key, value in
      (key, mapValue(value, key: key, from: source, to: destination))
    })
  }

  private static func mapValue(_ value: JSONValue, key: String?, from source: String, to destination: String) -> JSONValue {
    if let key, pathKeys.contains(key) {
      switch value {
      case .string(let path): return .string(mapPath(path, from: source, to: destination))
      case .array(let paths): return .array(paths.map { mapValue($0, key: key, from: source, to: destination) })
      default: break
      }
    }
    switch value {
    case .object(let fields):
      return .object(Dictionary(uniqueKeysWithValues: fields.map { childKey, child in
        (childKey, mapValue(child, key: childKey, from: source, to: destination))
      }))
    case .array(let values):
      return .array(values.map { mapValue($0, key: key, from: source, to: destination) })
    default:
      return value
    }
  }

  private static func mapPath(_ path: String, from source: String, to destination: String) -> String {
    guard path == source || path.hasPrefix(source + "/") else { return path }
    return destination + path.dropFirst(source.count)
  }
}
