import AgentRuntimeKit
import Foundation
import XCTest

final class AgentSessionSQLiteSupportTests: XCTestCase {
  func testOpenThreadsDatabaseAndListThreadRecords() throws {
    guard FileManager.default.isExecutableFile(atPath: sqliteExecutablePath) else {
      throw XCTSkip("sqlite3 is not available")
    }
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("state")
    try runSQLite(
      state.path,
      """
      CREATE TABLE threads (
        id TEXT,
        rollout_path TEXT,
        created_at TEXT,
        updated_at TEXT,
        source TEXT,
        model_provider TEXT,
        cwd TEXT,
        cli_version TEXT,
        title TEXT,
        first_user_message TEXT,
        archived_at TEXT,
        git_sha TEXT,
        git_branch TEXT,
        git_origin_url TEXT
      );
      INSERT INTO threads VALUES (
        'session-1',
        '/tmp/rollout.jsonl',
        '2026-06-17T00:02:00.000Z',
        '2026-06-17T00:03:00Z',
        'cli',
        'openai',
        '/tmp/project',
        '',
        '',
        'hello sqlite',
        '',
        'abc123',
        'main',
        ''
      );
      INSERT INTO threads VALUES (
        'missing-required',
        '',
        '2026-06-17T00:02:00Z',
        '2026-06-17T00:03:00Z',
        'cli',
        '',
        '/tmp/project',
        '1.0.0',
        'ignored',
        '',
        '',
        '',
        '',
        ''
      );
      """
    )

    XCTAssertEqual(AgentSessionSQLiteSupport.openThreadsDatabase(at: state.path), state.path)
    let records = AgentSessionSQLiteSupport.listThreadRecords(
      dbPath: state.path,
      separator: "|||test|||"
    )

    XCTAssertEqual(records.count, 1)
    let record = try XCTUnwrap(records.first)
    XCTAssertEqual(record.id, "session-1")
    XCTAssertEqual(record.rolloutPath, "/tmp/rollout.jsonl")
    XCTAssertEqual(record.source, "cli")
    XCTAssertEqual(record.modelProvider, "openai")
    XCTAssertEqual(record.cwd, "/tmp/project")
    XCTAssertEqual(record.cliVersion, "unknown")
    XCTAssertEqual(record.title, "hello sqlite")
    XCTAssertEqual(record.firstUserMessage, "hello sqlite")
    XCTAssertNil(record.archivedAt)
    XCTAssertEqual(record.git, AgentSessionSQLiteGit(sha: "abc123", branch: "main"))
  }

  private var sqliteExecutablePath: String {
    "/usr/bin/sqlite3"
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ).appendingPathComponent("tmp/agent-runtime-kit-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func runSQLite(_ path: String, _ sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sqliteExecutablePath)
    process.arguments = [path, sql]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
