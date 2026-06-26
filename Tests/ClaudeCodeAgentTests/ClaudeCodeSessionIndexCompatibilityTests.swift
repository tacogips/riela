import XCTest
@testable import ClaudeCodeAgent

final class ClaudeCodeSessionIndexCompatibilityTests: XCTestCase {
  func testSessionQueryUsesDeterministicTieBreakers() throws {
    let sessions = [
      ClaudeCodeSession(
        id: "beta",
        rolloutPath: "/tmp/beta.jsonl",
        createdAt: try testDate("2026-06-17T00:01:00Z"),
        updatedAt: try testDate("2026-06-17T00:10:00Z"),
        source: .cli,
        cwd: "/tmp/project",
        cliVersion: "1.0.0",
        title: "Beta"
      ),
      ClaudeCodeSession(
        id: "zeta",
        rolloutPath: "/tmp/zeta.jsonl",
        createdAt: try testDate("2026-06-17T00:01:00Z"),
        updatedAt: try testDate("2026-06-17T00:10:00Z"),
        source: .cli,
        cwd: "/tmp/project",
        cliVersion: "1.0.0",
        title: "Zeta"
      ),
      ClaudeCodeSession(
        id: "alpha",
        rolloutPath: "/tmp/alpha.jsonl",
        createdAt: try testDate("2026-06-17T00:02:00Z"),
        updatedAt: try testDate("2026-06-17T00:10:00Z"),
        source: .cli,
        cwd: "/tmp/project",
        cliVersion: "1.0.0",
        title: "Alpha"
      )
    ]

    let sorted = ClaudeCodeSessionQuery.sorted(
      sessions,
      options: ClaudeCodeSessionListOptions(sortBy: "updatedAt", sortOrder: "desc")
    )

    XCTAssertEqual(sorted.map(\.id), ["alpha", "zeta", "beta"])
  }

  func testSessionIndexUsesRolloutMetadataBeforeStaleSQLiteRows() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    try writeClaudeSQLiteState(
      home: home,
      sessionId: "metadata-drift-session",
      cwd: "/tmp/sqlite-project",
      source: "vscode",
      branch: "develop"
    )
    let sqliteFiltered = try XCTUnwrap(
      ClaudeCodeSessionSQLiteIndex.listSessionsSqlite(
        claudeCodeHome: home.path,
        options: ClaudeCodeSessionListOptions(
          claudeCodeHome: home.path,
          source: .vscode,
          cwd: "/tmp/../tmp/sqlite-project",
          branch: "develop"
        )
      )
    )
    XCTAssertEqual(sqliteFiltered.sessions.map(\.id), ["metadata-drift-session"])
    let rollout = try writeClaudeRollout(
      home: home,
      sessionId: "metadata-drift-session",
      cwd: "/tmp/project",
      source: "cli",
      branch: "main",
      message: "rollout metadata is authoritative",
      modifiedAt: "2026-06-17T00:10:00Z"
    )

    let rolloutFiltered = ClaudeCodeSessionIndex.listSessions(
      options: ClaudeCodeSessionListOptions(
        claudeCodeHome: home.path,
        source: .cli,
        cwd: "/tmp/../tmp/project",
        branch: "main"
      )
    )
    XCTAssertEqual(rolloutFiltered.sessions.map(\.id), ["metadata-drift-session"])

    let staleSQLiteFiltered = ClaudeCodeSessionIndex.listSessions(
      options: ClaudeCodeSessionListOptions(
        claudeCodeHome: home.path,
        source: .vscode,
        cwd: "/tmp/sqlite-project",
        branch: "develop"
      )
    )
    XCTAssertEqual(staleSQLiteFiltered.sessions, [])
    XCTAssertEqual(
      resolvedPath(ClaudeCodeSessionIndex.findSession(id: "metadata-drift-session", claudeCodeHome: home.path)?.rolloutPath),
      resolvedPath(rollout.path)
    )
  }

  func testSessionIndexPrefersNewestRolloutForDuplicateSessionIds() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let sessionId = "duplicate-session"
    _ = try writeClaudeRollout(
      home: home,
      sessionId: sessionId,
      cwd: "/tmp/old-project",
      source: "vscode",
      branch: "old",
      message: "older duplicate",
      modifiedAt: "2026-06-17T00:05:00Z"
    )
    let newerRollout = try writeClaudeRollout(
      home: home,
      sessionId: sessionId,
      cwd: "/tmp/new-project",
      source: "cli",
      branch: "main",
      message: "newer duplicate",
      modifiedAt: "2026-06-17T00:10:00Z",
      rolloutFileTimestamp: "2026-06-17T00-01-00"
    )

    let result = ClaudeCodeSessionIndex.listSessions(
      options: ClaudeCodeSessionListOptions(claudeCodeHome: home.path, sortBy: "updatedAt")
    )

    XCTAssertEqual(result.total, 1)
    let session = try XCTUnwrap(result.sessions.first)
    XCTAssertEqual(resolvedPath(session.rolloutPath), resolvedPath(newerRollout.path))
    XCTAssertEqual(session.cwd, "/tmp/new-project")
    XCTAssertEqual(session.source, .cli)
    XCTAssertEqual(
      resolvedPath(ClaudeCodeSessionIndex.findSession(id: sessionId, claudeCodeHome: home.path)?.rolloutPath),
      resolvedPath(newerRollout.path)
    )
    XCTAssertEqual(
      try ClaudeCodeSessionIndex.searchSessions(query: "newer duplicate", options: ClaudeCodeSessionListOptions(claudeCodeHome: home.path)).sessionIds,
      [sessionId]
    )
  }

  func testSessionSearchBudgetCountsReadableTranscriptsOnly() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let missingTranscriptId = "sqlite-missing-transcript"
    try writeClaudeSQLiteState(home: home, sessionId: missingTranscriptId)
    try FileManager.default.removeItem(at: home.appendingPathComponent("sqlite-\(missingTranscriptId).jsonl"))
    let readableSessionId = "readable-rollout"
    try writeClaudeRollout(
      home: home,
      sessionId: readableSessionId,
      message: "readable match",
      modifiedAt: "2026-06-17T00:01:00Z"
    )

    let search = try ClaudeCodeSessionIndex.searchSessions(
      query: "readable match",
      options: ClaudeCodeSessionListOptions(claudeCodeHome: home.path, sortBy: "updatedAt"),
      searchOptions: ClaudeCodeSessionTranscriptSearchOptions(maxSessions: 1)
    )

    XCTAssertEqual(search.sessionIds, [readableSessionId])
    XCTAssertEqual(search.scannedSessions, 1)
  }

  func testSessionSearchReportsTruncationWhenMaxSessionsSkipsReadableCandidates() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    try writeClaudeRollout(
      home: home,
      sessionId: "first",
      message: "not the target",
      modifiedAt: "2026-06-17T00:02:00Z",
      rolloutFileTimestamp: "2026-06-17T00-02-00"
    )
    try writeClaudeRollout(
      home: home,
      sessionId: "second",
      message: "target needle",
      modifiedAt: "2026-06-17T00:01:00Z",
      rolloutFileTimestamp: "2026-06-17T00-01-00"
    )

    let search = try ClaudeCodeSessionIndex.searchSessions(
      query: "target needle",
      options: ClaudeCodeSessionListOptions(claudeCodeHome: home.path, sortBy: "updatedAt"),
      searchOptions: ClaudeCodeSessionTranscriptSearchOptions(maxSessions: 1)
    )

    XCTAssertEqual(search.sessionIds, [])
    XCTAssertEqual(search.scannedSessions, 1)
    XCTAssertTrue(search.truncated)
  }
}

private func resolvedPath(_ path: String?) -> String? {
  path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
}
