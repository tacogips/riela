import Foundation

public typealias AgentProcessOutputDecoder = @Sendable (Data) -> String

public func decodeAgentProcessOutput(_ data: Data) -> String {
  // Process output may contain invalid UTF-8; keep replacement-character decoding.
  // swiftlint:disable:next optional_data_string_conversion
  String(decoding: data, as: UTF8.self)
}

open class AgentProcessOutputBuffers<RolloutLine>: @unchecked Sendable {
  public typealias RolloutLineParser = @Sendable (String) -> RolloutLine?

  private let condition = NSCondition()
  private let rolloutLineParser: RolloutLineParser
  private var stdoutData = Data()
  private var stderrData = Data()
  private var stdoutLineSplitter = AgentJSONLByteLineSplitter()
  private var parsedLines: [RolloutLine] = []
  private var stdoutClosed = false

  public init(
    outputDecoder: @escaping AgentProcessOutputDecoder = decodeAgentProcessOutput,
    rolloutLineParser: @escaping RolloutLineParser
  ) {
    _ = outputDecoder
    self.rolloutLineParser = rolloutLineParser
  }

  public func appendStdout(_ data: Data) {
    condition.lock()
    stdoutData.append(data)
    for rawLine in stdoutLineSplitter.feed(data) {
      appendParsedLine(rawLine)
    }
    condition.broadcast()
    condition.unlock()
  }

  public func appendStderr(_ data: Data) {
    condition.lock()
    stderrData.append(data)
    condition.unlock()
  }

  public func finishStdout() {
    condition.lock()
    if let line = stdoutLineSplitter.flush() {
      appendParsedLine(line)
    }
    stdoutClosed = true
    condition.broadcast()
    condition.unlock()
  }

  public func stdout() -> Data {
    condition.lock()
    defer { condition.unlock() }
    return stdoutData
  }

  public func stderr() -> Data {
    condition.lock()
    defer { condition.unlock() }
    return stderrData
  }

  public func lines() -> [RolloutLine] {
    condition.lock()
    defer { condition.unlock() }
    return parsedLines
  }

  public func nextLine(after cursor: inout Int, timeout: TimeInterval?) -> RolloutLine? {
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

  private func appendParsedLine(_ rawLine: String) {
    guard !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let line = rolloutLineParser(rawLine) else {
      return
    }
    parsedLines.append(line)
  }
}

public final class AgentManagedProcess<Execution, RolloutLine>: @unchecked Sendable {
  public typealias OutputBuffers = AgentProcessOutputBuffers<RolloutLine>
  public typealias ExecutionFactory = @Sendable (_ stdout: Data, _ stderr: Data, _ exitCode: Int32) -> Execution

  private let process: Process?
  private let input: FileHandle?
  private let output: FileHandle?
  private let error: FileHandle?
  private let outputGroup = DispatchGroup()
  private let signalController: AgentProcessSignalController
  private let failedExecution: Execution?
  private let executionFactory: ExecutionFactory
  public let outputBuffers: OutputBuffers

  public init(
    process: Process,
    input: FileHandle,
    output: FileHandle,
    error: FileHandle,
    outputBuffers: OutputBuffers,
    executionFactory: @escaping ExecutionFactory
  ) {
    self.process = process
    self.input = input
    self.output = output
    self.error = error
    self.signalController = AgentProcessSignalController(process: process)
    self.outputBuffers = outputBuffers
    self.failedExecution = nil
    self.executionFactory = executionFactory
  }

  public init(
    failedExecution: Execution,
    outputBuffers: OutputBuffers,
    executionFactory: @escaping ExecutionFactory
  ) {
    self.process = nil
    self.input = nil
    self.output = nil
    self.error = nil
    self.signalController = AgentProcessSignalController(process: nil)
    self.outputBuffers = outputBuffers
    self.outputBuffers.finishStdout()
    self.failedExecution = failedExecution
    self.executionFactory = executionFactory
  }

  public func startDraining() {
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

  public func write(_ text: String) -> Bool {
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

  public func closeInput() {
    try? input?.close()
  }

  public func terminate() {
    closeInput()
    _ = signalController.terminateAndScheduleKill(after: 1)
  }

  public func waitUntilExit() {
    process?.waitUntilExit()
    signalController.markExited()
    outputGroup.wait()
  }

  public func execution() -> Execution {
    if let failedExecution {
      return failedExecution
    }
    outputGroup.wait()
    return executionFactory(outputBuffers.stdout(), outputBuffers.stderr(), process?.terminationStatus ?? 127)
  }
}
