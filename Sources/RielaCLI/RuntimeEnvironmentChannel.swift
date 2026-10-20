import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RielaCore

/// The only decodable value-bearing wire object. Never exposed to CLI output,
/// telemetry, workflow variables, or persisted configuration.
private struct RuntimeEnvironmentFrame: Decodable {
  var generation: UInt64
  var managedNames: [String]
  var values: [String: String]
}

struct RuntimeEnvironmentAcknowledgement: Codable, Equatable, Sendable {
  var type = "runtime-environment-ack"
  var generation: UInt64?
  var names: [String]
  var accepted: Bool
  var error: String?
}

actor EventRuntimeEnvironment {
  private let base: [String: String]
  private var environment: [String: String]?
  private var managedNames: Set<String>?
  private var generation: UInt64 = 0
  private var failed = false
  private var firstWaiters: [CheckedContinuation<Void, Error>] = []

  init(base: [String: String], requiresBootstrap: Bool = false) {
    self.base = base
    environment = requiresBootstrap ? nil : base
  }

  func capture() throws -> [String: String] {
    guard let environment else { throw CLIUsageError("environment_channel_unprepared") }
    return environment
  }

  func awaitInitial() async throws {
    if environment != nil { return }
    if failed { throw CLIUsageError("environment_channel_closed") }
    try await withCheckedThrowingContinuation { firstWaiters.append($0) }
  }

  func replace(_ data: Data) -> RuntimeEnvironmentAcknowledgement {
    var received: UInt64?
    do {
      guard data.count <= 1_048_576 else { throw CLIUsageError("environment_channel_invalid") }
      let frame = try JSONDecoder().decode(RuntimeEnvironmentFrame.self, from: data)
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
  }
}

/// A bounded reader on a private pipe. EOF affects bootstrap only; an already
/// captured generation remains available. No stdin ownership without the flag.
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
      guard frame.count <= 1_048_576 else { finish(); return }
      if case .dropped = continuation?.yield(frame) { finish(); return }
    }
    if buffer.count > 1_048_576 { finish() }
  }

  private func finish() {
    stopped = true; input.readabilityHandler = nil; buffer.removeAll()
    continuation?.finish(); continuation = nil
  }

  func stop() { lock.lock(); defer { lock.unlock() }; finish() }
  deinit { input.readabilityHandler = nil; continuation?.finish(); task?.cancel() }
}
