import Foundation
import AgentRuntimeKit
import RielaCore

public struct CodexBackendActivityProbe: SessionBackendActivityProbing {
  private static let launchCorrelationTolerance: TimeInterval = 60
  private static let candidateLimit = 200

  public let backend = NodeExecutionBackend.codexAgent
  public var codexHome: String

  public init(codexHome: String = CodexSessionIndex.resolveCodexHome()) {
    self.codexHome = codexHome
  }

  public func assess(_ input: SessionBackendActivityProbeInput) throws -> SessionBackendActivity {
    guard FileManager.default.fileExists(atPath: codexHome) else {
      return SessionBackendActivityClassifier.classify(
        input: input,
        providerActivityAt: nil,
        providerEvidence: [SessionBackendActivityEvidence(
          kind: .diagnostic,
          detail: "Codex home is unavailable"
        )],
        requiresProviderArtifactForStall: true,
        hasCorrelatedProviderArtifact: false
      )
    }
    let lookup = activityCandidates(input)
    if lookup.truncated {
      return .unknown(
        backend: input.backend,
        observedAt: input.observedAt,
        activeThresholdMs: input.activeThresholdMs,
        stalledThresholdMs: input.stalledThresholdMs,
        reason: "Codex artifact candidate limit was exceeded"
      )
    }
    let matches = lookup.sessions
    guard matches.count <= 1 else {
      return .unknown(
        backend: input.backend,
        observedAt: input.observedAt,
        activeThresholdMs: input.activeThresholdMs,
        stalledThresholdMs: input.stalledThresholdMs,
        reason: "Codex artifact correlation is ambiguous"
      )
    }
    let match = matches.first
    let artifact = match.flatMap(validatedArtifact)
    let evidence: [SessionBackendActivityEvidence]
    if let artifact {
      evidence = [SessionBackendActivityEvidence(
        kind: .artifact,
        detail: "uniquely correlated Codex rollout artifact",
        path: artifact.path,
        observedAt: artifact.modifiedAt,
        ageMs: SessionBackendActivityClassifier.ageMs(from: artifact.modifiedAt, to: input.observedAt)
      )]
    } else if let match {
      evidence = [SessionBackendActivityEvidence(
        kind: .diagnostic,
        detail: "correlated Codex rollout artifact is missing or unreadable",
        path: match.rolloutPath
      )]
    } else {
      evidence = []
    }
    return SessionBackendActivityClassifier.classify(
      input: input,
      providerActivityAt: artifact?.modifiedAt,
      providerEvidence: evidence,
      requiresProviderArtifactForStall: true,
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
    let sqliteSessions = CodexSessionSQLiteIndex.activitySessionsSqlite(
      codexHome: codexHome,
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
      home: codexHome,
      from: lowerBound,
      through: upperBound,
      limit: Self.candidateLimit
    )
    if rolloutPage.truncated {
      return ActivityCandidateLookup(sessions: [], truncated: true)
    }
    let rolloutSessions = rolloutPage.paths.compactMap(CodexSessionIndex.buildSession)
    var sessionsById = Dictionary(uniqueKeysWithValues: sqliteSessions.map { ($0.id, $0) })
    for session in rolloutSessions {
      sessionsById[session.id] = session
    }
    let candidates = Array(sessionsById.values)
    let matches: [CodexSession]
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

  private func validatedArtifact(_ session: CodexSession) -> ValidatedArtifact? {
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
    _ sessions: [CodexSession],
    input: SessionBackendActivityProbeInput
  ) -> [CodexSession] {
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
  var sessions: [CodexSession]
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
  limit: Int
) -> BoundedRolloutPathPage {
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
  return BoundedRolloutPathPage(paths: paths.sorted(), truncated: false)
}

private func activityDayPaths(from lowerBound: Date, through upperBound: Date) -> [String] {
  let formatter = DateFormatter()
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyy/MM/dd"
  return Array(Set([formatter.string(from: lowerBound), formatter.string(from: upperBound)])).sorted()
}
