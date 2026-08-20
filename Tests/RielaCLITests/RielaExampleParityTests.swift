import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

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
    "enterprise-matrix-agent-personas",
    "enterprise-matrix-customer-escalation",
    "enterprise-matrix-security-incident",
    "enterprise-matrix-vendor-onboarding",
    "file-markdown-convert",
    "first-four-arithmetic-pipeline",
    "gemini-ocr-worker",
    "gemini-sdk-worker",
    "gmail-latest-mail-digest-telegram",
    "kaiba-document-intake",
    "loop-baseline-regression-ops",
    "loop-budget-guard",
    "loop-ci-gate-check",
    "loop-concurrency-lease",
    "loop-engineer-quality-loop",
    "loop-outcome-notifications",
    "loop-stall-guard",
    "matrix-agent-trio-chat",
    "matrix-chat-reply",
    "memory-consolidation",
    "node-combinations-showcase",
    "note-agent",
    "note-link-extract",
    "open-model-provider-codex",
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
    "workflow-knowledge-base",
    "wrike-project-kanban-agent",
    "x-follower-ai-business-digest",
    "x-incremental-posts-kv"
  ]
}

final class RielaExampleParityTests: XCTestCase {
  private enum RepositoryPackage {
    static let manifestFileName = "Package.swift"
  }

  private enum ExampleCatalog {
    static let directoryName = "examples"
    static let expectedMockScenarioCount = 35
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
    static func variables(
      text: String = "@rinacursor0529bot explain the SDK trio setup",
      eventId: String = "mock-1",
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

  /// The graph-RAG examples drive the `kaiba/*` retrieval add-ons for real (only
  /// their agent step is mocked), so the mock run needs a note root that already
  /// contains a bounded graph. Seeding `subject -> hop-one -> hop-two` lets the
  /// traversal return actual neighbors instead of failing on missing input.
  private enum GraphRAGExampleFixture {
    static let workflowNames: Set<String> = ["note-agent", "note-link-extract"]

    /// Seeded through the `kaiba/*` add-ons rather than kaiba's own API: the
    /// CLI test target does not link kaiba, and going through the same nodes
    /// the examples use keeps the fixture honest.
    static func variables(noteRoot: String, workflowName: String) async throws -> String {
      try FileManager.default.createDirectory(
        atPath: noteRoot,
        withIntermediateDirectories: true
      )
      let subject = try await createNote(noteRoot: noteRoot, body: "# Subject\n\nprojectalpha kickoff planning")
      let hopOne = try await createNote(noteRoot: noteRoot, body: "# Hop One\n\nprojectalpha design decisions")
      let hopTwo = try await createNote(noteRoot: noteRoot, body: "# Hop Two\n\nrollout notes")
      try await linkNotes(noteRoot: noteRoot, from: subject, to: hopOne)
      try await linkNotes(noteRoot: noteRoot, from: hopOne, to: hopTwo)
      let input: [String: Any] = workflowName == "note-link-extract"
        ? ["noteId": subject, "limit": 8]
        : ["query": "projectalpha", "limit": 5]
      let payload: [String: Any] = ["noteRoot": noteRoot, "workflowInput": input]
      let data = try JSONSerialization.data(withJSONObject: payload)
      return String(decoding: data, as: UTF8.self)
    }

    private static func createNote(noteRoot: String, body: String) async throws -> String {
      let output = try await execute(
        addon: "kaiba/note-create",
        config: ["noteRoot": .string(noteRoot), "bodyMarkdown": .string(body)]
      )
      guard case let .string(noteId)? = output.payload["noteId"] else {
        throw CLIUsageError("kaiba/note-create returned no noteId")
      }
      return noteId
    }

    private static func linkNotes(noteRoot: String, from: String, to: String) async throws {
      _ = try await execute(
        addon: "kaiba/note-graphql-document",
        config: [
          "noteRoot": .string(noteRoot),
          "query": .string(
            "mutation Link($input: LinkNotesInput!) { linkNotes(input: $input) { result { accepted } link { fromNoteId toNoteId } } }"
          ),
          "variables": .object([
            "input": .object(["fromNoteId": .string(from), "toNoteId": .string(to)])
          ])
        ]
      )
    }

    private static func execute(
      addon: String,
      config: RielaCore.JSONObject
    ) async throws -> AdapterExecutionOutput {
      try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
        WorkflowAddonExecutionInput(
          workflowId: "graph-rag-fixture",
          stepId: "seed",
          nodeId: "seed",
          addon: WorkflowNodeAddonRef(name: addon, version: "1", config: config),
          resolvedInputPayload: [:]
        ),
        context: AdapterExecutionContext()
      )
    }
  }

  /// The consolidation example writes to both memory stores for real (only its
  /// summarizer step is mocked), so the mock run needs a scratch riela memory
  /// root and a scratch kaiba note root instead of `.riela/memory` and
  /// `~/.kaiba`.
  private enum MemoryConsolidationExampleFixture {
    static let workflowName = "memory-consolidation"

    static func variables(memoryRoot: String, noteRoot: String) throws -> String {
      let payload: [String: Any] = [
        "memoryRoot": memoryRoot,
        "noteRoot": noteRoot,
        "workflowInput": [
          "text": "Kickoff review settled the project-atlas scope.",
          "actor": "taco",
          "conversationId": "example-conversation",
          "consolidationKey": "memory-consolidation-example-2026-08-01"
        ]
      ]
      let data = try JSONSerialization.data(withJSONObject: payload)
      return String(decoding: data, as: UTF8.self)
    }
  }

  private enum WorkflowKnowledgeBaseExampleFixture {
    static let workflowName = "workflow-knowledge-base"

    static func variables(memoryRoot: String, noteRoot: String) throws -> String {
      let payload: [String: Any] = [
        "memoryRoot": memoryRoot,
        "noteRoot": noteRoot,
        "workflowInput": [
          "task": "Implement retry handling for the flaky sync API client.",
          "knowledgeQuery": "backoff",
          "runKey": "workflow-knowledge-base-example-2026-08-21"
        ]
      ]
      let data = try JSONSerialization.data(withJSONObject: payload)
      return String(decoding: data, as: UTF8.self)
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
        let memoryRoot = sessionStore.appendingPathComponent("memory", isDirectory: true)
        arguments.append(contentsOf: [
          "--variables",
          TelegramSDKTrioChatMock.variables(memoryRoot: memoryRoot.path)
        ])
      }
      if workflowName.hasPrefix("enterprise-matrix-") {
        let memoryRoot = sessionStore.appendingPathComponent("memory", isDirectory: true)
        arguments.append(contentsOf: [
          "--variables",
          #"{"memoryRoot":"\#(memoryRoot.path)","workflowInput":{"memoryRoot":"\#(memoryRoot.path)"}}"#
        ])
      }
      if workflowName == MemoryConsolidationExampleFixture.workflowName {
        arguments.append(contentsOf: [
          "--variables",
          try MemoryConsolidationExampleFixture.variables(
            memoryRoot: sessionStore.appendingPathComponent("memory", isDirectory: true).path,
            noteRoot: sessionStore.appendingPathComponent("notes", isDirectory: true).path
          )
        ])
      }
      if workflowName == WorkflowKnowledgeBaseExampleFixture.workflowName {
        arguments.append(contentsOf: [
          "--variables",
          try WorkflowKnowledgeBaseExampleFixture.variables(
            memoryRoot: sessionStore.appendingPathComponent("memory", isDirectory: true).path,
            noteRoot: sessionStore.appendingPathComponent("notes", isDirectory: true).path
          )
        ])
      }
      if GraphRAGExampleFixture.workflowNames.contains(workflowName) {
        let noteRoot = sessionStore.appendingPathComponent("notes", isDirectory: true)
        arguments.append(contentsOf: [
          "--variables",
          try await GraphRAGExampleFixture.variables(noteRoot: noteRoot.path, workflowName: workflowName)
        ])
      }
      let generatedWorkflowHome = sessionStore.appendingPathComponent("home", isDirectory: true)
      let result: CLICommandResult
      if workflowName.hasPrefix("enterprise-matrix-") {
        try FileManager.default.createDirectory(at: generatedWorkflowHome, withIntermediateDirectories: true)
        result = await CLIRuntimeEnvironment.$overrides.withValue(["HOME": generatedWorkflowHome.path]) {
          await app.run(arguments)
        }
      } else {
        result = await app.run(arguments)
      }

      XCTAssertEqual(result.exitCode, .success, "\(workflowName): \(result.stderr)\n\(result.stdout)")
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let payload = try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(payload.workflowId, workflowName)
      XCTAssertEqual(payload.status, .completed, workflowName)
      if workflowName == "enterprise-matrix-security-incident" {
        let generated = try XCTUnwrap(
          payload.session.executions.first { $0.stepId == "generate-incident-lead-workflow" }?
            .acceptedOutput?.payload,
          workflowName
        )
        XCTAssertEqual(generated["generatedWorkflowRegistered"], .bool(true))
        XCTAssertEqual(generated["generatedWorkflowExecuted"], .bool(true))
        let generatedWorkflowId = try XCTUnwrap(jsonString(generated["generatedWorkflowId"]))
        let registered = generatedWorkflowHome
          .appendingPathComponent(".riela/temporary-workflows", isDirectory: true)
          .appendingPathComponent(generatedWorkflowId, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: registered.appendingPathComponent("workflow.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
          atPath: registered.appendingPathComponent("prompts/task-worker.md").path
        ))
      }
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

  func testEnterpriseMatrixRoomFixturesMatchTheirWorkflowBindings() async throws {
    let sourceEventRoot = repositoryRoot()
      .appendingPathComponent("examples/event-sources/.riela-events", isDirectory: true)
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-enterprise-matrix-events-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let eventRoot = tempDir.appendingPathComponent("events", isDirectory: true)
    for directory in ["sources", "bindings", "destinations"] {
      try FileManager.default.createDirectory(
        at: eventRoot.appendingPathComponent(directory, isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    try FileManager.default.copyItem(
      at: sourceEventRoot.appendingPathComponent("sources/enterprise-matrix.json"),
      to: eventRoot.appendingPathComponent("sources/enterprise-matrix.json")
    )
    let fixtures = [
      (
        room: "security",
        payload: "enterprise-matrix-security-message.json",
        binding: "enterprise-matrix-security-to-workflow.json",
        conversationId: "!security-incident:matrix.example",
        workflowName: "enterprise-matrix-security-incident"
      ),
      (
        room: "vendor",
        payload: "enterprise-matrix-vendor-message.json",
        binding: "enterprise-matrix-vendor-to-workflow.json",
        conversationId: "!vendor-onboarding:matrix.example",
        workflowName: "enterprise-matrix-vendor-onboarding"
      ),
      (
        room: "customer",
        payload: "enterprise-matrix-customer-message.json",
        binding: "enterprise-matrix-customer-to-workflow.json",
        conversationId: "!customer-escalation:matrix.example",
        workflowName: "enterprise-matrix-customer-escalation"
      )
    ]

    for fixture in fixtures {
      try FileManager.default.copyItem(
        at: sourceEventRoot.appendingPathComponent("bindings").appendingPathComponent(fixture.binding),
        to: eventRoot.appendingPathComponent("bindings").appendingPathComponent(fixture.binding)
      )
      let destination = fixture.binding.replacingOccurrences(of: "-to-workflow.json", with: "-replies.json")
      try FileManager.default.copyItem(
        at: sourceEventRoot.appendingPathComponent("destinations").appendingPathComponent(destination),
        to: eventRoot.appendingPathComponent("destinations").appendingPathComponent(destination)
      )
    }

    for fixture in fixtures {
      let payloadURL = repositoryRoot()
        .appendingPathComponent("examples/event-sources/payloads")
        .appendingPathComponent(fixture.payload)
      let result = await RielaCLIApplication().run([
        "events", "emit", "enterprise-matrix",
        "--event-root", eventRoot.path,
        "--event-file", payloadURL.path,
        "--read-only",
        "--output", "json"
      ])

      XCTAssertEqual(result.exitCode, .success, "\(fixture.room): \(result.stderr)")
      let scoped = try JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(scoped.status, "ok", fixture.room)
      XCTAssertTrue(scoped.records.contains("status=dry-run"), fixture.room)

      let payload = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(contentsOf: payloadURL)) as? [String: Any]
      )
      XCTAssertEqual(payload["room_id"] as? String, fixture.conversationId, fixture.room)

      let bindingURL = sourceEventRoot
        .appendingPathComponent("bindings")
        .appendingPathComponent(fixture.binding)
      let binding = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(contentsOf: bindingURL)) as? [String: Any]
      )
      let match = try XCTUnwrap(binding["match"] as? [String: Any])
      XCTAssertEqual(match["conversationId"] as? String, fixture.conversationId, fixture.room)
      XCTAssertEqual(binding["workflowName"] as? String, fixture.workflowName, fixture.room)
    }
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

  private func jsonString(_ value: RielaCore.JSONValue?) -> String? {
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
