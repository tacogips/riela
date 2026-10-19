import Foundation
import RielaCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class RetentionTargetLock {
  private let descriptor: Int32

  private init(descriptor: Int32) { self.descriptor = descriptor }

  static func tryAcquire(stateDirectory: String) throws -> RetentionTargetLock? {
    try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let path = URL(fileURLWithPath: stateDirectory).appendingPathComponent("automatic.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR { continue }
      let lockError = errno
      _ = close(descriptor)
      if lockError == EWOULDBLOCK || lockError == EAGAIN { return nil }
      throw POSIXError(.init(rawValue: lockError) ?? .EIO)
    }
    return RetentionTargetLock(descriptor: descriptor)
  }

  deinit {
    _ = flock(descriptor, LOCK_UN)
    _ = close(descriptor)
  }
}

struct RetentionRunStamp: Codable, Equatable, Sendable {
  var lastAttemptAt: Date?
  var lastCompletedAt: Date?
  var lastStatus: String?

  static func read(stateDirectory: String) -> RetentionRunStamp? {
    let path = URL(fileURLWithPath: stateDirectory).appendingPathComponent("last-run.json")
    guard let data = try? Data(contentsOf: path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(RetentionRunStamp.self, from: data)
  }

  func write(stateDirectory: String) throws {
    let directory = URL(fileURLWithPath: stateDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let destination = directory.appendingPathComponent("last-run.json")
    let temporary = directory.appendingPathComponent(".last-run-\(UUID().uuidString).tmp")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(self)
    do {
      try data.write(to: temporary, options: .atomic)
      guard rename(temporary.path, destination.path) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  static func isFresh(_ stamp: RetentionRunStamp?, now: Date, minInterval: TimeInterval) -> Bool {
    guard let attempted = stamp?.lastAttemptAt, minInterval > 0 else { return false }
    let elapsed = now.timeIntervalSince(attempted)
    return elapsed >= 0 && elapsed < minInterval
  }
}
