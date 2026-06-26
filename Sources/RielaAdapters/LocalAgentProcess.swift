import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct LocalAgentProcessConfiguration: Equatable, Sendable {
  public var executableURL: URL
  public var arguments: [String]
  public var environment: [String: String]
  public var unsetEnvironmentKeys: Set<String>
  public var workingDirectoryURL: URL?

  public init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String] = [:],
    unsetEnvironmentKeys: Set<String> = [],
    workingDirectoryURL: URL? = nil
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.unsetEnvironmentKeys = unsetEnvironmentKeys
    self.workingDirectoryURL = workingDirectoryURL
  }
}

public struct LocalAgentCommand: Sendable {
  public var provider: String
  public var configuration: LocalAgentProcessConfiguration
  public var stdin: String
  public var normalizeStdout: @Sendable (String) -> String
  public var backendEventType: @Sendable (String) -> String?

  public init(
    provider: String,
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    normalizeStdout: @escaping @Sendable (String) -> String = { $0 },
    backendEventType: @escaping @Sendable (String) -> String? = { _ in nil }
  ) {
    self.provider = provider
    self.configuration = configuration
    self.stdin = stdin
    self.normalizeStdout = normalizeStdout
    self.backendEventType = backendEventType
  }
}

public protocol LocalAgentCommandBuilding: Sendable {
  var provider: String { get }
  func buildCommand(for input: AdapterExecutionInput) throws -> LocalAgentCommand
}

public struct LocalAgentProcessResult: Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var terminationStatus: Int32

  public init(stdout: String, stderr: String, terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol LocalAgentProcessRunning: Sendable {
  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult
}

public enum LocalAgentProcessOutputStream: String, Equatable, Sendable {
  case stdout
  case stderr
}

public struct LocalAgentProcessOutputEvent: Equatable, Sendable {
  public var stream: LocalAgentProcessOutputStream
  public var line: String

  public init(stream: LocalAgentProcessOutputStream, line: String) {
    self.stream = stream
    self.line = line
  }
}

public protocol LocalAgentProcessEventStreaming: LocalAgentProcessRunning {
  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult
}

private final class LockedProcessData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func store(_ value: Data) {
    lock.lock()
    data = value
    lock.unlock()
  }

  func load() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}

private final class LocalProcessPipeReader: @unchecked Sendable {
  private let fileHandle: FileHandle
  private let stream: LocalAgentProcessOutputStream
  private let outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?

  init(
    fileHandle: FileHandle,
    stream: LocalAgentProcessOutputStream,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) {
    self.fileHandle = fileHandle
    self.stream = stream
    self.outputEventHandler = outputEventHandler
  }

  func readToEnd() -> Data {
    var output = Data()
    var pendingLine = Data()
    while true {
      let chunk = fileHandle.readData(ofLength: 4_096)
      guard !chunk.isEmpty else {
        break
      }
      output.append(chunk)
      pendingLine.append(chunk)
      emitCompleteLines(from: &pendingLine)
    }
    emitPendingLine(pendingLine)
    return output
  }

  private func emitCompleteLines(from pendingLine: inout Data) {
    while let newlineIndex = pendingLine.firstIndex(of: 10) {
      let lineData = pendingLine[..<newlineIndex]
      pendingLine.removeSubrange(...newlineIndex)
      emitLine(Data(lineData))
    }
  }

  private func emitPendingLine(_ pendingLine: Data) {
    guard !pendingLine.isEmpty else {
      return
    }
    emitLine(pendingLine)
  }

  private func emitLine(_ data: Data) {
    guard let outputEventHandler else {
      return
    }
    var lineData = data
    if lineData.last == 13 {
      lineData.removeLast()
    }
    guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else {
      return
    }
    outputEventHandler(LocalAgentProcessOutputEvent(stream: stream, line: line))
  }
}

private final class LocalProcessPipes: @unchecked Sendable {
  private let inputPipe: Pipe
  private let outputPipe: Pipe
  private let errorPipe: Pipe
  private let lock = NSLock()

  init(inputPipe: Pipe, outputPipe: Pipe, errorPipe: Pipe) {
    self.inputPipe = inputPipe
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
  }

  func closeParentOutputWriters() {
    lock.lock()
    defer { lock.unlock() }
    try? outputPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForWriting.close()
  }

  func closeForFailureOrTimeout() {
    lock.lock()
    defer { lock.unlock() }
    try? inputPipe.fileHandleForWriting.close()
    try? outputPipe.fileHandleForWriting.close()
    try? outputPipe.fileHandleForReading.close()
    try? errorPipe.fileHandleForWriting.close()
    try? errorPipe.fileHandleForReading.close()
  }
}

private final class LocalProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false
  private var didTimeout = false
  private var deadlineWorkItem: DispatchWorkItem?
  private let continuation: CheckedContinuation<LocalAgentProcessResult, Error>

  init(continuation: CheckedContinuation<LocalAgentProcessResult, Error>) {
    self.continuation = continuation
  }

  func setDeadlineWorkItem(_ workItem: DispatchWorkItem) {
    lock.lock()
    deadlineWorkItem = workItem
    lock.unlock()
  }

  func markTimedOut() {
    lock.lock()
    didTimeout = true
    lock.unlock()
  }

  func timedOut() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return didTimeout
  }

  func cancelDeadline() {
    lock.lock()
    let workItem = deadlineWorkItem
    lock.unlock()
    workItem?.cancel()
  }

  func resume(_ result: Result<LocalAgentProcessResult, Error>) {
    lock.lock()
    guard !didResume else {
      lock.unlock()
      return
    }
    didResume = true
    let workItem = deadlineWorkItem
    lock.unlock()

    workItem?.cancel()
    switch result {
    case let .success(value):
      continuation.resume(returning: value)
    case let .failure(error):
      continuation.resume(throwing: error)
    }
  }
}

private final class LocalProcessCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var didCancel = false
  private var didFinish = false
  private var processHandle: LocalProcessHandle?
  private var pipes: LocalProcessPipes?
  private var completion: LocalProcessCompletion?

  func configure(
    processHandle: LocalProcessHandle,
    pipes: LocalProcessPipes,
    completion: LocalProcessCompletion
  ) {
    let shouldCancel: Bool
    lock.lock()
    if didFinish {
      lock.unlock()
      return
    }
    self.processHandle = processHandle
    self.pipes = pipes
    self.completion = completion
    shouldCancel = didCancel
    lock.unlock()

    if shouldCancel {
      cancelConfiguredProcess(processHandle: processHandle, pipes: pipes, completion: completion)
    }
  }

  func cancel() {
    let currentProcessHandle: LocalProcessHandle?
    let currentPipes: LocalProcessPipes?
    let currentCompletion: LocalProcessCompletion?
    lock.lock()
    guard !didFinish, !didCancel else {
      lock.unlock()
      return
    }
    didCancel = true
    currentProcessHandle = processHandle
    currentPipes = pipes
    currentCompletion = completion
    lock.unlock()

    if let currentProcessHandle, let currentPipes, let currentCompletion {
      cancelConfiguredProcess(
        processHandle: currentProcessHandle,
        pipes: currentPipes,
        completion: currentCompletion
      )
    }
  }

  func finish() {
    lock.lock()
    didFinish = true
    processHandle = nil
    pipes = nil
    completion = nil
    lock.unlock()
  }

  private func cancelConfiguredProcess(
    processHandle: LocalProcessHandle,
    pipes: LocalProcessPipes,
    completion: LocalProcessCompletion
  ) {
    pipes.closeForFailureOrTimeout()
    if processHandle.terminateGroupOrProcess() {
      processHandle.scheduleKillIfRunning(after: 1)
    }
    completion.resume(.failure(CancellationError()))
  }
}

private final class CStringArray {
  private var pointers: [UnsafeMutablePointer<CChar>?]

  init(_ strings: [String]) {
    pointers = strings.map { strdup($0) }
    pointers.append(nil)
  }

  deinit {
    for pointer in pointers where pointer != nil {
      free(pointer)
    }
  }

  func withUnsafeMutableBufferPointer<Result>(
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
  ) rethrows -> Result {
    try pointers.withUnsafeMutableBufferPointer { buffer in
      try body(buffer.baseAddress!)
    }
  }
}

typealias LocalProcessSignal = @Sendable (pid_t, Int32) -> Int32

final class LocalProcessHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var processId: pid_t?
  private var processGroupId: pid_t?
  private var didExit = false
  private var killWorkItem: DispatchWorkItem?
  private let signalProcess: LocalProcessSignal

  init(signalProcess: @escaping LocalProcessSignal = { processId, signal in kill(processId, signal) }) {
    self.signalProcess = signalProcess
  }

  func store(processId: pid_t) {
    lock.lock()
    guard !didExit else {
      lock.unlock()
      return
    }
    self.processId = processId
    self.processGroupId = processId
    lock.unlock()
  }

  @discardableResult
  func terminateGroupOrProcess() -> Bool {
    signalGroupOrProcess(SIGTERM)
  }

  @discardableResult
  func killGroupOrProcess() -> Bool {
    signalGroupOrProcess(SIGKILL)
  }

  @discardableResult
  func scheduleKillIfRunning(after delay: TimeInterval) -> Bool {
    let workItem = DispatchWorkItem {
      self.killScheduledProcessGroup()
    }
    lock.lock()
    guard processGroupId != nil else {
      lock.unlock()
      workItem.cancel()
      return false
    }
    killWorkItem?.cancel()
    killWorkItem = workItem
    lock.unlock()

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: workItem)
    return true
  }

  func markExited(afterTimeout: Bool = false) {
    lock.lock()
    didExit = true
    processId = nil
    let groupId = processGroupId
    let workItem = killWorkItem
    lock.unlock()

    if afterTimeout, let groupId, processGroupIsLive(groupId) {
      return
    }

    lock.lock()
    processGroupId = nil
    killWorkItem = nil
    lock.unlock()
    workItem?.cancel()
  }

  private func killScheduledProcessGroup() {
    lock.lock()
    let groupId = processGroupId
    lock.unlock()
    guard let groupId else {
      return
    }
    guard processGroupIsLive(groupId) else {
      clearScheduledProcessGroup(groupId)
      return
    }
    clearScheduledProcessGroup(groupId)
    _ = signalProcess(-groupId, SIGKILL)
  }

  private func clearScheduledProcessGroup(_ groupId: pid_t) {
    lock.lock()
    if processGroupId == groupId {
      processGroupId = nil
      killWorkItem = nil
    }
    lock.unlock()
  }

  private func processGroupIsLive(_ groupId: pid_t) -> Bool {
    signalProcess(-groupId, 0) == 0
  }

  private func signalGroupOrProcess(_ signal: Int32) -> Bool {
    lock.lock()
    let groupId = processGroupId
    let pid = didExit ? nil : processId
    lock.unlock()
    guard let groupId else {
      return false
    }
    if signalProcess(-groupId, signal) == 0 {
      return true
    }
    guard let pid else {
      return false
    }
    return signalProcess(pid, signal) == 0
  }
}

private func localProcessTimeoutError() -> AdapterExecutionError {
  AdapterExecutionError(.timeout, "local agent process exceeded deadline and was terminated")
}

private func spawnProcess(
  configuration: LocalAgentProcessConfiguration,
  inputReadDescriptor: Int32,
  inputWriteDescriptor: Int32,
  outputReadDescriptor: Int32,
  outputWriteDescriptor: Int32,
  errorReadDescriptor: Int32,
  errorWriteDescriptor: Int32
) throws -> pid_t {
  #if canImport(Glibc)
  var fileActions = posix_spawn_file_actions_t()
  var attributes = posix_spawnattr_t()
  #else
  var fileActions: posix_spawn_file_actions_t?
  var attributes: posix_spawnattr_t?
  #endif
  posix_spawn_file_actions_init(&fileActions)
  posix_spawnattr_init(&attributes)
  defer {
    posix_spawn_file_actions_destroy(&fileActions)
    posix_spawnattr_destroy(&attributes)
  }

  try checkPosixSpawn(posix_spawn_file_actions_adddup2(&fileActions, inputReadDescriptor, STDIN_FILENO), operation: "dup stdin")
  try checkPosixSpawn(posix_spawn_file_actions_adddup2(&fileActions, outputWriteDescriptor, STDOUT_FILENO), operation: "dup stdout")
  try checkPosixSpawn(posix_spawn_file_actions_adddup2(&fileActions, errorWriteDescriptor, STDERR_FILENO), operation: "dup stderr")
  try checkPosixSpawn(posix_spawn_file_actions_addclose(&fileActions, inputReadDescriptor), operation: "close child stdin pipe")
  try checkPosixSpawn(posix_spawn_file_actions_addclose(&fileActions, inputWriteDescriptor), operation: "close child stdin writer")
  try checkPosixSpawn(posix_spawn_file_actions_addclose(&fileActions, outputReadDescriptor), operation: "close child stdout reader")
  try checkPosixSpawn(posix_spawn_file_actions_addclose(&fileActions, outputWriteDescriptor), operation: "close child stdout pipe")
  try checkPosixSpawn(posix_spawn_file_actions_addclose(&fileActions, errorReadDescriptor), operation: "close child stderr reader")
  try checkPosixSpawn(posix_spawn_file_actions_addclose(&fileActions, errorWriteDescriptor), operation: "close child stderr pipe")
  if let workingDirectoryURL = configuration.workingDirectoryURL {
    try workingDirectoryURL.path.withCString { path in
      try checkPosixSpawn(posix_spawn_file_actions_addchdir_np(&fileActions, path), operation: "set working directory")
    }
  }

  #if canImport(Darwin)
  let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
  #else
  let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
  #endif
  try checkPosixSpawn(posix_spawnattr_setflags(&attributes, spawnFlags), operation: "set process flags")
  try checkPosixSpawn(posix_spawnattr_setpgroup(&attributes, 0), operation: "set child process group")

  let arguments = [configuration.executableURL.path] + configuration.arguments
  let environment = ProcessInfo.processInfo.environment
    .filter { !configuration.unsetEnvironmentKeys.contains($0.key) }
    .merging(configuration.environment) { _, new in new }
    .map { "\($0.key)=\($0.value)" }
  let argv = CStringArray(arguments)
  let envp = CStringArray(environment)
  var processId = pid_t()

  let spawnResult = configuration.executableURL.path.withCString { executablePath in
    argv.withUnsafeMutableBufferPointer { argvPointer in
      envp.withUnsafeMutableBufferPointer { envPointer in
        posix_spawn(&processId, executablePath, &fileActions, &attributes, argvPointer, envPointer)
      }
    }
  }
  try checkPosixSpawn(spawnResult, operation: "spawn \(configuration.executableURL.path)")
  return processId
}

private func checkPosixSpawn(_ result: Int32, operation: String) throws {
  guard result == 0 else {
    throw AdapterExecutionError(.providerError, "local agent process failed to \(operation): \(String(cString: strerror(result)))")
  }
}

private func terminationStatus(fromWaitStatus status: Int32) -> Int32 {
  if status & 0x7f == 0 {
    return (status >> 8) & 0xff
  }
  return -(status & 0x7f)
}

public struct FoundationLocalAgentProcessRunner: LocalAgentProcessRunning, LocalAgentProcessEventStreaming {
  public init() {}

  public func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date? = nil) async throws -> LocalAgentProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil)
  }

  public func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date? = nil,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    let cancellationState = LocalProcessCancellationState()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let processHandle = LocalProcessHandle()
        let pipes = LocalProcessPipes(inputPipe: inputPipe, outputPipe: outputPipe, errorPipe: errorPipe)

        let outputGroup = DispatchGroup()
        let outputData = LockedProcessData()
        let errorData = LockedProcessData()
        let outputReader = LocalProcessPipeReader(
          fileHandle: outputPipe.fileHandleForReading,
          stream: .stdout,
          outputEventHandler: outputEventHandler
        )
        let errorReader = LocalProcessPipeReader(
          fileHandle: errorPipe.fileHandleForReading,
          stream: .stderr,
          outputEventHandler: outputEventHandler
        )

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
          outputData.store(outputReader.readToEnd())
          outputGroup.leave()
        }

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
          errorData.store(errorReader.readToEnd())
          outputGroup.leave()
        }

        let completion = LocalProcessCompletion(continuation: continuation)

        do {
          let processId = try spawnProcess(
            configuration: configuration,
            inputReadDescriptor: inputPipe.fileHandleForReading.fileDescriptor,
            inputWriteDescriptor: inputPipe.fileHandleForWriting.fileDescriptor,
            outputReadDescriptor: outputPipe.fileHandleForReading.fileDescriptor,
            outputWriteDescriptor: outputPipe.fileHandleForWriting.fileDescriptor,
            errorReadDescriptor: errorPipe.fileHandleForReading.fileDescriptor,
            errorWriteDescriptor: errorPipe.fileHandleForWriting.fileDescriptor
          )
          processHandle.store(processId: processId)
          cancellationState.configure(processHandle: processHandle, pipes: pipes, completion: completion)
          try? inputPipe.fileHandleForReading.close()
          pipes.closeParentOutputWriters()

          DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            _ = waitpid(processId, &status, 0)
            processHandle.markExited(afterTimeout: completion.timedOut())
            completion.cancelDeadline()
            outputGroup.notify(queue: .global(qos: .utility)) {
              if completion.timedOut() {
                return
              }

              let output = String(data: outputData.load(), encoding: .utf8) ?? ""
              let error = String(data: errorData.load(), encoding: .utf8) ?? ""
              cancellationState.finish()
              completion.resume(
                .success(
                  LocalAgentProcessResult(
                    stdout: output,
                    stderr: error,
                    terminationStatus: terminationStatus(fromWaitStatus: status)
                  )
                )
              )
            }
          }

          if let deadline {
            let delay = max(0, deadline.timeIntervalSinceNow)
            let workItem = DispatchWorkItem {
              completion.markTimedOut()
              pipes.closeForFailureOrTimeout()
              if processHandle.terminateGroupOrProcess() {
                processHandle.scheduleKillIfRunning(after: 1)
              }
              cancellationState.finish()
              completion.resume(.failure(localProcessTimeoutError()))
            }
            completion.setDeadlineWorkItem(workItem)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: workItem)
          }
          inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
          try inputPipe.fileHandleForWriting.close()
        } catch {
          pipes.closeForFailureOrTimeout()
          processHandle.terminateGroupOrProcess()
          if completion.timedOut() {
            cancellationState.finish()
            completion.resume(.failure(localProcessTimeoutError()))
          } else {
            cancellationState.finish()
            completion.resume(.failure(error))
          }
        }
      }
    } onCancel: {
      cancellationState.cancel()
    }
  }
}

public struct LocalAgentCommandAdapter: NodeAdapter {
  public var commandBuilder: any LocalAgentCommandBuilding
  public var runner: any LocalAgentProcessRunning

  public init(
    commandBuilder: any LocalAgentCommandBuilding,
    runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner()
  ) {
    self.commandBuilder = commandBuilder
    self.runner = runner
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let command = try commandBuilder.buildCommand(for: input)
    let result: LocalAgentProcessResult
    if let streamingRunner = runner as? any LocalAgentProcessEventStreaming {
      result = try await streamingRunner.run(
        configuration: command.configuration,
        stdin: command.stdin,
        deadline: context.deadline,
        outputEventHandler: outputEventHandler(command: command, context: context)
      )
    } else {
      result = try await runner.run(configuration: command.configuration, stdin: command.stdin, deadline: context.deadline)
    }
    guard result.terminationStatus == 0 else {
      let detail = redactAdapterSensitiveText(
        result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
        additionalSensitiveValues: sensitiveAdapterEnvironmentValues(command.configuration.environment)
      )
      throw AdapterExecutionError(.providerError, "\(command.provider) failed with exit code \(result.terminationStatus): \(detail)")
    }

    let responseText = command.normalizeStdout(result.stdout)
    let normalized = try normalizeAgentOutput(responseText, source: command.provider, requiresOutputContract: input.node.output != nil)
    return AdapterExecutionOutput(
      provider: command.provider,
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: normalized.completionPassed,
      when: normalized.when,
      payload: normalized.payload
    )
  }

  private func outputEventHandler(
    command: LocalAgentCommand,
    context: AdapterExecutionContext
  ) -> (@Sendable (LocalAgentProcessOutputEvent) -> Void)? {
    guard let backendEventHandler = context.backendEventHandler else {
      return nil
    }
    return { outputEvent in
      guard outputEvent.stream == .stdout,
            let eventType = command.backendEventType(outputEvent.line) else {
        return
      }
      let semaphore = DispatchSemaphore(value: 0)
      Task {
        await backendEventHandler(AdapterBackendEvent(provider: command.provider, eventType: eventType))
        semaphore.signal()
      }
      semaphore.wait()
    }
  }

  private func normalizeAgentOutput(
    _ text: String,
    source: String,
    requiresOutputContract: Bool
  ) throws -> OutputContractEnvelopeNormalization {
    guard requiresOutputContract else {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("{"),
        let parsed = try? parseJSONObjectCandidate(trimmed, source: source),
        let normalized = try? normalizeOutputContractEnvelope(parsed, source: source) {
        return normalized
      }
      return OutputContractEnvelopeNormalization(
        completionPassed: true,
        when: ["always": true],
        payload: normalizeTextBusinessPayload(text),
        usedEnvelope: false
      )
    }

    let parsed = try parseJSONObjectCandidate(text, source: source)
    return try normalizeOutputContractEnvelope(parsed, source: source)
  }
}
