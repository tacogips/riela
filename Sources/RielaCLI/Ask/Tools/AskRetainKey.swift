import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum AskRetainKey {
  private static let size = 32
  private static let invalid = AskError(code: "retain_key_invalid", message: "The Ask retain key is invalid or unavailable")

  static func load(storeRoot: String) throws(AskError) -> Data {
    let directory = URL(fileURLWithPath: storeRoot, isDirectory: true)
    let key = directory.appendingPathComponent("ask-retain-key")
    do {
      if let existing = try read(key) { return existing }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let temporary = directory.appendingPathComponent(".ask-retain-key-\(UUID().uuidString)")
      let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw invalid }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer {
        try? file.close()
        _ = unlink(temporary.path)
      }
      guard fchmod(descriptor, 0o600) == 0 else { throw invalid }
      var random = SystemRandomNumberGenerator()
      let bytes = Data((0..<size).map { _ in UInt8.random(in: .min ... .max, using: &random) })
      try file.write(contentsOf: bytes)
      // Publish the complete key exclusively so another process can never read a partial write.
      if link(temporary.path, key.path) == 0 { return bytes }
      guard errno == EEXIST, let existing = try read(key) else { throw invalid }
      return existing
    } catch {
      throw invalid
    }
  }

  private static func read(_ key: URL) throws -> Data? {
    let descriptor = open(key.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw invalid
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
          metadata.st_mode & 0o777 == 0o600, metadata.st_size == size,
          let bytes = try file.read(upToCount: size + 1), bytes.count == size else {
      throw invalid
    }
    return bytes
  }
}
