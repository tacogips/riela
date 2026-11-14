#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public struct CodexTokenMetadata: Equatable, Codable, Sendable {
  public var id: String
  public var name: String?
  public var permissions: [String]
  public var createdAt: String?
  public var expiresAt: String?
  public var revoked: Bool
  public var revokedAt: String?

  public init(id: String, permissions: [String], revoked: Bool = false, name: String? = nil, createdAt: String? = nil, expiresAt: String? = nil, revokedAt: String? = nil) {
    self.id = id
    self.name = name
    self.permissions = permissions
    self.createdAt = createdAt
    self.expiresAt = expiresAt
    self.revoked = revoked
    self.revokedAt = revokedAt
  }
}

public struct CodexTokenRecord: Equatable, Codable, Sendable {
  var secretHash: String
  public var metadata: CodexTokenMetadata

  public init(secretHash: String, metadata: CodexTokenMetadata) {
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
    case revoked
    case revokedAt
    case tokenHash
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let metadata = try container.decodeIfPresent(CodexTokenMetadata.self, forKey: .metadata) {
      self.metadata = metadata
      self.secretHash = try container.decode(String.self, forKey: .secretHash)
      return
    }

    let id = try container.decode(String.self, forKey: .id)
    let revokedAt = try container.decodeIfPresent(String.self, forKey: .revokedAt)
    self.metadata = CodexTokenMetadata(
      id: id,
      permissions: try container.decodeIfPresent([String].self, forKey: .permissions) ?? [],
      revoked: (try container.decodeIfPresent(Bool.self, forKey: .revoked)) ?? (revokedAt != nil),
      name: try container.decodeIfPresent(String.self, forKey: .name),
      createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt),
      expiresAt: try container.decodeIfPresent(String.self, forKey: .expiresAt),
      revokedAt: revokedAt
    )
    self.secretHash = try container.decode(String.self, forKey: .tokenHash)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(metadata.id, forKey: .id)
    try container.encodeIfPresent(metadata.name, forKey: .name)
    try container.encode(metadata.permissions, forKey: .permissions)
    try container.encodeIfPresent(metadata.createdAt, forKey: .createdAt)
    try container.encodeIfPresent(metadata.expiresAt, forKey: .expiresAt)
    try container.encodeIfPresent(metadata.revokedAt, forKey: .revokedAt)
    try container.encode(secretHash, forKey: .tokenHash)
  }
}

public struct CodexTokenManager: Sendable {
  private var tokens: [String: CodexTokenRecord] = [:]

  public init() {}

  public init(records: [CodexTokenRecord]) {
    self.tokens = Dictionary(uniqueKeysWithValues: records.map { ($0.metadata.id, $0) })
  }

  public mutating func create(permissions: [String] = ["session:read"]) -> (secret: String, metadata: CodexTokenMetadata) {
    let secret = UUID().uuidString
    let metadata = CodexTokenMetadata(id: UUID().uuidString, permissions: Self.normalizePermissions(permissions), revoked: false, createdAt: nowString())
    tokens[metadata.id] = CodexTokenRecord(secretHash: hashSecret(secret), metadata: metadata)
    return (secret, metadata)
  }

  public mutating func createRawToken(name: String? = nil, permissions: [String] = ["session:read"], expiresAt: String? = nil) -> String {
    let created = create(permissions: permissions)
    var metadata = created.metadata
    metadata.name = name
    metadata.expiresAt = expiresAt
    tokens[metadata.id] = CodexTokenRecord(secretHash: hashSecret(created.secret), metadata: metadata)
    return "\(metadata.id).\(created.secret)"
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

  public func verify(rawToken: String, permission: String) -> CodexTokenMetadata? {
    let parts = rawToken.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2, verify(id: parts[0], secret: parts[1], permission: permission) else {
      return nil
    }
    return tokens[parts[0]]?.metadata
  }

  public func listMetadata() -> [CodexTokenMetadata] {
    tokens.values.map(\.metadata).sorted { $0.id < $1.id }
  }

  public static func parsePermissionsCSV(_ text: String) -> [String] {
    normalizePermissions(text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty })
  }

  public mutating func revoke(id: String) -> Bool {
    guard var stored = tokens[id] else {
      return false
    }
    stored.metadata.revoked = true
    stored.metadata.revokedAt = nowString()
    tokens[id] = stored
    return true
  }

  public mutating func rotate(id: String) -> String? {
    guard var stored = tokens[id] else {
      return nil
    }
    let secret = UUID().uuidString
    stored.secretHash = hashSecret(secret)
    stored.metadata.revoked = false
    stored.metadata.revokedAt = nil
    tokens[id] = stored
    return secret
  }

  public static func normalizePermissions(_ permissions: [String]) -> [String] {
    let allowed: Set<String> = ["session:create", "session:read", "session:cancel", "group:*", "queue:*", "bookmark:*"]
    var seen: Set<String> = []
    var normalized: [String] = []
    for permission in permissions.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) where !seen.contains(permission) && allowed.contains(permission) {
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
    permissions.contains(permission) || permissions.contains("*") || permissions.contains(permission.split(separator: ":").first.map { "\($0):*" } ?? "")
  }

  public func records() -> [CodexTokenRecord] {
    tokens.values.sorted { $0.metadata.id < $1.metadata.id }
  }

  private func isExpired(_ metadata: CodexTokenMetadata) -> Bool {
    guard let expiresAt = metadata.expiresAt else {
      return false
    }
    return ISO8601DateFormatter().date(from: expiresAt).map { $0 <= Date() } ?? false
  }

  private func nowString() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}

public struct CodexTokensConfig: Equatable, Codable, Sendable {
  public var tokens: [CodexTokenRecord]

  public init(tokens: [CodexTokenRecord] = []) {
    self.tokens = tokens
  }
}

public enum CodexTokenPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("tokens.json")
  }

  public static func load(configDir: String) throws -> CodexTokenManager {
    let config = try CodexJSONStore<CodexTokensConfig>(url: url(configDir: configDir)).load(default: CodexTokensConfig())
    return CodexTokenManager(records: config.tokens)
  }

  public static func save(_ manager: CodexTokenManager, configDir: String) throws {
    try CodexJSONStore<CodexTokensConfig>(url: url(configDir: configDir)).save(CodexTokensConfig(tokens: manager.records()))
  }

  public static func createRawToken(name: String? = nil, permissions: [String], expiresAt: String? = nil, configDir: String) throws -> String {
    var manager = try load(configDir: configDir)
    let token = manager.createRawToken(name: name, permissions: permissions, expiresAt: expiresAt)
    try save(manager, configDir: configDir)
    return token
  }

  public static func listMetadata(configDir: String) throws -> [CodexTokenMetadata] {
    try load(configDir: configDir).listMetadata()
  }

  public static func verify(rawToken: String, permission: String, configDir: String) throws -> CodexTokenMetadata? {
    try load(configDir: configDir).verify(rawToken: rawToken, permission: permission)
  }

  public static func revoke(id: String, configDir: String) throws -> Bool {
    var manager = try load(configDir: configDir)
    let revoked = manager.revoke(id: id)
    try save(manager, configDir: configDir)
    return revoked
  }

  public static func rotate(id: String, configDir: String) throws -> String? {
    var manager = try load(configDir: configDir)
    guard let secret = manager.rotate(id: id), let metadata = manager.listMetadata().first(where: { $0.id == id }) else {
      return nil
    }
    try save(manager, configDir: configDir)
    return "\(metadata.id).\(secret)"
  }
}
