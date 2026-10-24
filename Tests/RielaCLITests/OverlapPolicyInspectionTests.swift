import Foundation
import RielaCore
import RielaEvents
@testable import RielaCLI
import XCTest

final class OverlapPolicyInspectionTests: XCTestCase {
  func testEventsValidateShowsPoliciesForEnabledCronBindingsOnly() async throws {
    let root = try temporaryDirectory()
    let config: [String: Any] = [
      "sources": [
        ["id": "cron", "kind": "cron", "enabled": true],
        ["id": "webhook", "kind": "webhook", "enabled": true, "path": "/hook"]
      ],
      "bindings": [
        bindingJSON(id: "a", sourceId: "cron", overlapPolicy: "queue", maxQueuedRuns: 2),
        bindingJSON(id: "b", sourceId: "cron"),
        bindingJSON(id: "c", sourceId: "webhook")
      ]
    ]
    try writeJSON(config, to: root.appendingPathComponent("events.json"))

    let result = await RielaCLIApplication().run([
      "events", "validate", "--event-root", root.path, "--output", "text"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("binding=a overlapPolicy=queue"), result.stdout)
    XCTAssertTrue(result.stdout.contains("binding=b overlapPolicy=inherit"), result.stdout)
    XCTAssertFalse(result.stdout.contains("binding=c overlapPolicy="), result.stdout)
  }

  func testEventsListShowsReasonAndBindingAndLeavesLegacySuffixesAbsent() async throws {
    let root = try temporaryDirectory()
    let receipts = root.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let envelope = ExternalEventEnvelope(
      sourceId: "cron", eventId: "event", provider: "riela", eventType: "cron.tick",
      receivedAt: Date(timeIntervalSince1970: 10), input: [:]
    )
    let receipt = PersistedEventReceipt(
      receiptId: "overlap", sourceId: "cron", eventId: "event", status: "skipped", duplicate: false,
      workflowExecutionId: nil, workflowName: "workflow", replayedFromReceiptId: nil,
      reason: "overlap-skip:b:session-1", updatedAt: Date(timeIntervalSince1970: 20), envelope: envelope,
      bindingId: "b"
    )
    let legacy = PersistedEventReceipt(
      receiptId: "legacy", sourceId: "cron", eventId: "legacy-event", status: "received", duplicate: false,
      workflowExecutionId: nil, workflowName: nil, replayedFromReceiptId: nil,
      reason: nil, updatedAt: Date(timeIntervalSince1970: 30), envelope: envelope
    )
    try writeReceipt(receipt, to: receipts.appendingPathComponent("overlap.json"))
    try writeReceipt(legacy, to: receipts.appendingPathComponent("legacy.json"))

    let listed = await RielaCLIApplication().run([
      "events", "list", "--event-root", root.path, "--status", "skipped", "--output", "text"
    ])
    XCTAssertEqual(listed.exitCode, .success, listed.stderr)
    XCTAssertTrue(listed.stdout.contains(" reason=overlap-skip:b:session-1 binding=b"), listed.stdout)
    XCTAssertFalse(listed.stdout.contains("receipt=legacy"), listed.stdout)

    let all = await RielaCLIApplication().run(["events", "list", "--event-root", root.path, "--output", "text"])
    XCTAssertEqual(all.exitCode, .success, all.stderr)
    let legacyLine = try XCTUnwrap(all.stdout.split(separator: "\n").first { $0.contains("receipt=legacy") })
    XCTAssertFalse(legacyLine.contains(" reason="), String(legacyLine))
    XCTAssertFalse(legacyLine.contains(" binding="), String(legacyLine))
  }

  func testReplayOfCronReceiptsIsPerBindingAndCarriesOverlapMetadata() async throws {
    let root = try temporaryDirectory()
    let receipts = root.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let envelope = ExternalEventEnvelope(
      sourceId: "cron", eventId: "cron-100", provider: "riela", eventType: "cron.tick",
      receivedAt: Date(timeIntervalSince1970: 100), input: [:]
    )
    var originalIds: [String: String] = [:]
    for (bindingId, policy) in [("binding-a", "queue"), ("binding-b", "skip")] {
      let receiptId = cronOverlapReceiptId(sourceId: "cron", eventId: "cron-100", bindingId: bindingId)
      originalIds[bindingId] = receiptId
      let receipt = PersistedEventReceipt(
        receiptId: receiptId, sourceId: "cron", eventId: "cron-100", status: "completed", duplicate: false,
        workflowExecutionId: "session-\(bindingId)", workflowName: "workflow", replayedFromReceiptId: nil,
        reason: nil, updatedAt: Date(timeIntervalSince1970: 100), envelope: envelope,
        bindingId: bindingId, overlapPolicy: policy, overlapPolicySource: "binding"
      )
      try writeReceipt(receipt, to: receipts.appendingPathComponent("\(receiptId).json"))
    }

    var replayIds: [String: String] = [:]
    for bindingId in ["binding-a", "binding-b"] {
      let replayed = await RielaCLIApplication().run([
        "events", "replay", try XCTUnwrap(originalIds[bindingId]), "--event-root", root.path, "--output", "text"
      ])
      XCTAssertEqual(replayed.exitCode, .success, replayed.stderr)
      replayIds[bindingId] = cronOverlapReceiptId(sourceId: "cron", eventId: "cron-100-replay", bindingId: bindingId)
      XCTAssertTrue(replayed.stdout.contains("receipt=\(replayIds[bindingId] ?? "")"), replayed.stdout)
    }
    XCTAssertNotEqual(replayIds["binding-a"], replayIds["binding-b"])
    let store = EventReceiptStore(eventRoot: root)
    for (bindingId, policy) in [("binding-a", "queue"), ("binding-b", "skip")] {
      let replay = try XCTUnwrap(store.load(try XCTUnwrap(replayIds[bindingId])))
      XCTAssertEqual(replay.replayedFromReceiptId, originalIds[bindingId])
      XCTAssertEqual(replay.bindingId, bindingId)
      XCTAssertEqual(replay.overlapPolicy, policy)
      XCTAssertEqual(replay.overlapPolicySource, "binding")
      XCTAssertEqual(replay.status, "replayed")
    }
  }

  func testReceiptFormatStaysBackwardReadableWithServeInstanceId() throws {
    // A receipt written before serveInstanceId existed still decodes.
    let legacy = Data("""
    {"duplicate":false,"envelope":{"eventId":"e","eventType":"cron.tick","input":{},"provider":"riela",
    "receivedAt":"2025-08-06T00:00:00Z","sourceId":"cron"},"eventId":"e","receiptId":"legacy-receipt",
    "sourceId":"cron","status":"completed","updatedAt":"2025-08-06T00:00:00Z"}
    """.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(PersistedEventReceipt.self, from: legacy)
    XCTAssertNil(decoded.serveInstanceId)
    XCTAssertEqual(decoded.status, "completed")

    // Without a stamp the key is omitted, so the on-disk format is unchanged.
    let root = try temporaryDirectory()
    let store = EventReceiptStore(eventRoot: root)
    try store.save(decoded)
    let raw = try String(contentsOf: store.url(for: "legacy-receipt"), encoding: .utf8)
    XCTAssertFalse(raw.contains("serveInstanceId"), raw)
    var stamped = decoded
    stamped.serveInstanceId = "123-abcd"
    try store.save(stamped)
    XCTAssertEqual(try store.load("legacy-receipt")?.serveInstanceId, "123-abcd")
  }

  func testEventsListIsNewestFirstSoLimitReturnsRecentReceipts() async throws {
    let root = try temporaryDirectory()
    let receipts = root.appendingPathComponent("receipts", isDirectory: true)
    try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
    let envelope = ExternalEventEnvelope(
      sourceId: "cron", eventId: "event", provider: "riela", eventType: "cron.tick",
      receivedAt: Date(timeIntervalSince1970: 10), input: [:]
    )
    // Receipt ids sort opposite to their age, like random cron hash ids can.
    for (receiptId, updatedAt) in [("a-oldest", 10.0), ("b-newest", 30.0), ("c-middle", 20.0)] {
      let receipt = PersistedEventReceipt(
        receiptId: receiptId, sourceId: "cron", eventId: receiptId, status: "skipped", duplicate: false,
        workflowExecutionId: nil, workflowName: "workflow", replayedFromReceiptId: nil, reason: nil,
        updatedAt: Date(timeIntervalSince1970: updatedAt), envelope: envelope
      )
      try writeReceipt(receipt, to: receipts.appendingPathComponent("\(receiptId).json"))
    }

    let listed = await RielaCLIApplication().run([
      "events", "list", "--event-root", root.path, "--limit", "2", "--output", "text"
    ])
    XCTAssertEqual(listed.exitCode, .success, listed.stderr)
    let ids = listed.stdout.split(separator: "\n").compactMap { line in
      line.split(separator: " ").first { $0.hasPrefix("receipt=") }.map { String($0.dropFirst("receipt=".count)) }
    }
    XCTAssertEqual(ids, ["b-newest", "c-middle"], listed.stdout)
  }

  func testWorkflowInspectShowsTriggerDefaultsInJSONAndTextAndOmitsAbsentValue() async throws {
    let withDefaults = try await inspectWorkflow(triggerDefaults: ["overlapPolicy": "queue", "maxQueuedRuns": 2])
    let summary = try JSONDecoder().decode(WorkflowInspectionSummary.self, from: Data(withDefaults.stdout.utf8))
    XCTAssertEqual(summary.triggerDefaults?.overlapPolicy, "queue")
    XCTAssertEqual(summary.triggerDefaults?.maxQueuedRuns, 2)
    let text = try await inspectWorkflow(triggerDefaults: ["overlapPolicy": "queue", "maxQueuedRuns": 2], output: .text)
    XCTAssertTrue(text.stdout.contains("triggerDefaults: overlapPolicy=queue maxQueuedRuns=2"), text.stdout)

    let withoutDefaults = try await inspectWorkflow(triggerDefaults: nil)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(withoutDefaults.stdout.utf8)) as? [String: Any])
    XCTAssertNil(json["triggerDefaults"])
    let absentText = try await inspectWorkflow(triggerDefaults: nil, output: .text)
    XCTAssertFalse(absentText.stdout.contains("triggerDefaults:"), absentText.stdout)
  }

  private func inspectWorkflow(
    triggerDefaults: [String: Any]?,
    output: WorkflowOutputFormat = .json
  ) async throws -> CLICommandResult {
    let root = try temporaryDirectory()
    let bundle = root.appendingPathComponent("worker-only-single-step", isDirectory: true)
    let example = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("examples/worker-only-single-step", isDirectory: true)
    try FileManager.default.copyItem(at: example, to: bundle)
    let workflowURL = bundle.appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
    workflow["triggerDefaults"] = triggerDefaults
    try writeJSON(workflow, to: workflowURL)
    return await RielaCLIApplication().run([
      "workflow", "inspect", "worker-only-single-step", "--workflow-definition-dir", bundle.path,
      "--output", output.rawValue
    ])
  }

  private func bindingJSON(
    id: String,
    sourceId: String,
    overlapPolicy: String? = nil,
    maxQueuedRuns: Int? = nil
  ) -> [String: Any] {
    var binding: [String: Any] = [
      "id": id,
      "sourceId": sourceId,
      "workflowName": "workflow",
      "inputMapping": ["mode": "event-input"]
    ]
    binding["overlapPolicy"] = overlapPolicy
    binding["maxQueuedRuns"] = maxQueuedRuns
    return binding
  }

  private func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(
        "tmp/schedule-overlap-policy-20261021-session-471/overlap-03-inspection/fixtures/\(UUID().uuidString)",
        isDirectory: true
      )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: url)
  }

  private func writeReceipt(_ receipt: PersistedEventReceipt, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(receipt).write(to: url)
  }
}
