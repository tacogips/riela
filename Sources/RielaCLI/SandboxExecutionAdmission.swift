import Foundation
import RielaCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Kernel-owned leases use the same gate/slot names as the legacy ART pool.
/// A failed weighted acquisition releases every partial slot before waiting.
final class SandboxExecutionAdmission: @unchecked Sendable {
  private let descriptors: [Int32]

  private init(_ descriptors: [Int32]) { self.descriptors = descriptors }

  deinit { for descriptor in descriptors { close(descriptor) } }

  static func acquire(_ policy: WorkflowExecutionAdmission?, environment: [String: String],
                      deadline: Date?) async throws -> SandboxExecutionAdmission? {
    guard let policy else { return nil }
    try policy.validate()
    guard let path = environment[policy.directoryEnvironment], path.hasPrefix("/"),
          path.utf8.count <= 4096, !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          URL(fileURLWithPath: path).standardizedFileURL.path != "/" else { throw invalid() }
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { throw invalid() }
    let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryDescriptor >= 0 else { throw invalid() }
    var metadata = stat()
    let owned = fstat(directoryDescriptor, &metadata) == 0 && metadata.st_uid == geteuid()
    close(directoryDescriptor)
    guard owned else { throw invalid() }
    let limit = min(deadline ?? .distantFuture, Date().addingTimeInterval(TimeInterval(policy.waitTimeoutSeconds)))
    while true {
      try Task.checkCancellation()
      guard Date() < limit else { throw AdapterExecutionError(.timeout, "sandbox admission deadline reached") }
      if let lease = try attempt(policy, directory: directory) {
        try Task.checkCancellation()
        guard Date() < limit else { throw AdapterExecutionError(.timeout, "sandbox admission deadline reached") }
        return lease
      }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  private static func attempt(_ policy: WorkflowExecutionAdmission, directory: URL) throws -> SandboxExecutionAdmission? {
    let gate = try openLock(directory.appendingPathComponent("admission.lock"))
    defer { close(gate) }
    guard try lock(gate) else { return nil }
    try checkCapacity(policy.capacity, directory: directory)
    var slots: [Int32] = []
    var transferred = false
    defer { if !transferred { for descriptor in slots { close(descriptor) } } }
    for index in 0..<policy.capacity {
      let descriptor = try openLock(directory.appendingPathComponent(String(index)))
      do {
        if try lock(descriptor) { slots.append(descriptor) } else { close(descriptor) }
      } catch { close(descriptor); throw error }
      if slots.count == policy.weight {
        transferred = true
        return .init(slots)
      }
    }
    return nil
  }

  private static func openLock(_ url: URL) throws -> Int32 {
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw invalid() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(),
          metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), fchmod(descriptor, 0o600) == 0 else {
      close(descriptor)
      throw invalid()
    }
    return descriptor
  }

  private static func lock(_ descriptor: Int32) throws -> Bool {
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR { continue }
      if errno == EWOULDBLOCK || errno == EAGAIN { return false }
      throw invalid()
    }
    return true
  }

  private static func checkCapacity(_ capacity: Int, directory: URL) throws {
    let descriptor = try openLock(directory.appendingPathComponent("capacity"))
    defer { close(descriptor) }
    var bytes = [UInt8](repeating: 0, count: 32)
    let count = read(descriptor, &bytes, bytes.count)
    guard count >= 0, count < bytes.count else { throw invalid() }
    if count == 0 {
      let value = Array("\(capacity)\n".utf8)
      guard value.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == value.count else { throw invalid() }
    } else {
      guard String(bytes: bytes.prefix(count), encoding: .utf8) == "\(capacity)\n" else {
        throw AdapterExecutionError(.policyBlocked, "sandbox admission capacity differs from the shared pool")
      }
    }
  }

  private static func invalid() -> AdapterExecutionError {
    .init(.policyBlocked, "sandbox admission requires an available host-owned pool directory")
  }
}
