#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum ClaudeCodeBookmarkType: String, Equatable, Codable, Sendable {
  case session
  case message
  case range
}

public struct ClaudeCodeBookmark: Equatable, Codable, Sendable {
  public var id: String
  public var type: ClaudeCodeBookmarkType
  public var sessionId: String
  public var messageId: String?
  public var text: String?
  public var name: String?
  public var description: String?
  public var tags: [String]
  public var startLine: Int?
  public var endLine: Int?
  public var fromMessageId: String?
  public var toMessageId: String?
  public var createdAt: String?
  public var updatedAt: String?

  public init(
    id: String,
    type: ClaudeCodeBookmarkType,
    sessionId: String,
    messageId: String? = nil,
    text: String? = nil,
    name: String? = nil,
    description: String? = nil,
    tags: [String] = [],
    startLine: Int? = nil,
    endLine: Int? = nil,
    fromMessageId: String? = nil,
    toMessageId: String? = nil,
    createdAt: String? = nil,
    updatedAt: String? = nil
  ) {
    let now = claudeCodeOperationalNow()
    self.id = id
    self.type = type
    self.sessionId = sessionId
    self.messageId = messageId
    self.text = text
    self.name = name
    self.description = description
    self.tags = tags
    self.startLine = startLine
    self.endLine = endLine
    self.fromMessageId = fromMessageId
    self.toMessageId = toMessageId
    self.createdAt = createdAt ?? now
    self.updatedAt = updatedAt ?? now
  }
}

public struct ClaudeCodeBookmarkSearchResult: Equatable, Sendable {
  public var bookmark: ClaudeCodeBookmark
  public var score: Double

  public init(bookmark: ClaudeCodeBookmark, score: Double) {
    self.bookmark = bookmark
    self.score = score
  }
}

public struct ClaudeCodeBookmarkManager: Equatable, Sendable {
  private var bookmarks: [ClaudeCodeBookmark] = []

  public init() {}

  public mutating func create(
    type: ClaudeCodeBookmarkType,
    sessionId: String,
    messageId: String? = nil,
    text: String? = nil,
    name: String? = nil,
    description: String? = nil,
    tags: [String] = [],
    startLine: Int? = nil,
    endLine: Int? = nil,
    fromMessageId: String? = nil,
    toMessageId: String? = nil
  ) throws -> ClaudeCodeBookmark {
    let requiredName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let requiredName, !requiredName.isEmpty else {
      throw ClaudeCodeOperationalError.invalidBookmark
    }
    let hasRangeEndpoints = fromMessageId != nil || toMessageId != nil || startLine != nil || endLine != nil
    if type == .session, messageId != nil || hasRangeEndpoints {
      throw ClaudeCodeOperationalError.invalidBookmark
    }
    if type == .message, messageId == nil || hasRangeEndpoints {
      throw ClaudeCodeOperationalError.invalidBookmark
    }
    if type == .range, messageId != nil {
      throw ClaudeCodeOperationalError.invalidBookmark
    }
    if type == .range, fromMessageId == nil || toMessageId == nil {
      throw ClaudeCodeOperationalError.invalidBookmark
    }
    if type == .range, startLine != nil, endLine != nil, (startLine ?? 0) > (endLine ?? 0) {
      throw ClaudeCodeOperationalError.invalidBookmark
    }
    var seenTags = Set<String>()
    let normalizedTags = tags.compactMap { tag -> String? in
      let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, !seenTags.contains(normalized) else {
        return nil
      }
      seenTags.insert(normalized)
      return normalized
    }
    let now = claudeCodeOperationalNow()
    let bookmark = ClaudeCodeBookmark(
      id: UUID().uuidString,
      type: type,
      sessionId: sessionId,
      messageId: messageId,
      text: text,
      name: requiredName,
      description: description,
      tags: normalizedTags,
      startLine: startLine,
      endLine: endLine,
      fromMessageId: fromMessageId,
      toMessageId: toMessageId,
      createdAt: now,
      updatedAt: now
    )
    bookmarks.append(bookmark)
    return bookmark
  }

  public func get(id: String) -> ClaudeCodeBookmark? {
    bookmarks.first { $0.id == id }
  }

  public func list(sessionId: String? = nil, tag: String? = nil) -> [ClaudeCodeBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId) && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func list(sessionId: String? = nil, type: ClaudeCodeBookmarkType? = nil, tag: String? = nil) -> [ClaudeCodeBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId) && (type == nil || bookmark.type == type) && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func search(text: String) -> [ClaudeCodeBookmark] {
    searchResults(text: text, limit: Int.max).map(\.bookmark)
  }

  public func searchResults(text: String, limit: Int = 50) -> [ClaudeCodeBookmarkSearchResult] {
    let needle = text.lowercased()
    guard !needle.isEmpty, limit != 0 else {
      return []
    }
    return bookmarks.compactMap { bookmark -> ClaudeCodeBookmarkSearchResult? in
      var score = 0.0
      if bookmark.name?.lowercased().contains(needle) == true {
        score += 5
      }
      if bookmark.description?.lowercased().contains(needle) == true || bookmark.text?.lowercased().contains(needle) == true {
        score += 3
      }
      if bookmark.sessionId.lowercased().contains(needle) {
        score += 2
      }
      if bookmark.messageId?.lowercased().contains(needle) == true || bookmark.fromMessageId?.lowercased().contains(needle) == true || bookmark.toMessageId?.lowercased().contains(needle) == true {
        score += 2
      }
      score += Double(bookmark.tags.map { $0.lowercased() }.filter { $0.contains(needle) }.count)
      return score > 0 ? ClaudeCodeBookmarkSearchResult(bookmark: bookmark, score: score) : nil
    }
    .sorted { lhs, rhs in
      if lhs.score == rhs.score {
        return bookmarkSortTimestamp(lhs.bookmark) > bookmarkSortTimestamp(rhs.bookmark)
      }
      return lhs.score > rhs.score
    }
    .prefix(limit)
    .map { $0 }
  }

  public mutating func delete(id: String) -> Bool {
    guard let index = bookmarks.firstIndex(where: { $0.id == id }) else {
      return false
    }
    bookmarks.remove(at: index)
    return true
  }

  public mutating func replaceBookmarks(_ bookmarks: [ClaudeCodeBookmark]) {
    self.bookmarks = bookmarks
  }
}

private func bookmarkSortTimestamp(_ bookmark: ClaudeCodeBookmark) -> String {
  bookmark.updatedAt ?? bookmark.createdAt ?? ""
}

public struct ClaudeCodeBookmarksConfig: Equatable, Codable, Sendable {
  public var bookmarks: [ClaudeCodeBookmark]

  public init(bookmarks: [ClaudeCodeBookmark] = []) {
    self.bookmarks = bookmarks
  }
}

public enum ClaudeCodeBookmarkPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("bookmarks.json")
  }

  public static func legacyDirectory(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true)
      .appendingPathComponent("metadata", isDirectory: true)
      .appendingPathComponent("bookmarks", isDirectory: true)
  }

  public static func legacyURL(bookmarkId: String, configDir: String) -> URL {
    legacyDirectory(configDir: configDir).appendingPathComponent("\(bookmarkId).json")
  }

  public static func load(configDir: String) throws -> ClaudeCodeBookmarksConfig {
    var config = try ClaudeCodeJSONStore<ClaudeCodeBookmarksConfig>(url: url(configDir: configDir)).load(default: ClaudeCodeBookmarksConfig())
    config.bookmarks = mergeBookmarks(config.bookmarks, loadLegacyBookmarks(configDir: configDir))
    return config
  }

  public static func save(_ config: ClaudeCodeBookmarksConfig, configDir: String) throws {
    try ClaudeCodeJSONStore<ClaudeCodeBookmarksConfig>(url: url(configDir: configDir)).save(config)
    try saveLegacyBookmarks(config.bookmarks, configDir: configDir)
  }

  public static func addBookmark(
    type: ClaudeCodeBookmarkType,
    sessionId: String,
    messageId: String? = nil,
    name: String? = nil,
    description: String? = nil,
    tags: [String] = [],
    fromMessageId: String? = nil,
    toMessageId: String? = nil,
    configDir: String
  ) throws -> ClaudeCodeBookmark {
    var config = try load(configDir: configDir)
    var manager = ClaudeCodeBookmarkManager()
    manager.replaceBookmarks(config.bookmarks)
    let bookmark = try manager.create(type: type, sessionId: sessionId, messageId: messageId, text: description, name: name, description: description, tags: tags, fromMessageId: fromMessageId, toMessageId: toMessageId)
    config.bookmarks = manager.list()
    try save(config, configDir: configDir)
    return bookmark
  }

  public static func getBookmark(id: String, configDir: String) throws -> ClaudeCodeBookmark? {
    try load(configDir: configDir).bookmarks.first { $0.id == id }
  }

  public static func listBookmarks(sessionId: String? = nil, type: ClaudeCodeBookmarkType? = nil, tag: String? = nil, configDir: String) throws -> [ClaudeCodeBookmark] {
    var manager = ClaudeCodeBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.list(sessionId: sessionId, type: type, tag: tag)
  }

  public static func searchBookmarks(_ text: String, configDir: String) throws -> [ClaudeCodeBookmark] {
    try searchBookmarkResults(text, limit: Int.max, configDir: configDir).map(\.bookmark)
  }

  public static func searchBookmarkResults(_ text: String, limit: Int = 50, configDir: String) throws -> [ClaudeCodeBookmarkSearchResult] {
    var manager = ClaudeCodeBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.searchResults(text: text, limit: limit)
  }

  public static func deleteBookmark(id: String, configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    var manager = ClaudeCodeBookmarkManager()
    manager.replaceBookmarks(config.bookmarks)
    let deleted = manager.delete(id: id)
    config.bookmarks = manager.list()
    try save(config, configDir: configDir)
    return deleted
  }

  private static func mergeBookmarks(_ aggregate: [ClaudeCodeBookmark], _ legacy: [ClaudeCodeBookmark]) -> [ClaudeCodeBookmark] {
    var byId = Dictionary(uniqueKeysWithValues: aggregate.map { ($0.id, $0) })
    for bookmark in legacy {
      byId[bookmark.id] = bookmark
    }
    return byId.values.sorted { bookmarkSortTimestamp($0) > bookmarkSortTimestamp($1) }
  }

  private static func loadLegacyBookmarks(configDir: String) -> [ClaudeCodeBookmark] {
    let directory = legacyDirectory(configDir: configDir)
    guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    return entries.compactMap { entry -> ClaudeCodeBookmark? in
      guard entry.pathExtension == "json" else {
        return nil
      }
      let isRegularFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
      guard isRegularFile, let data = try? Data(contentsOf: entry) else {
        return nil
      }
      return try? JSONDecoder().decode(ClaudeCodeBookmark.self, from: data)
    }
  }

  private static func saveLegacyBookmarks(_ bookmarks: [ClaudeCodeBookmark], configDir: String) throws {
    let directory = legacyDirectory(configDir: configDir)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let expected = Set(bookmarks.map { "\($0.id).json" })
    let existing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
    for entry in existing where entry.pathExtension == "json" && !expected.contains(entry.lastPathComponent) {
      try? FileManager.default.removeItem(at: entry)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for bookmark in bookmarks {
      try encoder.encode(bookmark).write(to: legacyURL(bookmarkId: bookmark.id, configDir: configDir), options: .atomic)
    }
  }
}

func claudeCodeOperationalNow() -> String {
  ISO8601DateFormatter().string(from: Date())
}

public struct ClaudeCodeTokenMetadata: Equatable, Codable, Sendable {
  public var id: String
  public var name: String?
  public var permissions: [String]
  public var createdAt: String?
  public var expiresAt: String?
  public var lastUsedAt: String?
  public var revoked: Bool
  public var revokedAt: String?

  public init(id: String, permissions: [String], revoked: Bool = false, name: String? = nil, createdAt: String? = nil, expiresAt: String? = nil, lastUsedAt: String? = nil, revokedAt: String? = nil) {
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

public struct ClaudeCodeTokenRecord: Equatable, Codable, Sendable {
  var secretHash: String
  public var metadata: ClaudeCodeTokenMetadata

  public init(secretHash: String, metadata: ClaudeCodeTokenMetadata) {
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
    if let metadata = try container.decodeIfPresent(ClaudeCodeTokenMetadata.self, forKey: .metadata) {
      self.metadata = metadata
      self.secretHash = try container.decode(String.self, forKey: .secretHash)
      return
    }

    let id = try container.decode(String.self, forKey: .id)
    let revokedAt = try container.decodeIfPresent(String.self, forKey: .revokedAt)
    self.metadata = ClaudeCodeTokenMetadata(
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
    try container.encode(secretHash, forKey: .hash)
  }
}

public struct ClaudeCodeTokenManager: Sendable {
  private var tokens: [String: ClaudeCodeTokenRecord] = [:]

  public init() {}

  public init(records: [ClaudeCodeTokenRecord]) {
    self.tokens = Dictionary(uniqueKeysWithValues: records.map { ($0.metadata.id, $0) })
  }

  public mutating func create(permissions: [String] = ["session:read"]) -> (secret: String, metadata: ClaudeCodeTokenMetadata) {
    let rawToken = Self.generateRawToken()
    let idStart = rawToken.index(rawToken.startIndex, offsetBy: 4)
    let idEnd = rawToken.index(idStart, offsetBy: 8)
    let metadata = ClaudeCodeTokenMetadata(id: String(rawToken[idStart..<idEnd]), permissions: Self.normalizePermissions(permissions), revoked: false, createdAt: nowString())
    tokens[metadata.id] = ClaudeCodeTokenRecord(secretHash: hashSecret(rawToken), metadata: metadata)
    return (rawToken, metadata)
  }

  public mutating func createRawToken(name: String? = nil, permissions: [String] = ["session:read"], expiresAt: String? = nil) -> String {
    let created = create(permissions: permissions)
    var metadata = created.metadata
    metadata.name = name
    metadata.expiresAt = expiresAt
    tokens[metadata.id] = ClaudeCodeTokenRecord(secretHash: hashSecret(created.secret), metadata: metadata)
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

  public mutating func verify(rawToken: String, permission: String) -> ClaudeCodeTokenMetadata? {
    guard rawToken.hasPrefix("cca_"), rawToken.count >= 12 else {
      return nil
    }
    let idStart = rawToken.index(rawToken.startIndex, offsetBy: 4)
    let idEnd = rawToken.index(idStart, offsetBy: 8)
    let id = String(rawToken[idStart..<idEnd])
    guard let stored = tokens[id], !stored.metadata.revoked, !isExpired(stored.metadata) else {
      return nil
    }
    guard timingSafeEqual(stored.secretHash, hashSecret(rawToken)), permits(stored.metadata.permissions, permission: permission) else {
      return nil
    }
    var metadata = stored.metadata
    metadata.lastUsedAt = nowString()
    tokens[id] = ClaudeCodeTokenRecord(secretHash: stored.secretHash, metadata: metadata)
    return metadata
  }

  public func listMetadata() -> [ClaudeCodeTokenMetadata] {
    tokens.values.map(\.metadata).sorted { $0.id < $1.id }
  }

  public static func parsePermissionsCSV(_ text: String) -> [String] {
    normalizePermissions(text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty })
  }

  public mutating func revoke(id: String) -> Bool {
    guard tokens[id] != nil else {
      return false
    }
    tokens[id] = nil
    return true
  }

  public mutating func rotate(id: String) -> String? {
    guard let stored = tokens[id] else {
      return nil
    }
    let rawToken = Self.generateRawToken()
    let idStart = rawToken.index(rawToken.startIndex, offsetBy: 4)
    let idEnd = rawToken.index(idStart, offsetBy: 8)
    let newId = String(rawToken[idStart..<idEnd])
    let metadata = ClaudeCodeTokenMetadata(id: newId, permissions: stored.metadata.permissions, name: stored.metadata.name, createdAt: nowString(), expiresAt: stored.metadata.expiresAt)
    tokens[id] = nil
    tokens[newId] = ClaudeCodeTokenRecord(secretHash: hashSecret(rawToken), metadata: metadata)
    return rawToken
  }

  public static func normalizePermissions(_ permissions: [String]) -> [String] {
    let allowed: Set<String> = ["session:create", "session:read", "session:cancel", "group:create", "group:run", "queue:*", "bookmark:*"]
    var seen: Set<String> = []
    var normalized: [String] = []
    for permission in permissions.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }) where !seen.contains(permission) && allowed.contains(permission) {
      seen.insert(permission)
      normalized.append(permission)
    }
    return normalized
  }

  private func hashSecret(_ secret: String) -> String {
    "sha256:" + SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
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

  public func records() -> [ClaudeCodeTokenRecord] {
    tokens.values.sorted { $0.metadata.id < $1.metadata.id }
  }

  private func isExpired(_ metadata: ClaudeCodeTokenMetadata) -> Bool {
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

  private static func generateRawToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
    }
    let encoded = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "cca_\(encoded)"
  }

}

public struct ClaudeCodeTokensConfig: Equatable, Codable, Sendable {
  public var tokens: [ClaudeCodeTokenRecord]

  public init(tokens: [ClaudeCodeTokenRecord] = []) {
    self.tokens = tokens
  }
}

public enum ClaudeCodeTokenPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("api-tokens.json")
  }

  private static func legacyUrl(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("tokens.json")
  }

  public static func load(configDir: String) throws -> ClaudeCodeTokenManager {
    let primary = url(configDir: configDir)
    let resolvedURL = FileManager.default.fileExists(atPath: primary.path) ? primary : legacyUrl(configDir: configDir)
    let config = try ClaudeCodeJSONStore<ClaudeCodeTokensConfig>(url: resolvedURL).load(default: ClaudeCodeTokensConfig())
    return ClaudeCodeTokenManager(records: config.tokens)
  }

  public static func save(_ manager: ClaudeCodeTokenManager, configDir: String) throws {
    try ClaudeCodeJSONStore<ClaudeCodeTokensConfig>(url: url(configDir: configDir)).save(ClaudeCodeTokensConfig(tokens: manager.records()))
  }

  public static func createRawToken(name: String? = nil, permissions: [String], expiresAt: String? = nil, configDir: String) throws -> String {
    var manager = try load(configDir: configDir)
    let token = manager.createRawToken(name: name, permissions: permissions, expiresAt: expiresAt)
    try save(manager, configDir: configDir)
    return token
  }

  public static func listMetadata(configDir: String) throws -> [ClaudeCodeTokenMetadata] {
    try load(configDir: configDir).listMetadata()
  }

  public static func verify(rawToken: String, permission: String, configDir: String) throws -> ClaudeCodeTokenMetadata? {
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

public struct ClaudeCodeJSONStore<Value: Codable & Sendable>: Sendable {
  public var url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load(default defaultValue: Value) throws -> Value {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return defaultValue
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(Value.self, from: data)
  }

  public func save(_ value: Value) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: [.atomic])
  }
}

public enum ClaudeCodeOperationalError: Error, Equatable {
  case invalidBookmark
}
