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
    func decode<T: Decodable>(_ type: T.Type, _ raw: JSONValue?) throws -> T {
      guard let raw else { throw AdapterExecutionError(.invalidInput, "cache entries or keys are required") }
      do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(raw)) } catch { throw AdapterExecutionError(.invalidInput, "invalid cache entries or keys") }
    }
    let cacheId = try text("cacheId", fallback: "retrieval-cache")
    let scope = try text("scope", fallback: input.workflowId)
    let store = RielaCacheStore(rootDirectory: try text("cacheRoot",
      fallback: RielaCacheStore.defaultRootDirectory(workingDirectory: workingDirectory.path)))
    let response: CacheResult
    switch operation {
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
      response = try store.put(cacheId: cacheId, scope: scope, entries: entries)
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
