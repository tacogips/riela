import AgentRuntimeKit
import XCTest

final class AgentProcessContractsTests: XCTestCase {
  func testProcessRecordAndExecutionContracts() {
    let record = AgentProcessRecord(
      id: "process-1",
      pid: 123,
      command: "agent run",
      prompt: "hello",
      startedAt: "2026-07-02T00:00:00Z",
      status: .running,
      exitCode: nil,
      arguments: ["agent", "run"],
      input: ["hello"]
    )
    let completed = AgentProcessRecord(
      id: "process-1",
      pid: 123,
      command: "agent run",
      prompt: "hello",
      startedAt: "2026-07-02T00:00:00Z",
      status: .exited,
      exitCode: 0,
      arguments: ["agent", "run"],
      input: ["hello"]
    )

    XCTAssertEqual(record.status.rawValue, "running")
    XCTAssertNotEqual(record, completed)
    XCTAssertEqual(AgentProcessExecution(stdout: "ok", stderr: "", exitCode: 0).stdout, "ok")
    XCTAssertEqual(AgentProcessStatus.killed.rawValue, "killed")
  }
}
