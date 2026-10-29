import Foundation

extension WorkflowExecutionSandbox {
  /// Lossless projection for persisted workflow instance and run overrides.
  var jsonObject: JSONObject {
    var object: JSONObject = [
      "backend": .string(backend.rawValue), "networkPolicy": .string(networkPolicy.rawValue),
      "readPaths": .array(readPaths.map(JSONValue.string)),
      "writePaths": .array(writePaths.map(JSONValue.string)),
      "credentialPaths": .array(credentialPaths.map(JSONValue.string)),
      "environment": .array(environment.map(JSONValue.string)),
      "credentials": .array(credentials.map { .object(["source": .string($0.source), "homePath": .string($0.homePath)]) })
    ]
    if ephemeralHome { object["ephemeralHome"] = .bool(true) }
    if !credentialEnvironment.isEmpty { object["credentialEnvironment"] = .object(credentialEnvironment.mapValues(JSONValue.string)) }
    if let admission {
      object["admission"] = .object([
        "directoryEnvironment": .string(admission.directoryEnvironment),
        "capacity": .integer(Int64(admission.capacity)), "weight": .integer(Int64(admission.weight)),
        "waitTimeoutSeconds": .integer(Int64(admission.waitTimeoutSeconds)),
        "minimumRemainingSeconds": .integer(Int64(admission.minimumRemainingSeconds))
      ])
    }
    if let container {
      var containerObject: JSONObject = [
        "runtime": .string(container.runtime.rawValue),
        "networkPolicy": .string(container.networkPolicy.rawValue),
        "mounts": .array(container.mounts.map { .object([
          "source": .string($0.source), "target": .string($0.target), "readOnly": .bool($0.readOnly)
        ]) })
      ]
      containerObject["image"] = .string(container.image)
      object["container"] = .object(containerObject)
    }
    return object
  }
}
