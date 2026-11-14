import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Explicit workspace-relative outputs carried in the authenticated result.
/// Limits leave room for node output in the one-MiB completion envelope.
public struct DistributedArtifact: Codable, Equatable, Sendable {
  public static let maximumCount = 16
  public static let maximumTotalBytes = 512 * 1024

  public let path: String
  public let data: Data
  public let sha256: String

  public init(path: String, data: Data) {
    self.path = path
    self.data = data
    self.sha256 = Self.digest(data)
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func validPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 256 && !path.contains("\\")
      && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  static func validatePaths(_ paths: [String]) throws {
    guard paths.count <= maximumCount, Set(paths).count == paths.count, paths.allSatisfy(validPath) else {
      throw AdapterExecutionError(.invalidInput, "remote exports must be unique relative file paths without traversal")
    }
  }

  static func validate(_ artifacts: [Self], expectedPaths: [String]) throws {
    try validatePaths(expectedPaths)
    guard artifacts.map(\.path).sorted() == expectedPaths.sorted(),
      artifacts.reduce(0, { $0 + $1.data.count }) <= maximumTotalBytes,
      artifacts.allSatisfy({ $0.sha256 == digest($0.data) }) else {
      throw AdapterExecutionError(.invalidOutput, "remote artifact manifest, digest or size is invalid")
    }
  }

  static func collect(paths: [String], root: URL) throws -> [Self] {
    try validatePaths(paths)
    var remaining = maximumTotalBytes
    return try paths.map { path in
      let bytes = try readRegularFile(path: path, root: root, maximumBytes: remaining)
      remaining -= bytes.count
      return Self(path: path, data: bytes)
    }
  }

  private static func readRegularFile(path: String, root: URL, maximumBytes: Int) throws -> Data {
    var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw artifactReadError() }
    defer { close(descriptor) }
    let components = path.split(separator: "/").map(String.init)
    for (index, component) in components.enumerated() {
      let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index < components.count - 1 ? O_DIRECTORY : 0)
      let next = openat(descriptor, component, flags)
      guard next >= 0 else { throw artifactReadError() }
      close(descriptor)
      descriptor = next
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      status.st_size >= 0, status.st_size <= maximumBytes else { throw artifactReadError() }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      #if os(Linux)
      let count = Glibc.read(descriptor, &buffer, min(buffer.count, maximumBytes - output.count + 1))
      #else
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes - output.count + 1))
      #endif
      if count < 0 && errno == EINTR { continue }
      guard count >= 0, output.count + count <= maximumBytes else { throw artifactReadError() }
      if count == 0 { return output }
      output.append(contentsOf: buffer.prefix(count))
    }
  }

  private static func artifactReadError() -> AdapterExecutionError {
    AdapterExecutionError(.invalidOutput, "remote export must be a readable regular file within the workspace and artifact size limit; symlinks are forbidden")
  }
}

public struct DistributedArtifactLocation: Equatable, Sendable {
  public let path: String
  public let url: URL
  public let sha256: String
  public let size: Int
}
