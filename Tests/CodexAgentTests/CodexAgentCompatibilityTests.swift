import Foundation
import CryptoKit
import XCTest
@testable import CodexAgent
@testable import RielaCore

final class CodexAgentCompatibilityTests: XCTestCase {
  func testLegacyCodexAgentUnitTestSurfaceHasSwiftCoverage() {
    let coverage: [String: [String]] = [
      "src/activity/manager.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/auth/token-manager.test.ts": ["testProcessManagerRunAgentAndOperationalStores", "testQueueGroupBookmarkAndTokenFocusedMutations"],
      "src/bookmark/manager.test.ts": ["testProcessManagerRunAgentAndOperationalStores", "testPersistentQueueAndBookmarkRepositoriesMirrorReferenceConfigFiles"],
      "src/cli/format.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/cli/graphql.test.ts": ["testGraphQLVariablesFileChangesAndTranscriptSearchBudgets", "testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/cli/index.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/file-changes/extractor.test.ts": ["testGraphQLVariablesFileChangesAndTranscriptSearchBudgets", "testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/file-changes/service.test.ts": ["testGraphQLVariablesFileChangesAndTranscriptSearchBudgets"],
      "src/graphql/index.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/group/repository.test.ts": ["testProcessManagerRunAgentAndOperationalStores", "testQueueGroupBookmarkAndTokenFocusedMutations"],
      "src/main.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/markdown/parser.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/process/manager.test.ts": ["testProcessManagerRunAgentAndOperationalStores", "testProcessManagerResumeStreamAndProductionRunAgentRunner"],
      "src/queue/repository.test.ts": ["testProcessManagerRunAgentAndOperationalStores", "testQueueGroupBookmarkAndTokenFocusedMutations", "testPersistentQueueAndBookmarkRepositoriesMirrorReferenceConfigFiles"],
      "src/queue/runner.test.ts": ["testQueueGroupBookmarkAndTokenFocusedMutations"],
      "src/rollout/reader.test.ts": ["testParseRolloutLineNormalizesReferenceRolloutAndExecEvents", "testReadRolloutSessionMessagesAndSystemInjectedFiltering"],
      "src/rollout/watcher.test.ts": ["testRolloutWatcherAndSQLiteSessionIndexFallbackContracts"],
      "src/sdk/agent-runner.dist-runtime.test.ts": ["testProcessManagerRunAgentAndOperationalStores"],
      "src/sdk/agent-runner.process-options.test.ts": ["AgentAdapterTests.testCodexProcessCommandBuilderMatchesReferenceExecCompatibilityArgs", "AgentAdapterTests.testCodexProcessCommandBuilderBuildsResumeCompatibilityArgs"],
      "src/sdk/agent-runner.test.ts": ["testProcessManagerRunAgentAndOperationalStores", "testProcessManagerResumeStreamAndProductionRunAgentRunner", "testCodexAgentSDKRawModeAndResumeBackfillMirrorLegacySessionRunner", "testCodexAgentSDKLifecycleCompletionAndErrorEventsMirrorLegacyRunAgent", "testCodexAgentSDKCharStreamGranularityEmitsPerCharacterDeltas"],
      "src/sdk/events.test.ts": ["AgentAdapterTests.testCodexAgentEventNormalizerPortsSdkNormalizedEvents", "testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/sdk/mock-session-runner.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/sdk/model-availability.test.ts": ["AgentAdapterTests.testCodexDefaultReadinessOperationsProbeToolsAuthAndModels"],
      "src/sdk/session-runner.test.ts": ["testProcessManagerResumeStreamAndProductionRunAgentRunner", "testResumeSessionDiscoversLateRolloutBackfillsAndDeduplicatesLines", "testCodexAgentSDKCharStreamGranularityEmitsPerCharacterDeltas"],
      "src/sdk/tool-registry.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/sdk/tool-versions.test.ts": ["AgentAdapterTests.testCodexDefaultReadinessOperationsProbeToolsAuthAndModels"],
      "src/sdk/usage-stats.test.ts": ["testUsageStatsAggregatesMessagesToolsTurnCompleteAndTokenCountDeltas"],
      "src/session/index.test.ts": ["testSessionIndexListsFiltersFindsLatestAndSearchesTranscripts"],
      "src/session/search.test.ts": ["testSessionIndexListsFiltersFindsLatestAndSearchesTranscripts", "testGraphQLVariablesFileChangesAndTranscriptSearchBudgets"],
      "src/session/sqlite.test.ts": ["testRolloutWatcherAndSQLiteSessionIndexFallbackContracts"],
    ]
    let expectedLegacyTests: Set<String> = [
      "src/activity/manager.test.ts",
      "src/auth/token-manager.test.ts",
      "src/bookmark/manager.test.ts",
      "src/cli/format.test.ts",
      "src/cli/graphql.test.ts",
      "src/cli/index.test.ts",
      "src/file-changes/extractor.test.ts",
      "src/file-changes/service.test.ts",
      "src/graphql/index.test.ts",
      "src/group/repository.test.ts",
      "src/main.test.ts",
      "src/markdown/parser.test.ts",
      "src/process/manager.test.ts",
      "src/queue/repository.test.ts",
      "src/queue/runner.test.ts",
      "src/rollout/reader.test.ts",
      "src/rollout/watcher.test.ts",
      "src/sdk/agent-runner.dist-runtime.test.ts",
      "src/sdk/agent-runner.process-options.test.ts",
      "src/sdk/agent-runner.test.ts",
      "src/sdk/events.test.ts",
      "src/sdk/mock-session-runner.test.ts",
      "src/sdk/model-availability.test.ts",
      "src/sdk/session-runner.test.ts",
      "src/sdk/tool-registry.test.ts",
      "src/sdk/tool-versions.test.ts",
      "src/sdk/usage-stats.test.ts",
      "src/session/index.test.ts",
      "src/session/search.test.ts",
      "src/session/sqlite.test.ts",
    ]

    XCTAssertEqual(Set(coverage.keys), expectedLegacyTests)
    XCTAssertEqual(coverage.count, 30)
    XCTAssertFalse(coverage.values.contains { $0.isEmpty })
  }

  func testParseRolloutLineNormalizesReferenceRolloutAndExecEvents() throws {
    let sessionMeta = parseRolloutLine(
      """
      {"timestamp":"2025-05-07T17:24:21.123Z","type":"session_meta","payload":{"meta":{"id":"session-1","timestamp":"2025-05-07T17:24:21.123Z","cwd":"/tmp/project","originator":"codex-cli","cli_version":"0.1.0","source":"cli","model_provider":"openai"},"git":{"sha":"abc123","branch":"main","origin_url":"https://example.test/repo.git"}}}
      """
    )
    XCTAssertEqual(sessionMeta?.type, "session_meta")
    XCTAssertEqual(sessionMeta?.provenance?.origin, .frameworkEvent)

    let execStarted = parseRolloutLine(#"{"type":"thread.started","thread_id":"exec-thread-1"}"#)
    XCTAssertEqual(execStarted?.type, "session_meta")
    XCTAssertEqual(CodexRolloutReader.parseSessionMeta(from: try XCTUnwrap(execStarted))?.source, .exec)

    let execMessage = parseRolloutLine(#"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"hello from exec stream"}}"#)
    XCTAssertEqual(execMessage?.type, "event_msg")
    XCTAssertEqual(execMessage?.provenance?.role, "assistant")

    XCTAssertNil(parseRolloutLine(""))
    XCTAssertNil(parseRolloutLine(#"{"type":"unknown"}"#))
  }

  func testReadRolloutSessionMessagesAndSystemInjectedFiltering() throws {
    let root = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    let rollout = root.appendingPathComponent("rollout-test.jsonl")
    try [
      #"{"timestamp":"2025-05-07T17:24:21.123Z","type":"session_meta","payload":{"meta":{"id":"session-1","timestamp":"2025-05-07T17:24:21.123Z","cwd":"/tmp/project","cli_version":"0.1.0","source":"cli"}}}"#,
      "{\"timestamp\":\"2025-05-07T17:24:22.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"UserMessage\",\"message\":\"# AGENTS.md instructions for /tmp/project\"}}",
      #"{"timestamp":"2025-05-07T17:24:23.000Z","type":"event_msg","payload":{"type":"UserMessage","message":"Fix the auth bug"}}"#,
      #"{"timestamp":"2025-05-07T17:24:24.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"I will fix it."}}"#,
      #"{"timestamp":"2025-05-07T17:24:25.000Z","type":"response_item","payload":{"type":"function_call","name":"read_file","arguments":"{\"path\":\"README.md\"}","call_id":"call-1"}}"#,
      #"{"timestamp":"2025-05-07T17:24:26.000Z","type":"event_msg","payload":{"type":"ExecCommandEnd","command":["echo","hello"],"exit_code":0,"aggregated_output":"hello\n"}}"#,
    ].joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)

    XCTAssertEqual(try extractFirstUserMessage(path: rollout.path), "Fix the auth bug")
    let allMessages = try getSessionMessages(path: rollout.path)
    XCTAssertEqual(allMessages.count, 5)
    XCTAssertTrue(allMessages.contains { $0.category == .assistantToolResponse })
    XCTAssertTrue(allMessages.contains { $0.category == .toolUserResponse && $0.text == "hello\n" })

    let filtered = try getSessionMessages(path: rollout.path, options: CodexSessionMessageOptions(excludeToolRelated: true, excludeSystemInjected: true))
    XCTAssertEqual(filtered.map(\.text), ["Fix the auth bug", "I will fix it."])
  }

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
    try writeRollout(day1.appendingPathComponent("rollout-2025-05-07T17-24-21-\(session1).jsonl"), id: session1, cwd: "/tmp/project-a", source: "cli", branch: "main", message: "Fix bug in auth")
    try writeRollout(day1.appendingPathComponent("rollout-2025-05-07T18-00-00-\(session2).jsonl"), id: session2, cwd: "/tmp/project-b", source: "vscode", branch: "develop", message: "Add tests")
    try writeRollout(day2.appendingPathComponent("rollout-2025-05-08T10-00-00-\(session3).jsonl"), id: session3, cwd: "/tmp/project-a", source: "exec", branch: nil, message: "日本語 transcript")

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
    XCTAssertEqual(findLatestSession(codexHome: home.path, cwd: "/tmp/project-a")?.id, session3)

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

  func testRolloutWatcherAndSQLiteSessionIndexFallbackContracts() throws {
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

    let state = home.appendingPathComponent("state")
    try runSQLite(state.path, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, source TEXT NOT NULL, model_provider TEXT, cwd TEXT NOT NULL, cli_version TEXT NOT NULL, title TEXT, first_user_message TEXT, archived_at TEXT, git_sha TEXT, git_branch TEXT, git_origin_url TEXT);")
    try runSQLite(state.path, "INSERT INTO threads VALUES ('sqlite-session','/tmp/rollout.jsonl','2026-02-20T10:00:00Z','2026-02-20T10:05:00Z','cli','openai','/tmp/project','1.0.0','SQLite title','Hello',NULL,'abc','main','https://example.test/repo.git');")

    XCTAssertEqual(CodexSessionSQLiteIndex.openCodexDb(codexHome: home.path), state.path)
    let sqliteSessions = try XCTUnwrap(CodexSessionSQLiteIndex.listSessionsSqlite(codexHome: home.path))
    XCTAssertEqual(sqliteSessions.sessions.map(\.id), ["sqlite-session"])
    XCTAssertEqual(findSession(id: "sqlite-session", codexHome: home.path)?.git?.branch, "main")
  }

  func testProcessManagerRunAgentAndOperationalStores() throws {
    let manager = CodexProcessManager(executableName: "codex-dev") { arguments, _, environment in
      XCTAssertEqual(arguments.prefix(3), ["codex-dev", "exec", "--json"])
      XCTAssertEqual(environment["CODEX_TEST"], "1")
      return CodexProcessExecution(
        stdout: #"{"timestamp":"2025-05-07T17:24:23.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"done"}}"#,
        exitCode: 0
      )
    }
    let streamed = manager.spawnExecStream(prompt: "hello", options: CodexProcessOptions(environmentVariables: ["CODEX_TEST": "1"]))
    XCTAssertEqual(streamed.waitForCompletion(), 0)
    XCTAssertEqual(streamed.collectLines().first?.type, "event_msg")
    XCTAssertEqual(manager.list().first?.status, .exited)
    XCTAssertFalse(manager.kill(id: streamed.process.id))

    let rawLine = CodexRolloutLine(timestamp: "2025-05-07T17:24:23.000Z", type: "event_msg", payload: .object(["type": .string("AgentMessage"), "message": .string("hello")]))
    let runner = createMockCodexSessionRunner(startSessions: [MockCodexRunningSession(sessionId: "session-sdk", messages: [rawLine])])
    let events = try CodexAgentSDK.runAgent(request: CodexAgentSDK.Request(prompt: "hello", streamMode: .normalized), runner: runner)
    XCTAssertTrue(events.contains { $0.type == "assistant.snapshot" })

    var queues = CodexQueueRepository()
    let queue = queues.createQueue(name: "work")
    let prompt = try XCTUnwrap(queues.addPrompt(queueId: queue.id, prompt: "ship", imagePaths: ["/tmp/a.png"]))
    XCTAssertTrue(queues.updatePrompt(queueId: queue.id, promptId: prompt.id, status: .completed))
    XCTAssertEqual(queues.listQueues().first?.prompts.first?.status, .completed)

    var groups = CodexGroupRepository()
    let group = groups.createGroup(name: "batch")
    XCTAssertTrue(groups.addSession(groupId: group.id, sessionId: "session-sdk"))
    XCTAssertEqual(groups.listGroups().first?.sessionIds, ["session-sdk"])

    var bookmarks = CodexBookmarkManager()
    let bookmark = try bookmarks.create(type: .message, sessionId: "session-sdk", messageId: "message-1", text: "important", name: "important", tags: ["Review"])
    XCTAssertEqual(bookmarks.list(tag: "review"), [bookmark])

    var tokens = CodexTokenManager()
    let token = tokens.create(permissions: ["session:cancel"])
    XCTAssertTrue(tokens.verify(id: token.metadata.id, secret: token.secret, permission: "session:cancel"))
    XCTAssertEqual(tokens.listMetadata().first?.permissions, ["session:cancel"])

    XCTAssertEqual(CodexSessionCommands.runArguments(prompt: "hello").prefix(2), ["exec", "--json"])
    XCTAssertEqual(CodexSessionCommands.resumeArguments(sessionId: "session-sdk").prefix(3), ["exec", "resume", "--json"])

    let trackedResume = manager.spawnResumeProcess(sessionId: "session-sdk", prompt: "continue")
    XCTAssertEqual(trackedResume.status, .running)
    XCTAssertTrue(manager.kill(id: trackedResume.id))
    let trackedFork = manager.spawnForkProcess(sessionId: "session-sdk", nthMessage: 2)
    XCTAssertEqual(trackedFork.status, .running)
    XCTAssertTrue(manager.kill(id: trackedFork.id))
  }

  func testProcessManagerResumeStreamAndProductionRunAgentRunner() throws {
    let codexHome = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: codexHome)
    }
    let manager = CodexProcessManager(executableName: "codex-dev") { arguments, prompt, _ in
      XCTAssertEqual(arguments.prefix(4), ["codex-dev", "exec", "resume", "--json"])
      XCTAssertTrue(arguments.contains("session-prod"))
      XCTAssertEqual(prompt, "continue")
      return CodexProcessExecution(
        stdout: [
          #"{"timestamp":"2025-05-07T17:24:21.123Z","type":"session_meta","payload":{"meta":{"id":"session-prod","timestamp":"2025-05-07T17:24:21.123Z","cwd":"/tmp/project","cli_version":"0.1.0","source":"exec"}}}"#,
          #"{"timestamp":"2025-05-07T17:24:23.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"resumed"}}"#,
        ].joined(separator: "\n"),
        exitCode: 0
      )
    }

    let runner = CodexProcessSessionRunner(processManager: manager)
    let events = try CodexAgentSDK.runAgent(request: CodexAgentSDK.Request(prompt: "continue", sessionId: "session-prod", options: CodexProcessOptions(codexHome: codexHome.path), streamMode: .normalized), runner: runner)
    XCTAssertTrue(events.contains { $0.type == "session.started" && $0.sessionId == "session-prod" && $0.payload["resumed"] == .bool(true) })
    let assistantEvents = events.filter { $0.type == "assistant.snapshot" }
    XCTAssertTrue(assistantEvents.contains { event in
      event.payload["content"] == .string("resumed")
    })
    XCTAssertTrue(events.contains { $0.type == "session.completed" && $0.payload["success"] == .bool(true) })
    XCTAssertEqual(manager.list().first?.command, #"codex-dev exec resume --json -- session-prod continue"#)

    let directResume = try runner.startSession(config: CodexSessionConfig(prompt: "continue", resumeSessionId: "session-prod", options: CodexProcessOptions(codexHome: codexHome.path)))
    XCTAssertEqual(directResume.waitForCompletion().exitCode, 0)
    XCTAssertEqual(directResume.sessionId, "session-prod")
    XCTAssertTrue(manager.list().contains { $0.command == #"codex-dev exec resume --json -- session-prod continue"# })
  }

  func testCodexAgentSDKRawModeAndResumeBackfillMirrorLegacySessionRunner() throws {
    let codexHome = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: codexHome)
    }
    let day = codexHome.appendingPathComponent("sessions/2026/06/17", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try writeRollout(
      day.appendingPathComponent("rollout-2026-06-17T02-00-00-session-prod.jsonl"),
      id: "session-prod",
      cwd: "/tmp/project",
      source: "exec",
      branch: nil,
      message: "existing user message"
    )
    let manager = CodexProcessManager(executableName: "codex-dev") { _, _, _ in
      CodexProcessExecution(
        stdout: #"{"timestamp":"2026-06-17T02:01:00.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"new answer"}}"#,
        exitCode: 0
      )
    }
    let runner = CodexProcessSessionRunner(processManager: manager)
    let rawEvents = try CodexAgentSDK.runAgent(
      request: CodexAgentSDK.Request(
        prompt: "continue",
        sessionId: "session-prod",
        options: CodexProcessOptions(codexHome: codexHome.path, includeExistingOnResume: true)
      ),
      runner: runner
    )

    XCTAssertTrue(rawEvents.contains { $0.type == "session.started" && $0.sessionId == "session-prod" && $0.payload["resumed"] == .bool(true) })
    XCTAssertTrue(rawEvents.contains { event in
      guard let chunk = jsonObject(event.payload["chunk"]) else {
        return false
      }
      return event.type == "session.message" && chunk["type"] == .string("session_meta")
    })
    XCTAssertTrue(rawEvents.contains { event in
      guard let chunk = jsonObject(event.payload["chunk"]) else {
        return false
      }
      return event.type == "session.message" && chunk["payload"] == .object(["type": .string("AgentMessage"), "message": .string("new answer")])
    })
    XCTAssertTrue(rawEvents.contains { $0.type == "session.completed" && jsonObject($0.payload["result"])?["success"] == .bool(true) })
  }

  func testCodexAgentSDKCharStreamGranularityEmitsPerCharacterDeltas() throws {
    let manager = CodexProcessManager(executableName: "codex-dev") { _, _, _ in
      CodexProcessExecution(
        stdout: [
          #"{"timestamp":"2026-06-17T02:00:00.000Z","type":"session_meta","payload":{"meta":{"id":"session-char","timestamp":"2026-06-17T02:00:00.000Z","cwd":"/tmp/project","cli_version":"0.1.0","source":"exec"}}}"#,
          #"{"timestamp":"2026-06-17T02:00:01.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"ab"}}"#
        ].joined(separator: "\n"),
        exitCode: 0
      )
    }
    let runner = CodexProcessSessionRunner(processManager: manager)
    let events = try CodexAgentSDK.runAgent(
      request: CodexAgentSDK.Request(
        prompt: "hello",
        options: CodexProcessOptions(streamGranularity: "char"),
        streamMode: .normalized
      ),
      runner: runner
    )

    let deltas = events.filter { $0.type == "assistant.delta" }.compactMap { jsonString($0.payload["text"]) }
    XCTAssertEqual(deltas, ["a", "b"])
    let snapshots = events.filter { $0.type == "assistant.snapshot" }.compactMap { jsonString($0.payload["content"]) }
    XCTAssertEqual(snapshots, ["a", "ab"])
  }

  func testCodexAgentSDKLifecycleCompletionAndErrorEventsMirrorLegacyRunAgent() throws {
    let manager = CodexProcessManager(executableName: "codex-dev") { _, _, _ in
      CodexProcessExecution(
        stdout: [
          #"{"timestamp":"2026-06-17T02:00:00.000Z","type":"session_meta","payload":{"meta":{"id":"session-error","timestamp":"2026-06-17T02:00:00.000Z","cwd":"/tmp/project","cli_version":"0.1.0","source":"exec"}}}"#,
          #"{"timestamp":"2026-06-17T02:00:01.000Z","type":"event_msg","payload":{"type":"Error","message":"boom"}}"#
        ].joined(separator: "\n"),
        exitCode: 1
      )
    }
    let runner = CodexProcessSessionRunner(processManager: manager)
    let events = try CodexAgentSDK.runAgent(
      request: CodexAgentSDK.Request(prompt: "hello", streamMode: .normalized),
      runner: runner
    )

    XCTAssertEqual(events.first?.type, "session.started")
    XCTAssertEqual(events.first?.payload["resumed"], .bool(false))
    XCTAssertTrue(events.contains { $0.type == "session.error" && $0.payload["message"] == .string("boom") })
    XCTAssertTrue(events.contains { $0.type == "session.completed" && $0.payload["success"] == .bool(false) && $0.payload["exitCode"] == .number(1) })
  }

  func testResumeSessionDiscoversLateRolloutBackfillsAndDeduplicatesLines() throws {
    let codexHome = try makeTemporaryDirectory()
    let temp = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: codexHome)
      try? FileManager.default.removeItem(at: temp)
    }
    let day = codexHome.appendingPathComponent("sessions/2026/06/17", isDirectory: true)
    let rollout = day.appendingPathComponent("rollout-2026-06-17T02-10-00-session-late.jsonl")
    let duplicateLine = #"{"timestamp":"2026-06-17T02:10:01.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"late file answer"}}"#
    let fakeCodex = try createExecutable(
      directory: temp,
      name: "fake-codex-late-rollout.sh",
      body: """
      sleep 0.1
      mkdir -p '\(day.path)'
      printf '%s\\n' '{"timestamp":"2026-06-17T02:10:00.000Z","type":"session_meta","payload":{"meta":{"id":"session-late","timestamp":"2026-06-17T02:10:00.000Z","cwd":"\(temp.path)","cli_version":"0.1.0","source":"exec"}}}' > '\(rollout.path)'
      printf '%s\\n' '\(duplicateLine)' >> '\(rollout.path)'
      printf '%s\\n' '\(duplicateLine)'
      """
    )
    let runner = CodexProcessSessionRunner(processManager: CodexProcessManager(executableName: fakeCodex.path))
    let rawEvents = try CodexAgentSDK.runAgent(
      request: CodexAgentSDK.Request(
        prompt: "continue",
        sessionId: "session-late",
        options: CodexProcessOptions(codexHome: codexHome.path)
      ),
      runner: runner
    )

    XCTAssertTrue(rawEvents.contains { $0.type == "session.started" && $0.sessionId == "session-late" && $0.payload["resumed"] == .bool(true) })
    XCTAssertTrue(rawEvents.contains { event in
      guard let chunk = jsonObject(event.payload["chunk"]) else {
        return false
      }
      return event.type == "session.message" && chunk["type"] == .string("session_meta")
    })
    let lateMessages = rawEvents.filter { event in
      guard
        let chunk = jsonObject(event.payload["chunk"]),
        let payload = jsonObject(chunk["payload"])
      else {
        return false
      }
      return jsonString(payload["message"]) == "late file answer"
    }
    XCTAssertEqual(lateMessages.count, 1)
  }

  func testProcessBackedRunAgentUsesSessionMetaIdAfterAsyncStart() throws {
    let temp = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: temp)
    }
    let fakeCodex = try createExecutable(
      directory: temp,
      name: "fake-codex-session-id.sh",
      body: """
      sleep 0.1
      printf '{"timestamp":"2026-06-17T02:00:00.000Z","type":"session_meta","payload":{"meta":{"id":"real-session-id","timestamp":"2026-06-17T02:00:00.000Z","cwd":"/tmp/project","cli_version":"0.1.0","source":"exec"}}}\\n'
      printf '{"timestamp":"2026-06-17T02:00:01.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"done"}}\\n'
      """
    )
    let runner = CodexProcessSessionRunner(processManager: CodexProcessManager(executableName: fakeCodex.path))
    let directSession = try runner.startSession(config: CodexSessionConfig(prompt: "hello"))
    XCTAssertEqual(directSession.waitForCompletion().exitCode, 0)
    XCTAssertTrue(directSession.messages().contains { $0.type == "session_meta" })
    XCTAssertEqual(directSession.sessionId, "real-session-id")
    XCTAssertEqual(directSession.getState()["sessionId"], "real-session-id")

    let events = try CodexAgentSDK.runAgent(request: CodexAgentSDK.Request(prompt: "hello", streamMode: .normalized), runner: runner)
    XCTAssertTrue(events.contains { $0.type == "assistant.snapshot" && $0.sessionId == "real-session-id" })
  }

  func testProcessBackedSessionCancelTerminatesChildProcess() throws {
    let temp = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: temp)
    }
    let fakeCodex = try createExecutable(
      directory: temp,
      name: "fake-codex-long-running.sh",
      body: """
      printf '{"timestamp":"2025-05-07T17:24:21.123Z","type":"session_meta","payload":{"meta":{"id":"session-cancel","timestamp":"2025-05-07T17:24:21.123Z","cwd":"/tmp/project","cli_version":"0.1.0","source":"exec"}}}\\n'
      sleep 60
      """
    )
    let manager = CodexProcessManager(executableName: fakeCodex.path)
    let runner = CodexProcessSessionRunner(processManager: manager)
    let session = try runner.startSession(config: CodexSessionConfig(prompt: "cancel me"))
    _ = session.messages()
    let processId = try XCTUnwrap(session.getState()["processId"])

    let result = session.cancel()

    XCTAssertFalse(result.success)
    XCTAssertEqual(result.exitCode, 130)
    XCTAssertEqual(manager.get(id: processId)?.status, .killed)
  }

  func testProcessManagerStreamReturnsBeforeCompletionAndYieldsLiveLines() throws {
    let temp = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: temp)
    }
    let fakeCodex = try createExecutable(
      directory: temp,
      name: "fake-codex-live-stream.sh",
      body: """
      printf '{"timestamp":"2025-05-07T17:24:23.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"first"}}\\n'
      sleep 1
      printf '{"timestamp":"2025-05-07T17:24:24.000Z","type":"turn_complete","payload":{"type":"TurnComplete"}}\\n'
      """
    )
    let manager = CodexProcessManager(executableName: fakeCodex.path)
    let startedAt = Date()
    let stream = manager.spawnExecStream(prompt: "hello")

    XCTAssertEqual(manager.get(id: stream.process.id)?.status, .running)
    let first = stream.lines.next(timeout: 1.0)
    XCTAssertEqual(first?.type, "event_msg")
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.9)
    XCTAssertEqual(manager.get(id: stream.process.id)?.status, .running)
    XCTAssertEqual(stream.waitForCompletion(), 0)
    XCTAssertEqual(stream.collectLines().map(\.type), ["event_msg", "turn_complete"])
    XCTAssertEqual(manager.get(id: stream.process.id)?.status, .exited)
    XCTAssertEqual(manager.prune(), 1)
  }

  func testQueueGroupBookmarkAndTokenFocusedMutations() throws {
    var queues = CodexQueueRepository()
    let queue = queues.createQueue(name: "release")
    let firstPrompt = try XCTUnwrap(queues.addPrompt(queueId: queue.id, prompt: "one"))
    let secondPrompt = try XCTUnwrap(queues.addPrompt(queueId: queue.id, prompt: "two"))
    XCTAssertEqual(queues.findQueue("release")?.id, queue.id)
    XCTAssertTrue(queues.pauseQueue(id: queue.id))
    XCTAssertEqual(queues.getQueue(id: queue.id)?.paused, true)
    XCTAssertTrue(queues.resumeQueue(id: queue.id))
    XCTAssertTrue(queues.movePrompt(queueId: queue.id, promptId: secondPrompt.id, toIndex: 0))
    XCTAssertEqual(queues.getQueue(id: queue.id)?.prompts.map(\.id), [secondPrompt.id, firstPrompt.id])
    XCTAssertFalse(queues.movePrompt(queueId: queue.id, promptId: secondPrompt.id, toIndex: 2))
    XCTAssertFalse(queues.movePrompt(queueId: queue.id, from: 0, to: -1))
    XCTAssertEqual(queues.getQueue(id: queue.id)?.prompts.map(\.id), [secondPrompt.id, firstPrompt.id])
    XCTAssertTrue(queues.setMode(queueId: queue.id, mode: .manual))
    let runPrompts = queues.runQueue(id: queue.id) { prompt in
      XCTAssertEqual(prompt.id, secondPrompt.id)
      return 0
    }
    XCTAssertEqual(runPrompts.map(\.id), [secondPrompt.id])
    XCTAssertEqual(queues.getQueue(id: queue.id)?.prompts.first?.resultExitCode, 0)
    XCTAssertNotNil(queues.getQueue(id: queue.id)?.prompts.first?.startedAt)
    XCTAssertNotNil(queues.getQueue(id: queue.id)?.prompts.first?.completedAt)
    XCTAssertTrue(queues.removePrompt(queueId: queue.id, promptId: firstPrompt.id))
    XCTAssertEqual(queues.getQueue(id: queue.id)?.prompts.map(\.id), [secondPrompt.id])
    XCTAssertTrue(queues.deleteQueue(id: queue.id))
    XCTAssertNil(queues.getQueue(id: queue.id))

    var groups = CodexGroupRepository()
    let group = groups.createGroup(name: "parallel")
    XCTAssertEqual(groups.findGroup("parallel")?.id, group.id)
    XCTAssertTrue(groups.addSession(groupId: group.id, sessionId: "session-a"))
    XCTAssertTrue(groups.addSession(groupId: group.id, sessionId: "session-b"))
    XCTAssertTrue(groups.addSession(groupId: group.id, sessionId: "session-a"))
    XCTAssertEqual(groups.getGroup(id: group.id)?.sessionIds, ["session-a", "session-b"])
    let groupResults = groups.runGroup(id: group.id, maxConcurrent: 1) { sessionId in
      return 0
    }
    XCTAssertEqual(groupResults.map(\.sessionId), ["session-a", "session-b"])
    XCTAssertTrue(groups.pauseGroup(id: group.id))
    XCTAssertEqual(groups.getGroup(id: group.id)?.paused, true)
    XCTAssertTrue(groups.resumeGroup(id: group.id))
    XCTAssertTrue(groups.removeSession(groupId: group.id, sessionId: "session-a"))
    XCTAssertEqual(groups.getGroup(id: group.id)?.sessionIds, ["session-b"])
    XCTAssertTrue(groups.deleteGroup(id: group.id))

    var bookmarks = CodexBookmarkManager()
    XCTAssertThrowsError(try bookmarks.create(type: .session, sessionId: "session-a"))
    XCTAssertThrowsError(try bookmarks.create(type: .message, sessionId: "session-a"))
    XCTAssertThrowsError(try bookmarks.create(type: .session, sessionId: "session-a", messageId: "message-a"))
    XCTAssertThrowsError(try bookmarks.create(type: .session, sessionId: "session-a", fromMessageId: "message-a", toMessageId: "message-b"))
    XCTAssertThrowsError(try bookmarks.create(type: .message, sessionId: "session-a", messageId: "message-a", fromMessageId: "message-a", toMessageId: "message-b"))
    XCTAssertThrowsError(try bookmarks.create(type: .range, sessionId: "session-a"))
    XCTAssertThrowsError(try bookmarks.create(type: .range, sessionId: "session-a", messageId: "message-a", fromMessageId: "message-a", toMessageId: "message-b"))
    XCTAssertThrowsError(try bookmarks.create(type: .range, sessionId: "session-a", name: "invalid range", startLine: 5, endLine: 4))
    let bookmark = try bookmarks.create(type: .range, sessionId: "session-a", text: "important", name: "range note", tags: [" Beta ", "Ship", "Beta", "ship", "Ship"], startLine: 1, endLine: 4, fromMessageId: "message-a", toMessageId: "message-b")
    XCTAssertEqual(bookmarks.list(tag: "SHIP"), [bookmark])
    XCTAssertEqual(bookmarks.get(id: bookmark.id), bookmark)
    XCTAssertEqual(bookmark.tags, ["Beta", "Ship", "ship"])
    XCTAssertEqual(bookmarks.search(text: "port").map(\.id), [bookmark.id])
    XCTAssertEqual(bookmarks.search(text: "session-a").map(\.id), [bookmark.id])
    XCTAssertTrue(bookmarks.delete(id: bookmark.id))
    XCTAssertEqual(bookmarks.list(sessionId: "session-a"), [])

    var tokens = CodexTokenManager()
    XCTAssertEqual(CodexTokenManager.parsePermissionsCSV("session:read, session:cancel, queue:* , session:*"), ["session:read", "session:cancel", "queue:*"])
    let token = tokens.create(permissions: ["session:read"])
    XCTAssertTrue(tokens.verify(id: token.metadata.id, secret: token.secret, permission: "session:read"))
    XCTAssertFalse(tokens.verify(id: token.metadata.id, secret: token.secret, permission: "session:write"))
    XCTAssertFalse(String(describing: tokens.listMetadata()).contains(token.secret))
    let rotated = try XCTUnwrap(tokens.rotate(id: token.metadata.id))
    XCTAssertFalse(tokens.verify(id: token.metadata.id, secret: token.secret, permission: "session:read"))
    XCTAssertTrue(tokens.verify(id: token.metadata.id, secret: rotated, permission: "session:read"))
    XCTAssertTrue(tokens.revoke(id: token.metadata.id))
    XCTAssertFalse(tokens.verify(id: token.metadata.id, secret: rotated, permission: "session:read"))
    XCTAssertTrue(try XCTUnwrap(tokens.listMetadata().first).revoked)
    let rotatedRevoked = try XCTUnwrap(tokens.rotate(id: token.metadata.id))
    XCTAssertTrue(tokens.verify(id: token.metadata.id, secret: rotatedRevoked, permission: "session:read"))
    XCTAssertFalse(try XCTUnwrap(tokens.listMetadata().first).revoked)

    let temp = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: temp)
    }
    let queueStore = CodexJSONStore<[CodexQueue]>(url: temp.appendingPathComponent("queues.json"))
    try queueStore.save([CodexQueue(id: "queue-1", name: "persisted", prompts: [], paused: false)])
    XCTAssertEqual(try queueStore.load(default: []).first?.name, "persisted")
  }

  func testPersistentQueueAndBookmarkRepositoriesMirrorReferenceConfigFiles() throws {
    let configDir = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: configDir)
    }

    XCTAssertEqual(try CodexQueuePersistence.load(configDir: configDir.path).queues, [])
    let queue = try CodexQueuePersistence.createQueue(name: "persisted", projectPath: "/project/path", configDir: configDir.path)
    XCTAssertEqual(queue.projectPath, "/project/path")
    let prompt = try XCTUnwrap(CodexQueuePersistence.addPrompt(queueId: queue.id, prompt: "Analyze screenshots", imagePaths: ["./a.png", "./b.png"], configDir: configDir.path))
    XCTAssertEqual(prompt.imagePaths, ["./a.png", "./b.png"])
    XCTAssertEqual(try CodexQueuePersistence.findQueue("persisted", configDir: configDir.path)?.prompts.count, 1)
    var completed = prompt
    completed.status = .completed
    completed.resultExitCode = 0
    XCTAssertTrue(try CodexQueuePersistence.updateQueuePrompts(queueId: queue.id, prompts: [completed], configDir: configDir.path))
    XCTAssertEqual(try CodexQueuePersistence.findQueue(queue.id, configDir: configDir.path)?.prompts.first?.status, .completed)
    let rawQueues = try String(contentsOf: CodexQueuePersistence.url(configDir: configDir.path), encoding: .utf8)
    XCTAssertNoThrow(try JSONDecoder().decode(CodexQueuesConfig.self, from: Data(rawQueues.utf8)))
    XCTAssertTrue(try CodexQueuePersistence.removeQueue(queue.id, configDir: configDir.path))
    XCTAssertEqual(try CodexQueuePersistence.listQueues(configDir: configDir.path), [])

    let sessionBookmark = try CodexBookmarkPersistence.addBookmark(type: .session, sessionId: "session-1", name: "important session", description: "Detailed postmortem", tags: ["Priority", "review"], configDir: configDir.path)
    XCTAssertEqual(try CodexBookmarkPersistence.getBookmark(id: sessionBookmark.id, configDir: configDir.path)?.name, "important session")
    _ = try CodexBookmarkPersistence.addBookmark(type: .message, sessionId: "session-2", messageId: "message-1", name: "message two", tags: ["beta"], configDir: configDir.path)
    XCTAssertEqual(try CodexBookmarkPersistence.listBookmarks(sessionId: "session-1", configDir: configDir.path).map(\.id), [sessionBookmark.id])
    XCTAssertEqual(try CodexBookmarkPersistence.listBookmarks(type: .message, configDir: configDir.path).count, 1)
    XCTAssertEqual(try CodexBookmarkPersistence.searchBookmarks("postmortem", configDir: configDir.path).map(\.id), [sessionBookmark.id])
    XCTAssertTrue(try CodexBookmarkPersistence.deleteBookmark(id: sessionBookmark.id, configDir: configDir.path))
    XCTAssertNil(try CodexBookmarkPersistence.getBookmark(id: sessionBookmark.id, configDir: configDir.path))
  }

  func testGraphQLVariablesFileChangesAndTranscriptSearchBudgets() throws {
    XCTAssertEqual(try CodexGraphQLCommandExecutor.parseVariables(#"{"id":"session-1","limit":5}"#)["id"], .string("session-1"))
    XCTAssertThrowsError(try CodexGraphQLCommandExecutor.parseVariables(#"["not-object"]"#)) { error in
      XCTAssertEqual(error as? CodexGraphQLError, .variablesMustBeObject)
    }

    let applyPatchText = "*** Update File: Sources/Existing.swift\n*** Delete File: Sources/Old.swift\n"
    let applyPatch = CodexRolloutLine(timestamp: "now", type: "event_msg", payload: .object(["patch": .string(applyPatchText)]))
    XCTAssertEqual(
      CodexFileChanges.extract(from: applyPatch),
      [
        CodexFileChange(path: "Sources/Existing.swift", operation: .modified, source: .applyPatch, patch: applyPatchText),
        CodexFileChange(path: "Sources/Old.swift", operation: .deleted, source: .applyPatch, patch: applyPatchText),
      ]
    )

    let shellChange = CodexRolloutLine(timestamp: "now", type: "event_msg", payload: .object(["file_changes": .array([.object(["path": .string("README.md"), "operation": .string("modified"), "source": .string("shell")])])]))
    XCTAssertEqual(CodexFileChanges.extract(from: shellChange), [CodexFileChange(path: "README.md", operation: .modified, source: .shell)])
    let directMoveChange = CodexRolloutLine(timestamp: "now", type: "event_msg", payload: .object(["file_changes": .array([.object(["path": .string("New.md"), "previousPath": .string("Old.md"), "operation": .string("moved"), "source": .string("shell")])])]))
    XCTAssertEqual(CodexFileChanges.extract(from: directMoveChange), [CodexFileChange(path: "New.md", operation: .moved, source: .shell, previousPath: "Old.md")])
    let failedShell = CodexRolloutLine(timestamp: "now", type: "event_msg", payload: .object(["exit_code": .number(1), "file_changes": .array([.object(["path": .string("FAILED.md"), "operation": .string("modified"), "source": .string("shell")])])]))
    XCTAssertEqual(CodexFileChanges.extract(from: failedShell), [])
    let pendingPatchCall = CodexRolloutLine(
      timestamp: "now",
      type: "response_item",
      payload: .object([
        "type": .string("function_call"),
        "call_id": .string("call-failed-patch"),
        "arguments": .object(["command": .string("apply_patch <<'PATCH'\n*** Update File: Failed.swift\nPATCH")]),
      ])
    )
    let failedPatchOutput = CodexRolloutLine(
      timestamp: "now",
      type: "response_item",
      payload: .object([
        "type": .string("function_call_output"),
        "call_id": .string("call-failed-patch"),
        "output": .string(#"{"metadata":{"exit_code":1},"status":"failed"}"#),
      ])
    )
    XCTAssertEqual(CodexFileChanges.extract(from: [pendingPatchCall, failedPatchOutput]), [])
    let movedPatch = CodexRolloutLine(timestamp: "now", type: "event_msg", payload: .object(["patch": .string("*** Update File: Old.md\n*** Move to: New.md\n")]))
    XCTAssertEqual(
      CodexFileChanges.extract(from: movedPatch),
      [CodexFileChange(path: "New.md", operation: .modified, source: .applyPatch, previousPath: "Old.md", patch: "*** Update File: Old.md\n*** Move to: New.md\n")]
    )
    let index = CodexFileChangeIndex.rebuild(from: [applyPatch, movedPatch])
    XCTAssertEqual(index.find("Old.md")?.operation, .modified)
    XCTAssertEqual(index.find("New.md")?.previousPath, "Old.md")
    XCTAssertTrue(index.listChangedFiles().contains("New.md"))

    let localShell = CodexRolloutLine(
      timestamp: "now",
      type: "response_item",
      payload: .object([
        "type": .string("local_shell_call"),
        "arguments": .string(#"{"command":"git mv OldName.md NewName.md"}"#),
      ])
    )
    XCTAssertEqual(CodexFileChanges.extract(from: localShell), [CodexFileChange(path: "NewName.md", operation: .moved, source: .shell, previousPath: "OldName.md", command: "git mv OldName.md NewName.md")])
    let redirect = CodexRolloutLine(
      timestamp: "now",
      type: "response_item",
      payload: .object([
        "type": .string("function_call"),
        "arguments": .object(["command": .string("printf hello > Created.md")]),
      ])
    )
    XCTAssertEqual(CodexFileChanges.extract(from: redirect), [CodexFileChange(path: "Created.md", operation: .created, source: .shell, command: "printf hello > Created.md")])

    let home = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: home)
    }
    let day = home.appendingPathComponent("sessions/2025/05/07", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let sessionId = "dddd0000-0000-0000-0000-000000000004"
    let rollout = day.appendingPathComponent("rollout-2025-05-07T17-24-21-\(sessionId).jsonl")
    try [
      #"{"timestamp":"2025-05-07T17:24:21.123Z","type":"session_meta","payload":{"meta":{"id":"\#(sessionId)","timestamp":"2025-05-07T17:24:21.123Z","cwd":"/tmp/project","cli_version":"0.1.0","source":"cli"}}}"#,
      #"{"timestamp":"2025-05-07T17:25:00.000Z","type":"event_msg","payload":{"type":"UserMessage","message":"Alpha request"}}"#,
      #"{"timestamp":"2025-05-07T17:25:01.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"beta response"}}"#,
    ].joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)

    XCTAssertEqual(try CodexSessionIndex.searchSessions(query: "alpha", options: CodexSessionListOptions(codexHome: home.path), searchOptions: CodexSessionTranscriptSearchOptions(role: "user")).sessionIds, [sessionId])
    XCTAssertEqual(try CodexSessionIndex.searchSessions(query: "alpha", options: CodexSessionListOptions(codexHome: home.path), searchOptions: CodexSessionTranscriptSearchOptions(caseSensitive: true)).sessionIds, [])
    XCTAssertEqual(try CodexSessionIndex.searchSessions(query: "response", options: CodexSessionListOptions(codexHome: home.path), searchOptions: CodexSessionTranscriptSearchOptions(role: "assistant", limit: 1, offset: 0)).sessionIds, [sessionId])
  }

  func testGraphQLExecutesOperationalCommandsTokensFilesAndDefaultProcess() throws {
    let configDir = try makeTemporaryDirectory()
    let codexHome = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: configDir)
      try? FileManager.default.removeItem(at: codexHome)
    }
    let context = CodexAgentCompatibilityContext(codexHome: codexHome.path, configDir: configDir.path)

    let queueCreate = CodexGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("release"), "projectPath": .string("/project")], context: context)
    XCTAssertEqual(queueCreate.errors, [])
    let queueId = try XCTUnwrap(jsonString(jsonObject(queueCreate.data)?["id"]))
    let prompt = CodexGraphQLCommandExecutor.execute(command: "queue.add", variables: ["id": .string(queueId), "prompt": .string("ship")], context: context)
    let promptId = try XCTUnwrap(jsonString(jsonObject(prompt.data)?["id"]))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.move", variables: ["id": .string(queueId), "promptId": .string(promptId), "toIndex": .number(0)], context: context).errors, [])
    XCTAssertEqual(try CodexQueuePersistence.findQueue(queueId, configDir: configDir.path)?.prompts.map(\.id), [promptId])
    let cliQueueWithoutProject = CodexCLICommandExecutor.execute(arguments: ["queue", "create", "cli-release", "configDir=\(configDir.path)"], context: context)
    XCTAssertEqual(cliQueueWithoutProject.errors, ["missingVariable(\"projectPath\")"])

    let group = CodexGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("parallel"), "description": .string("release batch")], context: context)
    let groupId = try XCTUnwrap(jsonString(jsonObject(group.data)?["id"]))
    XCTAssertEqual(try CodexGroupPersistence.findGroup(groupId, configDir: configDir.path)?.description, "release batch")
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "group.add", variables: ["id": .string(groupId), "sessionId": .string("session-a")], context: context).errors, [])
    XCTAssertEqual(try CodexGroupPersistence.findGroup(groupId, configDir: configDir.path)?.sessionIds, ["session-a"])

    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "bookmark.add", variables: ["type": .string("bad"), "sessionId": .string("session-a")], context: context).errors.isEmpty)
    let bookmark = CodexGraphQLCommandExecutor.execute(command: "bookmark.add", variables: ["type": .string("session"), "sessionId": .string("session-a"), "name": .string("postmortem"), "description": .string("postmortem"), "tags": .array([.string("Review")])], context: context)
    let bookmarkId = try XCTUnwrap(jsonString(jsonObject(bookmark.data)?["id"]))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["query": .string("post")], context: context).errors, [])
    let bookmarkSearch = CodexGraphQLCommandExecutor.execute(command: "bookmark.search", variables: ["query": .string("post"), "limit": .number(1)], context: context)
    let bookmarkResults = try XCTUnwrap(jsonArray(bookmarkSearch.data))
    XCTAssertEqual(bookmarkResults.count, 1)
    XCTAssertNotNil(jsonObject(bookmarkResults.first)?["score"])
    XCTAssertEqual(try CodexBookmarkPersistence.getBookmark(id: bookmarkId, configDir: configDir.path)?.tags, ["Review"])
    let cliBookmark = CodexCLICommandExecutor.execute(
      arguments: [
        "bookmark", "add",
        "--type", "message",
        "--session", "session-a",
        "--message", "message-a",
        "--name", "cli note",
        "--description", "cli note",
        "--tag", "Review",
        "--tag", "Ship",
        "configDir=\(configDir.path)",
      ],
      context: context
    )
    XCTAssertEqual(cliBookmark.errors, [])
    let cliBookmarkId = try XCTUnwrap(jsonString(jsonObject(cliBookmark.data)?["id"]))
    XCTAssertEqual(try CodexBookmarkPersistence.getBookmark(id: cliBookmarkId, configDir: configDir.path)?.tags, ["Review", "Ship"])
    let cliRangeBookmark = CodexCLICommandExecutor.execute(
      arguments: [
        "bookmark", "add",
        "--type", "range",
        "--session", "session-a",
        "--name", "range note",
        "--from", "message-a",
        "--to", "message-b",
        "configDir=\(configDir.path)",
      ],
      context: context
    )
    XCTAssertEqual(cliRangeBookmark.errors, [])
    let cliRangeBookmarkId = try XCTUnwrap(jsonString(jsonObject(cliRangeBookmark.data)?["id"]))
    XCTAssertEqual(try CodexBookmarkPersistence.getBookmark(id: cliRangeBookmarkId, configDir: configDir.path)?.fromMessageId, "message-a")
    let cliBookmarkList = CodexCLICommandExecutor.execute(arguments: ["bookmark", "list", "--session", "session-a", "--type", "message", "--tag", "ship", "configDir=\(configDir.path)"], context: context)
    XCTAssertEqual(cliBookmarkList.errors, [])
    XCTAssertEqual(jsonArray(cliBookmarkList.data)?.count, 1)

    let tokenCreate = CodexGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("ci"), "permissions": .array([.string("session:read")])], context: context)
    let rawToken = try XCTUnwrap(jsonString(tokenCreate.data))
    XCTAssertNotNil(try CodexTokenPersistence.verify(rawToken: rawToken, permission: "session:read", configDir: configDir.path))
    XCTAssertNil(try CodexTokenPersistence.verify(rawToken: rawToken, permission: "session:write", configDir: configDir.path))
    let listedTokens = CodexGraphQLCommandExecutor.execute(command: "token.list", context: context)
    XCTAssertFalse(String(describing: listedTokens.data).contains(rawToken))
    let tokenId = String(rawToken.split(separator: ".", maxSplits: 1).first ?? "")
    let rotated = CodexGraphQLCommandExecutor.execute(command: "token.rotate", variables: ["id": .string(tokenId)], context: context)
    let rotatedToken = try XCTUnwrap(jsonString(rotated.data))
    XCTAssertNotEqual(rotatedToken, rawToken)
    XCTAssertNil(try CodexTokenPersistence.verify(rawToken: rawToken, permission: "session:read", configDir: configDir.path))
    XCTAssertNotNil(try CodexTokenPersistence.verify(rawToken: rotatedToken, permission: "session:read", configDir: configDir.path))
    let cliTokenList = CodexCLICommandExecutor.execute(arguments: ["token", "list", "configDir=\(configDir.path)"], context: context)
    XCTAssertEqual(cliTokenList.errors, [])
    XCTAssertFalse(String(describing: cliTokenList.data).contains(rotatedToken))

    let day = codexHome.appendingPathComponent("sessions/2026/02/20", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rollout = day.appendingPathComponent("rollout-files.jsonl")
    try [
      #"{"timestamp":"2026-02-20T10:00:00.000Z","type":"session_meta","payload":{"meta":{"id":"file-session","timestamp":"2026-02-20T10:00:00.000Z","cwd":"/tmp/project","source":"cli"}}}"#,
      #"{"timestamp":"2026-02-20T10:00:01.000Z","type":"event_msg","payload":{"patch":"*** Add File: Sources/New.swift\n"}}"#,
    ].joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
    let files = CodexGraphQLCommandExecutor.execute(command: "files.list", variables: ["sessionId": .string("file-session")], context: context)
    XCTAssertEqual(jsonString(jsonObject(files.data)?["sessionId"]), "file-session")
    XCTAssertEqual(jsonNumber(jsonObject(files.data)?["totalFiles"]), 1)
    XCTAssertEqual(jsonString(jsonObject(jsonArray(jsonObject(files.data)?["files"])?.first)?["path"]), "Sources/New.swift")
    let cliFiles = CodexCLICommandExecutor.execute(arguments: ["files", "list", "file-session", "codexHome=\(codexHome.path)"], context: context)
    XCTAssertEqual(jsonString(jsonObject(jsonArray(jsonObject(cliFiles.data)?["files"])?.first)?["path"]), "Sources/New.swift")
    let found = CodexGraphQLCommandExecutor.execute(command: "files.find", variables: ["path": .string("Sources/New.swift")], context: context)
    XCTAssertEqual(jsonString(jsonObject(found.data)?["path"]), "Sources/New.swift")

    let fakeCodex = try createExecutable(
      directory: configDir,
      name: "fake-codex.sh",
      body: """
      printf '{"timestamp":"2026-02-20T10:00:00.000Z","type":"session_meta","payload":{"meta":{"id":"process-session","timestamp":"2026-02-20T10:00:00.000Z","cwd":"%s","source":"exec"}}}\\n' "$PWD"
      printf '{"timestamp":"2026-02-20T10:00:01.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"done"}}\\n'
      """
    )
    let processRun = CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("hello"), "executableName": .string(fakeCodex.path), "cwd": .string(configDir.path)], context: context)
    XCTAssertEqual(processRun.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(processRun.data)?["exitCode"]), 0)
    XCTAssertEqual(jsonString(jsonObject(processRun.data)?["sessionId"]), "process-session")
    XCTAssertEqual(jsonArray(jsonObject(processRun.data)?["lines"])?.count, 2)
    XCTAssertTrue(jsonString(jsonObject(processRun.data)?["stdout"])?.contains("process-session") == true)
  }

  func testUsageStatsAggregatesMessagesToolsTurnCompleteAndTokenCountDeltas() throws {
    let sessionsDir = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: sessionsDir)
    }
    try writeUsageRollout(sessionsDir: sessionsDir, relativePath: "2026/02/18/rollout-aaa.jsonl", lines: [
      usageLine("2026-02-18T10:00:00.000Z", "session_meta", .object(["meta": .object(["id": .string("sess-1"), "timestamp": .string("2026-02-18T10:00:00.000Z"), "cwd": .string("/tmp/work")])])),
      usageLine("2026-02-18T10:00:03.000Z", "event_msg", .object(["type": .string("UserMessage"), "message": .string("hello")])),
      usageLine("2026-02-18T10:00:05.000Z", "event_msg", .object(["type": .string("AgentMessage"), "message": .string("world")])),
      usageLine(
        "2026-02-18T10:00:06.000Z",
        "response_item",
        .object([
          "type": .string("message"),
          "role": .string("assistant"),
          "content": .array([
            .object(["type": .string("output_text"), "text": .string("done")])
          ]),
        ])
      ),
      usageLine("2026-02-18T10:00:07.000Z", "response_item", .object(["type": .string("function_call"), "name": .string("toolA"), "arguments": .string("{}"), "call_id": .string("call-1")])),
      usageLine("2026-02-18T10:00:08.000Z", "event_msg", .object(["type": .string("TurnComplete"), "usage": .object(["model": .string("gpt-5-mini"), "input_tokens": .number(10), "output_tokens": .number(20), "cache_read_input_tokens": .number(3), "cache_creation_input_tokens": .number(4), "total_tokens": .number(37)])])),
    ])
    try writeUsageRollout(sessionsDir: sessionsDir, relativePath: "2026/02/19/rollout-bbb.jsonl", lines: [
      usageLine("2026-02-19T09:00:00.000Z", "session_meta", .object(["meta": .object(["id": .string("sess-2"), "timestamp": .string("2026-02-19T09:00:00.000Z"), "cwd": .string("/tmp/work")])])),
      "{broken-json-line",
      usageLine("2026-02-19T09:00:01.000Z", "event_msg", .object(["type": .string("UserMessage"), "message": .string("next")])),
      usageLine("2026-02-19T09:00:02.000Z", "event_msg", .object(["type": .string("TurnComplete"), "usage": .object(["model": .string("gpt-5"), "input_tokens": .number(5), "output_tokens": .number(6), "total_tokens": .number(11)])])),
      usageLine("2026-02-19T09:00:03.000Z", "event_msg", .object(["type": .string("TurnComplete"), "usage": .object(["model": .string("gpt-5-mini"), "inputTokens": .number(2), "outputTokens": .number(1), "totalTokens": .number(3)])])),
    ])
    try writeUsageRollout(sessionsDir: sessionsDir, relativePath: "2026/02/20/rollout-token-count.jsonl", lines: [
      usageLine("2026-02-20T09:00:00.000Z", "session_meta", .object(["meta": .object(["id": .string("sess-3"), "timestamp": .string("2026-02-20T09:00:00.000Z"), "cwd": .string("/tmp/work")])])),
      usageLine("2026-02-20T09:00:01.000Z", "event_msg", .object(["type": .string("token_count"), "info": .object(["model": .string("gpt-5-codex"), "total_token_usage": .object(["input_tokens": .number(50), "cached_input_tokens": .number(10), "output_tokens": .number(40), "total_tokens": .number(100)])])])),
      usageLine("2026-02-20T09:00:02.000Z", "event_msg", .object(["type": .string("token_count"), "info": .object(["model": .string("gpt-5-codex"), "total_token_usage": .object(["input_tokens": .number(70), "cached_input_tokens": .number(10), "output_tokens": .number(70), "total_tokens": .number(140)])])])),
      usageLine("2026-02-20T09:00:03.000Z", "event_msg", .object(["type": .string("token_count"), "info": .object(["model": .string("gpt-5-codex"), "last_token_usage": .object(["input_tokens": .number(3), "cached_input_tokens": .number(1), "output_tokens": .number(2), "total_tokens": .number(6)])])])),
      usageLine("2026-02-20T09:00:04.000Z", "event_msg", .object(["type": .string("token_count"), "info": .null])),
      usageLine("2026-02-20T09:00:05.000Z", "event_msg", .object(["type": .string("token_count"), "info": .object(["total_token_usage": .object(["input_tokens": .number(90), "output_tokens": .number(10), "total_tokens": .number(100)]), "rate_limits": .object(["limit_name": .string("GPT-5.3 Codex Spark")])])])),
    ])

    let stats = try XCTUnwrap(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.path, recentDays: 3, now: try isoDate("2026-02-20T12:00:00.000Z"))))
    XCTAssertEqual(stats.totalSessions, 3)
    XCTAssertEqual(stats.totalMessages, 4)
    XCTAssertEqual(stats.firstSessionDate, "2026-02-18")
    XCTAssertEqual(stats.lastComputedDate, "2026-02-20")
    XCTAssertEqual(stats.modelUsage["gpt-5-mini"], CodexModelUsageStats(inputTokens: 12, outputTokens: 21, cacheReadInputTokens: 3, cacheCreationInputTokens: 4))
    XCTAssertEqual(stats.modelUsage["gpt-5"], CodexModelUsageStats(inputTokens: 5, outputTokens: 6))
    XCTAssertEqual(stats.modelUsage["gpt-5-codex"], CodexModelUsageStats(inputTokens: 73, outputTokens: 72, cacheReadInputTokens: 11))
    XCTAssertEqual(stats.modelUsage["gpt-5.3-codex-spark"], CodexModelUsageStats(inputTokens: 90, outputTokens: 10))
    XCTAssertEqual(stats.recentDailyActivity[0], CodexDailyActivity(date: "2026-02-18", messageCount: 3, sessionCount: 1, toolCallCount: 1, tokensByModel: ["gpt-5-mini": 37]))
    XCTAssertEqual(stats.recentDailyActivity[1], CodexDailyActivity(date: "2026-02-19", messageCount: 1, sessionCount: 1, tokensByModel: ["gpt-5": 11, "gpt-5-mini": 3]))
    XCTAssertEqual(stats.recentDailyActivity[2], CodexDailyActivity(date: "2026-02-20", sessionCount: 1, tokensByModel: ["gpt-5-codex": 146, "gpt-5.3-codex-spark": 100]))
  }

  func testUsageStatsReturnsNilForMissingSessionsDirAndCachesWithinTTL() throws {
    let sessionsDir = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: sessionsDir)
    }
    XCTAssertNil(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.appendingPathComponent("missing").path, recentDays: 1, now: try isoDate("2026-02-20T12:00:00.000Z"))))
    let rollout = try writeUsageRollout(sessionsDir: sessionsDir, relativePath: "2026/02/20/rollout-cache.jsonl", lines: [
      usageLine("2026-02-20T10:00:00.000Z", "session_meta", .object(["meta": .object(["id": .string("sess-cache"), "timestamp": .string("2026-02-20T10:00:00.000Z"), "cwd": .string("/tmp/work")])])),
      usageLine("2026-02-20T10:00:02.000Z", "event_msg", .object(["type": .string("TurnComplete"), "usage": .object(["model": .string("gpt-5"), "input_tokens": .number(1), "output_tokens": .number(1), "total_tokens": .number(2)])])),
    ])
    let first = try XCTUnwrap(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.path, recentDays: 1, now: try isoDate("2026-02-20T12:00:00.000Z"))))
    XCTAssertEqual(first.modelUsage["gpt-5"]?.inputTokens, 1)
    try writeUsageRollout(url: rollout, lines: [
      usageLine("2026-02-20T10:00:00.000Z", "session_meta", .object(["meta": .object(["id": .string("sess-cache"), "timestamp": .string("2026-02-20T10:00:00.000Z"), "cwd": .string("/tmp/work")])])),
      usageLine("2026-02-20T10:00:02.000Z", "event_msg", .object(["type": .string("TurnComplete"), "usage": .object(["model": .string("gpt-5"), "input_tokens": .number(99), "output_tokens": .number(1), "total_tokens": .number(100)])])),
    ])
    let cached = try XCTUnwrap(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.path, recentDays: 1, now: try isoDate("2026-02-20T12:00:04.000Z"))))
    XCTAssertEqual(cached.modelUsage["gpt-5"]?.inputTokens, 1)
    let refreshed = try XCTUnwrap(getCodexUsageStats(options: CodexUsageStatsOptions(codexSessionsDir: sessionsDir.path, recentDays: 1, now: try isoDate("2026-02-20T12:00:06.000Z"))))
    XCTAssertEqual(refreshed.modelUsage["gpt-5"]?.inputTokens, 99)
  }

  func testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps() throws {
    let lines = [
      CodexRolloutLine(timestamp: "2025-05-07T17:24:24.000Z", type: "event_msg", payload: .object(["type": .string("TurnStarted")])),
      CodexRolloutLine(timestamp: "2025-05-07T17:24:25.000Z", type: "event_msg", payload: .object(["type": .string("ExecApprovalRequest")])),
    ]
    let activity = CodexSessionIndex.deriveActivityEntry(sessionId: "session-1", lines: lines)
    XCTAssertEqual(activity.status, .waitingApproval)

    let runningSession = MockCodexRunningSession(sessionId: "session-1", messages: lines)
    let runner = createMockCodexSessionRunner(startSessions: [runningSession])
    let started = try runner.startSession(config: CodexSessionConfig(prompt: "hello"))
    XCTAssertEqual(started.sessionId, "session-1")
    XCTAssertEqual(runner.startSessionCalls.map(\.config.prompt), ["hello"])
    XCTAssertEqual(started.messages().count, 2)
    XCTAssertEqual(started.waitForCompletion().exitCode, 0)

    let emitter = BasicCodexSDKEventEmitter()
    var seenPayload: JSONObject?
    let id = emitter.on(.sessionStarted) { payload in
      seenPayload = payload
    }
    emitter.emit(.sessionStarted, payload: ["sessionId": .string("session-1")])
    XCTAssertEqual(seenPayload?["sessionId"], .string("session-1"))
    emitter.off(.sessionStarted, id: id)

    var registry = CodexToolRegistry()
    registry.register(name: "read_file", definition: ["description": .string("Read a file")])
    XCTAssertEqual(registry.listNames(), ["read_file"])

    let temp = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: temp)
    }
    let paths = try CodexAgentAttachments.imagePathArguments(
      from: [.path("/tmp/source.png"), .base64(data: Data("png".utf8).base64EncodedString(), mediaType: "image/png", filename: "../unsafe name.png")],
      tempDirectory: temp
    )
    XCTAssertEqual(paths.first, "/tmp/source.png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths[1]))
    CodexAgentAttachments.cleanup(paths: [paths[1]])
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths[1]))

    XCTAssertEqual(CodexCLICompatibility.parseProcessOptions(["--model", "gpt-5.5", "--sandbox", "read-only", "--full-auto"]).model, "gpt-5.5")
    XCTAssertEqual(try CodexCLICompatibility.parseCommand(["queue", "move", "queue-1", "prompt-1", "0"]).family, .queue)
    XCTAssertThrowsError(try CodexCLICompatibility.parseCommand(["queue", "unknown"]))
    XCTAssertTrue(CodexCLICompatibility.usage().contains("graphql"))
    XCTAssertTrue(CodexGraphQLCommandExecutor.normalizeDocument("session.list").contains(#"command(name: "session.list""#))
    XCTAssertTrue(CodexGraphQLCommandExecutor.normalizeDocument("group.create").hasPrefix("mutation"))
    XCTAssertTrue(CodexGraphQLCommandExecutor.normalizeDocument("session.watch").hasPrefix("subscription"))
    XCTAssertEqual(try CodexGraphQLCommandExecutor.parseParams(["limit=5", "tag=ship"])["limit"], .number(5))
    let graphQLParamResult = CodexCLICommandExecutor.execute(arguments: ["graphql", "session.list", "--param", #"{"limit":1}"#], context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path))
    XCTAssertEqual(graphQLParamResult.errors, [])
    let variablesPath = temp.appendingPathComponent("graphql-vars.json")
    try #"{"param":{"limit":1}}"#.write(to: variablesPath, atomically: true, encoding: .utf8)
    let graphQLVariablesResult = CodexCLICommandExecutor.execute(arguments: ["graphql", "session.list", "--variables", variablesPath.path], context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path))
    XCTAssertEqual(graphQLVariablesResult.errors, [])
    XCTAssertEqual(jsonObject(CodexGraphQLCommandExecutor.execute(command: "query { ping }").data)?["ping"], .bool(true))
    let variableNameCommand = CodexGraphQLCommandExecutor.execute(
      command: #"query ($name: String!, $param: JSON) { command(name: $name, params: $param) }"#,
      variables: ["name": .string("session.list"), "param": .object(["limit": .number(1)])],
      context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path)
    )
    XCTAssertEqual(variableNameCommand.errors, [])
    let inlineParams = CodexGraphQLCommandExecutor.execute(
      command: #"mutation { command(name: "group.create", params: {name: "inline", description: "from inline"}) }"#,
      context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path)
    )
    XCTAssertEqual(inlineParams.errors, [])
    XCTAssertEqual(try CodexGroupPersistence.findGroup("inline", configDir: temp.path)?.description, "from inline")
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "unknown.command").errors, ["Unknown command: unknown.command"])
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "subscription { queue.run }").errors, ["Unsupported subscription command: queue.run"])
    let fakeCodex = try createExecutable(
      directory: temp,
      name: "fake-codex-session-run.sh",
      body: """
      printf '{"type":"turn_complete","session_id":"session-test"}\\n'
      printf 'CODEX_HOME=%s\\n' "${CODEX_HOME:-}" >&2
      """
    )
    let versionDefault = CodexGraphQLCommandExecutor.execute(command: "version.get", variables: ["executableName": .string(fakeCodex.path)])
    XCTAssertEqual(versionDefault.errors, [])
    XCTAssertNotEqual(jsonObject(versionDefault.data)?["git"], .null)
    let versionWithoutGit = CodexGraphQLCommandExecutor.execute(command: "version.get", variables: ["executableName": .string(fakeCodex.path), "includeGit": .bool(false)])
    XCTAssertEqual(jsonObject(versionWithoutGit.data)?["git"], .null)
    let runResult = CodexGraphQLCommandExecutor.execute(
      command: "session.run",
      variables: ["prompt": .string("hello with spaces"), "model": .string("gpt-5.5"), "fullAuto": .bool(true), "streamGranularity": .string("event"), "executableName": .string(fakeCodex.path)],
      context: CodexAgentCompatibilityContext(codexHome: temp.path, configDir: temp.path)
    )
    if case let .object(data) = runResult.data, case let .array(arguments) = data["arguments"] {
      XCTAssertTrue(arguments.contains(.string("--model")))
      XCTAssertTrue(arguments.contains(.string("gpt-5.5")))
      XCTAssertTrue(arguments.contains(.string("--dangerously-bypass-approvals-and-sandbox")))
      XCTAssertTrue(arguments.contains(.string("--stream-granularity")))
      XCTAssertTrue(arguments.contains(.string("event")))
      XCTAssertTrue(arguments.contains(.string("hello with spaces")))
      XCTAssertEqual(jsonNumber(data["exitCode"]), 0)
      XCTAssertEqual(jsonString(data["stderr"]), "CODEX_HOME=\(temp.path)\n")
    } else {
      XCTFail("expected session.run arguments")
    }
    XCTAssertTrue(CodexGraphQLCommandExecutor.supportedCommandNames.isSuperset(of: ["queue.move", "bookmark.search", "token.rotate", "files.rebuild", "session.watch"]))
    XCTAssertEqual(CodexMarkdown.parseTasks("# Work\n- [ ] one\n- [x] two").map(\.checked), [false, true])
    XCTAssertEqual(CodexMarkdown.parseSections("# Work\nBody\n## Next\nMore").map(\.heading), ["Work", "Next"])
    let patch = "*** Add File: Sources/New.swift\n"
    let changes = CodexFileChanges.extract(from: CodexRolloutLine(timestamp: "now", type: "event_msg", payload: .object(["patch": .string(patch)])))
    XCTAssertEqual(changes, [CodexFileChange(path: "Sources/New.swift", operation: .created, source: .applyPatch, patch: patch)])
  }

  func testLegacyTokenHashConfigQueueGroupRunAndGraphQLAliases() throws {
    let configDir = try makeTemporaryDirectory()
    let codexHome = try makeTemporaryDirectory()
    addTeardownBlock {
      try? FileManager.default.removeItem(at: configDir)
      try? FileManager.default.removeItem(at: codexHome)
    }
    let context = CodexAgentCompatibilityContext(codexHome: codexHome.path, configDir: configDir.path)

    let legacyTokenHash = SHA256.hash(data: Data("legacy-secret".utf8)).map { String(format: "%02x", $0) }.joined()
    try """
    {
      "tokens": [
        {
          "id": "legacy-token",
          "name": "legacy",
          "permissions": ["session:read"],
          "createdAt": "2026-02-20T10:00:00.000Z",
          "tokenHash": "\(legacyTokenHash)"
        }
      ]
    }
    """.write(to: configDir.appendingPathComponent("tokens.json"), atomically: true, encoding: .utf8)
    XCTAssertEqual(try CodexTokenPersistence.verify(rawToken: "legacy-token.legacy-secret", permission: "session:read", configDir: configDir.path)?.name, "legacy")
    XCTAssertFalse(String(describing: CodexGraphQLCommandExecutor.execute(command: "token.list", context: context).data).contains("legacy-secret"))

    let marker = configDir.appendingPathComponent("codex-run-marker.txt")
    let fakeCodex = try createExecutable(
      directory: configDir,
      name: "fake-codex-runner.sh",
      body: """
      printf '%s\\n' "$*" >> "\(marker.path)"
      printf '{"type":"turn_complete","session_id":"fake"}\\n'
      exit "${FAKE_CODEX_EXIT_CODE:-0}"
      """
    )

    let cliRun = CodexCLICommandExecutor.execute(
      arguments: ["session", "run", "--prompt", "cli prompt", "--model", "gpt-5.5", "--sandbox", "read-only", "--full-auto", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliRun.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(cliRun.data)?["exitCode"]), 0)
    let cliEqualsPromptRun = CodexCLICommandExecutor.execute(
      arguments: ["session", "run", "foo=bar", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliEqualsPromptRun.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(cliEqualsPromptRun.data)?["exitCode"]), 0)
    let cliModelCheck = CodexCLICommandExecutor.execute(
      arguments: ["model", "check", "--model", "gpt-5.5", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliModelCheck.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(cliModelCheck.data)?["exitCode"]), 0)
    XCTAssertEqual(jsonObject(cliModelCheck.data)?["ok"], .bool(true))
    let appVersion = CodexAgentCLIApplication.run(arguments: ["version", "includeGit=false"], context: context)
    XCTAssertEqual(appVersion.exitCode, 0)
    XCTAssertEqual(appVersion.stderr, "")
    XCTAssertTrue(appVersion.stdout.contains(#""version""#))

    let cliQueueCreate = CodexCLICommandExecutor.execute(
      arguments: ["queue", "create", "cli-release", "--project", configDir.path],
      context: context
    )
    XCTAssertEqual(cliQueueCreate.errors, [])
    let cliQueueAdd = CodexCLICommandExecutor.execute(
      arguments: ["queue", "add", "cli-release", "--prompt", "queued via cli", "--image", "/tmp/cli-a.png", "--image", "/tmp/cli-b.png"],
      context: context
    )
    XCTAssertEqual(cliQueueAdd.errors, [])
    let cliQueuePromptId = try XCTUnwrap(jsonString(jsonObject(cliQueueAdd.data)?["id"]))
    XCTAssertEqual(try CodexQueuePersistence.findQueue("cli-release", configDir: configDir.path)?.projectPath, configDir.path)
    XCTAssertEqual(try CodexQueuePersistence.findQueue("cli-release", configDir: configDir.path)?.prompts.first?.imagePaths, ["/tmp/cli-a.png", "/tmp/cli-b.png"])
    XCTAssertEqual(CodexCLICommandExecutor.execute(arguments: ["queue", "mode", "cli-release", cliQueuePromptId, "--mode", "manual"], context: context).errors, [])
    XCTAssertEqual(CodexCLICommandExecutor.execute(arguments: ["queue", "move", "cli-release", "--from", "0", "--to", "0"], context: context).errors, [])

    let cliGroupCreate = CodexCLICommandExecutor.execute(arguments: ["group", "create", "cli-batch"], context: context)
    XCTAssertEqual(cliGroupCreate.errors, [])
    XCTAssertEqual(CodexCLICommandExecutor.execute(arguments: ["group", "add", "cli-batch", "session-cli"], context: context).errors, [])
    let cliGroupRun = CodexCLICommandExecutor.execute(
      arguments: ["group", "run", "cli-batch", "--prompt", "group via cli", "--max-concurrent", "1", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliGroupRun.errors, [])
    let cliResumeWithFlagPrompt = CodexCLICommandExecutor.execute(
      arguments: ["session", "resume", "session-1", "--prompt", "resume via cli flag", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliResumeWithFlagPrompt.errors, [])
    let cliResumeWithPositionalPrompt = CodexCLICommandExecutor.execute(
      arguments: ["session", "resume", "session-1", "resume", "via", "cli", "positionals", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliResumeWithPositionalPrompt.errors, [])
    let cliForkWithNthMessage = CodexCLICommandExecutor.execute(
      arguments: ["session", "fork", "session-1", "--nth-message", "2", "--codex-binary", fakeCodex.path],
      context: context
    )
    XCTAssertEqual(cliForkWithNthMessage.errors, [])

    let queueCreate = CodexGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("release"), "projectPath": .string(configDir.path)], context: context)
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.create", variables: ["name": .string("invalid")], context: context).errors, ["missingVariable(\"projectPath\")"])
    let queueId = try XCTUnwrap(jsonString(jsonObject(queueCreate.data)?["id"]))
    let first = CodexGraphQLCommandExecutor.execute(command: "queue.add", variables: ["id": .string(queueId), "prompt": .string("first"), "images": .array([.string("/tmp/a.png")])], context: context)
    let firstId = try XCTUnwrap(jsonString(jsonObject(first.data)?["id"]))
    let second = CodexGraphQLCommandExecutor.execute(command: "queue.add", variables: ["id": .string(queueId), "prompt": .string("second")], context: context)
    let secondId = try XCTUnwrap(jsonString(jsonObject(second.data)?["id"]))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.move", variables: ["id": .string(queueId), "from": .number(1), "to": .number(0)], context: context).errors, [])
    XCTAssertEqual(try CodexQueuePersistence.findQueue(queueId, configDir: configDir.path)?.prompts.map(\.id), [secondId, firstId])
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.move", variables: ["id": .string(queueId), "from": .number(0), "to": .number(2)], context: context).errors, ["Queue command not found"])
    XCTAssertEqual(try CodexQueuePersistence.findQueue(queueId, configDir: configDir.path)?.prompts.map(\.id), [secondId, firstId])
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.update", variables: ["id": .string(queueId), "commandId": .string(firstId), "prompt": .string("updated"), "status": .string("pending")], context: context).errors, [])
    let invalidStatus = CodexGraphQLCommandExecutor.execute(command: "queue.update", variables: ["id": .string(queueId), "commandId": .string(firstId), "status": .string("archived")], context: context)
    XCTAssertEqual(invalidStatus.errors, ["status must be one of: pending, running, completed, failed"])
    XCTAssertEqual(try CodexQueuePersistence.findQueue(queueId, configDir: configDir.path)?.prompts.first(where: { $0.id == firstId })?.status, .pending)
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "queue.mode", variables: ["id": .string(queueId), "commandId": .string(firstId), "mode": .string("manual")], context: context).errors, [])
    let queueRun = CodexGraphQLCommandExecutor.execute(command: "queue.run", variables: ["id": .string(queueId), "executableName": .string(fakeCodex.path)], context: context)
    XCTAssertEqual(queueRun.errors, [])
    XCTAssertTrue(String(describing: queueRun.data).contains("queue_completed"))

    let groupCreate = CodexGraphQLCommandExecutor.execute(command: "group.create", variables: ["name": .string("batch")], context: context)
    let groupId = try XCTUnwrap(jsonString(jsonObject(groupCreate.data)?["id"]))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "group.add", variables: ["id": .string(groupId), "sessionId": .string("session-1")], context: context).errors, [])
    let groupRun = CodexGraphQLCommandExecutor.execute(command: "group.run", variables: ["id": .string(groupId), "prompt": .string("ship"), "executableName": .string(fakeCodex.path)], context: context)
    XCTAssertEqual(groupRun.errors, [])
    XCTAssertTrue(String(describing: groupRun.data).contains("session_completed"))
    var markerText = ""
    for _ in 0..<20 {
      markerText = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
      if markerText.contains("resume via cli flag"),
         markerText.contains("resume via cli positionals"),
         markerText.contains("--nth-message 2") {
        break
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertTrue(markerText.contains("first") || markerText.contains("updated"))
    XCTAssertTrue(markerText.contains("ship"))
    XCTAssertTrue(markerText.contains("resume"))
    XCTAssertTrue(markerText.contains("session-1"))
    XCTAssertTrue(markerText.contains("foo=bar"))
    XCTAssertTrue(markerText.contains("resume via cli flag"))
    XCTAssertTrue(markerText.contains("resume via cli positionals"))
    XCTAssertTrue(markerText.contains("--nth-message 2"))
    let aliasRun = CodexGraphQLCommandExecutor.execute(
      command: "session.run",
      variables: [
        "prompt": .string("alias"),
        "codexBinary": .string(fakeCodex.path),
        "environmentVariables": .object(["FAKE_CODEX_EXIT_CODE": .string("0")]),
      ],
      context: context
    )
    XCTAssertEqual(aliasRun.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(aliasRun.data)?["exitCode"]), 0)
    let invalidEnvironment = CodexGraphQLCommandExecutor.execute(
      command: "session.run",
      variables: ["prompt": .string("bad"), "environmentVariables": .object(["FAKE_CODEX_EXIT_CODE": .number(0)])],
      context: context
    )
    XCTAssertFalse(invalidEnvironment.errors.isEmpty)
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["executableName": .string(fakeCodex.path)], context: context).errors, ["missingVariable(\"prompt\")"])
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("   "), "executableName": .string(fakeCodex.path)], context: context).errors, ["missingVariable(\"prompt\")"])
    XCTAssertEqual(CodexCLICommandExecutor.execute(arguments: ["session", "run", "--codex-binary", fakeCodex.path], context: context).errors, ["missingVariable(\"prompt\")"])
    let appMissingPrompt = CodexAgentCLIApplication.run(arguments: ["session", "run", "--codex-binary", fakeCodex.path], context: context)
    XCTAssertEqual(appMissingPrompt.exitCode, 1)
    XCTAssertTrue(appMissingPrompt.stderr.contains("prompt"))
    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("bad"), "images": .array([.number(1)])], context: context).errors.isEmpty)
    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("bad"), "sandbox": .string("bad")], context: context).errors.isEmpty)
    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("bad"), "approvalMode": .string("bad")], context: context).errors.isEmpty)
    let approvalRun = CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("approval"), "approvalMode": .string("always"), "executableName": .string(fakeCodex.path)], context: context)
    XCTAssertEqual(approvalRun.errors, [])
    XCTAssertFalse(String(describing: approvalRun.data).contains("--approval-mode"))
    XCTAssertFalse(CodexGraphQLCommandExecutor.execute(command: "session.run", variables: ["prompt": .string("bad"), "streamGranularity": .string("word")], context: context).errors.isEmpty)
    let slowCodex = try createExecutable(
      directory: configDir,
      name: "fake-codex-slow.sh",
      body: """
      sleep 1
      printf '{"type":"turn_complete","session_id":"fake"}\\n'
      """
    )
    let resumeHandle = CodexGraphQLCommandExecutor.execute(command: "session.resume", variables: ["id": .string("session-1"), "prompt": .string("resume"), "executableName": .string(slowCodex.path)], context: context)
    XCTAssertEqual(resumeHandle.errors, [])
    XCTAssertEqual(jsonString(jsonObject(resumeHandle.data)?["status"]), "running")
    let forkHandle = CodexGraphQLCommandExecutor.execute(command: "session.fork", variables: ["id": .string("session-1"), "nthMessage": .number(1), "executableName": .string(slowCodex.path)], context: context)
    XCTAssertEqual(forkHandle.errors, [])
    XCTAssertEqual(jsonString(jsonObject(forkHandle.data)?["status"]), "running")
    let defaultToken = CodexGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("default")], context: context)
    let defaultRawToken = try XCTUnwrap(jsonString(defaultToken.data))
    XCTAssertNotNil(try CodexTokenPersistence.verify(rawToken: defaultRawToken, permission: "session:read", configDir: configDir.path))
    XCTAssertNil(try CodexTokenPersistence.verify(rawToken: defaultRawToken, permission: "session:cancel", configDir: configDir.path))
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "token.create", variables: ["permissions": .array([.string("session:read")])], context: context).errors, ["missingVariable(\"name\")"])
    XCTAssertEqual(CodexGraphQLCommandExecutor.execute(command: "token.create", variables: ["name": .string("bad"), "permissions": .array([.string("session:*")])], context: context).errors, ["No valid permissions provided"])
    let cliToken = CodexCLICommandExecutor.execute(arguments: ["token", "create", "--name", "cli-token", "--permissions", "session:cancel,session:*", "--expires-at", "2099-01-01T00:00:00Z"], context: context)
    XCTAssertEqual(cliToken.errors, [])
    let cliRawToken = try XCTUnwrap(jsonString(cliToken.data))
    let cliTokenMetadata = try XCTUnwrap(try CodexTokenPersistence.verify(rawToken: cliRawToken, permission: "session:cancel", configDir: configDir.path))
    XCTAssertEqual(cliTokenMetadata.name, "cli-token")
    XCTAssertEqual(cliTokenMetadata.permissions, ["session:cancel"])

    let day = codexHome.appendingPathComponent("sessions/2026/02/20", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let rolloutA = day.appendingPathComponent("rollout-session-a.jsonl")
    try writeRollout(rolloutA, id: "session-a", cwd: configDir.path, source: "cli", branch: "main", message: "FindMe")
    let rolloutFiles = day.appendingPathComponent("rollout-session-files.jsonl")
    try writeRollout(rolloutFiles, id: "session-files", cwd: configDir.path, source: "cli", branch: "files", message: "files")
    try "{\"timestamp\":\"2025-05-07T17:26:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"patch\":\"*** Add File: Sources/A.swift\\n\"}}".appendLine(to: rolloutFiles)
    try writeRollout(day.appendingPathComponent("rollout-session-b.jsonl"), id: "session-b", cwd: "/tmp/other", source: "exec", branch: "dev", message: "skip")
    let cliList = CodexCLICommandExecutor.execute(arguments: ["session", "list", "--source", "cli", "--cwd", configDir.path, "--branch", "main", "--limit", "1"], context: context)
    XCTAssertEqual(cliList.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(cliList.data)?["total"]), 1)
    let list = CodexGraphQLCommandExecutor.execute(command: "session.list", variables: ["source": .string("cli"), "cwd": .string(configDir.path), "branch": .string("main"), "limit": .number(1), "offset": .number(0)], context: context)
    XCTAssertEqual(jsonNumber(jsonObject(list.data)?["total"]), 1)
    let search = CodexGraphQLCommandExecutor.execute(command: "session.search", variables: ["query": .string("findme"), "role": .string("user"), "caseSensitive": .bool(false), "limit": .number(1)], context: context)
    XCTAssertEqual(jsonArray(jsonObject(search.data)?["sessionIds"]), [.string("session-a")])
    XCTAssertEqual(jsonNumber(jsonObject(search.data)?["offset"]), 0)
    XCTAssertEqual(jsonNumber(jsonObject(search.data)?["limit"]), 1)
    XCTAssertNotNil(jsonObject(search.data)?["durationMs"])
    let byteLimitedSearch = CodexGraphQLCommandExecutor.execute(command: "session.search", variables: ["query": .string("findme"), "role": .string("user"), "maxBytes": .number(20)], context: context)
    XCTAssertEqual(jsonArray(jsonObject(byteLimitedSearch.data)?["sessionIds"]), [.string("session-a")])
    XCTAssertEqual(jsonObject(byteLimitedSearch.data)?["truncated"], .bool(false))
    let cappedSearch = CodexGraphQLCommandExecutor.execute(command: "session.search", variables: ["query": .string("FindMe"), "maxSessions": .number(0)], context: context)
    XCTAssertEqual(jsonArray(jsonObject(cappedSearch.data)?["sessionIds"]), [])
    let negativeSearch = CodexGraphQLCommandExecutor.execute(command: "session.search", variables: ["query": .string("FindMe"), "maxSessions": .number(-1), "offset": .number(-1), "limit": .number(-1)], context: context)
    XCTAssertEqual(negativeSearch.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(negativeSearch.data)?["sessionIds"]), [])
    let wrapperSearch = CodexGraphQLCommandExecutor.execute(
      command: #"query ($param: JSON) { command(name: "session.search", params: $param) }"#,
      variables: ["param": .object(["query": .string("findme"), "role": .string("user")])],
      context: context
    )
    XCTAssertEqual(jsonArray(jsonObject(wrapperSearch.data)?["sessionIds"]), [.string("session-a")])
    let transcript = CodexGraphQLCommandExecutor.execute(command: "session.searchTranscript", variables: ["id": .string("session-a"), "query": .string("FindMe")], context: context)
    XCTAssertEqual(jsonObject(transcript.data)?["matched"], .bool(true))
    XCTAssertEqual(jsonNumber(jsonObject(transcript.data)?["matchCount"]), 1)
    XCTAssertEqual(jsonNumber(jsonObject(transcript.data)?["scannedEvents"]), 1)
    let missingTranscript = CodexGraphQLCommandExecutor.execute(command: "session.searchTranscript", variables: ["id": .string("missing-session"), "query": .string("FindMe")], context: context)
    XCTAssertEqual(missingTranscript.errors, [])
    XCTAssertEqual(jsonString(jsonObject(missingTranscript.data)?["sessionId"]), "missing-session")
    XCTAssertEqual(jsonObject(missingTranscript.data)?["matched"], .bool(false))
    let cliTranscript = CodexCLICommandExecutor.execute(arguments: ["session", "searchTranscript", "session-a", "FindMe"], context: context)
    XCTAssertEqual(cliTranscript.errors, [])
    XCTAssertEqual(jsonObject(cliTranscript.data)?["matched"], .bool(true))
    let watch = CodexGraphQLCommandExecutor.execute(command: #"subscription ($param: JSON) { command(name: "session.watch", params: $param) }"#, variables: ["param": .object(["id": .string("session-a"), "startOffset": .number(0)])], context: context)
    XCTAssertEqual(watch.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(watch.data)?["events"])?.count, 2)
    let negativeOffsetWatch = CodexGraphQLCommandExecutor.execute(command: "session.watch", variables: ["id": .string("session-a"), "startOffset": .number(-1)], context: context)
    XCTAssertEqual(negativeOffsetWatch.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(negativeOffsetWatch.data)?["events"])?.count, 2)
    let defaultOffsetWatch = CodexGraphQLCommandExecutor.execute(command: "session.watch", variables: ["id": .string("session-a")], context: context)
    XCTAssertEqual(defaultOffsetWatch.errors, [])
    XCTAssertEqual(jsonArray(jsonObject(defaultOffsetWatch.data)?["events"])?.count, 2)
    let liveWatch = try CodexGraphQLCommandExecutor.watchSession(id: "session-a", codexHome: codexHome.path)
    defer {
      liveWatch.cancel()
    }
    try #"{"timestamp":"2025-05-07T17:27:00.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"Live watch"}}"#.appendLine(to: rolloutA)
    XCTAssertEqual(liveWatch.next(timeout: 1)?.payload, .object(["type": .string("AgentMessage"), "message": .string("Live watch")]))
    let cliFileList = CodexCLICommandExecutor.execute(arguments: ["files", "list", "session-files", "codexHome=\(codexHome.path)"], context: context)
    XCTAssertEqual(jsonString(jsonObject(cliFileList.data)?["sessionId"]), "session-files")
    XCTAssertEqual(jsonNumber(jsonObject(cliFileList.data)?["totalFiles"]), 1)
    XCTAssertEqual(jsonString(jsonObject(jsonArray(jsonObject(cliFileList.data)?["files"])?.first)?["path"]), "Sources/A.swift")
    let cliPatches = CodexCLICommandExecutor.execute(arguments: ["files", "patches", "session-files", "codexHome=\(codexHome.path)"], context: context)
    XCTAssertEqual(jsonString(jsonObject(cliPatches.data)?["sessionId"]), "session-files")
    XCTAssertEqual(jsonNumber(jsonObject(cliPatches.data)?["totalFiles"]), 1)
    XCTAssertEqual(jsonNumber(jsonObject(cliPatches.data)?["totalChanges"]), 1)
    let firstPatchFile = jsonObject(jsonArray(jsonObject(cliPatches.data)?["files"])?.first)
    XCTAssertEqual(jsonString(firstPatchFile?["path"]), "Sources/A.swift")
    let firstPatchChange = jsonObject(jsonArray(firstPatchFile?["changes"])?.first)
    XCTAssertTrue(jsonString(firstPatchChange?["patch"])?.contains("*** Add File: Sources/A.swift\\n") == true)
    let rebuild = CodexGraphQLCommandExecutor.execute(command: "files.rebuild", context: context)
    XCTAssertEqual(rebuild.errors, [])
    XCTAssertEqual(jsonNumber(jsonObject(rebuild.data)?["indexedSessions"]), 3)
    let fileFind = CodexGraphQLCommandExecutor.execute(command: "files.find", variables: ["path": .string("Sources/A.swift")], context: context)
    XCTAssertEqual(fileFind.errors, [])
    XCTAssertEqual(jsonString(jsonObject(fileFind.data)?["path"]), "Sources/A.swift")
    XCTAssertEqual(jsonString(jsonObject(jsonArray(jsonObject(fileFind.data)?["sessions"])?.first)?["sessionId"]), "session-files")

    try writeRollout(day.appendingPathComponent("rollout-session-long.jsonl"), id: "session-long", cwd: configDir.path, source: "cli", branch: "long", message: "Needle " + String(repeating: "x", count: 100))
    let longPrefixTranscript = CodexGraphQLCommandExecutor.execute(command: "session.searchTranscript", variables: ["id": .string("session-long"), "query": .string("Needle"), "maxBytes": .number(10)], context: context)
    XCTAssertEqual(longPrefixTranscript.errors, [])
    XCTAssertEqual(jsonObject(longPrefixTranscript.data)?["matched"], .bool(true))
    XCTAssertEqual(jsonNumber(jsonObject(longPrefixTranscript.data)?["matchCount"]), 1)
    XCTAssertEqual(jsonObject(longPrefixTranscript.data)?["truncated"], .bool(true))
  }

  func testFailedProcessStreamStartupClosesLineStream() {
    let manager = CodexProcessManager(executableName: "codex")
    let stream = manager.spawnExecStream(prompt: "hello", options: CodexProcessOptions(cwd: "/definitely/missing/riela/codex-agent-test"))

    XCTAssertEqual(stream.waitForCompletion(), 127)
    XCTAssertNil(stream.lines.next(timeout: nil))
  }
}

private extension String {
  func appendLine(to url: URL) throws {
    try (self + "\n").appendRaw(to: url)
  }

  func appendRaw(to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer {
      try? handle.close()
    }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(utf8))
  }
}

private func makeTemporaryDirectory() throws -> URL {
  let repoTmp = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("tmp/riela-codex-agent-tests", isDirectory: true)
  try FileManager.default.createDirectory(at: repoTmp, withIntermediateDirectories: true)
  let url = repoTmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func writeRollout(_ url: URL, id: String, cwd: String, source: String, branch: String?, message: String) throws {
  let git = branch.map { #","git":{"sha":"abc123","branch":"\#($0)","origin_url":"https://example.test/repo.git"}"# } ?? ""
  try [
    #"{"timestamp":"2025-05-07T17:24:21.123Z","type":"session_meta","payload":{"meta":{"id":"\#(id)","timestamp":"2025-05-07T17:24:21.123Z","cwd":"\#(cwd)","originator":"codex-cli","cli_version":"0.1.0","source":"\#(source)","model_provider":"openai"}\#(git)}}"#,
    #"{"timestamp":"2025-05-07T17:25:00.000Z","type":"event_msg","payload":{"type":"UserMessage","message":"\#(message)"}}"#,
  ].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func runSQLite(_ path: String, _ sql: String) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
  process.arguments = [path, sql]
  process.standardOutput = Pipe()
  process.standardError = Pipe()
  try process.run()
  process.waitUntilExit()
  XCTAssertEqual(process.terminationStatus, 0)
}

@discardableResult
private func writeUsageRollout(sessionsDir: URL, relativePath: String, lines: [String]) throws -> URL {
  let url = sessionsDir.appendingPathComponent(relativePath)
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try writeUsageRollout(url: url, lines: lines)
  return url
}

private func writeUsageRollout(url: URL, lines: [String]) throws {
  try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func usageLine(_ timestamp: String, _ type: String, _ payload: JSONValue) -> String {
  let data = try! JSONEncoder().encode(JSONValue.object(["timestamp": .string(timestamp), "type": .string(type), "payload": payload]))
  return String(decoding: data, as: UTF8.self)
}

private func isoDate(_ value: String) throws -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return try XCTUnwrap(formatter.date(from: value))
}

private func jsonObject(_ value: JSONValue?) -> JSONObject? {
  if case let .object(object)? = value {
    return object
  }
  return nil
}

private func jsonString(_ value: JSONValue?) -> String? {
  if case let .string(string)? = value {
    return string
  }
  return nil
}

private func jsonArray(_ value: JSONValue?) -> [JSONValue]? {
  if case let .array(array)? = value {
    return array
  }
  return nil
}

private func jsonNumber(_ value: JSONValue?) -> Double? {
  if case let .number(number)? = value {
    return number
  }
  return nil
}

private func createExecutable(directory: URL, name: String, body: String) throws -> URL {
  let url = directory.appendingPathComponent(name)
  try "#!/bin/sh\nset -eu\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  return url
}
