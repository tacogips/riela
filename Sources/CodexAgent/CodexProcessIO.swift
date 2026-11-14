import AgentRuntimeKit
import Foundation

final class ProcessOutputBuffers: AgentProcessOutputBuffers<CodexRolloutLine>, @unchecked Sendable {
  init() {
    super.init(
      outputDecoder: processOutputString(from:),
      rolloutLineParser: CodexRolloutReader.parseRolloutLine
    )
  }
}

final class ManagedCodexProcess: AgentManagedProcessRuntime, @unchecked Sendable {
  private let managed: AgentManagedProcess<CodexProcessExecution, CodexRolloutLine>
  let outputBuffers: ProcessOutputBuffers
  var agentOutputBuffers: AgentProcessOutputBuffers<CodexRolloutLine> { outputBuffers }

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

  init(failedExecution: CodexProcessExecution) {
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

  func execution() -> CodexProcessExecution {
    managed.execution()
  }

  private static func execution(stdout: Data, stderr: Data, exitCode: Int32) -> CodexProcessExecution {
    CodexProcessExecution(
      stdout: processOutputString(from: stdout),
      stderr: processOutputString(from: stderr),
      exitCode: exitCode
    )
  }
}
