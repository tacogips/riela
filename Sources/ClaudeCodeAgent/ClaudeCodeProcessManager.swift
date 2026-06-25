import Foundation
import RielaCore

public enum ClaudeCodeProcessStatus: String, Equatable, Sendable {
  case running
  case exited
  case killed
}

public struct ClaudeCodeProcessRecord: Equatable, Sendable {
  public var id: String
  public var pid: Int32
  public var command: String
  public var prompt: String
  public var startedAt: String
  public var status: ClaudeCodeProcessStatus
  public var exitCode: Int32?
  public var arguments: [String]
  public var input: [String]

  public init(id: String, pid: Int32, command: String, prompt: String, startedAt: String, status: ClaudeCodeProcessStatus, exitCode: Int32? = nil, arguments: [String] = [], input: [String] = []) {
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

public struct ClaudeCodeProcessExecution: Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32

  public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

public struct ClaudeCodeExecStreamResult: Sendable {
  public var process: ClaudeCodeProcessRecord
  public var lines: ClaudeCodeRolloutLineStream
  public var completion: ClaudeCodeProcessCompletion

  public func collectLines() -> [ClaudeCodeRolloutLine] {
    completion.wait()
    return lines.snapshot()
  }

  public func waitForCompletion() -> Int32 {
    completion.wait()
  }
}

public final class ClaudeCodeRolloutLineStream: @unchecked Sendable {
  private let buffers: ProcessOutputBuffers
  private var cursor = 0

  fileprivate init(buffers: ProcessOutputBuffers) {
    self.buffers = buffers
  }

  public func next(timeout: TimeInterval? = nil) -> ClaudeCodeRolloutLine? {
    buffers.nextLine(after: &cursor, timeout: timeout)
  }

  public func snapshot() -> [ClaudeCodeRolloutLine] {
    buffers.lines()
  }
}

public final class ClaudeCodeProcessCompletion: @unchecked Sendable {
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

public final class ClaudeCodeProcessManager: @unchecked Sendable {
  public typealias Executor = @Sendable ([String], String, [String: String]) -> ClaudeCodeProcessExecution
  private let lock = NSLock()
  private let executableName: String
  private let executor: Executor?
  private var records: [String: ClaudeCodeProcessRecord] = [:]
  private var managedProcesses: [String: ManagedClaudeCodeProcess] = [:]
  private var nextPid: Int32 = 10_000

  public init(executableName: String = "claude", executor: Executor? = nil) {
    self.executableName = executableName
    self.executor = executor
  }

  public func spawnExec(prompt: String, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> (process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) {
    run(prompt: prompt, arguments: ClaudeCodeProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options), options: options)
  }

  public func spawnResume(sessionId: String, prompt: String? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> (process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) {
    run(prompt: prompt ?? "", arguments: ClaudeCodeProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func spawnResumeProcess(sessionId: String, prompt: String? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> ClaudeCodeProcessRecord {
    let arguments = ClaudeCodeProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options)
    if executor != nil {
      return startExecutorProcess(prompt: prompt ?? "", arguments: arguments, options: options)
    }
    return startManagedProcess(prompt: prompt ?? "", arguments: arguments, options: options, closeInputAfterPrompt: false).process
  }

  public func spawnFork(sessionId: String, nthMessage: Int? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> (process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) {
    run(prompt: "", arguments: ClaudeCodeProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options), options: options)
  }

  public func spawnForkProcess(sessionId: String, nthMessage: Int? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> ClaudeCodeProcessRecord {
    let arguments = ClaudeCodeProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options)
    if executor != nil {
      return startExecutorProcess(prompt: "", arguments: arguments, options: options)
    }
    return startManagedProcess(prompt: "", arguments: arguments, options: options, closeInputAfterPrompt: false).process
  }

  public func spawnExecStream(prompt: String, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> ClaudeCodeExecStreamResult {
    stream(prompt: prompt, arguments: ClaudeCodeProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options), options: options)
  }

  public func spawnResumeStream(sessionId: String, prompt: String? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> ClaudeCodeExecStreamResult {
    stream(prompt: prompt ?? "", arguments: ClaudeCodeProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func list() -> [ClaudeCodeProcessRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records.values.sorted { $0.startedAt < $1.startedAt }
  }

  public func get(id: String) -> ClaudeCodeProcessRecord? {
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

  private func run(prompt: String, arguments: [String], options: ClaudeCodeProcessOptions) -> (process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) {
    let allArguments = [executableName] + arguments
    let environment = ClaudeCodeProcessCommandBuilder.buildEnvironment(options: options)
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
    var record = ClaudeCodeProcessRecord(id: id, pid: pid, command: allArguments.joined(separator: " "), prompt: prompt, startedAt: startedAt, status: .running, arguments: allArguments)
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

  private func startExecutorProcess(prompt: String, arguments: [String], options: ClaudeCodeProcessOptions) -> ClaudeCodeProcessRecord {
    let allArguments = [executableName] + arguments
    _ = ClaudeCodeProcessCommandBuilder.buildEnvironment(options: options)
    lock.lock()
    let id = UUID().uuidString
    let pid = nextPid
    nextPid += 1
    let startedAt = ISO8601DateFormatter().string(from: Date())
    let record = ClaudeCodeProcessRecord(id: id, pid: pid, command: allArguments.joined(separator: " "), prompt: prompt, startedAt: startedAt, status: .running, arguments: allArguments)
    records[id] = record
    lock.unlock()
    return record
  }

  private func stream(prompt: String, arguments: [String], options: ClaudeCodeProcessOptions) -> ClaudeCodeExecStreamResult {
    if executor != nil {
      let executed = run(prompt: prompt, arguments: arguments, options: options)
      let buffers = ProcessOutputBuffers()
      buffers.appendStdout(Data(executed.result.stdout.utf8))
      buffers.appendStderr(Data(executed.result.stderr.utf8))
      buffers.finishStdout()
      return ClaudeCodeExecStreamResult(
        process: executed.process,
        lines: ClaudeCodeRolloutLineStream(buffers: buffers),
        completion: ClaudeCodeProcessCompletion { executed.result.exitCode }
      )
    }

    let started = startManagedProcess(prompt: prompt, arguments: arguments, options: options, closeInputAfterPrompt: true)
    return ClaudeCodeExecStreamResult(
      process: started.process,
      lines: ClaudeCodeRolloutLineStream(buffers: started.managed.outputBuffers),
      completion: ClaudeCodeProcessCompletion { [weak self, managed = started.managed, processId = started.process.id] in
        managed.waitUntilExit()
        let result = managed.execution()
        self?.finishManagedProcess(id: processId, exitCode: result.exitCode)
        self?.removeManagedProcess(id: processId)
        return result.exitCode
      }
    )
  }

  private func startManagedProcess(prompt: String, arguments: [String], options: ClaudeCodeProcessOptions, closeInputAfterPrompt: Bool) -> (process: ClaudeCodeProcessRecord, managed: ManagedClaudeCodeProcess) {
    let allArguments = [executableName] + arguments
    let environment = ClaudeCodeProcessCommandBuilder.buildEnvironment(options: options)
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
      let record = ClaudeCodeProcessRecord(id: id, pid: process.processIdentifier, command: allArguments.joined(separator: " "), prompt: prompt, startedAt: startedAt, status: .running, arguments: allArguments)
      let managed = ManagedClaudeCodeProcess(process: process, input: inputPipe.fileHandleForWriting, output: outputPipe.fileHandleForReading, error: errorPipe.fileHandleForReading, outputBuffers: outputBuffers)
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
      let record = ClaudeCodeProcessRecord(id: id, pid: -1, command: allArguments.joined(separator: " "), prompt: prompt, startedAt: startedAt, status: .exited, exitCode: 127, arguments: allArguments)
      let managed = ManagedClaudeCodeProcess(failedExecution: ClaudeCodeProcessExecution(stdout: "", stderr: error.localizedDescription, exitCode: 127))
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

public final class ClaudeCodeProcessRunningSession: ClaudeCodeRunningSession, @unchecked Sendable {
  private let lock = NSLock()
  private var currentSessionId: String
  private let processRecord: ClaudeCodeProcessRecord
  private let streamResult: ClaudeCodeExecStreamResult
  private let existingLines: [ClaudeCodeRolloutLine]
  private let streamGranularity: String
  private let resumeCapture: ClaudeCodeResumeRolloutCapture?
  private let terminateProcess: () -> Bool
  private var collectedLines: [ClaudeCodeRolloutLine]?
  private var closed = false

  fileprivate init(
    sessionId: String,
    processRecord: ClaudeCodeProcessRecord,
    streamResult: ClaudeCodeExecStreamResult,
    existingLines: [ClaudeCodeRolloutLine] = [],
    streamGranularity: String = "event",
    resumeCapture: ClaudeCodeResumeRolloutCapture? = nil,
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

  public func pushMessage(_ message: ClaudeCodeRolloutLine) throws {
    throw ClaudeCodeProcessSessionError.readOnlySession
  }

  public func messages() -> [ClaudeCodeRolloutLine] {
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

  public func waitForCompletion() -> ClaudeCodeSessionResult {
    let exitCode = streamResult.waitForCompletion()
    let mergedLines = streamLines(includeFinalRolloutBackfill: true)
    let sessionId = refreshSessionId(from: mergedLines)
    let lines = mergedLines.streamChunks(granularity: streamGranularity, sessionId: sessionId)
    lock.lock()
    collectedLines = lines
    closed = true
    lock.unlock()
    let now = ISO8601DateFormatter().string(from: Date())
    return ClaudeCodeSessionResult(success: exitCode == 0, exitCode: exitCode, startedAt: processRecord.startedAt, completedAt: now, messageCount: mergedLines.count)
  }

  public func cancel() -> ClaudeCodeSessionResult {
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
    return ClaudeCodeSessionResult(success: false, exitCode: 130, startedAt: processRecord.startedAt, completedAt: now, messageCount: mergedLines.count)
  }

  private func streamLines(includeFinalRolloutBackfill: Bool) -> [ClaudeCodeRolloutLine] {
    var lines = existingLines + streamResult.lines.snapshot()
    if let resumeCapture {
      lines.append(contentsOf: resumeCapture.flush(includeFinalBackfill: includeFinalRolloutBackfill))
    }
    return lines.deduplicatingStableRolloutLines()
  }

  @discardableResult
  private func refreshSessionId(from lines: [ClaudeCodeRolloutLine]) -> String {
    let resolved = Self.sessionId(from: lines)
    lock.lock()
    if let resolved {
      currentSessionId = resolved
    }
    let value = currentSessionId
    lock.unlock()
    return value
  }

  private static func sessionId(from lines: [ClaudeCodeRolloutLine]) -> String? {
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

public final class ClaudeCodeProcessSessionRunner: ClaudeCodeSessionRunner, @unchecked Sendable {
  public typealias Session = ClaudeCodeProcessRunningSession
  private let processManager: ClaudeCodeProcessManager

  public init(processManager: ClaudeCodeProcessManager = ClaudeCodeProcessManager()) {
    self.processManager = processManager
  }

  public func startSession(config: ClaudeCodeSessionConfig) throws -> ClaudeCodeProcessRunningSession {
    if let resumeSessionId = config.resumeSessionId {
      return try resumeSession(sessionId: resumeSessionId, prompt: config.prompt, options: config.options)
    }
    let result = processManager.spawnExecStream(prompt: config.prompt, options: config.options)
    return ClaudeCodeProcessRunningSession(
      sessionId: sessionId(from: result.lines.snapshot()) ?? result.process.id,
      processRecord: result.process,
      streamResult: result,
      streamGranularity: config.options.streamGranularity ?? "event",
      terminateProcess: { [processManager, processId = result.process.id] in
        processManager.kill(id: processId)
      }
    )
  }

  public func resumeSession(sessionId: String, prompt: String?, options: ClaudeCodeProcessOptions) throws -> ClaudeCodeProcessRunningSession {
    let claudeCodeHome = options.claudeCodeHome ?? options.environmentVariables["CLAUDE_CONFIG_DIR"]
    let session = ClaudeCodeSessionIndex.findSession(id: sessionId, claudeCodeHome: claudeCodeHome)
    let existingLines = options.includeExistingOnResume ? existingRolloutLines(session: session) : []
    let capture = ClaudeCodeResumeRolloutCapture(sessionId: sessionId, claudeCodeHome: claudeCodeHome, initialSession: session)
    let result = processManager.spawnResumeStream(sessionId: sessionId, prompt: prompt, options: options)
    return ClaudeCodeProcessRunningSession(
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

  private func sessionId(from lines: [ClaudeCodeRolloutLine]) -> String? {
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

  private func existingRolloutLines(session: ClaudeCodeSession?) -> [ClaudeCodeRolloutLine] {
    guard let session else {
      return []
    }
    return (try? ClaudeCodeRolloutReader.readRollout(path: session.rolloutPath)) ?? []
  }
}

public enum ClaudeCodeProcessSessionError: Error, Equatable {
  case readOnlySession
}

private func parseStdoutLines(_ stdout: String) -> [ClaudeCodeRolloutLine] {
  stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { ClaudeCodeRolloutReader.parseRolloutLine(String($0)) }
}
