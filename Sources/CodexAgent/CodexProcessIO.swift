import Foundation
import RielaCore

final class ManagedCodexProcess: @unchecked Sendable {
  private let process: Process?
  private let input: FileHandle?
  private let output: FileHandle?
  private let error: FileHandle?
  let outputBuffers: ProcessOutputBuffers
  private let outputGroup = DispatchGroup()
  private let failedExecution: CodexProcessExecution?

  init(process: Process, input: FileHandle, output: FileHandle, error: FileHandle, outputBuffers: ProcessOutputBuffers) {
    self.process = process
    self.input = input
    self.output = output
    self.error = error
    self.outputBuffers = outputBuffers
    self.failedExecution = nil
  }

  init(failedExecution: CodexProcessExecution) {
    self.process = nil
    self.input = nil
    self.output = nil
    self.error = nil
    self.outputBuffers = ProcessOutputBuffers()
    self.outputBuffers.finishStdout()
    self.failedExecution = failedExecution
  }

  func startDraining() {
    if let output {
      outputGroup.enter()
      DispatchQueue.global(qos: .utility).async { [outputBuffers, outputGroup] in
        defer {
          outputBuffers.finishStdout()
          outputGroup.leave()
        }
        while true {
          let data = output.availableData
          if data.isEmpty {
            break
          }
          outputBuffers.appendStdout(data)
        }
      }
    }
    if let error {
      outputGroup.enter()
      DispatchQueue.global(qos: .utility).async { [outputBuffers, outputGroup] in
        defer { outputGroup.leave() }
        while true {
          let data = error.availableData
          if data.isEmpty {
            break
          }
          outputBuffers.appendStderr(data)
        }
      }
    }
  }

  func write(_ text: String) -> Bool {
    guard let input else {
      return false
    }
    do {
      try input.write(contentsOf: Data(text.utf8))
      return true
    } catch {
      return false
    }
  }

  func closeInput() {
    try? input?.close()
  }

  func terminate() {
    process?.terminate()
  }

  func waitUntilExit() {
    process?.waitUntilExit()
    outputGroup.wait()
  }

  func execution() -> CodexProcessExecution {
    if let failedExecution {
      return failedExecution
    }
    outputGroup.wait()
    return CodexProcessExecution(
      stdout: processOutputString(from: outputBuffers.stdout()),
      stderr: processOutputString(from: outputBuffers.stderr()),
      exitCode: process?.terminationStatus ?? 127
    )
  }
}

final class ProcessOutputBuffers: @unchecked Sendable {
  private let condition = NSCondition()
  private var stdoutData = Data()
  private var stderrData = Data()
  private var stdoutPartial = ""
  private var parsedLines: [CodexRolloutLine] = []
  private var stdoutClosed = false

  func appendStdout(_ data: Data) {
    condition.lock()
    stdoutData.append(data)
    stdoutPartial += processOutputString(from: data)
    drainCompleteStdoutLines()
    condition.broadcast()
    condition.unlock()
  }

  func appendStderr(_ data: Data) {
    condition.lock()
    stderrData.append(data)
    condition.unlock()
  }

  func finishStdout() {
    condition.lock()
    if !stdoutPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let line = CodexRolloutReader.parseRolloutLine(stdoutPartial) {
      parsedLines.append(line)
    }
    stdoutPartial = ""
    stdoutClosed = true
    condition.broadcast()
    condition.unlock()
  }

  func stdout() -> Data {
    condition.lock()
    defer { condition.unlock() }
    return stdoutData
  }

  func stderr() -> Data {
    condition.lock()
    defer { condition.unlock() }
    return stderrData
  }

  func lines() -> [CodexRolloutLine] {
    condition.lock()
    defer { condition.unlock() }
    return parsedLines
  }

  func nextLine(after cursor: inout Int, timeout: TimeInterval?) -> CodexRolloutLine? {
    condition.lock()
    defer { condition.unlock() }
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    while cursor >= parsedLines.count && !stdoutClosed {
      if let deadline {
        if !condition.wait(until: deadline) {
          return nil
        }
      } else {
        condition.wait()
      }
    }
    guard cursor < parsedLines.count else {
      return nil
    }
    let line = parsedLines[cursor]
    cursor += 1
    return line
  }

  private func drainCompleteStdoutLines() {
    while let newline = stdoutPartial.firstIndex(of: "\n") {
      let rawLine = String(stdoutPartial[..<newline])
      stdoutPartial.removeSubrange(stdoutPartial.startIndex...newline)
      if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        continue
      }
      if let line = CodexRolloutReader.parseRolloutLine(rawLine) {
        parsedLines.append(line)
      }
    }
  }
}
