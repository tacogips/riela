import Foundation
import RielaCore
import RielaMemory

/// Approved public author metadata only. Article bodies and credentials never
/// share this transport; seeds preserve the provider fetch timestamp.
struct XUserPrivateCacheSpace: PrivateWorkflowCacheSpace {
  let exchange: XGatewayUserCacheExchange
  init(environment: [String: String], clock: @escaping @Sendable () -> Date = { Date() }) {
    exchange = XGatewayUserCacheExchange(environment: environment, clock: clock)
  }

  func snapshot() -> JSONObject? {
    do {
      let keys = try exchange.store.keys(cacheId: XGatewayUserCacheExchange.cacheId, scope: XGatewayUserCacheExchange.scope)
      guard keys.count <= XGatewayUserCacheExchange.maximumAdditions else { return nil }
      var rows: [JSONValue] = []
      for offset in stride(from: 0, to: keys.count, by: 512) {
        let result = try exchange.store.get(cacheId: XGatewayUserCacheExchange.cacheId, scope: XGatewayUserCacheExchange.scope,
          keys: Array(keys[offset..<min(offset + 512, keys.count)]), maxOutputBytes: 8_000_000, touch: false)
        for lookup in result.results {
          guard let entry = lookup.entry, let payload = entry.payload,
            case let .object(user) = jsonValue(from: payload), Self.valid(user), user["id"] == .string(entry.key),
            Self.date(entry.fetchedAt) != nil else { continue }
          rows.append(.object(["user": .object(user), "fetchedAt": .string(entry.fetchedAt)]))
        }
      }
      let value: JSONObject = ["version": .integer(1), "entries": .array(rows)]
      guard try JSONEncoder().encode(value).count <= XGatewayUserCacheExchange.maximumSnapshotBytes else { return nil }
      return value
    } catch { return nil }
  }

  func seed(_ value: JSONObject) {
    guard Set(value.keys) == ["version", "entries"], value["version"] == .integer(1),
      case let .array(rows)? = value["entries"], rows.count <= XGatewayUserCacheExchange.maximumAdditions,
      let encoded = try? JSONEncoder().encode(value), encoded.count <= XGatewayUserCacheExchange.maximumSnapshotBytes else { return }
    var entries: [CachePut] = []; var ids = Set<String>()
    for row in rows {
      guard case let .object(entry) = row, Set(entry.keys) == ["user", "fetchedAt"],
        case let .object(user)? = entry["user"], Self.valid(user), case let .string(id)? = user["id"],
        case let .string(fetchedAt)? = entry["fetchedAt"], Self.date(fetchedAt) != nil,
        ids.insert(id).inserted, let payload = try? memoryJSONValue(from: .object(user)) else { return }
      entries.append(CachePut(key: id, fetchedAt: fetchedAt, payload: payload))
    }
    // Validation of the whole envelope precedes the first write. Store policy
    // rejects expired/future inputs; optional cache failures remain misses.
    for offset in stride(from: 0, to: entries.count, by: 128) {
      _ = try? exchange.store.put(cacheId: XGatewayUserCacheExchange.cacheId, scope: XGatewayUserCacheExchange.scope,
        entries: Array(entries[offset..<min(offset + 128, entries.count)]), skipNewerEntries: true)
    }
  }

  func consume(_ payload: JSONValue) -> String {
    guard case let .array(rows) = payload, rows.count <= XGatewayUserCacheExchange.maximumAdditions,
      rows.allSatisfy({ if case let .object(user) = $0 { return Self.valid(user) }; return false }) else { return "invalid" }
    do {
      let result = try exchange.consume(envelope: ["ok": .bool(true), "data": .object([
        "data": .object([:]), "extensions": .object(["userMemory": .array(rows)])])])
      guard case let .object(graphQL)? = result["data"], case let .object(ext)? = graphQL["extensions"],
        ext["userCacheStatus"] == .string("ok") else { return "unavailable" }
      return "stored"
    } catch { return "invalid" }
  }

  private static func valid(_ user: JSONObject) -> Bool {
    guard Set(user.keys).isSubset(of: ["id", "username", "name"]),
      case let .string(id)? = user["id"], id.range(of: #"^[0-9]{1,32}$"#, options: .regularExpression) != nil,
      case let .string(handle)? = user["username"], handle.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil else { return false }
    if let name = user["name"] {
      guard case let .string(text) = name, text.utf8.count <= 512 else { return false }
    }
    return true
  }
  private static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
