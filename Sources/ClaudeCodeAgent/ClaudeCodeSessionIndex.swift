import Foundation
import RielaCore

public struct ClaudeCodeSession: Equatable, Sendable {
  public var id: String
  public var rolloutPath: String
  public var createdAt: Date
  public var updatedAt: Date
  public var source: ClaudeCodeSessionSource
  public var modelProvider: String?
  public var cwd: String
  public var cliVersion: String
  public var title: String
  public var firstUserMessage: String?
  public var archivedAt: Date?
  public var git: ClaudeCodeSessionGit?
  public var forkedFromId: String?

  public init(
    id: String,
    rolloutPath: String,
    createdAt: Date,
    updatedAt: Date,
    source: ClaudeCodeSessionSource,
    modelProvider: String? = nil,
    cwd: String,
    cliVersion: String,
    title: String,
    firstUserMessage: String? = nil,
    archivedAt: Date? = nil,
    git: ClaudeCodeSessionGit? = nil,
    forkedFromId: String? = nil
  ) {
    self.id = id
    self.rolloutPath = rolloutPath
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.source = source
    self.modelProvider = modelProvider
    self.cwd = cwd
    self.cliVersion = cliVersion
    self.title = title
    self.firstUserMessage = firstUserMessage
    self.archivedAt = archivedAt
    self.git = git
    self.forkedFromId = forkedFromId
  }
}

public struct ClaudeCodeSessionListOptions: Equatable, Sendable {
  public var claudeCodeHome: String?
  public var source: ClaudeCodeSessionSource?
  public var cwd: String?
  public var branch: String?
  public var limit: Int
  public var offset: Int
  public var sortBy: String
  public var sortOrder: String

  public init(
    claudeCodeHome: String? = nil,
    source: ClaudeCodeSessionSource? = nil,
    cwd: String? = nil,
    branch: String? = nil,
    limit: Int = 50,
    offset: Int = 0,
    sortBy: String = "createdAt",
    sortOrder: String = "desc"
  ) {
    self.claudeCodeHome = claudeCodeHome
    self.source = source
    self.cwd = cwd
    self.branch = branch
    self.limit = limit
    self.offset = offset
    self.sortBy = sortBy
    self.sortOrder = sortOrder
  }
}

public struct ClaudeCodeSessionListResult: Equatable, Sendable {
  public var sessions: [ClaudeCodeSession]
  public var total: Int
  public var offset: Int
  public var limit: Int

  public init(sessions: [ClaudeCodeSession], total: Int, offset: Int, limit: Int) {
    self.sessions = sessions
    self.total = total
    self.offset = offset
    self.limit = limit
  }
}

public struct ClaudeCodeSessionTranscriptSearchOptions: Equatable, Sendable {
  public var caseSensitive: Bool
  public var role: String
  public var maxBytes: Int?
  public var maxEvents: Int?
  public var maxSessions: Int?
  public var timeoutMs: Int?
  public var limit: Int
  public var offset: Int

  public init(
    caseSensitive: Bool = false,
    role: String = "both",
    maxBytes: Int? = nil,
    maxEvents: Int? = nil,
    maxSessions: Int? = nil,
    timeoutMs: Int? = nil,
    limit: Int = 50,
    offset: Int = 0
  ) {
    self.caseSensitive = caseSensitive
    self.role = role
    self.maxBytes = maxBytes
    self.maxEvents = maxEvents
    self.maxSessions = maxSessions
    self.timeoutMs = timeoutMs
    self.limit = limit
    self.offset = offset
  }
}

public struct ClaudeCodeSessionsSearchResult: Equatable, Sendable {
  public var sessionIds: [String]
  public var total: Int
  public var offset: Int
  public var limit: Int
  public var scannedSessions: Int
  public var scannedBytes: Int
  public var scannedEvents: Int
  public var truncated: Bool
  public var timedOut: Bool
  public var durationMs: Double

  public init(sessionIds: [String], total: Int, offset: Int, limit: Int, scannedSessions: Int, scannedBytes: Int, scannedEvents: Int, truncated: Bool, timedOut: Bool = false, durationMs: Double = 0) {
    self.sessionIds = sessionIds
    self.total = total
    self.offset = offset
    self.limit = limit
    self.scannedSessions = scannedSessions
    self.scannedBytes = scannedBytes
    self.scannedEvents = scannedEvents
    self.truncated = truncated
    self.timedOut = timedOut
    self.durationMs = durationMs
  }
}

public struct ClaudeCodeTranscriptSearchResult: Equatable, Sendable {
  public var matched: Bool
  public var matchCount: Int
  public var scannedBytes: Int
  public var scannedEvents: Int
  public var truncated: Bool
  public var timedOut: Bool
  public var durationMs: Double

  public init(matched: Bool, matchCount: Int, scannedBytes: Int, scannedEvents: Int, truncated: Bool, timedOut: Bool = false, durationMs: Double = 0) {
    self.matched = matched
    self.matchCount = matchCount
    self.scannedBytes = scannedBytes
    self.scannedEvents = scannedEvents
    self.truncated = truncated
    self.timedOut = timedOut
    self.durationMs = durationMs
  }
}

public enum ClaudeCodeActivityStatus: String, Equatable, Sendable {
  case idle
  case running
  case waitingApproval = "waiting_approval"
  case failed
}

public struct ClaudeCodeActivityEntry: Equatable, Sendable {
  public var sessionId: String
  public var status: ClaudeCodeActivityStatus
  public var updatedAt: String

  public init(sessionId: String, status: ClaudeCodeActivityStatus, updatedAt: String) {
    self.sessionId = sessionId
    self.status = status
    self.updatedAt = updatedAt
  }
}

public enum ClaudeCodeSessionIndex {
  public static func resolveClaudeCodeHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    environment["CLAUDE_CONFIG_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
  }

  public static func discoverRolloutPaths(claudeCodeHome: String? = nil) -> [String] {
    let home = claudeCodeHome ?? resolveClaudeCodeHome()
    let sessionsDir = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
    var paths: [String] = []
    collectDateRollouts(root: sessionsDir, into: &paths)
    let archivedDir = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("archived_sessions", isDirectory: true)
    paths.append(contentsOf: rolloutFiles(in: archivedDir))
    paths.append(contentsOf: legacyProjectSessionFiles(home: home))
    return Array(Set(paths)).sorted()
  }

  public static func buildSession(rolloutPath: String) -> ClaudeCodeSession? {
    guard let meta = try? ClaudeCodeRolloutReader.parseSessionMeta(path: rolloutPath) else {
      return buildLegacyProjectSession(path: rolloutPath)
    }
    guard let createdAt = isoDate(meta.timestamp) else {
      return nil
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath)
    let updatedAt = attributes?[.modificationDate] as? Date ?? createdAt
    let firstUserMessage = try? ClaudeCodeRolloutReader.extractFirstUserMessage(path: rolloutPath)
    let archivedAt = rolloutPath.contains("/archived_sessions/") ? updatedAt : nil
    return ClaudeCodeSession(
      id: meta.id,
      rolloutPath: rolloutPath,
      createdAt: createdAt,
      updatedAt: updatedAt,
      source: meta.source,
      modelProvider: meta.modelProvider,
      cwd: meta.cwd,
      cliVersion: meta.cliVersion,
      title: firstUserMessage ?? meta.id,
      firstUserMessage: firstUserMessage,
      archivedAt: archivedAt,
      git: meta.git,
      forkedFromId: meta.forkedFromId
    )
  }

  public static func listSessions(options: ClaudeCodeSessionListOptions = ClaudeCodeSessionListOptions()) -> ClaudeCodeSessionListResult {
    var sessions = mergedIndexedSessions(claudeCodeHome: options.claudeCodeHome)
    sessions = ClaudeCodeSessionQuery.sorted(sessions.filter { ClaudeCodeSessionQuery.matches($0, options: options) }, options: options)
    let total = sessions.count
    let pageRange = ClaudeCodeSessionQuery.page(totalCount: total, offset: options.offset, limit: options.limit)
    return ClaudeCodeSessionListResult(sessions: Array(sessions[pageRange]), total: total, offset: options.offset, limit: options.limit)
  }

  private static func mergedIndexedSessions(claudeCodeHome: String?) -> [ClaudeCodeSession] {
    let sqliteSessions = unfilteredSQLiteSessions(claudeCodeHome: claudeCodeHome)
    let rolloutSessions = preferredRolloutSessions(discoverRolloutPaths(claudeCodeHome: claudeCodeHome).compactMap(buildSession))
    let rolloutIds = Set(rolloutSessions.map(\.id))
    return rolloutSessions + sqliteSessions.filter { !rolloutIds.contains($0.id) }
  }

  private static func unfilteredSQLiteSessions(claudeCodeHome: String?) -> [ClaudeCodeSession] {
    ClaudeCodeSessionSQLiteIndex.listSessionsSqlite(
      claudeCodeHome: claudeCodeHome,
      options: ClaudeCodeSessionListOptions(
        claudeCodeHome: claudeCodeHome,
        limit: Int.max,
        offset: 0
      )
    )?.sessions ?? []
  }

  private static func preferredRolloutSessions(_ sessions: [ClaudeCodeSession]) -> [ClaudeCodeSession] {
    var ids: [String] = []
    var sessionsById: [String: ClaudeCodeSession] = [:]
    for session in sessions {
      guard let existing = sessionsById[session.id] else {
        ids.append(session.id)
        sessionsById[session.id] = session
        continue
      }
      if shouldPreferRolloutSession(session, over: existing) {
        sessionsById[session.id] = session
      }
    }
    return ids.compactMap { sessionsById[$0] }
  }

  private static func shouldPreferRolloutSession(_ candidate: ClaudeCodeSession, over existing: ClaudeCodeSession) -> Bool {
    if candidate.updatedAt != existing.updatedAt {
      return candidate.updatedAt > existing.updatedAt
    }
    if candidate.createdAt != existing.createdAt {
      return candidate.createdAt > existing.createdAt
    }
    return candidate.rolloutPath > existing.rolloutPath
  }

  public static func findSession(id: String, claudeCodeHome: String? = nil) -> ClaudeCodeSession? {
    mergedIndexedSessions(claudeCodeHome: claudeCodeHome).first { $0.id == id }
  }

  public static func findLatestSession(claudeCodeHome: String? = nil, cwd: String? = nil) -> ClaudeCodeSession? {
    listSessions(options: ClaudeCodeSessionListOptions(claudeCodeHome: claudeCodeHome, cwd: cwd, limit: 1, sortBy: "updatedAt")).sessions.first
  }

  public static func searchSessionTranscript(session: ClaudeCodeSession, query: String, options: ClaudeCodeSessionTranscriptSearchOptions = ClaudeCodeSessionTranscriptSearchOptions()) throws -> Bool {
    try searchSessionTranscriptDetailed(session: session, query: query, options: options).matched
  }

  public static func searchSessionTranscriptDetailed(
    session: ClaudeCodeSession,
    query: String,
    options: ClaudeCodeSessionTranscriptSearchOptions = ClaudeCodeSessionTranscriptSearchOptions(),
    stopAtFirstMatch: Bool = false
  ) throws -> ClaudeCodeTranscriptSearchResult {
    guard !query.isEmpty else {
      throw ClaudeCodeSessionSearchError.emptyQuery
    }
    let startedAt = Date()
    let messages = try ClaudeCodeRolloutReader.getSessionMessages(path: session.rolloutPath)
    let needle = options.caseSensitive ? query : query.lowercased()
    var matchCount = 0
    var scannedBytes = 0
    var scannedEvents = 0
    for message in messages {
      if let timeoutMs = options.timeoutMs, Date().timeIntervalSince(startedAt) * 1000 >= Double(timeoutMs) {
        return ClaudeCodeTranscriptSearchResult(
          matched: matchCount > 0,
          matchCount: matchCount,
          scannedBytes: scannedBytes,
          scannedEvents: scannedEvents,
          truncated: true,
          timedOut: true,
          durationMs: Date().timeIntervalSince(startedAt) * 1000
        )
      }
      if let maxEvents = options.maxEvents, scannedEvents >= maxEvents {
        return ClaudeCodeTranscriptSearchResult(
          matched: matchCount > 0,
          matchCount: matchCount,
          scannedBytes: scannedBytes,
          scannedEvents: scannedEvents,
          truncated: true,
          durationMs: Date().timeIntervalSince(startedAt) * 1000
        )
      }
      scannedEvents += 1
      if options.role != "both", message.role != options.role {
        continue
      }
      guard let text = message.text else {
        continue
      }
      let textBytes = text.lengthOfBytes(using: .utf8)
      let searchableText: String
      let consumedBytes: Int
      let truncatedByBytes: Bool
      if let maxBytes = options.maxBytes {
        let remainingBytes = maxBytes - scannedBytes
        guard remainingBytes > 0 else {
          return ClaudeCodeTranscriptSearchResult(
            matched: matchCount > 0,
            matchCount: matchCount,
            scannedBytes: scannedBytes,
            scannedEvents: scannedEvents,
            truncated: true,
            durationMs: Date().timeIntervalSince(startedAt) * 1000
          )
        }
        if textBytes > remainingBytes {
          searchableText = utf8Prefix(text, maxBytes: remainingBytes)
          consumedBytes = searchableText.lengthOfBytes(using: .utf8)
          truncatedByBytes = true
        } else {
          searchableText = text
          consumedBytes = textBytes
          truncatedByBytes = false
        }
      } else {
        searchableText = text
        consumedBytes = textBytes
        truncatedByBytes = false
      }
      scannedBytes += consumedBytes
      let count = countMatches(text: searchableText, query: needle, caseSensitive: options.caseSensitive)
      if count > 0 {
        matchCount += count
        if stopAtFirstMatch {
          return ClaudeCodeTranscriptSearchResult(
            matched: true,
            matchCount: matchCount,
            scannedBytes: scannedBytes,
            scannedEvents: scannedEvents,
            truncated: truncatedByBytes,
            durationMs: Date().timeIntervalSince(startedAt) * 1000
          )
        }
      }
      if truncatedByBytes {
        return ClaudeCodeTranscriptSearchResult(
          matched: matchCount > 0,
          matchCount: matchCount,
          scannedBytes: scannedBytes,
          scannedEvents: scannedEvents,
          truncated: true,
          durationMs: Date().timeIntervalSince(startedAt) * 1000
        )
      }
    }
    return ClaudeCodeTranscriptSearchResult(
      matched: matchCount > 0,
      matchCount: matchCount,
      scannedBytes: scannedBytes,
      scannedEvents: scannedEvents,
      truncated: false,
      durationMs: Date().timeIntervalSince(startedAt) * 1000
    )
  }

  public static func searchSessions(
    query: String,
    options: ClaudeCodeSessionListOptions = ClaudeCodeSessionListOptions(),
    searchOptions: ClaudeCodeSessionTranscriptSearchOptions = ClaudeCodeSessionTranscriptSearchOptions()
  ) throws -> ClaudeCodeSessionsSearchResult {
    guard !query.isEmpty else {
      throw ClaudeCodeSessionSearchError.emptyQuery
    }
    let startedAt = Date()
    let allCandidates = listSessions(options: ClaudeCodeSessionListOptions(
      claudeCodeHome: options.claudeCodeHome,
      source: options.source,
      cwd: options.cwd,
      branch: options.branch,
      limit: Int.max,
      offset: 0,
      sortBy: options.sortBy,
      sortOrder: options.sortOrder
    )).sessions
    let readableCandidates = allCandidates.filter(sessionHasReadableTranscript)
    let maxSessions = max(0, searchOptions.maxSessions ?? readableCandidates.count)
    let candidates = readableCandidates.prefix(maxSessions)
    var matches: [String] = []
    var scannedBytes = 0
    var scannedEvents = 0
    var scannedSessions = 0
    var truncated = readableCandidates.count > candidates.count
    var timedOut = false
    for session in candidates {
      if let timeoutMs = searchOptions.timeoutMs, Date().timeIntervalSince(startedAt) * 1000 >= Double(timeoutMs) {
        timedOut = true
        truncated = true
        break
      }
      if let maxBytes = searchOptions.maxBytes, scannedBytes >= maxBytes {
        truncated = true
        break
      }
      if let maxEvents = searchOptions.maxEvents, scannedEvents >= maxEvents {
        truncated = true
        break
      }
      scannedSessions += 1
      var sessionOptions = searchOptions
      if let maxBytes = searchOptions.maxBytes {
        sessionOptions.maxBytes = max(0, maxBytes - scannedBytes)
      }
      if let maxEvents = searchOptions.maxEvents {
        sessionOptions.maxEvents = max(0, maxEvents - scannedEvents)
      }
      let result = try searchSessionTranscriptDetailed(session: session, query: query, options: sessionOptions, stopAtFirstMatch: true)
      scannedBytes += result.scannedBytes
      scannedEvents += result.scannedEvents
      if result.matched {
        matches.append(session.id)
      }
      if result.timedOut {
        timedOut = true
        truncated = true
        break
      }
      if result.truncated {
        truncated = true
        break
      }
    }
    let total = matches.count
    let pageRange = ClaudeCodeSessionQuery.page(totalCount: total, offset: searchOptions.offset, limit: searchOptions.limit)
    return ClaudeCodeSessionsSearchResult(
      sessionIds: Array(matches[pageRange]),
      total: total,
      offset: searchOptions.offset,
      limit: searchOptions.limit,
      scannedSessions: scannedSessions,
      scannedBytes: scannedBytes,
      scannedEvents: scannedEvents,
      truncated: truncated,
      timedOut: timedOut,
      durationMs: Date().timeIntervalSince(startedAt) * 1000
    )
  }

  private static func sessionHasReadableTranscript(_ session: ClaudeCodeSession) -> Bool {
    FileManager.default.isReadableFile(atPath: session.rolloutPath)
  }

  private static func countMatches(text: String, query: String, caseSensitive: Bool) -> Int {
    let haystack = caseSensitive ? text : text.lowercased()
    guard !query.isEmpty else {
      return 0
    }
    var count = 0
    var searchStart = haystack.startIndex
    while let range = haystack.range(of: query, range: searchStart..<haystack.endIndex) {
      count += 1
      searchStart = range.upperBound
    }
    return count
  }

  private static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else {
      return ""
    }
    var result = ""
    var usedBytes = 0
    for character in text {
      let characterBytes = String(character).lengthOfBytes(using: .utf8)
      guard usedBytes + characterBytes <= maxBytes else {
        break
      }
      result.append(character)
      usedBytes += characterBytes
    }
    return result
  }

  public static func deriveActivityEntry(sessionId: String, lines: [ClaudeCodeRolloutLine]) -> ClaudeCodeActivityEntry {
    var status = ClaudeCodeActivityStatus.idle
    var updatedAt = lines.last?.timestamp ?? ""
    for line in lines {
      updatedAt = line.timestamp
      guard let payload = jsonObject(line.payload), let type = jsonString(payload["type"]) else {
        continue
      }
      if type == "TurnStarted" || type == "ExecCommandBegin" {
        status = .running
      } else if type == "TurnComplete" || type == "ExecCommandEnd" {
        status = .idle
      } else if type == "Error" || type == "Aborted" {
        status = .failed
      } else if type == "PatchApplyApprovalRequest" || type == "ExecApprovalRequest" {
        status = .waitingApproval
      }
    }
    return ClaudeCodeActivityEntry(sessionId: sessionId, status: status, updatedAt: updatedAt)
  }
}

public enum ClaudeCodeSessionSearchError: Error, Equatable {
  case emptyQuery
}

enum ClaudeCodeSessionQuery {
  private enum SortField: String {
    case createdAt
    case updatedAt

    init(option: String) {
      self = Self(rawValue: option) ?? .createdAt
    }
  }

  private enum SortDirection: String {
    case ascending = "asc"
    case descending = "desc"

    init(option: String) {
      self = Self(rawValue: option) ?? .descending
    }

    var isAscending: Bool {
      self == .ascending
    }
  }

  static func matches(_ session: ClaudeCodeSession, options: ClaudeCodeSessionListOptions) -> Bool {
    if let source = options.source, session.source != source {
      return false
    }
    if let cwd = options.cwd, standardizedPath(session.cwd) != standardizedPath(cwd) {
      return false
    }
    if let branch = options.branch, session.git?.branch != branch {
      return false
    }
    return true
  }

  static func sorted(_ sessions: [ClaudeCodeSession], options: ClaudeCodeSessionListOptions) -> [ClaudeCodeSession] {
    sessions.sorted { lhs, rhs in
      isOrderedBefore(lhs, rhs, options: options)
    }
  }

  static func page(totalCount: Int, offset: Int, limit: Int) -> Range<Int> {
    let start = min(max(offset, 0), totalCount)
    let requestedCount = max(limit, 0)
    let end = start + min(requestedCount, totalCount - start)
    return start..<end
  }

  private static func isOrderedBefore(_ lhs: ClaudeCodeSession, _ rhs: ClaudeCodeSession, options: ClaudeCodeSessionListOptions) -> Bool {
    let field = SortField(option: options.sortBy)
    let direction = SortDirection(option: options.sortOrder)
    let leftPrimary = primarySortDate(lhs, field: field)
    let rightPrimary = primarySortDate(rhs, field: field)
    if leftPrimary != rightPrimary {
      return direction.isAscending ? leftPrimary < rightPrimary : leftPrimary > rightPrimary
    }
    let leftSecondary = secondarySortDate(lhs, field: field)
    let rightSecondary = secondarySortDate(rhs, field: field)
    if leftSecondary != rightSecondary {
      return direction.isAscending ? leftSecondary < rightSecondary : leftSecondary > rightSecondary
    }
    if lhs.id != rhs.id {
      return direction.isAscending ? lhs.id < rhs.id : lhs.id > rhs.id
    }
    return direction.isAscending ? lhs.rolloutPath < rhs.rolloutPath : lhs.rolloutPath > rhs.rolloutPath
  }

  private static func primarySortDate(_ session: ClaudeCodeSession, field: SortField) -> Date {
    field == .updatedAt ? session.updatedAt : session.createdAt
  }

  private static func secondarySortDate(_ session: ClaudeCodeSession, field: SortField) -> Date {
    field == .updatedAt ? session.createdAt : session.updatedAt
  }
}

public func resolveClaudeCodeHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
  ClaudeCodeSessionIndex.resolveClaudeCodeHome(environment: environment)
}

public func discoverRolloutPaths(claudeCodeHome: String? = nil) -> [String] {
  ClaudeCodeSessionIndex.discoverRolloutPaths(claudeCodeHome: claudeCodeHome)
}

public func buildSession(rolloutPath: String) -> ClaudeCodeSession? {
  ClaudeCodeSessionIndex.buildSession(rolloutPath: rolloutPath)
}

public func listSessions(options: ClaudeCodeSessionListOptions = ClaudeCodeSessionListOptions()) -> ClaudeCodeSessionListResult {
  ClaudeCodeSessionIndex.listSessions(options: options)
}

public func findSession(id: String, claudeCodeHome: String? = nil) -> ClaudeCodeSession? {
  ClaudeCodeSessionIndex.findSession(id: id, claudeCodeHome: claudeCodeHome)
}

public func findLatestSession(claudeCodeHome: String? = nil, cwd: String? = nil) -> ClaudeCodeSession? {
  ClaudeCodeSessionIndex.findLatestSession(claudeCodeHome: claudeCodeHome, cwd: cwd)
}

private func collectDateRollouts(root: URL, into paths: inout [String]) {
  for year in directoryNames(in: root).sorted(by: >) {
    let yearURL = root.appendingPathComponent(year, isDirectory: true)
    for month in directoryNames(in: yearURL).sorted(by: >) {
      let monthURL = yearURL.appendingPathComponent(month, isDirectory: true)
      for day in directoryNames(in: monthURL).sorted(by: >) {
        let dayURL = monthURL.appendingPathComponent(day, isDirectory: true)
        paths.append(contentsOf: rolloutFiles(in: dayURL))
      }
    }
  }
}

private func directoryNames(in url: URL) -> [String] {
  guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
    return []
  }
  return entries.filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }.map(\.lastPathComponent)
}

private func rolloutFiles(in url: URL) -> [String] {
  guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
    return []
  }
  return entries
    .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.lastPathComponent.hasSuffix(".jsonl") }
    .sorted { $0.lastPathComponent > $1.lastPathComponent }
    .map(\.path)
}

private func legacyProjectSessionFiles(home: String) -> [String] {
  let projects = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
  guard let enumerator = FileManager.default.enumerator(
    at: projects,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
  ) else {
    return []
  }
  var paths: [String] = []
  for case let url as URL in enumerator {
    guard url.pathExtension == "jsonl" else {
      continue
    }
    let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    if isRegularFile {
      paths.append(url.path)
    }
  }
  return paths.sorted()
}

private func buildLegacyProjectSession(path: String) -> ClaudeCodeSession? {
  guard path.contains("/projects/"), let lines = try? ClaudeCodeRolloutReader.readRollout(path: path), !lines.isEmpty else {
    return nil
  }
  let firstTimestamp = lines.first?.timestamp ?? ISO8601DateFormatter().string(from: Date())
  let createdAt = isoDate(firstTimestamp) ?? Date(timeIntervalSince1970: 0)
  let attributes = try? FileManager.default.attributesOfItem(atPath: path)
  let updatedAt = attributes?[.modificationDate] as? Date ?? createdAt
  let firstUserMessage = try? ClaudeCodeRolloutReader.extractFirstUserMessage(path: path)
  let title = firstUserMessage ?? legacySummaryTitle(lines: lines) ?? legacySessionId(from: path)
  return ClaudeCodeSession(
    id: legacySessionId(from: path),
    rolloutPath: path,
    createdAt: createdAt,
    updatedAt: updatedAt,
    source: .cli,
    cwd: legacyProjectCwd(lines: lines) ?? legacyProjectPath(from: path),
    cliVersion: legacyCliVersion(lines: lines) ?? "unknown",
    title: title,
    firstUserMessage: firstUserMessage
  )
}

private func legacySessionId(from path: String) -> String {
  let url = URL(fileURLWithPath: path)
  if url.lastPathComponent == "session.jsonl" {
    return url.deletingLastPathComponent().lastPathComponent
  }
  return url.deletingPathExtension().lastPathComponent
}

private func legacyProjectPath(from path: String) -> String {
  let components = URL(fileURLWithPath: path).pathComponents
  guard let projectsIndex = components.lastIndex(of: "projects"), projectsIndex + 1 < components.count else {
    return ""
  }
  let encoded = components[projectsIndex + 1]
  return encoded.replacingOccurrences(of: "-", with: "/")
}

private func legacyProjectCwd(lines: [ClaudeCodeRolloutLine]) -> String? {
  for line in lines {
    guard let payload = jsonObject(line.payload), let meta = jsonObject(payload["meta"]), let cwd = jsonString(meta["cwd"]), !cwd.isEmpty else {
      continue
    }
    return cwd
  }
  return nil
}

private func legacyCliVersion(lines: [ClaudeCodeRolloutLine]) -> String? {
  for line in lines {
    guard let payload = jsonObject(line.payload), let meta = jsonObject(payload["meta"]), let version = jsonString(meta["cli_version"]) else {
      continue
    }
    return version
  }
  return nil
}

private func legacySummaryTitle(lines: [ClaudeCodeRolloutLine]) -> String? {
  for line in lines {
    guard let payload = jsonObject(line.payload), let summary = jsonString(payload["summary"]) else {
      continue
    }
    return summary
  }
  return nil
}

private func isoDate(_ text: String) -> Date? {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: text) {
    return date
  }
  return ISO8601DateFormatter().date(from: text)
}

private func standardizedPath(_ path: String) -> String {
  URL(fileURLWithPath: path).standardizedFileURL.path
}

private func jsonString(_ value: RielaCore.JSONValue?) -> String? {
  guard case let .string(text) = value else {
    return nil
  }
  return text
}

private func jsonObject(_ value: RielaCore.JSONValue?) -> RielaCore.JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}
