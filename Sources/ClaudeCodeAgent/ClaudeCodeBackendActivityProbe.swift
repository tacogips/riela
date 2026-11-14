import Foundation
import AgentRuntimeKit
import RielaCore

public struct ClaudeCodeBackendActivityProbe: SessionBackendActivityProbing {
  private static let launchCorrelationTolerance: TimeInterval = 60
  private static let candidateLimit = 200

  public let backend = NodeExecutionBackend.claudeCodeAgent
  public var claudeCodeHome: String

  public init(claudeCodeHome: String = ClaudeCodeSessionIndex.resolveClaudeCodeHome()) {
    self.claudeCodeHome = claudeCodeHome
  }

  public func assess(_ input: SessionBackendActivityProbeInput) throws -> SessionBackendActivity {
    let homeExists = FileManager.default.fileExists(atPath: claudeCodeHome)
    let lookup = homeExists
      ? activityCandidates(input)
      : ActivityCandidateLookup(sessions: [], truncated: false)
    if lookup.truncated {
      return .unknown(
        backend: input.backend,
        observedAt: input.observedAt,
        activeThresholdMs: input.activeThresholdMs,
        stalledThresholdMs: input.stalledThresholdMs,
        reason: "Claude artifact candidate limit was exceeded"
      )
    }
    let matches = lookup.sessions
    guard matches.count <= 1 else {
      return .unknown(
        backend: input.backend,
        observedAt: input.observedAt,
        activeThresholdMs: input.activeThresholdMs,
        stalledThresholdMs: input.stalledThresholdMs,
        reason: "Claude artifact correlation is ambiguous"
      )
    }
    let match = matches.first
    let artifact = match.flatMap(validatedArtifact)
    var evidence: [SessionBackendActivityEvidence] = []
    if let artifact {
      evidence.append(SessionBackendActivityEvidence(
        kind: .artifact,
        detail: "uniquely correlated Claude session artifact",
        path: artifact.path,
        observedAt: artifact.modifiedAt,
        ageMs: SessionBackendActivityClassifier.ageMs(from: artifact.modifiedAt, to: input.observedAt)
      ))
    } else if let match {
      evidence.append(SessionBackendActivityEvidence(
        kind: .diagnostic,
        detail: "correlated Claude session artifact is missing or unreadable",
        path: match.rolloutPath
      ))
    } else if !homeExists {
      evidence.append(SessionBackendActivityEvidence(kind: .diagnostic, detail: "Claude home is unavailable"))
    }
    return SessionBackendActivityClassifier.classify(
      input: input,
      providerActivityAt: artifact?.modifiedAt,
      providerEvidence: evidence,
      requiresProviderArtifactForStall: false,
      hasCorrelatedProviderArtifact: artifact != nil
    )
  }

  private func activityCandidates(_ input: SessionBackendActivityProbeInput) -> ActivityCandidateLookup {
    let lowerBound = input.execution.createdAt.addingTimeInterval(-Self.launchCorrelationTolerance)
    let upperBound = input.execution.createdAt.addingTimeInterval(Self.launchCorrelationTolerance)
    let sqliteQuery = AgentSessionSQLiteQuery(
      id: input.execution.backendSessionId,
      cwd: input.execution.backendSessionId == nil ? input.execution.backendWorkingDirectory : nil,
      createdAfter: input.execution.backendSessionId == nil ? lowerBound : nil,
      createdBefore: input.execution.backendSessionId == nil ? upperBound : nil,
      limit: Self.candidateLimit + 1
    )
    let sqliteSessions = ClaudeCodeSessionSQLiteIndex.activitySessionsSqlite(
      claudeCodeHome: claudeCodeHome,
      query: sqliteQuery,
      readMode: .strict
    )
    if input.execution.backendSessionId != nil, sqliteSessions.count == 1 {
      return ActivityCandidateLookup(sessions: sqliteSessions, truncated: false)
    }
    if sqliteSessions.count > Self.candidateLimit {
      return ActivityCandidateLookup(sessions: [], truncated: true)
    }
    let rolloutPage = boundedRolloutPaths(
      home: claudeCodeHome,
      from: lowerBound,
      through: upperBound,
      backendSessionId: input.execution.backendSessionId,
      workingDirectory: input.execution.backendWorkingDirectory,
      limit: Self.candidateLimit
    )
    if rolloutPage.truncated {
      return ActivityCandidateLookup(sessions: [], truncated: true)
    }
    let rolloutSessions = rolloutPage.paths.compactMap(ClaudeCodeSessionIndex.buildSession)
    var sessionsById = Dictionary(uniqueKeysWithValues: sqliteSessions.map { ($0.id, $0) })
    for session in rolloutSessions {
      sessionsById[session.id] = session
    }
    let candidates = Array(sessionsById.values)
    let matches: [ClaudeCodeSession]
    if let backendSessionId = input.execution.backendSessionId {
      matches = candidates.filter { $0.id == backendSessionId }
    } else {
      matches = correlatedSessions(candidates, input: input)
    }
    return ActivityCandidateLookup(
      sessions: matches,
      truncated: candidates.count > Self.candidateLimit
    )
  }

  private func validatedArtifact(_ session: ClaudeCodeSession) -> ValidatedArtifact? {
    let url = URL(fileURLWithPath: session.rolloutPath)
    guard
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let modifiedAt = values.contentModificationDate,
      let handle = try? FileHandle(forReadingFrom: url)
    else {
      return nil
    }
    try? handle.close()
    return ValidatedArtifact(path: session.rolloutPath, modifiedAt: modifiedAt)
  }

  private func correlatedSessions(
    _ sessions: [ClaudeCodeSession],
    input: SessionBackendActivityProbeInput
  ) -> [ClaudeCodeSession] {
    guard let workingDirectory = input.execution.backendWorkingDirectory else {
      return []
    }
    let earliestCreatedAt = input.execution.createdAt.addingTimeInterval(-Self.launchCorrelationTolerance)
    let latestCreatedAt = input.execution.createdAt.addingTimeInterval(Self.launchCorrelationTolerance)
    return sessions.filter {
      $0.cwd == workingDirectory
        && $0.createdAt >= earliestCreatedAt
        && $0.createdAt <= latestCreatedAt
    }
  }
}

private struct ValidatedArtifact {
  var path: String
  var modifiedAt: Date
}

private struct ActivityCandidateLookup {
  var sessions: [ClaudeCodeSession]
  var truncated: Bool
}

private struct BoundedRolloutPathPage {
  var paths: [String]
  var truncated: Bool
}

private func boundedRolloutPaths(
  home: String,
  from lowerBound: Date,
  through upperBound: Date,
  backendSessionId: String?,
  workingDirectory: String?,
  limit: Int
) -> BoundedRolloutPathPage {
  let projectDirectory = workingDirectory.map {
    URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent(claudeProjectDirectoryName(for: $0), isDirectory: true)
  }
  if let backendSessionId,
     isSafeClaudeProjectSessionId(backendSessionId),
     let projectDirectory {
    let directPaths = [
      projectDirectory.appendingPathComponent("\(backendSessionId).jsonl"),
      projectDirectory
        .appendingPathComponent(backendSessionId, isDirectory: true)
        .appendingPathComponent("session.jsonl")
    ].filter {
      FileManager.default.fileExists(atPath: $0.path)
    }.map(\.path)
    if !directPaths.isEmpty {
      return BoundedRolloutPathPage(
        paths: Array(directPaths.prefix(limit)).sorted(),
        truncated: directPaths.count > limit
      )
    }
  }
  let sessionsRoot = URL(fileURLWithPath: home, isDirectory: true)
    .appendingPathComponent("sessions", isDirectory: true)
  var paths: [String] = []
  for day in activityDayPaths(from: lowerBound, through: upperBound) {
    let directory = sessionsRoot.appendingPathComponent(day, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
    ) else {
      continue
    }
    for case let url as URL in enumerator where
      url.lastPathComponent.hasPrefix("rollout-")
        && url.lastPathComponent.hasSuffix(".jsonl") {
      paths.append(url.path)
      if paths.count > limit {
        return BoundedRolloutPathPage(paths: [], truncated: true)
      }
    }
  }
  guard workingDirectory != nil else {
    return BoundedRolloutPathPage(paths: paths.sorted(), truncated: false)
  }
  guard backendSessionId == nil, let projectDirectory else {
    return BoundedRolloutPathPage(paths: paths.sorted(), truncated: false)
  }
  if let enumerator = FileManager.default.enumerator(
    at: projectDirectory,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
  ) {
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
      guard isRegularFile else {
        continue
      }
      paths.append(url.path)
      if paths.count > limit {
        return BoundedRolloutPathPage(paths: [], truncated: true)
      }
    }
  }
  return BoundedRolloutPathPage(paths: paths.sorted(), truncated: false)
}

private func claudeProjectDirectoryName(for workingDirectory: String) -> String {
  workingDirectory.replacingOccurrences(of: "/", with: "-")
}

private func isSafeClaudeProjectSessionId(_ sessionId: String) -> Bool {
  !sessionId.isEmpty
    && !sessionId.contains("/")
    && !sessionId.contains("\\")
    && !sessionId.contains("..")
}

private func activityDayPaths(from lowerBound: Date, through upperBound: Date) -> [String] {
  let formatter = DateFormatter()
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyy/MM/dd"
  return Array(Set([formatter.string(from: lowerBound), formatter.string(from: upperBound)])).sorted()
}
