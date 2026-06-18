import Foundation

public enum CursorCLIBookmarkType: String, Equatable, Codable, Sendable {
  case session
  case message
  case range
}

public struct CursorCLIBookmark: Equatable, Codable, Sendable {
  public var id: String
  public var type: CursorCLIBookmarkType
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
    type: CursorCLIBookmarkType,
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
    let now = cursorCLIOperationalNow()
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

public struct CursorCLIBookmarkSearchResult: Equatable, Sendable {
  public var bookmark: CursorCLIBookmark
  public var score: Double

  public init(bookmark: CursorCLIBookmark, score: Double) {
    self.bookmark = bookmark
    self.score = score
  }
}

public struct CursorCLIBookmarkManager: Equatable, Sendable {
  private var bookmarks: [CursorCLIBookmark] = []

  public init() {}

  public mutating func create(
    type: CursorCLIBookmarkType,
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
  ) throws -> CursorCLIBookmark {
    let requiredName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let requiredName, !requiredName.isEmpty else {
      throw CursorCLIOperationalError.invalidBookmark
    }
    let hasRangeEndpoints = fromMessageId != nil || toMessageId != nil || startLine != nil || endLine != nil
    if type == .session, messageId != nil || hasRangeEndpoints {
      throw CursorCLIOperationalError.invalidBookmark
    }
    if type == .message, messageId == nil || hasRangeEndpoints {
      throw CursorCLIOperationalError.invalidBookmark
    }
    if type == .range, messageId != nil {
      throw CursorCLIOperationalError.invalidBookmark
    }
    if type == .range, fromMessageId == nil || toMessageId == nil {
      throw CursorCLIOperationalError.invalidBookmark
    }
    if type == .range, startLine != nil, endLine != nil, (startLine ?? 0) > (endLine ?? 0) {
      throw CursorCLIOperationalError.invalidBookmark
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
    let now = cursorCLIOperationalNow()
    let bookmark = CursorCLIBookmark(
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

  public func get(id: String) -> CursorCLIBookmark? {
    bookmarks.first { $0.id == id }
  }

  public func list(sessionId: String? = nil, tag: String? = nil) -> [CursorCLIBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId)
        && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func list(sessionId: String? = nil, type: CursorCLIBookmarkType? = nil, tag: String? = nil) -> [CursorCLIBookmark] {
    bookmarks.filter { bookmark in
      (sessionId == nil || bookmark.sessionId == sessionId)
        && (type == nil || bookmark.type == type)
        && (tag == nil || bookmark.tags.contains { $0.caseInsensitiveCompare(tag ?? "") == .orderedSame })
    }.sorted { lhs, rhs in
      bookmarkSortTimestamp(lhs) > bookmarkSortTimestamp(rhs)
    }
  }

  public func search(text: String) -> [CursorCLIBookmark] {
    searchResults(text: text, limit: Int.max).map(\.bookmark)
  }

  public func searchResults(text: String, limit: Int = 50) -> [CursorCLIBookmarkSearchResult] {
    let needle = text.lowercased()
    guard !needle.isEmpty, limit != 0 else {
      return []
    }
    return bookmarks.compactMap { bookmark -> CursorCLIBookmarkSearchResult? in
      var score = 0.0
      if bookmark.name?.lowercased().contains(needle) == true {
        score += 5
      }
      if bookmark.description?.lowercased().contains(needle) == true
        || bookmark.text?.lowercased().contains(needle) == true {
        score += 3
      }
      if bookmark.sessionId.lowercased().contains(needle) {
        score += 2
      }
      if bookmark.messageId?.lowercased().contains(needle) == true
        || bookmark.fromMessageId?.lowercased().contains(needle) == true
        || bookmark.toMessageId?.lowercased().contains(needle) == true {
        score += 2
      }
      score += Double(bookmark.tags.map { $0.lowercased() }.filter { $0.contains(needle) }.count)
      return score > 0 ? CursorCLIBookmarkSearchResult(bookmark: bookmark, score: score) : nil
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

  public mutating func replaceBookmarks(_ bookmarks: [CursorCLIBookmark]) {
    self.bookmarks = bookmarks
  }
}

private func bookmarkSortTimestamp(_ bookmark: CursorCLIBookmark) -> String {
  bookmark.updatedAt ?? bookmark.createdAt ?? ""
}

public struct CursorCLIBookmarksConfig: Equatable, Codable, Sendable {
  public var bookmarks: [CursorCLIBookmark]

  public init(bookmarks: [CursorCLIBookmark] = []) {
    self.bookmarks = bookmarks
  }
}

public enum CursorCLIBookmarkPersistence {
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

  public static func load(configDir: String) throws -> CursorCLIBookmarksConfig {
    var config = try CursorCLIJSONStore<CursorCLIBookmarksConfig>(url: url(configDir: configDir)).load(default: CursorCLIBookmarksConfig())
    config.bookmarks = mergeBookmarks(config.bookmarks, loadLegacyBookmarks(configDir: configDir))
    return config
  }

  public static func save(_ config: CursorCLIBookmarksConfig, configDir: String) throws {
    try CursorCLIJSONStore<CursorCLIBookmarksConfig>(url: url(configDir: configDir)).save(config)
    try saveLegacyBookmarks(config.bookmarks, configDir: configDir)
  }

  public static func addBookmark(
    type: CursorCLIBookmarkType,
    sessionId: String,
    messageId: String? = nil,
    name: String? = nil,
    description: String? = nil,
    tags: [String] = [],
    fromMessageId: String? = nil,
    toMessageId: String? = nil,
    configDir: String
  ) throws -> CursorCLIBookmark {
    var config = try load(configDir: configDir)
    var manager = CursorCLIBookmarkManager()
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

  public static func getBookmark(id: String, configDir: String) throws -> CursorCLIBookmark? {
    try load(configDir: configDir).bookmarks.first { $0.id == id }
  }

  public static func listBookmarks(
    sessionId: String? = nil,
    type: CursorCLIBookmarkType? = nil,
    tag: String? = nil,
    configDir: String
  ) throws -> [CursorCLIBookmark] {
    var manager = CursorCLIBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.list(sessionId: sessionId, type: type, tag: tag)
  }

  public static func searchBookmarks(_ text: String, configDir: String) throws -> [CursorCLIBookmark] {
    try searchBookmarkResults(text, limit: Int.max, configDir: configDir).map(\.bookmark)
  }

  public static func searchBookmarkResults(
    _ text: String,
    limit: Int = 50,
    configDir: String
  ) throws -> [CursorCLIBookmarkSearchResult] {
    var manager = CursorCLIBookmarkManager()
    manager.replaceBookmarks(try load(configDir: configDir).bookmarks)
    return manager.searchResults(text: text, limit: limit)
  }

  public static func deleteBookmark(id: String, configDir: String) throws -> Bool {
    var config = try load(configDir: configDir)
    var manager = CursorCLIBookmarkManager()
    manager.replaceBookmarks(config.bookmarks)
    let deleted = manager.delete(id: id)
    config.bookmarks = manager.list()
    try save(config, configDir: configDir)
    return deleted
  }

  private static func mergeBookmarks(_ aggregate: [CursorCLIBookmark], _ legacy: [CursorCLIBookmark]) -> [CursorCLIBookmark] {
    var byId = Dictionary(uniqueKeysWithValues: aggregate.map { ($0.id, $0) })
    for bookmark in legacy {
      byId[bookmark.id] = bookmark
    }
    return byId.values.sorted { bookmarkSortTimestamp($0) > bookmarkSortTimestamp($1) }
  }

  private static func loadLegacyBookmarks(configDir: String) -> [CursorCLIBookmark] {
    let directory = legacyDirectory(configDir: configDir)
    guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    return entries.compactMap { entry -> CursorCLIBookmark? in
      guard entry.pathExtension == "json" else {
        return nil
      }
      let isRegularFile = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
      guard isRegularFile, let data = try? Data(contentsOf: entry) else {
        return nil
      }
      return try? JSONDecoder().decode(CursorCLIBookmark.self, from: data)
    }
  }

  private static func saveLegacyBookmarks(_ bookmarks: [CursorCLIBookmark], configDir: String) throws {
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
