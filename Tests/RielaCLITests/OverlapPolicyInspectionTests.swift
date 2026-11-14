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
