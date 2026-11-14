import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class CommandExecutionLockLease: @unchecked Sendable {
  static let environmentKey = "RIELA_COMMAND_LOCKS"
  private let lock = NSLock()
  private var files: [Int32]
  let directory: String
  let resources: [WorkflowCommandLocks.Resource]

  private init(files: [Int32], directory: String, resources: [WorkflowCommandLocks.Resource]) {
    self.files = files; self.directory = directory; self.resources = resources
  }
  deinit { release() }
  func release() {
    lock.lock(); defer { lock.unlock() }
    // Closing releases this owner's references. An inherited child descriptor
    // must retain the lock if its native owner dies unexpectedly.
    for descriptor in files.reversed() { _ = close(descriptor) }
    files = []
  }
  var descriptors: Set<Int32> { lock.lock(); defer { lock.unlock() }; return Set(files) }
  func receipt() throws -> String {
    lock.lock(); defer { lock.unlock() }
    let value: JSONValue = .object(["directory": .string(directory), "resources": .array(zip(resources, files).map { resource, descriptor in
      .object(["name": .string(resource.name), "mode": .string(resource.mode.rawValue), "fd": .integer(Int64(descriptor))]) })])
    return try value.compactJSONString()
  }

  static func acquire(_ policy: WorkflowCommandLocks, environment: [String: String], workingDirectory: URL?) throws -> CommandExecutionLockLease? {
    try policy.validate()
    guard let root = environment[policy.directoryEnvironment] ?? policy.defaultDirectory, !root.isEmpty, root.utf8.count <= 4096 else {
      throw AdapterExecutionError(.policyBlocked, "command execution lock directory unavailable")
    }
    let directory = URL(fileURLWithPath: root, relativeTo: workingDirectory).standardizedFileURL.resolvingSymlinksInPath()
    var files: [Int32] = []
    defer { for descriptor in files { _ = close(descriptor) } }
    do {
      // Existing resources are checked before creating/acquiring any file.
      for resource in policy.resources {
        var status = stat()
        if lstat(directory.appendingPathComponent(resource.name).path, &status) == 0 {
          guard safe(status) else { throw invalid() }
        } else if errno != ENOENT { throw invalid() }
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      for resource in policy.resources {
        try Task.checkCancellation()
        let descriptor = open(directory.appendingPathComponent(resource.name).path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw invalid() }
        files.append(descriptor)
        var status = stat()
        guard fstat(descriptor, &status) == 0, safe(status), fchmod(descriptor, 0o600) == 0 else { throw invalid() }
        if flock(descriptor, (resource.mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 {
          if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
          throw invalid()
        }
      }
      let lease = CommandExecutionLockLease(files: files, directory: directory.path, resources: policy.resources)
      files = []; return lease
    } catch is CancellationError { throw CancellationError()
    } catch { throw invalid() }
  }

  private static func safe(_ status: stat) -> Bool {
    (status.st_mode & S_IFMT) == S_IFREG && status.st_nlink == 1 && status.st_uid == getuid()
  }
  private static func invalid() -> AdapterExecutionError { .init(.policyBlocked, "command execution lock unavailable or unsafe") }
}
