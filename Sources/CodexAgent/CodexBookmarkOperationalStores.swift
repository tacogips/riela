import Foundation

public enum CodexBookmarkType: String, Equatable, Codable, Sendable {
  case session
  case message
  case range
}

public struct CodexBookmark: Equatable, Codable, Sendable {
  public var id: String
  public var type: CodexBookmarkType
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
    type: CodexBookmarkType,
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
    let now = codexOperationalNow()
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

public struct CodexBookmarkSearchResult: Equatable, Sendable {
  public var bookmark: CodexBookmark
  public var score: Double

  public init(bookmark: CodexBookmark, score: Double) {
    self.bookmark = bookmark
    self.score = score
  }
}

public struct CodexBookmarkManager: Equatable, Sendable {
  private var bookmarks: [CodexBookmark] = []

  public init() {}

  public mutating func create(
    type: CodexBookmarkType,
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
  ) throws -> CodexBookmark {
    let requiredName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let requiredName, !requiredName.isEmpty else {
      throw CodexOperationalError.invalidBookmark
    }
    let hasRangeEndpoints = fromMessageId != nil || toMessageId != nil || startLine != nil || endLine != nil
    if type == .session, messageId != nil || hasRangeEndpoints {
      throw CodexOperationalError.invalidBookmark
    }
    if type == .message, messageId == nil || hasRangeEndpoints {
      throw CodexOperationalError.invalidBookmark
    }
    if type == .range, messageId != nil {
      throw CodexOperationalError.invalidBookmark
    }
    if type == .range, fromMessageId == nil || toMessageId == nil {
      throw CodexOperationalError.invalidBookmark
    }
    if type == .range, startLine != nil, endLine != nil, (startLine ?? 0) > (endLine ?? 0) {
      throw CodexOperationalError.invalidBookmark
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
    let now = codexOperationalNow()
    let bookmark = CodexBookmark(
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

  public func get(id: String) -> CodexBookmark? {
    bookmarks.first { $0.id == id }
  }

  public func list(sessionId: String? = nil, tag: String? = nil) -> [CodexBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId) && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func list(sessionId: String? = nil, type: CodexBookmarkType? = nil, tag: String? = nil) -> [CodexBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId) && (type == nil || bookmark.type == type) && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func search(text: String) -> [CodexBookmark] {
    searchResults(text: text, limit: Int.max).map(\.bookmark)
  }

  public func searchResults(text: String, limit: Int = 50) -> [CodexBookmarkSearchResult] {
    let needle = text.lowercased()
    guard !needle.isEmpty, limit != 0 else {
      return []
    }
    return bookmarks.compactMap { bookmark -> CodexBookmarkSearchResult? in
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
      return score > 0 ? CodexBookmarkSearchResult(bookmark: bookmark, score: score) : nil
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

  public mutating func replaceBookmarks(_ bookmarks: [CodexBookmark]) {
    self.bookmarks = bookmarks
  }
}

private func bookmarkSortTimestamp(_ bookmark: CodexBookmark) -> String {
  bookmark.updatedAt ?? bookmark.createdAt ?? ""
}

public struct CodexBookmarksConfig: Equatable, Codable, Sendable {
  public var bookmarks: [CodexBookmark]

  public init(bookmarks: [CodexBookmark] = []) {
    self.bookmarks = bookmarks
  }
}

public enum CodexBookmarkPersistence {
  public static func url(configDir: String) -> URL {
    URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent("bookmarks.json")
  }

  public static func load(configDir: String) throws -> CodexBookmarksConfig {
    try CodexJSONStore<CodexBookmarksConfig>(url: url(configDir: configDir)).load(default: CodexBookmarksConfig())
  }

  public static func save(_ config: CodexBookmarksConfig, configDir: String) throws {
    try CodexJSONStore<CodexBookmarksConfig>(url: url(configDir: configDir)).save(config)
  }

  public static func addBookmark(
    type: CodexBookmarkType,
    sessionId: String,
    messageId: String? = nil,
    name: String? = nil,
    description: String? = nil,
    tags: [String] = [],
    fromMessageId: String? = nil,
    toMessageId: String? = nil,
    configDir: String
  ) throws -> CodexBookmark {
    var config = try load(configDir: configDir)
    var manager = CodexBookmarkManager()
    manager.replaceBookmarks(config.bookmarks)
    let bookmark = try manager.create(
      type: type,
      sessionId: sessionId,
      messageId: messageId,
      text: description,
      name: name,
      description: description,
      tags: tags,
      fromMessageId: fromMessageId,
      toMessageId: toMessageId
    )
    config.bookmarks = manager.list()
    try save(config, configDir: configDir)
    return bookmark
  }

  public static func getBookmark(id: String, configDir: String) throws -> CodexBookmark? {
    try load(configDir: configDir).bookmarks.first { $0.id == id }
  }

  public static func listBookmarks(sessionId: String? = nil, type: CodexBookmarkType? = nil, tag: String? = nil, configDir: String) throws -> [CodexBookmark] {
    var manager = CodexBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.list(sessionId: sessionId, type: type, tag: tag)
  }

  public static func searchBookmarks(_ text: String, configDir: String) throws -> [CodexBookmark] {
    try searchBookmarkResults(text, limit: Int.max, configDir: configDir).map(\.bookmark)
  }

  public static func searchBookmarkResults(_ text: String, limit: Int = 50, configDir: String) throws -> [CodexBookmarkSearchResult] {
    var manager = CodexBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.searchResults(text: text, limit: limit)
  }

  public static func deleteBookmark(id: String, configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    var manager = CodexBookmarkManager()
    manager.replaceBookmarks(config.bookmarks)
    let deleted = manager.delete(id: id)
    config.bookmarks = manager.list()
    try save(config, configDir: configDir)
    return deleted
  }
}
