import Foundation
import RielaCore

/// Provider-independent metadata algebra. Body availability is supplied by a
/// cache read; availability and acquisition completion never acknowledge work.
enum RecordManifest {
  struct Entry: Codable {
    var key: String
    var version: String
    var value: JSONValue
  }

  static func execute(action: String, value: JSONObject) throws -> JSONObject {
    let common: Set<String> = ["entries"]
    let fields: [String: Set<String>] = [
      "partition": ["availableKeys", "oversizedKeys", "acknowledged", "selectedKeys", "unavailableAcknowledgedKeys"],
      "merge": ["current", "retainKeys"],
      "admit": ["available", "acknowledged", "priority", "examinedKeys", "maximumItems", "maximumBytes"],
      "recover": ["requestedKeys", "returnedKeys", "pendingKeys", "attemptedKeys", "deferredKeys",
        "availableKeys", "unavailableAcknowledgedKeys", "acknowledged", "context", "expectedContext"]
    ]
    guard let fields = fields[action], Set(value.keys).isSubset(of: common.union(fields)),
      try JSONEncoder().encode(value).count <= 64 * 1024 * 1024 - 8192 else { throw invalid() }
    let entries = try entries(value["entries"])
    let all = Set(entries.map { key($0.key) })
    let result: JSONObject
    switch action {
    case "admit": result = try RecordManifestAdmission.select(value, entries: entries)
    case "partition": result = try partition(value, entries: entries, all: all)
    case "merge":
      let current = try self.entries(value["current"])
      let retain = try keys(value["retainKeys"])
      guard retain.isSubset(of: all) else { throw invalid() }
      let known = Set(current.map { key($0.key) })
      let retained = entries.filter { retain.contains(key($0.key)) && !known.contains(key($0.key)) }
      let merged = current + retained
      guard merged.count <= 10_000 else { throw invalid() }
      result = ["entries": try json(merged), "retainedKeys": try json(retained.map(\.key))]
    case "recover": result = try recover(value, entries: entries, all: all)
    default: throw invalid()
    }
    guard try JSONEncoder().encode(result).count <= 64 * 1024 * 1024 - 8192 else { throw invalid() }
    return result
  }

  private static func partition(_ value: JSONObject, entries: [Entry], all: Set<Data>) throws -> JSONObject {
    let available = try keys(value["availableKeys"])
    let oversized = try keys(value["oversizedKeys"], fallback: [])
    let selected = try value["selectedKeys"].map { try keys($0) } ?? all
    let unavailable = try keys(value["unavailableAcknowledgedKeys"], fallback: [])
    let acknowledged = try acknowledgements(value["acknowledged"])
    guard selected.isSubset(of: all), available.isSubset(of: selected), oversized.isSubset(of: selected),
      available.isDisjoint(with: oversized), unavailable.isSubset(of: all) else { throw invalid() }
    let ready = entries.filter { available.contains(key($0.key)) }
    let missing = entries.filter { selected.contains(key($0.key)) && !available.contains(key($0.key)) && !oversized.contains(key($0.key)) }
    let missingKeys = Set(missing.map { key($0.key) })
    let pending = missing.filter { acknowledged[key($0.key)] != key($0.version) }
    let exported = entries.filter { entry in
      acknowledged[key(entry.key)] == key(entry.version) &&
        (missingKeys.contains(key(entry.key)) || (!selected.contains(key(entry.key)) && unavailable.contains(key(entry.key))))
    }
    return ["available": try json(ready), "pending": try json(pending), "acknowledgedMissing": try json(exported),
      "oversized": try json(entries.filter { oversized.contains(key($0.key)) }), "needsRecovery": .bool(!pending.isEmpty)]
  }

  private static func recover(_ value: JSONObject, entries: [Entry], all: Set<Data>) throws -> JSONObject {
    guard let context = value["context"], let expected = value["expectedContext"], context == expected, try encoded(context) == encoded(expected) else { throw invalid() }
    let requested = try keys(value["requestedKeys"])
    let returned = try keys(value["returnedKeys"])
    let pending = try keys(value["pendingKeys"])
    let available = try keys(value["availableKeys"])
    let unavailable = try keys(value["unavailableAcknowledgedKeys"], fallback: [])
    let acknowledged = try acknowledgements(value["acknowledged"])
    guard requested.isSubset(of: all), returned.isDisjoint(with: pending), returned.union(pending) == requested,
      returned.isSubset(of: available), available.isDisjoint(with: pending), available.isDisjoint(with: unavailable),
      pending.isDisjoint(with: unavailable), available.union(pending).union(unavailable) == all,
      entries.filter({ unavailable.contains(key($0.key)) }).allSatisfy({ acknowledged[key($0.key)] == key($0.version) }) else { throw invalid() }
    if value["attemptedKeys"] != nil || value["deferredKeys"] != nil {
      let attempted = try keys(value["attemptedKeys"])
      let deferred = try keys(value["deferredKeys"])
      guard attempted.isDisjoint(with: deferred), attempted.union(deferred) == requested,
        returned.isSubset(of: attempted), deferred.isSubset(of: pending) else { throw invalid() }
    }
    return ["retainedPending": try json(entries.filter { pending.contains(key($0.key)) }),
      "retainedAcknowledged": try json(entries.filter { unavailable.contains(key($0.key)) }),
      "coveredKeys": try json(sortedKeys(available)), "pendingKeys": try json(sortedKeys(pending)),
      "hasProgress": .bool(!returned.isEmpty)]
  }

  private static func entries(_ raw: JSONValue?) throws -> [Entry] {
    guard case let .array(items)? = raw, items.count <= 10_000, items.allSatisfy({ item in
      guard case let .object(object) = item else { return false }
      return Set(object.keys) == ["key", "version", "value"]
    }), let raw else { throw invalid() }
    let entries = try JSONDecoder().decode([Entry].self, from: JSONEncoder().encode(raw))
    guard entries.count <= 10_000, Set(entries.map { key($0.key) }).count == entries.count,
      entries.allSatisfy({ valid($0.key) && valid($0.version) }) else { throw invalid() }
    return entries
  }

  private static func keys(_ raw: JSONValue?, fallback: Set<Data>? = nil) throws -> Set<Data> {
    guard let raw else { if let fallback { return fallback }; throw invalid() }
    let values = try JSONDecoder().decode([String].self, from: JSONEncoder().encode(raw))
    guard values.count <= 10_000, Set(values.map(key)).count == values.count, values.allSatisfy(valid) else { throw invalid() }
    return Set(values.map(key))
  }

  private struct Acknowledgement: Decodable {
    var key: String
    var version: String
  }

  private static func acknowledgements(_ raw: JSONValue?) throws -> [Data: Data] {
    guard let raw else { return [:] }
    guard case let .array(items) = raw, items.count <= 10_000, items.allSatisfy({ item in
      guard case let .object(value) = item else { return false }
      return Set(value.keys) == ["key", "version"]
    }) else { throw invalid() }
    let values = try JSONDecoder().decode([Acknowledgement].self, from: JSONEncoder().encode(raw))
    guard Set(values.map { key($0.key) }).count == values.count,
      values.allSatisfy({ valid($0.key) && valid($0.version) }) else { throw invalid() }
    return Dictionary(uniqueKeysWithValues: values.map { (key($0.key), key($0.version)) })
  }

  private static func key(_ value: String) -> Data { Data(value.utf8) }

  private static func sortedKeys(_ values: Set<Data>) throws -> [String] {
    try values.sorted { $0.lexicographicallyPrecedes($1) }.map {
      guard let value = String(data: $0, encoding: .utf8) else { throw invalid() }
      return value
    }
  }

  private static func encoded(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func valid(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 1024 && !value.unicodeScalars.contains { $0.value < 32 }
  }

  private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  private static func invalid() -> AdapterExecutionError {
    .init(.invalidInput, "invalid record-manifest metadata or recovery partition")
  }
}
