#if os(macOS)
import Foundation
import RielaAppSupport

extension RielaApp {
  func registerDaemonWorkflowEventSource(identity: String, sourceJSON: String, bindingJSON: String) -> String? {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      return "Instance could not be found"
    }
    do {
      let sourceObject = try parseEventJSONObject(sourceJSON, label: "source")
      let bindingObject = try parseEventJSONObject(bindingJSON, label: "binding")
      let sourceId = try requiredEventString("id", in: sourceObject, label: "source")
      let sourceKind = try requiredEventString("kind", in: sourceObject, label: "source")
      guard RielaAppDaemonWorkflowDiscovery.isDaemonSourceKind(sourceKind) else {
        return "Event source kind \(sourceKind) is not supported by the RielaApp daemon listener"
      }
      let bindingSourceId = try requiredEventString("sourceId", in: bindingObject, label: "binding")
      guard bindingSourceId == sourceId else {
        return "Binding sourceId must match source id \(sourceId)"
      }
      let workflowName = try requiredEventString("workflowName", in: bindingObject, label: "binding")
      guard workflowName == candidate.workflowId else {
        return "Binding workflowName must be \(candidate.workflowId)"
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
      status = "Registered event source \(sourceId) for \(candidate.displayName)"
      refreshDaemonWorkflowWindow()
      restartActiveDaemonWorkflowAfterConfigurationChange(identity: identity, changeDescription: "event source")
      return nil
    } catch {
      return "Invalid event source registration: \(error.localizedDescription)"
    }
  }

  private func eventRootURL(for candidate: RielaAppDaemonWorkflowCandidate) -> URL {
    if let eventRoot = candidate.eventRoot, !eventRoot.isEmpty {
      return URL(fileURLWithPath: eventRoot, isDirectory: true)
    }
    return URL(fileURLWithPath: candidate.workflowDirectory, isDirectory: true)
      .appendingPathComponent(".riela-events", isDirectory: true)
  }

  private func parseEventJSONObject(_ text: String, label: String) throws -> [String: Any] {
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

  private func requiredEventString(_ key: String, in object: [String: Any], label: String) throws -> String {
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

  private func prettyEventJSONData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  }

  private func sanitizedEventFileName(_ rawValue: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    let mapped = rawValue.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar) : "-"
    }
    let sanitized = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_ :"))
    return sanitized.isEmpty ? "event-source" : sanitized
  }
}
#endif
