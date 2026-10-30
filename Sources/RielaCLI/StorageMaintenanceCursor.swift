import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct StorageMaintenanceCursor: Codable, Equatable, Sendable {
  static let fileName = "storage-maintenance.json"
  static let version = 1

  var version: Int = Self.version
  var queues: [String: Queue]

  struct Queue: Codable, Equatable, Sendable {
    var after: String?
    var complete: Bool = false
    var rescanNeeded: Bool = false
    var busy: [String] = []
    var failed: [String: Int] = [:]
    var parked: [Parked] = []
    var parkedOverflow: Int = 0
  }

  struct Parked: Codable, Equatable, Sendable {
    var key: String
    var error: String
  }

  static func read(stateDirectory: String) -> Self? {
    let path = URL(fileURLWithPath: stateDirectory).appendingPathComponent(fileName)
    guard let data = try? Data(contentsOf: path),
          let cursor = try? JSONDecoder().decode(Self.self, from: data),
          cursor.version == version else { return nil }
    return cursor
  }

  func write(stateDirectory: String) throws {
    let directory = URL(fileURLWithPath: stateDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let destination = directory.appendingPathComponent(Self.fileName)
    let temporary = directory.appendingPathComponent(".storage-maintenance-\(UUID().uuidString).tmp")
    let data = try JSONEncoder().encode(self)
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
}
