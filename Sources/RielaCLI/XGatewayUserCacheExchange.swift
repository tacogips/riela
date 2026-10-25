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
  /// Finite health values reported as `userCacheStatus`.
  static let statuses: Set<String> = ["ok", "write-unavailable", "unsupported"]
  /// Snapshot handed to the SDK; a larger cache is sent as empty (misses are refetched).
  static let maximumSnapshotBytes = 800_000
  /// Unicode scalars per `X_GW_USER_MEMORY_JSON_n` part (below Linux's ~128 KiB per value).
  static let partScalars = 20_000
  /// Rows accepted from one SDK reply.
  static let maximumAdditions = 10_000
  private static let maximumStoreReadBytes = 8_000_000
  let store: RielaCacheStore
  private let clock: @Sendable () -> Date

  init(environment: [String: String], clock: @escaping @Sendable () -> Date = { Date() }) {
    self.clock = clock
    store = RielaCacheStore(rootDirectory: XGatewayCacheRoot.path(environment: environment), clock: clock)
    // An unavailable store degrades to an empty exchange; consume() reports it.
    _ = try? store.configure(cacheId: Self.cacheId, policy: Self.policy)
  }

  init?(input: WorkflowAddonExecutionInput, environment: [String: String] = [:],
        clock: @escaping @Sendable () -> Date = { Date() }) throws {
    guard let value = input.addon.config?["userCache"] else { return nil }
    guard case let .bool(enabled) = value else {
      throw AdapterExecutionError(.invalidInput, "X userCache must be true or false")
    }
    guard enabled else { return nil }
    self.init(environment: environment, clock: clock)
  }

  /// Compatibility initializer; the working directory does not affect the cache root.
  init?(input: WorkflowAddonExecutionInput, workingDirectory _: URL, environment: [String: String] = [:],
        clock: @escaping @Sendable () -> Date = { Date() }) throws {
    try self.init(input: input, environment: environment, clock: clock)
  }

  func bindings() throws -> [String: String] {
    var json = try JSONValue.array(cachedRows()).compactJSONString()
    if json.utf8.count > Self.maximumSnapshotBytes { json = "[]" }
    // The SDK exchange uses bounded in-memory parts; Linux limits individual
    // environment values to about 128 KiB. Nothing here contains credentials.
    let scalars = json.unicodeScalars
    var parts: [String] = []
    var start = scalars.startIndex
    while start < scalars.endIndex {
      let end = scalars.index(start, offsetBy: Self.partScalars, limitedBy: scalars.endIndex) ?? scalars.endIndex
      parts.append(String(scalars[start..<end])); start = end
    }
    var bindings = ["X_GW_USER_MEMORY_PARTS": String(parts.count)]
    for (index, part) in parts.enumerated() { bindings["X_GW_USER_MEMORY_JSON_\(index)"] = part }
    return bindings
  }

  /// Optional cache reads must not fail a paid post read; misses are refetched.
  private func cachedRows() -> [JSONValue] {
    do {
      let keys = try store.keys(cacheId: Self.cacheId, scope: Self.scope)
      var rows: [JSONValue] = []
      for offset in stride(from: 0, to: keys.count, by: 1024) {
        let batch = Array(keys[offset..<min(offset + 1024, keys.count)])
        let result = try store.get(cacheId: Self.cacheId, scope: Self.scope, keys: batch, maxOutputBytes: Self.maximumStoreReadBytes, touch: false)
        rows += result.results.compactMap { $0.entry?.payload }.map { jsonValue(from: $0) }
      }
      return rows
    } catch {
      return []
    }
  }

  func consume(_ stdout: String) throws -> String {
    let envelope: JSONObject
    do { envelope = try JSONDecoder().decode(JSONObject.self, from: Data(stdout.utf8)) } catch {
      throw AdapterExecutionError(.invalidOutput, "X gateway returned invalid JSON")
    }
    return try JSONValue.object(consume(envelope: envelope)).compactJSONString()
  }

  /// Strips `userMemory` from a successful envelope and merges its rows into the
  /// cache. Failed or malformed envelopes pass through for the caller to reject.
  /// An image without the exchange still returns its paid data, marked
  /// `userCacheStatus: "unsupported"`.
  func consume(envelope input: JSONObject) throws -> JSONObject {
    var envelope = input
    guard envelope["ok"] == .bool(true), case var .object(graphQL)? = envelope["data"] else { return envelope }
    var extensions: JSONObject = [:]
    if case let .object(current)? = graphQL["extensions"] { extensions = current }
    guard let memory = extensions.removeValue(forKey: "userMemory") else {
      extensions["userCacheStatus"] = .string("unsupported")
      graphQL["extensions"] = .object(extensions)
      envelope["data"] = .object(graphQL)
      return envelope
    }
    guard case let .array(rows) = memory else {
      throw AdapterExecutionError(.invalidOutput, "X gateway returned invalid user cache metadata")
    }
    guard rows.count <= Self.maximumAdditions else { throw AdapterExecutionError(.invalidOutput, "X user cache additions exceed their bound") }
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
    if !rows.isEmpty { PrivateWorkflowCacheTransport.emit(cache: Self.cacheId, payload: .array(rows)) }
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
          keys: Array(used[offset..<min(offset + 1024, used.count)]), maxOutputBytes: Self.maximumStoreReadBytes)
      }
      extensions["userCacheStatus"] = .string("ok")
    } catch {
      // Optional cache maintenance must not turn a paid, successful post read
      // into a failed article batch. Never expose raw filesystem errors.
      extensions["userCacheStatus"] = .string("write-unavailable")
    }
    graphQL["extensions"] = extensions.isEmpty ? nil : .object(extensions)
    envelope["data"] = .object(graphQL)
    return envelope
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
