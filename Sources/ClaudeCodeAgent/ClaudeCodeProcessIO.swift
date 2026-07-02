import AgentRuntimeKit
import Foundation

final class ProcessOutputBuffers: AgentProcessOutputBuffers<ClaudeCodeRolloutLine>, @unchecked Sendable {
  init() {
    super.init(rolloutLineParser: ClaudeCodeRolloutReader.parseRolloutLine)
  }
}

final class ManagedClaudeCodeProcess: AgentManagedProcessRuntime, @unchecked Sendable {
  private let managed: AgentManagedProcess<ClaudeCodeProcessExecution, ClaudeCodeRolloutLine>
  let outputBuffers: ProcessOutputBuffers
  var agentOutputBuffers: AgentProcessOutputBuffers<ClaudeCodeRolloutLine> { outputBuffers }

  init(
    process: Process,
    input: FileHandle,
    output: FileHandle,
    error: FileHandle,
    outputBuffers: ProcessOutputBuffers = ProcessOutputBuffers()
  ) {
    self.outputBuffers = outputBuffers
    self.managed = AgentManagedProcess(
      process: process,
      input: input,
      output: output,
      error: error,
      outputBuffers: outputBuffers,
      executionFactory: Self.execution(stdout:stderr:exitCode:)
    )
  }

  init(failedExecution: ClaudeCodeProcessExecution) {
    let outputBuffers = ProcessOutputBuffers()
    self.outputBuffers = outputBuffers
    self.managed = AgentManagedProcess(
      failedExecution: failedExecution,
      outputBuffers: outputBuffers,
      executionFactory: Self.execution(stdout:stderr:exitCode:)
    )
  }

  func startDraining() {
    managed.startDraining()
  }

  func write(_ text: String) -> Bool {
    managed.write(text)
  }

  func closeInput() {
    managed.closeInput()
  }

  func terminate() {
    managed.terminate()
  }

  func waitUntilExit() {
    managed.waitUntilExit()
  }

  func execution() -> ClaudeCodeProcessExecution {
    managed.execution()
  }

  private static func execution(stdout: Data, stderr: Data, exitCode: Int32) -> ClaudeCodeProcessExecution {
    ClaudeCodeProcessExecution(
      stdout: decodeAgentProcessOutput(stdout),
      stderr: decodeAgentProcessOutput(stderr),
      exitCode: exitCode
    )
  }
}
