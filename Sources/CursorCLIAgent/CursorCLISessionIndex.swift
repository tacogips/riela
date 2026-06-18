import Foundation
import RielaCore

public struct CursorCLISession: Equatable, Sendable {
  public var id: String
  public var rolloutPath: String
  public var createdAt: Date
  public var updatedAt: Date
  public var source: CursorCLISessionSource
  public var modelProvider: String?
  public var cwd: String
  public var cliVersion: String
  public var title: String
  public var firstUserMessage: String?
  public var archivedAt: Date?
  public var git: CursorCLISessionGit?
  public var forkedFromId: String?

  public init(
    id: String,
    rolloutPath: String,
    createdAt: Date,
    updatedAt: Date,
    source: CursorCLISessionSource,
    modelProvider: String? = nil,
    cwd: String,
    cliVersion: String,
    title: String,
    firstUserMessage: String? = nil,
    archivedAt: Date? = nil,
    git: CursorCLISessionGit? = nil,
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

public struct CursorCLISessionListOptions: Equatable, Sendable {
  public var cursorCLIHome: String?
  public var source: CursorCLISessionSource?
  public var cwd: String?
  public var branch: String?
  public var limit: Int
  public var offset: Int
  public var sortBy: String
  public var sortOrder: String

  public init(
    cursorCLIHome: String? = nil,
    source: CursorCLISessionSource? = nil,
    cwd: String? = nil,
    branch: String? = nil,
    limit: Int = 50,
    offset: Int = 0,
    sortBy: String = "createdAt",
    sortOrder: String = "desc"
  ) {
    self.cursorCLIHome = cursorCLIHome
    self.source = source
    self.cwd = cwd
    self.branch = branch
    self.limit = limit
    self.offset = offset
    self.sortBy = sortBy
    self.sortOrder = sortOrder
  }
}

public struct CursorCLISessionListResult: Equatable, Sendable {
  public var sessions: [CursorCLISession]
  public var total: Int
  public var offset: Int
  public var limit: Int

  public init(sessions: [CursorCLISession], total: Int, offset: Int, limit: Int) {
    self.sessions = sessions
    self.total = total
    self.offset = offset
    self.limit = limit
  }
}

public struct CursorCLISessionTranscriptSearchOptions: Equatable, Sendable {
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

public struct CursorCLISessionsSearchResult: Equatable, Sendable {
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

public struct CursorCLITranscriptSearchResult: Equatable, Sendable {
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

public enum CursorCLIActivityStatus: String, Equatable, Sendable {
  case idle
  case running
  case waitingApproval = "waiting_approval"
  case failed
}

public struct CursorCLIActivityEntry: Equatable, Sendable {
  public var sessionId: String
  public var status: CursorCLIActivityStatus
  public var updatedAt: String

  public init(sessionId: String, status: CursorCLIActivityStatus, updatedAt: String) {
    self.sessionId = sessionId
    self.status = status
    self.updatedAt = updatedAt
  }
}

public enum CursorCLISessionIndex {
  public static func resolveCursorCLIHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    environment["CURSOR_CLI_AGENT_CURSOR_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor").path
  }

  public static func discoverRolloutPaths(cursorCLIHome: String? = nil) -> [String] {
    let home = cursorCLIHome ?? resolveCursorCLIHome()
    var paths = cursorProjectTranscriptFiles(home: home)
    let sessionsDir = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
    collectDateRollouts(root: sessionsDir, into: &paths)
    let archivedDir = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("archived_sessions", isDirectory: true)
    paths.append(contentsOf: rolloutFiles(in: archivedDir))
    paths.append(contentsOf: legacyProjectSessionFiles(home: home))
    return Array(Set(paths)).sorted()
  }

  public static func buildSession(rolloutPath: String) -> CursorCLISession? {
    guard let meta = try? CursorCLIRolloutReader.parseSessionMeta(path: rolloutPath) else {
      return buildLegacyProjectSession(path: rolloutPath)
    }
    guard let createdAt = isoDate(meta.timestamp) else {
      return nil
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath)
    let updatedAt = attributes?[.modificationDate] as? Date ?? createdAt
    let firstUserMessage = try? CursorCLIRolloutReader.extractFirstUserMessage(path: rolloutPath)
    let archivedAt = rolloutPath.contains("/archived_sessions/") ? updatedAt : nil
    return CursorCLISession(
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

  public static func listSessions(options: CursorCLISessionListOptions = CursorCLISessionListOptions()) -> CursorCLISessionListResult {
    var sessions: [CursorCLISession] = []
    if let sqliteResult = CursorCLISessionSQLiteIndex.listSessionsSqlite(
      cursorCLIHome: options.cursorCLIHome,
      options: CursorCLISessionListOptions(cursorCLIHome: options.cursorCLIHome, limit: Int.max, offset: 0, sortBy: options.sortBy, sortOrder: options.sortOrder)
    ) {
      sessions.append(contentsOf: sqliteResult.sessions)
    }
    let existingIds = Set(sessions.map(\.id))
    sessions.append(contentsOf: discoverRolloutPaths(cursorCLIHome: options.cursorCLIHome).compactMap(buildSession).filter { !existingIds.contains($0.id) })
    sessions = sessions.filter { session in
      if let source = options.source, session.source != source {
        return false
      }
      if let cwd = options.cwd, URL(fileURLWithPath: session.cwd).standardizedFileURL.path != URL(fileURLWithPath: cwd).standardizedFileURL.path {
        return false
      }
      if let branch = options.branch, session.git?.branch != branch {
        return false
      }
      return true
    }
    sessions.sort { lhs, rhs in
      let left = options.sortBy == "updatedAt" ? lhs.updatedAt : lhs.createdAt
      let right = options.sortBy == "updatedAt" ? rhs.updatedAt : rhs.createdAt
      return options.sortOrder == "asc" ? left < right : left > right
    }
    let total = sessions.count
    let start = min(max(options.offset, 0), sessions.count)
    let end = min(start + max(options.limit, 0), sessions.count)
    return CursorCLISessionListResult(sessions: Array(sessions[start..<end]), total: total, offset: options.offset, limit: options.limit)
  }

  public static func findSession(id: String, cursorCLIHome: String? = nil) -> CursorCLISession? {
    if let session = CursorCLISessionSQLiteIndex.findSessionSqlite(id: id, cursorCLIHome: cursorCLIHome) {
      return session
    }
    for path in discoverRolloutPaths(cursorCLIHome: cursorCLIHome) {
      guard let session = buildSession(rolloutPath: path), session.id == id else {
        continue
      }
      return session
    }
    return nil
  }

  public static func findLatestSession(cursorCLIHome: String? = nil, cwd: String? = nil) -> CursorCLISession? {
    listSessions(options: CursorCLISessionListOptions(cursorCLIHome: cursorCLIHome, cwd: cwd, limit: 1, sortBy: "updatedAt")).sessions.first
  }

  public static func searchSessionTranscript(session: CursorCLISession, query: String, options: CursorCLISessionTranscriptSearchOptions = CursorCLISessionTranscriptSearchOptions()) throws -> Bool {
    try searchSessionTranscriptDetailed(session: session, query: query, options: options).matched
  }

  public static func searchSessionTranscriptDetailed(
    session: CursorCLISession,
    query: String,
    options: CursorCLISessionTranscriptSearchOptions = CursorCLISessionTranscriptSearchOptions(),
    stopAtFirstMatch: Bool = false
  ) throws -> CursorCLITranscriptSearchResult {
    guard !query.isEmpty else {
      throw CursorCLISessionSearchError.emptyQuery
    }
    let startedAt = Date()
    let messages = try CursorCLIRolloutReader.getSessionMessages(path: session.rolloutPath)
    let needle = options.caseSensitive ? query : query.lowercased()
    var matchCount = 0
    var scannedBytes = 0
    var scannedEvents = 0
    for message in messages {
      if let timeoutMs = options.timeoutMs, Date().timeIntervalSince(startedAt) * 1000 >= Double(timeoutMs) {
        return CursorCLITranscriptSearchResult(
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
        return CursorCLITranscriptSearchResult(
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
          return CursorCLITranscriptSearchResult(
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
          return CursorCLITranscriptSearchResult(
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
        return CursorCLITranscriptSearchResult(
          matched: matchCount > 0,
          matchCount: matchCount,
          scannedBytes: scannedBytes,
          scannedEvents: scannedEvents,
          truncated: true,
          durationMs: Date().timeIntervalSince(startedAt) * 1000
        )
      }
    }
    return CursorCLITranscriptSearchResult(
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
    options: CursorCLISessionListOptions = CursorCLISessionListOptions(),
    searchOptions: CursorCLISessionTranscriptSearchOptions = CursorCLISessionTranscriptSearchOptions()
  ) throws -> CursorCLISessionsSearchResult {
    guard !query.isEmpty else {
      throw CursorCLISessionSearchError.emptyQuery
    }
    let startedAt = Date()
    let allCandidates = listSessions(
      options: CursorCLISessionListOptions(
        cursorCLIHome: options.cursorCLIHome,
        source: options.source,
        cwd: options.cwd,
        branch: options.branch,
        limit: Int.max,
        offset: 0,
        sortBy: options.sortBy,
        sortOrder: options.sortOrder
      )
    ).sessions
    let maxSessions = max(0, searchOptions.maxSessions ?? allCandidates.count)
    let candidates = Array(allCandidates.prefix(maxSessions))
    var matches: [String] = []
    var scannedBytes = 0
    var scannedEvents = 0
    var scannedSessions = 0
    var truncated = false
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
    let requestedOffset = max(0, searchOptions.offset)
    let requestedLimit = max(0, searchOptions.limit)
    let start = min(requestedOffset, matches.count)
    let end = min(start + requestedLimit, matches.count)
    return CursorCLISessionsSearchResult(
      sessionIds: Array(matches[start..<end]),
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

  public static func deriveActivityEntry(sessionId: String, lines: [CursorCLIRolloutLine]) -> CursorCLIActivityEntry {
    var status = CursorCLIActivityStatus.idle
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
    return CursorCLIActivityEntry(sessionId: sessionId, status: status, updatedAt: updatedAt)
  }
}

public enum CursorCLISessionSearchError: Error, Equatable {
  case emptyQuery
}

public func resolveCursorCLIHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
  CursorCLISessionIndex.resolveCursorCLIHome(environment: environment)
}

public func discoverRolloutPaths(cursorCLIHome: String? = nil) -> [String] {
  CursorCLISessionIndex.discoverRolloutPaths(cursorCLIHome: cursorCLIHome)
}

public func buildSession(rolloutPath: String) -> CursorCLISession? {
  CursorCLISessionIndex.buildSession(rolloutPath: rolloutPath)
}

public func listSessions(options: CursorCLISessionListOptions = CursorCLISessionListOptions()) -> CursorCLISessionListResult {
  CursorCLISessionIndex.listSessions(options: options)
}

public func findSession(id: String, cursorCLIHome: String? = nil) -> CursorCLISession? {
  CursorCLISessionIndex.findSession(id: id, cursorCLIHome: cursorCLIHome)
}

public func findLatestSession(cursorCLIHome: String? = nil, cwd: String? = nil) -> CursorCLISession? {
  CursorCLISessionIndex.findLatestSession(cursorCLIHome: cursorCLIHome, cwd: cwd)
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

private func cursorProjectTranscriptFiles(home: String) -> [String] {
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
    guard url.pathExtension == "jsonl", url.path.contains("/agent-transcripts/") else {
      continue
    }
    let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
    if isRegularFile {
      paths.append(url.path)
    }
  }
  return paths.sorted()
}

private func legacyProjectSessionFiles(home: String) -> [String] {
  cursorProjectTranscriptFiles(home: home)
}

private func buildLegacyProjectSession(path: String) -> CursorCLISession? {
  guard path.contains("/projects/"), let lines = try? CursorCLIRolloutReader.readRollout(path: path), !lines.isEmpty else {
    return nil
  }
  let firstTimestamp = lines.first?.timestamp ?? ISO8601DateFormatter().string(from: Date())
  let createdAt = isoDate(firstTimestamp) ?? Date(timeIntervalSince1970: 0)
  let attributes = try? FileManager.default.attributesOfItem(atPath: path)
  let updatedAt = attributes?[.modificationDate] as? Date ?? createdAt
  let firstUserMessage = try? CursorCLIRolloutReader.extractFirstUserMessage(path: path)
  let title = firstUserMessage ?? legacySummaryTitle(lines: lines) ?? legacySessionId(from: path)
  return CursorCLISession(
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

private func legacyProjectCwd(lines: [CursorCLIRolloutLine]) -> String? {
  for line in lines {
    guard let payload = jsonObject(line.payload), let meta = jsonObject(payload["meta"]), let cwd = jsonString(meta["cwd"]), !cwd.isEmpty else {
      continue
    }
    return cwd
  }
  return nil
}

private func legacyCliVersion(lines: [CursorCLIRolloutLine]) -> String? {
  for line in lines {
    guard let payload = jsonObject(line.payload), let meta = jsonObject(payload["meta"]), let version = jsonString(meta["cli_version"]) else {
      continue
    }
    return version
  }
  return nil
}

private func legacySummaryTitle(lines: [CursorCLIRolloutLine]) -> String? {
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
