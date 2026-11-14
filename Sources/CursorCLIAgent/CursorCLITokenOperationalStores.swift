#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public struct CursorCLITokenMetadata: Equatable, Codable, Sendable {
  public var id: String
  public var name: String?
  public var permissions: [String]
  public var createdAt: String?
  public var expiresAt: String?
  public var lastUsedAt: String?
  public var revoked: Bool
  public var revokedAt: String?

  public init(
    id: String,
    permissions: [String],
    revoked: Bool = false,
    name: String? = nil,
    createdAt: String? = nil,
    expiresAt: String? = nil,
    lastUsedAt: String? = nil,
    revokedAt: String? = nil
  ) {
    self.id = id
    self.name = name
    self.permissions = permissions
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.lastUsedAt = lastUsedAt
    self.revoked = revoked
    self.revokedAt = revokedAt
  }
}

public struct CursorCLITokenRecord: Equatable, Codable, Sendable {
  var secretHash: String
  public var metadata: CursorCLITokenMetadata

  public init(secretHash: String, metadata: CursorCLITokenMetadata) {
    self.secretHash = secretHash
    self.metadata = metadata
  }

  private enum CodingKeys: String, CodingKey {
    case secretHash
    case metadata
    case id
    case name
    case permissions
    case createdAt
    case expiresAt
    case lastUsedAt
    case revoked
    case revokedAt
    case hash
    case tokenHash
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let metadata = try container.decodeIfPresent(CursorCLITokenMetadata.self, forKey: .metadata) {
      self.metadata = metadata
      self.secretHash = try container.decode(String.self, forKey: .secretHash)
      return
    }

    let id = try container.decode(String.self, forKey: .id)
    let revokedAt = try container.decodeIfPresent(String.self, forKey: .revokedAt)
    self.metadata = CursorCLITokenMetadata(
      id: id,
      permissions: try container.decodeIfPresent([String].self, forKey: .permissions) ?? [],
      revoked: (try container.decodeIfPresent(Bool.self, forKey: .revoked)) ?? (revokedAt != nil),
      name: try container.decodeIfPresent(String.self, forKey: .name),
      createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt),
      expiresAt: try container.decodeIfPresent(String.self, forKey: .expiresAt),
      lastUsedAt: try container.decodeIfPresent(String.self, forKey: .lastUsedAt),
      revokedAt: revokedAt
    )
    self.secretHash = try container.decodeIfPresent(String.self, forKey: .hash)
      ?? container.decode(String.self, forKey: .tokenHash)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(metadata.id, forKey: .id)
    try container.encodeIfPresent(metadata.name, forKey: .name)
    try container.encode(metadata.permissions, forKey: .permissions)
    try container.encodeIfPresent(metadata.createdAt, forKey: .createdAt)
    try container.encodeIfPresent(metadata.expiresAt, forKey: .expiresAt)
    try container.encodeIfPresent(metadata.lastUsedAt, forKey: .lastUsedAt)
    try container.encodeIfPresent(metadata.revokedAt, forKey: .revokedAt)
    try container.encode(secretHash, forKey: .tokenHash)
  }
}

public struct CursorCLITokenManager: Sendable {
  private var tokens: [String: CursorCLITokenRecord] = [:]

  public init() {}

  public init(records: [CursorCLITokenRecord]) {
    self.tokens = Dictionary(uniqueKeysWithValues: records.map { ($0.metadata.id, $0) })
  }

  public mutating func create(permissions: [String] = ["session:read"]) -> (secret: String, metadata: CursorCLITokenMetadata) {
    let id = UUID().uuidString
    let rawToken = Self.generateRawToken(id: id)
    guard let secret = Self.parseRawToken(rawToken)?.secret else {
      preconditionFailure("generated token must parse")
    }
    let metadata = CursorCLITokenMetadata(
      id: id,
      permissions: Self.normalizePermissions(permissions),
      revoked: false,
      createdAt: nowString()
    )
    tokens[metadata.id] = CursorCLITokenRecord(secretHash: hashSecret(secret), metadata: metadata)
    return (rawToken, metadata)
  }

  public mutating func createRawToken(name: String? = nil, permissions: [String] = ["session:read"], expiresAt: String? = nil) -> String {
    let created = create(permissions: permissions)
    var metadata = created.metadata
    metadata.name = name
    metadata.expiresAt = expiresAt
    guard let secret = Self.parseRawToken(created.secret)?.secret else {
      return created.secret
    }
    tokens[metadata.id] = CursorCLITokenRecord(secretHash: hashSecret(secret), metadata: metadata)
    return created.secret
  }

  public func verify(id: String, secret: String, permission: String) -> Bool {
    guard let stored = tokens[id], !stored.metadata.revoked else {
      return false
    }
    guard !isExpired(stored.metadata) else {
      return false
    }
    return timingSafeEqual(stored.secretHash, hashSecret(secret)) && permits(stored.metadata.permissions, permission: permission)
  }

  public mutating func verify(rawToken: String, permission: String) -> CursorCLITokenMetadata? {
    guard let parsed = Self.parseRawToken(rawToken) else {
      return nil
    }
    guard let stored = tokens[parsed.id],
          !stored.metadata.revoked,
          stored.metadata.revokedAt == nil,
          !isExpired(stored.metadata) else {
      return nil
    }
    guard timingSafeEqual(stored.secretHash, hashSecret(parsed.secret)), permits(stored.metadata.permissions, permission: permission) else {
      return nil
    }
    var metadata = stored.metadata
    metadata.lastUsedAt = nowString()
    tokens[parsed.id] = CursorCLITokenRecord(secretHash: stored.secretHash, metadata: metadata)
    return metadata
  }

  public func listMetadata() -> [CursorCLITokenMetadata] {
    tokens.values.map(\.metadata).sorted { $0.id < $1.id }
  }

  public static func parsePermissionsCSV(_ text: String) -> [String] {
    normalizePermissions(text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty })
  }

  public mutating func revoke(id: String) -> Bool {
    guard let stored = tokens[id] else {
      return false
    }
    var metadata = stored.metadata
    metadata.revoked = true
    metadata.revokedAt = nowString()
    tokens[id] = CursorCLITokenRecord(secretHash: stored.secretHash, metadata: metadata)
    return true
  }

  public mutating func rotate(id: String) -> String? {
    guard let stored = tokens[id] else {
      return nil
    }
    let rawToken = Self.generateRawToken(id: id)
    guard let secret = Self.parseRawToken(rawToken)?.secret else {
      return nil
    }
    var metadata = stored.metadata
    metadata.revoked = false
    metadata.revokedAt = nil
    tokens[id] = CursorCLITokenRecord(secretHash: hashSecret(secret), metadata: metadata)
    return rawToken
  }

  public static func normalizePermissions(_ permissions: [String]) -> [String] {
    let allowed: Set<String> = [
      "session:create",
      "session:read",
      "session:cancel",
      "group:run",
      "group:*",
      "queue:*",
      "bookmark:*",
      "files:*",
      "server:read",
      "server:admin"
    ]
    var seen: Set<String> = []
    var normalized: [String] = []
    for permission in permissions
      .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      .filter({ !$0.isEmpty })
      where !seen.contains(permission) && allowed.contains(permission) {
      seen.insert(permission)
      normalized.append(permission)
    }
    return normalized
  }

  private func hashSecret(_ secret: String) -> String {
    SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard !left.isEmpty, !right.isEmpty else {
      return left.isEmpty && right.isEmpty
    }
    var difference = left.count ^ right.count
    let maxCount = max(left.count, right.count)
    for index in 0..<maxCount {
      difference |= Int(left[index % left.count] ^ right[index % right.count])
    }
    return difference == 0
  }

  private func permits(_ permissions: [String], permission: String) -> Bool {
    permissions.contains(permission)
      || permissions.contains("*")
      || permissions.contains(permission.split(separator: ":").first.map { "\($0):*" } ?? "")
      || (permission == "server:read" && permissions.contains("server:admin"))
  }

  public func records() -> [CursorCLITokenRecord] {
    tokens.values.sorted { $0.metadata.id < $1.metadata.id }
  }

  private func isExpired(_ metadata: CursorCLITokenMetadata) -> Bool {
    guard let expiresAt = metadata.expiresAt else {
      return false
    }
    guard let expiresAtDate = parseTokenTimestamp(expiresAt) else {
      return true
    }
    return expiresAtDate <= Date()
  }

  private func nowString() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }

  private func parseTokenTimestamp(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) {
      return date
    }
    return ISO8601DateFormatter().date(from: text)
  }

  private static func generateRawToken(id: String) -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
    }
    let encoded = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "\(id).\(encoded)"
  }

  private static func parseRawToken(_ rawToken: String) -> (id: String, secret: String)? {
    let parts = rawToken.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
      return nil
    }
    return (String(parts[0]), String(parts[1]))
  }

}

public struct CursorCLITokensConfig: Equatable, Codable, Sendable {
  public var tokens: [CursorCLITokenRecord]

  public init(tokens: [CursorCLITokenRecord] = []) {
    self.tokens = tokens
  }
}

public enum CursorCLITokenPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("tokens.json")
  }

  public static func load(configDir: String) throws -> CursorCLITokenManager {
    let config = try CursorCLIJSONStore<CursorCLITokensConfig>(url: url(configDir: configDir))
      .load(default: CursorCLITokensConfig())
    return CursorCLITokenManager(records: config.tokens)
  }

  public static func save(_ manager: CursorCLITokenManager, configDir: String) throws {
    try CursorCLIJSONStore<CursorCLITokensConfig>(url: url(configDir: configDir))
      .save(CursorCLITokensConfig(tokens: manager.records()))
  }

  public static func createRawToken(
    name: String? = nil,
    permissions: [String],
    expiresAt: String? = nil,
    configDir: String
  ) throws -> String {
    var manager = try load(configDir: configDir)
    let token = manager.createRawToken(name: name, permissions: permissions, expiresAt: expiresAt)
    try save(manager, configDir: configDir)
    return token
  }

  public static func listMetadata(configDir: String) throws -> [CursorCLITokenMetadata] {
    try load(configDir: configDir).listMetadata()
  }

  public static func verify(
    rawToken: String,
    permission: String,
    configDir: String
  ) throws -> CursorCLITokenMetadata? {
    var manager = try load(configDir: configDir)
    guard let metadata = manager.verify(rawToken: rawToken, permission: permission) else {
      return nil
    }
    try save(manager, configDir: configDir)
    return metadata
  }

  public static func revoke(id: String, configDir: String) throws -> Bool {
    var manager = try load(configDir: configDir)
    let revoked = manager.revoke(id: id)
    try save(manager, configDir: configDir)
    return revoked
  }

  public static func rotate(id: String, configDir: String) throws -> String? {
    var manager = try load(configDir: configDir)
    guard let rawToken = manager.rotate(id: id) else {
      return nil
    }
    try save(manager, configDir: configDir)
    return rawToken
  }
}
