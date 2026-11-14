import XCTest
@testable import CursorCLIAgent

final class CursorCLISessionIndexCompatibilityTests: XCTestCase {
  func testSessionQueryUsesDeterministicTieBreakers() throws {
    let sessions = [
      CursorCLISession(
        id: "beta",
        rolloutPath: "/tmp/beta.jsonl",
        createdAt: try testDate("2026-06-17T00:01:00Z"),
        updatedAt: try testDate("2026-06-17T00:10:00Z"),
        source: .cli,
        cwd: "/tmp/project",
        cliVersion: "1.0.0",
        title: "Beta"
      ),
      CursorCLISession(
        id: "zeta",
        rolloutPath: "/tmp/zeta.jsonl",
        createdAt: try testDate("2026-06-17T00:01:00Z"),
        updatedAt: try testDate("2026-06-17T00:10:00Z"),
        source: .cli,
        cwd: "/tmp/project",
        cliVersion: "1.0.0",
        title: "Zeta"
      ),
      CursorCLISession(
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

    let sorted = CursorCLISessionQuery.sorted(
      sessions,
      options: CursorCLISessionListOptions(sortBy: "updatedAt", sortOrder: "desc")
    )

    XCTAssertEqual(sorted.map(\.id), ["alpha", "zeta", "beta"])
  }

  func testRolloutWatcherEmitsCompleteLines() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let rollout = home.appendingPathComponent("projects/2026/06/17/rollout-session-watch.jsonl")
    try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "".write(to: rollout, atomically: true, encoding: .utf8)

    let watcher = CursorCLIRolloutWatcher()
    watcher.watchFile(path: rollout.path)
    try appendRaw(cursorEventMessageLine(timestamp: "2026-06-17T00:00:01.000Z", type: "UserMessage", message: "hello") + "\n", to: rollout)
    let events = watcher.flush()
    XCTAssertEqual(events.count, 1)
    if case let .line(path, line) = try XCTUnwrap(events.first) {
      XCTAssertEqual(path, rollout.path)
      XCTAssertEqual(line.type, "event_msg")
    } else {
      XCTFail("expected appended line event")
    }
    try appendRaw(
      #"{"timestamp":"2026-06-17T00:00:02.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"partial"}"#,
      to: rollout
    )
    XCTAssertEqual(watcher.flush(), [])
    try appendRaw("}\n", to: rollout)
    let completedPartial = watcher.flush()
    XCTAssertEqual(completedPartial.count, 1)
    if case let .line(_, line) = try XCTUnwrap(completedPartial.first),
       case let .object(payload) = line.payload {
      XCTAssertEqual(payload["message"], .string("partial"))
    } else {
      XCTFail("expected completed partial line event")
    }
    watcher.stop()
    XCTAssertTrue(watcher.isClosed)
    XCTAssertTrue(CursorCLIRolloutWatcher.sessionsWatchDir(cursorCLIHome: home.path).hasSuffix("/projects"))
  }

  func testSessionIndexUsesRolloutMetadataBeforeStaleSQLiteRows() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    try writeCursorSQLiteState(
      home: home,
      sessionId: "metadata-drift-session",
      cwd: "/tmp/sqlite-project",
      source: "vscode",
      branch: "develop"
    )
    let sqliteFiltered = try XCTUnwrap(
      CursorCLISessionSQLiteIndex.listSessionsSqlite(
        cursorCLIHome: home.path,
        options: CursorCLISessionListOptions(
          cursorCLIHome: home.path,
          source: .vscode,
          cwd: "/tmp/../tmp/sqlite-project",
          branch: "develop"
        )
      )
    )
    XCTAssertEqual(sqliteFiltered.sessions.map(\.id), ["metadata-drift-session"])
    let rollout = try writeCursorRollout(
      home: home,
      sessionId: "metadata-drift-session",
      cwd: "/tmp/project",
      source: "cli",
      branch: "main",
      message: "rollout metadata is authoritative",
      modifiedAt: "2026-06-17T00:10:00Z"
    )

    let rolloutFiltered = CursorCLISessionIndex.listSessions(
      options: CursorCLISessionListOptions(
        cursorCLIHome: home.path,
        source: .cli,
        cwd: "/tmp/../tmp/project",
        branch: "main"
      )
    )
    XCTAssertEqual(rolloutFiltered.sessions.map(\.id), ["metadata-drift-session"])

    let staleSQLiteFiltered = CursorCLISessionIndex.listSessions(
      options: CursorCLISessionListOptions(
        cursorCLIHome: home.path,
        source: .vscode,
        cwd: "/tmp/sqlite-project",
        branch: "develop"
      )
    )
    XCTAssertEqual(staleSQLiteFiltered.sessions, [])
    XCTAssertEqual(
      resolvedPath(CursorCLISessionIndex.findSession(id: "metadata-drift-session", cursorCLIHome: home.path)?.rolloutPath),
      resolvedPath(rollout.path)
    )
  }

  func testSessionIndexPrefersNewestRolloutForDuplicateSessionIds() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let sessionId = "duplicate-session"
    _ = try writeCursorRollout(
      home: home,
      sessionId: sessionId,
      cwd: "/tmp/old-project",
      source: "vscode",
      branch: "old",
      message: "older duplicate",
      modifiedAt: "2026-06-17T00:05:00Z"
    )
    let newerRollout = try writeCursorRollout(
      home: home,
      sessionId: sessionId,
      cwd: "/tmp/new-project",
      source: "cli",
      branch: "main",
      message: "newer duplicate",
      modifiedAt: "2026-06-17T00:10:00Z",
      rolloutFileTimestamp: "2026-06-17T00-01-00"
    )

    let result = CursorCLISessionIndex.listSessions(
      options: CursorCLISessionListOptions(cursorCLIHome: home.path, sortBy: "updatedAt")
    )

    XCTAssertEqual(result.total, 1)
    let session = try XCTUnwrap(result.sessions.first)
    XCTAssertEqual(resolvedPath(session.rolloutPath), resolvedPath(newerRollout.path))
    XCTAssertEqual(session.cwd, "/tmp/new-project")
    XCTAssertEqual(session.source, .cli)
    XCTAssertEqual(
      resolvedPath(CursorCLISessionIndex.findSession(id: sessionId, cursorCLIHome: home.path)?.rolloutPath),
      resolvedPath(newerRollout.path)
    )
    XCTAssertEqual(
      try CursorCLISessionIndex.searchSessions(query: "newer duplicate", options: CursorCLISessionListOptions(cursorCLIHome: home.path)).sessionIds,
      [sessionId]
    )
  }

  func testSessionSearchBudgetCountsReadableTranscriptsOnly() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let missingTranscriptId = "sqlite-missing-transcript"
    try writeCursorSQLiteState(home: home, sessionId: missingTranscriptId)
    try FileManager.default.removeItem(at: home.appendingPathComponent("sqlite-\(missingTranscriptId).jsonl"))
    let readableSessionId = "readable-rollout"
    try writeCursorRollout(
      home: home,
      sessionId: readableSessionId,
      message: "readable match",
      modifiedAt: "2026-06-17T00:01:00Z"
    )

    let search = try CursorCLISessionIndex.searchSessions(
      query: "readable match",
      options: CursorCLISessionListOptions(cursorCLIHome: home.path, sortBy: "updatedAt"),
      searchOptions: CursorCLISessionTranscriptSearchOptions(maxSessions: 1)
    )

    XCTAssertEqual(search.sessionIds, [readableSessionId])
    XCTAssertEqual(search.scannedSessions, 1)
  }

  func testSessionSearchReportsTruncationWhenMaxSessionsSkipsReadableCandidates() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    try writeCursorRollout(
      home: home,
      sessionId: "first",
      message: "not the target",
      modifiedAt: "2026-06-17T00:02:00Z",
      rolloutFileTimestamp: "2026-06-17T00-02-00"
    )
    try writeCursorRollout(
      home: home,
      sessionId: "second",
      message: "target needle",
      modifiedAt: "2026-06-17T00:01:00Z",
      rolloutFileTimestamp: "2026-06-17T00-01-00"
    )

    let search = try CursorCLISessionIndex.searchSessions(
      query: "target needle",
      options: CursorCLISessionListOptions(cursorCLIHome: home.path, sortBy: "updatedAt"),
      searchOptions: CursorCLISessionTranscriptSearchOptions(maxSessions: 1)
    )

    XCTAssertEqual(search.sessionIds, [])
    XCTAssertEqual(search.scannedSessions, 1)
    XCTAssertTrue(search.truncated)
  }

  private func appendRaw(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer {
      try? handle.close()
    }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
  }
}

private func resolvedPath(_ path: String?) -> String? {
  path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
}
