import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct RielaPairingAudit: Sendable {
  private struct Entry: Encodable {
    let action: String
    let grantId: String?
    let clientName: String?
    let scope: String?
    let remoteAddress: String?
    let time: Date
  }

  private let root: URL

  public init(root: URL) { self.root = root }

  public func append(
    action: String, grantId: String?, clientName: String?, scope: String?, remoteAddress: String?, now: Date
  ) {
    let entry = Entry(action: action, grantId: grantId, clientName: clientName, scope: scope,
                      remoteAddress: remoteAddress, time: now)
    try? append(entry)
  }

  private func append(_ entry: Entry) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let file = root.appendingPathComponent("pairing-audit.jsonl")
    let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          fchmod(descriptor, 0o600) == 0 else { return }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { return }
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(entry)
    data.append(0x0a)
    try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
  }
}
