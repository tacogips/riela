import AgentRuntimeKit
import Foundation

final class ProcessOutputBuffers: AgentProcessOutputBuffers<CursorCLIRolloutLine>, @unchecked Sendable {
  init() {
    super.init(
      outputDecoder: decodeProcessOutput,
      rolloutLineParser: CursorCLIRolloutReader.parseRolloutLine
    )
  }
}

final class ManagedCursorCLIProcess: AgentManagedProcessRuntime, @unchecked Sendable {
  private let managed: AgentManagedProcess<CursorCLIProcessExecution, CursorCLIRolloutLine>
  let outputBuffers: ProcessOutputBuffers
  var agentOutputBuffers: AgentProcessOutputBuffers<CursorCLIRolloutLine> { outputBuffers }

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

  init(failedExecution: CursorCLIProcessExecution) {
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

  func execution() -> CursorCLIProcessExecution {
    managed.execution()
  }

  private static func execution(stdout: Data, stderr: Data, exitCode: Int32) -> CursorCLIProcessExecution {
    CursorCLIProcessExecution(
      stdout: decodeProcessOutput(stdout),
      stderr: decodeProcessOutput(stderr),
      exitCode: exitCode
    )
  }
}

func decodeProcessOutput(_ data: Data) -> String {
  decodeAgentProcessOutput(data)
}
