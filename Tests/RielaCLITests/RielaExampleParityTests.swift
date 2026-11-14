import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class RielaExampleParityTests: XCTestCase {
  private enum RepositoryPackage {
    static let manifestFileName = "Package.swift"
  }

  private enum ExampleCatalog {
    static let directoryName = "examples"
    static let expectedMockScenarioCount = 36
    static let expectedNodeMockScenarioCount = 0
  }

  private enum WorkflowPackage {
    static let manifestFileName = "workflow.json"
  }

  private enum MockScenario {
    static let fileName = "mock-scenario.json"
  }

  private enum WorkflowIds {
    static let defaultSuperviserWorkflowName = "default-superviser"
    static let defaultSuperviserWorkflowId = "riela-default-superviser"
    static let chatMemoryRawAndDailySummaryWorkflowName = "chat-memory-raw-and-daily-summary"
    static let supervisedMockRetryWorkflowName = "supervised-mock-retry"
    static let discordAgentTrioChatWorkflowName = "discord-agent-trio-chat"
    static let matrixAgentTrioChatWorkflowName = "matrix-agent-trio-chat"
    static let telegramAgentTrioChatWorkflowName = "telegram-agent-trio-chat"
    static let telegramSDKTrioChatWorkflowName = "telegram-sdk-trio-chat"
    static let requiredLoopGateFailureWorkflowName = "required-loop-gate-failure"
    static let noteAutoTaggingWorkflowName = "note-auto-tagging"
    static let notePDFIngestWorkflowName = "note-pdf-ingest"
    static let noteQuickMemoWorkflowName = "note-quick-memo"
    static let noteYouTubeTranscriptWorkflowName = "note-youtube-transcript"
  }

  private enum NodeRuntime {
    static let scriptsDirectoryName = "scripts"
    static let shellScriptExtension = "sh"
    static let nodeInvocationNeedles = ["\nnode ", "\nexec node "]
  }

  private enum WorkflowRunCLI {
    static let workflowRunArgumentsPrefix = ["workflow", "run"]
    static let workflowDefinitionDirFlag = "--workflow-definition-dir"
    static let mockScenarioFlag = "--mock-scenario"
    static let sessionStoreFlag = "--session-store"
    static let maxStepsFlag = "--max-steps"
    static let mockRunMaxSteps = "200"
    static let outputFlag = "--output"
    static let jsonOutputFormat = "json"
    static let autoImproveFlag = "--auto-improve"
  }

  private enum TelegramSDKTrioChatMock {
    static let variables = #"""
    {
      "workflowInput": {
        "text": "@rinacursor0529bot explain the SDK trio setup",
        "provider": "telegram"
      },
      "event": {
        "sourceId": "telegram-live",
        "eventId": "mock-1",
        "provider": "telegram",
        "eventType": "chat.message",
        "input": {
          "text": "@rinacursor0529bot explain the SDK trio setup",
          "provider": "telegram",
          "attachments": [],
          "imagePaths": [],
          "attachmentText": ""
        },
        "conversation": {
          "id": "100",
          "threadId": "topic-a"
        },
        "actor": {
          "id": "200",
          "displayName": "Mock User"
        }
      }
    }
    """#

    static func variables(
      text: String,
      eventId: String,
      memoryRoot: String,
      isBot: Bool = false,
      actorUsername: String? = nil
    ) -> String {
      #"""
      {
        "workflowInput": {
          "text": "\#(text)",
          "provider": "telegram",
          "memoryRoot": "\#(memoryRoot)"
        },
        "memoryRoot": "\#(memoryRoot)",
        "event": {
          "sourceId": "telegram-live",
          "eventId": "\#(eventId)",
          "provider": "telegram",
          "eventType": "chat.message",
          "input": {
            "text": "\#(text)",
            "provider": "telegram",
            "attachments": [],
            "imagePaths": [],
            "attachmentText": ""
          },
          "conversation": {
            "id": "100",
            "threadId": "topic-a"
          },
          "actor": {
            "id": "200",
            "displayName": "Mock User",
            "username": "\#(actorUsername ?? "")",
            "isBot": \#(isBot)
          }
        }
      }
      """#
    }
  }

  private enum TrioChatMemoryMock {
    static func variables(provider: String, text: String, eventId: String, memoryRoot: String) -> String {
      #"""
      {
        "workflowInput": {
          "text": "\#(text)",
          "provider": "\#(provider)",
          "memoryRoot": "\#(memoryRoot)"
        },
        "memoryRoot": "\#(memoryRoot)",
        "event": {
          "sourceId": "\#(provider)-memory-regression",
          "eventId": "\#(eventId)",
          "provider": "\#(provider)",
          "eventType": "chat.message",
          "input": {
            "text": "\#(text)",
            "provider": "\#(provider)",
            "attachments": [],
            "imagePaths": [],
            "attachmentText": ""
          },
          "conversation": {
            "id": "memory-regression",
            "threadId": "topic-memory"
          },
          "actor": {
            "id": "memory-user",
            "displayName": "Memory User",
            "username": "memory-user",
            "isBot": false
          }
        }
      }
      """#
    }
  }

  private enum RawAndDailySummaryMemoryMock {
    static func variables(text: String, eventId: String, receivedAt: String, memoryRoot: String) -> String {
      #"""
      {
        "workflowInput": {
          "provider": "telegram",
          "text": "\#(text)",
          "eventId": "\#(eventId)",
          "conversationId": "chat-1",
          "receivedAt": "\#(receivedAt)",
          "memoryRoot": "\#(memoryRoot)"
        },
        "memoryRoot": "\#(memoryRoot)"
      }
      """#
    }
  }

  func testAllRielaExampleWorkflowsArePortedAndValidateInSwift() throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
    let expectedWorkflowNames = rielaExampleWorkflowNames()
    let actualWorkflowNames = try discoverWorkflowNames(examplesRoot: examplesRoot)

    XCTAssertEqual(actualWorkflowNames, expectedWorkflowNames)

    let resolver = FileSystemWorkflowBundleResolver()
    for workflowName in expectedWorkflowNames {
      let bundle = try resolver.resolve(WorkflowResolutionOptions(
        workflowName: workflowName,
        scope: .direct,
        workflowDefinitionDir: examplesRoot.path,
        workingDirectory: root.path
      ))
      let diagnostics = bundle.diagnostics + DefaultWorkflowValidator().validate(bundle.workflow)
      XCTAssertEqual(diagnostics.filter { $0.severity == .error }, [], workflowName)
      XCTAssertEqual(bundle.workflow.workflowId, expectedWorkflowId(for: workflowName))
    }
  }

  func testMockScenarioExamplesRunThroughSwiftCLI() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
    let app = RielaCLIApplication()
    let mockScenarioExamples = rielaExampleWorkflowNames().filter {
      hasMockScenario(examplesRoot: examplesRoot, workflowName: $0)
    }
    let nodeRuntimeMockScenarioExamples = mockScenarioExamples.filter {
      workflowUsesNodeRuntime(examplesRoot: examplesRoot, workflowName: $0)
    }

    XCTAssertEqual(mockScenarioExamples.count, ExampleCatalog.expectedMockScenarioCount)
    XCTAssertEqual(
      nodeRuntimeMockScenarioExamples.count,
      ExampleCatalog.expectedNodeMockScenarioCount
    )

    for workflowName in mockScenarioExamples {
      let scenario = examplesRoot
        .appendingPathComponent(workflowName, isDirectory: true)
        .appendingPathComponent(MockScenario.fileName)
      let sessionStore = root.appendingPathComponent("tmp/test-example-sessions-\(workflowName)-\(UUID().uuidString)", isDirectory: true)
      addTeardownBlock {
        try? FileManager.default.removeItem(at: sessionStore)
      }
      var arguments = WorkflowRunCLI.workflowRunArgumentsPrefix + [
        workflowName,
        WorkflowRunCLI.workflowDefinitionDirFlag, examplesRoot.path,
        WorkflowRunCLI.mockScenarioFlag, scenario.path,
        WorkflowRunCLI.sessionStoreFlag, sessionStore.path,
        WorkflowRunCLI.maxStepsFlag, WorkflowRunCLI.mockRunMaxSteps,
        WorkflowRunCLI.outputFlag, WorkflowRunCLI.jsonOutputFormat
      ]
      if workflowName == WorkflowIds.supervisedMockRetryWorkflowName {
        arguments.append(WorkflowRunCLI.autoImproveFlag)
      }
      if workflowName == WorkflowIds.telegramSDKTrioChatWorkflowName {
        arguments.append(contentsOf: ["--variables", TelegramSDKTrioChatMock.variables])
      }
      if workflowName == WorkflowIds.chatMemoryRawAndDailySummaryWorkflowName {
        let memoryRoot = root.appendingPathComponent("tmp/test-raw-daily-memory-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
          try? FileManager.default.removeItem(at: memoryRoot)
        }
        arguments.append(contentsOf: [
          "--variables", RawAndDailySummaryMemoryMock.variables(
            text: "parity memory event",
            eventId: "parity-1",
            receivedAt: "2026-06-22T09:00:00Z",
            memoryRoot: memoryRoot.path
          )
        ])
      }
      if let variables = try noteExampleVariables(workflowName: workflowName, root: root) {
        arguments.append(contentsOf: ["--variables", variables])
      }
      let result = await app.run(arguments)

      XCTAssertEqual(result.exitCode, .success, "\(workflowName): \(result.stderr)\n\(result.stdout)")
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(payload.workflowId, workflowName)
      XCTAssertEqual(payload.status, .completed, workflowName)
    }
  }

  func testTelegramSDKTrioChatMentionRoutingProducesRootReplies() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
    let scenario = examplesRoot
      .appendingPathComponent(WorkflowIds.telegramSDKTrioChatWorkflowName, isDirectory: true)
      .appendingPathComponent(MockScenario.fileName)
    let memoryRoot = root.appendingPathComponent("tmp/test-telegram-sdk-trio-chat-memory-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = root.appendingPathComponent("tmp/test-telegram-sdk-trio-chat-sessions-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: memoryRoot)
      try? FileManager.default.removeItem(at: sessionStore)
    }
    let cases = [
      ("rina", "@rinacursor0529bot explain the SDK trio setup", "rina"),
      ("mika", "@mikatrend0529bot give a short plan", "mika"),
      ("rina-about-mika", "@rinacursor0529bot さっきのmikaの回答は?", "rina"),
      ("yui-default", "Please summarize today's plan", "yui"),
      ("concatenated-mika", "Mikausersidecheck.Replyshort.", "yui")
    ]
    let app = RielaCLIApplication()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    for (eventId, text, expectedReplyAs) in cases {
      let result = await app.run(WorkflowRunCLI.workflowRunArgumentsPrefix + [
        WorkflowIds.telegramSDKTrioChatWorkflowName,
        WorkflowRunCLI.workflowDefinitionDirFlag, examplesRoot.path,
        WorkflowRunCLI.mockScenarioFlag, scenario.path,
        WorkflowRunCLI.sessionStoreFlag, sessionStore.path,
        WorkflowRunCLI.outputFlag, WorkflowRunCLI.jsonOutputFormat,
        "--variables", TelegramSDKTrioChatMock.variables(text: text, eventId: eventId, memoryRoot: memoryRoot.path)
      ])

      XCTAssertEqual(result.exitCode, .success, "\(eventId): \(result.stderr)\n\(result.stdout)")
      let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(payload.status, .completed, eventId)
      XCTAssertEqual(payload.rootOutput?["replyAs"], .string(expectedReplyAs), eventId)
      XCTAssertEqual(payload.rootOutput?["status"], .string("ok"), eventId)
    }
  }

  func testTelegramSDKTrioChatAllowsBotAuthoredCrossMentions() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
    let scenario = examplesRoot
      .appendingPathComponent(WorkflowIds.telegramSDKTrioChatWorkflowName, isDirectory: true)
      .appendingPathComponent(MockScenario.fileName)
    let memoryRoot = root.appendingPathComponent("tmp/test-telegram-sdk-trio-chat-memory-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = root.appendingPathComponent("tmp/test-telegram-sdk-trio-chat-sessions-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: memoryRoot)
      try? FileManager.default.removeItem(at: sessionStore)
    }
    let app = RielaCLIApplication()
    let result = await app.run(WorkflowRunCLI.workflowRunArgumentsPrefix + [
      WorkflowIds.telegramSDKTrioChatWorkflowName,
      WorkflowRunCLI.workflowDefinitionDirFlag, examplesRoot.path,
      WorkflowRunCLI.mockScenarioFlag, scenario.path,
      WorkflowRunCLI.sessionStoreFlag, sessionStore.path,
      WorkflowRunCLI.outputFlag, WorkflowRunCLI.jsonOutputFormat,
      "--variables", TelegramSDKTrioChatMock.variables(
        text: "@rinacursor0529bot ここ見て",
        eventId: "bot-authored-rina",
        memoryRoot: memoryRoot.path,
        isBot: true,
        actorUsername: "mikatrend0529bot"
      )
    ])

    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.status, .completed)
    XCTAssertEqual(payload.rootOutput?["replyAs"], .string("rina"))
  }

  func testTelegramSDKTrioChatSkipsSelfAuthoredMentions() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
    let scenario = examplesRoot
      .appendingPathComponent(WorkflowIds.telegramSDKTrioChatWorkflowName, isDirectory: true)
      .appendingPathComponent(MockScenario.fileName)
    let memoryRoot = root.appendingPathComponent("tmp/test-telegram-sdk-trio-chat-memory-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = root.appendingPathComponent("tmp/test-telegram-sdk-trio-chat-sessions-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: memoryRoot)
      try? FileManager.default.removeItem(at: sessionStore)
    }
    let app = RielaCLIApplication()
    let result = await app.run(WorkflowRunCLI.workflowRunArgumentsPrefix + [
      WorkflowIds.telegramSDKTrioChatWorkflowName,
      WorkflowRunCLI.workflowDefinitionDirFlag, examplesRoot.path,
      WorkflowRunCLI.mockScenarioFlag, scenario.path,
      WorkflowRunCLI.sessionStoreFlag, sessionStore.path,
      WorkflowRunCLI.outputFlag, WorkflowRunCLI.jsonOutputFormat,
      "--variables", TelegramSDKTrioChatMock.variables(
        text: "@mikatrend0529bot echo from self",
        eventId: "self-authored-mika",
        memoryRoot: memoryRoot.path,
        isBot: true,
        actorUsername: "mikatrend0529bot"
      )
    ])

    XCTAssertEqual(result.exitCode, .success, "\(result.stderr)\n\(result.stdout)")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.status, .completed)
    XCTAssertNil(payload.rootOutput)
  }

  func testTelegramDiscordAndMatrixTrioChatMemoryReadsAndWrites() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
    let tempDir = root.appendingPathComponent("tmp/test-trio-chat-memory-regression-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: tempDir)
    }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let cases = [
      (WorkflowIds.telegramAgentTrioChatWorkflowName, "telegram", "Telegram seeded Yui memory"),
      (WorkflowIds.discordAgentTrioChatWorkflowName, "discord", "Discord seeded Yui memory"),
      (WorkflowIds.matrixAgentTrioChatWorkflowName, "matrix", "Matrix seeded Yui memory")
    ]
    let app = RielaCLIApplication()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    for (workflowName, provider, seededMemory) in cases {
      let workflowTempDir = tempDir.appendingPathComponent(workflowName, isDirectory: true)
      let memoryRoot = workflowTempDir.appendingPathComponent("memory", isDirectory: true)
      let memoryStore = RielaMemoryStore(rootDirectory: memoryRoot.path)
      try memoryStore.save(
        memoryId: "persona-chat-memory",
        workflowId: workflowName,
        nodeId: "seed-yui-memory",
        registeredAt: "2026-06-22T09:00:00Z",
        tags: ["persona:yui", "kind:user-instruction", "importance:medium"],
        payload: .object([
          "personaId": .string("yui"),
          "personaName": .string("Yui Codex"),
          "kind": .string("user-instruction"),
          "importance": .string("medium"),
          "content": .string(seededMemory),
          "recordedAt": .string("2026-06-22T09:00:00Z")
        ])
      )

      let scenario = try scenarioWithYuiMemoryEntry(
        examplesRoot: examplesRoot,
        workflowName: workflowName,
        outputDirectory: workflowTempDir,
        marker: "\(provider) memory write marker"
      )
      let result = await app.run(WorkflowRunCLI.workflowRunArgumentsPrefix + [
        workflowName,
        WorkflowRunCLI.workflowDefinitionDirFlag, examplesRoot.path,
        WorkflowRunCLI.mockScenarioFlag, scenario.path,
        WorkflowRunCLI.sessionStoreFlag, workflowTempDir.appendingPathComponent("sessions", isDirectory: true).path,
        WorkflowRunCLI.maxStepsFlag, WorkflowRunCLI.mockRunMaxSteps,
        WorkflowRunCLI.outputFlag, WorkflowRunCLI.jsonOutputFormat,
        "--variables", TrioChatMemoryMock.variables(
          provider: provider,
          text: "Yui, remember this \(provider) memory regression",
          eventId: "\(provider)-memory-regression",
          memoryRoot: memoryRoot.path
        )
      ])

      XCTAssertEqual(result.exitCode, .success, "\(workflowName): \(result.stderr)\n\(result.stdout)")
      let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(payload.status, .completed, workflowName)
      let readYuiMemory = try XCTUnwrap(
        payload.session.executions.first { $0.stepId == "read-yui-memory" }?.acceptedOutput?.payload,
        workflowName
      )
      XCTAssertEqual(jsonNumber(readYuiMemory["memoryRecordCount"]), 1, workflowName)
      XCTAssertTrue(jsonString(readYuiMemory["memoryMarkdown"])?.contains(seededMemory) == true, workflowName)
      let writeYuiMemory = try XCTUnwrap(
        payload.session.executions.first { $0.stepId == "write-yui-memory" }?.acceptedOutput?.payload,
        workflowName
      )
      guard case let .object(memorySummary)? = writeYuiMemory["memory"] else {
        return XCTFail("\(workflowName): write-yui-memory did not return memory summary")
      }
      XCTAssertEqual(jsonNumber(memorySummary["entriesWritten"]), 1, workflowName)
      let writtenMemory = try memoryStore.search(
        memoryId: "persona-chat-memory",
        options: MemorySearchOptions(
          workflowId: workflowName,
          includeAllWorkflows: true,
          tags: ["persona:yui"],
          limit: 10
        )
      )
      XCTAssertEqual(writtenMemory.count, 2, workflowName)
      XCTAssertTrue(writtenMemory.contains { record in
        memoryString(objectPayload(record.payload)?["content"]) == "\(provider) memory write marker"
      }, workflowName)
    }
  }

  func testRawLogAndDailySummaryMemoryExampleCreatesAndUpdatesSeparateDatabases() async throws {
    let root = repositoryRoot()
    let examplesRoot = root.appendingPathComponent(ExampleCatalog.directoryName, isDirectory: true)
    let workflowName = WorkflowIds.chatMemoryRawAndDailySummaryWorkflowName
    let scenario = examplesRoot
      .appendingPathComponent(workflowName, isDirectory: true)
      .appendingPathComponent(MockScenario.fileName)
    let memoryRoot = root.appendingPathComponent("tmp/test-raw-daily-summary-memory-\(UUID().uuidString)", isDirectory: true)
    let sessionStore = root.appendingPathComponent("tmp/test-raw-daily-summary-sessions-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: memoryRoot)
      try? FileManager.default.removeItem(at: sessionStore)
    }
    let app = RielaCLIApplication()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let events = [
      ("first message", "raw-daily-1", "2026-06-22T09:00:00Z", "created"),
      ("second message", "raw-daily-2", "2026-06-22T10:00:00Z", "updated")
    ]
    var summaryRecordIds: [Int64] = []

    for (text, eventId, receivedAt, expectedAction) in events {
      let result = await app.run(WorkflowRunCLI.workflowRunArgumentsPrefix + [
        workflowName,
        WorkflowRunCLI.workflowDefinitionDirFlag, examplesRoot.path,
        WorkflowRunCLI.mockScenarioFlag, scenario.path,
        WorkflowRunCLI.sessionStoreFlag, sessionStore.path,
        WorkflowRunCLI.outputFlag, WorkflowRunCLI.jsonOutputFormat,
        "--variables", RawAndDailySummaryMemoryMock.variables(
          text: text,
          eventId: eventId,
          receivedAt: receivedAt,
          memoryRoot: memoryRoot.path
        )
      ])

      XCTAssertEqual(result.exitCode, .success, "\(eventId): \(result.stderr)\n\(result.stdout)")
      let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(payload.status, .completed, eventId)
      XCTAssertEqual(payload.rootOutput?["summaryAction"], .string(expectedAction), eventId)
      if let exact = payload.rootOutput?["summaryRecordId"]?.asInt64 {
        summaryRecordIds.append(exact)
      } else {
        XCTFail("\(eventId): missing summaryRecordId")
      }
    }

    XCTAssertEqual(Set(summaryRecordIds).count, 1)
    let store = RielaMemoryStore(rootDirectory: memoryRoot.path)
    let rawRecords = try store.search(
      memoryId: "raw-chat-log",
      options: MemorySearchOptions(workflowId: workflowName, sortOrder: .registeredAsc, limit: 10)
    )
    let summaryRecords = try store.search(
      memoryId: "daily-chat-summary",
      options: MemorySearchOptions(workflowId: workflowName, tags: ["summary:telegram:chat-1:2026-06-22"], limit: 10)
    )

    XCTAssertEqual(rawRecords.count, 2)
    XCTAssertEqual(summaryRecords.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try store.databasePath(memoryId: "raw-chat-log")))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try store.databasePath(memoryId: "daily-chat-summary")))
    XCTAssertEqual(memoryNumber(objectPayload(summaryRecords[0].payload)?["rawRecordCount"]), 2)
    XCTAssertTrue(memoryString(objectPayload(summaryRecords[0].payload)?["summary"])?.contains("first message") == true)
    XCTAssertTrue(memoryString(objectPayload(summaryRecords[0].payload)?["summary"])?.contains("second message") == true)
    XCTAssertEqual(try store.metadata(memoryId: "raw-chat-log")?.purpose, "save every incoming chat event as raw evidence")
    XCTAssertEqual(
      try store.metadata(memoryId: "daily-chat-summary")?.purpose,
      "save or update the compact daily summary for this conversation"
    )
  }

  func testMatrixGatewayPayloadFixtureMatchesEventBinding() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-matrix-event-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let eventRoot = tempDir.appendingPathComponent("events", isDirectory: true)
    let sourcesRoot = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindingsRoot = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sourcesRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindingsRoot, withIntermediateDirectories: true)
    try """
    {
      "id": "team-matrix",
      "kind": "matrix",
      "provider": "matrix"
    }
    """.write(to: sourcesRoot.appendingPathComponent("team-matrix.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "matrix-agent-trio-to-workflow",
      "sourceId": "team-matrix",
      "match": {
        "eventType": "chat.message",
        "conversationId": "!persona:matrix.example"
      },
      "workflowName": "matrix-agent-trio-chat",
      "inputMapping": {"mode": "event-input"}
    }
    """.write(
      to: bindingsRoot.appendingPathComponent("matrix-agent-trio-to-workflow.json"),
      atomically: true,
      encoding: .utf8
    )
    let eventFile = repositoryRoot()
      .appendingPathComponent("examples/event-sources/payloads/matrix-persona-message.json")
    let result = await RielaCLIApplication().run([
      "events", "emit", "team-matrix",
      "--event-root", eventRoot.path,
      "--event-file", eventFile.path,
      "--read-only",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let scoped = try JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(scoped.status, "ok")
    XCTAssertTrue(scoped.records.contains("status=dry-run"), scoped.records.joined(separator: "\n"))
  }

  func testTelegramGatewayPhotoFixtureMatchesEventBindingAndPreservesAttachmentMetadata() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-telegram-photo-event-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let eventRoot = tempDir.appendingPathComponent("events", isDirectory: true)
    let sourcesRoot = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindingsRoot = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sourcesRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindingsRoot, withIntermediateDirectories: true)
    try """
    {
      "id": "telegram-gateway-personas",
      "kind": "telegram-gateway",
      "provider": "telegram"
    }
    """.write(to: sourcesRoot.appendingPathComponent("telegram-gateway-personas.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "telegram-gateway-personas-to-workflow",
      "sourceId": "telegram-gateway-personas",
      "match": {
        "eventType": "chat.message"
      },
      "workflowName": "telegram-agent-trio-chat",
      "inputMapping": {"mode": "event-input"}
    }
    """.write(
      to: bindingsRoot.appendingPathComponent("telegram-gateway-personas-to-workflow.json"),
      atomically: true,
      encoding: .utf8
    )
    let eventFile = repositoryRoot()
      .appendingPathComponent("examples/event-sources/payloads/telegram-gateway-photo-message.json")
    let result = await RielaCLIApplication().run([
      "events", "emit", "telegram-gateway-personas",
      "--event-root", eventRoot.path,
      "--event-file", eventFile.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let scoped = try JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(scoped.status, "ok")
    XCTAssertTrue(scoped.records.contains("status=dry-run"), scoped.records.joined(separator: "\n"))
    let receiptURL = try XCTUnwrap(
      FileManager.default.enumerator(at: eventRoot.appendingPathComponent("receipts"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .first { $0.pathExtension == "json" }
    )
    let receipt = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: receiptURL))
    let receiptObject = try XCTUnwrap(jsonObject(receipt))
    let envelope = try XCTUnwrap(jsonObject(receiptObject["envelope"]))
    let input = try XCTUnwrap(jsonObject(envelope["input"]))
    XCTAssertEqual(input["text"], .string("Yui, summarize this image and ask Mika too."))
    XCTAssertEqual(input["attachmentText"], .string("Yui, summarize this image and ask Mika too."))
    let attachments = try XCTUnwrap(jsonArray(input["attachments"]))
    let attachment = try XCTUnwrap(jsonObject(attachments.first))
    XCTAssertEqual(attachment["kind"], .string("photo"))
    XCTAssertEqual(attachment["provider"], .string("telegram"))
    XCTAssertEqual(attachment["fileId"], .string("telegram-large-photo"))
    XCTAssertEqual(attachment["width"], .number(1280))
    XCTAssertEqual(attachment["height"], .number(720))
  }

  private func rielaExampleWorkflowNames() -> [String] {
    [
      "apple-calendar-fetch",
      "apple-clock-alarms-list",
      "apple-gateway-admin",
      "apple-gateway-packaging-plan",
      "apple-mail-list",
      "apple-note-create",
      "apple-note-read",
      "apple-notes-list",
      "apple-notifications",
      "apple-reminders-list",
      "chat-event-attachment-judgement",
      "chat-memory-raw-and-daily-summary",
      "chat-reply-webhook",
      "chat-supervisor-collaboration",
      "claude-riela-claude-worker",
      "claude-riela-codex-coding",
      "codex-codex-topic-debate",
      "default-superviser",
      "design-and-implement-review-loop",
      "design-and-implement-review-loop-feature-plan",
      "discord-agent-trio-chat",
      "discord-codex-chat",
      "discord-persona-chat",
      "dispatcher-llm-resolver-stub",
      "first-four-arithmetic-pipeline",
      "gemini-ocr-worker",
      "gemini-sdk-worker",
      "gmail-latest-mail-digest-telegram",
      "loop-engineer-quality-loop",
      "matrix-agent-trio-chat",
      "matrix-chat-reply",
      "node-combinations-showcase",
      "note-agent",
      "note-auto-tagging",
      "note-config-agent",
      "note-edit-rewrite",
      "note-link-extract",
      "note-pdf-ingest",
      "note-quick-memo",
      "note-selection-question",
      "note-youtube-transcript",
      "recent-change-quality-loop",
      "required-loop-gate-failure",
      "riela-default-workflow-supervisor",
      "same-node-session-echo",
      "scheduled-sleep",
      "seatbelt-sandboxed-worker",
      "shared-agent-trio-personas",
      "slack-agent-trio-chat",
      "slack-codex-chat",
      "subworkflow-chained-simple",
      "supervised-mock-retry",
      "telegram-agent-trio-chat",
      "telegram-agent-trio-time-signal",
      "telegram-sdk-trio-chat",
      "worker-only-single-step",
      "workflow-call-live-echo",
      "workflow-call-live-echo-callee",
      "workflow-call-review-target",
      "workflow-call-simple",
      "x-follower-ai-business-digest"
    ]
  }

  private func expectedWorkflowId(for workflowName: String) -> String {
    workflowName == WorkflowIds.defaultSuperviserWorkflowName
      ? WorkflowIds.defaultSuperviserWorkflowId
      : workflowName
  }

  private func discoverWorkflowNames(examplesRoot: URL) throws -> [String] {
    let contents = try FileManager.default.contentsOfDirectory(
      at: examplesRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    return try contents.compactMap { url -> String? in
      guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        return nil
      }
      let workflowPath = url.appendingPathComponent(WorkflowPackage.manifestFileName).path
      guard FileManager.default.fileExists(atPath: workflowPath) else {
        return nil
      }
      return url.lastPathComponent
    }.sorted()
  }

  private func hasMockScenario(examplesRoot: URL, workflowName: String) -> Bool {
    let scenario = examplesRoot
      .appendingPathComponent(workflowName, isDirectory: true)
      .appendingPathComponent(MockScenario.fileName)
    return FileManager.default.fileExists(atPath: scenario.path)
  }

  private func workflowUsesNodeRuntime(examplesRoot: URL, workflowName: String) -> Bool {
    let scriptsRoot = examplesRoot
      .appendingPathComponent(workflowName, isDirectory: true)
      .appendingPathComponent(NodeRuntime.scriptsDirectoryName, isDirectory: true)
    guard
      let scripts = try? FileManager.default.contentsOfDirectory(
        at: scriptsRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return false
    }
    return scripts.contains { script in
      guard
        script.pathExtension == NodeRuntime.shellScriptExtension,
        let text = try? String(contentsOf: script, encoding: .utf8)
      else {
        return false
      }
      return NodeRuntime.nodeInvocationNeedles.contains { text.contains($0) }
    }
  }

  private func scenarioWithYuiMemoryEntry(
    examplesRoot: URL,
    workflowName: String,
    outputDirectory: URL,
    marker: String
  ) throws -> URL {
    let scenarioPath = examplesRoot
      .appendingPathComponent(workflowName, isDirectory: true)
      .appendingPathComponent(MockScenario.fileName)
    let data = try Data(contentsOf: scenarioPath)
    guard var scenario = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      var yuiNode = scenario["yui-codex"] as? [String: Any],
      var yuiPayload = yuiNode["payload"] as? [String: Any] else {
      throw XCTSkip("scenario is not object-shaped: \(workflowName)")
    }
    yuiPayload["memoryEntries"] = [[
      "kind": "user-instruction",
      "importance": "medium",
      "source": "memory-regression",
      "content": marker
    ]]
    yuiNode["payload"] = yuiPayload
    scenario["yui-codex"] = yuiNode
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let outputPath = outputDirectory.appendingPathComponent("mock-scenario-with-memory.json")
    let outputData = try JSONSerialization.data(withJSONObject: scenario, options: [.prettyPrinted, .sortedKeys])
    try outputData.write(to: outputPath)
    return outputPath
  }

  private func jsonString(_ value: JSONValue?) -> String? {
    guard case let .string(string)? = value else {
      return nil
    }
    return string
  }

  private func jsonNumber(_ value: JSONValue?) -> Int? {
    guard let int64 = value?.asInt64 else {
      return nil
    }
    return Int(exactly: int64)
  }

  private func objectPayload(_ value: MemoryJSONValue) -> [String: MemoryJSONValue]? {
    guard case let .object(object) = value else {
      return nil
    }
    return object
  }

  private func memoryString(_ value: MemoryJSONValue?) -> String? {
    guard case let .string(string)? = value else {
      return nil
    }
    return string
  }

  private func memoryNumber(_ value: MemoryJSONValue?) -> Int? {
    guard case let .number(number)? = value, number.rounded() == number else {
      return nil
    }
    return Int(number)
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(RepositoryPackage.manifestFileName).path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}
