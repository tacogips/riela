import Foundation
import RielaCore
import WebHooky
@testable import RielaCLI
import XCTest

final class EventLiveServeWebhookyTests: XCTestCase {
  func testWebhookyServeDispatchesStreamedRecordToBoundWorkflow() async throws {
    let eventRoot = try temporaryDirectory()
    try writeWebhookyEventConfig(eventRoot: eventRoot)
    let record = WebhookRecord(
      t: 1_754_438_400,
      fetched: false,
      payload: .object([
        "source": .string("wrike"),
        "events": .array([
          .object([
            "eventType": .string("TaskCreated"),
            "taskId": .string("TASK-91")
          ])
        ])
      ])
    )
    let workflowRunner = FakeEventWorkflowRunner(replyText: "", replyAs: "")
    let server = DefaultEventLiveServer(
      webhookyStreamer: FakeWebhookyStreamer(records: [record]),
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_WEBHOOKY_URL": "https://hooks.example.test",
      "TEST_WEBHOOKY_CREDENTIAL": "key-1:secret-1",
      "TEST_WEBHOOKY_FETCH_UUID": "fetch-uuid-1"
    ]) {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions(["--limit", "1"]),
        output: .json
      )
    }

    XCTAssertEqual(result.status, "ok")
    XCTAssertTrue(result.records.contains("processedEvents=1"))
    let requests = await workflowRunner.requests
    XCTAssertEqual(requests.map(\.workflowName), ["webhooky-flow"])
    guard case let .object(input)? = requests.first?.runtimeVariables["workflowInput"] else {
      return XCTFail("expected workflowInput object")
    }
    XCTAssertEqual(input["firstEventType"], .string("TaskCreated"))
    guard case let .object(payload)? = input["payload"] else {
      return XCTFail("expected payload object")
    }
    XCTAssertEqual(payload["source"], .string("wrike"))
  }

  func testWebhookyServeSkipsAlreadyFetchedRecordsByDefault() async throws {
    let eventRoot = try temporaryDirectory()
    try writeWebhookyEventConfig(eventRoot: eventRoot)
    let fetched = WebhookRecord(t: 1_754_438_400, fetched: true, payload: .object(["n": .number(1)]))
    let fresh = WebhookRecord(t: 1_754_438_401, fetched: false, payload: .object(["n": .number(2)]))
    let workflowRunner = FakeEventWorkflowRunner(replyText: "", replyAs: "")
    let server = DefaultEventLiveServer(
      webhookyStreamer: FakeWebhookyStreamer(records: [fetched, fresh]),
      workflowRunner: workflowRunner
    )

    let result = try await CLIRuntimeEnvironment.$overrides.withValue([
      "TEST_WEBHOOKY_URL": "https://hooks.example.test",
      "TEST_WEBHOOKY_CREDENTIAL": "key-1:secret-1",
      "TEST_WEBHOOKY_FETCH_UUID": "fetch-uuid-1"
    ]) {
      try await server.serve(
        eventRoot: eventRoot,
        target: nil,
        parsed: try ParsedParityOptions(["--limit", "1"]),
        output: .json
      )
    }

    XCTAssertEqual(result.status, "ok")
    let requests = await workflowRunner.requests
    XCTAssertEqual(requests.count, 1)
    guard case let .object(input)? = requests.first?.runtimeVariables["workflowInput"],
          case let .object(payload)? = input["payload"] else {
      return XCTFail("expected payload object")
    }
    XCTAssertEqual(payload["n"], .integer(2))
  }

  func testWebhookySourceValidatesEnvironmentAndCredentialShape() throws {
    let source = WebhookyStreamSource(
      id: "hooks",
      baseUrlEnv: "TEST_WEBHOOKY_URL",
      credentialEnv: "TEST_WEBHOOKY_CREDENTIAL",
      fetchUuidEnv: "TEST_WEBHOOKY_FETCH_UUID"
    )
    XCTAssertThrowsError(try source.validateEnvironment(environment: [:]))
    XCTAssertThrowsError(try source.validateEnvironment(environment: [
      "TEST_WEBHOOKY_URL": "https://hooks.example.test",
      "TEST_WEBHOOKY_CREDENTIAL": "missing-separator",
      "TEST_WEBHOOKY_FETCH_UUID": "fetch-uuid-1"
    ]))
    let resolved = try source.resolvedConnection(environment: [
      "TEST_WEBHOOKY_URL": "https://hooks.example.test",
      "TEST_WEBHOOKY_CREDENTIAL": "key-1:secret-1",
      "TEST_WEBHOOKY_FETCH_UUID": "fetch-uuid-1"
    ])
    XCTAssertEqual(resolved.apiKey, "key-1")
    XCTAssertEqual(resolved.apiSecret, "secret-1")
    XCTAssertEqual(resolved.fetchUUID, "fetch-uuid-1")
  }

  private func writeWebhookyEventConfig(eventRoot: URL) throws {
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindings = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try """
    {
      "id": "webhooky-live",
      "kind": "webhooky",
      "baseUrlEnv": "TEST_WEBHOOKY_URL",
      "credentialEnv": "TEST_WEBHOOKY_CREDENTIAL",
      "fetchUuidEnv": "TEST_WEBHOOKY_FETCH_UUID"
    }
    """.write(to: sources.appendingPathComponent("webhooky-live.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "webhooky-to-workflow",
      "sourceId": "webhooky-live",
      "workflowName": "webhooky-flow",
      "match": {"eventType": "webhook.record"},
      "inputMapping": {
        "mode": "template",
        "template": {
          "request": "webhook record received",
          "payload": "{{event.input.payload}}",
          "firstEventType": "{{event.input.payload.events.0.eventType}}",
          "receivedAt": "{{event.input.receivedAt}}"
        },
        "mirrorToHumanInput": false
      }
    }
    """.write(to: bindings.appendingPathComponent("webhooky-to-workflow.json"), atomically: true, encoding: .utf8)
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-event-live-webhooky-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }
}

private struct FakeWebhookyStreamer: WebhookyRecordStreaming {
  let records: [WebhookRecord]

  func stream(
    source: WebhookyStreamSource,
    environment: [String: String]
  ) throws -> AsyncThrowingStream<WebhookRecord, Error> {
    AsyncThrowingStream { continuation in
      for record in records {
        continuation.yield(record)
      }
      // Keep the stream open like a live socket; serve exits via --limit.
    }
  }
}
