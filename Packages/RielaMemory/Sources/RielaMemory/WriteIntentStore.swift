import Crypto
import Foundation

/// A caller-selected durable target. It is distinct from a provider/body cache.
public struct WriteIntentReference: Codable, Equatable, Sendable {
  public var version: Int
  public var ownerSHA256: String
  public var slot: Int
  public var key: String
  public var sha256: String
}

public enum WriteIntentError: Error, Equatable, Sendable {
  case invalid, changed, contended
}

/// Two durable slots per owner, with atomic SQLite compare/exchange and no TTL.
/// The caller owns the publication fence from stage through journal-pointer
/// commit. Clear is allowed only after that pointer was durably released. This
/// store never publishes, acknowledges a source, or changes a provider cursor.
public struct RielaWriteIntentStore: Sendable {
  public var rootDirectory: String
  public var storeId: String
  public var scope: String
  private static let key = "write-intents-v1"
  public static let maximumPayloadBytes = 16 * 1024 * 1024

  public init(rootDirectory: String, storeId: String, scope: String) {
    self.rootDirectory = rootDirectory; self.storeId = storeId; self.scope = scope
  }

  public func stage(key: String, serializedJSON: String, selected: WriteIntentReference?) throws -> WriteIntentReference {
    guard !key.isEmpty, key.utf8.count <= 1024, !key.unicodeScalars.contains(where: { $0.value < 32 }),
      serializedJSON.utf8.count <= Self.maximumPayloadBytes,
      (try? JSONDecoder().decode(MemoryJSONValue.self, from: Data(serializedJSON.utf8))) != nil else { throw WriteIntentError.invalid }
    let sha = Self.digest(serializedJSON)
    for _ in 0..<8 {
      let (store, previous, slots) = try read()
      let owner = try ownerDigest()
      if let selected { try validate(selected, owner: owner) }
      if let selected {
        guard matches(slots[selected.slot], selected) else { throw WriteIntentError.changed }
        if selected.sha256 == sha && selected.key == key { return selected }
      }
      let slot = selected.map { 1 - $0.slot } ?? 0
      var next = slots
      next[slot] = .object(["key": .string(key), "sha256": .string(sha), "serializedJSON": .string(serializedJSON)])
      if try store.compareExchange(storeId: storeId, scope: scope, key: Self.key,
          expectedValue: previous, value: .object(["version": .number(1), "slots": .array(next)])) {
        try secureFiles(store)
        return .init(version: 1, ownerSHA256: owner, slot: slot, key: key, sha256: sha)
      }
    }
    throw WriteIntentError.contended
  }

  public func load(_ reference: WriteIntentReference) throws -> String? {
    let (_, _, slots) = try read()
    try validate(reference, owner: ownerDigest())
    guard matches(slots[reference.slot], reference), case let .object(value) = slots[reference.slot],
      case let .string(payload)? = value["serializedJSON"] else { return nil }
    guard Self.digest(payload) == reference.sha256 else { throw WriteIntentError.changed }
    return payload
  }

  public func clear() throws {
    for _ in 0..<8 {
      let (store, previous, _) = try read()
      guard previous != nil else { return }
      if try store.compareExchange(storeId: storeId, scope: scope, key: Self.key, expectedValue: previous,
          value: .object(["version": .number(1), "slots": .array([.null, .null])])) {
        try secureFiles(store); return
      }
    }
    throw WriteIntentError.contended
  }

  private func read() throws -> (RielaKeyValueStore, MemoryJSONValue?, [MemoryJSONValue]) {
    guard rootDirectory.hasPrefix("/"), !scope.isEmpty, scope.utf8.count <= 512 else { throw WriteIntentError.invalid }
    let directory = URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL
    guard directory.path == directory.resolvingSymlinksInPath().path else { throw WriteIntentError.invalid }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let store = RielaKeyValueStore(rootDirectory: directory.path)
    try secureFiles(store)
    let previous = try store.get(storeId: storeId, scope: scope, key: Self.key)?.value
    guard let previous else { return (store, nil, [.null, .null]) }
    guard case let .object(box) = previous, box["version"] == .number(1), case let .array(slots)? = box["slots"], slots.count == 2 else { throw WriteIntentError.invalid }
    for slot in slots {
      if slot == .null { continue }
      guard case let .object(value) = slot, case let .string(payload)? = value["serializedJSON"],
        case let .string(sha)? = value["sha256"], case let .string(key)? = value["key"], !key.isEmpty,
        payload.utf8.count <= Self.maximumPayloadBytes, Self.digest(payload) == sha else { throw WriteIntentError.changed }
    }
    return (store, previous, slots)
  }

  private func matches(_ value: MemoryJSONValue, _ reference: WriteIntentReference) -> Bool {
    guard case let .object(row) = value else { return false }
    return row["key"] == .string(reference.key) && row["sha256"] == .string(reference.sha256)
  }

  private func validate(_ ref: WriteIntentReference, owner: String) throws {
    guard ref.version == 1, ref.ownerSHA256 == owner, (0...1).contains(ref.slot), !ref.key.isEmpty,
      ref.key.utf8.count <= 1024, ref.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw WriteIntentError.invalid }
  }

  private func ownerDigest() throws -> String {
    let identity = [URL(fileURLWithPath: rootDirectory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path, storeId, scope]
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    return Self.digest(String(decoding: try encoder.encode(identity), as: UTF8.self))
  }

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func secureFiles(_ store: RielaKeyValueStore) throws {
    let path = try store.databasePath(storeId: storeId)
    for suffix in ["", "-wal", "-shm", "-journal"] {
      let file = path + suffix
      if (try? FileManager.default.destinationOfSymbolicLink(atPath: file)) != nil { throw WriteIntentError.invalid }
      guard FileManager.default.fileExists(atPath: file) else { continue }
      do {
        let attrs = try FileManager.default.attributesOfItem(atPath: file)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
          (attrs[.referenceCount] as? NSNumber)?.intValue == 1 else { throw WriteIntentError.invalid }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
      } catch {
        guard !suffix.isEmpty, !FileManager.default.fileExists(atPath: file) else { throw error }
      }
    }
  }
}
