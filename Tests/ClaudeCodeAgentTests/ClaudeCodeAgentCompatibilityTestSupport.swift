import Foundation
import Dispatch
import XCTest
@testable import ClaudeCodeAgent
@testable import RielaCore

typealias LegacyCoverageProbe = (category: String, probe: () throws -> Void)

func executeGraphQL(command: String, variables: JSONObject = [:], context: ClaudeCodeAgentCompatibilityContext = ClaudeCodeAgentCompatibilityContext()) -> ClaudeCodeGraphQLCommandExecutor.Result {
  ClaudeCodeGraphQLCommandExecutor.execute(command: command, variables: variables, context: context)
}

func legacyClaudeCodeAgentUnitTests() -> Set<String> {
  [
    "src/auth/duration.test.ts", "src/auth/token-manager.test.ts", "src/cli/commands/activity/cleanup.test.ts", "src/cli/commands/activity/list.test.ts", "src/cli/commands/activity/status.test.ts",
    "src/cli/commands/auth/status.test.ts", "src/cli/commands/auth/verify.test.ts", "src/cli/commands/bookmark.test.ts", "src/cli/commands/edge-cases.test.ts", "src/cli/commands/error-handling.test.ts",
    "src/cli/commands/group.test.ts", "src/cli/commands/queue.test.ts", "src/cli/commands/session.test.ts", "src/cli/commands/version.test.ts", "src/cli/graphql.test.ts", "src/cli/main.test.ts",
    "src/cli/output.test.ts", "src/container.test.ts", "src/errors.test.ts", "src/graphql/index.test.ts", "src/lib.test.ts", "src/package-metadata.test.ts", "src/polling/event-parser.test.ts",
    "src/polling/group-monitor.test.ts", "src/polling/monitor.test.ts", "src/polling/output.test.ts", "src/polling/parser.test.ts", "src/polling/state-manager.test.ts", "src/polling/watcher.test.ts",
    "src/repository/file/base-repository.test.ts", "src/repository/file/bookmark-repository.test.ts", "src/repository/file/group-repository.test.ts", "src/repository/file/queue-repository.test.ts",
    "src/repository/in-memory/bookmark-repository.test.ts", "src/repository/in-memory/group-repository.test.ts", "src/repository/in-memory/queue-repository.test.ts",
    "src/repository/in-memory/session-repository.test.ts", "src/result.test.ts", "src/sdk/__fixtures__/mock-receiver.test.ts", "src/sdk/__fixtures__/mock-session.test.ts",
    "src/sdk/__fixtures__/mock-transport.test.ts", "src/sdk/__tests__/exports.test.ts", "src/sdk/__tests__/tool-call.integration.test.ts", "src/sdk/activity/__tests__/integration.test.ts",
    "src/sdk/activity/hook-types.test.ts", "src/sdk/activity/manager.test.ts", "src/sdk/activity/store.test.ts", "src/sdk/activity/transcript-analyzer.test.ts", "src/sdk/agent.test.ts",
    "src/sdk/bookmarks/manager.test.ts", "src/sdk/bookmarks/search.test.ts", "src/sdk/client.test.ts", "src/sdk/control-protocol.test.ts", "src/sdk/credentials/__tests__/integration.test.ts",
    "src/sdk/credentials/__tests__/manager.test.ts", "src/sdk/credentials/__tests__/reader.test.ts", "src/sdk/credentials/__tests__/validation.test.ts", "src/sdk/credentials/__tests__/writer.test.ts",
    "src/sdk/environment.test.ts", "src/sdk/errors.test.ts", "src/sdk/events/emitter.test.ts", "src/sdk/file-changes/extractor.test.ts", "src/sdk/file-changes/index-manager.test.ts",
    "src/sdk/file-changes/service.test.ts", "src/sdk/group/config-generator.test.ts", "src/sdk/group/dependency-graph.test.ts", "src/sdk/group/events.test.ts", "src/sdk/group/manager.test.ts",
    "src/sdk/group/progress.test.ts", "src/sdk/group/runner.test.ts", "src/sdk/group/session-processor.test.ts", "src/sdk/group/types.test.ts", "src/sdk/jsonl-parser.test.ts",
    "src/sdk/markdown-parser/detectors.test.ts", "src/sdk/markdown-parser/parser.test.ts", "src/sdk/mock-session-runner.test.ts", "src/sdk/queue/manager.test.ts", "src/sdk/queue/recovery.test.ts",
    "src/sdk/queue/runner.test.ts", "src/sdk/readiness.test.ts", "src/sdk/receiver.test.ts", "src/sdk/session-reader.test.ts", "src/sdk/session-state.test.ts", "src/sdk/tool-registry.test.ts",
    "src/sdk/tool-versions.test.ts", "src/sdk/transport/subprocess.test.ts", "src/sdk/types/mcp.test.ts", "src/sdk/types/protocol.test.ts", "src/sdk/types/state.test.ts", "src/sdk/types/tool.test.ts",
    "src/services/atomic-writer.test.ts", "src/services/file-lock.test.ts", "src/test/fixtures/fixtures.test.ts", "src/test/helpers.test.ts", "src/test/mocks/clock.test.ts", "src/test/mocks/filesystem.test.ts",
    "src/test/mocks/lock.test.ts", "src/test/mocks/process-manager.test.ts", "src/test/utils/concurrency.test.ts", "src/types/activity.test.ts", "src/types/types.test.ts"
  ]
}

func legacyCoverageCategory(for path: String) -> String {
  let prefixMappings = [
    ("src/auth/", "auth"), ("src/cli/", "cli"), ("src/polling/", "polling"),
    ("src/repository/", "repository"), ("src/sdk/activity/", "sdk-activity"),
    ("src/sdk/bookmarks/", "sdk-bookmarks"), ("src/sdk/credentials/", "sdk-credentials"),
    ("src/sdk/file-changes/", "sdk-file-changes"), ("src/sdk/group/", "sdk-group"),
    ("src/sdk/markdown-parser/", "sdk-markdown-parser"), ("src/sdk/queue/", "sdk-queue"),
    ("src/sdk/types/", "sdk-types"), ("src/sdk/", "sdk"), ("src/services/", "services"), ("src/test/", "test-support"), ("src/types/", "types")
  ]
  if let mapping = prefixMappings.first(where: { path.hasPrefix($0.0) }) {
    return mapping.1
  }
  if path == "src/graphql/index.test.ts" { return "graphql" }
  let coreTests = ["src/container.test.ts", "src/errors.test.ts", "src/lib.test.ts"]
  if (coreTests + ["src/package-metadata.test.ts", "src/result.test.ts"]).contains(path) {
    return "container-and-core"
  }
  return "unmapped"
}

func legacySwiftCoverageProbes() -> [LegacyCoverageProbe] {
  [
    ("auth", {
      XCTAssertEqual(try ClaudeCodeDurationParser.seconds("1d"), 86_400)
      let raw = try ClaudeCodeTokenPersistence.createRawToken(
        name: "probe",
        permissions: ["session:read"],
        configDir: makeTemporaryDirectory().path
      )
      XCTAssertTrue(raw.hasPrefix("cca_"))
    }),
    ("cli", { XCTAssertEqual(ClaudeCodeAgentCLIApplication.run(arguments: ["version", "includeGit=false"]).exitCode, 0) }),
    ("container-and-core", { XCTAssertEqual(ClaudeCodeProcessCommandBuilder.buildExecArguments(prompt: "probe").first, "-p") }),
    ("graphql", { XCTAssertEqual(try ClaudeCodeGraphQLCommandExecutor.parseParams(["limit=2"])["limit"], .number(2)) }),
    ("polling", {
      var parser = ClaudeCodeJsonlStreamParser()
      XCTAssertEqual(parser.feed(#"{"type":"assistant","content":"ok"}"# + "\n").first?.type, "assistant")
    }),
    ("repository", {
      var repository = ClaudeCodeQueueRepository()
      XCTAssertEqual(repository.createQueue(name: "probe").name, "probe")
    }),
    ("sdk", {
      let manager = ClaudeCodeProcessManager(executableName: "claude-probe") { _, _, _ in
        ClaudeCodeProcessExecution(exitCode: 0)
      }
      XCTAssertEqual(manager.spawnExec(prompt: "probe").result.exitCode, 0)
    }),
    ("sdk-activity", { XCTAssertEqual(ClaudeCodeActivityAnalyzer.status(hookEventName: "PermissionRequest"), .waitingUserResponse) }),
    ("sdk-bookmarks", {
      var manager = ClaudeCodeBookmarkManager()
      _ = try manager.create(type: .session, sessionId: "probe", name: "Probe")
      XCTAssertEqual(manager.search(text: "probe").count, 1)
    }),
    ("sdk-credentials", {
      let configPath = ClaudeCodeConfigReader.defaultConfigPath(environment: ["HOME": "/tmp/home"])
      XCTAssertTrue(configPath.hasSuffix("/.claude.json"))
    }),
    ("sdk-file-changes", {
      let change = ClaudeCodeFileChange(path: "Sources/A.swift", operation: .modified, source: .shell)
      let index = ClaudeCodeFileChangeIndex(changes: [change])
      XCTAssertEqual(index.find("Sources/A.swift")?.operation, .modified)
    }),
    ("sdk-group", {
      var groups = ClaudeCodeGroupRepository()
      XCTAssertEqual(groups.createGroup(name: "g").name, "g")
    }),
    ("sdk-markdown-parser", { XCTAssertEqual(ClaudeCodeMarkdown.parseTasks("# Work\n- [x] done").first?.text, "done") }),
    ("sdk-queue", {
      var queues = ClaudeCodeQueueRepository()
      let queue = queues.createQueue(name: "q")
      XCTAssertNotNil(queues.addPrompt(queueId: queue.id, prompt: "p"))
    }),
    ("sdk-types", { XCTAssertEqual(ClaudeCodeActivityStatusValue.working.rawValue, "working") }),
    ("services", {
      let url = try makeTemporaryDirectory().appendingPathComponent("queues.json")
      let store = ClaudeCodeJSONStore<ClaudeCodeQueuesConfig>(url: url)
      try store.save(ClaudeCodeQueuesConfig())
    }),
    ("test-support", { XCTAssertFalse(try makeTemporaryDirectory().path.isEmpty) }),
    ("types", { XCTAssertEqual(ClaudeCodeActivityStatusValue.waitingUserResponse.rawValue, "waiting_user_response") })
  ]
}

func makeTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("riela-claude-agent-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func writeClaudeRollout(home: URL, sessionId: String, cwd: String = "/tmp/project") throws {
  let day = home.appendingPathComponent("sessions/2026/06/17", isDirectory: true)
  try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
  let rollout = day.appendingPathComponent("rollout-2026-06-17T00-00-00-\(sessionId).jsonl")
  let lines = [
    #"{"timestamp":"2026-06-17T00:00:00.000Z","type":"session_meta","# +
      #""payload":{"meta":{"id":"\#(sessionId)","timestamp":"2026-06-17T00:00:00.000Z","# +
      #""cwd":"\#(cwd)","cli_version":"0.1.0","source":"cli","model_provider":"anthropic"}}}"#,
    #"{"timestamp":"2026-06-17T00:00:01.000Z","type":"event_msg","payload":{"type":"UserMessage","message":"hello"}}"#
  ]
  try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
}

func writeClaudeSQLiteState(home: URL, sessionId: String) throws {
  let state = home.appendingPathComponent("state")
  let rollout = home.appendingPathComponent("sqlite-\(sessionId).jsonl")
  try [
    #"{"timestamp":"2026-06-17T00:02:00.000Z","type":"session_meta","# +
      #""payload":{"meta":{"id":"\#(sessionId)","timestamp":"2026-06-17T00:02:00.000Z","# +
      #""cwd":"/tmp/sqlite-project","cli_version":"1.0.0","source":"cli","model_provider":"anthropic"}}}"#,
    #"{"timestamp":"2026-06-17T00:02:01.000Z","type":"event_msg","payload":{"type":"UserMessage","message":"sqlite hello"}}"#
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
    '\(sessionId)',
    '\(rollout.path)',
    '2026-06-17T00:02:00.000Z',
    '2026-06-17T00:03:00.000Z',
    'cli',
    'anthropic',
    '/tmp/sqlite-project',
    '1.0.0',
    'SQLite session',
    'sqlite hello',
    '',
    '',
    '',
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

func writeClaudeCredentials(home: URL, expiresAt: Date) throws {
  let expiresMs = Int(expiresAt.timeIntervalSince1970 * 1000)
  try """
  {
    "claudeAiOauth": {
      "accessToken": "access",
      "refreshToken": "refresh",
      "expiresAt": \(expiresMs),
      "scopes": ["user:inference"],
      "subscriptionType": "pro",
      "rateLimitTier": "standard"
    }
  }
  """.write(to: home.appendingPathComponent(".credentials.json"), atomically: true, encoding: .utf8)
}

func writeLegacyClaudeProjectSession(home: URL, projectPath: String, sessionId: String) throws {
  let encodedProjectPath = projectPath.replacingOccurrences(of: "/", with: "-")
  let projectDir = home.appendingPathComponent("projects/\(encodedProjectPath)", isDirectory: true)
  try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
  let session = projectDir.appendingPathComponent("\(sessionId).jsonl")
  let lines = [
    #"{"type":"summary","timestamp":"2026-06-17T00:00:00.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","version":"1.0.0","summary":"Legacy title"}"#,
    #"{"type":"user","timestamp":"2026-06-17T00:00:01.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","message":{"role":"user","content":"hello legacy"}}"#,
    #"{"type":"assistant","timestamp":"2026-06-17T00:00:02.000Z","sessionId":"\#(sessionId)","cwd":"\#(projectPath)","message":{"role":"assistant","content":[{"type":"text","text":"legacy response"}]}}"#
  ]
  try lines.joined(separator: "\n").write(to: session, atomically: true, encoding: .utf8)
}

func writeLegacyClaudeProjectSessionWithoutCwd(home: URL, encodedProjectPath: String, sessionId: String) throws {
  let projectDir = home.appendingPathComponent("projects/\(encodedProjectPath)", isDirectory: true)
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
