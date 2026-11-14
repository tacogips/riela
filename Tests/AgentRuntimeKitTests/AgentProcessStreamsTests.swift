import AgentRuntimeKit
import Foundation
import XCTest

final class AgentProcessStreamsTests: XCTestCase {
  func testRolloutLineStreamAdvancesCursorAndKeepsSnapshot() {
    let buffers = AgentProcessOutputBuffers<String> { line in
      line.hasPrefix("event:") ? line : nil
    }
    let stream = AgentRolloutLineStream(buffers: buffers)

    buffers.appendStdout(Data("event:one\nignored\nevent:two\n".utf8))
    XCTAssertEqual(stream.next(timeout: 0.001), "event:one")
    XCTAssertEqual(stream.next(timeout: 0.001), "event:two")
    XCTAssertNil(stream.next(timeout: 0.001))
    XCTAssertEqual(stream.snapshot(), ["event:one", "event:two"])
  }

  func testProcessCompletionCachesExitCode() {
    var waitCount = 0
    let completion = AgentProcessCompletion {
      waitCount += 1
      return 42
    }

    XCTAssertEqual(completion.wait(), 42)
    XCTAssertEqual(completion.wait(), 42)
    XCTAssertEqual(waitCount, 1)
  }

  func testExecStreamResultWaitsBeforeCollectingLines() {
    let buffers = AgentProcessOutputBuffers<String> { line in line }
    let stream = AgentRolloutLineStream(buffers: buffers)
    let process = AgentProcessRecord(
      id: "process-1",
      pid: 123,
      command: "agent run",
      prompt: "hello",
      startedAt: "2026-07-02T00:00:00Z",
      status: .running,
      arguments: ["agent", "run"]
    )
    var waitCount = 0
    let result = AgentExecStreamResult(
      process: process,
      lines: stream,
      completion: AgentProcessCompletion {
        waitCount += 1
        buffers.appendStdout(Data("event:done\n".utf8))
        buffers.finishStdout()
        return 7
      }
    )

    XCTAssertEqual(result.waitForCompletion(), 7)
    XCTAssertEqual(result.collectLines(), ["event:done"])
    XCTAssertEqual(waitCount, 1)
    XCTAssertEqual(result.process.id, "process-1")
  }
}
