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
  public var sandboxPolicy: LocalProcessSandboxPolicy?

  public init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String] = [:],
    unsetEnvironmentKeys: Set<String> = [],
    workingDirectoryURL: URL? = nil,
    sandboxPolicy: LocalProcessSandboxPolicy? = nil
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.unsetEnvironmentKeys = unsetEnvironmentKeys
    self.workingDirectoryURL = workingDirectoryURL
    self.sandboxPolicy = sandboxPolicy
  }
}

/// Backend-specific tool-child liveness monitor (codex terminal-child stall
/// recovery). The adapter drives its lifecycle: `start` before the process
/// spawns, `processSpawned` once the direct agent child's pid is known, raw
/// stdout lines during streaming, and `stop` on completion, failure, or
/// cancellation — after `stop` returns, no monitor task or signal may remain
/// live.
public protocol LocalAgentToolChildMonitoring: Sendable {
  func start(emitBackendEvent: @escaping @Sendable (AdapterBackendEvent) -> Void)
  func processSpawned(_ processId: Int32)
  func observeStdoutLine(_ line: String)
  func stop() async
}

public struct LocalAgentCommand: Sendable {
  public var provider: String
  public var metadata: JSONObject
  public var additionalSensitiveValues: [String]
  public var configuration: LocalAgentProcessConfiguration
  public var stdin: String
  public var normalizeStdout: @Sendable (String) -> String
  public var backendEventType: @Sendable (String) -> String?
  public var classifyBackendEvent: (@Sendable (String) -> AdapterBackendEvent?)?
  /// Observes raw stdout JSONL without consuming or rewriting normal output.
  public var observeStdoutLine: (@Sendable (String) -> Void)?
  /// Called after a zero process exit and before output normalization.
  public var processDidSucceed: (@Sendable () -> Void)?
  /// Optional terminal tool-child stall monitor (nil = policy off).
  public var toolChildMonitor: (any LocalAgentToolChildMonitoring)?

  public init(
    provider: String,
    metadata: JSONObject = [:],
    additionalSensitiveValues: [String] = [],
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    normalizeStdout: @escaping @Sendable (String) -> String = { $0 },
    backendEventType: @escaping @Sendable (String) -> String? = { _ in nil },
    classifyBackendEvent: (@Sendable (String) -> AdapterBackendEvent?)? = nil,
    observeStdoutLine: (@Sendable (String) -> Void)? = nil,
    processDidSucceed: (@Sendable () -> Void)? = nil,
    toolChildMonitor: (any LocalAgentToolChildMonitoring)? = nil
  ) {
    self.provider = provider
    self.metadata = metadata
    self.additionalSensitiveValues = additionalSensitiveValues
    self.configuration = configuration
    self.stdin = stdin
    self.normalizeStdout = normalizeStdout
    self.backendEventType = backendEventType
    self.classifyBackendEvent = classifyBackendEvent
    self.observeStdoutLine = observeStdoutLine
    self.processDidSucceed = processDidSucceed
    self.toolChildMonitor = toolChildMonitor
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

/// Streaming runners that can additionally report the spawned direct child's
/// pid, enabling tool-child correlation. Optional capability; runners without
/// it simply never bind process identities.
public protocol LocalAgentProcessSpawnObserving: LocalAgentProcessEventStreaming {
  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?,
    spawnHandler: (@Sendable (Int32) -> Void)?
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
  private let fileDescriptor: Int32
  private let stream: LocalAgentProcessOutputStream
  private let outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?

  init(
    fileHandle: FileHandle,
    stream: LocalAgentProcessOutputStream,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) {
    self.fileDescriptor = fileHandle.fileDescriptor
    self.stream = stream
    self.outputEventHandler = outputEventHandler
  }

  func readToEnd() -> Data {
    var output = Data()
    var pendingLine = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let byteCount = buffer.withUnsafeMutableBytes { pointer in
        read(fileDescriptor, pointer.baseAddress, pointer.count)
      }
      if byteCount == 0 {
        break
      }
      if byteCount < 0 {
        if errno == EINTR {
          continue
        }
        break
      }
      let chunk = Data(buffer.prefix(byteCount))
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

private struct LocalProcessStdinWriter: Sendable {
  var fileDescriptor: Int32
  var stdin: String

  func writeAndClose() {
    disableSigpipeForStdin(fileDescriptor)
    let data = Data(stdin.utf8)
    data.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        return
      }
      var written = 0
      while written < buffer.count {
        let byteCount = min(16_384, buffer.count - written)
        let result = write(fileDescriptor, baseAddress.advanced(by: written), byteCount)
        if result > 0 {
          written += result
          continue
        }
        if result == -1 && errno == EINTR {
          continue
        }
        if result == -1 && (errno == EPIPE || errno == EBADF) {
          break
        }
        break
      }
    }
    _ = close(fileDescriptor)
  }
}

private final class LocalProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false
  private var didTimeout = false
  private var didCancel = false
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

  func markCancelled() {
    lock.lock()
    didCancel = true
    lock.unlock()
  }

  func timedOut() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return didTimeout
  }

  func cancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return didCancel
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
    completion.markCancelled()
    pipes.closeForFailureOrTimeout()
    if processHandle.terminateGroupOrProcess() {
      processHandle.scheduleKillIfRunning(after: 1)
    }
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

private func disableSigpipeForStdin(_ fileDescriptor: Int32) {
  #if canImport(Darwin)
  _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
  #else
  _ = signal(SIGPIPE, SIG_IGN)
  #endif
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

public struct FoundationLocalAgentProcessRunner: LocalAgentProcessRunning, LocalAgentProcessEventStreaming, LocalAgentProcessSpawnObserving {
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
    try await run(
      configuration: configuration,
      stdin: stdin,
      deadline: deadline,
      outputEventHandler: outputEventHandler,
      spawnHandler: nil
    )
  }

  public func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date? = nil,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?,
    spawnHandler: (@Sendable (Int32) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    let effectiveConfiguration = try seatbeltInvocation(for: configuration) ?? configuration
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
            configuration: effectiveConfiguration,
            inputReadDescriptor: inputPipe.fileHandleForReading.fileDescriptor,
            inputWriteDescriptor: inputPipe.fileHandleForWriting.fileDescriptor,
            outputReadDescriptor: outputPipe.fileHandleForReading.fileDescriptor,
            outputWriteDescriptor: outputPipe.fileHandleForWriting.fileDescriptor,
            errorReadDescriptor: errorPipe.fileHandleForReading.fileDescriptor,
            errorWriteDescriptor: errorPipe.fileHandleForWriting.fileDescriptor
          )
          processHandle.store(processId: processId)
          spawnHandler?(Int32(processId))
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
              if completion.cancelled() {
                cancellationState.finish()
                completion.resume(.failure(CancellationError()))
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
          let stdinWriter = LocalProcessStdinWriter(
            fileDescriptor: inputPipe.fileHandleForWriting.fileDescriptor,
            stdin: stdin
          )
          DispatchQueue.global(qos: .utility).async {
            stdinWriter.writeAndClose()
          }
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
  public var backendEventCoalescingTimeThreshold: TimeInterval

  public init(
    commandBuilder: any LocalAgentCommandBuilding,
    runner: any LocalAgentProcessRunning = FoundationLocalAgentProcessRunner(),
    backendEventCoalescingTimeThreshold: TimeInterval = 0.25
  ) {
    self.commandBuilder = commandBuilder
    self.runner = runner
    self.backendEventCoalescingTimeThreshold = backendEventCoalescingTimeThreshold
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let command = try commandBuilder.buildCommand(for: input)
    let result: LocalAgentProcessResult
    if let streamingRunner = runner as? any LocalAgentProcessEventStreaming {
      let eventBridge = makeBackendEventBridge(
        command: command,
        context: context,
        streamContent: backendContentStreamingEnabled(input.node.variables["streamBackendContent"]),
        coalescingTimeThreshold: backendEventCoalescingTimeThreshold
      )
      let monitor = command.toolChildMonitor
      monitor?.start(emitBackendEvent: eventBridge.emitInjected)
      let outputHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
      let bridgeHandler = eventBridge.handler
      if monitor != nil || command.observeStdoutLine != nil || bridgeHandler != nil {
        outputHandler = { outputEvent in
          if outputEvent.stream == .stdout {
            command.observeStdoutLine?(outputEvent.line)
            monitor?.observeStdoutLine(outputEvent.line)
          }
          bridgeHandler?(outputEvent)
        }
      } else {
        outputHandler = nil
      }
      do {
        if let monitor, let spawnObservingRunner = streamingRunner as? any LocalAgentProcessSpawnObserving {
          result = try await spawnObservingRunner.run(
            configuration: command.configuration,
            stdin: command.stdin,
            deadline: context.deadline,
            outputEventHandler: outputHandler,
            spawnHandler: { monitor.processSpawned($0) }
          )
        } else {
          result = try await streamingRunner.run(
            configuration: command.configuration,
            stdin: command.stdin,
            deadline: context.deadline,
            outputEventHandler: outputHandler
          )
        }
        await monitor?.stop()
        eventBridge.finish()
        await eventBridge.waitForCompletion()
      } catch {
        await monitor?.stop()
        eventBridge.finish()
        await eventBridge.waitForCompletion()
        throw redactedCommandExecutionError(error, command: command)
      }
    } else {
      do {
        result = try await runner.run(configuration: command.configuration, stdin: command.stdin, deadline: context.deadline)
      } catch {
        throw redactedCommandExecutionError(error, command: command)
      }
      for line in result.stdout.split(whereSeparator: \.isNewline) {
        command.observeStdoutLine?(String(line))
      }
    }
    guard result.terminationStatus == 0 else {
      let detail = redactAdapterSensitiveText(
        result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
        additionalSensitiveValues: commandSensitiveValues(command)
      )
      throw AdapterExecutionError(.providerError, "\(command.provider) failed with exit code \(result.terminationStatus): \(detail)")
    }
    command.processDidSucceed?()

    let responseText = redactAdapterSensitiveText(
      command.normalizeStdout(result.stdout),
      additionalSensitiveValues: commandSensitiveValues(command)
    )
    let normalized = try normalizeAgentOutput(responseText, source: command.provider, requiresOutputContract: input.node.output != nil)
    let sensitiveValues = commandSensitiveValues(command)
    var payload = sanitizedJSONObject(normalized.payload, sensitiveValues: sensitiveValues)
    payload.merge(sanitizedJSONObject(command.metadata, sensitiveValues: sensitiveValues)) { _, metadataValue in metadataValue }
    return AdapterExecutionOutput(
      provider: command.provider,
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: normalized.completionPassed,
      when: sanitizedWhen(normalized.when, sensitiveValues: sensitiveValues),
      payload: payload
    )
  }

  private func makeBackendEventBridge(
    command: LocalAgentCommand,
    context: AdapterExecutionContext,
    streamContent: Bool,
    coalescingTimeThreshold: TimeInterval
  ) -> BackendEventBridge {
    guard let backendEventHandler = context.backendEventHandler else {
      return BackendEventBridge(handler: nil, emitInjected: { _ in }, finish: {}, waitForCompletion: {})
    }
    let sensitiveValues = commandSensitiveValues(command)
    let (eventStream, continuation) = AsyncStream.makeStream(
      of: AdapterBackendEvent.self,
      bufferingPolicy: .bufferingNewest(512)
    )
    let consumer = Task {
      for await event in eventStream {
        await backendEventHandler(event)
      }
    }
    let coalescer = BackendEventCoalescer(timeThreshold: coalescingTimeThreshold)
    let handler: @Sendable (LocalAgentProcessOutputEvent) -> Void = { outputEvent in
      guard outputEvent.stream == .stdout else {
        return
      }
      let classified = command.classifyBackendEvent?(outputEvent.line)
      let selectedEvent = streamContent || classified?.backendSessionId != nil ? classified : nil
      guard var event = selectedEvent ?? fallbackBackendEvent(command: command, line: outputEvent.line) else {
        return
      }
      if event.provider.isEmpty {
        event.provider = command.provider
      }
      if !command.metadata.isEmpty {
        event.metadata = (event.metadata ?? [:]).merging(command.metadata) { _, commandValue in commandValue }
      }
      event = sanitizedBackendEvent(event, sensitiveValues: sensitiveValues)
      coalescer.absorb(event) { continuation.yield($0) }
    }
    return BackendEventBridge(
      handler: handler,
      emitInjected: { event in
        var event = event
        if !command.metadata.isEmpty {
          event.metadata = (event.metadata ?? [:]).merging(command.metadata) { _, commandValue in commandValue }
        }
        event = sanitizedBackendEvent(event, sensitiveValues: sensitiveValues)
        _ = continuation.yield(event)
      },
      finish: {
        coalescer.finish { continuation.yield($0) }
        continuation.finish()
      },
      waitForCompletion: { await consumer.value }
    )
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
