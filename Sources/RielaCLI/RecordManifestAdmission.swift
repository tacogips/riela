import Foundation
import RielaCore

/// Provider-independent bounded admission. Cache availability does not mark a
/// version handled: only explicit matching acknowledgement metadata does.
enum RecordManifestAdmission {
  private struct Available {
    var payload: JSONValue
    var bytes: Int
  }

  static func select(_ config: JSONObject, entries: [RecordManifest.Entry]) throws -> JSONObject {
    let maximum = try bound(config["maximumItems"], fallback: 40, upper: 10_000)
    let byteLimit = try bound(config["maximumBytes"], fallback: 1_000_000, upper: 8_000_000)
    guard byteLimit >= 2 else { throw invalid() }
    let byKey = Dictionary(uniqueKeysWithValues: entries.map { (Data($0.key.utf8), $0) })
    let acknowledgements = try acknowledged(config["acknowledged"])
    let priority = try priority(config["priority"])
    let examined = try examined(config["examinedKeys"], fallback: Set(byKey.keys))
    guard examined.isSubset(of: Set(byKey.keys)) else { throw invalid() }
    let available = try available(config["available"], entries: byKey)
    let handled = entries.filter { acknowledgements[Data($0.key.utf8)] == Data($0.version.utf8) }
    let handledKeys = Set(handled.map { Data($0.key.utf8) })
    let candidates = entries.filter { !handledKeys.contains(Data($0.key.utf8)) }
    // A pending prefix is reused only while every exact descriptor survives.
    // A changed version is eligible again, without inheriting an old ACK.
    let reusable = try priority.allSatisfy { row in
      guard let current = byKey[Data(row.key.utf8)], !handledKeys.contains(Data(row.key.utf8)) else { return false }
      return try encode(current) == encode(row)
    }
    let preferred = reusable ? priority : []
    let preferredKeys = Set(preferred.map { Data($0.key.utf8) })
    let ordered = preferred + candidates.filter { !preferredKeys.contains(Data($0.key.utf8)) }
    var admitted: [RecordManifest.Entry] = [], records: [JSONValue] = []
    var unavailable: [String] = [], oversized: [String] = [], bytes = 2
    for row in ordered {
      let key = Data(row.key.utf8)
      guard let body = available[key] else {
        if examined.contains(key) { unavailable.append(row.key) }
        continue
      }
      if body.bytes + 2 > byteLimit { oversized.append(row.key); continue }
      let charge = body.bytes + (records.isEmpty ? 0 : 1)
      guard admitted.count < maximum, bytes + charge <= byteLimit else { continue }
      admitted.append(row); records.append(body.payload); bytes += charge
    }
    let admittedKeys = Set(admitted.map { Data($0.key.utf8) })
    return ["admitted": try json(admitted), "records": .array(records),
      "deferred": try json(candidates.filter { !admittedKeys.contains(Data($0.key.utf8)) }),
      "handled": try json(handled), "unavailableKeys": try json(unavailable), "oversizedKeys": try json(oversized)]
  }

  private static func available(_ raw: JSONValue?, entries: [Data: RecordManifest.Entry]) throws -> [Data: Available] {
    guard case let .array(rows)? = raw, rows.count <= 10_000 else { throw invalid() }
    var values: [Data: Available] = [:]
    for row in rows {
      guard case let .object(row) = row, Set(row.keys) == ["key", "version", "payload"],
        let key = text(row["key"]), let version = text(row["version"]), let payload = row["payload"],
        values[Data(key.utf8)] == nil, let entry = entries[Data(key.utf8)],
        Data(version.utf8) == Data(entry.version.utf8) else { throw invalid() }
      values[Data(key.utf8)] = .init(payload: payload, bytes: try encode(payload).count)
    }
    return values
  }

  private static func acknowledged(_ raw: JSONValue?) throws -> [Data: Data] {
    guard case let .array(rows) = raw ?? .array([]), rows.count <= 10_000 else { throw invalid() }
    var values: [Data: Data] = [:]
    for row in rows {
      guard case let .object(row) = row, Set(row.keys) == ["key", "version"],
        let key = text(row["key"]), let version = text(row["version"]), values[Data(key.utf8)] == nil else { throw invalid() }
      values[Data(key.utf8)] = Data(version.utf8)
    }
    return values
  }

  private static func priority(_ raw: JSONValue?) throws -> [RecordManifest.Entry] {
    guard case let .array(rows) = raw ?? .array([]), rows.count <= 10_000 else { throw invalid() }
    var keys = Set<Data>()
    for row in rows {
      guard case let .object(row) = row, Set(row.keys) == ["key", "version", "value"],
        let key = text(row["key"]), text(row["version"]) != nil, keys.insert(Data(key.utf8)).inserted else { throw invalid() }
    }
    return try JSONDecoder().decode([RecordManifest.Entry].self, from: encode(rows))
  }

  private static func examined(_ raw: JSONValue?, fallback: Set<Data>) throws -> Set<Data> {
    guard let raw else { return fallback }
    guard case let .array(rows) = raw, rows.count <= 10_000 else { throw invalid() }
    var keys = Set<Data>()
    for row in rows {
      guard let value = text(row), keys.insert(Data(value.utf8)).inserted else { throw invalid() }
    }
    return keys
  }

  private static func text(_ value: JSONValue?) -> String? {
    guard case let .string(text)? = value, !text.isEmpty, text.utf8.count <= 1024,
      !text.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
    return text
  }

  private static func bound(_ value: JSONValue?, fallback: Int, upper: Int) throws -> Int {
    guard case let .integer(raw) = value ?? .integer(Int64(fallback)), let value = Int(exactly: raw),
      (1...upper).contains(value) else { throw invalid() }
    return value
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  private static func json<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: encode(value))
  }
  private static func invalid() -> AdapterExecutionError { .init(.invalidInput, "invalid record admission metadata") }
}
