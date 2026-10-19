import Foundation

struct TerminalRetentionPaths: Equatable, Sendable {
  var sessionRoot: String
  var artifactRoot: String?
  var memoryRoot: String?

  init(sessionRoot: String, artifactRoot: String?, memoryRoot: String?) throws {
    self.sessionRoot = try Self.checked(sessionRoot)
    self.artifactRoot = try artifactRoot.map(Self.checked)
    self.memoryRoot = try memoryRoot.map(Self.checked)
    let roots = [self.sessionRoot, self.artifactRoot, self.memoryRoot].compactMap { $0 }
    guard Set(roots).count == roots.count else { throw TerminalRetentionError.unsafePath }
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
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: prefix)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
          throw TerminalRetentionError.unsafePath
        }
      } catch let error as NSError where error.domain == NSCocoaErrorDomain
        && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
        // A new/missing managed suffix is safe; all existing parents were checked.
        continue
      }
    }
    return prefix.isEmpty ? "/" : prefix
  }

  static func checkedDatabase(_ path: String) throws -> String {
    let result = try checked(path)
    for suffix in ["-wal", "-shm", "-journal"] { _ = try checked(result + suffix) }
    return result
  }

  func artifactSnapshot(_ id: String) throws -> String {
    guard let artifactRoot else { throw TerminalRetentionError.unsafePath }
    guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil,
          !id.contains("..") else { throw TerminalRetentionError.unsafePath }
    return try Self.checked(URL(fileURLWithPath: artifactRoot).appendingPathComponent(id)
      .appendingPathComponent("runtime-snapshot.json").path)
  }

  func memoryDatabases() throws -> [String] {
    guard let memoryRoot else { return [] }
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
