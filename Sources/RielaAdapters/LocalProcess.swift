import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct LocalProcessConfiguration: Equatable, Sendable {
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

public struct LocalProcessResult: Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var terminationStatus: Int32

  public init(stdout: String, stderr: String, terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol LocalProcessRunning: Sendable {
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult
}

public enum LocalProcessOutputStream: String, Equatable, Sendable {
  case stdout
  case stderr
}

public struct LocalProcessOutputEvent: Equatable, Sendable {
  public var stream: LocalProcessOutputStream
  public var line: String

  public init(stream: LocalProcessOutputStream, line: String) {
    self.stream = stream
    self.line = line
  }
}

public protocol LocalProcessEventStreaming: LocalProcessRunning {
  func run(
    configuration: LocalProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalProcessOutputEvent) -> Void)?
  ) async throws -> LocalProcessResult
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
  private let fileDescriptor: Int32
  private let stream: LocalProcessOutputStream
  private let outputEventHandler: (@Sendable (LocalProcessOutputEvent) -> Void)?

  init(
    fileHandle: FileHandle,
    stream: LocalProcessOutputStream,
    outputEventHandler: (@Sendable (LocalProcessOutputEvent) -> Void)?
  ) {
    self.fileHandle = fileHandle
    self.fileDescriptor = fileHandle.fileDescriptor
    self.stream = stream
    self.outputEventHandler = outputEventHandler
  }

  func readToEnd() -> Data {
    defer { try? fileHandle.close() }
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
    outputEventHandler(LocalProcessOutputEvent(stream: stream, line: line))
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
    try? errorPipe.fileHandleForWriting.close()
    // Each reader owns its handle through EOF. Closing its descriptor from
    // another thread would permit fd reuse while a read is still in flight.
    // Process-group termination closes child writers and wakes both readers.
  }
}

private final class LocalProcessStdinWriter: @unchecked Sendable {
  private let fileDescriptor: Int32
  private let stdin: String

  init(fileHandle: FileHandle, stdin: String) throws {
    // Own a distinct descriptor before cancellation can close the Pipe's
    // handle. Capturing only its numeric fd would still permit descriptor
    // reuse between cancellation and the asynchronous writer starting.
    let descriptor = fcntl(fileHandle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    fileDescriptor = descriptor
    self.stdin = stdin
  }

  deinit { _ = close(fileDescriptor) }

  func writeAndClose(onStarted: (@Sendable () -> Void)? = nil) {
    disableSigpipeForStdin(fileDescriptor)
    onStarted?()
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
  }
}

private final class LocalProcessCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false
  private var didTimeout = false
  private var didCancel = false
  private var deadlineWorkItem: DispatchWorkItem?
  private let continuation: CheckedContinuation<LocalProcessResult, Error>

  init(continuation: CheckedContinuation<LocalProcessResult, Error>) {
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

  func resume(_ result: Result<LocalProcessResult, Error>) {
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

  /// Observe exit without reaping. The unreaped group leader pins its PID and
  /// PGID until all pending signals and output readers have finished, avoiding
  /// an ID-reuse race between waitpid and delayed descendant escalation.
  func waitForLeaderExit() -> Bool {
    lock.lock()
    let ownedPID = processId
    lock.unlock()
    guard let ownedPID else { return false }
    var information = siginfo_t()
    var result: Int32
    repeat {
      result = waitid(P_PID, id_t(ownedPID), &information, WEXITED | WNOWAIT)
    } while result < 0 && errno == EINTR
    if result == 0 { return true }
    // Someone else reaped the child: ownership cannot be inferred from the
    // numeric ID any more, so fail closed without any subsequent signal.
    lock.lock()
    didExit = true
    processId = nil
    processGroupId = nil
    killWorkItem?.cancel()
    killWorkItem = nil
    lock.unlock()
    return false
  }

  func reapAfterOutput(terminateRemaining: Bool) -> Int32 {
    lock.lock()
    defer { lock.unlock() }
    guard let ownedPID = processId else { return 0 }
    if terminateRemaining, let groupId = processGroupId {
      _ = signalProcess(-groupId, SIGKILL)
    }
    // Signals execute under this same lock. Clear their authority before
    // releasing the PID back to the OS, not after waitpid returns.
    didExit = true
    processId = nil
    processGroupId = nil
    killWorkItem?.cancel()
    killWorkItem = nil
    var status: Int32 = 0
    while waitpid(ownedPID, &status, 0) < 0, errno == EINTR {}
    return status
  }

  private func killScheduledProcessGroup() {
    lock.lock()
    defer { lock.unlock() }
    guard let groupId = processGroupId, processId != nil else { return }
    _ = signalProcess(-groupId, SIGKILL)
    killWorkItem = nil
  }

  private func signalGroupOrProcess(_ signal: Int32) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let groupId = processGroupId
    let pid = didExit ? nil : processId
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
  configuration: LocalProcessConfiguration,
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
  let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
  #else
  let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
  #endif
  // The CLI uses ignored dispositions plus DispatchSource for these signals.
  // Do not inherit SIG_IGN into command shells: an ignored-on-entry signal
  // cannot be trapped by a non-interactive shell, preventing graceful cancel.
  var defaultSignals = sigset_t()
  sigemptyset(&defaultSignals)
  for signalNumber in [SIGINT, SIGTERM, SIGPIPE] { sigaddset(&defaultSignals, signalNumber) }
  try checkPosixSpawn(posix_spawnattr_setsigdefault(&attributes, &defaultSignals), operation: "reset child signal dispositions")
  var signalMask = sigset_t()
  sigemptyset(&signalMask)
  try checkPosixSpawn(posix_spawnattr_setsigmask(&attributes, &signalMask), operation: "reset child signal mask")
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

/// Runs one foreground command. Its dedicated process group belongs to this
/// invocation, including background children that remain after the leader
/// exits. A command must not escape that group (setsid/setpgid/daemonization);
/// detached services require a separately owned lifecycle, not this runner.
public struct FoundationLocalProcessRunner: LocalProcessRunning, LocalProcessEventStreaming {
  public init() {}

  public func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date? = nil) async throws -> LocalProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil)
  }

  public func run(
    configuration: LocalProcessConfiguration,
    stdin: String,
    deadline: Date? = nil,
    outputEventHandler: (@Sendable (LocalProcessOutputEvent) -> Void)?
  ) async throws -> LocalProcessResult {
    try await run(
      configuration: configuration,
      stdin: stdin,
      deadline: deadline,
      outputEventHandler: outputEventHandler,
      stdinWriterStartedHandler: nil
    )
  }

  /// Testable cancellation boundary: invoked by the writer after it owns a
  /// duplicated stdin descriptor and immediately before its first write.
  public func run(
    configuration: LocalProcessConfiguration,
    stdin: String,
    deadline: Date? = nil,
    outputEventHandler: (@Sendable (LocalProcessOutputEvent) -> Void)?,
    stdinWriterStartedHandler: (@Sendable () -> Void)?
  ) async throws -> LocalProcessResult {
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
          let stdinWriter = try LocalProcessStdinWriter(fileHandle: inputPipe.fileHandleForWriting, stdin: stdin)
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
          try? inputPipe.fileHandleForWriting.close()
          cancellationState.configure(processHandle: processHandle, pipes: pipes, completion: completion)
          try? inputPipe.fileHandleForReading.close()
          pipes.closeParentOutputWriters()

          DispatchQueue.global(qos: .utility).async {
            let ownsExitedChild = processHandle.waitForLeaderExit()
            if ownsExitedChild {
              // Do this before waiting for EOF: a background child can keep
              // the pipes open even after a successful leader exit. WNOWAIT
              // still pins signal authority; all leader bytes remain readable.
              processHandle.killGroupOrProcess()
            }
            outputGroup.notify(queue: .global(qos: .utility)) {
              let status = processHandle.reapAfterOutput(terminateRemaining: true)
              completion.cancelDeadline()
              if completion.timedOut() {
                cancellationState.finish()
                completion.resume(.failure(localProcessTimeoutError()))
                return
              }
              guard ownsExitedChild else {
                cancellationState.finish()
                completion.resume(.failure(POSIXError(.ECHILD)))
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
                  LocalProcessResult(
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
              // A deadline requests termination; it is not proof of process
              // completion. The exit/EOF/reap path returns the timeout only
              // after this invocation has reclaimed its owned group.
            }
            completion.setDeadlineWorkItem(workItem)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: workItem)
          }
          DispatchQueue.global(qos: .utility).async {
            stdinWriter.writeAndClose(onStarted: stdinWriterStartedHandler)
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
