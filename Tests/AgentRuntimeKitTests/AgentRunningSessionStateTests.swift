import AgentRuntimeKit
import Foundation
import XCTest

final class AgentRunningSessionStateTests: XCTestCase {
  func testRunningSessionStateMergesChunksAndRefreshesSessionId() {
    let buffers = AgentProcessOutputBuffers<String> { line in line }
    buffers.appendStdout(Data("session:next\nmessage\n".utf8))
    let state = AgentRunningSessionState(
      sessionId: "initial",
      processRecord: processRecord(),
      streamResult: AgentExecStreamResult(
        process: processRecord(),
        lines: AgentRolloutLineStream(buffers: buffers),
        completion: AgentProcessCompletion { 0 }
      ),
      existingLines: ["message"],
      streamGranularity: "event",
      resumeBackfill: { includeFinal in includeFinal ? ["final"] : [] },
      sessionIdResolver: { lines in
        lines.first { $0.hasPrefix("session:") }?.replacingOccurrences(of: "session:", with: "")
      },
      lineDeduplicator: { lines in
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
      },
      streamChunker: { lines, _, sessionId in lines.map { "\(sessionId):\($0)" } }
    )

    XCTAssertEqual(state.messages(), ["next:message", "next:session:next"])
    XCTAssertEqual(state.sessionId, "next")

    let completion = state.waitForCompletion()
    XCTAssertTrue(completion.success)
    XCTAssertEqual(completion.exitCode, 0)
    XCTAssertEqual(completion.messageCount, 3)
    XCTAssertEqual(completion.lines, ["next:message", "next:session:next", "next:final"])
    XCTAssertEqual(state.getState()["status"], "completed")
  }

  func testRunningSessionStateCancelTerminatesAndReports130() {
    let buffers = AgentProcessOutputBuffers<String> { line in line }
    let terminated = LockedFlag()
    let state = AgentRunningSessionState(
      sessionId: "session",
      processRecord: processRecord(),
      streamResult: AgentExecStreamResult(
        process: processRecord(),
        lines: AgentRolloutLineStream(buffers: buffers),
        completion: AgentProcessCompletion { 9 }
      ),
      terminateProcess: {
        terminated.set()
        return true
      },
      sessionIdResolver: { _ in nil },
      lineDeduplicator: { $0 },
      streamChunker: { lines, _, _ in lines }
    )

    let completion = state.cancel()
    XCTAssertTrue(terminated.value)
    XCTAssertFalse(completion.success)
    XCTAssertEqual(completion.exitCode, 130)
    XCTAssertEqual(state.getState()["status"], "completed")
  }
}

private func processRecord() -> AgentProcessRecord {
  AgentProcessRecord(
    id: UUID().uuidString,
    pid: 42,
    command: "agent run",
    prompt: "hello",
    startedAt: "2026-07-02T00:00:00Z",
    status: .running,
    arguments: ["agent", "run"]
  )
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue = false

  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return storedValue
  }

  func set() {
    lock.lock()
    storedValue = true
    lock.unlock()
  }
}
