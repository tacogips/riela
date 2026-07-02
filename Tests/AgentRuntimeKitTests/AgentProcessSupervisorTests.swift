import AgentRuntimeKit
import Foundation
import XCTest

final class AgentProcessSupervisorTests: XCTestCase {
  func testSupervisorRunsInjectedExecutorAndFinishesRecord() {
    let supervisor = AgentProcessSupervisor<TestManagedProcess>(
      executableName: "agent",
      executor: { arguments, prompt, environment in
        XCTAssertEqual(arguments, ["agent", "run"])
        XCTAssertEqual(prompt, "hello")
        XCTAssertEqual(environment["TEST_ENV"], "1")
        return AgentProcessExecution(stdout: "ok", stderr: "", exitCode: 5)
      }
    )

    let result = supervisor.run(
      prompt: "hello",
      arguments: ["run"],
      environment: ["TEST_ENV": "1"],
      cwd: nil,
      makeManaged: TestManagedProcess.makeManaged,
      makeFailedManaged: TestManagedProcess.makeFailed
    )

    XCTAssertEqual(result.result.exitCode, 5)
    XCTAssertEqual(result.process.status, .exited)
    XCTAssertEqual(result.process.exitCode, 5)
    XCTAssertEqual(supervisor.get(id: result.process.id)?.status, .exited)
  }

  func testSupervisorWrapsInjectedExecutorOutputAsStream() {
    let supervisor = AgentProcessSupervisor<TestManagedProcess>(
      executableName: "agent",
      executor: { _, _, _ in
        AgentProcessExecution(stdout: "event:one\nevent:two\n", stderr: "ignored", exitCode: 0)
      }
    )

    let stream = supervisor.stream(
      prompt: "hello",
      arguments: ["run"],
      environment: [:],
      cwd: nil,
      makeOutputBuffers: { TestManagedProcess.makeBuffers() },
      makeManaged: TestManagedProcess.makeManaged,
      makeFailedManaged: TestManagedProcess.makeFailed
    )

    XCTAssertEqual(stream.collectLines(), ["event:one", "event:two"])
    XCTAssertEqual(stream.waitForCompletion(), 0)
    XCTAssertEqual(supervisor.get(id: stream.process.id)?.exitCode, 0)
  }
}

private final class TestManagedProcess: AgentManagedProcessRuntime, @unchecked Sendable {
  let agentOutputBuffers = AgentProcessOutputBuffers<String> { line in line }
  private let result: AgentProcessExecution

  init(result: AgentProcessExecution = AgentProcessExecution()) {
    self.result = result
  }

  func startDraining() {}

  func write(_ text: String) -> Bool {
    true
  }

  func closeInput() {}

  func terminate() {}

  func waitUntilExit() {}

  func execution() -> AgentProcessExecution {
    result
  }

  static func makeBuffers() -> AgentProcessOutputBuffers<String> {
    AgentProcessOutputBuffers<String> { line in line.hasPrefix("event:") ? line : nil }
  }

  static func makeManaged(
    process _: Process,
    input _: FileHandle,
    output _: FileHandle,
    error _: FileHandle
  ) -> TestManagedProcess {
    TestManagedProcess()
  }

  static func makeFailed(_ error: Error) -> TestManagedProcess {
    TestManagedProcess(result: AgentProcessExecution(stdout: "", stderr: error.localizedDescription, exitCode: 127))
  }
}
