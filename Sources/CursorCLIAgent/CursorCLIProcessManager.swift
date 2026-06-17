import Foundation
import RielaCore

public enum CursorCLIProcessStatus: String, Equatable, Sendable {
  case running
  case exited
  case killed
}

public struct CursorCLIProcessRecord: Equatable, Sendable {
  public var id: String
  public var pid: Int32
  public var command: String
  public var prompt: String
  public var startedAt: String
  public var status: CursorCLIProcessStatus
  public var exitCode: Int32?
  public var arguments: [String]
  public var input: [String]

  public init(id: String, pid: Int32, command: String, prompt: String, startedAt: String, status: CursorCLIProcessStatus, exitCode: Int32? = nil, arguments: [String] = [], input: [String] = []) {
    self.id = id
    self.pid = pid
    self.command = command
    self.prompt = prompt
    self.startedAt = startedAt
    self.status = status
    self.exitCode = exitCode
    self.arguments = arguments
    self.input = input
  }
}

public struct CursorCLIProcessExecution: Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32

  public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

public struct CursorCLIExecStreamResult: Sendable {
  public var process: CursorCLIProcessRecord
  public var lines: CursorCLIRolloutLineStream
  public var completion: CursorCLIProcessCompletion

  public func collectLines() -> [CursorCLIRolloutLine] {
    completion.wait()
    return lines.snapshot()
  }

  public func waitForCompletion() -> Int32 {
    completion.wait()
  }
}

public final class CursorCLIRolloutLineStream: @unchecked Sendable {
  private let buffers: ProcessOutputBuffers
  private var cursor = 0

  fileprivate init(buffers: ProcessOutputBuffers) {
    self.buffers = buffers
  }

  public func next(timeout: TimeInterval? = nil) -> CursorCLIRolloutLine? {
    buffers.nextLine(after: &cursor, timeout: timeout)
  }

  public func snapshot() -> [CursorCLIRolloutLine] {
    buffers.lines()
  }
}

public final class CursorCLIProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private let waitClosure: () -> Int32
  private var cachedExitCode: Int32?

  fileprivate init(_ waitClosure: @escaping () -> Int32) {
    self.waitClosure = waitClosure
  }

  @discardableResult
  public func wait() -> Int32 {
    lock.lock()
    if let cachedExitCode {
      lock.unlock()
      return cachedExitCode
    }
    lock.unlock()
    let exitCode = waitClosure()
    lock.lock()
    cachedExitCode = exitCode
    lock.unlock()
    return exitCode
  }
}

public final class CursorCLIProcessManager: @unchecked Sendable {
  public typealias Executor = @Sendable ([String], String, [String: String]) -> CursorCLIProcessExecution
  private let lock = NSLock()
  private let executableName: String
  private let executor: Executor?
  private var records: [String: CursorCLIProcessRecord] = [:]
  private var managedProcesses: [String: ManagedCursorCLIProcess] = [:]
  private var nextPid: Int32 = 10_000

  public init(executableName: String = "cursor-agent", executor: Executor? = nil) {
    self.executableName = executableName
    self.executor = executor
  }

  public func spawnExec(prompt: String, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> (process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) {
    run(prompt: prompt, arguments: CursorCLIProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options), options: options)
  }

  public func spawnResume(sessionId: String, prompt: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> (process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) {
    run(prompt: prompt ?? "", arguments: CursorCLIProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func spawnResumeProcess(sessionId: String, prompt: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> CursorCLIProcessRecord {
    let arguments = CursorCLIProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options)
    if executor != nil {
      return startExecutorProcess(prompt: prompt ?? "", arguments: arguments, options: options)
    }
    return startManagedProcess(prompt: prompt ?? "", arguments: arguments, options: options, closeInputAfterPrompt: false).process
  }

  public func spawnFork(sessionId: String, nthMessage: Int? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> (process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) {
    run(prompt: "", arguments: CursorCLIProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options), options: options)
  }

  public func spawnForkProcess(sessionId: String, nthMessage: Int? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> CursorCLIProcessRecord {
    let arguments = CursorCLIProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options)
    if executor != nil {
      return startExecutorProcess(prompt: "", arguments: arguments, options: options)
    }
    return startManagedProcess(prompt: "", arguments: arguments, options: options, closeInputAfterPrompt: false).process
  }

  public func spawnExecStream(prompt: String, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> CursorCLIExecStreamResult {
    stream(prompt: prompt, arguments: CursorCLIProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options), options: options)
  }

  public func spawnResumeStream(sessionId: String, prompt: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> CursorCLIExecStreamResult {
    stream(prompt: prompt ?? "", arguments: CursorCLIProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func list() -> [CursorCLIProcessRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records.values.sorted { $0.startedAt < $1.startedAt }
  }

  public func get(id: String) -> CursorCLIProcessRecord? {
    lock.lock()
    defer { lock.unlock() }
    return records[id]
  }

  public func kill(id: String) -> Bool {
    lock.lock()
    guard var record = records[id], record.status == .running else {
      lock.unlock()
      return false
    }
    let managed = managedProcesses[id]
    record.status = .killed
    records[id] = record
    lock.unlock()
    managed?.terminate()
    return true
  }

  public func writeInput(id: String, text: String) -> Bool {
    lock.lock()
    guard var record = records[id], record.status == .running else {
      lock.unlock()
      return false
    }
    let managed = managedProcesses[id]
    record.input.append(text)
    records[id] = record
    lock.unlock()
    return managed?.write(text) ?? false
  }

  public func killAll() {
    lock.lock()
    let running = managedProcesses.filter { id, _ in records[id]?.status == .running }.map(\.value)
    records = records.mapValues { record in
      var next = record
      if next.status == .running {
        next.status = .killed
      }
      return next
    }
    lock.unlock()
    running.forEach { $0.terminate() }
  }

  @discardableResult
  public func prune() -> Int {
    lock.lock()
    let before = records.count
    records = records.filter { $0.value.status == .running }
    let removed = before - records.count
    lock.unlock()
    return removed
  }

  private func run(prompt: String, arguments: [String], options: CursorCLIProcessOptions) -> (process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) {
    let allArguments = [executableName] + arguments
    let environment = CursorCLIProcessCommandBuilder.buildEnvironment(options: options)
    guard let executor else {
      let started = startManagedProcess(prompt: prompt, arguments: arguments, options: options, closeInputAfterPrompt: true)
      started.managed.waitUntilExit()
      let result = started.managed.execution()
      lock.lock()
      var record = records[started.process.id] ?? started.process
      if record.status == .running {
        record.status = .exited
      }
      record.exitCode = result.exitCode
      records[record.id] = record
      lock.unlock()
      removeManagedProcess(id: record.id)
      return (record, result)
    }
    lock.lock()
    let id = UUID().uuidString
    let pid = nextPid
    nextPid += 1
    let startedAt = ISO8601DateFormatter().string(from: Date())
    var record = CursorCLIProcessRecord(id: id, pid: pid, command: allArguments.joined(separator: " "), prompt: prompt, startedAt: startedAt, status: .running, arguments: allArguments)
    records[id] = record
    lock.unlock()

    let result = executor(allArguments, prompt, environment)
    lock.lock()
    record.status = .exited
    record.exitCode = result.exitCode
    records[id] = record
    lock.unlock()
    return (record, result)
  }

  private func startExecutorProcess(prompt: String, arguments: [String], options: CursorCLIProcessOptions) -> CursorCLIProcessRecord {
    let allArguments = [executableName] + arguments
    _ = CursorCLIProcessCommandBuilder.buildEnvironment(options: options)
    lock.lock()
    let id = UUID().uuidString
    let pid = nextPid
    nextPid += 1
    let startedAt = ISO8601DateFormatter().string(from: Date())
    let record = CursorCLIProcessRecord(id: id, pid: pid, command: allArguments.joined(separator: " "), prompt: prompt, startedAt: startedAt, status: .running, arguments: allArguments)
    records[id] = record
    lock.unlock()
    return record
  }

  private func stream(prompt: String, arguments: [String], options: CursorCLIProcessOptions) -> CursorCLIExecStreamResult {
    if executor != nil {
      let executed = run(prompt: prompt, arguments: arguments, options: options)
      let buffers = ProcessOutputBuffers()
      buffers.appendStdout(Data(executed.result.stdout.utf8))
      buffers.appendStderr(Data(executed.result.stderr.utf8))
      buffers.finishStdout()
      return CursorCLIExecStreamResult(
        process: executed.process,
        lines: CursorCLIRolloutLineStream(buffers: buffers),
        completion: CursorCLIProcessCompletion { executed.result.exitCode }
      )
    }

    let started = startManagedProcess(prompt: prompt, arguments: arguments, options: options, closeInputAfterPrompt: true)
    return CursorCLIExecStreamResult(
      process: started.process,
      lines: CursorCLIRolloutLineStream(buffers: started.managed.outputBuffers),
      completion: CursorCLIProcessCompletion { [weak self, managed = started.managed, processId = started.process.id] in
        managed.waitUntilExit()
        let result = managed.execution()
        self?.finishManagedProcess(id: processId, exitCode: result.exitCode)
        self?.removeManagedProcess(id: processId)
        return result.exitCode
      }
    )
  }

  private func startManagedProcess(prompt: String, arguments: [String], options: CursorCLIProcessOptions, closeInputAfterPrompt: Bool) -> (process: CursorCLIProcessRecord, managed: ManagedCursorCLIProcess) {
    let allArguments = [executableName] + arguments
    let environment = CursorCLIProcessCommandBuilder.buildEnvironment(options: options)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = allArguments
    process.environment = environment
    if let cwd = options.cwd {
      process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    }

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.standardInput = inputPipe

    let id = UUID().uuidString
    let startedAt = ISO8601DateFormatter().string(from: Date())
    let outputBuffers = ProcessOutputBuffers()

    do {
      try process.run()
      let record = CursorCLIProcessRecord(id: id, pid: process.processIdentifier, command: allArguments.joined(separator: " "), prompt: prompt, startedAt: startedAt, status: .running, arguments: allArguments)
      let managed = ManagedCursorCLIProcess(process: process, input: inputPipe.fileHandleForWriting, output: outputPipe.fileHandleForReading, error: errorPipe.fileHandleForReading, outputBuffers: outputBuffers)
      managed.startDraining()
      if closeInputAfterPrompt {
        managed.closeInput()
      }
      lock.lock()
      records[id] = record
      managedProcesses[id] = managed
      lock.unlock()
      process.terminationHandler = { [weak self] process in
        self?.finishManagedProcess(id: id, exitCode: process.terminationStatus)
      }
      return (record, managed)
    } catch {
      let record = CursorCLIProcessRecord(id: id, pid: -1, command: allArguments.joined(separator: " "), prompt: prompt, startedAt: startedAt, status: .exited, exitCode: 127, arguments: allArguments)
      let managed = ManagedCursorCLIProcess(failedExecution: CursorCLIProcessExecution(stdout: "", stderr: error.localizedDescription, exitCode: 127))
      lock.lock()
      records[id] = record
      lock.unlock()
      return (record, managed)
    }
  }

  private func finishManagedProcess(id: String, exitCode: Int32) {
    lock.lock()
    guard var record = records[id] else {
      lock.unlock()
      return
    }
    if record.status == .running {
      record.status = .exited
    }
    record.exitCode = exitCode
    records[id] = record
    lock.unlock()
  }

  private func removeManagedProcess(id: String) {
    lock.lock()
    managedProcesses.removeValue(forKey: id)
    lock.unlock()
  }
}

private final class ManagedCursorCLIProcess: @unchecked Sendable {
  private let process: Process?
  private let input: FileHandle?
  private let output: FileHandle?
  private let error: FileHandle?
  fileprivate let outputBuffers: ProcessOutputBuffers
  private let outputGroup = DispatchGroup()
  private let failedExecution: CursorCLIProcessExecution?

  init(process: Process, input: FileHandle, output: FileHandle, error: FileHandle, outputBuffers: ProcessOutputBuffers) {
    self.process = process
    self.input = input
    self.output = output
    self.error = error
    self.outputBuffers = outputBuffers
    self.failedExecution = nil
  }

  init(failedExecution: CursorCLIProcessExecution) {
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

  func execution() -> CursorCLIProcessExecution {
    if let failedExecution {
      return failedExecution
    }
    outputGroup.wait()
    return CursorCLIProcessExecution(
      stdout: String(decoding: outputBuffers.stdout(), as: UTF8.self),
      stderr: String(decoding: outputBuffers.stderr(), as: UTF8.self),
      exitCode: process?.terminationStatus ?? 127
    )
  }
}

fileprivate final class ProcessOutputBuffers: @unchecked Sendable {
  private let condition = NSCondition()
  private var stdoutData = Data()
  private var stderrData = Data()
  private var stdoutPartial = ""
  private var parsedLines: [CursorCLIRolloutLine] = []
  private var stdoutClosed = false

  func appendStdout(_ data: Data) {
    condition.lock()
    stdoutData.append(data)
    stdoutPartial += String(decoding: data, as: UTF8.self)
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
    if !stdoutPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let line = CursorCLIRolloutReader.parseRolloutLine(stdoutPartial) {
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

  func lines() -> [CursorCLIRolloutLine] {
    condition.lock()
    defer { condition.unlock() }
    return parsedLines
  }

  func nextLine(after cursor: inout Int, timeout: TimeInterval?) -> CursorCLIRolloutLine? {
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
      if let line = CursorCLIRolloutReader.parseRolloutLine(rawLine) {
        parsedLines.append(line)
      }
    }
  }
}

public enum CursorCLIAgentSDK {
  public enum StreamMode: String, Equatable, Sendable {
    case raw
    case normalized
  }

  public struct Request: Equatable, Sendable {
    public var prompt: String?
    public var sessionId: String?
    public var options: CursorCLIProcessOptions
    public var streamMode: StreamMode

    public init(prompt: String? = nil, sessionId: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions(), streamMode: StreamMode = .raw) {
      self.prompt = prompt
      self.sessionId = sessionId
      self.options = options
      self.streamMode = streamMode
    }
  }

  public static func runAgent<Runner: CursorCLISessionRunner>(request: Request, runner: Runner) throws -> [CursorCLIAgentNormalizedEvent] {
    let resumed = request.sessionId != nil
    let session: Runner.Session
    do {
      if let sessionId = request.sessionId {
        session = try runner.resumeSession(sessionId: sessionId, prompt: request.prompt, options: request.options)
      } else {
        session = try runner.startSession(config: CursorCLISessionConfig(prompt: request.prompt ?? "", options: request.options))
      }
    } catch {
      return [
        CursorCLIAgentNormalizedEvent(
          type: "session.error",
          sessionId: request.sessionId ?? "unknown-session",
          payload: ["message": .string(String(describing: error))]
        )
      ]
    }
    let result = session.waitForCompletion()
    let messages = session.messages()
    let resolvedSessionId = sessionId(from: messages) ?? session.sessionId
    let started = CursorCLIAgentNormalizedEvent(type: "session.started", sessionId: resolvedSessionId, payload: ["resumed": .bool(resumed)])
    let completed = completedEvent(result: result, sessionId: resolvedSessionId, normalized: request.streamMode == .normalized)
    if request.streamMode == .raw {
      return [started] + messages.flatMap { line -> [CursorCLIAgentNormalizedEvent] in
        var events = [rawMessageEvent(from: line, sessionId: resolvedSessionId)]
        if let error = rolloutErrorEvent(from: line, sessionId: resolvedSessionId) {
          events.append(error)
        }
        return events
      } + [completed]
    }
    var normalizer = CursorCLIAgentEventNormalizer()
    let normalized = messages.flatMap { line -> [CursorCLIAgentNormalizedEvent] in
      var chunk: JSONObject = ["type": .string(line.type), "payload": line.payload]
      if line.type == "assistant.snapshot", let content = line.payloadObject?["content"] {
        chunk["content"] = content
      }
      return normalizer.normalize(chunk, fallbackSessionId: resolvedSessionId, includeSessionStarted: false)
    }
    return [started] + normalized + [completed]
  }

  private static func sessionId(from lines: [CursorCLIRolloutLine]) -> String? {
    for line in lines where line.type == "session_meta" {
      guard let object = line.payloadObject else {
        continue
      }
      if case let .object(meta)? = object["meta"], case let .string(id)? = meta["id"] {
        return id
      }
      if case let .string(id)? = object["session_id"] ?? object["sessionId"] ?? object["id"] {
        return id
      }
    }
    return nil
  }

  private static func rawMessageEvent(from line: CursorCLIRolloutLine, sessionId: String) -> CursorCLIAgentNormalizedEvent {
    CursorCLIAgentNormalizedEvent(type: "session.message", sessionId: sessionId, payload: ["chunk": rawLineValue(from: line)])
  }

  private static func rolloutErrorEvent(from line: CursorCLIRolloutLine, sessionId: String) -> CursorCLIAgentNormalizedEvent? {
    guard
      line.type == "event_msg",
      let object = line.payloadObject,
      stringValue(object["type"]) == "Error"
    else {
      return nil
    }
    return CursorCLIAgentNormalizedEvent(type: "session.error", sessionId: sessionId, payload: ["message": .string(stringValue(object["message"]) ?? "Unknown rollout error")])
  }

  private static func completedEvent(result: CursorCLISessionResult, sessionId: String, normalized: Bool) -> CursorCLIAgentNormalizedEvent {
    if normalized {
      return CursorCLIAgentNormalizedEvent(
        type: "session.completed",
        sessionId: sessionId,
        payload: [
          "success": .bool(result.success),
          "exitCode": .number(Double(result.exitCode))
        ]
      )
    }
    return CursorCLIAgentNormalizedEvent(type: "session.completed", sessionId: sessionId, payload: ["result": .object(sessionResultJSON(result))])
  }

  private static func sessionResultJSON(_ result: CursorCLISessionResult) -> JSONObject {
    [
      "success": .bool(result.success),
      "exitCode": .number(Double(result.exitCode)),
      "stats": .object([
        "startedAt": .string(result.startedAt),
        "completedAt": .string(result.completedAt),
        "messageCount": .number(Double(result.messageCount))
      ])
    ]
  }

  private static func rawLineValue(from line: CursorCLIRolloutLine) -> JSONValue {
    var payload: JSONObject = [
      "timestamp": .string(line.timestamp),
      "type": .string(line.type),
      "payload": line.payload,
    ]
    if let object = line.payloadObject {
      payload.merge(object) { current, _ in current }
    }
    return .object(payload)
  }
}

public final class CursorCLIProcessRunningSession: CursorCLIRunningSession, @unchecked Sendable {
  private let lock = NSLock()
  private var currentSessionId: String
  private let processRecord: CursorCLIProcessRecord
  private let streamResult: CursorCLIExecStreamResult
  private let existingLines: [CursorCLIRolloutLine]
  private let streamGranularity: String
  private let resumeCapture: CursorCLIResumeRolloutCapture?
  private let terminateProcess: () -> Bool
  private var collectedLines: [CursorCLIRolloutLine]?
  private var closed = false

  fileprivate init(
    sessionId: String,
    processRecord: CursorCLIProcessRecord,
    streamResult: CursorCLIExecStreamResult,
    existingLines: [CursorCLIRolloutLine] = [],
    streamGranularity: String = "event",
    resumeCapture: CursorCLIResumeRolloutCapture? = nil,
    terminateProcess: @escaping () -> Bool = { false }
  ) {
    self.currentSessionId = sessionId
    self.processRecord = processRecord
    self.streamResult = streamResult
    self.existingLines = existingLines
    self.streamGranularity = streamGranularity
    self.resumeCapture = resumeCapture
    self.terminateProcess = terminateProcess
  }

  public var sessionId: String {
    lock.lock()
    defer { lock.unlock() }
    return currentSessionId
  }

  public func getState() -> [String: String] {
    let sessionId = refreshSessionId(from: streamLines(includeFinalRolloutBackfill: false))
    lock.lock()
    defer { lock.unlock() }
    return [
      "sessionId": sessionId,
      "processId": processRecord.id,
      "status": closed ? "completed" : "running",
    ]
  }

  public func pushMessage(_ message: CursorCLIRolloutLine) throws {
    throw CursorCLIProcessSessionError.readOnlySession
  }

  public func messages() -> [CursorCLIRolloutLine] {
    lock.lock()
    if let collectedLines {
      lock.unlock()
      return collectedLines
    }
    lock.unlock()
    let mergedLines = streamLines(includeFinalRolloutBackfill: false)
    let sessionId = refreshSessionId(from: mergedLines)
    return mergedLines.streamChunks(granularity: streamGranularity, sessionId: sessionId)
  }

  public func waitForCompletion() -> CursorCLISessionResult {
    let exitCode = streamResult.waitForCompletion()
    let mergedLines = streamLines(includeFinalRolloutBackfill: true)
    let sessionId = refreshSessionId(from: mergedLines)
    let lines = mergedLines.streamChunks(granularity: streamGranularity, sessionId: sessionId)
    lock.lock()
    collectedLines = lines
    closed = true
    lock.unlock()
    let now = ISO8601DateFormatter().string(from: Date())
    return CursorCLISessionResult(success: exitCode == 0, exitCode: exitCode, startedAt: processRecord.startedAt, completedAt: now, messageCount: mergedLines.count)
  }

  public func cancel() -> CursorCLISessionResult {
    _ = terminateProcess()
    _ = streamResult.waitForCompletion()
    let mergedLines = streamLines(includeFinalRolloutBackfill: true)
    let sessionId = refreshSessionId(from: mergedLines)
    let lines = mergedLines.streamChunks(granularity: streamGranularity, sessionId: sessionId)
    lock.lock()
    collectedLines = lines
    closed = true
    lock.unlock()
    let now = ISO8601DateFormatter().string(from: Date())
    return CursorCLISessionResult(success: false, exitCode: 130, startedAt: processRecord.startedAt, completedAt: now, messageCount: mergedLines.count)
  }

  private func streamLines(includeFinalRolloutBackfill: Bool) -> [CursorCLIRolloutLine] {
    var lines = existingLines + streamResult.lines.snapshot()
    if let resumeCapture {
      lines.append(contentsOf: resumeCapture.flush(includeFinalBackfill: includeFinalRolloutBackfill))
    }
    return lines.deduplicatingStableRolloutLines()
  }

  @discardableResult
  private func refreshSessionId(from lines: [CursorCLIRolloutLine]) -> String {
    let resolved = Self.sessionId(from: lines)
    lock.lock()
    if let resolved {
      currentSessionId = resolved
    }
    let value = currentSessionId
    lock.unlock()
    return value
  }

  private static func sessionId(from lines: [CursorCLIRolloutLine]) -> String? {
    for line in lines where line.type == "session_meta" {
      guard let object = line.payloadObject else {
        continue
      }
      if case let .object(meta)? = object["meta"], case let .string(id)? = meta["id"] {
        return id
      }
      if case let .string(id)? = object["session_id"] ?? object["sessionId"] ?? object["id"] {
        return id
      }
    }
    return nil
  }
}

public final class CursorCLIProcessSessionRunner: CursorCLISessionRunner, @unchecked Sendable {
  public typealias Session = CursorCLIProcessRunningSession
  private let processManager: CursorCLIProcessManager

  public init(processManager: CursorCLIProcessManager = CursorCLIProcessManager()) {
    self.processManager = processManager
  }

  public func startSession(config: CursorCLISessionConfig) throws -> CursorCLIProcessRunningSession {
    if let resumeSessionId = config.resumeSessionId {
      return try resumeSession(sessionId: resumeSessionId, prompt: config.prompt, options: config.options)
    }
    let result = processManager.spawnExecStream(prompt: config.prompt, options: config.options)
    return CursorCLIProcessRunningSession(
      sessionId: sessionId(from: result.lines.snapshot()) ?? result.process.id,
      processRecord: result.process,
      streamResult: result,
      streamGranularity: config.options.streamGranularity ?? "event",
      terminateProcess: { [processManager, processId = result.process.id] in
        processManager.kill(id: processId)
      }
    )
  }

  public func resumeSession(sessionId: String, prompt: String?, options: CursorCLIProcessOptions) throws -> CursorCLIProcessRunningSession {
    let cursorCLIHome = options.cursorCLIHome ?? options.environmentVariables["CURSOR_CLI_AGENT_CURSOR_HOME"]
    let session = CursorCLISessionIndex.findSession(id: sessionId, cursorCLIHome: cursorCLIHome)
    let existingLines = options.includeExistingOnResume ? existingRolloutLines(session: session) : []
    let capture = CursorCLIResumeRolloutCapture(sessionId: sessionId, cursorCLIHome: cursorCLIHome, initialSession: session)
    let result = processManager.spawnResumeStream(sessionId: sessionId, prompt: prompt, options: options)
    return CursorCLIProcessRunningSession(
      sessionId: sessionId,
      processRecord: result.process,
      streamResult: result,
      existingLines: existingLines,
      streamGranularity: options.streamGranularity ?? "event",
      resumeCapture: capture,
      terminateProcess: { [processManager, processId = result.process.id] in
        processManager.kill(id: processId)
      }
    )
  }

  private func sessionId(from lines: [CursorCLIRolloutLine]) -> String? {
    for line in lines where line.type == "session_meta" {
      guard let object = line.payloadObject else {
        continue
      }
      if case let .object(meta)? = object["meta"], case let .string(id)? = meta["id"] {
        return id
      }
      if case let .string(id)? = object["session_id"] ?? object["sessionId"] ?? object["id"] {
        return id
      }
    }
    return nil
  }

  private func existingRolloutLines(session: CursorCLISession?) -> [CursorCLIRolloutLine] {
    guard let session else {
      return []
    }
    return (try? CursorCLIRolloutReader.readRollout(path: session.rolloutPath)) ?? []
  }
}

public enum CursorCLIProcessSessionError: Error, Equatable {
  case readOnlySession
}

private func parseStdoutLines(_ stdout: String) -> [CursorCLIRolloutLine] {
  stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { CursorCLIRolloutReader.parseRolloutLine(String($0)) }
}

private final class CursorCLIResumeRolloutCapture: @unchecked Sendable {
  private let lock = NSLock()
  private let sessionId: String
  private let cursorCLIHome: String?
  private let watcher: CursorCLIRolloutWatcher
  private var attachedPath: String?
  private var closed = false

  init(sessionId: String, cursorCLIHome: String?, initialSession: CursorCLISession?) {
    self.sessionId = sessionId
    self.cursorCLIHome = cursorCLIHome
    self.watcher = CursorCLIRolloutWatcher()
    if let initialSession {
      attachedPath = initialSession.rolloutPath
      watcher.watchFile(path: initialSession.rolloutPath, startOffset: rolloutFileSize(path: initialSession.rolloutPath))
    } else {
      watcher.watchSessionsDirectory(path: CursorCLIRolloutWatcher.sessionsWatchDir(cursorCLIHome: cursorCLIHome))
    }
  }

  func flush(includeFinalBackfill: Bool) -> [CursorCLIRolloutLine] {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return []
    }
    lock.unlock()

    var lines: [CursorCLIRolloutLine] = []
    for event in watcher.flush() {
      switch event {
      case let .line(_, line):
        lines.append(line)
      case let .newSession(path):
        attachIfMatching(path: path)
      case .error:
        continue
      }
    }
    if includeFinalBackfill {
      lines.append(contentsOf: finalBackfill())
      stop()
    }
    return lines
  }

  private func attachIfMatching(path: String) {
    guard rolloutPath(path, matchesSessionId: sessionId) else {
      return
    }
    lock.lock()
    defer { lock.unlock() }
    guard !closed, attachedPath == nil else {
      return
    }
    attachedPath = path
    watcher.watchFile(path: path, startOffset: 0)
  }

  private func finalBackfill() -> [CursorCLIRolloutLine] {
    let path: String?
    lock.lock()
    path = attachedPath
    lock.unlock()
    if let path {
      return (try? CursorCLIRolloutReader.readRollout(path: path)) ?? []
    }
    guard let session = CursorCLISessionIndex.findSession(id: sessionId, cursorCLIHome: cursorCLIHome) else {
      return []
    }
    lock.lock()
    if attachedPath == nil {
      attachedPath = session.rolloutPath
    }
    lock.unlock()
    return (try? CursorCLIRolloutReader.readRollout(path: session.rolloutPath)) ?? []
  }

  private func stop() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    lock.unlock()
    watcher.stop()
  }
}

private func rolloutFileSize(path: String) -> UInt64 {
  (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
}

private func rolloutPath(_ path: String, matchesSessionId sessionId: String) -> Bool {
  if URL(fileURLWithPath: path).lastPathComponent.contains(sessionId) {
    return true
  }
  guard let first = try? CursorCLIRolloutReader.readRollout(path: path).first else {
    return false
  }
  if first.type == "session_meta", let object = first.payloadObject {
    if case let .object(meta)? = object["meta"], case let .string(id)? = meta["id"] {
      return id == sessionId
    }
    if case let .string(id)? = object["session_id"] ?? object["sessionId"] ?? object["id"] {
      return id == sessionId
    }
  }
  return false
}

private extension Array where Element == CursorCLIRolloutLine {
  func deduplicatingStableRolloutLines() -> [CursorCLIRolloutLine] {
    var seen = Set<String>()
    var lines: [CursorCLIRolloutLine] = []
    for line in self {
      let key = line.stableLineKey
      guard !seen.contains(key) else {
        continue
      }
      seen.insert(key)
      lines.append(line)
    }
    return lines
  }

  func streamChunks(granularity: String, sessionId: String) -> [CursorCLIRolloutLine] {
    guard granularity == "char" else {
      return self
    }
    return flatMap { line -> [CursorCLIRolloutLine] in
      let segments = line.assistantTextSegments
      guard !segments.isEmpty else {
        return [line]
      }
      return segments.flatMap { segment in
        segment.map { character in
          CursorCLIRolloutLine(
            timestamp: line.timestamp,
            type: "assistant.delta",
            payload: .object([
              "kind": .string("char"),
              "char": .string(String(character)),
              "sessionId": .string(sessionId),
              "sourceType": .string(line.type),
              "source": line.jsonLineValue
            ]),
            provenance: line.provenance
          )
        }
      }
    }
  }
}

private extension CursorCLIRolloutLine {
  var payloadObject: JSONObject? {
    guard case let .object(object) = payload else {
      return nil
    }
    return object
  }

  var assistantTextSegments: [String] {
    if type == "event_msg" {
      guard
        let object = payloadObject,
        stringValue(object["type"]) == "AgentMessage",
        let message = stringValue(object["message"]),
        !message.isEmpty
      else {
        return []
      }
      return [message]
    }
    guard
      type == "response_item",
      let object = payloadObject,
      stringValue(object["type"]) == "message",
      stringValue(object["role"]) == "assistant",
      case let .array(content)? = object["content"]
    else {
      return []
    }
    return content.compactMap { entry -> String? in
      guard
        case let .object(item) = entry,
        ["output_text", "input_text"].contains(stringValue(item["type"])),
        let text = stringValue(item["text"]),
        !text.isEmpty
      else {
        return nil
      }
      return text
    }
  }

  var stableLineKey: String {
    jsonString(jsonLineValue)
  }

  var jsonLineValue: JSONValue {
    .object([
      "timestamp": .string(timestamp),
      "type": .string(type),
      "payload": payload
    ])
  }
}

private func jsonString(_ value: JSONValue) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  guard let data = try? encoder.encode(value) else {
    return "\(value)"
  }
  return String(decoding: data, as: UTF8.self)
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
