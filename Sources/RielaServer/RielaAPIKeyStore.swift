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

  public enum Scope: String, Codable, Sendable, Comparable {
    case read, operate, admin

    public static func < (lhs: Self, rhs: Self) -> Bool {
      switch (lhs, rhs) {
      case (.read, .operate), (.read, .admin), (.operate, .admin): true
      default: false
      }
    }
  }

  public struct PairingInfo: Codable, Equatable, Sendable {
    public let clientName: String
    public let pairedAt: Date

    public init(clientName: String, pairedAt: Date) {
      self.clientName = clientName
      self.pairedAt = pairedAt
    }
  }

  public struct Record: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let purpose: Purpose
    public let workerID: String?
    public let createdAt: Date
    public let expiresAt: Date?
    public fileprivate(set) var revokedAt: Date?
    public let scope: Scope?
    public let pairing: PairingInfo?
    public fileprivate(set) var lastUsedAt: Date?

    public var effectiveScope: Scope { scope ?? .admin }
  }

  /// The token is available only in the issuance result, never in list results or persisted records.
  public struct IssuedKey: Sendable {
    public let record: Record
    public let token: String
  }

  public enum StoreError: Error {
    case invalidRequest, keyNotFound, unavailable, corrupt
    case pairingCodeInvalid, pairingAddressNotRoutable, pairingAddressRequiresTLS

    public var code: String {
      switch self {
      case .invalidRequest: "invalid_request"
      case .keyNotFound: "key_not_found"
      case .unavailable: "api_auth_unavailable"
      case .corrupt: "api_auth_corrupt"
      case .pairingCodeInvalid: "pairing_code_invalid"
      case .pairingAddressNotRoutable: "pairing_address_not_routable"
      case .pairingAddressRequiresTLS: "pairing_address_requires_tls"
      }
    }
  }

  private struct PairingCode: Encodable {
    let address: String
    let secret: String
    let serverId: String
  }

  private struct StoredPairingCode: Codable {
    let digest: String
    let address: String
    let scope: Scope
    let expiresAt: Date
    var failedAttempts = 0
    var usedAt: Date?
  }

  private struct StoredKey: Codable {
    var record: Record
    let digest: String
  }

  private struct State: Codable {
    var version = 1
    var requireClientKey = true
    var keys: [StoredKey] = []
    var pairingCode: StoredPairingCode?
  }

  public let root: URL
  public init(root: URL) { self.root = root }

  public static func defaultRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    homeDirectory.appendingPathComponent(".riela/rielaapp/api-auth", isDirectory: true)
  }

  public func issue(
    name: String, purpose: Purpose = .client, workerID: String? = nil,
    expiresAt: Date? = nil, now: Date = Date(), scope: Scope? = nil, pairing: PairingInfo? = nil
  ) throws -> IssuedKey {
    let name = try Self.keyName(name)
    guard expiresAt.map({ $0 > now }) ?? true,
          purpose == .worker ? workerID?.isEmpty == false : workerID == nil else {
      throw StoreError.invalidRequest
    }
    let issued = Self.makeKey(name: name, purpose: purpose, workerID: workerID,
                              expiresAt: expiresAt, now: now, scope: scope, pairing: pairing)
    try transaction { $0.keys.append(Self.storedKey(issued)) }
    return issued
  }

  public func mintPairingCode(
    address: String, scope: Scope, serverId: String, now: Date, ttl: TimeInterval = 600
  ) throws -> String {
    _ = try RielaPairingAddress.validate(address)
    guard ttl.isFinite, ttl > 0 else { throw StoreError.invalidRequest }
    let secret = Self.randomSecret()
    let code = PairingCode(address: address, secret: secret, serverId: serverId)
    let encoded = try JSONEncoder().encode(code)
    try transaction { state in
      state.pairingCode = StoredPairingCode(digest: Self.digest(secret), address: address,
                                            scope: scope, expiresAt: now.addingTimeInterval(ttl))
    }
    return "rp1." + Self.base64URL(encoded)
  }

  public func redeemPairingCode(secret: String, clientName: String, now: Date) throws -> IssuedKey {
    let name = try? Self.keyName(clientName)
    let digest = SHA256.hash(data: Data(secret.utf8))
    let result: (issued: IssuedKey?, changed: Bool) = try transaction(writeWhen: { $0.changed }, { state in
      guard var code = state.pairingCode, code.usedAt == nil, code.expiresAt > now else { return (nil, false) }
      guard Self.matches(digest, stored: code.digest) else {
        code.failedAttempts += 1
        state.pairingCode = code.failedAttempts < 5 ? code : nil
        return (nil, true)
      }
      // Client names are persisted and audited. A pairing envelope is longer than its 43-byte secret.
      guard let name,
            name.range(of: secret, options: .literal) == nil,
            name.range(of: #"rp1\.[A-Za-z0-9_-]{58,}"#, options: .regularExpression) == nil else {
        return (nil, false)
      }
      let pairing = PairingInfo(clientName: name, pairedAt: now)
      let key = Self.makeKey(name: name, purpose: .client, workerID: nil,
                             expiresAt: nil, now: now, scope: code.scope, pairing: pairing)
      code.usedAt = now
      state.pairingCode = code
      state.keys.append(Self.storedKey(key))
      return (key, true)
    })
    guard let issued = result.issued else { throw StoreError.pairingCodeInvalid }
    return issued
  }

  public func pairingGrants() throws -> [Record] {
    try transaction(write: false) { $0.keys.map(\.record).filter { $0.pairing != nil } }
  }

  public func touch(id: String, now: Date) throws {
    try transaction(writeWhen: { $0 }, { state in
      guard let index = state.keys.firstIndex(where: { $0.record.id == id && $0.record.revokedAt == nil }),
            state.keys[index].record.lastUsedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else {
        return false
      }
      state.keys[index].record.lastUsedAt = now
      return true
    })
  }

  private static func keyName(_ value: String) throws -> String {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 200,
          !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw StoreError.invalidRequest
    }
    return name
  }

  private static func makeKey(
    name: String, purpose: Purpose, workerID: String?, expiresAt: Date?, now: Date, scope: Scope?, pairing: PairingInfo?
  ) -> IssuedKey {
    let record = Record(id: UUID().uuidString.lowercased(), name: name, purpose: purpose,
                        workerID: workerID, createdAt: now, expiresAt: expiresAt, revokedAt: nil,
                        scope: scope, pairing: pairing, lastUsedAt: nil)
    return IssuedKey(record: record, token: "riela_" + randomSecret())
  }

  private static func storedKey(_ issued: IssuedKey) -> StoredKey {
    StoredKey(record: issued.record, digest: digest(issued.token))
  }

  private static func randomSecret() -> String {
    base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
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

  private func transaction<Value>(
    write: Bool = true, writeWhen: (Value) -> Bool = { _ in true }, _ operation: (inout State) throws -> Value
  ) throws -> Value {
    try withStoreLock {
      let file = root.appendingPathComponent("api-keys.json")
      var state = try read(file)
      let result = try operation(&state)
      if write, writeWhen(result) { try Self.persist(try Self.encode(state), to: file) }
      return result
    }
  }

  func withStoreLock<Value>(_ operation: () throws -> Value) throws -> Value {
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
    return try operation()
  }

  private func read(_ file: URL) throws -> State {
    guard let data = try Self.readRegularFile(file) else { return State() }
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

  package static func readRegularFile(_ file: URL) throws -> Data? {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if descriptor < 0 {
      guard errno == ENOENT else { throw StoreError.unavailable }
      return nil
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw StoreError.unavailable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    guard let data = try handle.readToEnd() else { throw StoreError.corrupt }
    return data
  }

  private static func encode(_ state: State) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(state)
  }

  package static func persist(_ data: Data, to file: URL) throws {
    let root = file.deletingLastPathComponent()
    let staging = root.appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString).tmp")
    let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw StoreError.unavailable }
    defer {
      close(descriptor)
      _ = unlink(staging.path)
    }
    guard fchmod(descriptor, 0o600) == 0 else { throw StoreError.unavailable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.write(contentsOf: data)
    guard fsync(descriptor) == 0, rename(staging.path, file.path) == 0 else { throw StoreError.unavailable }
    let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directory >= 0 else { throw StoreError.unavailable }
    defer { close(directory) }
    guard fsync(directory) == 0 else { throw StoreError.unavailable }
  }
}
