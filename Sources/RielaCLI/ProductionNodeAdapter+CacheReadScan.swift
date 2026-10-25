import Foundation
import RielaCore
import RielaMemory

extension BuiltinWorkflowAddonResolver {
  /// Fill an available batch through missing/expired/oversized prefixes. This
  /// node never acknowledges work, advances a provider cursor or renews TTL.
  func executeCacheReadScan(_ input: WorkflowAddonExecutionInput, config: JSONObject,
                            deadline: Date?) throws -> AdapterExecutionOutput {
    guard Set(config.keys).isSubset(of: ["action", "stores", "requests", "startIndex", "maxHits",
                                        "maxExamined", "maxItemBytes", "maxOutputBytes"]),
      case let .object(stores)? = config["stores"], (1...16).contains(stores.count),
      case let .array(requests)? = config["requests"], requests.count <= 10_000,
      try JSONEncoder().encode(config).count <= RielaCacheStore.maximumFrameBytes - 8192 else { throw cacheScanInvalid() }
    func bound(_ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
      guard case let .integer(raw) = config[key] ?? .integer(Int64(value)), let result = Int(exactly: raw),
        range.contains(result) else { throw cacheScanInvalid() }
      return result
    }
    let start = try bound("startIndex", default: 0, range: 0...requests.count)
    let maximumHits = try bound("maxHits", default: 40, range: 1...10_000)
    let maximumExamined = try bound("maxExamined", default: 256, range: 1...1024)
    let maximumItem = try bound("maxItemBytes", default: 1_000_000, range: 1...8_000_000)
    let maximumOutput = min(try bound("maxOutputBytes", default: 7_991_808, range: 1024...8_000_000), 7_991_808)
    do {
      let plan = try cacheReadPlan(stores: stores, requests: requests, workflowId: input.workflowId)
      for request in plan.ordered {
        let row: JSONObject = ["id": .string(request.id), "status": .string("oversized")]
        guard try JSONEncoder().encode(row).count + 256 <= maximumOutput else { throw cacheScanInvalid() }
      }
      try Task.checkCancellation()
      if let deadline, deadline <= Date() { throw AdapterExecutionError(.timeout, "cache read scan deadline expired") }
      // Every reference, including the unread tail, was validated before any
      // configuration can release old protection or apply disposable LRU.
      for name in plan.groups.keys.sorted() {
        let exchange = plan.exchanges[name]!
        if !exchange.capacityProtection {
          _ = try exchange.store.reconcile(cacheId: exchange.cacheId, scope: exchange.scope, references: .array([]))
        }
      }
      for name in plan.groups.keys.sorted() {
        let exchange = plan.exchanges[name]!
        _ = try exchange.store.configure(cacheId: exchange.cacheId, policy: exchange.policy)
      }
      var results: [JSONValue] = [], index = start, hits = 0, bytes = 256
      var reason = "end"
      while index < plan.ordered.count {
        try Task.checkCancellation()
        if let deadline, deadline <= Date() { throw AdapterExecutionError(.timeout, "cache read scan deadline expired") }
        if results.count == maximumExamined { reason = "scan-limit"; break }
        if hits == maximumHits { reason = "hit-limit"; break }
        let request = plan.ordered[index], exchange = plan.exchanges[request.store]!
        let found: CacheBodyRead
        var oversized = false
        do {
          found = try exchange.get([request.reference], maxLookupBytes: min(maximumItem, maximumOutput) + 8192)
        } catch RielaCacheError.oversized {
          // The store checks byte metadata before loading large payload JSON.
          found = .init(); oversized = true
        }
        var row: JSONObject = ["id": .string(request.id)]
        var hit = false
        if oversized { row["status"] = .string("oversized")
        } else if let body = found.hits[request.reference.key] {
          let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(body))
          if try JSONEncoder().encode(payload).count > maximumItem {
            row["status"] = .string("oversized")
          } else {
            row["status"] = .string("hit"); row["payload"] = payload; hit = true
          }
        } else if found.expired.contains(request.reference.key) { row["status"] = .string("expired")
        } else if found.missing.contains(request.reference.key) { row["status"] = .string("missing")
        } else { throw cacheScanInvalid() }
        var charge = try JSONEncoder().encode(row).count + 1
        if hit && charge + 256 > maximumOutput {
          row.removeValue(forKey: "payload");row["status"] = .string("oversized");hit = false
          charge = try JSONEncoder().encode(row).count + 1
        }
        if bytes + charge > maximumOutput {
          // A retry starts at this unconsumed item, never after a lost hit.
          reason = "output-budget"; break
        }
        bytes += charge; results.append(.object(row)); index += 1
        if hit { hits += 1 }
      }
      let payload: JSONObject = ["results": .array(results), "nextIndex": .integer(Int64(index)),
        "examinedCount": .integer(Int64(results.count)), "hitCount": .integer(Int64(hits)),
        "complete": .bool(index == requests.count), "stopReason": .string(reason)]
      guard try JSONEncoder().encode(payload).count <= maximumOutput else { throw cacheScanInvalid() }
      return .init(provider: "riela-builtin-addon", model: input.addon.name,
                   promptText: "", completionPassed: true, payload: payload)
    } catch let error as RielaCacheError { throw cacheExchangeFailure(error) }
  }
}

private func cacheScanInvalid() -> AdapterExecutionError {
  .init(.invalidInput, "invalid cache-exchange read-scan request or readback")
}
