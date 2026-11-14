import Foundation
import RielaCore
import RielaMemory

/// A separate, bounded observation cache. Never treats local dedup as an invoice.
struct XGatewayUsageCacheExchange: Sendable {
  static let cacheId = "x-gateway-api-usage"
  static let scope = "observations"
  static let policy = CachePolicy(ttlSeconds: 35 * 86_400, maxBytes: 10 * 1024 * 1024)
  /// Largest gateway stdout/stderr envelope decoded for telemetry.
  static let maximumEnvelopeBytes = 8_000_000
  let store: RielaCacheStore
  private let clock: @Sendable () -> Date
  private let configuredScope: String?

  /// Direct construction for callers that already know the application scope
  /// (for example a private-workflow host); nil uses the credential fingerprint.
  init(scope: String?, environment: [String: String], clock: @escaping @Sendable () -> Date = { Date() }) throws {
    if let scope {
      guard scope.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else {
        throw AdapterExecutionError(.invalidInput, "X usageScope must be a stable application identifier")
      }
    }
    configuredScope = scope
    self.clock = clock
    store = RielaCacheStore(rootDirectory: XGatewayCacheRoot.path(environment: environment), clock: clock)
    _ = try? store.configure(cacheId: Self.cacheId, policy: Self.policy)
  }

  init?(input: WorkflowAddonExecutionInput, environment: [String: String],
        clock: @escaping @Sendable () -> Date = { Date() }) throws {
    guard let flag = input.addon.config?["usageCache"] else { return nil }
    guard case let .bool(enabled) = flag else {
      throw AdapterExecutionError(.invalidInput, "X usageCache must be true or false")
    }
    guard enabled else { return nil }
    var scope: String?
    if let value = input.addon.config?["usageScope"] {
      guard case let .string(text) = value else {
        throw AdapterExecutionError(.invalidInput, "X usageScope must be a stable application identifier")
      }
      scope = text
    }
    try self.init(scope: scope, environment: environment, clock: clock)
  }

  /// Compatibility initializer; the working directory does not affect the cache root.
  init?(input: WorkflowAddonExecutionInput, workingDirectory _: URL, environment: [String: String],
        clock: @escaping @Sendable () -> Date = { Date() }) throws {
    try self.init(input: input, environment: environment, clock: clock)
  }

  enum Status: String, Sendable { case stored, unavailable, unsupported, invalid }

  /// Decodes one JSON object within the shared envelope bound.
  static func decodeBoundedEnvelope(_ text: String) -> JSONObject? {
    guard !text.isEmpty, text.utf8.count <= maximumEnvelopeBytes else { return nil }
    return try? JSONDecoder().decode(JSONObject.self, from: Data(text.utf8))
  }

  /// Called before adapter validation, including a failed SDK/container result.
  func record(stdout: String, stderr: String, environment: [String: String]) -> Status {
    record(envelopes: [stdout, stderr].compactMap(Self.decodeBoundedEnvelope), environment: environment)
  }

  /// Records the first telemetry found in already-decoded envelopes.
  /// `nullObservationStatus` carries a sender's finite status when it forwarded
  /// no observation (only `invalid` is honoured; absence stays `unsupported`).
  func record(envelopes: [JSONObject], environment: [String: String], nullObservationStatus: Status? = nil,
              maximumResources: Int = XGatewayUsageObservation.maximumResources) -> Status {
    var telemetry: JSONValue?
    for envelope in envelopes {
      if case let .object(graphQL)? = envelope["data"], case let .object(ext)? = graphQL["extensions"] {
        telemetry = ext["resourceUsage"]
      }
      if case let .object(error)? = envelope["error"] { telemetry = error["resourceUsage"] ?? telemetry }
      if telemetry != nil { break }
    }
    var normalized = JSONValue.null
    var status = nullObservationStatus == .invalid ? Status.invalid : .unsupported
    if let telemetry, telemetry != .null {
      if let value = XGatewayUsageObservation.normalized(telemetry, maximumResources: maximumResources) {
        normalized = value; status = .stored
      } else { status = .invalid }
    }
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

/// Built-in X caches share one root: runtime `RIELA_CACHE_ROOT`, else the
/// current user's `.riela/cache`, so a workflow checkout change keeps them.
enum XGatewayCacheRoot {
  static func path(environment: [String: String]) -> String {
    if let root = nonEmptyString(environment["RIELA_CACHE_ROOT"]) { return root }
    let home = CLIRuntimeEnvironment.homeDirectory(environment: environment)
    return URL(fileURLWithPath: home).appendingPathComponent(".riela/cache").path
  }
}

struct XGatewayUsageObservation: Codable {
  /// SDK-side bound for one observation.
  static let maximumResources = 100_000
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
  var valid: Bool { valid(maximumResources: Self.maximumResources) }

  func valid(maximumResources: Int) -> Bool {
    version == 1 && (0...1_000_000).contains(httpResponses)
      && (0...httpResponses).contains(successfulResponses)
      && (0...1_000_000).contains(unclassifiedResources) && resources.count <= maximumResources
      && resources.allSatisfy { $0.idHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
        && $0.utcDay.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil }
  }

  /// Re-encodes telemetry through the strict schema so unknown fields are dropped;
  /// nil when the telemetry is malformed or exceeds `maximumResources`.
  static func normalized(_ telemetry: JSONValue, maximumResources: Int = maximumResources) -> JSONValue? {
    guard let data = try? telemetry.compactJSONString(),
          let value = try? JSONDecoder().decode(Self.self, from: Data(data.utf8)),
          value.valid(maximumResources: maximumResources),
          let encoded = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: encoded)
  }
}
