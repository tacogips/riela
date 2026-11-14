import Foundation
import RielaCore
import RielaEvents
@testable import RielaCLI
import XCTest

@discardableResult
func assertReadOnlyEventReceipt(eventRoot: URL, file: StaticString = #filePath, line: UInt = #line) throws -> PersistedEventReceipt {
  let urls = try FileManager.default.contentsOfDirectory(at: eventRoot.appendingPathComponent("receipts"), includingPropertiesForKeys: nil)
  XCTAssertEqual(urls.count, 1, file: file, line: line)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let receipt = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: XCTUnwrap(urls.first)))
  XCTAssertEqual(receipt.status, "skipped", file: file, line: line)
  XCTAssertEqual(receipt.reason, "read-only", file: file, line: line)
  XCTAssertNil(receipt.workflowExecutionId, file: file, line: line)
  XCTAssertFalse(receipt.duplicate, file: file, line: line)
  XCTAssertFalse(receipt.readOnlyTriggers?.isEmpty ?? true, file: file, line: line)
  XCTAssertEqual(receipt.readOnlyDiagnostics, [], file: file, line: line)
  return receipt
}

final class EventReadOnlyPolicyTests: XCTestCase {
  func testFlagAndBothEnvironmentSpellingsFailClosedAndCannotOverrideTrue() throws {
    let plain = try ParsedParityOptions([])
    XCTAssertFalse(try EventReadOnlyPolicy.isEnabled(parsed: plain, environment: [:]))
    for key in ["RIELA_EVENTS_READ_ONLY", "RIEL_EVENTS_READ_ONLY"] {
      for raw in ["1", "true", "YES", " on "] {
        XCTAssertTrue(try EventReadOnlyPolicy.isEnabled(parsed: plain, environment: [key: raw]))
      }
      for raw in ["0", "false", "NO", "off", ""] {
        XCTAssertFalse(try EventReadOnlyPolicy.isEnabled(parsed: plain, environment: [key: raw]))
        XCTAssertTrue(try EventReadOnlyPolicy.isEnabled(parsed: ParsedParityOptions(["--read-only"]), environment: [key: raw]))
      }
      XCTAssertThrowsError(try EventReadOnlyPolicy.isEnabled(parsed: plain, environment: [key: "maybe"]))
    }
    XCTAssertTrue(try EventReadOnlyPolicy.isEnabled(parsed: plain, environment: ["RIELA_EVENTS_READ_ONLY": "false", "RIEL_EVENTS_READ_ONLY": "true"]))
  }

  func testLongProviderIDReplayRetainsOriginalEvidenceWithoutClaimingExecution() async throws {
    let root = try eventReadOnlyTemporaryDirectory()
    let server = DefaultEventLiveServer()
    let eventID = String(repeating: "$provider:/long-id-", count: 30)
    let envelope = ExternalEventEnvelope(sourceId: "source", eventId: eventID, provider: "matrix", eventType: "chat.message", receivedAt: Date(timeIntervalSince1970: 10), input: ["text": .string("retained")])
    let trigger = EventDryRunTriggerSummary(bindingId: "binding", workflowName: "workflow", executionMode: .direct, input: envelope.input)
    XCTAssertTrue(try server.recordReadOnlyEventIfNeeded(
      envelope: envelope, triggerResult: EventDryRunResult(accepted: true, triggers: [trigger]),
      parsed: ParsedParityOptions(["--read-only"]), eventRoot: root
    ))
    let original = try assertReadOnlyEventReceipt(eventRoot: root)
    let runner = ScopedParityCommandRunner()
    XCTAssertEqual(runner.safeReceiptId(sourceId: "source", eventId: "short"), "event-c291cmNlAHNob3J0")
    let replayID = runner.safeReceiptId(sourceId: "source", eventId: eventID + "-replay")
    XCTAssertLessThanOrEqual(replayID.count, 128)
    XCTAssertEqual(replayID, runner.safeReceiptId(sourceId: "source", eventId: eventID + "-replay"))
    let replayed = await RielaCLIApplication().run([
      "events", "replay", original.receiptId, "--event-root", root.path,
      "--reason", "operator inspection", "--output", "json"
    ])
    XCTAssertEqual(replayed.exitCode, .success, replayed.stderr)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let originalURL = root.appendingPathComponent("receipts/" + original.receiptId + ".json")
    XCTAssertEqual(try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: originalURL)), original)
    let replayURL = root.appendingPathComponent("receipts/" + replayID + ".json")
    let replay = try decoder.decode(PersistedEventReceipt.self, from: Data(contentsOf: replayURL))
    XCTAssertEqual(replay.status, "dry-run")
    XCTAssertNil(replay.workflowExecutionId)
    XCTAssertEqual(replay.replayedFromReceiptId, original.receiptId)
    XCTAssertEqual(replay.envelope.input, envelope.input)
    XCTAssertEqual(replay.envelope.receivedAt, envelope.receivedAt)
    XCTAssertEqual(replay.readOnlyTriggers, [trigger])
  }

  func testCommonRunnerBoundaryRejectsReadOnlyEvenWithoutSourceGate() async throws {
    let runner = FakeEventWorkflowRunner(replyText: "must not send", replyAs: "bot")
    let server = DefaultEventLiveServer(workflowRunner: runner)
    do {
      _ = try await server.runEventWorkflow(EventWorkflowRunRequest(
        workflowName: "unused", runtimeVariables: [:], parsed: ParsedParityOptions(["--read-only"])
      ))
      XCTFail("Read-only workflow dispatch was allowed")
    } catch is EventReadOnlyDispatchBlocked {}
    let captured = await runner.requests
    XCTAssertTrue(captured.isEmpty)
  }

  func testReadOnlyReceiptRetainsFirstObservationAndMappingForInspection() async throws {
    let root = try eventReadOnlyTemporaryDirectory()
    let server = DefaultEventLiveServer()
    let envelope = ExternalEventEnvelope(sourceId: "source", eventId: "event", provider: "riela", eventType: "cron.tick", receivedAt: Date(timeIntervalSince1970: 10), input: [:])
    let trigger = EventDryRunTriggerSummary(bindingId: "binding", workflowName: "workflow", executionMode: .direct, input: ["request": .string("observed")])
    let result = EventDryRunResult(accepted: true, triggers: [trigger])
    let parsed = try ParsedParityOptions(["--read-only"])
    XCTAssertTrue(try server.recordReadOnlyEventIfNeeded(envelope: envelope, triggerResult: result, parsed: parsed, eventRoot: root, observedAt: Date(timeIntervalSince1970: 20)))
    let first = try assertReadOnlyEventReceipt(eventRoot: root)
    XCTAssertTrue(try server.recordReadOnlyEventIfNeeded(envelope: envelope, triggerResult: result, parsed: parsed, eventRoot: root, observedAt: Date(timeIntervalSince1970: 30)))
    let repeated = try assertReadOnlyEventReceipt(eventRoot: root)
    XCTAssertEqual(first, repeated)
    XCTAssertEqual(repeated.updatedAt, Date(timeIntervalSince1970: 20))
    XCTAssertEqual(repeated.envelope, envelope)
    XCTAssertEqual(repeated.readOnlyTriggers, [trigger])
    let listed = await RielaCLIApplication().run(["events", "list", "--event-root", root.path, "--output", "json"])
    XCTAssertEqual(listed.exitCode, .success, listed.stderr)
    XCTAssertTrue(listed.stdout.contains("status=skipped"))
  }
}

func eventReadOnlyTemporaryDirectory() throws -> URL {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/events-readonly/tests/" + UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}
