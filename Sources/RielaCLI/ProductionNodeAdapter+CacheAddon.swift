import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

enum BuiltinCacheAddon: String {
  case configure = "riela/cache-configure"
  case put = "riela/cache-put"
  case get = "riela/cache-get"
  case delete = "riela/cache-delete"
  case prune = "riela/cache-prune"
  case protect = "riela/cache-protect"
  case reconcile = "riela/cache-reconcile"
  case maintain = "riela/cache-maintain"
}

extension BuiltinWorkflowAddonResolver {
  func executeCacheAddon(_ input: WorkflowAddonExecutionInput, operation: BuiltinCacheAddon) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.invalidInput, "unsupported cache add-on version")
    }
    let variables = try addonVariables(for: input)
    let rendered = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: variables)
    guard case let .object(config) = rendered else { throw AdapterExecutionError(.invalidInput, "invalid cache config") }
    func value(_ key: String) -> JSONValue? { config[key] ?? variables[key] }
    func text(_ key: String, fallback: String? = nil) throws -> String {
      if let result = nonEmptyString(value(key)) { return result }
      if let fallback { return fallback }
      throw AdapterExecutionError(.invalidInput, "cache requires \(key)")
    }
    func integer(_ key: String, fallback: Int) throws -> Int {
      guard let raw = value(key) else { return fallback }
      let number: Int?
      switch raw {
      case let .integer(item): number = Int(exactly: item)
      case let .number(item): number = item.isFinite ? Int(exactly: item) : nil
      default: number = nil
      }
      guard let number else { throw AdapterExecutionError(.invalidInput, "cache \(key) must be an integer") }
      return number
    }
    func number(_ key: String, fallback: Double) throws -> Double {
      guard let raw = value(key) else { return fallback }
      switch raw {
      case let .integer(item): return Double(item)
      case let .number(item) where item.isFinite: return item
      default: throw AdapterExecutionError(.invalidInput, "cache \(key) must be a number")
      }
    }
    func decode<T: Decodable>(_ type: T.Type, _ raw: JSONValue?) throws -> T {
      guard let raw else { throw AdapterExecutionError(.invalidInput, "cache entries or keys are required") }
      do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(raw)) } catch { throw AdapterExecutionError(.invalidInput, "invalid cache entries or keys") }
    }
    let store = RielaCacheStore(rootDirectory: try text("cacheRoot",
      fallback: RielaCacheStore.defaultRootDirectory(workingDirectory: workingDirectory.path)))
    if operation == .maintain {
      // Maintenance only applies each store's own stored policy, so built-in
      // runtime caches may be listed. A failed store fails the node.
      let result = try store.maintain(cacheIds: decode([String].self, value("cacheIds")),
        maxDurationSeconds: number("maxDurationSeconds", fallback: 120))
      let payload = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(result))
      return AdapterExecutionOutput(provider: "riela-builtin-addon", model: input.addon.name,
        promptText: "", completionPassed: result.status != "failed", payload: payload)
    }
    let cacheId = try text("cacheId", fallback: "retrieval-cache")
    // Every other operation reads or writes rows: x-gateway-* caches hold
    // guest-exported runtime data and are off limits to workflows.
    guard !RielaCacheStore.isReservedBuiltinCacheId(cacheId) else {
      throw AdapterExecutionError(.policyBlocked, "cacheId '\(cacheId)' is reserved for a built-in runtime cache")
    }
    let scope = try text("scope", fallback: input.workflowId)
    let response: CacheResult
    switch operation {
    case .maintain: throw AdapterExecutionError(.invalidInput, "unreachable maintenance operation")
    case .configure:
      response = try store.configure(cacheId: cacheId, policy: CachePolicy(
        ttlSeconds: integer("ttlSeconds", fallback: 86_400), maxBytes: integer("maxBytes", fallback: 268_435_456)))
    case .prune: response = try store.prune(cacheId: cacheId)
    case .put:
      let entries: [CachePut]
      if let raw = value("entries") { entries = try decode([CachePut].self, raw) } else {
        guard let payload = value("payload") else { throw AdapterExecutionError(.invalidInput, "cache requires payload") }
        entries = [CachePut(key: try text("key"), fetchedAt: try text("fetchedAt"), payload: try memoryJSONValue(from: payload))]
      }
      response = try store.put(cacheId: cacheId, scope: scope, entries: entries,
        retaining: try value("retainedReferences").map { try memoryJSONValue(from: $0) })
    case .protect:
      response = try store.protect(cacheId: cacheId, scope: scope, entries: decode([CacheProtection].self, value("entries")))
    case .reconcile:
      guard let references = value("references") else { throw AdapterExecutionError(.invalidInput, "cache requires references") }
      response = try store.reconcile(cacheId: cacheId, scope: scope, references: memoryJSONValue(from: references))
    case .get:
      let keys = try value("keys").map { try decode([String].self, $0) } ?? [text("key")]
      response = try store.get(cacheId: cacheId, scope: scope, keys: keys,
        maxOutputBytes: integer("maxOutputBytes", fallback: RielaCacheStore.maximumFrameBytes))
    case .delete:
      let entries = try value("entries").map { try decode([CacheDelete].self, $0) }
        ?? [CacheDelete(key: text("key"), revision: text("expectedRevision"))]
      response = try store.delete(cacheId: cacheId, scope: scope, entries: entries)
    }
    let payload = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(response))
    return AdapterExecutionOutput(provider: "riela-builtin-addon", model: input.addon.name,
      promptText: "", completionPassed: true, payload: payload)
  }
}
