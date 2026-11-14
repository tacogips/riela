import Foundation
import RielaSQLite

struct RuntimePayloadFragment: Equatable, Sendable {
  let digest: String
  let json: String
}

struct RuntimeReducedPayload: Equatable, Sendable {
  let json: String
  let digest: String
  let fragments: [RuntimePayloadFragment]
}

enum RuntimePayloadFragmentEncoder {
  static let minimumFragmentBytes = 1024
  static let referenceKey = "$rielaPayloadRef"
  static let markerKey = "_rielaPayloadRefs"

  static func reduce(fullJSON: String) throws -> RuntimeReducedPayload {
    let original = RuntimeReducedPayload(
      json: fullJSON, digest: SQLiteWorkflowRuntimePersistenceStore.sha256(fullJSON), fragments: []
    )
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(fullJSON.utf8))
    guard case var .object(object) = value, let snapshot = object["inputSnapshot"], !containsReference(snapshot) else {
      return original
    }
    var fragments: [String: RuntimePayloadFragment] = [:]
    object["inputSnapshot"] = try reduceValue(snapshot, fragments: &fragments)
    guard !fragments.isEmpty else { return original }
    let ordered = fragments.keys.sorted()
    object[markerKey] = .array(ordered.map { .string($0) })
    let json = try encode(.object(object))
    return RuntimeReducedPayload(
      json: json, digest: SQLiteWorkflowRuntimePersistenceStore.sha256(json),
      fragments: ordered.compactMap { fragments[$0] }
    )
  }

  static func expand(_ execution: inout JSONValue, fragments: [String: String]) throws {
    guard case var .object(object) = execution, object[markerKey] != nil else { return }
    object.removeValue(forKey: markerKey)
    if let snapshot = object["inputSnapshot"] {
      object["inputSnapshot"] = try expandValue(snapshot, fragments: fragments, visiting: [])
    }
    execution = .object(object)
  }

  static func fragmentDigests(_ execution: JSONValue) throws -> [String]? {
    guard case let .object(object) = execution, let marker = object[markerKey] else { return nil }
    guard case let .array(values) = marker else {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime payload fragment missing or corrupt: marker")
    }
    return try values.map { value in
      guard case let .string(digest) = value else {
        throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime payload fragment missing or corrupt: marker")
      }
      return digest
    }
  }

  static func fetchFragments(_ digests: [String], root: String, db: SQLiteDatabase) throws -> [String: String] {
    let unique = Array(Set(digests)).sorted()
    var fragments: [String: String] = [:]
    for start in stride(from: 0, to: unique.count, by: 500) {
      let chunk = Array(unique[start..<min(start + 500, unique.count)])
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
      let rows = try db.query(
        "SELECT digest, json(bytes) AS payload FROM workflow_runtime_payloads WHERE root_session_id=? AND digest IN (\(placeholders))",
        bindings: [.text(root)] + chunk.map { .text($0) }
      )
      for row in rows {
        if let digest = row["digest"], let payload = row["payload"] { fragments[digest] = payload }
      }
    }
    return fragments
  }

  private static func expandValue(
    _ value: JSONValue, fragments: [String: String], visiting: Set<String>
  ) throws -> JSONValue {
    switch value {
    case let .object(object):
      if object.count == 1, case let .string(digest)? = object[referenceKey] {
        guard !visiting.contains(digest), let text = fragments[digest],
              SQLiteWorkflowRuntimePersistenceStore.sha256(text) == digest,
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
          throw WorkflowRuntimePersistenceStoreError.sqliteFailed("runtime payload fragment missing or corrupt: \(digest)")
        }
        return try expandValue(decoded, fragments: fragments, visiting: visiting.union([digest]))
      }
      var result: JSONObject = [:]
      for (key, child) in object {
        result[key] = try expandValue(child, fragments: fragments, visiting: visiting)
      }
      return .object(result)
    case let .array(values):
      return .array(try values.map { try expandValue($0, fragments: fragments, visiting: visiting) })
    default:
      return value
    }
  }

  private static func containsReference(_ value: JSONValue) -> Bool {
    switch value {
    case let .object(object):
      return object[referenceKey] != nil || object.values.contains(where: containsReference)
    case let .array(values):
      return values.contains(where: containsReference)
    default:
      return false
    }
  }

  private static func reduceValue(
    _ value: JSONValue, fragments: inout [String: RuntimePayloadFragment]
  ) throws -> JSONValue {
    let candidate: JSONValue
    switch value {
    case let .object(object):
      var reduced: JSONObject = [:]
      for key in object.keys.sorted() {
        if let child = object[key] { reduced[key] = try reduceValue(child, fragments: &fragments) }
      }
      candidate = .object(reduced)
    case let .array(values):
      candidate = .array(try values.map { try reduceValue($0, fragments: &fragments) })
    case .string:
      candidate = value
    default:
      return value
    }
    let json = try encode(candidate)
    guard json.utf8.count >= minimumFragmentBytes else { return candidate }
    let digest = SQLiteWorkflowRuntimePersistenceStore.sha256(json)
    fragments[digest] = RuntimePayloadFragment(digest: digest, json: json)
    return .object([referenceKey: .string(digest)])
  }

  private static func encode(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = RuntimeSnapshotDates.encoding
    return String(bytes: try encoder.encode(value), encoding: .utf8) ?? "{}"
  }
}

extension SQLiteWorkflowRuntimePersistenceStore {
  @TaskLocal static var writesReducedExecutionPayloadsOverride: Bool?
  static let writesReducedExecutionPayloadsByDefault = true
  static var writesReducedExecutionPayloads: Bool {
    writesReducedExecutionPayloadsOverride ?? writesReducedExecutionPayloadsByDefault
  }
}
