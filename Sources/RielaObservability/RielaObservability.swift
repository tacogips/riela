import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RielaTelemetrySurface: String, Codable, Equatable, Sendable {
  case cli
  case serve
  case eventsServe = "events-serve"
  case app
}

public enum RielaTelemetrySignal: String, Codable, Equatable, Sendable {
  case traces
  case logs
  case metrics
}

public enum RielaTelemetryStatus: String, Codable, Equatable, Sendable {
  case ok
  case error
}

public struct RielaTelemetryConfiguration: Equatable, Sendable {
  public var enabled: Bool
  public var surface: RielaTelemetrySurface
  public var serviceName: String
  public var endpoint: URL?
  public var resourceAttributes: [String: String]
  public var enabledSignals: Set<RielaTelemetrySignal>

  public init(
    enabled: Bool,
    surface: RielaTelemetrySurface,
    serviceName: String,
    endpoint: URL? = nil,
    resourceAttributes: [String: String] = [:],
    enabledSignals: Set<RielaTelemetrySignal> = [.traces, .logs, .metrics]
  ) {
    self.enabled = enabled
    self.surface = surface
    self.serviceName = serviceName
    self.endpoint = endpoint
    self.resourceAttributes = resourceAttributes
    self.enabledSignals = enabledSignals
  }

  public static func fromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment,
    surface: RielaTelemetrySurface
  ) -> RielaTelemetryConfiguration {
    let disabled = boolValue(environment["OTEL_SDK_DISABLED"]) == true
    let endpointValue = firstNonEmpty(
      environment["OTEL_EXPORTER_OTLP_ENDPOINT"],
      environment["RIELA_OTEL_ENDPOINT"]
    )
    let endpoint = endpointValue.flatMap(URL.init(string:))
    let explicitlyEnabled = boolValue(environment["RIELA_OTEL_ENABLED"]) == true
    let enabled = !disabled && (explicitlyEnabled || endpoint != nil)
    let serviceName = firstNonEmpty(environment["OTEL_SERVICE_NAME"], environment["RIELA_OTEL_SERVICE_NAME"])
      ?? defaultServiceName(surface: surface)
    let resources = parseResourceAttributes(firstNonEmpty(
      environment["OTEL_RESOURCE_ATTRIBUTES"],
      environment["RIELA_OTEL_RESOURCE_ATTRIBUTES"]
    ))
    let signals = resolveEnabledSignals(environment)
    return RielaTelemetryConfiguration(
      enabled: enabled,
      surface: surface,
      serviceName: serviceName,
      endpoint: endpoint,
      resourceAttributes: resources,
      enabledSignals: signals
    )
  }
}

public struct RielaTelemetrySpan: Codable, Equatable, Sendable {
  public var name: String
  public var status: RielaTelemetryStatus
  public var startedAt: Date
  public var endedAt: Date
  public var attributes: [String: String]

  public init(
    name: String,
    status: RielaTelemetryStatus,
    startedAt: Date,
    endedAt: Date = Date(),
    attributes: [String: String] = [:]
  ) {
    self.name = name
    self.status = status
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.attributes = RielaTelemetryRedactor.redactedAttributes(attributes)
  }
}

public struct RielaTelemetryLog: Codable, Equatable, Sendable {
  public var name: String
  public var severity: String
  public var timestamp: Date
  public var attributes: [String: String]

  public init(name: String, severity: String = "INFO", timestamp: Date = Date(), attributes: [String: String] = [:]) {
    self.name = name
    self.severity = severity
    self.timestamp = timestamp
    self.attributes = RielaTelemetryRedactor.redactedAttributes(attributes)
  }
}

public struct RielaTelemetryMetric: Codable, Equatable, Sendable {
  public var name: String
  public var value: Double
  public var timestamp: Date
  public var attributes: [String: String]

  public init(name: String, value: Double, timestamp: Date = Date(), attributes: [String: String] = [:]) {
    self.name = name
    self.value = value
    self.timestamp = timestamp
    self.attributes = RielaTelemetryRedactor.redactedAttributes(attributes)
  }
}

public protocol RielaTelemetry: Sendable {
  func recordSpan(_ span: RielaTelemetrySpan) async
  func recordLog(_ log: RielaTelemetryLog) async
  func recordMetric(_ metric: RielaTelemetryMetric) async
  func flush(timeout: Duration) async
}

public struct NoOpRielaTelemetry: RielaTelemetry {
  public init() {}
  public func recordSpan(_ span: RielaTelemetrySpan) async {}
  public func recordLog(_ log: RielaTelemetryLog) async {}
  public func recordMetric(_ metric: RielaTelemetryMetric) async {}
  public func flush(timeout: Duration) async {}
}

public actor InMemoryRielaTelemetry: RielaTelemetry {
  private var storedSpans: [RielaTelemetrySpan] = []
  private var storedLogs: [RielaTelemetryLog] = []
  private var storedMetrics: [RielaTelemetryMetric] = []

  public init() {}

  public func recordSpan(_ span: RielaTelemetrySpan) {
    storedSpans.append(span)
  }

  public func recordLog(_ log: RielaTelemetryLog) {
    storedLogs.append(log)
  }

  public func recordMetric(_ metric: RielaTelemetryMetric) {
    storedMetrics.append(metric)
  }

  public func flush(timeout: Duration) {}

  public func spans() -> [RielaTelemetrySpan] {
    storedSpans
  }

  public func logs() -> [RielaTelemetryLog] {
    storedLogs
  }

  public func metrics() -> [RielaTelemetryMetric] {
    storedMetrics
  }
}

public enum RielaTelemetryFactory {
  public static func make(configuration: RielaTelemetryConfiguration) -> any RielaTelemetry {
    guard configuration.enabled, let endpoint = configuration.endpoint else {
      return NoOpRielaTelemetry()
    }
    return OTLPRielaTelemetryExporter(configuration: configuration, endpoint: endpoint)
  }
}

public enum RielaTelemetryRedactor {
  private static let secretKeyPattern = #"(?i)(token|secret|password|authorization|cookie|api[_-]?key|session)"#
  private static let allowedValueKeys = [
    "id", "name", "version", "surface", "command", "status", "kind", "type", "backend", "provider", "model",
    "attempt", "count", "duration_ms", "elapsed_ms", "host", "port", "path", "method", "enabled",
    "error_class", "error_code"
  ]
  private static let allowedValueKeyPattern = #"(?i)(^|\.)(\#(allowedValueKeys.joined(separator: "|")))$"#

  public static func redactedAttributes(_ attributes: [String: String]) -> [String: String] {
    attributes.reduce(into: [:]) { result, pair in
      guard isAllowedKey(pair.key), !looksSecret(pair.key), !looksSecret(pair.value) else {
        result[pair.key] = "[redacted]"
        return
      }
      result[pair.key] = bounded(pair.value)
    }
  }

  private static func isAllowedKey(_ key: String) -> Bool {
    key.range(of: allowedValueKeyPattern, options: .regularExpression) != nil
  }

  private static func looksSecret(_ value: String) -> Bool {
    value.range(of: secretKeyPattern, options: .regularExpression) != nil
  }

  private static func bounded(_ value: String) -> String {
    value.count > 256 ? String(value.prefix(256)) : value
  }
}

public struct RielaTraceContext: Equatable, Sendable {
  public var traceparent: String
  public var tracestate: String?
  public var baggage: String?

  public init(traceparent: String, tracestate: String? = nil, baggage: String? = nil) {
    self.traceparent = traceparent
    self.tracestate = tracestate
    self.baggage = baggage
  }

  public static func generated() -> RielaTraceContext {
    RielaTraceContext(traceparent: "00-\(randomHex(byteCount: 16))-\(randomHex(byteCount: 8))-01")
  }

  public static func fromEnvironment(_ environment: [String: String]) -> RielaTraceContext? {
    guard let traceparent = environment["traceparent"], !traceparent.isEmpty else {
      return nil
    }
    return RielaTraceContext(
      traceparent: traceparent,
      tracestate: environment["tracestate"],
      baggage: environment["baggage"]
    )
  }

  public func environmentValues() -> [String: String] {
    var values = ["traceparent": traceparent]
    if let tracestate, !tracestate.isEmpty {
      values["tracestate"] = tracestate
    }
    if let baggage, !baggage.isEmpty {
      values["baggage"] = baggage
    }
    return values
  }
}

public func telemetryChildProcessEnvironment(
  from environment: [String: String],
  traceContext: RielaTraceContext = .generated(),
  additionalResourceAttributes: [String: String] = [:]
) -> [String: String] {
  var values = environment.filter { key, _ in
    key.hasPrefix("OTEL_") || key.hasPrefix("RIELA_OTEL_")
  }
  values.merge(traceContext.environmentValues()) { _, propagated in propagated }
  values["OTEL_SERVICE_NAME"] = "riela-events-serve"
  values["RIELA_OTEL_SERVICE_NAME"] = "riela-events-serve"
  values["RIELA_OTEL_PARENT_SURFACE"] = "riela-app"
  let inheritedResources = parseResourceAttributes(firstNonEmpty(
    values["OTEL_RESOURCE_ATTRIBUTES"],
    values["RIELA_OTEL_RESOURCE_ATTRIBUTES"]
  ))
  let resourceAttributes = inheritedResources.merging(additionalResourceAttributes) { _, childValue in childValue }
  if !resourceAttributes.isEmpty {
    values["OTEL_RESOURCE_ATTRIBUTES"] = renderResourceAttributes(resourceAttributes)
  }
  return values
}

private func randomHex(byteCount: Int) -> String {
  (0..<byteCount).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
}

private actor OTLPRielaTelemetryExporter: RielaTelemetry {
  private let configuration: RielaTelemetryConfiguration
  private let endpoint: URL
  private var spans: [RielaTelemetrySpan] = []
  private var logs: [RielaTelemetryLog] = []
  private var metrics: [RielaTelemetryMetric] = []

  init(configuration: RielaTelemetryConfiguration, endpoint: URL) {
    self.configuration = configuration
    self.endpoint = endpoint
  }

  func recordSpan(_ span: RielaTelemetrySpan) {
    guard configuration.enabledSignals.contains(.traces) else {
      return
    }
    spans.append(span)
  }

  func recordLog(_ log: RielaTelemetryLog) {
    guard configuration.enabledSignals.contains(.logs) else {
      return
    }
    logs.append(log)
  }

  func recordMetric(_ metric: RielaTelemetryMetric) {
    guard configuration.enabledSignals.contains(.metrics) else {
      return
    }
    metrics.append(metric)
  }

  func flush(timeout: Duration) async {
    let spansToSend = spans
    let logsToSend = logs
    let metricsToSend = metrics
    let endpoint = self.endpoint
    let configuration = self.configuration
    spans.removeAll()
    logs.removeAll()
    metrics.removeAll()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await sendBestEffort(spansToSend, signalPath: "v1/traces", endpoint: endpoint, configuration: configuration) }
      group.addTask { await sendBestEffort(logsToSend, signalPath: "v1/logs", endpoint: endpoint, configuration: configuration) }
      group.addTask { await sendBestEffort(metricsToSend, signalPath: "v1/metrics", endpoint: endpoint, configuration: configuration) }
    }
  }
}

private func sendBestEffort<T: Encodable & Sendable>(
  _ records: [T],
  signalPath: String,
  endpoint: URL,
  configuration: RielaTelemetryConfiguration
) async {
  guard !records.isEmpty else {
    return
  }
  do {
    var request = URLRequest(url: endpoint.appendingPathComponent(signalPath))
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder.telemetryEncoder.encode(
      OTLPPayload(
        serviceName: configuration.serviceName,
        surface: configuration.surface.rawValue,
        resourceAttributes: configuration.resourceAttributes,
        records: records
      )
    )
    _ = try await URLSession.shared.data(for: request)
  } catch {
  }
}

private struct OTLPPayload<Record: Encodable>: Encodable {
  var serviceName: String
  var surface: String
  var resourceAttributes: [String: String]
  var records: [Record]
}

private extension JSONEncoder {
  static var telemetryEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

private func firstNonEmpty(_ values: String?...) -> String? {
  values.compactMap { value in
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }.first
}

private func boolValue(_ value: String?) -> Bool? {
  guard let value = value?.lowercased() else {
    return nil
  }
  switch value {
  case "1", "true", "yes", "on":
    return true
  case "0", "false", "no", "off":
    return false
  default:
    return nil
  }
}

private func defaultServiceName(surface: RielaTelemetrySurface) -> String {
  switch surface {
  case .cli:
    return "riela-cli"
  case .serve:
    return "riela-serve"
  case .eventsServe:
    return "riela-events-serve"
  case .app:
    return "riela-app"
  }
}

private func resolveEnabledSignals(_ environment: [String: String]) -> Set<RielaTelemetrySignal> {
  var signals: Set<RielaTelemetrySignal> = []
  if boolValue(environment["RIELA_OTEL_TRACES_ENABLED"]) != false {
    signals.insert(.traces)
  }
  if boolValue(environment["RIELA_OTEL_LOGS_ENABLED"]) != false {
    signals.insert(.logs)
  }
  if boolValue(environment["RIELA_OTEL_METRICS_ENABLED"]) != false {
    signals.insert(.metrics)
  }
  return signals
}

private func parseResourceAttributes(_ value: String?) -> [String: String] {
  guard let value else {
    return [:]
  }
  return value.split(separator: ",").reduce(into: [:]) { result, part in
    let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
    guard pair.count == 2 else {
      return
    }
    result[pair[0]] = pair[1]
  }
}

private func renderResourceAttributes(_ attributes: [String: String]) -> String {
  attributes.keys.sorted().map { key in
    "\(key)=\(attributes[key] ?? "")"
  }.joined(separator: ",")
}
