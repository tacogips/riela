import Foundation
import RielaAdapters
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

// swiftlint:disable:next type_body_length
final class WorkflowCommandTests: XCTestCase {
  func testTopLevelHelpReturnsSuccessfulSmokeOutput() async {
    let result = await RielaCLIApplication().run(["--help"])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    XCTAssertTrue(result.stdout.contains("workflow validate"))
    XCTAssertTrue(result.stdout.contains("workflow run <workflow> [--variables <json|@file>]"))
    XCTAssertTrue(result.stdout.contains("Swift CLI is the production Homebrew runtime"))
    XCTAssertFalse(result.stdout.contains("TypeScript/Bun"))
    XCTAssertFalse(result.stdout.contains("cutover gates pass"))
  }

  func testValidateInspectAndDeterministicRunWorkerFixture() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-worker-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }
    let app = RielaCLIApplication()

    let validate = await app.run([
      "workflow", "validate", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .success)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertTrue(validation.valid)
    XCTAssertEqual(validation.workflowId, "worker-only-single-step")
    XCTAssertEqual(validation.sourceScope, .direct)

    let inspect = await app.run([
      "workflow", "inspect", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--output", "json",
      "--structure"
    ])
    XCTAssertEqual(inspect.exitCode, .success)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    XCTAssertEqual(summary.entryStepId, "main-worker")
    XCTAssertEqual(summary.stepIds, ["main-worker"])
    XCTAssertEqual(summary.counts.steps, 1)
    XCTAssertEqual(summary.counts.crossWorkflowDispatches, 0)

    let run = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--variables", #"{"workflowInput":{"request":"noop reproduction for CLI variables handling"}}"#,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success)
    let result = try decodeJSON(WorkflowRunResult.self, from: run.stdout)
    XCTAssertEqual(result.workflowId, "worker-only-single-step")
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.nodeExecutions, 1)
    XCTAssertEqual(result.transitions, 0)
    XCTAssertEqual(result.rootOutput?["status"], .string("ready"))
  }

  func testWorkflowRunDefaultsToJSONLEventsWithImmediateSessionRecord() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-jsonl-default-session-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }
    let run = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--variables", #"{"workflowInput":{"request":"noop reproduction for CLI variables handling"}}"#,
      "--session-store", sessionStore.path
    ])

    XCTAssertEqual(run.exitCode, .success)
    XCTAssertTrue(run.stderr.isEmpty)
    let lines = run.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 6)

    let first = try decodeJSON(WorkflowRunEvent.self, from: lines[0])
    XCTAssertEqual(first.type, .sessionStarted)
    XCTAssertEqual(first.workflowId, "worker-only-single-step")
    XCTAssertTrue(first.sessionId.hasPrefix("worker-only-single-step-session-"))

    let context = try decodeJSON(WorkflowRunContextRecord.self, from: lines[1])
    XCTAssertEqual(context.type, "run_context")
    XCTAssertEqual(context.sessionId, first.sessionId)
    XCTAssertEqual(context.workflowName, "worker-only-single-step")
    XCTAssertEqual(context.sessionStore, sessionStore.path)

    let final = try decodeJSON(WorkflowRunResultRecord.self, from: lines[5])
    XCTAssertEqual(final.type, "run_result")
    XCTAssertEqual(final.result.status, .completed)
    XCTAssertEqual(final.result.rootOutput?["status"], .string("ready"))
  }

  func testWorkflowRunJSONLWriterPersistsSessionBeforeStartRecordIsEmitted() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-jsonl-live-session-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }
    let probe = JSONLWriterProbe(sessionStore: sessionStore)
    let app = RielaCLIApplication(
      runCommand: WorkflowRunCommand(jsonlRecordWriter: { line in
        probe.record(line)
      })
    )

    let run = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore.path
    ])

    XCTAssertEqual(run.exitCode, .success)
    XCTAssertTrue(run.stdout.isEmpty)
    XCTAssertTrue(run.stderr.isEmpty)
    XCTAssertTrue(probe.persistedAtSessionStart())
    XCTAssertEqual(probe.lines().count, 6)
    let canonicalDatabasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    )
    XCTAssertEqual(CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionStore.path), canonicalDatabasePath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDatabasePath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionStore.appendingPathComponent("cli-workflow-sessions.sqlite").path))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sessionStore.path).allSatisfy { !$0.hasSuffix(".json") })
  }

  func testWorkflowRunJSONLFailureIncludesBufferedProgressRecords() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-jsonl-buffered-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }

    let run = await RielaCLIApplication().run([
      "workflow", "run", "recent-change-quality-loop",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/recent-change-quality-loop/mock-scenario.json",
      "--session-store", sessionStore.path,
      "--max-steps", "1",
      "--output", "jsonl"
    ])

    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stderr.isEmpty)
    let lines = run.stdout.split(separator: "\n").map(String.init)
    XCTAssertGreaterThanOrEqual(lines.count, 4)

    let first = try decodeJSON(WorkflowRunEvent.self, from: lines[0])
    XCTAssertEqual(first.type, .sessionStarted)
    XCTAssertEqual(first.workflowId, "recent-change-quality-loop")

    let context = try decodeJSON(WorkflowRunContextRecord.self, from: lines[1])
    XCTAssertEqual(context.type, "run_context")
    XCTAssertEqual(context.sessionId, first.sessionId)
    XCTAssertEqual(context.workflowName, "recent-change-quality-loop")
    XCTAssertEqual(context.sessionStore, sessionStore.path)

    XCTAssertTrue(lines.contains { $0.contains(#""type":"session_completed""#) })
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: lines[lines.count - 1])
    XCTAssertEqual(failure.sessionId, first.sessionId)
    XCTAssertEqual(failure.failureKind, .maxStepsExceeded)
    XCTAssertEqual(failure.stepBudgetDiagnostic?.stepBudget, 1)
  }

  func testUsageSupportsAddonSmokeWorkflow() async throws {
    let root = repositoryRoot()
    let result = await RielaCLIApplication().run([
      "workflow", "usage", "matrix-chat-reply",
      "--workflow-definition-dir", "\(root)/examples",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: result.stdout)
    XCTAssertEqual(summary.workflowId, "matrix-chat-reply")
    XCTAssertTrue(summary.addonSourceSummaries.contains("reply-to-matrix:riela/chat-reply-worker"))
  }

  func testBuiltinChatReplyWorkerRendersInboxTemplateAndPreservesHandoffFlags() async throws {
    let output = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-trio",
        stepId: "send-yui-reply",
        nodeId: "send-yui-reply",
        addon: WorkflowNodeAddonRef(
          name: "riela/chat-reply-worker",
          version: "1",
          config: [
            "textTemplate": .string("{{inbox.latest.output.payload.replyText}}"),
            "replyAsTemplate": .string("{{replyAs}}")
          ]
        ),
        variables: [:],
        resolvedInputPayload: [
          "replyAs": .string("yui"),
          "replyText": .string("Yui reply"),
          "handoff_mika": .bool(true),
          "handoff_rina": .bool(false)
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["replyText"], .string("Yui reply"))
    XCTAssertEqual(output.payload["text"], .string("Yui reply"))
    XCTAssertEqual(output.payload["replyAs"], .string("yui"))
    XCTAssertEqual(output.payload["dispatchStatus"], .string("intent-only"))
    XCTAssertEqual(output.when["handoff_mika"], true)
    XCTAssertEqual(output.when["handoff_rina"], false)
  }

  func testBuiltinMemoryAddonsSaveLoadAndSearchWorkflowScopedRecords() async throws {
    let root = repositoryRoot()
    let memoryRoot = "\(root)/tmp/test-builtin-memory-addons-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    try FileManager.default.createDirectory(atPath: memoryRoot, withIntermediateDirectories: true)
    let sourceFile = URL(fileURLWithPath: memoryRoot).appendingPathComponent("source-yui.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceFile)
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let saveAddon = WorkflowNodeAddonRef(
      name: "riela/memory-save",
      version: "1",
      config: [
        "memoryId": .string("chat-memory"),
        "nodeId": .string("chat-event"),
        "tags": .array([.string("chat"), .string("routing")]),
        "filePaths": .array([.string(sourceFile.path)]),
        "payloadTemplate": .object([
          "text": .string("{{event.input.text}}"),
          "conversationId": .string("{{event.conversation.id}}")
        ])
      ]
    )

    let save = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "save-chat-event-memory",
        nodeId: "save-chat-event-memory",
        addon: saveAddon,
        variables: [
          "workflowInput": .object(["memoryRoot": .string(memoryRoot)]),
          "event": .object([
            "input": .object(["text": .string("Yui, remember the routing test")]),
            "conversation": .object(["id": .string("chat-1")])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(save.payload["saved"], .bool(true))
    XCTAssertEqual(save.payload["memoryId"], .string("chat-memory"))
    guard
      case let .object(savedRecord)? = save.payload["record"],
      case let .object(savedPayload)? = savedRecord["payload"]
    else {
      return XCTFail("memory-save record payload was not returned")
    }
    XCTAssertEqual(savedRecord["tags"], .array([.string("chat"), .string("routing")]))
    guard case let .array(savedFiles)? = savedRecord["files"],
      case let .object(savedFile)? = savedFiles.first else {
      return XCTFail("memory-save record files were not returned")
    }
    XCTAssertEqual(savedFile["kind"], .string("image"))
    guard case let .string(savedFilePath)? = savedFile["path"] else {
      return XCTFail("memory-save record file path was not returned")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: savedFilePath))
    XCTAssertEqual(savedPayload["text"], .string("Yui, remember the routing test"))
    XCTAssertEqual(savedPayload["conversationId"], .string("chat-1"))
    guard let savedRecordId = savedRecord["recordId"]?.asInt64 else {
      return XCTFail("memory-save record id was not returned")
    }

    let update = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "update-chat-event-memory",
        nodeId: "update-chat-event-memory",
        addon: WorkflowNodeAddonRef(
          name: "riela/memory-update",
          version: "1",
          config: [
            "memoryId": .string("chat-memory"),
            "recordId": .number(Double(savedRecordId)),
            "tags": .array([.string("chat"), .string("routing"), .string("updated")]),
            "files": .array([
              .object([
                "path": .string(sourceFile.path),
                "mediaType": .string("image/png"),
                "kind": .string("image"),
                "name": .string("yui.png")
              ])
            ]),
            "payload": .object([
              "text": .string("Yui, remember the updated routing test"),
              "conversationId": .string("chat-1")
            ])
          ]
        ),
        variables: [
          "workflowInput": .object(["memoryRoot": .string(memoryRoot)])
        ]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(update.payload["updated"], .bool(true))

    let load = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "load-yui-chat-memory",
        nodeId: "load-yui-chat-memory",
        addon: WorkflowNodeAddonRef(
          name: "riela/memory-load",
          version: "1",
          config: [
            "memoryId": .string("chat-memory"),
            "memoryRoot": .string(memoryRoot),
            "workflowScopeOnly": .bool(true)
          ]
        ),
        variables: [
          "workflowInput": .object(["memoryRoot": .string(memoryRoot)])
        ]
      ),
      context: AdapterExecutionContext()
    )
    guard case let .array(loadedRecords)? = load.payload["records"] else {
      return XCTFail("memory-load records were not returned")
    }
    XCTAssertEqual(loadedRecords.count, 1)
    guard case let .string(loadRecordsText)? = load.payload["recordsText"] else {
      return XCTFail("memory-load recordsText was not returned")
    }
    XCTAssertEqual(load.payload["memoryAttachmentCountRead"], .number(1))
    guard case let .array(loadImagePaths)? = load.payload["imagePaths"],
      case let .string(loadImagePath)? = loadImagePaths.first else {
      return XCTFail("memory-load imagePaths were not returned")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: loadImagePath))
    XCTAssertTrue(loadRecordsText.contains("Yui, remember the updated routing test"))
    XCTAssertTrue(loadRecordsText.contains("image image/png yui.png"))

    let search = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "search-chat-memory",
        nodeId: "search-chat-memory",
        addon: WorkflowNodeAddonRef(
          name: "riela/memory-search",
          version: "1",
          config: [
            "memoryId": .string("chat-memory"),
            "memoryRoot": .string(memoryRoot),
            "workflowScopeOnly": .bool(true),
            "matchPatterns": .array([.string("routing test")]),
            "tags": .array([.string("updated")])
          ]
        ),
        variables: [
          "workflowInput": .object(["memoryRoot": .string(memoryRoot)])
        ]
      ),
      context: AdapterExecutionContext()
    )
    guard case let .array(searchRecords)? = search.payload["records"] else {
      return XCTFail("memory-search records were not returned")
    }
    XCTAssertEqual(searchRecords.count, 1)
    guard case let .string(searchRecordsText)? = search.payload["recordsText"] else {
      return XCTFail("memory-search recordsText was not returned")
    }
    guard case let .array(searchFilePaths)? = search.payload["filePaths"],
      case let .string(searchFilePath)? = searchFilePaths.first else {
      return XCTFail("memory-search filePaths were not returned")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: searchFilePath))
    XCTAssertTrue(searchRecordsText.contains("Yui, remember the updated routing test"))
    XCTAssertTrue(searchRecordsText.contains("files: image image/png yui.png"))
  }

  func testBuiltinMemoryAddonsRejectInvalidTagsAndRelatedRecordIds() async throws {
    let root = repositoryRoot()
    let memoryRoot = "\(root)/tmp/test-invalid-memory-addon-input-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])

    do {
      _ = try await resolver.execute(
        WorkflowAddonExecutionInput(
          workflowId: "telegram-sdk-trio-chat",
          stepId: "save-chat-event-memory",
          nodeId: "save-chat-event-memory",
          addon: WorkflowNodeAddonRef(
            name: "riela/memory-save",
            version: "1",
            config: [
              "memoryId": .string("chat-memory"),
              "memoryRoot": .string(memoryRoot),
              "tags": .array([.number(1)]),
              "payload": .object(["text": .string("invalid tag")])
            ]
          )
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected invalid tag failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(error.message, "memory tags[0] must be a non-empty string")
    }

    do {
      _ = try await resolver.execute(
        WorkflowAddonExecutionInput(
          workflowId: "telegram-sdk-trio-chat",
          stepId: "save-chat-event-memory",
          nodeId: "save-chat-event-memory",
          addon: WorkflowNodeAddonRef(
            name: "riela/memory-save",
            version: "1",
            config: [
              "memoryId": .string("chat-memory"),
              "memoryRoot": .string(memoryRoot),
              "relatedRecordIds": .array([.number(1.5)]),
              "payload": .object(["text": .string("invalid related id")])
            ]
          )
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected invalid related record id failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(error.message, "memory relatedRecordIds[0] must be a positive integer record id")
    }
  }

  func testBuiltinChatMemoryRawDailySummaryAddonCreatesAndUpdatesSummary() async throws {
    let root = repositoryRoot()
    let memoryRoot = "\(root)/tmp/test-chat-memory-raw-daily-addon-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let addon = WorkflowNodeAddonRef(
      name: "riela/chat-memory-raw-daily-summary",
      version: "1",
      config: [
        "rawMemoryId": .string("raw-chat-log"),
        "summaryMemoryId": .string("daily-chat-summary"),
        "memoryRoot": .string(memoryRoot)
      ]
    )

    let first = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "chat-memory-raw-and-daily-summary",
        stepId: "update-chat-memory",
        nodeId: "update-chat-memory",
        addon: addon,
        variables: rawDailySummaryVariables(text: "first message", eventId: "event-1", receivedAt: "2026-06-22T09:00:00Z")
      ),
      context: AdapterExecutionContext()
    )
    let second = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "chat-memory-raw-and-daily-summary",
        stepId: "update-chat-memory",
        nodeId: "update-chat-memory",
        addon: addon,
        variables: rawDailySummaryVariables(text: "second message", eventId: "event-2", receivedAt: "2026-06-22T10:00:00Z")
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(first.payload["summaryAction"], .string("created"))
    XCTAssertEqual(second.payload["summaryAction"], .string("updated"))
    XCTAssertEqual(first.payload["summaryRecordId"], second.payload["summaryRecordId"])
    let store = RielaMemoryStore(rootDirectory: memoryRoot)
    let rawRecords = try store.search(
      memoryId: "raw-chat-log",
      options: MemorySearchOptions(workflowId: "chat-memory-raw-and-daily-summary", sortOrder: .registeredAsc, limit: 10)
    )
    let summaryRecords = try store.search(
      memoryId: "daily-chat-summary",
      options: MemorySearchOptions(workflowId: "chat-memory-raw-and-daily-summary", tags: ["summary:telegram:chat-1:2026-06-22"], limit: 10)
    )
    XCTAssertEqual(rawRecords.count, 2)
    XCTAssertEqual(summaryRecords.count, 1)
    XCTAssertNotEqual(try store.databasePath(memoryId: "raw-chat-log"), try store.databasePath(memoryId: "daily-chat-summary"))
    XCTAssertEqual(memoryNumber(objectPayload(summaryRecords[0].payload)?["rawRecordCount"]), 2)
    XCTAssertEqual(memoryInt64Array(objectPayload(summaryRecords[0].payload)?["rawLogRecordIds"]), rawRecords.map(\.recordId))
    XCTAssertTrue(memoryString(objectPayload(summaryRecords[0].payload)?["summary"])?.contains("first message") == true)
    XCTAssertTrue(memoryString(objectPayload(summaryRecords[0].payload)?["summary"])?.contains("second message") == true)
  }

  func testBuiltinChatMemoryRawDailySummaryKeepsTotalCountAndCapsRawLogRecordIds() async throws {
    let root = repositoryRoot()
    let memoryRoot = "\(root)/tmp/test-chat-memory-raw-daily-count-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let addon = WorkflowNodeAddonRef(
      name: "riela/chat-memory-raw-daily-summary",
      version: "1",
      config: [
        "rawMemoryId": .string("raw-chat-log"),
        "summaryMemoryId": .string("daily-chat-summary"),
        "memoryRoot": .string(memoryRoot)
      ]
    )

    for index in 1...12 {
      _ = try await resolver.execute(
        WorkflowAddonExecutionInput(
          workflowId: "chat-memory-raw-and-daily-summary",
          stepId: "update-chat-memory",
          nodeId: "update-chat-memory",
          addon: addon,
          variables: rawDailySummaryVariables(
            text: "message \(index)",
            eventId: "event-\(index)",
            receivedAt: "2026-06-22T10:\(String(format: "%02d", index)):00Z"
          )
        ),
        context: AdapterExecutionContext()
      )
    }

    let store = RielaMemoryStore(rootDirectory: memoryRoot)
    let summaryRecords = try store.search(
      memoryId: "daily-chat-summary",
      options: MemorySearchOptions(workflowId: "chat-memory-raw-and-daily-summary", tags: ["summary:telegram:chat-1:2026-06-22"], limit: 10)
    )

    XCTAssertEqual(summaryRecords.count, 1)
    XCTAssertEqual(memoryNumber(objectPayload(summaryRecords[0].payload)?["rawRecordCount"]), 12)
    XCTAssertEqual(memoryInt64Array(objectPayload(summaryRecords[0].payload)?["rawLogRecordIds"]), Array(3...12).map(Int64.init))
  }

  func testBuiltinChatMemoryRawDailySummarySeparatesProvidersWithSameConversationId() async throws {
    let root = repositoryRoot()
    let memoryRoot = "\(root)/tmp/test-chat-memory-raw-daily-provider-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let addon = WorkflowNodeAddonRef(
      name: "riela/chat-memory-raw-daily-summary",
      version: "1",
      config: [
        "rawMemoryId": .string("raw-chat-log"),
        "summaryMemoryId": .string("daily-chat-summary"),
        "memoryRoot": .string(memoryRoot)
      ]
    )

    _ = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "chat-memory-raw-and-daily-summary",
        stepId: "update-chat-memory",
        nodeId: "update-chat-memory",
        addon: addon,
        variables: rawDailySummaryVariables(
          provider: "telegram",
          text: "telegram message",
          eventId: "telegram-1",
          receivedAt: "2026-06-22T09:00:00Z"
        )
      ),
      context: AdapterExecutionContext()
    )
    _ = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "chat-memory-raw-and-daily-summary",
        stepId: "update-chat-memory",
        nodeId: "update-chat-memory",
        addon: addon,
        variables: rawDailySummaryVariables(
          provider: "discord",
          text: "discord message",
          eventId: "discord-1",
          receivedAt: "2026-06-22T09:01:00Z"
        )
      ),
      context: AdapterExecutionContext()
    )

    let store = RielaMemoryStore(rootDirectory: memoryRoot)
    let summaryRecords = try store.search(
      memoryId: "daily-chat-summary",
      options: MemorySearchOptions(workflowId: "chat-memory-raw-and-daily-summary", limit: 10)
    )

    XCTAssertEqual(summaryRecords.count, 2)
    XCTAssertEqual(Set(summaryRecords.flatMap(\.tags)), Set([
      "daily-summary",
      "summary:telegram:chat-1:2026-06-22",
      "summary:discord:chat-1:2026-06-22",
      "conversation:chat-1",
      "date:2026-06-22"
    ]))
  }

  func testBuiltinSDKWorkerExecutesInjectedLiveAdapter() async throws {
    let harness = RecordingSDKAddonHarness()
    let output = try await BuiltinWorkflowAddonResolver(
      environment: ["CURSOR_API_KEY": "cursor-secret"],
      cursorAdapterFactory: { _ in
        return await harness.makeAdapter(provider: "cursor-cli-agent", text: "最近はいい感じ。短く試せる形で返すね。")
      }
    ).execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "rina-cursor-sdk",
        nodeId: "rina-cursor-sdk",
        addon: WorkflowNodeAddonRef(
          name: "riela/cursor-sdk-worker",
          version: "1",
          config: [
            "model": .string("gpt-5.5"),
            "systemPromptTemplate": .string("You are {{persona}}."),
            "promptTemplate": .string("Reply to {{event.input.text}} as {{persona}}."),
            "mockResponseTemplate": .string("this mock must not be used")
          ]
        ),
        variables: [
          "event": .object(["input": .object(["text": .string("SDK trio")])]),
          "persona": .string("Rina")
        ],
        resolvedInputPayload: ["text": .string("hello"), "inputFilterSkipped": .bool(true)]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.provider, "cursor-cli-agent")
    XCTAssertEqual(output.model, "gpt-5.5")
    XCTAssertEqual(output.promptText, "Reply to SDK trio as Rina.")
    XCTAssertEqual(output.payload["executionBackend"], .string("official/cursor-sdk"))
    XCTAssertEqual(output.payload["text"], .string("最近はいい感じ。短く試せる形で返すね。"))
    XCTAssertEqual(output.payload["replyText"], .string("最近はいい感じ。短く試せる形で返すね。"))
    XCTAssertEqual(output.payload["liveExecution"], .bool(true))
    XCTAssertNil(output.payload["inputFilterSkipped"])

    let inputs = await harness.recordedInputs()
    let input = try XCTUnwrap(inputs.first)
    XCTAssertEqual(input.systemPromptText, "You are Rina.")
    XCTAssertEqual(input.mergedVariables["input"], .object(["text": .string("hello"), "inputFilterSkipped": .bool(true)]))
  }

  func testScenarioBackedAddonResolverUsesMockResponseBeforeFallback() async throws {
    let root = repositoryRoot()
    let resolver = try makeScenarioBackedAddonResolver(
      scenarioPath: "\(root)/examples/telegram-sdk-trio-chat/mock-scenario.json",
      workingDirectory: root
    )
    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "rina-cursor-sdk",
        nodeId: "rina-cursor-sdk",
        addon: WorkflowNodeAddonRef(name: "riela/cursor-sdk-worker", version: "1"),
        variables: [:]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.provider, "scenario-mock")
    XCTAssertEqual(output.model, "gpt-5.3-codex-spark")
    let expectedText = "問題ない。直前の流れを見る限り、Mikaの答えは文脈に沿っている。"
    XCTAssertEqual(output.payload["text"], .string(expectedText))
    XCTAssertEqual(output.when["always"], true)
  }

  func testBuiltinChatPersonaRouterSelectsNamedPersonas() async throws {
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let addon = WorkflowNodeAddonRef(
      name: "riela/chat-persona-router",
      version: "1",
      config: [
        "defaultPersonaId": .string("yui"),
        "personas": .array([
          .object(["id": .string("yui"), "aliases": .array([.string("yui"), .string("codex")])]),
          .object(["id": .string("mika"), "aliases": .array([.string("mika"), .string("claude")])]),
          .object(["id": .string("rina"), "aliases": .array([.string("rina"), .string("cursor")])])
        ])
      ]
    )

    let rina = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-trio",
        stepId: "route-message",
        nodeId: "route-message",
        addon: addon,
        variables: ["workflowInput": .object(["request": .string("Rina に技術観点を聞いて")])]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(rina.payload["target"], .string("rina"))
    XCTAssertEqual(rina.when["target_rina"], true)
    XCTAssertEqual(rina.when["target_yui"], false)

    let maki = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-trio",
        stepId: "route-message",
        nodeId: "route-message",
        addon: addon,
        variables: ["humanInput": .object(["request": .string("Maki の見え方も聞きたい")])]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(maki.payload["target"], .string("mika"))
    XCTAssertEqual(maki.when["target_mika"], true)
  }

  func testBuiltinGeminiSDKWorkerResolvesEnvironmentAndRenderedPrompt() async throws {
    let harness = RecordingGeminiAddonHarness()
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["USER_GEMINI_KEY": "gemini-secret"],
      geminiAdapterFactory: { configuration in
        await harness.makeAdapter(configuration: configuration)
      }
    )
    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "gemini-demo",
        stepId: "ask-gemini",
        nodeId: "ask-gemini",
        addon: WorkflowNodeAddonRef(
          name: "riela/gemini-sdk-worker",
          version: "1",
          config: [
            "model": .string("gemini-3.5-flash"),
            "systemPromptTemplate": .string("System {{topic}}"),
            "promptTemplate": .string("Reply about {{topic}} from {{input.prior}} and {{userText}}."),
            "inlineDataParts": .array([
              .object([
                "mimeType": .string("image/png"),
                "dataBase64": .string("iVBORw0KGgo=")
              ])
            ])
          ],
          env: [
            "GEMINI_API_KEY": .object([
              "fromEnv": .string("USER_GEMINI_KEY"),
              "required": .bool(true)
            ])
          ],
          inputs: [
            "userText": .string("{{input.prior}} plus addon input")
          ]
        ),
        variables: ["topic": .string("weather")],
        resolvedInputPayload: ["prior": .string("rain")]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["text"], .string("gemini reply"))
    let configurations = await harness.recordedConfigurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertEqual(configuration.apiKeyEnv, "GEMINI_API_KEY")
    XCTAssertEqual(configuration.environment?["GEMINI_API_KEY"], "gemini-secret")
    let inputs = await harness.recordedInputs()
    let input = try XCTUnwrap(inputs.first)
    XCTAssertEqual(input.node.executionBackend, .officialGeminiSDK)
    XCTAssertEqual(input.node.model, "gemini-3.5-flash")
    XCTAssertEqual(input.promptText, "Reply about weather from rain and rain plus addon input.")
    XCTAssertEqual(input.systemPromptText, "System weather")
    XCTAssertEqual(
      input.mergedVariables["geminiInlineDataParts"],
      .array([
        .object([
          "mimeType": .string("image/png"),
          "dataBase64": .string("iVBORw0KGgo=")
        ])
      ])
    )
  }

  func testBuiltinGeminiSDKWorkerPrefersGoogleAPIKeyTargetWhenBothAreMapped() async throws {
    let harness = RecordingGeminiAddonHarness()
    let resolver = BuiltinWorkflowAddonResolver(
      environment: [
        "USER_GEMINI_KEY": "gemini-test-key",
        "USER_GOOGLE_KEY": "google-test-key"
      ],
      geminiAdapterFactory: { configuration in
        await harness.makeAdapter(configuration: configuration)
      }
    )

    _ = try await resolver.execute(
      geminiAddonExecutionInput(
        env: [
          "GEMINI_API_KEY": .object(["fromEnv": .string("USER_GEMINI_KEY")]),
          "GOOGLE_API_KEY": .object(["fromEnv": .string("USER_GOOGLE_KEY")])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let configurations = await harness.recordedConfigurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertEqual(configuration.apiKeyEnv, "GOOGLE_API_KEY")
    XCTAssertEqual(configuration.environment?["GOOGLE_API_KEY"], "google-test-key")
    XCTAssertEqual(configuration.environment?["GEMINI_API_KEY"], "gemini-test-key")
  }

  func testBuiltinGeminiSDKWorkerReadsTaskLocalCLIEnvironmentOverrides() async throws {
    let harness = RecordingGeminiAddonHarness()
    let output = try await CLIRuntimeEnvironment.$overrides.withValue(["USER_GEMINI_KEY": "override-gemini-key"]) {
      try await BuiltinWorkflowAddonResolver(
        geminiAdapterFactory: { configuration in
          await harness.makeAdapter(configuration: configuration)
        }
      ).execute(
        geminiAddonExecutionInput(),
        context: AdapterExecutionContext()
      )
    }

    XCTAssertEqual(output.payload["text"], .string("gemini reply"))
    let configurations = await harness.recordedConfigurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertEqual(configuration.environment?["GEMINI_API_KEY"], "override-gemini-key")
  }

  func testBuiltinGeminiSDKWorkerFailsClosedWhenRequiredAPIKeyEnvIsMissing() async throws {
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])

    do {
      _ = try await resolver.execute(geminiAddonExecutionInput(), context: AdapterExecutionContext())
      XCTFail("Expected missing Gemini key failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(error.message, "required environment variable 'USER_GEMINI_KEY' is unavailable for addon.env.GEMINI_API_KEY")
    }
  }

  func testNodePatchIsInMemoryOnly() async throws {
    let root = repositoryRoot()
    let nodePath = "\(root)/examples/worker-only-single-step/nodes/node-main-worker.json"
    let before = try String(contentsOfFile: nodePath, encoding: .utf8)
    let app = RielaCLIApplication()
    let result = await app.run([
      "workflow", "validate", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--node-patch", #"{"main-worker":{"model":"gpt-5-mini","effort":"low"}}"#,
      "--executable",
      "--output", "json"
    ])
    XCTAssertEqual(result.exitCode, .success)
    let after = try String(contentsOfFile: nodePath, encoding: .utf8)
    XCTAssertEqual(after, before)
  }

  func geminiAddonExecutionInput(
    env: JSONObject = [
      "GEMINI_API_KEY": .object([
        "fromEnv": .string("USER_GEMINI_KEY"),
        "required": .bool(true)
      ])
    ]
  ) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "gemini-demo",
      stepId: "ask-gemini",
      nodeId: "ask-gemini",
      addon: WorkflowNodeAddonRef(
        name: "riela/gemini-sdk-worker",
        version: "1",
        config: [
          "model": .string("gemini-3.5-flash"),
          "systemPromptTemplate": .string("System {{topic}}"),
          "promptTemplate": .string("Reply about {{topic}} from {{input.prior}} and {{userText}}.")
        ],
        env: env,
        inputs: [
          "userText": .string("{{input.prior}} plus addon input")
        ]
      ),
      variables: ["topic": .string("weather")],
      resolvedInputPayload: ["prior": .string("rain")]
    )
  }
}
