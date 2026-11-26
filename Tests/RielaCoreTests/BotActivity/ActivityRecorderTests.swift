import Foundation
import XCTest
@testable import RielaCore

final class ActivityRecorderTests: XCTestCase {
  private let at = Date(timeIntervalSince1970: 1_700_000_000)
  private let sessionId = "session"
  private let executionId = "execution"

  func testCoalescesTenChunksIntoOneFinalMessage() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotStore(sessionStoreRoot: root.path)
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    await start(recorder)

    let chunks = (0..<10).map { "chunk \($0) " }
    for (index, chunk) in chunks.enumerated() {
      await record(.message(messageId: "message", text: chunk, replace: false), in: recorder, offset: Double(index) / 10)
    }
    let beforeSettle = try store.activityPage(sessionId: sessionId, afterSequence: 0, limit: 20)
    XCTAssertEqual(beforeSettle.events.map(\.kind), [.stepStarted])

    await recorder.settle(sessionId: sessionId, executionId: executionId, reason: .completed, stepStatus: "completed", at: at.addingTimeInterval(1))
    let page = try store.activityPage(sessionId: sessionId, afterSequence: 0, limit: 20)
    XCTAssertEqual(page.events.map(\.kind), [.stepStarted, .message, .stepFinished, .settled])
    let message = try XCTUnwrap(page.events.first { $0.kind == .message })
    XCTAssertEqual(message.payload["messageId"], .string("message"))
    XCTAssertEqual(message.payload["text"], .string(chunks.joined()))
    XCTAssertEqual(message.payload["final"], .bool(true))
    XCTAssertEqual(page.state?.lastMessageLine, chunks.joined())
    XCTAssertNil(page.state?.currentExecutionId)
    XCTAssertEqual(page.activitySource, "acp")
  }

  func testStructuralEventFlushesTextFirst() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotStore(sessionStoreRoot: root.path)
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    await start(recorder)

    await record(.message(messageId: "message", text: "Opening the file", replace: false), in: recorder)
    await record(.toolCall(.init(toolCallId: "read", status: "pending")), in: recorder, offset: 0.1)

    let page = try store.activityPage(sessionId: sessionId, afterSequence: 1, limit: 10)
    XCTAssertEqual(page.events.map(\.seq), [2, 3])
    XCTAssertEqual(page.events.map(\.kind), [.message, .toolCall])
    XCTAssertEqual(page.events.first?.payload["text"], .string("Opening the file"))
    XCTAssertEqual(page.state?.toolCalls.first?.toolCallId, "read")
  }

  func testWholeMessageReplacesEarlierFlushedText() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotStore(sessionStoreRoot: root.path)
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    await start(recorder)
    await record(.message(messageId: "message", text: "Draft", replace: false), in: recorder)
    await record(.toolCall(.init(toolCallId: "read", status: "completed")), in: recorder, offset: 0.1)
    let initial = try store.activityPage(sessionId: sessionId)
    XCTAssertEqual(initial.events.first { $0.kind == .message }?.payload["text"], .string("Draft"))

    await record(.message(messageId: "message", text: "Updated", replace: true), in: recorder, offset: 0.2)
    await record(.message(messageId: "message", text: " result", replace: false), in: recorder, offset: 0.3)
    await recorder.settle(
      sessionId: sessionId, executionId: executionId, reason: .completed, stepStatus: "completed", at: at.addingTimeInterval(1)
    )

    let delta = try store.activityPage(sessionId: sessionId, afterSequence: initial.lastSequence)
    XCTAssertEqual(delta.events.map(\.kind), [.message, .stepFinished, .settled])
    XCTAssertEqual(delta.events.first?.seq, initial.lastSequence + 1)
    XCTAssertEqual(delta.events.first?.payload, [
      "messageId": .string("message"), "text": .string("Updated result"), "replace": .bool(true), "final": .bool(true)
    ])
    XCTAssertEqual(delta.state?.lastMessageLine, "Updated result")
  }

  func testSettlingFinalizesMessageAlreadyDeliveredBeforeStop() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotStore(sessionStoreRoot: root.path)
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    await start(recorder)
    await record(.message(messageId: "message", text: "Finished", replace: false), in: recorder)
    await record(.stop(stopReason: "end_turn", limited: false, limitedResetAt: nil), in: recorder, offset: 0.1)

    let interim = try store.activityPage(sessionId: sessionId)
    XCTAssertEqual(interim.events.map(\.kind), [.stepStarted, .message, .stop])
    XCTAssertEqual(interim.events.first { $0.kind == .message }?.payload["final"], .bool(false))
    await recorder.settle(
      sessionId: sessionId, executionId: executionId, reason: .completed, stepStatus: "completed", at: at.addingTimeInterval(1)
    )
    let delta = try store.activityPage(sessionId: sessionId, afterSequence: interim.lastSequence)
    XCTAssertEqual(delta.events.map(\.kind), [.message, .stepFinished, .settled])
    XCTAssertEqual(delta.events.first?.payload, ["messageId": .string("message"), "text": .string(""), "final": .bool(true)])
    XCTAssertEqual(delta.state?.lastMessageLine, "Finished")
  }

  func testTrimsOnlyEventHistoryAndMarksStaleCursors() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotStore(sessionStoreRoot: root.path)
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    await start(recorder)
    await record(.toolCall(.init(toolCallId: "still-open", status: "in_progress")), in: recorder)
    for index in 1...2_098 {
      await record(.notice(severity: "info", title: "Notice \(index)", description: nil), in: recorder, offset: Double(index))
    }

    let stalePage = try store.activityPage(sessionId: sessionId, afterSequence: 50, limit: 5_000)
    XCTAssertTrue(stalePage.truncated)
    XCTAssertEqual(stalePage.lastSequence, 2_100)
    XCTAssertEqual(stalePage.firstRetainedSequence, 101)
    XCTAssertEqual(stalePage.events.map(\.seq), Array(101...600))
    XCTAssertEqual(stalePage.state?.toolCalls.map(\.toolCallId), ["still-open"])
    XCTAssertEqual(stalePage.state?.toolCalls.first?.status, "inProgress")

    var retained = stalePage.events.map(\.seq)
    for cursor in [600, 1_100, 1_600] {
      let page = try store.activityPage(sessionId: sessionId, afterSequence: cursor, limit: 500)
      XCTAssertFalse(page.truncated)
      retained.append(contentsOf: page.events.map(\.seq))
    }
    XCTAssertEqual(retained, Array(101...2_100))
    let storedRows = try store.read { db in
      try db.query("SELECT seq FROM activity_events WHERE session_id = 'session'").count
    }
    XCTAssertEqual(storedRows, 2_000)
  }

  func testOversizeMessageIsCappedAtAValidUTF8Prefix() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotStore(sessionStoreRoot: root.path)
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    await start(recorder)

    let original = String(repeating: "幅🚀", count: 3_000)
    await record(.message(messageId: "message", text: original, replace: false), in: recorder)

    let page = try store.activityPage(sessionId: sessionId, afterSequence: 0, limit: 20)
    let message = try XCTUnwrap(page.events.first { $0.kind == .message })
    let truncated = try XCTUnwrap(message.payload["text"])
    guard case let .string(text) = truncated else {
      return XCTFail("Expected a text payload")
    }
    XCTAssertEqual(message.payload["truncated"], .bool(true))
    XCTAssertFalse(text.isEmpty)
    XCTAssertTrue(original.utf8.starts(with: text.utf8))
    XCTAssertLessThan(text.utf8.count, original.utf8.count)
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(message.payload).count, 8_192)
  }

  func testRecorderFailsClosedWhenSessionStoreRootIsAFile() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = Data("existing file".utf8)
    try existing.write(to: root)
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)

    await start(recorder)
    await record(.toolCall(.init(toolCallId: "read", status: "pending")), in: recorder)
    let outcome = await recorder.requestPermission(
      sessionId: sessionId,
      executionId: executionId,
      request: .init(options: [.init(optionId: "allow", name: "Allow", kind: "allow_once")]),
      waitMs: 0,
      deadline: nil
    )
    await recorder.settle(sessionId: sessionId, executionId: executionId, reason: .completed, stepStatus: "completed", at: at)

    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(try Data(contentsOf: root), existing)
  }

  func testConcurrentFanoutRecordingAndTimestampFormatting() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    let store = BotStore(sessionStoreRoot: root.path)

    await withTaskGroup(of: Void.self) { group in
      for branch in 0..<12 {
        group.addTask { [at] in
          let branchSession = "fanout-session-\(branch)"
          let branchExec = "exec-\(branch)"
          await recorder.stepStarted(
            sessionId: branchSession, executionId: branchExec, stepId: "step6", nodeId: "node6",
            backend: "codex-agent", requestedModel: "gpt-6.1-terra", at: at
          )
          for step in 0..<10 {
            _ = RoutineStore.timestamp(at.addingTimeInterval(Double(step)))
            await recorder.record(
              sessionId: branchSession,
              executionId: branchExec,
              update: .toolCall(.init(toolCallId: "tool-\(branch)-\(step)", title: "Tool \(step)", status: "completed")),
              at: at.addingTimeInterval(Double(step))
            )
          }
          await recorder.settle(
            sessionId: branchSession, executionId: branchExec, reason: .completed, stepStatus: "completed",
            at: at.addingTimeInterval(20)
          )
        }
      }
    }

    for branch in 0..<12 {
      let page = try store.activityPage(sessionId: "fanout-session-\(branch)", afterSequence: 0, limit: 50)
      XCTAssertGreaterThanOrEqual(page.events.count, 13)
      XCTAssertNil(page.state?.currentExecutionId)
    }
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  private func start(_ recorder: SQLiteWorkflowActivityRecorder) async {
    await recorder.stepStarted(
      sessionId: sessionId, executionId: executionId, stepId: "step", nodeId: "node",
      backend: "acp", requestedModel: nil, at: at
    )
  }

  private func record(
    _ update: AdapterActivityUpdate, in recorder: SQLiteWorkflowActivityRecorder, offset: Double = 0
  ) async {
    await recorder.record(sessionId: sessionId, executionId: executionId, update: update, at: at.addingTimeInterval(offset))
  }
}
