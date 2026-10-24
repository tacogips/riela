import Foundation
import RielaCore
import RielaMemory

/// A separate, bounded observation cache. Never treats local dedup as an invoice.
struct XGatewayUsageCacheExchange: Sendable {
  static let cacheId = "x-gateway-api-usage"
  static let scope = "observations"
  static let policy = CachePolicy(ttlSeconds: 35 * 86_400, maxBytes: 10 * 1024 * 1024)
  let store: RielaCacheStore
  private let clock: @Sendable () -> Date
  private let configuredScope: String?

  init?(input: WorkflowAddonExecutionInput, workingDirectory: URL, environment: [String: String],
        clock: @escaping @Sendable () -> Date = { Date() }) throws {
    guard let flag = input.addon.config?["usageCache"] else { return nil }
    guard case let .bool(enabled) = flag else {
      throw AdapterExecutionError(.invalidInput, "X usageCache must be true or false")
    }
    guard enabled else { return nil }
    if let value = input.addon.config?["usageScope"] {
      guard case let .string(text) = value, text.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else {
        throw AdapterExecutionError(.invalidInput, "X usageScope must be a stable application identifier")
      }
      configuredScope = text
    } else { configuredScope = nil }
    let home = CLIRuntimeEnvironment.homeDirectory(environment: environment)
    let root = nonEmptyString(environment["RIELA_CACHE_ROOT"])
      ?? URL(fileURLWithPath: home).appendingPathComponent(".riela/cache").path
    self.clock = clock
    store = RielaCacheStore(rootDirectory: root, clock: clock)
    _ = try? store.configure(cacheId: Self.cacheId, policy: Self.policy)
  }

  enum Status: String { case stored, unavailable, unsupported, invalid }

  /// Called before adapter validation, including a failed SDK/container result.
  func record(stdout: String, stderr: String, environment: [String: String]) -> Status {
    let candidates = [stdout, stderr].compactMap { text -> JSONObject? in
      guard text.utf8.count <= 8_000_000 else { return nil }
      return try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8))
    }
    var telemetry: JSONValue?
    for envelope in candidates {
      if case let .object(graphQL)? = envelope["data"], case let .object(ext)? = graphQL["extensions"] {
        telemetry = ext["resourceUsage"]
      }
      if case let .object(error)? = envelope["error"] { telemetry = error["resourceUsage"] ?? telemetry }
      if telemetry != nil { break }
    }
    var observation: Observation?
    var status = Status.unsupported
    if let telemetry, telemetry != .null {
      if let data = try? telemetry.compactJSONString(),
         let value = try? JSONDecoder().decode(Observation.self, from: Data(data.utf8)), value.valid {
        observation = value; status = .stored
      } else { status = .invalid }
    }
    let normalized = observation.flatMap { value in
      (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    } ?? .null
    XGatewayUsageTransport.emit(observation: normalized, status: status)
    do {
      let identity = configuredScope ?? environment["X_GW_CONSUMER_KEY"] ?? environment["X_GW_APP_TOKEN"] ?? environment["X_GW_TOKEN"]
      guard let identity, !identity.isEmpty else { return .unavailable }
      let scope = JSONCanonical.sha256Hex(Data(identity.utf8))
      let timestamp = ISO8601DateFormatter().string(from: clock())
      let scopeKind = configuredScope != nil ? "configured-application" : "credential"
      let entry: JSONObject = ["recordedAt": .string(timestamp), "applicationScope": .string(scope),
        "scopeKind": .string(scopeKind), "observation": normalized, "telemetryStatus": .string(status.rawValue)]
      _ = try store.put(cacheId: Self.cacheId, scope: Self.scope,
        entries: [CachePut(key: UUID().uuidString, fetchedAt: timestamp, payload: try memoryJSONValue(from: .object(entry)))])
      return status
    } catch { return .unavailable }
  }

  typealias Observation = XGatewayUsageObservation
}

struct XGatewayUsageObservation: Codable {
  enum Basis: String, Codable { case upstreamResponse = "upstream-response" }
  enum BillingStatus: String, Codable { case notReported = "not-reported" }
  enum Kind: String, Codable { case post, user, media, other }
  struct Resource: Codable {
    let kind: Kind
    let idHash: String
    let utcDay: String
  }
  let version: Int
  let basis: Basis
  let billingStatus: BillingStatus
  let httpResponses: Int
  let successfulResponses: Int
  let unclassifiedResources: Int
  let resources: [Resource]
  var valid: Bool {
    version == 1 && (0...1_000_000).contains(httpResponses)
      && (0...httpResponses).contains(successfulResponses)
      && (0...1_000_000).contains(unclassifiedResources) && resources.count <= 100_000
      && resources.allSatisfy { $0.idHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        && $0.utcDay.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil }
  }
}
