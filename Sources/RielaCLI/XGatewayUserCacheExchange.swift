import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

/// Built-in author cache, separate from article bodies and durable memory.
/// The workflow only enables it; the runtime owns policy and namespace.
struct XGatewayUserCacheExchange: Sendable {
  static let cacheId = "x-gateway-users"
  static let scope = "public-users"
  static let policy = CachePolicy(ttlSeconds: 30 * 86_400, maxBytes: 512 * 1024)
  let store: RielaCacheStore
  private let clock: @Sendable () -> Date

  init?(input: WorkflowAddonExecutionInput, workingDirectory: URL, environment: [String: String] = [:],
        clock: @escaping @Sendable () -> Date = { Date() }) throws {
    guard let value = input.addon.config?["userCache"] else { return nil }
    guard case let .bool(enabled) = value else {
      throw AdapterExecutionError(.invalidInput, "X userCache must be true or false")
    }
    guard enabled else { return nil }
    let home = CLIRuntimeEnvironment.homeDirectory(environment: environment)
    let root = nonEmptyString(environment["RIELA_CACHE_ROOT"])
      ?? URL(fileURLWithPath: home).appendingPathComponent(".riela/cache").path
    self.clock = clock
    store = RielaCacheStore(rootDirectory: root, clock: clock)
    _ = try store.configure(cacheId: Self.cacheId, policy: Self.policy)
  }

  func bindings() throws -> [String: String] {
    let keys = try store.keys(cacheId: Self.cacheId, scope: Self.scope)
    var rows: [JSONValue] = []
    for offset in stride(from: 0, to: keys.count, by: 1024) {
      let batch = Array(keys[offset..<min(offset + 1024, keys.count)])
      let result = try store.get(cacheId: Self.cacheId, scope: Self.scope, keys: batch, maxOutputBytes: 8_000_000, touch: false)
      rows += result.results.compactMap { $0.entry?.payload }.map { jsonValue(from: $0) }
    }
    let json = try JSONValue.array(rows).compactJSONString()
    guard json.utf8.count <= 800_000 else {
      throw AdapterExecutionError(.invalidInput, "X user cache exceeds its private transport budget")
    }
    // The SDK exchange uses bounded in-memory parts; Linux limits individual
    // environment values to about 128 KiB. Nothing here contains credentials.
    let scalars = json.unicodeScalars
    var parts: [String] = []
    var start = scalars.startIndex
    while start < scalars.endIndex {
      let end = scalars.index(start, offsetBy: 20_000, limitedBy: scalars.endIndex) ?? scalars.endIndex
      parts.append(String(scalars[start..<end])); start = end
    }
    var bindings = ["X_GW_USER_MEMORY_PARTS": String(parts.count)]
    for (index, part) in parts.enumerated() { bindings["X_GW_USER_MEMORY_JSON_\(index)"] = part }
    return bindings
  }

  func consume(_ stdout: String) throws -> String {
    var envelope: JSONObject
    do { envelope = try JSONDecoder().decode(JSONObject.self, from: Data(stdout.utf8)) } catch {
      throw AdapterExecutionError(.invalidOutput, "X gateway returned invalid JSON")
    }
    guard envelope["ok"] == .bool(true), case var .object(graphQL)? = envelope["data"],
          case var .object(extensions)? = graphQL["extensions"],
          case let .array(rows)? = extensions.removeValue(forKey: "userMemory") else {
      if envelope["ok"] == .bool(false) { return stdout }
      throw AdapterExecutionError(.invalidOutput, "X gateway image does not support the user cache exchange")
    }
    guard rows.count <= 10_000 else { throw AdapterExecutionError(.invalidOutput, "X user cache additions exceed their bound") }
    var additions: [String: JSONObject] = [:]
    for row in rows {
      guard case let .object(user) = row,
            Set(user.keys).isSubset(of: ["id", "username", "name"]),
            let id = nonEmptyString(user["id"]), id.range(of: #"^[0-9]{1,32}$"#, options: .regularExpression) != nil,
            let handle = nonEmptyString(user["username"]), handle.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil,
            validName(user["name"]) else {
        throw AdapterExecutionError(.invalidOutput, "X gateway returned invalid user cache metadata")
      }
      additions[id] = user
    }
    do {
      if !additions.isEmpty {
        let timestamp = ISO8601DateFormatter().string(from: clock())
        // Per-user cache keys and the store's transaction merge parallel guests;
        // reads never renew TTL and article-cache pruning cannot affect users.
        let ids = additions.keys.sorted()
        for offset in stride(from: 0, to: ids.count, by: 128) {
          let batch = Array(ids[offset..<min(offset + 128, ids.count)])
          _ = try store.put(cacheId: Self.cacheId, scope: Self.scope, entries: batch.map { id in
            CachePut(key: id, fetchedAt: timestamp, payload: try memoryJSONValue(from: .object(additions[id] ?? [:])))
          }, skipNewerEntries: true)
        }
      }
      let used = authorIDs(in: graphQL["data"] ?? .object([:])).sorted()
      for offset in stride(from: 0, to: used.count, by: 1024) {
        _ = try store.get(cacheId: Self.cacheId, scope: Self.scope,
          keys: Array(used[offset..<min(offset + 1024, used.count)]), maxOutputBytes: 8_000_000)
      }
      extensions["userCacheStatus"] = .string("ok")
    } catch {
      // Optional cache maintenance must not turn a paid, successful post read
      // into a failed article batch. Never expose raw filesystem errors.
      extensions["userCacheStatus"] = .string("write-unavailable")
    }
    graphQL["extensions"] = extensions.isEmpty ? nil : .object(extensions)
    envelope["data"] = .object(graphQL)
    return try JSONValue.object(envelope).compactJSONString()
  }

  private func authorIDs(in value: JSONValue) -> Set<String> {
    switch value {
    case let .array(items): return items.reduce(into: Set<String>()) { $0.formUnion(authorIDs(in: $1)) }
    case let .object(object):
      var result: Set<String> = []
      if case let .object(author)? = object["author"], let id = nonEmptyString(author["id"]),
         id.range(of: #"^[0-9]{1,32}$"#, options: .regularExpression) != nil { result.insert(id) }
      for nested in object.values { result.formUnion(authorIDs(in: nested)) }
      return result
    default: return []
    }
  }

  private func validName(_ value: JSONValue?) -> Bool {
    guard let value else { return true }
    guard case let .string(name) = value else { return false }
    return name.utf8.count <= 512
  }
}
