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
  public var maxBufferRecords: Int
  public var legacyPayload: Bool
  public var traceContext: RielaTraceContext?
  public var autoFlushInterval: Duration?

  public init(
    enabled: Bool,
    surface: RielaTelemetrySurface,
    serviceName: String,
    endpoint: URL? = nil,
    resourceAttributes: [String: String] = [:],
    enabledSignals: Set<RielaTelemetrySignal> = [.traces, .logs, .metrics],
    maxBufferRecords: Int = 2_048,
    legacyPayload: Bool = false,
    traceContext: RielaTraceContext? = nil,
    autoFlushInterval: Duration? = .seconds(10)
  ) {
    self.enabled = enabled
    self.surface = surface
    self.serviceName = serviceName
    self.endpoint = endpoint
    self.resourceAttributes = resourceAttributes
    self.enabledSignals = enabledSignals
    self.maxBufferRecords = max(1, maxBufferRecords)
    self.legacyPayload = legacyPayload
    self.traceContext = traceContext
    self.autoFlushInterval = autoFlushInterval
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
    let maxBufferRecords = positiveInt(environment["RIELA_OTEL_MAX_BUFFER_RECORDS"]) ?? 2_048
    let legacyPayload = boolValue(environment["RIELA_OTEL_LEGACY_PAYLOAD"]) == true
    return RielaTelemetryConfiguration(
      enabled: enabled,
      surface: surface,
      serviceName: serviceName,
      endpoint: endpoint,
      resourceAttributes: resources,
      enabledSignals: signals,
      maxBufferRecords: maxBufferRecords,
      legacyPayload: legacyPayload,
      traceContext: RielaTraceContext.fromEnvironment(environment)
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
    "error_class", "error_code", "environment", "profile"
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
  private let traceId: String
  private let parentSpanId: String?
  private var spans: [RielaTelemetrySpan] = []
  private var logs: [RielaTelemetryLog] = []
  private var metrics: [RielaTelemetryMetric] = []
  private var droppedSpans = 0
  private var droppedLogs = 0
  private var droppedMetrics = 0
  private var consecutiveExportFailures = 0
  private var autoFlushTask: Task<Void, Never>?

  init(configuration: RielaTelemetryConfiguration, endpoint: URL) {
    self.configuration = configuration
    self.endpoint = endpoint
    let generatedContext = RielaTraceContext.generated()
    let context = configuration.traceContext ?? generatedContext
    self.traceId = traceIdValue(from: context.traceparent) ?? traceIdValue(from: generatedContext.traceparent) ?? randomHex(byteCount: 16)
    self.parentSpanId = configuration.traceContext.flatMap { spanIdValue(from: $0.traceparent) }
  }

  func recordSpan(_ span: RielaTelemetrySpan) {
    guard configuration.enabledSignals.contains(.traces) else {
      return
    }
    appendBounded(span, to: &spans, droppedCount: &droppedSpans)
    startAutoFlushIfNeeded()
  }

  func recordLog(_ log: RielaTelemetryLog) {
    guard configuration.enabledSignals.contains(.logs) else {
      return
    }
    appendBounded(log, to: &logs, droppedCount: &droppedLogs)
    startAutoFlushIfNeeded()
  }

  func recordMetric(_ metric: RielaTelemetryMetric) {
    guard configuration.enabledSignals.contains(.metrics) else {
      return
    }
    appendBounded(metric, to: &metrics, droppedCount: &droppedMetrics)
    startAutoFlushIfNeeded()
  }

  func flush(timeout: Duration) async {
    let spansToSend = spans
    let logsToSend = logs
    let metricsToSend = metrics
    let dropped = DroppedTelemetryCounts(spans: droppedSpans, logs: droppedLogs, metrics: droppedMetrics)
    let endpoint = self.endpoint
    let configuration = self.configuration
    let traceId = self.traceId
    let parentSpanId = self.parentSpanId
    spans.removeAll()
    logs.removeAll()
    metrics.removeAll()
    droppedSpans = 0
    droppedLogs = 0
    droppedMetrics = 0
    var outcomes: [TelemetryExportOutcome] = []
    await withTaskGroup(of: TelemetryExportOutcome.self) { group in
      var sendTasks = 0
      if !spansToSend.isEmpty {
        sendTasks += 1
        group.addTask {
          await sendTelemetry(
            .traces,
            records: .spans(spansToSend, traceId: traceId, parentSpanId: parentSpanId),
            endpoint: endpoint,
            configuration: configuration,
            dropped: dropped,
            timeout: timeout
          )
        }
      }
      if !logsToSend.isEmpty {
        sendTasks += 1
        group.addTask {
          await sendTelemetry(
            .logs,
            records: .logs(logsToSend),
            endpoint: endpoint,
            configuration: configuration,
            dropped: dropped,
            timeout: timeout
          )
        }
      }
      if !metricsToSend.isEmpty {
        sendTasks += 1
        group.addTask {
          await sendTelemetry(
            .metrics,
            records: .metrics(metricsToSend),
            endpoint: endpoint,
            configuration: configuration,
            dropped: dropped,
            timeout: timeout
          )
        }
      }
      guard sendTasks > 0 else {
        return
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return .failure("telemetry export timed out")
      }
      while let outcome = await group.next() {
        outcomes.append(outcome)
        if case .failure = outcome {
          group.cancelAll()
          break
        }
        if outcomes.count == sendTasks {
          group.cancelAll()
          break
        }
      }
    }
    recordExportOutcomes(outcomes)
  }

  private func appendBounded<T>(_ record: T, to records: inout [T], droppedCount: inout Int) {
    let overflowCount = records.count - configuration.maxBufferRecords + 1
    if overflowCount > 0 {
      records.removeFirst(overflowCount)
      droppedCount += overflowCount
    }
    records.append(record)
  }

  private func startAutoFlushIfNeeded() {
    guard autoFlushTask == nil, let interval = configuration.autoFlushInterval else {
      return
    }
    autoFlushTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self else {
          return
        }
        await self.flush(timeout: .seconds(2))
      }
    }
  }

  private func recordExportOutcomes(_ outcomes: [TelemetryExportOutcome]) {
    let failureMessages = outcomes.compactMap { outcome -> String? in
      if case let .failure(message) = outcome {
        return message
      }
      return nil
    }
    if let message = failureMessages.first {
      if consecutiveExportFailures == 0 {
        writeTelemetryWarning("failed: \(message)")
      }
      consecutiveExportFailures += 1
      return
    }
    if consecutiveExportFailures > 0 {
      writeTelemetryWarning("recovered")
    }
    consecutiveExportFailures = 0
  }
}

private enum TelemetryExportRecords: Sendable {
  case spans([RielaTelemetrySpan], traceId: String, parentSpanId: String?)
  case logs([RielaTelemetryLog])
  case metrics([RielaTelemetryMetric])
}

private enum TelemetryExportOutcome: Sendable {
  case success
  case failure(String)
}

private struct DroppedTelemetryCounts: Equatable, Sendable {
  var spans: Int
  var logs: Int
  var metrics: Int
}

private func sendTelemetry(
  _ signal: RielaTelemetrySignal,
  records: TelemetryExportRecords,
  endpoint: URL,
  configuration: RielaTelemetryConfiguration,
  dropped: DroppedTelemetryCounts,
  timeout: Duration
) async -> TelemetryExportOutcome {
  do {
    var request = URLRequest(url: endpoint.appendingPathComponent(signalPath(for: signal)))
    request.httpMethod = "POST"
    request.timeoutInterval = timeoutInterval(for: timeout)
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try telemetryBody(
      signal: signal,
      records: records,
      configuration: configuration,
      dropped: dropped
    )
    let (_, response) = try await URLSession.shared.data(for: request)
    if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
      return .failure("collector returned HTTP \(httpResponse.statusCode) for \(signal.rawValue)")
    }
    return .success
  } catch {
    return .failure(String(describing: error))
  }
}

private func telemetryBody(
  signal: RielaTelemetrySignal,
  records: TelemetryExportRecords,
  configuration: RielaTelemetryConfiguration,
  dropped: DroppedTelemetryCounts
) throws -> Data {
  if configuration.legacyPayload {
    return try legacyTelemetryBody(records: records, configuration: configuration, dropped: dropped)
  }
  let encoder = JSONEncoder.telemetryEncoder
  switch records {
  case let .spans(spans, traceId, parentSpanId):
    return try encoder.encode(OTLPTraceExportRequest(
      resourceSpans: [
        OTLPResourceSpans(
          resource: otlpResource(configuration: configuration, dropped: dropped),
          scopeSpans: [
            OTLPScopeSpans(scope: otlpScope(), spans: spans.map {
              OTLPSpan(
                traceId: traceId,
                spanId: randomHex(byteCount: 8),
                parentSpanId: parentSpanId,
                name: $0.name,
                startTimeUnixNano: unixNanoString($0.startedAt),
                endTimeUnixNano: unixNanoString($0.endedAt),
                attributes: otlpAttributes($0.attributes),
                status: OTLPStatus(code: $0.status == .error ? 2 : 1)
              )
            })
          ]
        )
      ]
    ))
  case let .logs(logs):
    return try encoder.encode(OTLPLogExportRequest(
      resourceLogs: [
        OTLPResourceLogs(
          resource: otlpResource(configuration: configuration, dropped: dropped),
          scopeLogs: [
            OTLPScopeLogs(scope: otlpScope(), logRecords: logs.map {
              OTLPLogRecord(
                timeUnixNano: unixNanoString($0.timestamp),
                severityText: $0.severity,
                body: OTLPAnyValue(stringValue: $0.name),
                attributes: otlpAttributes($0.attributes)
              )
            })
          ]
        )
      ]
    ))
  case let .metrics(metrics):
    return try encoder.encode(OTLPMetricExportRequest(
      resourceMetrics: [
        OTLPResourceMetrics(
          resource: otlpResource(configuration: configuration, dropped: dropped),
          scopeMetrics: [
            OTLPScopeMetrics(scope: otlpScope(), metrics: metrics.map {
              OTLPMetric(
                name: $0.name,
                gauge: OTLPGauge(dataPoints: [
                  OTLPNumberDataPoint(
                    timeUnixNano: unixNanoString($0.timestamp),
                    asDouble: $0.value,
                    attributes: otlpAttributes($0.attributes)
                  )
                ])
              )
            })
          ]
        )
      ]
    ))
  }
}

private func legacyTelemetryBody(
  records: TelemetryExportRecords,
  configuration: RielaTelemetryConfiguration,
  dropped: DroppedTelemetryCounts
) throws -> Data {
  let resourceAttributes = resourceAttributes(configuration: configuration, dropped: dropped)
  switch records {
  case let .spans(spans, _, _):
    return try JSONEncoder.telemetryEncoder.encode(OTLPLegacyPayload(
      serviceName: configuration.serviceName,
      surface: configuration.surface.rawValue,
      resourceAttributes: resourceAttributes,
      records: spans
    ))
  case let .logs(logs):
    return try JSONEncoder.telemetryEncoder.encode(OTLPLegacyPayload(
      serviceName: configuration.serviceName,
      surface: configuration.surface.rawValue,
      resourceAttributes: resourceAttributes,
      records: logs
    ))
  case let .metrics(metrics):
    return try JSONEncoder.telemetryEncoder.encode(OTLPLegacyPayload(
      serviceName: configuration.serviceName,
      surface: configuration.surface.rawValue,
      resourceAttributes: resourceAttributes,
      records: metrics
    ))
  }
}

private func signalPath(for signal: RielaTelemetrySignal) -> String {
  switch signal {
  case .traces:
    return "v1/traces"
  case .logs:
    return "v1/logs"
  case .metrics:
    return "v1/metrics"
  }
}

private func timeoutInterval(for duration: Duration) -> TimeInterval {
  let components = duration.components
  let seconds = TimeInterval(components.seconds)
  let fractionalSeconds = TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  return max(0.001, seconds + fractionalSeconds)
}

private struct OTLPLegacyPayload<Record: Encodable>: Encodable {
  var serviceName: String
  var surface: String
  var resourceAttributes: [String: String]
  var records: [Record]
}

private struct OTLPTraceExportRequest: Encodable {
  var resourceSpans: [OTLPResourceSpans]
}

private struct OTLPResourceSpans: Encodable {
  var resource: OTLPResource
  var scopeSpans: [OTLPScopeSpans]
}

private struct OTLPScopeSpans: Encodable {
  var scope: OTLPScope
  var spans: [OTLPSpan]
}

private struct OTLPSpan: Encodable {
  var traceId: String
  var spanId: String
  var parentSpanId: String?
  var name: String
  var startTimeUnixNano: String
  var endTimeUnixNano: String
  var attributes: [OTLPKeyValue]
  var status: OTLPStatus
}

private struct OTLPStatus: Encodable {
  var code: Int
}

private struct OTLPLogExportRequest: Encodable {
  var resourceLogs: [OTLPResourceLogs]
}

private struct OTLPResourceLogs: Encodable {
  var resource: OTLPResource
  var scopeLogs: [OTLPScopeLogs]
}

private struct OTLPScopeLogs: Encodable {
  var scope: OTLPScope
  var logRecords: [OTLPLogRecord]
}

private struct OTLPLogRecord: Encodable {
  var timeUnixNano: String
  var severityText: String
  var body: OTLPAnyValue
  var attributes: [OTLPKeyValue]
}

private struct OTLPMetricExportRequest: Encodable {
  var resourceMetrics: [OTLPResourceMetrics]
}

private struct OTLPResourceMetrics: Encodable {
  var resource: OTLPResource
  var scopeMetrics: [OTLPScopeMetrics]
}

private struct OTLPScopeMetrics: Encodable {
  var scope: OTLPScope
  var metrics: [OTLPMetric]
}

private struct OTLPMetric: Encodable {
  var name: String
  var gauge: OTLPGauge
}

private struct OTLPGauge: Encodable {
  var dataPoints: [OTLPNumberDataPoint]
}

private struct OTLPNumberDataPoint: Encodable {
  var timeUnixNano: String
  var asDouble: Double
  var attributes: [OTLPKeyValue]
}

private struct OTLPResource: Encodable {
  var attributes: [OTLPKeyValue]
}

private struct OTLPScope: Encodable {
  var name: String
}

private struct OTLPKeyValue: Encodable {
  var key: String
  var value: OTLPAnyValue
}

private struct OTLPAnyValue: Encodable {
  var stringValue: String?
  var doubleValue: Double?
}

private func otlpResource(configuration: RielaTelemetryConfiguration, dropped: DroppedTelemetryCounts) -> OTLPResource {
  OTLPResource(attributes: otlpAttributes(resourceAttributes(configuration: configuration, dropped: dropped)))
}

private func resourceAttributes(
  configuration: RielaTelemetryConfiguration,
  dropped: DroppedTelemetryCounts
) -> [String: String] {
  var attributes = RielaTelemetryRedactor.redactedAttributes(configuration.resourceAttributes)
  attributes["service.name"] = configuration.serviceName
  attributes["riela.surface"] = configuration.surface.rawValue
  if dropped.spans > 0 {
    attributes["riela.telemetry.dropped.spans"] = String(dropped.spans)
  }
  if dropped.logs > 0 {
    attributes["riela.telemetry.dropped.logs"] = String(dropped.logs)
  }
  if dropped.metrics > 0 {
    attributes["riela.telemetry.dropped.metrics"] = String(dropped.metrics)
  }
  return attributes
}

private func otlpScope() -> OTLPScope {
  OTLPScope(name: "riela")
}

private func otlpAttributes(_ attributes: [String: String]) -> [OTLPKeyValue] {
  attributes.sorted { $0.key < $1.key }.map { key, value in
    OTLPKeyValue(key: key, value: OTLPAnyValue(stringValue: value))
  }
}

private func unixNanoString(_ date: Date) -> String {
  let nanoseconds = max(0, date.timeIntervalSince1970 * 1_000_000_000)
  return String(Int64(nanoseconds.rounded()))
}

private func traceIdValue(from traceparent: String) -> String? {
  traceparentComponents(traceparent).traceId
}

private func spanIdValue(from traceparent: String) -> String? {
  traceparentComponents(traceparent).spanId
}

private func traceparentComponents(_ traceparent: String) -> (traceId: String?, spanId: String?) {
  let parts = traceparent.split(separator: "-").map(String.init)
  guard parts.count >= 4, parts[1].count == 32, parts[2].count == 16 else {
    return (nil, nil)
  }
  return (parts[1], parts[2])
}

private func writeTelemetryWarning(_ message: String) {
  FileHandle.standardError.write(Data("riela telemetry export \(message)\n".utf8))
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

private func positiveInt(_ value: String?) -> Int? {
  guard let value, let parsed = Int(value), parsed > 0 else {
    return nil
  }
  return parsed
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
