import Foundation
import Darwin

public struct KaibaInstanceStore: Sendable {
  public let homeURL: URL

  public init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeURL = homeURL
  }

  public var fileURL: URL {
    homeURL.appendingPathComponent(".riela/kaiba/instances.json")
  }

  public func load() throws -> KaibaInstanceCatalog {
    var metadata = stat()
    if lstat(fileURL.path, &metadata) != 0 {
      if errno == ENOENT { return KaibaInstanceCatalog() }
      throw KaibaInstanceStoreError.unavailable
    }
    guard (metadata.st_mode & S_IFMT) == S_IFREG else {
      throw KaibaInstanceStoreError.invalidStore
    }
    do {
      let data: Data
      do {
        data = try Data(contentsOf: fileURL)
      } catch {
        throw KaibaInstanceStoreError.unavailable
      }
      var duplicateKeyValidator = StrictJSONDuplicateKeyValidator(data: data)
      try duplicateKeyValidator.validate()
      try validateSchema(data)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      do {
        return try KaibaInstanceValidation.validated(decoder.decode(KaibaInstanceCatalog.self, from: data))
      } catch {
        throw KaibaInstanceStoreError.invalidStore
      }
    } catch let error as KaibaInstanceStoreError {
      throw error
    } catch {
      throw KaibaInstanceStoreError.invalidStore
    }
  }

  public func save(_ catalog: KaibaInstanceCatalog) throws {
    let directory = fileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try withExclusiveLock(in: directory) {
        try saveUnlocked(catalog)
      }
    } catch let error as KaibaInstanceStoreError {
      throw error
    } catch {
      throw KaibaInstanceStoreError.unavailable
    }
  }

  /// Serializes a read-modify-write operation across CLI and App processes.
  /// The closure receives the current validated snapshot and must return a new
  /// validated catalog; rejected mutations leave the original file untouched.
  public func mutate(_ body: (KaibaInstanceCatalog) throws -> KaibaInstanceCatalog) throws -> KaibaInstanceCatalog {
    let directory = fileURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      return try withExclusiveLock(in: directory) {
        let current = try load()
        let candidate: KaibaInstanceCatalog
        do {
          candidate = try body(current)
        } catch {
          throw MutationBodyError(underlying: error)
        }
        let updated = try KaibaInstanceValidation.validated(candidate)
        try saveUnlocked(updated)
        return updated
      }
    } catch let error as MutationBodyError {
      throw error.underlying
    } catch let error as KaibaInstanceStoreError {
      throw error
    } catch {
      throw KaibaInstanceStoreError.unavailable
    }
  }

  /// Applies a row mutation only when the caller's immutable snapshot is still
  /// current under the catalog lock. This prevents a stale CLI/App editor from
  /// overwriting a concurrent configuration change.
  public func mutateInstance(
    id: String,
    expected: KaibaInstance,
    _ body: (KaibaInstance) throws -> KaibaInstance
  ) throws -> KaibaInstanceCatalog {
    try mutate { catalog in
      var updated = catalog
      guard let index = updated.instances.firstIndex(where: { $0.id == id }) else {
        throw KaibaInstanceStoreError.missingInstance
      }
      guard updated.instances[index] == expected else {
        throw KaibaInstanceStoreError.changedInstance
      }
      updated.instances[index] = try body(expected)
      return updated
    }
  }

  private func saveUnlocked(_ catalog: KaibaInstanceCatalog) throws {
    let validated = try KaibaInstanceValidation.validated(catalog)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(validated)
    try data.write(to: fileURL, options: [.atomic])
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.synchronize()
    let directoryDescriptor = open(fileURL.deletingLastPathComponent().path, O_RDONLY)
    guard directoryDescriptor >= 0 else { throw KaibaInstanceStoreError.unavailable }
    defer { close(directoryDescriptor) }
    guard fsync(directoryDescriptor) == 0 else { throw KaibaInstanceStoreError.unavailable }
  }

  private func withExclusiveLock<Result>(
    in directory: URL,
    _ body: () throws -> Result
  ) throws -> Result {
    let lockURL = directory.appendingPathComponent("instances.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw KaibaInstanceStoreError.unavailable }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw KaibaInstanceStoreError.unavailable }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
  }

  private func validateSchema(_ data: Data) throws {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(root.keys) == ["schemaVersion", "instances"],
          let instances = root["instances"] as? [[String: Any]] else {
      throw KaibaInstanceStoreError.invalidStore
    }
    let instanceKeys: Set<String> = ["id", "name", "endpoint", "authentication", "enabled", "isDefault", "allowInsecureHTTP", "allowRemoteUnauthenticated", "lastTest"]
    let testKeys: Set<String> = ["status", "code", "attemptedAt"]
    for instance in instances {
      guard Set(instance.keys) == instanceKeys,
            let authentication = instance["authentication"] as? [String: Any],
            let mode = authentication["mode"] as? String,
            Set(authentication.keys) == (mode == "bearer" ? ["mode", "environmentVariable"] : ["mode"]),
            ["bearer", "unauthenticated"].contains(mode),
            let lastTest = instance["lastTest"] as? [String: Any], Set(lastTest.keys).isSubset(of: testKeys) else {
        throw KaibaInstanceStoreError.invalidStore
      }
    }
  }
}

private struct MutationBodyError: Error {
  let underlying: Error
}

/// `JSONSerialization` silently retains the last duplicate key. Scan the raw
/// document before schema projection so duplicate catalog keys fail closed.
struct StrictJSONDuplicateKeyValidator {
  private let bytes: [UInt8]
  private var index = 0

  init(data: Data) {
    bytes = Array(data)
  }

  mutating func validate() throws {
    try parseValue()
    skipWhitespace()
    guard index == bytes.count else { throw KaibaInstanceStoreError.invalidStore }
  }

  private mutating func parseValue() throws {
    skipWhitespace()
    guard let byte = bytes[safe: index] else { throw KaibaInstanceStoreError.invalidStore }
    switch byte {
    case Self.openObject:
      try parseObject()
    case Self.openArray:
      try parseArray()
    case Self.quote:
      _ = try parseString()
    default:
      try parseLiteralOrNumber()
    }
  }

  private mutating func parseObject() throws {
    try consume(Self.openObject)
    skipWhitespace()
    if consumeIf(Self.closeObject) { return }
    var keys = Set<String>()
    while true {
      skipWhitespace()
      let key = try parseString()
      guard keys.insert(key).inserted else { throw KaibaInstanceStoreError.invalidStore }
      skipWhitespace()
      try consume(Self.colon)
      try parseValue()
      skipWhitespace()
      if consumeIf(Self.closeObject) { return }
      try consume(Self.comma)
    }
  }

  private mutating func parseArray() throws {
    try consume(Self.openArray)
    skipWhitespace()
    if consumeIf(Self.closeArray) { return }
    while true {
      try parseValue()
      skipWhitespace()
      if consumeIf(Self.closeArray) { return }
      try consume(Self.comma)
    }
  }

  private mutating func parseString() throws -> String {
    skipWhitespace()
    let start = index
    try consume(Self.quote)
    while let byte = bytes[safe: index] {
      index += 1
      if byte == Self.quote {
        let token = Data(bytes[start..<index])
        guard let key = try? JSONSerialization.jsonObject(with: token, options: [.fragmentsAllowed]) as? String else {
          throw KaibaInstanceStoreError.invalidStore
        }
        return key
      }
      if byte == Self.backslash {
        guard bytes[safe: index] != nil else { throw KaibaInstanceStoreError.invalidStore }
        index += 1
      } else if byte < 0x20 {
        throw KaibaInstanceStoreError.invalidStore
      }
    }
    throw KaibaInstanceStoreError.invalidStore
  }

  private mutating func parseLiteralOrNumber() throws {
    let start = index
    while let byte = bytes[safe: index], !Self.delimiters.contains(byte) {
      guard byte >= 0x20 else { throw KaibaInstanceStoreError.invalidStore }
      index += 1
    }
    guard index > start else { throw KaibaInstanceStoreError.invalidStore }
  }

  private mutating func skipWhitespace() {
    while let byte = bytes[safe: index], Self.whitespace.contains(byte) {
      index += 1
    }
  }

  private mutating func consume(_ expected: UInt8) throws {
    skipWhitespace()
    guard consumeIf(expected) else { throw KaibaInstanceStoreError.invalidStore }
  }

  private mutating func consumeIf(_ expected: UInt8) -> Bool {
    guard bytes[safe: index] == expected else { return false }
    index += 1
    return true
  }

  private static let openObject: UInt8 = 0x7B
  private static let closeObject: UInt8 = 0x7D
  private static let openArray: UInt8 = 0x5B
  private static let closeArray: UInt8 = 0x5D
  private static let quote: UInt8 = 0x22
  private static let backslash: UInt8 = 0x5C
  private static let colon: UInt8 = 0x3A
  private static let comma: UInt8 = 0x2C
  private static let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
  private static let delimiters: Set<UInt8> = whitespace.union([comma, closeArray, closeObject])
}

private extension Array where Element == UInt8 {
  subscript(safe index: Int) -> UInt8? {
    indices.contains(index) ? self[index] : nil
  }
}
