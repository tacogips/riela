import Foundation
import RielaAddonSupport
import RielaCore
import RielaMemory

extension BuiltinWorkflowAddonResolver {
  static let cacheExchangeRegistration = BuiltinAddonHandlerRegistration(name: "riela/cache-exchange", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try resolver.executeCacheExchange(input, deadline: context.deadline)
  }

  func executeCacheExchange(_ input: WorkflowAddonExecutionInput, deadline: Date? = nil) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)) else { throw cacheExchangeInvalid() }
    if config["action"] == .string("read-scan") { return try executeCacheReadScan(input, config: config, deadline: deadline) }
    if config["action"] == .string("read-set") { return try executeCacheReadSet(input, config: config) }
    guard
      Set(config.keys).isSubset(of: ["action", "storage", "entries", "references", "retainedReferences", "enabled"]),
      case let .string(action)? = config["action"], ["configure", "put", "get", "protect", "reconcile", "prune"].contains(action),
      case let .object(storage)? = config["storage"],
      Set(storage.keys).isSubset(of: ["cacheId", "scope", "cacheRoot", "ttlSeconds", "maxBytes", "capacityProtection"]),
      let cache = nonEmptyString(storage["cacheId"]),
      case let .integer(ttl) = storage["ttlSeconds"] ?? .integer(86_400),
      case let .integer(maximum) = storage["maxBytes"] ?? .integer(10 * 1024 * 1024),
      case let .bool(protection) = storage["capacityProtection"] ?? .bool(false),
      let ttlSeconds = Int(exactly: ttl), let maxBytes = Int(exactly: maximum),
      try JSONEncoder().encode(config).count <= RielaCacheStore.maximumFrameBytes - 4096 else { throw cacheExchangeInvalid() }
    let fields: [String: Set<String>] = ["configure": [], "prune": [], "put": ["entries", "retainedReferences"],
      "get": ["references"], "protect": ["references", "enabled"], "reconcile": ["references"]]
    guard Set(config.keys).subtracting(["action", "storage"]).isSubset(of: fields[action] ?? []) else { throw cacheExchangeInvalid() }
    func text(_ name: String, fallback: String) throws -> String {
      guard let raw = storage[name] else { return fallback }
      guard let value = nonEmptyString(raw) else { throw cacheExchangeInvalid() }; return value
    }
    func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) throws -> T {
      guard let value else { throw cacheExchangeInvalid() }
      return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
    let root = try text("cacheRoot", fallback: RielaCacheStore.defaultRootDirectory(workingDirectory: workingDirectory.path))
    let scope = try text("scope", fallback: input.workflowId)
    let policy = CachePolicy(ttlSeconds: ttlSeconds, maxBytes: maxBytes)
    let store = RielaCacheStore(rootDirectory: root)
    let exchange = try RielaCacheExchange(store: store, cacheId: cache, scope: scope, policy: policy, capacityProtection: protection)
    let payload: JSONObject
    do {
      switch action {
      case "configure": payload = try cacheExchangeObject(store.configure(cacheId: cache, policy: policy))
      case "prune": payload = try cacheExchangeObject(store.prune(cacheId: cache))
      case "put":
        let refs = try exchange.put(decode([CachePut].self, config["entries"]),
          retaining: config["retainedReferences"].map { try memoryJSONValue(from: $0) })
        payload = ["references": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(refs))]
      case "get": payload = try cacheExchangeObject(exchange.get(decode([CacheBodyReference].self, config["references"])))
      case "protect":
        guard case let .bool(enabled)? = config["enabled"] else { throw cacheExchangeInvalid() }
        try exchange.protect(decode([CacheBodyReference].self, config["references"]), enabled: enabled)
        payload = ["updated": .bool(true)]
      case "reconcile":
        guard let references = config["references"] else { throw cacheExchangeInvalid() }
        payload = try cacheExchangeObject(exchange.reconcile(memoryJSONValue(from: references)))
      default: throw cacheExchangeInvalid()
      }
    } catch let error as RielaCacheError {
      throw cacheExchangeFailure(error)
    } catch { throw cacheExchangeInvalid() }
    guard try JSONEncoder().encode(payload).count <= RielaCacheStore.maximumFrameBytes - 4096 else { throw cacheExchangeInvalid() }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, payload: payload)
  }
}

private func cacheExchangeObject<T: Encodable>(_ value: T) throws -> JSONObject {
  try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(value))
}

private func cacheExchangeInvalid() -> AdapterExecutionError {
  .init(.invalidInput, "invalid cache-exchange request or storage operation")
}

func cacheExchangeFailure(_ error: RielaCacheError) -> AdapterExecutionError {
  let reason: String
  switch error {
  case .oversized: reason = "oversized"
  case .expiredInput: reason = "expiredInput"
  case .revisionConflict: reason = "revisionConflict"
  case .protectedCapacityExceeded: reason = "protectedCapacityExceeded"
  case .foreignDatabase: reason = "foreignDatabase"
  case .busy: reason = "busy"
  case .invalid: reason = "invalid"
  }
  return .init(.invalidInput, "\(reason): cache-exchange operation failed")
}
