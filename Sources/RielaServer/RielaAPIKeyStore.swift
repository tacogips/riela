import Crypto
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Persistent controller credentials. Only token digests cross the persistence boundary.
public struct RielaAPIKeyStore: Sendable {
  public enum Purpose: String, Codable, Sendable { case client, worker }

  public struct Record: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let purpose: Purpose
    public let workerID: String?
    public let createdAt: Date
    public let expiresAt: Date?
    public fileprivate(set) var revokedAt: Date?
  }

  /// The token is available only in the issuance result, never in list results or persisted records.
  public struct IssuedKey: Sendable {
    public let record: Record
    public let token: String
  }

  public enum StoreError: Error { case invalidRequest, keyNotFound, unavailable, corrupt }

  private struct StoredKey: Codable {
    let record: Record
    let digest: String
  }

  private struct State: Codable {
    var version = 1
    var requireClientKey = true
    var keys: [StoredKey] = []
  }

  public let root: URL
  public init(root: URL) { self.root = root }

  public static func defaultRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    homeDirectory.appendingPathComponent(".riela/rielaapp/api-auth", isDirectory: true)
  }

  public func issue(
    name: String, purpose: Purpose = .client, workerID: String? = nil,
    expiresAt: Date? = nil, now: Date = Date()
  ) throws -> IssuedKey {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 200,
          !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          expiresAt.map({ $0 > now }) ?? true,
          purpose == .worker ? workerID?.isEmpty == false : workerID == nil else {
      throw StoreError.invalidRequest
    }
    let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let token = "riela_" + secret.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let record = Record(id: UUID().uuidString.lowercased(), name: name, purpose: purpose,
                        workerID: workerID, createdAt: now, expiresAt: expiresAt, revokedAt: nil)
    try transaction { $0.keys.append(StoredKey(record: record, digest: Self.digest(token))) }
    return IssuedKey(record: record, token: token)
  }

  public func list() throws -> [Record] { try transaction(write: false) { $0.keys.map(\.record) } }

  public func revoke(id: String, now: Date = Date()) throws {
    try transaction { state in
      guard let index = state.keys.firstIndex(where: { $0.record.id == id }) else { throw StoreError.keyNotFound }
      let old = state.keys[index]
      var record = old.record
      if record.revokedAt == nil { record.revokedAt = now }
      state.keys[index] = StoredKey(record: record, digest: old.digest)
    }
  }

  public func requireClientKey() throws -> Bool { try transaction(write: false) { $0.requireClientKey } }

  public func setRequireClientKey(_ required: Bool) throws {
    try transaction { $0.requireClientKey = required }
  }

  /// Omitting workerID resolves the token's identity; supplying it additionally enforces that binding.
  public func authenticate(
    _ token: String, purpose: Purpose, workerID: String? = nil, now: Date = Date()
  ) throws -> Record? {
    try transaction(write: false) { state in
      Self.match(token, purpose: purpose, workerID: workerID, now: now, state: state)
    }
  }

  /// Disabling client authentication never disables worker authentication.
  public func authorizeClient(token: String?, now: Date = Date()) throws -> Bool {
    try transaction(write: false) { state in
      guard let token else { return !state.requireClientKey }
      return Self.match(token, purpose: .client, workerID: nil, now: now, state: state) != nil
    }
  }

  private static func match(
    _ token: String, purpose: Purpose, workerID: String?, now: Date, state: State
  ) -> Record? {
    let digest = SHA256.hash(data: Data(token.utf8))
    return state.keys.first { key in
      matches(digest, stored: key.digest) && key.record.purpose == purpose && (workerID == nil || key.record.workerID == workerID)
        && key.record.revokedAt == nil && (key.record.expiresAt.map { $0 > now } ?? true)
    }?.record
  }

  private static func matches(_ digest: SHA256.Digest, stored: String) -> Bool {
    let encoded = Array(stored.utf8)
    guard encoded.count == 64 else { return false }
    var bytes = Data()
    for offset in stride(from: 0, to: encoded.count, by: 2) {
      guard let pair = String(bytes: encoded[offset..<(offset + 2)], encoding: .utf8),
            let byte = UInt8(pair, radix: 16) else { return false }
      bytes.append(byte)
    }
    // swift-crypto's Digest equality uses its constant-time safeCompare primitive.
    return digest == bytes
  }

  private static func digest(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func transaction<Value>(write: Bool = true, _ operation: (inout State) throws -> Value) throws -> Value {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let lock = root.appendingPathComponent("api-keys.lock")
    let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw StoreError.unavailable }
    defer { close(descriptor) }
    guard fchmod(descriptor, 0o600) == 0 else { throw StoreError.unavailable }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw StoreError.unavailable }
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    let file = root.appendingPathComponent("api-keys.json")
    var state = try read(file)
    let result = try operation(&state)
    if write { try persist(state, to: file) }
    return result
  }

  private func read(_ file: URL) throws -> State {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if descriptor < 0 {
      guard errno == ENOENT else { throw StoreError.unavailable }
      return State()
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw StoreError.unavailable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    guard let data = try handle.readToEnd() else { throw StoreError.corrupt }
    let state: State
    do { state = try JSONDecoder().decode(State.self, from: data) } catch { throw StoreError.corrupt }
    guard state.version == 1,
          Set(state.keys.map { $0.record.id }).count == state.keys.count,
          Set(state.keys.map(\.digest)).count == state.keys.count,
          state.keys.allSatisfy({ key in
            key.digest.count == 64 && key.digest.allSatisfy { $0.isHexDigit }
              && (key.record.purpose == .worker ? key.record.workerID?.isEmpty == false : key.record.workerID == nil)
          }) else { throw StoreError.corrupt }
    return state
  }

  private func persist(_ state: State, to file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    let staging = root.appendingPathComponent(".api-keys-\(UUID().uuidString).tmp")
    let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw StoreError.unavailable }
    defer {
      close(descriptor)
      _ = unlink(staging.path)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.write(contentsOf: data)
    guard fsync(descriptor) == 0, rename(staging.path, file.path) == 0 else { throw StoreError.unavailable }
    let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw StoreError.unavailable }
    defer { close(directory) }
    guard fsync(directory) == 0 else { throw StoreError.unavailable }
  }
}
