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
      "status": closed ? "completed" : "running"
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
