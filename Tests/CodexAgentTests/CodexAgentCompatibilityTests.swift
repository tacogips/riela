import Foundation
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
      "src/rollout/watcher.test.ts": ["CodexAgentSessionIndexCompatibilityTests.testRolloutWatcherEmitsCompleteLines"],
      "src/sdk/agent-runner.dist-runtime.test.ts": ["testProcessManagerRunAgentAndOperationalStores"],
      "src/sdk/agent-runner.process-options.test.ts": [
        "AgentAdapterTests.testCodexProcessCommandBuilderMatchesReferenceExecCompatibilityArgs",
        "AgentAdapterTests.testCodexProcessCommandBuilderBuildsResumeCompatibilityArgs"
      ],
      "src/sdk/agent-runner.test.ts": [
        "testProcessManagerRunAgentAndOperationalStores",
        "testProcessManagerResumeStreamAndProductionRunAgentRunner",
        "testCodexAgentSDKRawModeAndResumeBackfillMirrorLegacySessionRunner",
        "testCodexAgentSDKLifecycleCompletionAndErrorEventsMirrorLegacyRunAgent",
        "testCodexAgentSDKCharStreamGranularityEmitsPerCharacterDeltas"
      ],
      "src/sdk/events.test.ts": ["AgentAdapterTests.testCodexAgentEventNormalizerPortsSdkNormalizedEvents", "testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/sdk/mock-session-runner.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/sdk/model-availability.test.ts": ["AgentAdapterTests.testCodexDefaultReadinessOperationsProbeToolsAuthAndModels"],
      "src/sdk/session-runner.test.ts": [
        "testProcessManagerResumeStreamAndProductionRunAgentRunner",
        "testResumeSessionDiscoversLateRolloutBackfillsAndDeduplicatesLines",
        "testCodexAgentSDKCharStreamGranularityEmitsPerCharacterDeltas"
      ],
      "src/sdk/tool-registry.test.ts": ["testActivityMockRunnerEmitterToolRegistryAttachmentsAndOps"],
      "src/sdk/tool-versions.test.ts": ["AgentAdapterTests.testCodexDefaultReadinessOperationsProbeToolsAuthAndModels"],
      "src/sdk/usage-stats.test.ts": ["testUsageStatsAggregatesMessagesToolsTurnCompleteAndTokenCountDeltas"],
      "src/session/index.test.ts": ["CodexAgentSessionIndexCompatibilityTests.testSessionIndexListsFiltersFindsLatestAndSearchesTranscripts"],
      "src/session/search.test.ts": [
        "CodexAgentSessionIndexCompatibilityTests.testSessionIndexListsFiltersFindsLatestAndSearchesTranscripts",
        "testGraphQLVariablesFileChangesAndTranscriptSearchBudgets"
      ],
      "src/session/sqlite.test.ts": ["CodexAgentSessionIndexCompatibilityTests.testSessionIndexMergesSQLiteAndRolloutsWithRolloutMetadataPrecedence"]
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
      "src/session/sqlite.test.ts"
    ]

    XCTAssertEqual(Set(coverage.keys), expectedLegacyTests)
    XCTAssertEqual(coverage.count, 30)
    XCTAssertFalse(coverage.values.contains { $0.isEmpty })
  }

  func testParseRolloutLineNormalizesReferenceRolloutAndExecEvents() throws {
    let sessionMeta = parseRolloutLine(codexSessionMetaLine(id: "session-1", cwd: "/tmp/project", branch: "main"))
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
      codexSessionMetaLine(id: "session-1", cwd: "/tmp/project", includeProvenance: false),
      codexEventMessageLine(
        timestamp: "2025-05-07T17:24:22.000Z",
        type: "UserMessage",
        message: "# AGENTS.md instructions for /tmp/project"
      ),
      codexEventMessageLine(timestamp: "2025-05-07T17:24:23.000Z", type: "UserMessage", message: "Fix the auth bug"),
      codexEventMessageLine(timestamp: "2025-05-07T17:24:24.000Z", type: "AgentMessage", message: "I will fix it."),
      usageLine(
        "2025-05-07T17:24:25.000Z",
        "response_item",
        .object([
          "type": .string("function_call"),
          "name": .string("read_file"),
          "arguments": .string(#"{"path":"README.md"}"#),
          "call_id": .string("call-1")
        ])
      ),
      usageLine(
        "2025-05-07T17:24:26.000Z",
        "event_msg",
        .object([
          "type": .string("ExecCommandEnd"),
          "command": .array([.string("echo"), .string("hello")]),
          "exit_code": .number(0),
          "aggregated_output": .string("hello\n")
        ])
      )
    ].joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)

    XCTAssertEqual(try extractFirstUserMessage(path: rollout.path), "Fix the auth bug")
    let allMessages = try getSessionMessages(path: rollout.path)
    XCTAssertEqual(allMessages.count, 5)
    XCTAssertTrue(allMessages.contains { $0.category == .assistantToolResponse })
    XCTAssertTrue(allMessages.contains { $0.category == .toolUserResponse && $0.text == "hello\n" })

    let filtered = try getSessionMessages(
      path: rollout.path,
      options: CodexSessionMessageOptions(excludeToolRelated: true, excludeSystemInjected: true)
    )
    XCTAssertEqual(filtered.map(\.text), ["Fix the auth bug", "I will fix it."])
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
          #"{"timestamp":"2025-05-07T17:24:23.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"resumed"}}"#
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
      printf '%s\\n' '\(codexSessionMetaLine(id: "session-late", timestamp: "2026-06-17T02:10:00.000Z", cwd: temp.path, source: "exec", includeProvenance: false))' > '\(rollout.path)'
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
      printf '%s\\n' '\(codexSessionMetaLine(id: "real-session-id", timestamp: "2026-06-17T02:00:00.000Z", cwd: "/tmp/project", source: "exec", includeProvenance: false))'
      printf '%s\\n' '\(codexEventMessageLine(timestamp: "2026-06-17T02:00:01.000Z", type: "AgentMessage", message: "done"))'
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
      printf '%s\\n' '\(codexSessionMetaLine(id: "session-cancel", cwd: "/tmp/project", source: "exec", includeProvenance: false))'
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
    let groupResults = groups.runGroup(id: group.id, maxConcurrent: 1) { _ in
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
    let bookmark = try bookmarks.create(
      type: .range,
      sessionId: "session-a",
      text: "important",
      name: "range note",
      tags: [" Beta ", "Ship", "Beta", "ship", "Ship"],
      startLine: 1,
      endLine: 4,
      fromMessageId: "message-a",
      toMessageId: "message-b"
    )
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

    let sessionBookmark = try CodexBookmarkPersistence.addBookmark(
      type: .session,
      sessionId: "session-1",
      name: "important session",
      description: "Detailed postmortem",
      tags: ["Priority", "review"],
      configDir: configDir.path
    )
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
        CodexFileChange(path: "Sources/Old.swift", operation: .deleted, source: .applyPatch, patch: applyPatchText)
      ]
    )

    let shellChange = CodexRolloutLine(
      timestamp: "now",
      type: "event_msg",
      payload: .object(["file_changes": .array([
        .object(["path": .string("README.md"), "operation": .string("modified"), "source": .string("shell")])
      ])])
    )
    XCTAssertEqual(CodexFileChanges.extract(from: shellChange), [CodexFileChange(path: "README.md", operation: .modified, source: .shell)])
    let directMoveChange = CodexRolloutLine(
      timestamp: "now",
      type: "event_msg",
      payload: .object(["file_changes": .array([
        .object([
          "path": .string("New.md"),
          "previousPath": .string("Old.md"),
          "operation": .string("moved"),
          "source": .string("shell")
        ])
      ])])
    )
    XCTAssertEqual(CodexFileChanges.extract(from: directMoveChange), [CodexFileChange(path: "New.md", operation: .moved, source: .shell, previousPath: "Old.md")])
    let failedShell = CodexRolloutLine(
      timestamp: "now",
      type: "event_msg",
      payload: .object([
        "exit_code": .number(1),
        "file_changes": .array([
          .object(["path": .string("FAILED.md"), "operation": .string("modified"), "source": .string("shell")])
        ])
      ])
    )
    XCTAssertEqual(CodexFileChanges.extract(from: failedShell), [])
    let pendingPatchCall = CodexRolloutLine(
      timestamp: "now",
      type: "response_item",
      payload: .object([
        "type": .string("function_call"),
        "call_id": .string("call-failed-patch"),
        "arguments": .object(["command": .string("apply_patch <<'PATCH'\n*** Update File: Failed.swift\nPATCH")])
      ])
    )
    let failedPatchOutput = CodexRolloutLine(
      timestamp: "now",
      type: "response_item",
      payload: .object([
        "type": .string("function_call_output"),
        "call_id": .string("call-failed-patch"),
        "output": .string(#"{"metadata":{"exit_code":1},"status":"failed"}"#)
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
        "arguments": .string(#"{"command":"git mv OldName.md NewName.md"}"#)
      ])
    )
    XCTAssertEqual(CodexFileChanges.extract(from: localShell), [CodexFileChange(path: "NewName.md", operation: .moved, source: .shell, previousPath: "OldName.md", command: "git mv OldName.md NewName.md")])
    let redirect = CodexRolloutLine(
      timestamp: "now",
      type: "response_item",
      payload: .object([
        "type": .string("function_call"),
        "arguments": .object(["command": .string("printf hello > Created.md")])
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
      #"{"timestamp":"2025-05-07T17:25:01.000Z","type":"event_msg","payload":{"type":"AgentMessage","message":"beta response"}}"#
    ].joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)

    XCTAssertEqual(
      try CodexSessionIndex.searchSessions(
        query: "alpha",
        options: CodexSessionListOptions(codexHome: home.path),
        searchOptions: CodexSessionTranscriptSearchOptions(role: "user")
      ).sessionIds,
      [sessionId]
    )
    XCTAssertEqual(
      try CodexSessionIndex.searchSessions(
        query: "alpha",
        options: CodexSessionListOptions(codexHome: home.path),
        searchOptions: CodexSessionTranscriptSearchOptions(caseSensitive: true)
      ).sessionIds,
      []
    )
    XCTAssertEqual(
      try CodexSessionIndex.searchSessions(
        query: "response",
        options: CodexSessionListOptions(codexHome: home.path),
        searchOptions: CodexSessionTranscriptSearchOptions(role: "assistant", limit: 1, offset: 0)
      ).sessionIds,
      [sessionId]
    )
  }

}
