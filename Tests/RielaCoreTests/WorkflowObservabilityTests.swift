import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import RielaObservability
@testable import RielaCore

final class WorkflowObservabilityTests: XCTestCase {
  func testTelemetryConfigurationHonorsDisabledPrecedenceAndAliases() {
    let disabled = RielaTelemetryConfiguration.fromEnvironment(
      [
        "OTEL_SDK_DISABLED": "true",
        "RIELA_OTEL_ENABLED": "true",
        "RIELA_OTEL_ENDPOINT": "http://collector.test:4318"
      ],
      surface: .cli
    )

    XCTAssertFalse(disabled.enabled)

    let enabled = RielaTelemetryConfiguration.fromEnvironment(
      [
        "RIELA_OTEL_ENABLED": "true",
        "RIELA_OTEL_ENDPOINT": "http://collector.test:4318",
        "RIELA_OTEL_SERVICE_NAME": "custom-riela",
        "RIELA_OTEL_RESOURCE_ATTRIBUTES": "deployment.environment=test,profile=default",
        "RIELA_OTEL_LOGS_ENABLED": "false",
        "RIELA_OTEL_MAX_BUFFER_RECORDS": "17",
        "RIELA_OTEL_LEGACY_PAYLOAD": "true",
        "traceparent": "00-11111111111111111111111111111111-2222222222222222-01"
      ],
      surface: .app
    )

    XCTAssertTrue(enabled.enabled)
    XCTAssertEqual(enabled.endpoint?.absoluteString, "http://collector.test:4318")
    XCTAssertEqual(enabled.serviceName, "custom-riela")
    XCTAssertEqual(enabled.resourceAttributes["deployment.environment"], "test")
    XCTAssertFalse(enabled.enabledSignals.contains(.logs))
    XCTAssertTrue(enabled.enabledSignals.contains(.traces))
    XCTAssertEqual(enabled.maxBufferRecords, 17)
    XCTAssertTrue(enabled.legacyPayload)
    XCTAssertEqual(enabled.traceContext?.traceparent, "00-11111111111111111111111111111111-2222222222222222-01")
  }

  func testTelemetryRedactorRedactsSecretLikeAttributes() {
    let redacted = RielaTelemetryRedactor.redactedAttributes([
      "workflow.id": "workflow",
      "status": "completed",
      "OPENAI_API_KEY": "sk-secret-value",
      "prompt": "raw prompt text"
    ])

    XCTAssertEqual(redacted["workflow.id"], "workflow")
    XCTAssertEqual(redacted["status"], "completed")
    XCTAssertEqual(redacted["OPENAI_API_KEY"], "[redacted]")
    XCTAssertEqual(redacted["prompt"], "[redacted]")
  }

  func testWorkflowRunnerEmitsInMemoryTelemetryForWorkflowAndStep() async throws {
    let telemetry = InMemoryRielaTelemetry()
    let runner = DeterministicWorkflowRunner(
      adapter: TelemetryStaticAdapter(),
      telemetry: telemetry
    )

    _ = try await runner.run(
      DeterministicWorkflowRunRequest(
        workflow: WorkflowDefinition(
          workflowId: "telemetry-workflow",
          defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
          entryStepId: "worker",
          nodeRegistry: [WorkflowNodeRegistryRef(id: "worker", nodeFile: "worker.json")],
          steps: [WorkflowStepRef(id: "worker", nodeId: "worker", role: .worker)],
          nodes: []
        ),
        nodePayloads: [
          "worker": AgentNodePayload(
            id: "worker",
            executionBackend: .codexAgent,
            model: "gpt-5",
            promptTemplate: "hello"
          )
        ]
      )
    )

    let spans = await telemetry.spans()
    let metrics = await telemetry.metrics()

    XCTAssertTrue(spans.contains { $0.name == "riela.workflow.run" })
    XCTAssertTrue(spans.contains { $0.name == "riela.workflow.step" })
    XCTAssertTrue(metrics.contains { $0.name == "riela.workflow.run.complete.count" })
    XCTAssertTrue(metrics.contains { $0.name == "riela.workflow.step.count" })
    let runSpan = try XCTUnwrap(spans.first { $0.name == "riela.workflow.run" })
    let stepSpan = try XCTUnwrap(spans.first { $0.name == "riela.workflow.step" })
    XCTAssertEqual(runSpan.attributes["workflow.id"], "telemetry-workflow")
    XCTAssertLessThanOrEqual(runSpan.startedAt, stepSpan.startedAt)
    XCTAssertLessThanOrEqual(stepSpan.startedAt, stepSpan.endedAt)
    XCTAssertLessThanOrEqual(runSpan.startedAt, runSpan.endedAt)
  }

  func testOTLPExporterSendsRedactedSignalsToCollectorEndpoints() async throws {
    RecordingOTLPURLProtocol.reset()
    URLProtocol.registerClass(RecordingOTLPURLProtocol.self)
    defer { URLProtocol.unregisterClass(RecordingOTLPURLProtocol.self) }
    let telemetry = RielaTelemetryFactory.make(configuration: RielaTelemetryConfiguration(
      enabled: true,
      surface: .cli,
      serviceName: "riela-test",
      endpoint: try XCTUnwrap(URL(string: "http://collector.test:4318")),
      resourceAttributes: ["deployment.environment": "test"],
      traceContext: RielaTraceContext(traceparent: "00-11111111111111111111111111111111-2222222222222222-01"),
      autoFlushInterval: nil
    ))

    await telemetry.recordSpan(RielaTelemetrySpan(
      name: "riela.workflow.run",
      status: .ok,
      startedAt: Date(timeIntervalSince1970: 1),
      attributes: ["workflow.id": "workflow-a", "token": "secret-token"]
    ))
    await telemetry.recordLog(RielaTelemetryLog(
      name: "riela.workflow.started",
      attributes: ["workflow.id": "workflow-a", "prompt": "raw prompt"]
    ))
    await telemetry.recordMetric(RielaTelemetryMetric(
      name: "riela.workflow.run.complete.count",
      value: 1,
      attributes: ["status": "completed"]
    ))

    await telemetry.flush(timeout: .seconds(1))

    let requests = RecordingOTLPURLProtocol.requests()
    XCTAssertEqual(Set(requests.map(\.path)), Set(["/v1/traces", "/v1/logs", "/v1/metrics"]))
    XCTAssertEqual(requests.count, 3)
    for request in requests {
      let bodyText = String(data: try JSONSerialization.data(withJSONObject: request.body, options: [.sortedKeys]), encoding: .utf8)
      XCTAssertFalse(bodyText?.contains("secret-token") == true)
      XCTAssertFalse(bodyText?.contains("raw prompt") == true)
    }
    let traceRequest = try XCTUnwrap(requests.first { $0.path == "/v1/traces" })
    let resourceSpans = try XCTUnwrap(traceRequest.body["resourceSpans"] as? [[String: Any]])
    let traceResource = try XCTUnwrap(resourceSpans.first?["resource"] as? [String: Any])
    XCTAssertEqual(otlpAttribute("service.name", in: traceResource), "riela-test")
    XCTAssertEqual(otlpAttribute("riela.surface", in: traceResource), "cli")
    XCTAssertEqual(otlpAttribute("deployment.environment", in: traceResource), "test")
    let scopeSpans = try XCTUnwrap(resourceSpans.first?["scopeSpans"] as? [[String: Any]])
    let spans = try XCTUnwrap(scopeSpans.first?["spans"] as? [[String: Any]])
    let span = try XCTUnwrap(spans.first)
    XCTAssertEqual(span["traceId"] as? String, "11111111111111111111111111111111")
    XCTAssertEqual(span["parentSpanId"] as? String, "2222222222222222")
    XCTAssertNotNil(span["startTimeUnixNano"] as? String)
    XCTAssertNotNil(span["endTimeUnixNano"] as? String)

    let logRequest = try XCTUnwrap(requests.first { $0.path == "/v1/logs" })
    XCTAssertNotNil(logRequest.body["resourceLogs"])
    let metricRequest = try XCTUnwrap(requests.first { $0.path == "/v1/metrics" })
    XCTAssertNotNil(metricRequest.body["resourceMetrics"])
  }

  func testOTLPExporterBoundsBuffersAndReportsDroppedRecords() async throws {
    RecordingOTLPURLProtocol.reset()
    URLProtocol.registerClass(RecordingOTLPURLProtocol.self)
    defer { URLProtocol.unregisterClass(RecordingOTLPURLProtocol.self) }
    let telemetry = RielaTelemetryFactory.make(configuration: RielaTelemetryConfiguration(
      enabled: true,
      surface: .cli,
      serviceName: "riela-test",
      endpoint: try XCTUnwrap(URL(string: "http://collector.test:4318")),
      enabledSignals: [.logs],
      maxBufferRecords: 2,
      autoFlushInterval: nil
    ))

    await telemetry.recordLog(RielaTelemetryLog(name: "log-1"))
    await telemetry.recordLog(RielaTelemetryLog(name: "log-2"))
    await telemetry.recordLog(RielaTelemetryLog(name: "log-3"))
    await telemetry.flush(timeout: .seconds(1))

    let request = try XCTUnwrap(RecordingOTLPURLProtocol.requests().first)
    let resourceLogs = try XCTUnwrap(request.body["resourceLogs"] as? [[String: Any]])
    let resource = try XCTUnwrap(resourceLogs.first?["resource"] as? [String: Any])
    XCTAssertEqual(otlpAttribute("riela.telemetry.dropped.logs", in: resource), "1")
    let scopeLogs = try XCTUnwrap(resourceLogs.first?["scopeLogs"] as? [[String: Any]])
    let records = try XCTUnwrap(scopeLogs.first?["logRecords"] as? [[String: Any]])
    let names = records.compactMap { (($0["body"] as? [String: Any])?["stringValue"] as? String) }
    XCTAssertEqual(names, ["log-2", "log-3"])
  }

  func testOTLPExporterFlushHonorsTimeoutWhenCollectorDoesNotRespond() async throws {
    HangingOTLPURLProtocol.reset()
    URLProtocol.registerClass(HangingOTLPURLProtocol.self)
    defer { URLProtocol.unregisterClass(HangingOTLPURLProtocol.self) }
    let telemetry = RielaTelemetryFactory.make(configuration: RielaTelemetryConfiguration(
      enabled: true,
      surface: .cli,
      serviceName: "riela-test",
      endpoint: try XCTUnwrap(URL(string: "http://collector.test:4318")),
      resourceAttributes: [:],
      enabledSignals: [.traces],
      autoFlushInterval: nil
    ))

    await telemetry.recordSpan(RielaTelemetrySpan(
      name: "riela.workflow.run",
      status: .ok,
      startedAt: Date(timeIntervalSince1970: 1),
      attributes: ["workflow.id": "workflow-a"]
    ))

    let start = ContinuousClock.now
    await telemetry.flush(timeout: .milliseconds(50))
    let elapsed = start.duration(to: ContinuousClock.now)

    XCTAssertEqual(HangingOTLPURLProtocol.startedRequestCount(), 1)
    XCTAssertLessThan(elapsed, .seconds(1))
  }
}

private func otlpAttribute(_ key: String, in owner: [String: Any]) -> String? {
  guard let attributes = owner["attributes"] as? [[String: Any]] else {
    return nil
  }
  let attribute = attributes.first { $0["key"] as? String == key }
  return (attribute?["value"] as? [String: Any])?["stringValue"] as? String
}

private struct RecordedOTLPRequest {
  var path: String
  var body: [String: Any]
}

private final class RecordingOTLPURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private nonisolated(unsafe) static var recordedRequests: [RecordedOTLPRequest] = []

  static func reset() {
    lock.withLock {
      recordedRequests = []
    }
  }

  static func requests() -> [RecordedOTLPRequest] {
    lock.withLock { recordedRequests }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "collector.test"
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let data = request.httpBody ?? Self.data(from: request.httpBodyStream)
    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    Self.lock.withLock {
      Self.recordedRequests.append(RecordedOTLPRequest(path: request.url?.path ?? "", body: body))
    }
    let response = HTTPURLResponse(
      url: request.url ?? URL(fileURLWithPath: "/"),
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func data(from stream: InputStream?) -> Data {
    guard let stream else {
      return Data()
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else {
        break
      }
      data.append(buffer, count: count)
    }
    return data
  }
}

private final class HangingOTLPURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private nonisolated(unsafe) static var startedRequests = 0

  static func reset() {
    lock.withLock {
      startedRequests = 0
    }
  }

  static func startedRequestCount() -> Int {
    lock.withLock { startedRequests }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "collector.test"
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.lock.withLock {
      Self.startedRequests += 1
    }
  }

  override func stopLoading() {}
}

private struct TelemetryStaticAdapter: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["ok": .bool(true)]
    )
  }
}
