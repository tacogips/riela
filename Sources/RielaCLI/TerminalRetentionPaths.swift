import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct TerminalRetentionPaths: Equatable, Sendable {
  var sessionRoot: String
  var artifactRoot: String
  var memoryRoot: String

  init(sessionRoot: String, artifactRoot: String, memoryRoot: String) throws {
    self.sessionRoot = try Self.checked(sessionRoot)
    self.artifactRoot = try Self.checked(artifactRoot)
    self.memoryRoot = try Self.checked(memoryRoot)
    let roots = [self.sessionRoot, self.artifactRoot, self.memoryRoot]
    guard Set(roots).count == 3 else { throw TerminalRetentionError.unsafePath }
    for root in roots {
      guard !roots.contains(where: { $0 != root && root.hasPrefix($0 + "/") }) else {
        throw TerminalRetentionError.unsafePath
      }
      guard root != "/", root != FileManager.default.homeDirectoryForCurrentUser.path else {
        throw TerminalRetentionError.unsafePath
      }
    }
  }

  static func checked(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0") else { throw TerminalRetentionError.unsafePath }
    var prefix = ""
    for component in (path as NSString).pathComponents where component != "/" {
      guard component != ".", component != ".." else { throw TerminalRetentionError.unsafePath }
      prefix += "/" + component
      // Only file type is needed. Foundation's broad attribute API also
      // reads extended attributes for every ancestor and sidecar on every fresh
      // admission. lstat keeps the same no-follow component checks without them.
      var attributes = stat()
      if lstat(prefix, &attributes) == 0 {
        guard attributes.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
          throw TerminalRetentionError.unsafePath
        }
      } else {
        let code = errno
        if code == ENOENT || code == ENOTDIR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
    }
    return prefix.isEmpty ? "/" : prefix
  }

  static func checkedDatabase(_ path: String) throws -> String {
    let result = try checked(path)
    for suffix in ["-wal", "-shm", "-journal"] { _ = try checked(result + suffix) }
    return result
  }

  func databaseBytes() throws -> Int64 {
    let databases = [CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionRoot),
      SQLiteWorkflowMessageLog.defaultDatabasePath(rootDirectory: artifactRoot)]
    var total: Int64 = 0
    for database in databases {
      let path = try Self.checkedDatabase(database)
      for suffix in ["", "-wal", "-shm", "-journal"] {
        var attributes = stat()
        if lstat(path + suffix, &attributes) == 0 {
          guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_size >= 0 else {
            throw TerminalRetentionError.unsafePath
          }
          total = try TerminalRetentionMetadata.adding(total, Int64(attributes.st_size))
        } else if errno != ENOENT && errno != ENOTDIR {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
    }
    return total
  }

  func artifactSnapshot(_ id: String) throws -> String {
    guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil,
          !id.contains("..") else { throw TerminalRetentionError.unsafePath }
    return try Self.checked(URL(fileURLWithPath: artifactRoot).appendingPathComponent(id)
      .appendingPathComponent("runtime-snapshot.json").path)
  }

  func memoryDatabases() throws -> [String] {
    guard FileManager.default.fileExists(atPath: memoryRoot) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: memoryRoot).filter { $0.hasSuffix(".sqlite") }
      .sorted().map { try Self.checkedDatabase(URL(fileURLWithPath: memoryRoot).appendingPathComponent($0).path) }
  }
}

enum TerminalRetentionError: Error, Equatable {
  case unsafePath
  case foreignDatabase
  case changedFamily
  case secondaryProtected(String)
  case reclamationBusy
  case pendingRootsMismatch
}
