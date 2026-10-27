import Foundation
import RielaCore
import RielaMemory

/// Read an explicitly declared set of cache spaces without conflating physical
/// keys in different stores. Availability never acknowledges durable work.
extension BuiltinWorkflowAddonResolver {
  func executeCacheReadSet(_ input: WorkflowAddonExecutionInput, config: JSONObject) throws -> AdapterExecutionOutput {
    guard Set(config.keys).isSubset(of: ["action", "stores", "requests", "includePayload"]), config["action"] == .string("read-set"),
      case let .bool(includePayload) = config["includePayload"] ?? .bool(true),
      case let .object(stores)? = config["stores"], (1...16).contains(stores.count),
      case let .array(requests)? = config["requests"], requests.count <= 10_000,
      try JSONEncoder().encode(config).count <= RielaCacheStore.maximumFrameBytes - 8192 else { throw cacheReadSetInvalid() }
    do {
      let plan = try cacheReadPlan(stores: stores, requests: requests, workflowId: input.workflowId)
      let exchanges = plan.exchanges, groups = plan.groups, ordered = plan.ordered
      var results: [Data: JSONObject] = [:], bytes = 2
      for name in groups.keys.sorted() {
        let exchange = exchanges[name]!
        if !exchange.capacityProtection {
          // Release legacy protection before a lower disposable policy is
          // applied; otherwise protected bytes can prevent LRU reconfiguration.
          _ = try exchange.store.reconcile(cacheId: exchange.cacheId, scope: exchange.scope, references: .array([]))
        }
      }
      for name in groups.keys.sorted() {
        let exchange = exchanges[name]!, rows = groups[name]!
        _ = try exchange.store.configure(cacheId: exchange.cacheId, policy: exchange.policy)
        let read = includePayload ? try exchange.get(rows.map(\.reference)) : CacheBodyRead()
        let statuses = includePayload ? [:] : try exchange.availability(rows.map(\.reference))
        let missing = Set(read.missing), expired = Set(read.expired)
        for row in rows {
          var result: JSONObject = ["id": .string(row.id)]
          if !includePayload {
            guard let status = statuses[row.reference.key] else { throw cacheReadSetInvalid() }
            result["status"] = .string(status.rawValue)
          } else if let body = read.hits[row.reference.key] {
            result["status"] = .string("hit")
            result["payload"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(body))
          } else if missing.contains(row.reference.key) { result["status"] = .string("missing")
          } else if expired.contains(row.reference.key) { result["status"] = .string("expired")
          } else { throw cacheReadSetInvalid() }
          bytes += try JSONEncoder().encode(result).count + 1
          guard bytes <= RielaCacheStore.maximumFrameBytes - 8192 else { throw cacheReadSetInvalid() }
          results[Data(row.id.utf8)] = result
        }
      }
      let payload: JSONObject = ["results": .array(ordered.map { .object(results[Data($0.id.utf8)]!) })]
      guard try JSONEncoder().encode(payload).count <= RielaCacheStore.maximumFrameBytes - 4096 else { throw cacheReadSetInvalid() }
      return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, payload: payload)
    } catch let error as RielaCacheError { throw cacheExchangeFailure(error)
    } catch { throw cacheReadSetInvalid() }
  }

  func cacheReadPlan(stores: JSONObject, requests: [JSONValue], workflowId: String) throws -> CacheReadPlan {
      let exchanges = try stores.mapValues { try cacheReadExchange($0, workflowId: workflowId) }
      var policies: [String: CachePolicy] = [:]
      var protection: [String: [Data: Bool]] = [:]
      for exchange in exchanges.values {
        let path = try cacheReadPolicyKey(exchange.store.databasePath(cacheId: exchange.cacheId))
        if let previous = policies[path] {
          guard previous.ttlSeconds == exchange.policy.ttlSeconds, previous.maxBytes == exchange.policy.maxBytes else { throw cacheReadSetInvalid() }
        }
        policies[path] = exchange.policy
        let scope = Data(exchange.scope.utf8)
        if let previous = protection[path]?[scope], previous != exchange.capacityProtection { throw cacheReadSetInvalid() }
        protection[path, default: [:]][scope] = exchange.capacityProtection
      }
      var identities = Set<Data>(), groups: [String: [CacheReadRequest]] = [:], ordered: [CacheReadRequest] = []
      for raw in requests {
        guard case let .object(row) = raw, Set(row.keys) == ["id", "store", "reference"],
          case let .string(identity)? = row["id"], !identity.isEmpty, identity.utf8.count <= 1024,
          !identity.unicodeScalars.contains(where: { $0.value < 32 }), identities.insert(Data(identity.utf8)).inserted,
          case let .string(store)? = row["store"], exchanges[store] != nil, let reference = row["reference"] else { throw cacheReadSetInvalid() }
        let ref = try JSONDecoder().decode(CacheBodyReference.self, from: JSONEncoder().encode(reference))
        let request = CacheReadRequest(id: identity, store: store, reference: ref)
        groups[store, default: []].append(request); ordered.append(request)
      }
      // Validate the entire set before configuration can expire or evict a body.
      for (name, rows) in groups { try exchanges[name]!.validateReferences(rows.map(\.reference)) }
      return CacheReadPlan(exchanges: exchanges, groups: groups, ordered: ordered)
  }

  func cacheReadExchange(_ value: JSONValue, workflowId: String) throws -> RielaCacheExchange {
    guard case let .object(storage) = value,
      Set(storage.keys).isSubset(of: ["cacheId", "scope", "cacheRoot", "ttlSeconds", "maxBytes", "capacityProtection"]),
      case let .string(cache)? = storage["cacheId"], !cache.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      case let .integer(ttl) = storage["ttlSeconds"] ?? .integer(86_400),
      case let .integer(maximum) = storage["maxBytes"] ?? .integer(10 * 1024 * 1024),
      case let .bool(protection) = storage["capacityProtection"] ?? .bool(false),
      let ttlSeconds = Int(exactly: ttl), let maxBytes = Int(exactly: maximum) else { throw cacheReadSetInvalid() }
    func text(_ name: String, fallback: String) throws -> String {
      guard let raw = storage[name] else { return fallback }
      guard case let .string(value) = raw, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw cacheReadSetInvalid() }; return value
    }
    return try RielaCacheExchange(store: .init(rootDirectory: text("cacheRoot", fallback:
      RielaCacheStore.defaultRootDirectory(workingDirectory: workingDirectory.path))), cacheId: cache,
      scope: text("scope", fallback: workflowId), policy: .init(ttlSeconds: ttlSeconds, maxBytes: maxBytes), capacityProtection: protection)
  }
}

struct CacheReadPlan {
  var exchanges: [String: RielaCacheExchange]
  var groups: [String: [CacheReadRequest]]
  var ordered: [CacheReadRequest]
}

struct CacheReadRequest {
  var id: String
  var store: String
  var reference: CacheBodyReference
}

private func cacheReadSetInvalid() -> AdapterExecutionError {
  .init(.invalidInput, "invalid cache-exchange read-set request or readback")
}

func cacheReadPolicyKey(_ path: String) throws -> String {
  let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  guard FileManager.default.fileExists(atPath: canonical) else { return "path:" + canonical }
  let attributes = try FileManager.default.attributesOfItem(atPath: canonical)
  guard let device = attributes[.systemNumber] as? NSNumber,
    let inode = attributes[.systemFileNumber] as? NSNumber else { throw cacheReadSetInvalid() }
  return "inode:\(device):\(inode)"
}
