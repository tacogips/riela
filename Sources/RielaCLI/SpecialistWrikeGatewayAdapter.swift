import Foundation
import RielaCore

#if canImport(WrikeGatewayCore)
import WrikeGatewayCore
import WrikeGatewayRead
import WrikeGatewayWrite

/// Production tracker projection through the linked gateway writer tier. The
/// configuration contains mapping identifiers only; credentials remain in the
/// gateway's approved environment/keychain contract.
struct SpecialistWrikeGatewayAdapter: SpecialistWrikeGateway {
  private struct GatewayRequest {
    let document: String
    let variables: [String: Any]
    let resultKey: String
  }

  struct Configuration: Sendable {
    let folderId: String
    let statusByLifecycle: [String: String]
  }

  let configuration: Configuration
  var reader: any SpecialistWrikeReader = SpecialistProductionWrikeReader()

  func deliver(_ event: SpecialistOutboxEvent, trackerTaskId: String?) async throws -> String {
    let request: GatewayRequest
    if event.operation == "ownership" {
      request = GatewayRequest(
        document: "mutation SpecialistCreateTrackerTask($input: CreateTaskInput!) { createTask(input: $input) { task { id } } }",
        variables: ["input": ["folderId": configuration.folderId, "title": bounded(event.payload), "description": correlation(event)]],
        resultKey: "createTask"
      )
    } else {
      guard let trackerTaskId else { throw SpecialistRemoteDeliveryError.uncertain }
      let status = try lifecycleStatus(for: event)
      request = GatewayRequest(
        document: "mutation SpecialistUpdateTrackerTask($input: UpdateTaskInput!) { updateTask(input: $input) { task { id } } }",
        variables: ["input": ["taskId": trackerTaskId, "status": status, "description": correlation(event)]],
        resultKey: "updateTask"
      )
    }
    let variables = try JSONSerialization.data(withJSONObject: request.variables, options: [.sortedKeys])
    let frame = try GatewayComposition.makeCommandFrame(
      role: .writer,
      definitions: WriteCapabilities.all,
      environment: StaticEnvironmentReader(extra: gatewayEnvironment())
    )
    let outcome = await frame.run(arguments: [
      "graphql", "query", request.document,
      "--variables", String(bytes: variables, encoding: .utf8) ?? "{}"
    ])
    guard outcome.exitCode == .success,
          let object = try? JSONSerialization.jsonObject(with: Data(outcome.standardOutput.utf8)) as? [String: Any],
          let data = object["data"] as? [String: Any],
          let mutation = data[request.resultKey] as? [String: Any],
          let task = mutation["task"] as? [String: Any],
          let taskId = task["id"] as? String,
          !taskId.isEmpty else {
      // A mutation might have reached Wrike even when the receipt is absent.
      // The durable outbox therefore enters explicit reconciliation, never a
      // blind automatic retry.
      throw SpecialistRemoteDeliveryError.uncertain
    }
    return taskId
  }

  func reconcile(_ event: SpecialistOutboxEvent, trackerTaskId: String?) async throws -> SpecialistWrikeReconciliation {
    let marker = "[riela-correlation:\(event.eventId)]"
    var matches = Set<String>()
    var cursor: String?
    var seenCursors = Set<String>()
    // Bounded reader-only traversal. An incomplete traversal cannot establish
    // uniqueness, so it never promotes an uncertain write to delivered.
    for _ in 0 ..< 10 {
      let response = try await reader.tasks(folderId: configuration.folderId, cursor: cursor)
      guard let data = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { return .notFound }
      guard let connection = data["tasks"] as? [String: Any],
            let tasks = connection["nodes"] as? [[String: Any]],
            let page = connection["pageInfo"] as? [String: Any] else { return .notFound }
      for task in tasks {
        guard let id = task["id"] as? String, !id.isEmpty,
              let description = task["description"] as? String,
              description.contains(marker) else { continue }
        guard trackerTaskId == nil || trackerTaskId == id else { return .conflicting }
        matches.insert(id)
      }
      if matches.count > 1 { return .conflicting }
      guard let next = page["nextPageToken"] as? String, !next.isEmpty else {
        return matches.first.map(SpecialistWrikeReconciliation.delivered) ?? .notFound
      }
      guard seenCursors.insert(next).inserted else { return .notFound }
      cursor = next
    }
    return .notFound
  }

  func lifecycleStatus(for event: SpecialistOutboxEvent) throws -> String {
    guard let state = event.taskState else { throw SpecialistRemoteDeliveryError.uncertain }
    switch state {
    case .succeeded: return configuration.statusByLifecycle["succeeded"] ?? "Completed"
    case .cancelled: return configuration.statusByLifecycle["cancelled"] ?? "Cancelled"
    case .failed: return configuration.statusByLifecycle["failed"] ?? "Deferred"
    default: return configuration.statusByLifecycle["active"] ?? "Active"
    }
  }

  private func correlation(_ event: SpecialistOutboxEvent) -> String {
    "[riela-correlation:\(event.eventId)] " + String(event.payload.prefix(3_000))
  }

  private func bounded(_ value: String) -> String { String(value.prefix(200)) }

  private func gatewayEnvironment() -> [String: String] {
    let allowed = BuiltinWrikeGatewayAddon.allowedTargetEnvironmentNames
    return ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
  }
}

protocol SpecialistWrikeReader: Sendable {
  func tasks(folderId: String, cursor: String?) async throws -> Data
}

struct SpecialistProductionWrikeReader: SpecialistWrikeReader {
  static let document = """
    query SpecialistFindReceipt($folderId: ID!, $cursor: String) {
      tasks(scope: {folderId: $folderId}, page: {pageSize: 100, nextPageToken: $cursor}) {
        nodes { id description } pageInfo { nextPageToken }
      }
    }
    """

  func tasks(folderId: String, cursor: String?) async throws -> Data {
    var variables: [String: Any] = ["folderId": folderId]
    variables["cursor"] = cursor.map { $0 as Any } ?? NSNull()
    let encoded = try JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])
    let environment = ProcessInfo.processInfo.environment.filter { BuiltinWrikeGatewayAddon.allowedTargetEnvironmentNames.contains($0.key) }
    let frame = try GatewayComposition.makeCommandFrame(
      role: .reader, definitions: ReadCapabilities.all, environment: StaticEnvironmentReader(extra: environment)
    )
    let outcome = await frame.run(arguments: ["graphql", "query", Self.document, "--variables", String(bytes: encoded, encoding: .utf8) ?? "{}"])
    guard outcome.exitCode == .success,
          let object = try JSONSerialization.jsonObject(with: Data(outcome.standardOutput.utf8)) as? [String: Any],
          object["errors"] == nil, let data = object["data"] as? [String: Any] else {
      throw SpecialistRemoteDeliveryError.uncertain
    }
    return try JSONSerialization.data(withJSONObject: data)
  }
}
#else
struct SpecialistWrikeGatewayAdapter: SpecialistWrikeGateway {
  struct Configuration: Sendable {
    let folderId: String
    let statusByLifecycle: [String: String]
  }

  let configuration: Configuration

  func deliver(_ event: SpecialistOutboxEvent, trackerTaskId: String?) async throws -> String {
    throw SpecialistRemoteDeliveryError.permanent
  }
}
#endif
