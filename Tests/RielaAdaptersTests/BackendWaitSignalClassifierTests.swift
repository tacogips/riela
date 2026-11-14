import ACP
import Foundation
import RielaCore
import XCTest
@testable import RielaAdapters

final class BackendWaitSignalClassifierTests: XCTestCase {
  func testPendingToolCallUpdateProducesPresenceSignal() throws {
    let event = makeEvent(
      eventType: "tool_call_update",
      status: ACPToolCallStatus.pending.rawValue,
      title: "Allow calendar access"
    )

    let signal = try XCTUnwrap(TableBackendWaitSignalClassifier.default.classify(event, backend: .codexAgent))

    XCTAssertEqual(signal.eventType, "tool_call_update")
    XCTAssertEqual(signal.observedAt, event.at)
    XCTAssertEqual(signal.presence.traits, [.interactive, .userReachable])
    XCTAssertEqual(
      signal.presence.instructions,
      "Approve or answer the pending tool call 'Allow calendar access' on this host"
    )
  }

  func testCompletedToolCallDoesNotProduceSignal() {
    let event = makeEvent(eventType: "tool_call", status: ACPToolCallStatus.completed.rawValue, title: "Finished")
    XCTAssertNil(TableBackendWaitSignalClassifier.default.classify(event, backend: .codexAgent))
  }

  func testTextThatLooksLikeAWaitRequestIsIgnored() {
    let event = WorkflowBackendEventRecord(
      sequence: 1,
      at: Date(timeIntervalSinceReferenceDate: 10),
      eventType: "agent_message_chunk",
      content: "waiting for input",
      metadata: ["status": .string(ACPToolCallStatus.pending.rawValue)]
    )
    XCTAssertNil(TableBackendWaitSignalClassifier.default.classify(event, backend: .codexAgent))
  }

  func testOfficialSDKBackendDoesNotProduceSignal() {
    let event = makeEvent(eventType: "tool_call_update", status: ACPToolCallStatus.pending.rawValue, title: "Approve")
    XCTAssertNil(TableBackendWaitSignalClassifier.default.classify(event, backend: .officialOpenAISDK))
  }

  func testLatestSignalUsesFinalPersistedEventOnly() {
    let pending = makeEvent(eventType: "tool_call_update", status: ACPToolCallStatus.pending.rawValue, title: "Approve")
    let progress = WorkflowBackendEventRecord(
      sequence: 2,
      at: Date(timeIntervalSinceReferenceDate: 20),
      eventType: "agent_message_chunk",
      content: "Still working"
    )
    let classifier = TableBackendWaitSignalClassifier.default

    XCTAssertNil(classifier.latestSignal(in: [pending, progress], backend: .codexAgent))
    XCTAssertNotNil(classifier.latestSignal(in: [progress, pending], backend: .codexAgent))
    XCTAssertNil(classifier.latestSignal(in: [], backend: .codexAgent))
  }

  func testEmptyTableNeverClassifies() {
    let classifier = TableBackendWaitSignalClassifier(table: [:])
    let event = makeEvent(eventType: "tool_call_update", status: ACPToolCallStatus.pending.rawValue, title: "Approve")

    XCTAssertNil(classifier.classify(event, backend: .codexAgent))
    XCTAssertNil(classifier.latestSignal(in: [event], backend: .codexAgent))
  }

  private func makeEvent(eventType: String, status: String, title: String) -> WorkflowBackendEventRecord {
    WorkflowBackendEventRecord(
      sequence: 1,
      at: Date(timeIntervalSinceReferenceDate: 10),
      eventType: eventType,
      toolName: "tool fallback",
      metadata: ["status": .string(status), "title": .string(title)]
    )
  }
}
