import Foundation

public enum RielaWorkflowEventRegistration {
  public static func register(
    candidate: RielaAppDaemonWorkflowCandidate, sourceJSON: String, bindingJSON: String
  ) throws -> String {
    let sourceObject = try parseEventJSONObject(sourceJSON, label: "source")
    let bindingObject = try parseEventJSONObject(bindingJSON, label: "binding")
    let sourceId = try requiredEventString("id", in: sourceObject, label: "source")
    let sourceKind = try requiredEventString("kind", in: sourceObject, label: "source")
    guard RielaAppDaemonWorkflowDiscovery.isDaemonSourceKind(sourceKind) else {
      throw registrationError("Event source kind \(sourceKind) is not supported by the daemon listener")
    }
    let bindingSourceId = try requiredEventString("sourceId", in: bindingObject, label: "binding")
    guard bindingSourceId == sourceId else {
      throw registrationError("Binding sourceId must match source id \(sourceId)")
    }
    let workflowName = try requiredEventString("workflowName", in: bindingObject, label: "binding")
    guard workflowName == candidate.workflowId else {
      throw registrationError("Binding workflowName must be \(candidate.workflowId)")
    }
    let bindingId = try requiredEventString("id", in: bindingObject, label: "binding")
    let eventRoot = eventRootURL(for: candidate)
    let sourceDirectory = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindingDirectory = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindingDirectory, withIntermediateDirectories: true)
    try prettyEventJSONData(sourceObject).write(
      to: sourceDirectory.appendingPathComponent("\(sanitizedEventFileName(sourceId)).json"),
      options: .atomic
    )
    try prettyEventJSONData(bindingObject).write(
      to: bindingDirectory.appendingPathComponent("\(sanitizedEventFileName(bindingId)).json"),
      options: .atomic
    )
    return sourceId
  }

  private static func registrationError(_ message: String) -> NSError {
    NSError(domain: "Riela", code: 11, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private static func eventRootURL(for candidate: RielaAppDaemonWorkflowCandidate) -> URL {
    if let eventRoot = candidate.eventRoot, !eventRoot.isEmpty {
      return URL(fileURLWithPath: eventRoot, isDirectory: true)
    }
    return URL(fileURLWithPath: candidate.workflowDirectory, isDirectory: true)
      .appendingPathComponent(".riela-events", isDirectory: true)
  }

  private static func parseEventJSONObject(_ text: String, label: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    let value = try JSONSerialization.jsonObject(with: data)
    guard let object = value as? [String: Any] else {
      throw NSError(
        domain: "RielaApp",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: "\(label) JSON must be an object"]
      )
    }
    return object
  }

  private static func requiredEventString(_ key: String, in object: [String: Any], label: String) throws -> String {
    guard let value = object[key] as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw NSError(
        domain: "RielaApp",
        code: 11,
        userInfo: [NSLocalizedDescriptionKey: "\(label).\(key) is required"]
      )
    }
    return value
  }

  private static func prettyEventJSONData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  }

  private static func sanitizedEventFileName(_ rawValue: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    let mapped = rawValue.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let sanitized = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_ :"))
    return sanitized.isEmpty ? "event-source" : sanitized
  }
}
