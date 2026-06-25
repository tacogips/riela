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
        "RIELA_OTEL_LOGS_ENABLED": "false"
      ],
      surface: .app
    )

    XCTAssertTrue(enabled.enabled)
    XCTAssertEqual(enabled.endpoint?.absoluteString, "http://collector.test:4318")
    XCTAssertEqual(enabled.serviceName, "custom-riela")
    XCTAssertEqual(enabled.resourceAttributes["deployment.environment"], "test")
    XCTAssertFalse(enabled.enabledSignals.contains(.logs))
    XCTAssertTrue(enabled.enabledSignals.contains(.traces))
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
    XCTAssertEqual(spans.first { $0.name == "riela.workflow.run" }?.attributes["workflow.id"], "telemetry-workflow")
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
      resourceAttributes: ["deployment.environment": "test"]
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
      XCTAssertEqual(request.body["serviceName"] as? String, "riela-test")
      XCTAssertEqual(request.body["surface"] as? String, "cli")
      let bodyText = String(data: try JSONSerialization.data(withJSONObject: request.body, options: [.sortedKeys]), encoding: .utf8)
      XCTAssertFalse(bodyText?.contains("secret-token") == true)
      XCTAssertFalse(bodyText?.contains("raw prompt") == true)
    }
  }
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
