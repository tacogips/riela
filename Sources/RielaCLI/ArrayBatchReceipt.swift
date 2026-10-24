import Foundation
import RielaCore

/// Runtime-owned batch binding and ordered result assembly. Worker outputs can
/// select original identities; they cannot replace items or advance a partial join.
enum ArrayBatchReceipt {
  static func seal(_ batches: [JSONValue], identityKey: String, context: JSONValue) throws -> JSONValue {
    .object(["version": .integer(1), "identityKey": .string(identityKey), "context": context,
      "batchDigests": .array(try batches.map { .string(try digest($0)) })])
  }

  static func gather(_ config: JSONObject) throws -> JSONObject {
    guard Set(config.keys).isSubset(of: ["join", "groupId", "selectedIdsFrom", "jsonSchema"]),
      case let .object(join)? = config["join"], case let .string(group)? = config["groupId"], !group.isEmpty,
      group.utf8.count <= 1024, join["groupId"] == .string(group), join["allBranchesCompleted"] == .bool(true),
      case let .array(branches)? = join["branches"], branches.count <= 10_000,
      case let .object(receipt)? = join["context"],
      Set(receipt.keys) == Set(["version", "identityKey", "context", "batchDigests"]), receipt["version"] == .integer(1),
      case let .string(key)? = receipt["identityKey"], !key.isEmpty, key.utf8.count <= 256,
      case let .array(digests)? = receipt["batchDigests"], branches.count == digests.count,
      try JSONEncoder().encode(join).count <= 16_000_000 else { throw invalid() }
    let selection: String?
    if let value = config["selectedIdsFrom"] {
      guard case let .string(pointer) = value, pointer.hasPrefix("/"), pointer.utf8.count <= 1024 else { throw invalid() }
      selection = pointer
    } else { selection = nil }
    var ordered: [Int: JSONObject] = [:]
    for value in branches {
      guard case let .object(branch) = value, branch["status"] == .string("completed"),
        case let .integer(raw)? = branch["index"], let index = Int(exactly: raw), (0..<digests.count).contains(index),
        ordered.updateValue(branch, forKey: index) == nil else { throw invalid() }
    }
    var gathered: [JSONValue] = [], total = 0, identities = Set<Data>()
    for index in digests.indices {
      guard let branch = ordered[index], case let .array(items)? = branch["item"], !items.isEmpty,
        items.count <= 10_000, digests[index] == .string(try digest(.array(items))) else { throw invalid() }
      var batchIds = Set<Data>()
      for value in items {
        guard case let .object(item) = value, case let .string(identity)? = item[key], !identity.isEmpty,
          batchIds.insert(Data(identity.utf8)).inserted, identities.insert(Data(identity.utf8)).inserted else { throw invalid() }
      }
      total += items.count
      guard total <= 10_000 else { throw invalid() }
      let selected: Set<Data>
      if let selection {
        guard let output = branch["output"],
          case let .array(values)? = try JSONDataTransform.lookup(output, pointer: .string(selection)),
          values.count <= 10_000 else { throw invalid() }
        var ids = Set<Data>()
        for value in values {
          guard case let .string(identity) = value, batchIds.contains(Data(identity.utf8)) else { throw invalid() }
          ids.insert(Data(identity.utf8))
        }
        selected = ids
      } else { selected = batchIds }
      gathered += items.filter { value in
        guard case let .object(item) = value, case let .string(id)? = item[key] else { return false }
        return selected.contains(Data(id.utf8))
      }
    }
    return ["items": .array(gathered), "itemCount": .integer(Int64(total)), "selectedCount": .integer(Int64(gathered.count)),
      "context": receipt["context"] ?? .null]
  }

  private static func digest(_ value: JSONValue) throws -> String { JSONCanonical.sha256Hex(try JSONCanonical.encode(value)) }
  private static func invalid() -> AdapterExecutionError { .init(.invalidInput, "array-gather requires a complete, matching bound fanout join") }
}
