import Foundation
import RielaAddonSupport
import RielaCore

/// A private-worker stderr side channel. Only normalized operational metadata
/// crosses it; the source-output contract and gateway credentials stay private.
/// The host bounds what a guest can push through it: line size, resources per
/// record, and records per run (`XGatewayUsageExportCollector`).
enum XGatewayUsageTransport {
  static let prefix = "riela-x-resource-usage:"
  /// Largest accepted marker line, prefix included.
  static let maximumLineBytes = 2_000_000
  /// Resources accepted in one forwarded observation; larger ones are recorded as invalid.
  static let maximumResourcesPerRecord = 10_000
  private static let lock = NSLock()

  static func emit(observation: JSONValue, status: XGatewayUsageCacheExchange.Status) {
    guard ProcessInfo.processInfo.environment["RIELA_X_USAGE_EXPORT"] == "1" else { return }
    var observation = observation
    var status = status
    if case let .object(value) = observation, case let .array(resources)? = value["resources"],
       resources.count > maximumResourcesPerRecord {
      observation = .null
      status = .invalid
    }
    guard let json = line(observation: observation, status: status)
            ?? line(observation: .null, status: .invalid) else { return }
    lock.withLock { try? FileHandle.standardError.write(contentsOf: Data((json + "\n").utf8)) }
  }

  private static func line(observation: JSONValue, status: XGatewayUsageCacheExchange.Status) -> String? {
    let value: JSONObject = ["data": .object(["extensions": .object([
      "resourceUsage": observation, "usageObservationStatus": .string(status.rawValue)
    ])])]
    guard let json = try? JSONValue.object(value).compactJSONString() else { return nil }
    let line = prefix + json
    return line.utf8.count <= maximumLineBytes ? line : nil
  }

  static func consume(_ line: String, cache: XGatewayUsageCacheExchange) -> XGatewayUsageCacheExchange.Status? {
    guard line.hasPrefix(prefix), line.utf8.count <= maximumLineBytes else { return nil }
    guard let envelope = XGatewayUsageCacheExchange.decodeBoundedEnvelope(String(line.dropFirst(prefix.count))) else {
      // A marker that is not one JSON object is malformed telemetry, not zero usage.
      return cache.record(envelopes: [], environment: [:], nullObservationStatus: .invalid)
    }
    var reported: XGatewayUsageCacheExchange.Status?
    if case let .object(graphQL)? = envelope["data"], case let .object(extensions)? = graphQL["extensions"],
       let status = nonEmptyString(extensions["usageObservationStatus"]) {
      reported = XGatewayUsageCacheExchange.Status(rawValue: status)
    }
    return cache.record(envelopes: [envelope], environment: [:], nullObservationStatus: reported,
      maximumResources: maximumResourcesPerRecord)
  }
}

final class XGatewayUsageExportCollector: @unchecked Sendable {
  /// Marker records stored per private-workflow run; later markers are counted, not stored.
  static let maximumRecordsPerRun = 256
  private let cache: XGatewayUsageCacheExchange?
  private let maximumRecords: Int
  private let lock = NSLock()
  private var statuses: [String: Int] = [:]
  private var admitted = 0
  private var dropped = 0

  init(cache: XGatewayUsageCacheExchange?, maximumRecords: Int = XGatewayUsageExportCollector.maximumRecordsPerRun) {
    self.cache = cache
    self.maximumRecords = maximumRecords
  }

  func accept(_ line: String) {
    guard let cache, line.hasPrefix(XGatewayUsageTransport.prefix) else { return }
    let allowed: Bool = lock.withLock {
      guard admitted < maximumRecords else { dropped += 1; return false }
      admitted += 1
      return true
    }
    guard allowed, let status = XGatewayUsageTransport.consume(line, cache: cache) else { return }
    lock.withLock { statuses[status.rawValue, default: 0] += 1 }
  }

  var metadata: JSONObject {
    lock.withLock {
      var value: JSONObject = ["cacheId": .string(XGatewayUsageCacheExchange.cacheId),
       "statuses": .object(statuses.mapValues { .integer(Int64($0)) })]
      if dropped > 0 { value["droppedRecords"] = .integer(Int64(dropped)) }
      return value
    }
  }
}
