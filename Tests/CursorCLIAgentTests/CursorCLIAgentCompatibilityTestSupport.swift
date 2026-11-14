import Foundation
import Dispatch
import XCTest
@testable import CursorCLIAgent
@testable import RielaCore

func makeTemporaryDirectory() throws -> URL {
  let repoTmp = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
  ).appendingPathComponent("tmp/riela-cursor-agent-tests", isDirectory: true)
  try FileManager.default.createDirectory(at: repoTmp, withIntermediateDirectories: true)
  let url = repoTmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func testDate(_ text: String) throws -> Date {
  try XCTUnwrap(ISO8601DateFormatter().date(from: text))
}

func cursorRolloutLine(_ timestamp: String, _ type: String, _ payload: JSONValue) -> String {
  let object = JSONValue.object([
    "timestamp": .string(timestamp),
    "type": .string(type),
    "payload": payload
  ])
  guard
    let data = try? JSONEncoder().encode(object),
    let string = String(data: data, encoding: .utf8)
  else {
    XCTFail("expected Cursor rollout JSON encoding to succeed")
    return ""
  }
  return string
}

func cursorSessionMetaLine(
  id: String,
  timestamp: String,
  cwd: String,
  cliVersion: String,
  source: String,
  modelProvider: String,
  branch: String? = nil
) -> String {
  var payload: JSONObject = [
    "meta": .object([
      "id": .string(id),
      "timestamp": .string(timestamp),
      "cwd": .string(cwd),
      "cli_version": .string(cliVersion),
      "source": .string(source),
      "model_provider": .string(modelProvider)
    ])
  ]
  if let branch {
    payload["git"] = .object(["branch": .string(branch)])
  }
  return cursorRolloutLine(timestamp, "session_meta", .object(payload))
}

func cursorEventMessageLine(timestamp: String, type: String, message: String) -> String {
  cursorRolloutLine(timestamp, "event_msg", .object(["type": .string(type), "message": .string(message)]))
}

func cursorSQLLiteral(_ value: String) -> String {
  "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

@discardableResult
func writeCursorRollout(
  home: URL,
  sessionId: String,
  cwd: String = "/tmp/project",
  source: String = "cli",
  branch: String? = nil,
  message: String = "hello",
  modifiedAt: String? = nil,
  rolloutFileTimestamp: String = "2026-06-17T00-00-00"
) throws -> URL {
  let day = home.appendingPathComponent("sessions/2026/06/17", isDirectory: true)
  try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
  let rollout = day.appendingPathComponent("rollout-\(rolloutFileTimestamp)-\(sessionId).jsonl")
  let lines = [
    cursorSessionMetaLine(
      id: sessionId,
      timestamp: "2026-06-17T00:00:00.000Z",
      cwd: cwd,
      cliVersion: "0.1.0",
      source: source,
      modelProvider: "anthropic",
      branch: branch
    ),
    cursorEventMessageLine(timestamp: "2026-06-17T00:00:01.000Z", type: "UserMessage", message: message)
  ]
  try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
  if let modifiedAt {
    try FileManager.default.setAttributes(
      [.modificationDate: try testDate(modifiedAt)],
      ofItemAtPath: rollout.path
    )
  }
  return rollout
}

func writeCursorSQLiteState(
  home: URL,
  sessionId: String,
  cwd: String = "/tmp/sqlite-project",
  source: String = "cli",
  branch: String = ""
) throws {
  let state = home.appendingPathComponent("state")
  let rollout = home.appendingPathComponent("sqlite-\(sessionId).jsonl")
  try [
    cursorSessionMetaLine(
      id: sessionId,
      timestamp: "2026-06-17T00:02:00.000Z",
      cwd: cwd,
      cliVersion: "1.0.0",
      source: source,
      modelProvider: "anthropic",
      branch: branch.isEmpty ? nil : branch
    ),
    cursorEventMessageLine(timestamp: "2026-06-17T00:02:01.000Z", type: "UserMessage", message: "sqlite hello")
  ].joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
  let sql = """
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
    \(cursorSQLLiteral(sessionId)),
    \(cursorSQLLiteral(rollout.path)),
    '2026-06-17T00:02:00.000Z',
    '2026-06-17T00:03:00.000Z',
    \(cursorSQLLiteral(source)),
    'anthropic',
    \(cursorSQLLiteral(cwd)),
    '1.0.0',
    'SQLite session',
    'sqlite hello',
    '',
    '',
    \(cursorSQLLiteral(branch)),
    ''
  );
  """
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
  process.arguments = [state.path, sql]
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()
  process.waitUntilExit()
  XCTAssertEqual(process.terminationStatus, 0)
}

func writeCursorCredentials(home: URL, expiresAt: Date) throws {
  let expiresMs = Int(expiresAt.timeIntervalSince1970 * 1000)
  try """
  {
    "cursorOauth": {
      "accessToken": "access",
      "refreshToken": "refresh",
      "expiresAt": \(expiresMs),
      "scopes": ["user:inference"],
      "subscriptionType": "pro",
      "rateLimitTier": "standard"
    }
  }
  """.write(to: home.appendingPathComponent("credentials.json"), atomically: true, encoding: .utf8)
}

func writeLegacyCursorProjectSession(home: URL, projectPath: String, sessionId: String) throws {
  let encodedProjectPath = projectPath.replacingOccurrences(of: "/", with: "-")
  let projectDir = home.appendingPathComponent("projects/\(encodedProjectPath)/agent-transcripts", isDirectory: true)
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let session = projectDir.appendingPathComponent("\(sessionId).jsonl")
  let lines = [
    #"{"type":"summary","timestamp":"2026-06-17T00:00:00.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","version":"1.0.0","summary":"Legacy title"}"#,
    #"{"type":"user","timestamp":"2026-06-17T00:00:01.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","message":{"role":"user","content":"hello legacy"}}"#,
    #"{"type":"assistant","timestamp":"2026-06-17T00:00:02.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","# +
      #""message":{"role":"assistant","content":[{"type":"text","text":"legacy response"}]}}"#
  ]
  try lines.joined(separator: "\n").write(to: session, atomically: true, encoding: .utf8)
}

func writeLegacyCursorProjectSessionWithoutCwd(home: URL, encodedProjectPath: String, sessionId: String) throws {
  let projectDir = home.appendingPathComponent("projects/\(encodedProjectPath)/agent-transcripts", isDirectory: true)
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let session = projectDir.appendingPathComponent("\(sessionId).jsonl")
  let lines = [
    #"{"type":"user","timestamp":"2026-06-17T00:00:01.000Z","sessionId":"\#(sessionId)","message":{"role":"user","content":"relative legacy"}}"#
  ]
  try lines.joined(separator: "\n").write(to: session, atomically: true, encoding: .utf8)
}

func jsonObject(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else {
    return nil
  }
  return object
}

func jsonArray(_ value: JSONValue?) -> [JSONValue]? {
  guard case let .array(array) = value else {
    return nil
  }
  return array
}

func jsonString(_ value: JSONValue?) -> String? {
  guard case let .string(string) = value else {
    return nil
  }
  return string
}

func executeCursorGraphQL(_ command: String, variables: JSONObject = [:], context: CursorCLIAgentCompatibilityContext = CursorCLIAgentCompatibilityContext()) -> CursorCLIGraphQLCommandExecutor.Result {
  CursorCLIGraphQLCommandExecutor.execute(command: command, variables: variables, context: context)
}

func tokenFileContainsLegacyTimestamp(_ text: String, key: String) -> Bool {
  let pattern = #""\#(key)"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z""#
  return text.range(of: pattern, options: .regularExpression) != nil
}

final class LockedErrorCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  func count() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

extension Array where Element == String {
  func containsSubsequence(_ subsequence: [String]) -> Bool {
    guard !subsequence.isEmpty, count >= subsequence.count else {
      return false
    }
    for index in 0...(count - subsequence.count) where Array(self[index..<(index + subsequence.count)]) == subsequence {
      return true
    }
    return false
  }
}

extension CursorCLIAgentCompatibilityTests {
  func testPollingActivityDurationAndCursorConfigReader() throws {
    XCTAssertEqual(try CursorCLIDurationParser.seconds("2h"), 7200)
    XCTAssertThrowsError(try CursorCLIDurationParser.seconds("0d"))

    var parser = CursorCLIJsonlStreamParser()
    XCTAssertEqual(parser.feed(#"{"type":"user","content":"hel"#), [])
    let parsed = parser.feed(#"lo","uuid":"m1"}"# + "\n")
    XCTAssertEqual(parsed.first?.type, "user")
    XCTAssertEqual(parsed.first?.uuid, "m1")
    XCTAssertEqual(parsed.first?.content, "hello")
    XCTAssertEqual(parsed.first?.raw["content"], "hello")
    XCTAssertEqual(parser.feed(#"not-json"# + "\n"), [])

    var eventParser = CursorCLIPollingEventParser(now: { Date(timeIntervalSince1970: 10) })
    XCTAssertEqual(eventParser.map(CursorCLITranscriptEvent(type: "tool_use", uuid: "tool-1", raw: ["name": "Bash"]))?.type, .toolStart)
    var endParser = CursorCLIPollingEventParser(now: { Date(timeIntervalSince1970: 10) })
    _ = endParser.map(CursorCLITranscriptEvent(type: "tool_use", uuid: "tool-1", raw: ["name": "Bash"]))
    XCTAssertEqual(endParser.map(CursorCLITranscriptEvent(type: "tool_result", uuid: "tool-1", content: "done", raw: ["name": "Bash"]))?.type, .toolEnd)

    var nestedParser = CursorCLIJsonlStreamParser()
    let nestedToolUse = nestedParser.feed(#"{"type":"tool_use","timestamp":"2026-06-17T00:00:00Z","content":{"name":"Bash"},"uuid":"nested-1"}"# + "\n")
    let nestedToolResult = nestedParser.feed(#"{"type":"tool_result","timestamp":"2026-06-17T00:00:01Z","content":{"name":"Bash"}}"# + "\n")
    var nestedEventParser = CursorCLIPollingEventParser(now: { Date(timeIntervalSince1970: 0) })
    let start = nestedEventParser.map(try XCTUnwrap(nestedToolUse.first))
    let end = nestedEventParser.map(try XCTUnwrap(nestedToolResult.first))
    XCTAssertEqual(start?.name, "Bash")
    XCTAssertEqual(end?.type, .toolEnd)
    XCTAssertEqual(end?.name, "Bash")
    XCTAssertEqual(end?.durationMs, 1000)

    var states = CursorCLIPollingStateManager()
    states.apply(sessionId: "s1", event: CursorCLIMonitorEvent(type: .message, id: "m1"))
    states.apply(sessionId: "s1", event: CursorCLIMonitorEvent(type: .toolStart, id: "tool-1"))
    XCTAssertEqual(states.state(sessionId: "s1")?.messageCount, 1)
    XCTAssertEqual(states.state(sessionId: "s1")?.activeToolIds, ["tool-1"])

    XCTAssertEqual(CursorCLIActivityAnalyzer.status(hookEventName: "UserPromptSubmit"), .working)
    XCTAssertEqual(CursorCLIActivityAnalyzer.status(hookEventName: "PermissionRequest"), .waitingUserResponse)
    XCTAssertEqual(CursorCLIActivityAnalyzer.status(hookEventName: "Stop", transcriptTail: #"{"name":"AskUserQuestion"}"#), .waitingUserResponse)

    let dataDir = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dataDir) }
    let store = CursorCLIActivityStore(dataDir: dataDir.path)
    try store.save([
      CursorCLIStoredActivityEntry(sessionId: "old", status: .idle, updatedAt: "2020-01-01T00:00:00Z"),
      CursorCLIStoredActivityEntry(sessionId: "new", status: .working, updatedAt: "2026-06-17T00:00:00Z")
    ])
    let retained = try store.cleanup(olderThan: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")))
    XCTAssertEqual(retained.map(\.sessionId), ["new"])

    let home = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let cursorDir = home.appendingPathComponent(".cursor", isDirectory: true)
    try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
    let config = cursorDir.appendingPathComponent("account.json")
    try #"{"oauthAccount":{"accountUuid":"acct","emailAddress":"user@example.test","displayName":"User","organizationUuid":"org","organizationName":"Org","organizationBillingType":"pro","organizationRole":"admin"}}"#
      .write(to: config, atomically: true, encoding: .utf8)
    XCTAssertEqual(try CursorCLIConfigReader.account(environment: ["HOME": home.path])?.organizationName, "Org")
  }

  func testCliApplicationExposesCursorCLIAgentEntryPoint() {
    let result = CursorCLIAgentCLIApplication.run(arguments: ["version", "includeGit=false"])
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("version"))
  }
}
