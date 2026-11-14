import Foundation
import RielaCore

/// A private-worker stderr side channel. Only normalized operational metadata
/// crosses it; the source-output contract and gateway credentials stay private.
enum XGatewayUsageTransport {
  static let prefix = "riela-x-resource-usage:"
  private static let lock = NSLock()

  static func emit(observation: JSONValue, status: XGatewayUsageCacheExchange.Status) {
    guard ProcessInfo.processInfo.environment["RIELA_X_USAGE_EXPORT"] == "1" else { return }
    let value: JSONObject = ["data": .object(["extensions": .object([
      "resourceUsage": observation, "usageObservationStatus": .string(status.rawValue)
    ])])]
    guard let json = try? JSONValue.object(value).compactJSONString(), json.utf8.count <= 8_000_000 else { return }
    lock.withLock { try? FileHandle.standardError.write(contentsOf: Data((prefix + json + "\n").utf8)) }
  }

  static func consume(_ line: String, cache: XGatewayUsageCacheExchange) -> XGatewayUsageCacheExchange.Status? {
    guard line.hasPrefix(prefix), line.utf8.count <= 8_000_000 + prefix.utf8.count else { return nil }
    return cache.record(stdout: String(line.dropFirst(prefix.count)), stderr: "", environment: [:])
  }
}

final class XGatewayUsageExportCollector: @unchecked Sendable {
  private let cache: XGatewayUsageCacheExchange?
  private let lock = NSLock()
  private var statuses: [String: Int] = [:]
  init(cache: XGatewayUsageCacheExchange?) { self.cache = cache }
  func accept(_ line: String) {
    guard let cache, let status = XGatewayUsageTransport.consume(line, cache: cache) else { return }
    lock.withLock { statuses[status.rawValue, default: 0] += 1 }
  }
  var metadata: JSONObject {
    lock.withLock {
      ["cacheId": .string(XGatewayUsageCacheExchange.cacheId),
       "statuses": .object(statuses.mapValues { .integer(Int64($0)) })]
    }
  }
}
