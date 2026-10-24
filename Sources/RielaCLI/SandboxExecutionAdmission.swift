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
  /// Fixed, path-free refusal messages. Each cause has its own text so an
  /// operator can tell a missing host variable from a foreign-owned directory.
  enum Refusal {
    static let missingEnvironment = "sandbox admission pool directory variable is not set by the host"
    static let invalidPath = "sandbox admission pool directory must be an absolute, non-root path without control characters"
    static let createFailed = "sandbox admission pool directory could not be created"
    static let openFailed = "sandbox admission pool directory could not be opened"
    static let notOwned = "sandbox admission pool directory is not owned by the current user"
    static let networkFilesystem = "sandbox admission pool directory must be on a local filesystem"
    static let lockFileSymlink = "sandbox admission lock file must not be a symbolic link"
    static let lockFileOpen = "sandbox admission lock file could not be opened"
    static let lockFileType = "sandbox admission lock file is not an owner-only regular file"
    static let lockFailed = "sandbox admission lock operation failed"
    static let capacityRead = "sandbox admission capacity record could not be read"
    static let capacityWrite = "sandbox admission capacity record could not be written"
    static let capacityCorrupt = "sandbox admission capacity record is not a pool size; remove it while the pool is idle"
    static let capacityMismatch = "sandbox admission capacity differs from the shared pool"
  }

  private let descriptors: [Int32]

  private init(_ descriptors: [Int32]) { self.descriptors = descriptors }

  deinit { for descriptor in descriptors { close(descriptor) } }

  /// Runs `body` while holding the lease, so the lease scope is explicit and a
  /// refactor cannot shorten it. A nil policy runs `body` without admission.
  static func withLease<T>(_ policy: WorkflowExecutionAdmission?, environment: [String: String], deadline: Date?,
                           isolation: isolated (any Actor)? = #isolation,
                           _ body: () async throws -> T) async throws -> T {
    let lease = try await acquire(policy, environment: environment, deadline: deadline)
    defer { withExtendedLifetime(lease) {} }
    return try await body()
  }

  static func acquire(_ policy: WorkflowExecutionAdmission?, environment: [String: String],
                      deadline: Date?) async throws -> SandboxExecutionAdmission? {
    guard let policy else { return nil }
    try policy.validate()
    guard let path = environment[policy.directoryEnvironment], !path.isEmpty else {
      throw refused(Refusal.missingEnvironment)
    }
    guard path.hasPrefix("/"), path.utf8.count <= 4096,
          !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          URL(fileURLWithPath: path).standardizedFileURL.path != "/" else { throw refused(Refusal.invalidPath) }
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { throw refused(Refusal.createFailed) }
    try validateDirectory(directory)
    let limit = min(deadline ?? .distantFuture, Date().addingTimeInterval(TimeInterval(policy.waitTimeoutSeconds)))
    while true {
      try Task.checkCancellation()
      guard Date() < limit else { throw AdapterExecutionError(.timeout, "sandbox admission deadline reached") }
      try requireExecutionTime(policy, deadline: deadline)
      if let lease = try attempt(policy, directory: directory) {
        try Task.checkCancellation()
        guard Date() < limit else { throw AdapterExecutionError(.timeout, "sandbox admission deadline reached") }
        try requireExecutionTime(policy, deadline: deadline)
        return lease
      }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  private static func validateDirectory(_ directory: URL) throws {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw refused(Refusal.openFailed) }
    defer { close(descriptor) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid() else { throw refused(Refusal.notOwned) }
    // flock on NFS/SMB is emulated with per-process record locks: two leases in
    // one process would both "own" a slot. Refuse instead of over-admitting.
    // An uninspectable filesystem is not refused (detection is best-effort).
    guard !isNetworkFilesystem(descriptor: descriptor, path: directory.resolvingSymlinksInPath().path) else {
      throw refused(Refusal.networkFilesystem)
    }
  }

  private static func isNetworkFilesystem(descriptor: Int32, path: String) -> Bool {
    #if os(Linux)
    guard let mountInfo = try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8),
          let type = filesystemType(forPath: path, mountInfo: mountInfo) else { return false }
    return networkFilesystemTypes.contains(type)
    #else
    var info = statfs()
    guard fstatfs(descriptor, &info) == 0 else { return false }
    let name = withUnsafeBytes(of: &info.f_fstypename) { raw in
      String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
    }
    return networkFilesystemTypes.contains(name.lowercased())
    #endif
  }

  /// Linux (`mountinfo`) and Darwin (`f_fstypename`) names of network filesystems.
  static let networkFilesystemTypes: Set<String> = [
    "nfs", "nfs4", "cifs", "smb3", "smbfs", "afpfs", "webdav", "afs", "coda"
  ]

  /// The filesystem type of the longest mount point containing `path`, from
  /// `/proc/self/mountinfo` text (`... mountpoint ... - fstype source opts`).
  static func filesystemType(forPath path: String, mountInfo: String) -> String? {
    var best: (mountPoint: String, type: String)?
    for line in mountInfo.split(separator: "\n") {
      let halves = line.components(separatedBy: " - ")
      guard halves.count >= 2 else { continue }
      let fields = halves[0].split(separator: " ")
      guard fields.count >= 5, let type = halves[1].split(separator: " ").first else { continue }
      let mountPoint = decodeMountInfoEscapes(String(fields[4]))
      let contains = mountPoint == "/" || path == mountPoint || path.hasPrefix(mountPoint + "/")
      if contains, mountPoint.count >= (best?.mountPoint.count ?? -1) {
        best = (mountPoint, String(type))
      }
    }
    return best?.type
  }

  private static func decodeMountInfoEscapes(_ value: String) -> String {
    var bytes: [UInt8] = []
    let raw = Array(value.utf8)
    var index = 0
    while index < raw.count {
      if raw[index] == UInt8(ascii: "\\"), index + 3 < raw.count,
         let code = String(bytes: raw[(index + 1)...(index + 3)], encoding: .utf8).flatMap({ UInt8($0, radix: 8) }) {
        bytes.append(code)
        index += 4
      } else {
        bytes.append(raw[index])
        index += 1
      }
    }
    return String(bytes: bytes, encoding: .utf8) ?? value
  }

  private static func requireExecutionTime(_ policy: WorkflowExecutionAdmission, deadline: Date?) throws {
    if let deadline, deadline.timeIntervalSinceNow < Double(policy.minimumRemainingSeconds) {
      throw AdapterExecutionError(.timeout, "sandbox admission has insufficient execution time remaining")
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
    guard descriptor >= 0 else { throw refused(errno == ELOOP ? Refusal.lockFileSymlink : Refusal.lockFileOpen) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(),
          metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), fchmod(descriptor, 0o600) == 0 else {
      close(descriptor)
      throw refused(Refusal.lockFileType)
    }
    return descriptor
  }

  private static func lock(_ descriptor: Int32) throws -> Bool {
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR { continue }
      if errno == EWOULDBLOCK || errno == EAGAIN { return false }
      throw refused(Refusal.lockFailed)
    }
    return true
  }

  /// Called only while holding the gate lock, so reads and repairs are
  /// serialized across every participant. A complete record is the decimal
  /// capacity plus one newline. A record without the newline can only be an
  /// interrupted first write (no acquisition ever succeeds against it), so it
  /// is rewritten instead of poisoning the pool forever.
  static func checkCapacity(_ capacity: Int, directory: URL) throws {
    let descriptor = try openLock(directory.appendingPathComponent("capacity"))
    defer { close(descriptor) }
    var bytes = [UInt8](repeating: 0, count: 32)
    let count = pread(descriptor, &bytes, bytes.count, 0)
    guard count >= 0 else { throw refused(Refusal.capacityRead) }
    let record = bytes.prefix(count)
    let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
    guard count < bytes.count else { throw refused(Refusal.capacityCorrupt) }
    guard let newline = record.firstIndex(of: UInt8(ascii: "\n")) else {
      guard record.allSatisfy({ digits.contains($0) }) else { throw refused(Refusal.capacityCorrupt) }
      try writeCapacity(capacity, descriptor: descriptor)
      return
    }
    let value = record[..<newline]
    guard newline == record.index(before: record.endIndex), !value.isEmpty, value.allSatisfy({ digits.contains($0) }) else {
      throw refused(Refusal.capacityCorrupt)
    }
    guard Array(value) == Array(String(capacity).utf8) else { throw refused(Refusal.capacityMismatch) }
  }

  private static func writeCapacity(_ capacity: Int, descriptor: Int32) throws {
    let value = Array("\(capacity)\n".utf8)
    guard ftruncate(descriptor, 0) == 0 else { throw refused(Refusal.capacityWrite) }
    var offset = 0
    while offset < value.count {
      let written = value[offset...].withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, off_t(offset)) }
      if written < 0, errno == EINTR { continue }
      // A short or failed write leaves a record without the newline, which
      // the next participant repairs under the gate.
      guard written > 0 else { throw refused(Refusal.capacityWrite) }
      offset += written
    }
  }

  private static func refused(_ message: String) -> AdapterExecutionError { .init(.policyBlocked, message) }
}
