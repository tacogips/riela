import Foundation
import XCTest
@testable import CodexAgent
@testable import RielaCore

final class CodexAgentSessionIndexCompatibilityTests: XCTestCase {
  func testSessionIndexListsFiltersFindsLatestAndSearchesTranscripts() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let day1 = home.appendingPathComponent("sessions/2025/05/07", isDirectory: true)
    let day2 = home.appendingPathComponent("sessions/2025/05/08", isDirectory: true)
    try FileManager.default.createDirectory(at: day1, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: day2, withIntermediateDirectories: true)
    let session1 = "aaaa0000-0000-0000-0000-000000000001"
    let session2 = "bbbb0000-0000-0000-0000-000000000002"
    let session3 = "cccc0000-0000-0000-0000-000000000003"
    let rollout1 = day1.appendingPathComponent("rollout-2025-05-07T17-24-21-\(session1).jsonl")
    let rollout2 = day1.appendingPathComponent("rollout-2025-05-07T18-00-00-\(session2).jsonl")
    let rollout3 = day2.appendingPathComponent("rollout-2025-05-08T10-00-00-\(session3).jsonl")
    try writeRollout(
      rollout1,
      id: session1,
      cwd: "/tmp/project-a",
      source: "cli",
      branch: "main",
      message: "Fix bug in auth",
      modifiedAt: "2025-05-09T10:00:00.000Z"
    )
    try writeRollout(
      rollout2,
      id: session2,
      cwd: "/tmp/project-b",
      source: "vscode",
      branch: "develop",
      message: "Add tests",
      modifiedAt: "2025-05-07T18:00:00.000Z"
    )
    try writeRollout(
      rollout3,
      id: session3,
      cwd: "/tmp/project-a",
      source: "exec",
      branch: nil,
      message: "日本語 transcript",
      modifiedAt: "2025-05-08T10:00:00.000Z"
    )

    let paths = discoverRolloutPaths(codexHome: home.path)
    XCTAssertEqual(paths.count, 3)
    XCTAssertTrue(paths[0].contains(session3))

    let all = listSessions(options: CodexSessionListOptions(codexHome: home.path))
    XCTAssertEqual(all.total, 3)
    let graphQLList = CodexGraphQLCommandExecutor.execute(command: "session.list", variables: ["codexHome": .string(home.path)])
    let graphQLSession = try XCTUnwrap(jsonObject(jsonArray(jsonObject(graphQLList.data)?["sessions"])?.first))
    XCTAssertNotNil(graphQLSession["createdAt"])
    XCTAssertNotNil(graphQLSession["updatedAt"])
    XCTAssertNotNil(graphQLSession["cliVersion"])
    XCTAssertNotNil(graphQLSession["firstUserMessage"])
    XCTAssertNotNil(graphQLSession["git"])
    XCTAssertEqual(listSessions(options: CodexSessionListOptions(codexHome: home.path, source: .cli)).sessions.map(\.id), [session1])
    XCTAssertEqual(listSessions(options: CodexSessionListOptions(codexHome: home.path, branch: "develop")).sessions.map(\.id), [session2])
    XCTAssertEqual(findSession(id: session2, codexHome: home.path)?.source, .vscode)
    XCTAssertEqual(findLatestSession(codexHome: home.path, cwd: "/tmp/project-a")?.id, session1)

    let search = try CodexSessionIndex.searchSessions(query: "日本語", options: CodexSessionListOptions(codexHome: home.path))
    XCTAssertEqual(search.sessionIds, [session3])

    let truncated = try CodexSessionIndex.searchSessions(
      query: "auth",
      options: CodexSessionListOptions(codexHome: home.path),
      searchOptions: CodexSessionTranscriptSearchOptions(maxEvents: 1)
    )
    XCTAssertEqual(truncated.scannedSessions, 1)
    XCTAssertTrue(truncated.truncated)

    let timedOut = try CodexSessionIndex.searchSessions(
      query: "auth",
      options: CodexSessionListOptions(codexHome: home.path),
      searchOptions: CodexSessionTranscriptSearchOptions(timeoutMs: 0)
    )
    XCTAssertTrue(timedOut.timedOut)
  }

  func testRolloutWatcherEmitsCompleteLines() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let rollout = home.appendingPathComponent("sessions/2025/05/07/rollout-2025-05-07T17-24-21-session-watch.jsonl")
    try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "".write(to: rollout, atomically: true, encoding: .utf8)

    let watcher = CodexRolloutWatcher()
    watcher.watchFile(path: rollout.path)
    try #"{"timestamp":"2025-05-07T17:24:23.000Z","type":"event_msg","payload":{"type":"UserMessage","message":"hello"}}"#.appendLine(to: rollout)
    let events = watcher.flush()
    XCTAssertEqual(events.count, 1)
    if case let .line(path, line) = try XCTUnwrap(events.first) {
      XCTAssertEqual(path, rollout.path)
      XCTAssertEqual(line.type, "event_msg")
    } else {
      XCTFail("expected appended line event")
    }
    try #"{"timestamp":"2025-05-07T17:24:24.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"partial"}"#.appendRaw(to: rollout)
    XCTAssertEqual(watcher.flush(), [])
    try "}\n".appendRaw(to: rollout)
    let completedPartial = watcher.flush()
    XCTAssertEqual(completedPartial.count, 1)
    if case let .line(_, line) = try XCTUnwrap(completedPartial.first) {
      if case let .object(payload) = line.payload {
        XCTAssertEqual(payload["message"], .string("partial"))
      } else {
        XCTFail("expected object payload")
      }
    } else {
      XCTFail("expected completed partial line event")
    }
    watcher.stop()
    XCTAssertTrue(watcher.isClosed)
    XCTAssertTrue(CodexRolloutWatcher.sessionsWatchDir(codexHome: home.path).hasSuffix("/sessions"))
  }

  func testSessionIndexMergesSQLiteAndRolloutsWithRolloutMetadataPrecedence() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let sessionsDir = home.appendingPathComponent("sessions/2025/05/07", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let state = home.appendingPathComponent("state")
    try createThreadsDatabase(at: state)
    try insertThread(
      SQLiteThreadFixture(
        id: "sqlite-session",
        rolloutPath: "/tmp/rollout.jsonl",
        createdAt: "2026-02-20T10:00:00Z",
        updatedAt: "2026-02-20T10:05:00Z",
        source: "cli",
        cwd: "/tmp/project",
        title: "SQLite title",
        firstUserMessage: "Hello",
        branch: "main"
      ),
      into: state
    )
    try insertThread(
      SQLiteThreadFixture(
        id: "metadata-drift-session",
        rolloutPath: "/tmp/stale-rollout.jsonl",
        createdAt: "2026-02-20T10:01:00Z",
        updatedAt: "2026-02-20T10:06:00Z",
        source: "vscode",
        cwd: "/tmp/other-project",
        title: "Stale SQLite title",
        firstUserMessage: "Stale",
        branch: "develop"
      ),
      into: state
    )

    let rolloutOnlySessionId = "rollout-only-session"
    let rolloutOnly = sessionsDir.appendingPathComponent(
      "rollout-2026-02-20T10-10-00-\(rolloutOnlySessionId).jsonl"
    )
    try writeRollout(
      rolloutOnly,
      id: rolloutOnlySessionId,
      cwd: "/tmp/project",
      source: "cli",
      branch: "main",
      message: "rollout only",
      modifiedAt: "2026-02-20T10:10:00.000Z"
    )
    let metadataDrift = sessionsDir.appendingPathComponent(
      "rollout-2026-02-20T10-12-00-metadata-drift-session.jsonl"
    )
    try writeRollout(
      metadataDrift,
      id: "metadata-drift-session",
      cwd: "/tmp/project",
      source: "cli",
      branch: "main",
      message: "rollout metadata is authoritative for this filter",
      modifiedAt: "2026-02-20T10:12:00.000Z"
    )

    XCTAssertEqual(CodexSessionSQLiteIndex.openCodexDb(codexHome: home.path), state.path)
    let sqliteSessions = try XCTUnwrap(CodexSessionSQLiteIndex.listSessionsSqlite(codexHome: home.path))
    XCTAssertEqual(sqliteSessions.sessions.map(\.id), ["metadata-drift-session", "sqlite-session"])
    XCTAssertEqual(findSession(id: "sqlite-session", codexHome: home.path)?.git?.branch, "main")
    XCTAssertEqual(
      CodexSessionSQLiteIndex.findLatestSessionSqlite(codexHome: home.path, cwd: "/tmp/../tmp/project")?.id,
      "sqlite-session"
    )
    let projectSessions = listSessions(
      options: CodexSessionListOptions(codexHome: home.path, cwd: "/tmp/../tmp/project", sortBy: "updatedAt")
    )
    XCTAssertEqual(projectSessions.sessions.map(\.id), ["metadata-drift-session", rolloutOnlySessionId, "sqlite-session"])
    let rolloutFilteredSessions = listSessions(
      options: CodexSessionListOptions(codexHome: home.path, source: .cli, cwd: "/tmp/project", branch: "main")
    )
    XCTAssertTrue(rolloutFilteredSessions.sessions.contains { $0.id == "metadata-drift-session" })
    let staleSQLiteFilteredSessions = listSessions(
      options: CodexSessionListOptions(codexHome: home.path, source: .vscode, cwd: "/tmp/other-project", branch: "develop")
    )
    XCTAssertFalse(staleSQLiteFilteredSessions.sessions.contains { $0.id == "metadata-drift-session" })
    let metadataDriftSession = try XCTUnwrap(findSession(id: "metadata-drift-session", codexHome: home.path))
    XCTAssertEqual(metadataDriftSession.rolloutPath, metadataDrift.path)
    XCTAssertEqual(metadataDriftSession.cwd, "/tmp/project")
    XCTAssertEqual(metadataDriftSession.source, .cli)
    XCTAssertEqual(
      findLatestSession(codexHome: home.path, cwd: "/tmp/../tmp/project")?.id,
      "metadata-drift-session"
    )

    let search = try CodexSessionIndex.searchSessions(
      query: "rollout metadata is authoritative",
      options: CodexSessionListOptions(codexHome: home.path)
    )
    XCTAssertEqual(search.sessionIds, ["metadata-drift-session"])
    let sqliteOnlyTranscript = CodexGraphQLCommandExecutor.execute(
      command: "session.searchTranscript",
      variables: ["id": .string("sqlite-session"), "query": .string("Hello")],
      context: CodexAgentCompatibilityContext(codexHome: home.path)
    )
    XCTAssertEqual(sqliteOnlyTranscript.errors, [])
    XCTAssertEqual(jsonObject(sqliteOnlyTranscript.data)?["matched"], .bool(false))
    XCTAssertEqual(jsonNumber(jsonObject(sqliteOnlyTranscript.data)?["scannedEvents"]), 0)
  }

  func testSessionIndexPrefersNewestRolloutForDuplicateSessionIds() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let day1 = home.appendingPathComponent("sessions/2025/05/07", isDirectory: true)
    let day2 = home.appendingPathComponent("sessions/2025/05/08", isDirectory: true)
    try FileManager.default.createDirectory(at: day1, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: day2, withIntermediateDirectories: true)

    let sessionId = "duplicate-session"
    let olderRollout = day2.appendingPathComponent("rollout-2025-05-08T10-00-00-\(sessionId).jsonl")
    let newerRollout = day1.appendingPathComponent("rollout-2025-05-07T10-00-00-\(sessionId).jsonl")
    try writeRollout(
      olderRollout,
      id: sessionId,
      cwd: "/tmp/old-project",
      source: "vscode",
      branch: "old",
      message: "older duplicate",
      modifiedAt: "2025-05-08T10:00:00.000Z"
    )
    try writeRollout(
      newerRollout,
      id: sessionId,
      cwd: "/tmp/new-project",
      source: "cli",
      branch: "main",
      message: "newer duplicate",
      modifiedAt: "2025-05-09T10:00:00.000Z"
    )

    let result = listSessions(options: CodexSessionListOptions(codexHome: home.path, sortBy: "updatedAt"))
    XCTAssertEqual(result.total, 1)
    let session = try XCTUnwrap(result.sessions.first)
    XCTAssertEqual(session.rolloutPath, newerRollout.path)
    XCTAssertEqual(session.cwd, "/tmp/new-project")
    XCTAssertEqual(session.source, .cli)
    XCTAssertEqual(findSession(id: sessionId, codexHome: home.path)?.rolloutPath, newerRollout.path)

    let search = try CodexSessionIndex.searchSessions(
      query: "newer duplicate",
      options: CodexSessionListOptions(codexHome: home.path)
    )
    XCTAssertEqual(search.sessionIds, [sessionId])
  }

  func testSessionSearchBudgetCountsReadableTranscriptsOnly() throws {
    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let sessionsDir = home.appendingPathComponent("sessions/2026/02/20", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    let state = home.appendingPathComponent("state")
    try createThreadsDatabase(at: state)
    try insertThread(
      SQLiteThreadFixture(
        id: "sqlite-missing-transcript",
        rolloutPath: home.appendingPathComponent("missing-rollout.jsonl").path,
        createdAt: "2026-02-20T10:00:00Z",
        updatedAt: "2026-02-20T10:20:00Z",
        source: "cli",
        cwd: "/tmp/project",
        title: "Missing rollout",
        firstUserMessage: "unreadable match",
        branch: "main"
      ),
      into: state
    )

    let readableSessionId = "readable-rollout-session"
    let readableRollout = sessionsDir.appendingPathComponent(
      "rollout-2026-02-20T10-10-00-\(readableSessionId).jsonl"
    )
    try writeRollout(
      readableRollout,
      id: readableSessionId,
      cwd: "/tmp/project",
      source: "cli",
      branch: "main",
      message: "readable match",
      modifiedAt: "2026-02-20T10:10:00.000Z"
    )

    let search = try CodexSessionIndex.searchSessions(
      query: "readable match",
      options: CodexSessionListOptions(codexHome: home.path, sortBy: "updatedAt"),
      searchOptions: CodexSessionTranscriptSearchOptions(maxSessions: 1)
    )
    XCTAssertEqual(search.sessionIds, [readableSessionId])
    XCTAssertEqual(search.scannedSessions, 1)
  }

  private func createThreadsDatabase(at state: URL) throws {
    try runSQLite(
      state.path,
      """
      CREATE TABLE threads (
        id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        source TEXT NOT NULL, model_provider TEXT, cwd TEXT NOT NULL, cli_version TEXT NOT NULL, title TEXT,
        first_user_message TEXT, archived_at TEXT, git_sha TEXT, git_branch TEXT, git_origin_url TEXT
      );
      """
    )
  }

  private func insertThread(_ thread: SQLiteThreadFixture, into state: URL) throws {
    try runSQLite(
      state.path,
      """
      INSERT INTO threads VALUES (
        \(sqlLiteral(thread.id)), \(sqlLiteral(thread.rolloutPath)), \(sqlLiteral(thread.createdAt)), \(sqlLiteral(thread.updatedAt)),
        \(sqlLiteral(thread.source)), 'openai', \(sqlLiteral(thread.cwd)), '1.0.0', \(sqlLiteral(thread.title)),
        \(sqlLiteral(thread.firstUserMessage)), NULL, 'abc', \(sqlLiteral(thread.branch)),
        'https://example.test/repo.git'
      );
      """
    )
  }
}

private struct SQLiteThreadFixture {
  var id: String
  var rolloutPath: String
  var createdAt: String
  var updatedAt: String
  var source: String
  var cwd: String
  var title: String
  var firstUserMessage: String
  var branch: String
}

private func sqlLiteral(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}
