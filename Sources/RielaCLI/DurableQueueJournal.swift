import Foundation
import RielaCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Metadata journal, compatible with existing writers sharing the same flock.
/// Directory and leaf descriptors stay pinned across read/modify/rename.
enum DurableQueueJournal {
  static let maximumBytes = 7_990_000

  static func transaction(
    directory: URL, name: String, readOnly: Bool,
    context: AdapterExecutionContext, operation: (JSONObject) throws -> (JSONObject, JSONObject)
  ) throws -> JSONObject {
    var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw durableQueueInvalid() }
    defer { close(parent) }
    for component in directory.pathComponents.dropFirst() {
      var child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      if child < 0, errno == ENOENT {
        if readOnly { return try operation(["version": .integer(1), "requests": .object([:])]).1 }
        guard mkdirat(parent, component, 0o700) == 0 || errno == EEXIST else { throw durableQueueInvalid() }
        child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard child >= 0 else { throw durableQueueInvalid() }
      close(parent); parent = child
    }
    if readOnly {
      var info = stat()
      if fstatat(parent, name + ".json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
        guard errno == ENOENT else { throw durableQueueInvalid() }
        return try operation(["version": .integer(1), "requests": .object([:])]).1
      }
    }
    let lock = openat(parent, name + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw durableQueueInvalid() }
    defer { close(lock) }
    try regular(lock)
    guard fchmod(lock, 0o600) == 0 else { throw durableQueueInvalid() }
    let expires = Date().addingTimeInterval(5)
    while flock(lock, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EINTR || errno == EWOULDBLOCK || errno == EAGAIN, Date() < expires else { throw durableQueueInvalid() }
      try checkSnapshotWork(context)
      Thread.sleep(forTimeInterval: 0.005)
    }
    defer { _ = flock(lock, LOCK_UN) }
    try checkSnapshotWork(context)
    let file = openat(parent, name + ".json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    let state: JSONObject
    if file < 0 {
      guard errno == ENOENT else { throw durableQueueInvalid() }
      state = ["version": .integer(1), "requests": .object([:])]
    } else {
      defer { close(file) }
      try regular(file)
      var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
      while true {
        let count = read(file, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0, data.count + count <= maximumBytes else { throw durableQueueInvalid() }
        if count == 0 { break }
        data.append(buffer, count: count)
      }
      guard case let .object(value) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw durableQueueInvalid() }
      state = value
    }
    let (updated, result) = try operation(state)
    let data = try JSONEncoder().encode(updated)
    guard data.count <= maximumBytes, try JSONEncoder().encode(result).count <= maximumBytes else { throw durableQueueInvalid() }
    try checkSnapshotWork(context)
    if !readOnly {
      let temporary = ".\(name)-\(UUID().uuidString).tmp"
      let output = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard output >= 0 else { throw durableQueueInvalid() }
      defer { close(output); _ = unlinkat(parent, temporary, 0) }
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw durableQueueInvalid() }
          offset += count
        }
      }
      guard fsync(output) == 0 else { throw durableQueueInvalid() }
      try checkSnapshotWork(context)
      guard renameat(parent, temporary, parent, name + ".json") == 0, fsync(parent) == 0 else { throw durableQueueInvalid() }
    }
    return result
  }

  private static func regular(_ descriptor: Int32) throws {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumBytes else { throw durableQueueInvalid() }
  }
}

func durableQueueInvalid() -> AdapterExecutionError {
  .init(.invalidInput, "invalid, unavailable or contended durable metadata queue")
}
