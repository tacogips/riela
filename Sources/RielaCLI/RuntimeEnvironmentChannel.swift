import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RielaAppSupport
import RielaCore

/// Child-side name for the shared ACK wire type (`RielaAppSupport`).
typealias RuntimeEnvironmentAcknowledgement = RuntimeEnvironmentChannelAcknowledgement

actor EventRuntimeEnvironment {
  private enum WaitCondition {
    case generationAfter(UInt64)
    case closed
  }

  private let base: [String: String]
  private var environment: [String: String]?
  private var managedNames: Set<String>?
  private var generation: UInt64 = 0
  private var failed = false
  private var firstWaiters: [CheckedContinuation<Void, Error>] = []
  private var waiters: [UInt64: (WaitCondition, CheckedContinuation<Void, Error>)] = [:]
  private var nextWaiterToken: UInt64 = 0

  init(base: [String: String], requiresBootstrap: Bool = false) {
    self.base = base
    environment = requiresBootstrap ? nil : base
  }

  func capture() throws -> [String: String] {
    guard let environment else { throw CLIUsageError("environment_channel_unprepared") }
    return environment
  }

  /// Atomic snapshot plus the generation it belongs to (0 without a channel).
  func captureWithGeneration() throws -> (environment: [String: String], generation: UInt64) {
    (try capture(), generation)
  }

  var isClosed: Bool { failed }

  func awaitInitial() async throws {
    if environment != nil { return }
    if failed { throw CLIUsageError("environment_channel_closed") }
    try await withCheckedThrowingContinuation { firstWaiters.append($0) }
  }

  /// Returns once a generation newer than `generation` was accepted.
  /// Throws `CancellationError` when the calling task is cancelled.
  func awaitGeneration(after generation: UInt64) async throws {
    try await wait(for: .generationAfter(generation))
  }

  /// Returns once the channel reached EOF or was closed by an invalid read.
  /// Throws `CancellationError` when the calling task is cancelled.
  func awaitClosed() async throws {
    try await wait(for: .closed)
  }

  func replace(_ data: Data) -> RuntimeEnvironmentAcknowledgement {
    var received: UInt64?
    do {
      guard data.count <= RuntimeEnvironmentChannelWire.maxFrameBytes else {
        throw CLIUsageError("environment_channel_invalid")
      }
      let frame = try JSONDecoder().decode(RuntimeEnvironmentChannelFrame.self, from: data)
      received = frame.generation
      let names = try WorkflowEnvironmentRequirements.validated(frame.managedNames)
      let declared = Set(names)
      guard names.count == frame.managedNames.count, names.count <= 4096,
        frame.generation > generation, frame.generation > 0,
        managedNames == nil || managedNames == declared,
        Set(frame.values.keys).isSubset(of: declared),
        frame.values.values.allSatisfy({ !$0.utf8.contains(0) }) else {
        throw CLIUsageError("environment_channel_invalid")
      }
      var next = base
      for name in declared { next.removeValue(forKey: name) }
      next.merge(frame.values) { _, new in new }
      environment = next; managedNames = declared; generation = frame.generation
      for waiter in firstWaiters { waiter.resume() }
      firstWaiters.removeAll()
      resumeSatisfiedWaiters()
      return RuntimeEnvironmentAcknowledgement(generation: generation, names: names, accepted: true)
    } catch {
      return RuntimeEnvironmentAcknowledgement(generation: received, names: [], accepted: false,
        error: "environment_channel_invalid")
    }
  }

  func close() {
    failed = true
    for waiter in firstWaiters { waiter.resume(throwing: CLIUsageError("environment_channel_closed")) }
    firstWaiters.removeAll()
    resumeSatisfiedWaiters()
  }

  private func wait(for condition: WaitCondition) async throws {
    let token = nextWaiterToken
    nextWaiterToken += 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        // The cancellation flag is set before `onCancel` runs, so a cancel
        // that races registration is observed here.
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if isSatisfied(condition) {
          continuation.resume()
        } else {
          waiters[token] = (condition, continuation)
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(token) }
    }
  }

  private func cancelWaiter(_ token: UInt64) {
    waiters.removeValue(forKey: token)?.1.resume(throwing: CancellationError())
  }

  private func isSatisfied(_ condition: WaitCondition) -> Bool {
    switch condition {
    case .generationAfter(let value): return generation > value
    case .closed: return failed
    }
  }

  private func resumeSatisfiedWaiters() {
    for (token, waiter) in waiters where isSatisfied(waiter.0) {
      waiters.removeValue(forKey: token)
      waiter.1.resume()
    }
  }
}

/// Moves the private channel off the standard streams so no subprocess can
/// inherit it. The channel descriptors are duplicated close-on-exec above fd 2;
/// the original stdin and stdout descriptors are then pointed at /dev/null.
enum RuntimeEnvironmentChannelDescriptors {
  struct Detached {
    var input: FileHandle
    var output: FileHandle
  }

  static func detach(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO,
                     nullDevicePath: String = "/dev/null") throws -> Detached {
    let privateInput = fcntl(input, F_DUPFD_CLOEXEC, 3)
    guard privateInput >= 0 else { throw CLIUsageError("environment_channel_unavailable") }
    let privateOutput = fcntl(output, F_DUPFD_CLOEXEC, 3)
    guard privateOutput >= 0 else {
      close(privateInput)
      throw CLIUsageError("environment_channel_unavailable")
    }
    let null = open(nullDevicePath, O_RDWR | O_CLOEXEC)
    guard null >= 0 else {
      close(privateInput); close(privateOutput)
      throw CLIUsageError("environment_channel_unavailable")
    }
    defer { close(null) }
    // dup2 clears FD_CLOEXEC on the target, so the replaced standard streams
    // stay inheritable and simply read EOF / discard writes.
    guard dup2(null, input) >= 0, dup2(null, output) >= 0 else {
      close(privateInput); close(privateOutput)
      throw CLIUsageError("environment_channel_unavailable")
    }
    return Detached(input: FileHandle(fileDescriptor: privateInput, closeOnDealloc: true),
                    output: FileHandle(fileDescriptor: privateOutput, closeOnDealloc: true))
  }

  /// Writes `message` to stderr only when it is a safe code (lowercase
  /// snake case, at most 96 bytes), so free-form error text never leaves.
  static func reportSafeCode(_ message: String, to handle: FileHandle = .standardError) {
    guard let line = safeCodeLine(message) else { return }
    try? handle.write(contentsOf: Data(line.utf8))
  }

  static func safeCodeLine(_ message: String) -> String? {
    let bytes = Array(message.utf8)
    guard (1...96).contains(bytes.count), (97...122).contains(bytes[0]),
      bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
    return message + "\n"
  }
}

/// A bounded reader on a private pipe. EOF before the first frame fails
/// bootstrap; EOF afterwards marks the channel closed, which `events serve`
/// treats as "the parent is gone" and stops serving. No stdin ownership
/// without the flag.
final class RuntimeEnvironmentChannel: @unchecked Sendable {
  private let input: FileHandle
  private let output: FileHandle
  private let state: EventRuntimeEnvironment
  private let lock = NSLock()
  private var buffer = Data()
  private var stopped = false
  private var continuation: AsyncStream<Data>.Continuation?
  private var task: Task<Void, Never>?

  init(state: EventRuntimeEnvironment, input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
    self.state = state; self.input = input; self.output = output
    let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(4)) { continuation = $0 }
    task = Task { [state, output] in
      for await frame in stream {
        let ack = await state.replace(frame)
        if let data = try? JSONEncoder().encode(ack) {
          try? output.write(contentsOf: data + Data([10]))
        }
      }
      await state.close()
    }
    input.readabilityHandler = { [weak self] handle in self?.receive(handle) }
  }

  private func receive(_ handle: FileHandle) {
    lock.lock(); defer { lock.unlock() }
    guard !stopped else { return }
    var bytes = [UInt8](repeating: 0, count: 16_384)
    let count = read(handle.fileDescriptor, &bytes, bytes.count)
    guard count > 0 else { finish(); return }
    buffer.append(contentsOf: bytes.prefix(count))
    while let end = buffer.firstIndex(of: 10) {
      let frame = Data(buffer[..<end]); buffer.removeSubrange(...end)
      guard frame.count <= RuntimeEnvironmentChannelWire.maxFrameBytes else { finish(); return }
      if case .dropped = continuation?.yield(frame) { finish(); return }
    }
    if buffer.count > RuntimeEnvironmentChannelWire.maxFrameBytes { finish() }
  }

  private func finish() {
    stopped = true; input.readabilityHandler = nil; buffer.removeAll()
    continuation?.finish(); continuation = nil
  }

  func stop() { lock.lock(); defer { lock.unlock() }; finish() }
  deinit { input.readabilityHandler = nil; continuation?.finish(); task?.cancel() }
}
