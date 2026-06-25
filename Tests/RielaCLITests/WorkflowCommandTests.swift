// This worker owns only this legacy integration test file; splitting it would cross the assigned file boundary.
// swiftlint:disable file_length
import Foundation
import RielaAdapters
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

private actor RecordingWorkflowGraphQLRunTransport: WorkflowGraphQLRunTransporting {
  private(set) var endpoint: String?
  private(set) var request: WorkflowRemoteRunRequest?
  var result = WorkflowRemoteRunResult(
    sessionId: "remote-session-1",
    status: "completed",
    workflowName: "remote-workflow",
    workflowId: "remote-workflow",
    nodeExecutions: 2,
    transitions: 1,
    exitCode: 0
  )

  func executeWorkflow(endpoint: String, request: WorkflowRemoteRunRequest) async throws -> WorkflowRemoteRunResult {
    self.endpoint = endpoint
    self.request = request
    return result
  }

  func recordedEndpoint() -> String? {
    endpoint
  }

  func recordedRequest() -> WorkflowRemoteRunRequest? {
    request
  }
}

private actor RecordingGeminiAddonHarness {
  private var configurations: [OfficialSDKAdapterConfiguration] = []
  private var inputs: [AdapterExecutionInput] = []

  func makeAdapter(configuration: OfficialSDKAdapterConfiguration) -> any NodeAdapter {
    configurations.append(configuration)
    return RecordingGeminiAddonAdapter(harness: self)
  }

  func record(_ input: AdapterExecutionInput) {
    inputs.append(input)
  }

  func recordedConfigurations() -> [OfficialSDKAdapterConfiguration] {
    configurations
  }

  func recordedInputs() -> [AdapterExecutionInput] {
    inputs
  }
}

private struct RecordingGeminiAddonAdapter: NodeAdapter {
  let harness: RecordingGeminiAddonHarness

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    await harness.record(input)
    return AdapterExecutionOutput(
      provider: "official-gemini-sdk",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["text": .string("gemini reply")]
    )
  }
}

private actor RecordingSDKAddonHarness {
  private var inputs: [AdapterExecutionInput] = []

  func makeAdapter(provider: String, text: String) -> any NodeAdapter {
    RecordingSDKAddonAdapter(harness: self, provider: provider, text: text)
  }

  func record(_ input: AdapterExecutionInput) {
    inputs.append(input)
  }

  func recordedInputs() -> [AdapterExecutionInput] {
    inputs
  }
}

private struct RecordingSDKAddonAdapter: NodeAdapter {
  let harness: RecordingSDKAddonHarness
  let provider: String
  let text: String

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    await harness.record(input)
    return AdapterExecutionOutput(
      provider: provider,
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["text": .string(text)]
    )
  }
}

private final class JSONLWriterProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedLines: [String] = []
  private var persistedAtSessionStartValue = false
  private let sessionStore: URL

  init(sessionStore: URL) {
    self.sessionStore = sessionStore
  }

  func record(_ line: String) {
    lock.withLock {
      recordedLines.append(line)
      guard line.contains(#""type":"session_started""#),
        let event = try? JSONDecoder().decode(WorkflowRunEvent.self, from: Data(line.utf8))
      else {
        return
      }
      let session = try? CLIWorkflowSessionStore(rootDirectory: sessionStore.path).load(sessionId: event.sessionId)
      let snapshot = try? SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
      ).load(sessionId: event.sessionId)
      persistedAtSessionStartValue = session != nil && snapshot != nil
    }
  }

  func lines() -> [String] {
    lock.withLock { recordedLines }
  }

  func persistedAtSessionStart() -> Bool {
    lock.withLock { persistedAtSessionStartValue }
  }
}

private final class RecordingGraphQLURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private nonisolated(unsafe) static var responseQueue: [Data] = []
  private nonisolated(unsafe) static var recordedBodies: [[String: Any]] = []
  private nonisolated(unsafe) static var recordedHeaders: [[String: String]] = []

  static func reset(responses: [String]) {
    lock.withLock {
      responseQueue = responses.map { Data($0.utf8) }
      recordedBodies = []
      recordedHeaders = []
    }
  }

  static func bodies() -> [[String: Any]] {
    lock.withLock { recordedBodies }
  }

  static func headers() -> [[String: String]] {
    lock.withLock { recordedHeaders }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "riela.test"
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let body = request.httpBody ?? Self.data(from: request.httpBodyStream)
    let decoded = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let responseBody: Data = Self.lock.withLock {
      Self.recordedBodies.append(decoded)
      Self.recordedHeaders.append(request.allHTTPHeaderFields ?? [:])
      return Self.responseQueue.isEmpty ? Data(#"{"data":{}}"#.utf8) : Self.responseQueue.removeFirst()
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: responseBody)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func data(from stream: InputStream?) -> Data {
    guard let stream else {
      return Data()
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 {
        break
      }
      data.append(buffer, count: count)
    }
    return data
  }
}

private func environmentValue(_ name: String) -> String? {
  getenv(name).map { String(cString: $0) }
}

private func setEnvironmentValue(_ name: String, _ value: String?) {
  if let value {
    setenv(name, value, 1)
  } else {
    unsetenv(name)
  }
}

private func remoteGraphQLRunResponses(executionId: String = "remote-exec-1", status: String = "paused") -> [String] {
  [
    """
    {
      "data": {
        "executeWorkflow": {
          "workflowExecutionId": "\(executionId)",
          "sessionId": "remote-session-1",
          "status": "\(status)",
          "exitCode": 0
        }
      }
    }
    """,
    """
    {
      "data": {
        "workflowExecution": {
          "session": {
            "sessionId": "remote-session-1",
            "workflowName": "remote-workflow",
            "workflowId": "remote-workflow-id",
            "transitions": [
              { "when": "always" }
            ]
          },
          "nodeExecutions": [
            { "nodeExecId": "node-exec-1" },
            { "nodeExecId": "node-exec-2" }
          ]
        }
      }
    }
    """
  ]
}

final class WorkflowCommandTests: XCTestCase {
  func testTopLevelHelpReturnsSuccessfulSmokeOutput() async {
    let result = await RielaCLIApplication().run(["--help"])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    XCTAssertTrue(result.stdout.contains("workflow validate"))
    XCTAssertTrue(result.stdout.contains("Swift CLI is the production Homebrew runtime"))
    XCTAssertFalse(result.stdout.contains("TypeScript/Bun"))
    XCTAssertFalse(result.stdout.contains("cutover gates pass"))
  }

  func testValidateInspectAndDeterministicRunWorkerFixture() async throws {
    let root = repositoryRoot()
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
    let run = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json"
    ])

    XCTAssertEqual(run.exitCode, .success)
    XCTAssertTrue(run.stderr.isEmpty)
    let lines = run.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 5)

    let first = try decodeJSON(WorkflowRunEvent.self, from: lines[0])
    XCTAssertEqual(first.type, .sessionStarted)
    XCTAssertEqual(first.workflowId, "worker-only-single-step")
    XCTAssertTrue(first.sessionId.hasPrefix("worker-only-single-step-session-"))

    let final = try decodeJSON(WorkflowRunResultRecord.self, from: lines[4])
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
    XCTAssertEqual(probe.lines().count, 5)
    let canonicalDatabasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    )
    XCTAssertEqual(CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionStore.path), canonicalDatabasePath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDatabasePath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionStore.appendingPathComponent("cli-workflow-sessions.sqlite").path))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sessionStore.path).allSatisfy { !$0.hasSuffix(".json") })
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
    guard case let .number(savedRecordIdNumber)? = savedRecord["recordId"],
      let savedRecordId = Int64(exactly: savedRecordIdNumber) else {
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

  private func geminiAddonExecutionInput(
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

extension WorkflowCommandTests {
  func testInspectReportsCallableInputAndOutputContracts() async throws {
    let root = repositoryRoot()
    let result = await RielaCLIApplication().run([
      "workflow", "inspect", "codex-design-and-implement-review-loop",
      "--scope", "project",
      "--working-dir", root,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: result.stdout)
    XCTAssertEqual(summary.callable.stepId, "riela-manager")
    XCTAssertEqual(summary.callable.role, .manager)
    XCTAssertEqual(
      summary.callable.input?.description,
      """
      Provide either issue reference details for full issue resolution or Codex-reference planning details for a \
      design-plan-only run. Preferred fields are executionMode, issueUrl, issueNumber, issueRepository, issueTitle, \
      issueBody, targetFeatureArea, requestedBehavior, codexAgentReferences, referenceRepositoryRoot, and \
      referenceRepositoryUrl.
      """
    )
    XCTAssertEqual(
      summary.callable.output?.description,
      """
      Return either the final accepted issue-resolution summary or the accepted design-and-implementation-plan handoff, \
      including any required documentation refresh, the final commit-message, and commit/push status, depending on the \
      requested workflow mode.
      """
    )
  }

  func testResolverHydratesPromptTemplateFilesForTopLevelAndVariantPayloads() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-tests-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("template-workflow", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: workflowDirectory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workflowDirectory.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    try """
    {
      "workflowId": "template-workflow",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "worker",
      "nodes": [{ "id": "worker", "nodeFile": "nodes/node-worker.json" }],
      "steps": [{ "id": "worker", "nodeId": "worker", "role": "worker", "promptVariant": "review" }]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "worker",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "systemPromptTemplateFile": "prompts/system.md",
      "promptTemplateFile": "prompts/main.md",
      "sessionStartPromptTemplateFile": "prompts/start.md",
      "promptVariants": {
        "review": { "promptTemplateFile": "prompts/review.md" }
      },
      "variables": {}
    }
    """.write(to: workflowDirectory.appendingPathComponent("nodes/node-worker.json"), atomically: true, encoding: .utf8)
    try "system".write(to: workflowDirectory.appendingPathComponent("prompts/system.md"), atomically: true, encoding: .utf8)
    try "main".write(to: workflowDirectory.appendingPathComponent("prompts/main.md"), atomically: true, encoding: .utf8)
    try "start".write(to: workflowDirectory.appendingPathComponent("prompts/start.md"), atomically: true, encoding: .utf8)
    try "review".write(to: workflowDirectory.appendingPathComponent("prompts/review.md"), atomically: true, encoding: .utf8)

    let bundle = try FileSystemWorkflowBundleResolver().resolve(
      WorkflowResolutionOptions(workflowName: "template-workflow", scope: .direct, workflowDefinitionDir: root.path)
    )
    let payload = try XCTUnwrap(bundle.nodePayloads["worker"])

    XCTAssertEqual(payload.systemPromptTemplate, "system")
    XCTAssertEqual(payload.promptTemplate, "main")
    XCTAssertEqual(payload.sessionStartPromptTemplate, "start")
    XCTAssertEqual(payload.promptVariants?["review"]?.promptTemplate, "review")
    XCTAssertEqual(payload.promptTemplateFile, "prompts/main.md")
    XCTAssertEqual(payload.promptVariants?["review"]?.promptTemplateFile, "prompts/review.md")
  }

  func testWorkflowInspectAndUsageExposeLoopMetadataSummary() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-loop-summary-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("loop-summary", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "loop-summary",
      "description": "Loop summary workflow",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "implement",
      "loop": {
        "kind": "design-implement-review",
        "required": true,
        "description": "Implementation loop",
        "evidence": {
          "required": true,
          "artifactRootPolicy": "runtime-owned",
          "requiredSections": ["changed-files", "verification"]
        },
        "policies": {
          "mutation": {
            "allowedWriteRoots": ["Sources", "Tests"],
            "scratchRoot": "tmp/loop-summary",
            "commit": "deny",
            "push": "deny"
          },
          "process": {
            "nestedRiela": "deny",
            "nestedCodex": "deny",
            "allowedBackends": ["codex-agent"],
            "requiredWorkerModel": "gpt-5.5"
          },
          "network": { "mode": "inherit-command" }
        },
        "implementationPlan": {
          "required": true,
          "pathPattern": "impl-plans/active/*.md"
        },
        "gates": [{
          "id": "review-gate",
          "stepId": "review",
          "required": true,
          "acceptWhen": {
            "decision": "accepted",
            "maxHighFindings": 0,
            "maxMediumFindings": 0
          }
        }]
      },
      "nodes": [
        { "id": "implement", "nodeFile": "nodes/implement.json" },
        { "id": "review", "nodeFile": "nodes/review.json" }
      ],
      "steps": [
        {
          "id": "implement",
          "nodeId": "implement",
          "role": "worker",
          "loop": {
            "role": "worker",
            "evidenceTags": ["changed-files"],
            "recordsChangedFiles": true
          },
          "transitions": [{ "toStepId": "review" }]
        },
        {
          "id": "review",
          "nodeId": "review",
          "role": "worker",
          "loop": {
            "role": "gate",
            "gateId": "review-gate",
            "evidenceTags": ["verification"],
            "recordsVerification": true
          }
        }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "implement",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "promptTemplate": "implement",
      "variables": {}
    }
    """.write(to: nodesDirectory.appendingPathComponent("implement.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "review",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "promptTemplate": "review",
      "variables": {}
    }
    """.write(to: nodesDirectory.appendingPathComponent("review.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let inspect = await app.run([
      "workflow", "inspect", "loop-summary",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .success)
    let inspectSummary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    let inspectLoop = try XCTUnwrap(inspectSummary.loop)
    XCTAssertEqual(inspectLoop.kind, "design-implement-review")
    XCTAssertTrue(inspectLoop.required)
    XCTAssertTrue(inspectLoop.evidenceRequired)
    XCTAssertEqual(inspectLoop.artifactRootPolicy, "runtime-owned")
    XCTAssertEqual(inspectLoop.requiredEvidenceSections, ["changed-files", "verification"])
    XCTAssertEqual(inspectLoop.gates, [
      WorkflowLoopGateInspection(
        id: "review-gate",
        stepId: "review",
        required: true,
        acceptDecision: .accepted,
        maxHighFindings: 0,
        maxMediumFindings: 0
      )
    ])
    XCTAssertEqual(inspectLoop.steps.map(\.stepId), ["implement", "review"])
    XCTAssertEqual(inspectLoop.steps.last?.gateId, "review-gate")
    XCTAssertEqual(inspectLoop.policies?.allowedWriteRoots, ["Sources", "Tests"])
    XCTAssertEqual(inspectLoop.policies?.scratchRoot, "tmp/loop-summary")
    XCTAssertEqual(inspectLoop.policies?.commit, "deny")
    XCTAssertEqual(inspectLoop.policies?.push, "deny")
    XCTAssertEqual(inspectLoop.policies?.nestedRiela, "deny")
    XCTAssertEqual(inspectLoop.policies?.nestedCodex, "deny")
    XCTAssertEqual(inspectLoop.policies?.allowedBackends, ["codex-agent"])
    XCTAssertEqual(inspectLoop.policies?.requiredWorkerModel, "gpt-5.5")
    XCTAssertEqual(inspectLoop.policies?.networkMode, "inherit-command")
    XCTAssertEqual(inspectLoop.implementationPlan?.pathPattern, "impl-plans/active/*.md")

    let usage = await app.run([
      "workflow", "usage", "loop-summary",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])
    XCTAssertEqual(usage.exitCode, .success)
    let usageSummary = try decodeJSON(WorkflowInspectionSummary.self, from: usage.stdout)
    XCTAssertEqual(usageSummary.loop, inspectSummary.loop)

    let text = await app.run([
      "workflow", "inspect", "loop-summary",
      "--workflow-definition-dir", root.path,
      "--output", "text"
    ])
    XCTAssertEqual(text.exitCode, .success)
    XCTAssertTrue(text.stdout.contains("loop: required=true kind=design-implement-review gates=1 stepMetadata=2 artifactRootPolicy=runtime-owned"))
  }

  func testRunAcceptsTemporaryWorkflowJSONFileTarget() async throws {
    let root = repositoryRoot()
    let app = RielaCLIApplication()
    let result = await app.run([
      "workflow", "run", "\(root)/examples/temporary-workflow/temp-workflow.json",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.workflowId, "temporary-embedded-status")
    XCTAssertEqual(run.status, .completed)
    XCTAssertEqual(run.nodeExecutions, 1)
  }

  func testWorkflowRunDispatchesCodexAgentBackendToProductionAdapter() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-codex-dispatch-\(UUID().uuidString)", isDirectory: true)
    let workflowDirectory = root.appendingPathComponent("codex-dispatch", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "codex-dispatch",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "worker",
      "nodes": [{ "id": "worker", "nodeFile": "nodes/worker.json" }],
      "steps": [{ "id": "worker", "nodeId": "worker", "role": "worker" }]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "worker",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "promptTemplate": "dispatch through codex",
      "variables": {}
    }
    """.write(to: nodesDirectory.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)

    let marker = root.appendingPathComponent("fake-codex-called.txt")
    let fakeCodex = try createExecutable(
      directory: root,
      name: "fake-codex.sh",
      body: """
      if [ "$1" = "login" ] && [ "$2" = "status" ]; then
        exit 0
      fi
      printf '%s\\n' "$*" >> '\(marker.path)'
      printf '{"type":"assistant.snapshot","content":"fake codex reached"}\\n'
      exit 0
      """
    )
    let previousCodexExecutable = environmentValue("RIELA_CODEX_AGENT_EXECUTABLE")
    setEnvironmentValue("RIELA_CODEX_AGENT_EXECUTABLE", fakeCodex.path)
    defer { setEnvironmentValue("RIELA_CODEX_AGENT_EXECUTABLE", previousCodexExecutable) }

    let result = await RielaCLIApplication().run([
      "workflow", "run", "codex-dispatch",
      "--workflow-definition-dir", root.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.status, .completed)
    XCTAssertEqual(run.session.executions.first?.adapterOutput?.provider, "codex-agent")
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("exec --json"), true)
  }

  func testRunHonorsArtifactRootAndForwardsMaxConcurrency() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-run-artifact-root-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let artifactRoot = tempDir.appendingPathComponent("artifacts", isDirectory: true)

    let result = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--artifact-root", artifactRoot.path,
      "--max-concurrency", "2",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.status, .completed)
    let artifactSnapshot = artifactRoot
      .appendingPathComponent(run.session.sessionId, isDirectory: true)
      .appendingPathComponent("runtime-snapshot.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifactSnapshot.path))
  }

  func testSessionRerunUsesPersistedSessionStore() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-session-rerun-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true).path
    let app = RielaCLIApplication()

    let firstRun = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore,
      "--output", "json"
    ])
    XCTAssertEqual(firstRun.exitCode, .success, firstRun.stderr)
    let first = try decodeJSON(WorkflowRunResult.self, from: firstRun.stdout)

    let rerun = await app.run([
      "session", "rerun", first.session.sessionId, "main-worker",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore,
      "--output", "json"
    ])
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr)
    let payload = try decodeJSON(SessionRerunCommandResult.self, from: rerun.stdout)
    XCTAssertEqual(payload.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(payload.rerunFromStepId, "main-worker")
    XCTAssertNotEqual(payload.sessionId, first.session.sessionId)
    XCTAssertEqual(payload.status, .completed)
    XCTAssertEqual(payload.recovery?.entryMode, .rerun)
    XCTAssertEqual(payload.recovery?.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(payload.recovery?.sourceStepId, "main-worker")
    let loopRecover = await app.run([
      "loop", "recover", first.session.sessionId,
      "--from-step", "main-worker",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore,
      "--output", "json"
    ])
    XCTAssertEqual(loopRecover.exitCode, .success, loopRecover.stderr)
    let secondPayload = try decodeJSON(SessionRerunCommandResult.self, from: loopRecover.stdout)
    XCTAssertEqual(secondPayload.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(secondPayload.rerunFromStepId, "main-worker")
    XCTAssertNotEqual(secondPayload.sessionId, payload.sessionId)
    XCTAssertEqual(secondPayload.recovery?.entryMode, .rerun)
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore)
    )
    for sessionId in [payload.sessionId, secondPayload.sessionId] {
      XCTAssertEqual(try runtimeStore.load(sessionId: sessionId).session.sessionId, sessionId)
      XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: sessionStore, isDirectory: true)
        .appendingPathComponent("runtime-records", isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
        .appendingPathComponent("runtime-snapshot.json").path))
    }
  }

  func testSessionRerunRejectsNestedSuperviserFlag() async throws {
    let result = await RielaCLIApplication().run([
      "session", "rerun", "sess-1", "step-1", "--nested-superviser"
    ])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(SessionCommandFailureResult.self, from: result.stdout)
    XCTAssertTrue(failure.error.contains("not supported for session rerun"))
  }

  func testUserScopeWorkflowRunSupportsDefaultAutoScopeSessionRerunAndResume() async throws {
    let root = repositoryRoot()
    let layout = try makeIsolatedUserScopeWorkflowLayout(
      repositoryRoot: root,
      workflowName: "worker-only-single-step"
    )
    defer { try? FileManager.default.removeItem(at: layout.base) }

    let mockScenario = "\(root)/examples/worker-only-single-step/mock-scenario.json"
    let app = RielaCLIApplication()
    let environment = ["HOME": layout.homeRoot.path]

    let firstRun = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--scope", "user",
      "--working-dir", layout.projectRoot.path,
      "--mock-scenario", mockScenario,
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(firstRun.exitCode, .success, firstRun.stderr)
    let first = try decodeJSON(WorkflowRunResult.self, from: firstRun.stdout)

    let rerun = await app.run([
      "session", "rerun", first.session.sessionId, "main-worker",
      "--working-dir", layout.projectRoot.path,
      "--mock-scenario", mockScenario,
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr)
    let rerunPayload = try decodeJSON(SessionRerunCommandResult.self, from: rerun.stdout)
    XCTAssertEqual(rerunPayload.sourceSessionId, first.session.sessionId)
    XCTAssertEqual(rerunPayload.rerunFromStepId, "main-worker")
    XCTAssertEqual(rerunPayload.recovery?.entryMode, .rerun)
    XCTAssertEqual(rerunPayload.recovery?.sourceSessionId, first.session.sessionId)

    let resume = await app.run([
      "session", "resume", rerunPayload.sessionId,
      "--working-dir", layout.projectRoot.path,
      "--mock-scenario", mockScenario,
      "--output", "json"
    ], environment: environment)
    XCTAssertEqual(resume.exitCode, .success, resume.stderr)
    let resumePayload = try decodeJSON(SessionResumeCommandResult.self, from: resume.stdout)
    XCTAssertEqual(resumePayload.sourceSessionId, rerunPayload.sessionId)
    XCTAssertEqual(resumePayload.sessionId, rerunPayload.sessionId)
    XCTAssertEqual(resumePayload.status, .completed)
    XCTAssertEqual(resumePayload.recovery?.entryMode, .resume)
    XCTAssertEqual(resumePayload.recovery?.sourceSessionId, rerunPayload.sessionId)
  }

  func testValidateAndInspectRejectRemoteResolutionFlagsWithUsageExit() async throws {
    let app = RielaCLIApplication()

    let validate = await app.run([
      "workflow", "validate", "worker-only-single-step",
      "--endpoint", "http://localhost:4000/graphql"
    ])
    XCTAssertEqual(validate.exitCode, .usage)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertEqual(validateFailure.error, "Swift TASK-007 supports local workflow validate only")

    let inspect = await app.run([
      "workflow", "inspect", "worker-only-single-step",
      "--from-registry"
    ])
    XCTAssertEqual(inspect.exitCode, .usage)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.error, "Swift TASK-007 supports local workflow inspect only")
  }

  func testRunJSONFailureReturnsParseableFailureEnvelope() async throws {
    let root = repositoryRoot()
    let result = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--variables", #"{"unterminated": true"#,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.target, "worker-only-single-step")
    XCTAssertEqual(failure.status, .failed)
    XCTAssertEqual(failure.exitCode, CLIExitCode.failure.rawValue)
    XCTAssertFalse(failure.error.isEmpty)
  }

  func testWorkflowRunUsesGraphQLEndpointTransport() async throws {
    let previousToken = environmentValue("RIELA_REMOTE_AUTH_TOKEN")
    setEnvironmentValue("RIELA_REMOTE_AUTH_TOKEN", "env-token-1")
    defer { setEnvironmentValue("RIELA_REMOTE_AUTH_TOKEN", previousToken) }

    let transport = RecordingWorkflowGraphQLRunTransport()
    let app = RielaCLIApplication(runCommand: WorkflowRunCommand(graphQLTransport: transport))
    let result = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://localhost:4000/graphql",
      "--auth-token-env", "RIELA_REMOTE_AUTH_TOKEN",
      "--variables", #"{"request":"remote"}"#,
      "--max-concurrency", "3",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stderr.isEmpty)
    let remote = try decodeJSON(WorkflowRemoteRunResult.self, from: result.stdout)
    XCTAssertEqual(remote.sessionId, "remote-session-1")
    let recordedEndpoint = await transport.recordedEndpoint()
    XCTAssertEqual(recordedEndpoint, "http://localhost:4000/graphql")
    let recordedRequest = await transport.recordedRequest()
    let request = try XCTUnwrap(recordedRequest)
    XCTAssertEqual(request.workflowName, "worker-only-single-step")
    XCTAssertEqual(request.runtimeVariables["request"], .string("remote"))
    XCTAssertEqual(request.maxConcurrency, 3)
    XCTAssertEqual(request.authToken, "env-token-1")
    XCTAssertEqual(request.authTokenEnv, "RIELA_REMOTE_AUTH_TOKEN")
  }

  func testWorkflowRunEndpointUsesRielaAuthEnvironment() async throws {
    let previousRielaToken = environmentValue("RIELA_MANAGER_AUTH_TOKEN")
    let previousRielaSession = environmentValue("RIELA_MANAGER_SESSION_ID")
    defer {
      setEnvironmentValue("RIELA_MANAGER_AUTH_TOKEN", previousRielaToken)
      setEnvironmentValue("RIELA_MANAGER_SESSION_ID", previousRielaSession)
    }

    setEnvironmentValue("RIELA_MANAGER_AUTH_TOKEN", "riela-token")
    setEnvironmentValue("RIELA_MANAGER_SESSION_ID", "riela-session")

    let primaryTransport = RecordingWorkflowGraphQLRunTransport()
    let primaryApp = RielaCLIApplication(runCommand: WorkflowRunCommand(graphQLTransport: primaryTransport))
    let primaryResult = await primaryApp.run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://localhost:4000/graphql",
      "--output", "json"
    ])

    XCTAssertEqual(primaryResult.exitCode, .success, primaryResult.stderr)
    let recordedPrimaryRequest = await primaryTransport.recordedRequest()
    let primaryRequest = try XCTUnwrap(recordedPrimaryRequest)
    XCTAssertEqual(primaryRequest.authToken, "riela-token")
    XCTAssertEqual(primaryRequest.authTokenEnv, "RIELA_MANAGER_AUTH_TOKEN")
    XCTAssertEqual(primaryRequest.managerSessionId, "riela-session")
  }

  func testURLSessionWorkflowRunUsesSchemaAccurateRemotePayloadAndPausedStatus() async throws {
    let previousRielaManagerSession = environmentValue("RIELA_MANAGER_SESSION_ID")
    setEnvironmentValue("RIELA_MANAGER_SESSION_ID", "manager-session-1")
    defer {
      setEnvironmentValue("RIELA_MANAGER_SESSION_ID", previousRielaManagerSession)
    }

    RecordingGraphQLURLProtocol.reset(responses: remoteGraphQLRunResponses())
    URLProtocol.registerClass(RecordingGraphQLURLProtocol.self)
    defer { URLProtocol.unregisterClass(RecordingGraphQLURLProtocol.self) }

    let result = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://riela.test/graphql",
      "--auth-token", "explicit-token",
      "--variables", #"{"request":"remote"}"#,
      "--max-concurrency", "3",
      "--timeout-ms", "100",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let remote = try decodeJSON(WorkflowRemoteRunResult.self, from: result.stdout)
    XCTAssertEqual(remote.sessionId, "remote-session-1")
    XCTAssertEqual(remote.status, "paused")
    XCTAssertEqual(remote.workflowName, "remote-workflow")
    XCTAssertEqual(remote.workflowId, "remote-workflow-id")
    XCTAssertEqual(remote.nodeExecutions, 2)
    XCTAssertEqual(remote.transitions, 1)

    let bodies = RecordingGraphQLURLProtocol.bodies()
    XCTAssertEqual(bodies.count, 2)
    let headers = RecordingGraphQLURLProtocol.headers()
    XCTAssertEqual(headers.count, 2)
    for header in headers {
      XCTAssertEqual(header["Authorization"], "Bearer explicit-token")
      XCTAssertEqual(header["X-Riela-Manager-Session-Id"], "manager-session-1")
    }
    let executeBody = try XCTUnwrap(bodies.first)
    let executeQuery = try XCTUnwrap(executeBody["query"] as? String)
    XCTAssertTrue(executeQuery.contains("executeWorkflow(input: $input)"))
    XCTAssertFalse(executeQuery.contains("workflowName"))
    XCTAssertFalse(executeQuery.contains("workflowId"))
    XCTAssertFalse(executeQuery.contains("nodeExecutions"))
    XCTAssertFalse(executeQuery.contains("transitions"))
    let variables = try XCTUnwrap(executeBody["variables"] as? [String: Any])
    let input = try XCTUnwrap(variables["input"] as? [String: Any])
    XCTAssertEqual(input["workflowName"] as? String, "worker-only-single-step")
    XCTAssertNil(input["autoImprove"])
    XCTAssertNil(input["autoImprovePolicy"])
    XCTAssertNil(input["timeoutMs"])
    XCTAssertNil(input["authToken"])
    XCTAssertNil(input["authTokenEnv"])
    XCTAssertNil(input["managerSessionId"])
    XCTAssertEqual((input["maxConcurrency"] as? NSNumber)?.intValue, 3)

    let summaryBody = try XCTUnwrap(bodies.last)
    let summaryQuery = try XCTUnwrap(summaryBody["query"] as? String)
    XCTAssertTrue(summaryQuery.contains("workflowExecution(workflowExecutionId: $workflowExecutionId)"))
    let summaryVariables = try XCTUnwrap(summaryBody["variables"] as? [String: Any])
    XCTAssertEqual(summaryVariables["workflowExecutionId"] as? String, "remote-exec-1")
  }

  func testURLSessionWorkflowRunAutoImproveIsOptInOverRemotePayload() async throws {
    URLProtocol.registerClass(RecordingGraphQLURLProtocol.self)
    defer { URLProtocol.unregisterClass(RecordingGraphQLURLProtocol.self) }

    RecordingGraphQLURLProtocol.reset(responses: remoteGraphQLRunResponses(executionId: "remote-exec-disabled"))
    let disabled = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://riela.test/graphql",
      "--no-auto-improve",
      "--output", "json"
    ])

    XCTAssertEqual(disabled.exitCode, .success, disabled.stderr)
    let disabledBodies = RecordingGraphQLURLProtocol.bodies()
    let disabledExecuteBody = try XCTUnwrap(disabledBodies.first)
    let disabledVariables = try XCTUnwrap(disabledExecuteBody["variables"] as? [String: Any])
    let disabledInput = try XCTUnwrap(disabledVariables["input"] as? [String: Any])
    XCTAssertNil(disabledInput["autoImprove"])
    XCTAssertNil(disabledInput["nestedSuperviser"])

    RecordingGraphQLURLProtocol.reset(responses: remoteGraphQLRunResponses(executionId: "remote-exec-enabled"))
    let enabled = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--endpoint", "http://riela.test/graphql",
      "--auto-improve",
      "--max-supervised-attempts", "4",
      "--nested-supervisor",
      "--output", "json"
    ])

    XCTAssertEqual(enabled.exitCode, .success, enabled.stderr)
    let enabledBodies = RecordingGraphQLURLProtocol.bodies()
    let enabledExecuteBody = try XCTUnwrap(enabledBodies.first)
    let enabledVariables = try XCTUnwrap(enabledExecuteBody["variables"] as? [String: Any])
    let enabledInput = try XCTUnwrap(enabledVariables["input"] as? [String: Any])
    let enabledAutoImprove = try XCTUnwrap(enabledInput["autoImprove"] as? [String: Any])
    XCTAssertEqual((enabledAutoImprove["enabled"] as? NSNumber)?.boolValue, true)
    XCTAssertEqual((enabledAutoImprove["maxSupervisedAttempts"] as? NSNumber)?.intValue, 4)
    XCTAssertEqual((enabledInput["nestedSuperviser"] as? NSNumber)?.boolValue, true)
  }

  func testParserValidateJSONFailureReturnsParseableEnvelopeForUnknownOption() async throws {
    let result = await RielaCLIApplication().run([
      "workflow", "validate", "worker-only-single-step",
      "--unknown",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: result.stdout)
    XCTAssertFalse(failure.valid)
    XCTAssertEqual(failure.workflowId, "worker-only-single-step")
    XCTAssertEqual(failure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(failure.error.contains("unknown option '--unknown'"))
  }

  func testParserInspectJSONFailureReturnsParseableEnvelopeForMissingOptionValue() async throws {
    let result = await RielaCLIApplication().run([
      "workflow", "inspect", "worker-only-single-step",
      "--workflow-definition-dir",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowInspectionFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.workflowId, "worker-only-single-step")
    XCTAssertEqual(failure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(failure.error.contains("--workflow-definition-dir requires a value"))
  }

  func testScopedWorkflowNamesRejectTraversalAndSlashTargets() async throws {
    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "../../examples/worker-only-single-step",
      "--scope", "project",
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .usage)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertEqual(validateFailure.workflowId, "../../examples/worker-only-single-step")
    XCTAssertEqual(validateFailure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(validateFailure.error.contains("invalid scoped workflow or package name"))

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "nested/workflow",
      "--scope", "project",
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .usage)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.workflowId, "nested/workflow")
    XCTAssertEqual(inspectFailure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(inspectFailure.error.contains("invalid scoped workflow or package name"))

    let run = await RielaCLIApplication().run([
      "workflow", "run", "../worker-only-single-step",
      "--scope", "project",
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .usage)
    XCTAssertTrue(run.stderr.isEmpty)
    let runFailure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(runFailure.target, "../worker-only-single-step")
    XCTAssertEqual(runFailure.exitCode, CLIExitCode.usage.rawValue)
    XCTAssertTrue(runFailure.error.contains("invalid scoped workflow or package name"))
  }

  func testWorkflowResolutionSkipsNonWorkflowPackages() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-non-workflow-package-\(UUID().uuidString)", isDirectory: true)
    let packageDirectory = tempDir
      .appendingPathComponent(".riela/packages/addon-only", isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try """
    {
      "name": "addon-only",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Addon-only package",
      "tags": [],
      "registry": "local",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "checksumAlgorithm": "md5",
      "addons": [{
        "name": "demo-addon",
        "version": "1.0.0",
        "sourcePath": "addons/demo-addon",
        "contentDigest": "sha256:\(String(repeating: "a", count: 64))",
        "capabilities": [{"name": "process.spawn", "reason": "runs package command"}],
        "execution": {"kind": "local-command", "entrypoint": "run.sh"}
      }]
    }
    """.write(to: packageDirectory.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "addon-only",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertEqual(failure.workflowId, "addon-only")
    XCTAssertTrue(failure.error.contains("not found"), failure.error)
    XCTAssertFalse(failure.error.contains("package source validation failed"), failure.error)
  }

  func testScopedWorkflowResolutionRejectsSymlinkEscapes() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-symlink-escape-\(UUID().uuidString)", isDirectory: true)
    let scopedRoot = tempDir
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
    try FileManager.default.createDirectory(at: scopedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createSymbolicLink(
      at: scopedRoot.appendingPathComponent("escape"),
      withDestinationURL: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step").standardizedFileURL
    )

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "escape",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertFalse(validateFailure.valid)
    XCTAssertEqual(validateFailure.workflowId, "escape")
    XCTAssertTrue(validateFailure.error.contains("escapes"))

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", "escape",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .failure)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.workflowId, "escape")
    XCTAssertTrue(inspectFailure.error.contains("escapes"))

    let run = await RielaCLIApplication().run([
      "workflow", "run", "escape",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stderr.isEmpty)
    let runFailure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(runFailure.target, "escape")
    XCTAssertTrue(runFailure.error.contains("escapes"))
  }

  func testScopedWorkflowResolutionRejectsSymlinkedWorkflowJSON() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-workflow-json-symlink-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
      .appendingPathComponent("escape", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createSymbolicLink(
      at: workflowDir.appendingPathComponent("workflow.json"),
      withDestinationURL: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json").standardizedFileURL
    )

    try await assertScopedProjectWorkflowEscapeRejected(workingDirectory: tempDir)
  }

  func testScopedWorkflowResolutionRejectsSymlinkedNodePayload() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-node-payload-symlink-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("workflows", isDirectory: true)
      .appendingPathComponent("escape", isDirectory: true)
    let nodesDir = workflowDir.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let workflowJSON = try String(
      contentsOfFile: "\(root)/examples/worker-only-single-step/workflow.json",
      encoding: .utf8
    )
    try workflowJSON.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: nodesDir.appendingPathComponent("node-main-worker.json"),
      withDestinationURL: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes/node-main-worker.json").standardizedFileURL
    )

    try await assertScopedProjectWorkflowEscapeRejected(workingDirectory: tempDir)
  }

  func testAddonOnlyExecutableValidationMatchesDeterministicRunFailure() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-addon-only-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir.appendingPathComponent("addon-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try """
    {
      "workflowId": "addon-demo",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "addon-step",
      "nodes": [
        { "id": "addon-node", "addon": { "name": "missing-addon" } }
      ],
      "steps": [
        { "id": "addon-step", "nodeId": "addon-node", "role": "worker" }
      ]
    }
    """.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "addon-demo",
      "--workflow-definition-dir", tempDir.path,
      "--executable",
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertFalse(validation.valid)
    XCTAssertEqual(validation.nodeValidationResults.count, 1)
    XCTAssertEqual(validation.nodeValidationResults.first?.nodeId, "addon-node")
    XCTAssertEqual(validation.nodeValidationResults.first?.valid, false)
    XCTAssertTrue(validation.nodeValidationResults.first?.message.contains("require an add-on resolver") == true)

    let run = await RielaCLIApplication().run([
      "workflow", "run", "addon-demo",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(failure.target, "addon-demo")
    XCTAssertTrue(failure.error.contains("missing add-on resolver"))
  }

  func testInspectReportsNativeBundleAddonMetadataWithoutPassiveLoading() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-native-bundle-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir.appendingPathComponent("native-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let contentDigest = "sha256:\(String(repeating: "a", count: 64))"
    let dependencyDigest = "sha256:\(String(repeating: "b", count: 64))"
    let signingDigest = "sha256:\(String(repeating: "c", count: 64))"
    try """
    {
      "workflowId": "native-demo",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "native-step",
      "nodes": [
        { "id": "native-node", "addon": { "name": "native-runner", "version": "1.0.0" } }
      ],
      "steps": [
        { "id": "native-step", "nodeId": "native-node", "role": "worker" }
      ]
    }
    """.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "name": "native-workflow",
      "version": "1.0.0",
      "kind": "workflow",
      "description": "Native bundle workflow",
      "tags": [],
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5",
      "dependencies": [{
        "packageId": "native-addon-package",
        "kind": "node-addon",
        "addons": [{
          "name": "native-runner",
          "version": "1.0.0",
          "executionKind": "native-bundle",
          "abiVersion": 1,
          "bundleIdentifier": "com.example.riela.NativeRunner",
          "contentDigest": "\(contentDigest)",
          "dependencyClosureDigest": "\(dependencyDigest)",
          "codeSignatureRequirementDigest": "\(signingDigest)",
          "sourceScope": "project",
          "capabilityGrant": {
            "attachment.read": { "allowed": true, "scope": "attachments/input" }
          }
        }]
      }]
    }
    """.write(to: workflowDir.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let validate = await app.run([
      "workflow", "validate", "native-demo",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .success)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertTrue(validation.valid)
    XCTAssertEqual(validation.sourceKind, .package)
    XCTAssertEqual(validation.packageDirectory, workflowDir.path)
    XCTAssertEqual(validation.mutable, false)
    XCTAssertEqual(validation.nodeValidationResults, [])

    let inspect = await app.run([
      "workflow", "inspect", "native-demo",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .success)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    XCTAssertEqual(summary.sourceKind, .package)
    XCTAssertEqual(summary.packageDirectory, workflowDir.path)
    XCTAssertEqual(summary.mutable, false)
    let native = try XCTUnwrap(summary.nativeBundleAddons.first)
    XCTAssertEqual(native.nodeId, "native-node")
    XCTAssertEqual(native.addon, "native-runner")
    XCTAssertEqual(native.sourceKind, "native-bundle")
    XCTAssertEqual(native.sourceScope, "project")
    XCTAssertEqual(native.packageName, "native-addon-package")
    XCTAssertEqual(native.bundleIdentifier, "com.example.riela.NativeRunner")
    XCTAssertEqual(native.abiVersion, 1)
    XCTAssertEqual(native.contentDigest, contentDigest)
    XCTAssertEqual(native.dependencyClosureDigest, dependencyDigest)
    XCTAssertTrue(native.signingRequired)
    XCTAssertNil(native.signingVerified)
    XCTAssertEqual(native.cacheStatus, "not_loaded")
    XCTAssertNil(native.preflightHelperStatus)

    let executable = await app.run([
      "workflow", "validate", "native-demo",
      "--workflow-definition-dir", tempDir.path,
      "--executable",
      "--output", "json"
    ])
    XCTAssertEqual(executable.exitCode, .failure)
    let executableValidation = try decodeJSON(WorkflowValidationCommandResult.self, from: executable.stdout)
    XCTAssertFalse(executableValidation.valid)
    XCTAssertTrue(executableValidation.nodeValidationResults.first?.message.contains("preflight helper unavailable") == true)
  }

  func testValidateJSONFailureReturnsParseableEnvelopeForMissingWorkflow() async throws {
    let result = await RielaCLIApplication().run([
      "workflow", "validate", "definitely-missing-workflow",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: result.stdout)
    XCTAssertFalse(failure.valid)
    XCTAssertEqual(failure.workflowId, "definitely-missing-workflow")
    XCTAssertEqual(failure.exitCode, CLIExitCode.failure.rawValue)
    XCTAssertTrue(failure.error.contains("notFound"))
  }

  func testValidateJSONFailureReturnsDiagnosticsForInvalidWorkflow() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-invalid-workflow-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir.appendingPathComponent("broken", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try """
    {
      "workflowId": "broken",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "missing-entry",
      "nodes": [{ "id": "node", "nodeFile": "nodes/node.json" }],
      "steps": [{ "id": "step", "nodeId": "node", "role": "worker" }]
    }
    """.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let result = await RielaCLIApplication().run([
      "workflow", "validate", "broken",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: result.stdout)
    XCTAssertFalse(failure.valid)
    XCTAssertEqual(failure.workflowId, "broken")
    XCTAssertTrue(failure.error.contains("invalidWorkflow"))
    XCTAssertTrue(failure.diagnostics.contains {
      $0.path == "workflow.entryStepId" && $0.message.contains("missing-entry")
    })
  }

  func testValidateJSONFailureReturnsParseableEnvelopeForMalformedNodePatch() async throws {
    let root = repositoryRoot()
    let result = await RielaCLIApplication().run([
      "workflow", "validate", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--node-patch", #"{"unterminated": true"#,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowValidationFailureResult.self, from: result.stdout)
    XCTAssertFalse(failure.valid)
    XCTAssertEqual(failure.workflowId, "worker-only-single-step")
    XCTAssertFalse(failure.error.isEmpty)
  }

  func testWorkflowCatalogAndManifestCommandsReturnBehaviorOutput() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-catalog-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let workflowsRoot = tempDir.appendingPathComponent(".riela/workflows", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowsRoot, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: workflowsRoot.appendingPathComponent("demo")
    )

    let app = RielaCLIApplication()
    let list = await app.run([
      "workflow", "list",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(list.exitCode, .success)
    XCTAssertTrue(list.stderr.isEmpty)
    let listed = try decodeJSON(WorkflowCatalogResult.self, from: list.stdout)
    XCTAssertEqual(listed.workflows.map(\.workflowName), ["demo"])
    XCTAssertEqual(listed.workflows.first?.scope, .project)
    XCTAssertEqual(listed.workflows.first?.valid, true)

    let status = await app.run([
      "workflow", "status", "demo",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "table"
    ])
    XCTAssertEqual(status.exitCode, .success)
    XCTAssertTrue(status.stderr.isEmpty)
    XCTAssertTrue(status.stdout.contains("WORKFLOW\tSCOPE\tSOURCE\tSTATUS\tDIRECTORY"))
    XCTAssertTrue(status.stdout.contains("demo\tproject\tworkflow\tvalid"))

    let manifestURL = tempDir.appendingPathComponent("riela-package.json")
    try """
    {
      "name": "workflow-package",
      "version": "1.0.0",
      "description": "Workflow package",
      "tags": ["sample"],
      "registry": "default",
      "checksum": "abc123",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "missing-workflow"
    }
    """.write(to: manifestURL, atomically: true, encoding: .utf8)
    let manifest = await app.run([
      "workflow", "manifest", "validate", manifestURL.path,
      "--output", "json"
    ])
    XCTAssertEqual(manifest.exitCode, .usage)
    XCTAssertTrue(manifest.stderr.isEmpty)
    let manifestResult = try decodeJSON(WorkflowManifestValidationCommandResult.self, from: manifest.stdout)
    XCTAssertFalse(manifestResult.valid)
    XCTAssertTrue(manifestResult.issues.contains { $0.path == "workflowDirectory" || $0.message.contains("workflow.json not found") })

    let envManifest = await app.run([
      "workflow", "manifest", "validate",
      "--output", "json"
    ], environment: ["RIELA_WORKFLOW_MANIFEST": manifestURL.path])
    XCTAssertEqual(envManifest.exitCode, .usage)
    XCTAssertTrue(envManifest.stderr.isEmpty)
    let envManifestResult = try decodeJSON(WorkflowManifestValidationCommandResult.self, from: envManifest.stdout)
    XCTAssertEqual(envManifestResult.manifestPath, manifestURL.path)
  }

  func testSessionInspectionCommandsReturnPersistedSessionBehavior() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-sessions-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }

    let run = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: run.stdout)
    let runtimeRoot = sessionStore.appendingPathComponent("runtime-records", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRoot
      .appendingPathComponent(runResult.session.sessionId, isDirectory: true)
      .appendingPathComponent("runtime-snapshot.json").path))

    for command in ["status", "progress", "health", "step-runs", "export", "logs"] {
      let result = await RielaCLIApplication().run([
        "session", command, runResult.session.sessionId,
        "--session-store", sessionStore.path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, command)
      XCTAssertTrue(result.stderr.isEmpty, command)
      let inspection = try decodeJSON(SessionInspectionCommandResult.self, from: result.stdout)
      XCTAssertEqual(inspection.sessionId, runResult.session.sessionId, command)
      XCTAssertEqual(inspection.workflowName, "worker-only-single-step", command)
      XCTAssertEqual(inspection.status, .completed, command)
      XCTAssertEqual(inspection.executionCount, 1, command)
      if command == "health" {
        XCTAssertEqual(inspection.health, "ok")
      }
      if command == "status" || command == "step-runs" || command == "export" {
        XCTAssertEqual(inspection.executions.first?.stepId, "main-worker", command)
      }
    }
    XCTAssertEqual(
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot.path)
        .load(sessionId: runResult.session.sessionId)
        .session
        .sessionId,
      runResult.session.sessionId
    )
  }

  func testPackageRegistryReadOnlyCommandsDoNotInitializeRegistryConfig() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-registry-readonly-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )
    let registryConfig = tempDir
      .appendingPathComponent(".riela/workflow-packages", isDirectory: true)
      .appendingPathComponent("registries.json")

    let app = RielaCLIApplication()
    let registryList = await app.run([
      "package", "registry", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registryList.exitCode, .success, registryList.stderr)
    let listedRegistry = try decodeJSON(WorkflowPackageRegistryConfig.self, from: registryList.stdout)
    XCTAssertEqual(listedRegistry.defaultRegistryId, "default")
    XCTAssertEqual(listedRegistry.registries.map(\.id), ["default"])
    XCTAssertEqual(listedRegistry.registries.map(\.url), ["https://github.com/tacogips/riela-packages"])
    XCTAssertEqual(listedRegistry.registries.first?.localPath, "\(tempDir.path)-packages")
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryConfig.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryConfig.deletingLastPathComponent().path))

    let publishDryRun = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "dry-run-package",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(publishDryRun.exitCode, .success, publishDryRun.stderr)
    let published = try decodeJSON(WorkflowPackageCommandResult.self, from: publishDryRun.stdout)
    XCTAssertEqual(published.dryRun, true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryConfig.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: registryConfig.deletingLastPathComponent().path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-registry").path))
  }

  func testDefaultPackageRegistryUsesRielaPackagesWithoutPersistedConfig() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-default-registry-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    defer { try? FileManager.default.removeItem(atPath: "\(tempDir.path)-packages") }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )

    let app = RielaCLIApplication()
    let publish = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "default-registry-package",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])

    XCTAssertEqual(publish.exitCode, .success, publish.stderr)
    let publishResult = try decodeJSON(WorkflowPackageCommandResult.self, from: publish.stdout)
    let registryRecord = try decodeJSON(JSONObject.self, from: String(contentsOfFile: try XCTUnwrap(publishResult.destinationDirectory)))
    XCTAssertEqual(registryRecord["registry"]?.stringValue, "default")
    XCTAssertEqual(registryRecord["registryUrl"]?.stringValue, "https://github.com/tacogips/riela-packages")
    XCTAssertEqual(registryRecord["registryRef"]?.stringValue, "main")
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir.path)-packages/registry/default-registry-package.json"))
  }

  func testPackagePublishDryRunReportsRequiredLoopReadinessIssues() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-package-loop-readiness-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: packageSource
    )
    try """
    {
      "workflowId": "worker-only-single-step",
      "description": "Required loop workflow missing package readiness declarations.",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "main-worker",
      "loop": { "required": true },
      "nodes": [{ "id": "main-worker", "nodeFile": "nodes/node-main-worker.json" }],
      "steps": [{ "id": "main-worker", "nodeId": "main-worker", "role": "worker" }]
    }
    """.write(to: packageSource.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let missing = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "loop-readiness-missing",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(missing.exitCode, .success, missing.stderr)
    let missingResult = try decodeJSON(WorkflowPackageCommandResult.self, from: missing.stdout)
    let missingSummary = try XCTUnwrap(missingResult.packages.first)
    XCTAssertFalse(missingSummary.valid)
    XCTAssertTrue(missingSummary.issues.allSatisfy { $0.code == "LOOP_READINESS" })
    XCTAssertTrue(missingSummary.issues.contains { $0.path == "workflow.loop.evidence.required" })
    XCTAssertTrue(missingSummary.issues.contains { $0.path == "workflow.loop.gates" })
    XCTAssertTrue(missingSummary.issues.contains { $0.path == "workflow.loop.policies.mutation" })
    XCTAssertTrue(missingSummary.issues.contains { $0.path == "workflow.loop.policies.process" })

    try """
    {
      "workflowId": "worker-only-single-step",
      "description": "Required loop workflow with package readiness declarations.",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "main-worker",
      "loop": {
        "required": true,
        "evidence": { "required": true, "artifactRootPolicy": "runtime-owned" },
        "policies": {
          "mutation": {
            "allowedWriteRoots": ["Sources", "Tests", "tmp"],
            "scratchRoot": "tmp",
            "commit": "deny",
            "push": "deny"
          },
          "process": {
            "nestedRiela": "deny",
            "nestedCodex": "deny",
            "allowedBackends": ["codex-agent"]
          }
        },
        "implementationPlan": { "required": true, "pathPattern": "impl-plans/active/*.md" },
        "gates": [{ "id": "implementation-review", "stepId": "main-worker", "required": true }]
      },
      "nodes": [{ "id": "main-worker", "nodeFile": "nodes/node-main-worker.json" }],
      "steps": [{ "id": "main-worker", "nodeId": "main-worker", "role": "worker" }]
    }
    """.write(to: packageSource.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let ready = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "loop-readiness-ready",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(ready.exitCode, .success, ready.stderr)
    let readyResult = try decodeJSON(WorkflowPackageCommandResult.self, from: ready.stdout)
    let readySummary = try XCTUnwrap(readyResult.packages.first)
    XCTAssertTrue(readySummary.valid)
    XCTAssertEqual(readySummary.issues, [])
  }

  func testPackageCommandsUseRielaFixtureRegistryLocalPath() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-fixture-registry-\(UUID().uuidString)", isDirectory: true)
    let fixtureRegistry = tempDir.appendingPathComponent("riela-fixture", isDirectory: true)
    let fixturePackage = fixtureRegistry
      .appendingPathComponent("packages/fixture-clean-workflow", isDirectory: true)
    let fixtureWorkflow = fixturePackage
      .appendingPathComponent("workflows/fixture-clean-workflow", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: fixtureWorkflow.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: fixtureWorkflow
    )
    try """
    {
      "name": "fixture-clean-workflow",
      "version": "1.0.0",
      "description": "Safe fixture package used to verify successful package search and checkout.",
      "tags": ["fixture"],
      "workflow": {
        "description": "Safe fixture package used to verify successful package search and checkout.",
        "tags": ["fixture"],
        "backends": ["codex-agent"]
      },
      "registry": "fixture",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "workflows/fixture-clean-workflow",
      "repository": "https://github.com/tacogips/riela-fixture"
    }
    """.write(to: fixturePackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    let invalidFixturePackage = fixtureRegistry
      .appendingPathComponent("packages/fixture-invalid-metadata-workflow", isDirectory: true)
    try FileManager.default.createDirectory(at: invalidFixturePackage, withIntermediateDirectories: true)
    try """
    {
      "name": "fixture-invalid-metadata-workflow",
      "version": "1.0.0",
      "description": "Invalid fixture package used to verify registry search resilience.",
      "tags": ["fixture"],
      "workflow": {
        "title": 1,
        "description": "Invalid structured workflow metadata.",
        "tags": ["fixture"]
      },
      "registry": "fixture",
      "checksum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "workflows/fixture-invalid-metadata-workflow",
      "repository": "https://github.com/tacogips/riela-fixture"
    }
    """.write(
      to: invalidFixturePackage.appendingPathComponent("riela-package.json"),
      atomically: true,
      encoding: .utf8
    )

    let app = RielaCLIApplication()
    let directSearch = await app.run([
      "package", "search", "fixture-clean",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", fixtureRegistry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(directSearch.exitCode, .success, directSearch.stderr)
    let directSearchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: directSearch.stdout)
    XCTAssertEqual(directSearchResult.packages.map(\.name), ["fixture-clean-workflow"])
    XCTAssertTrue(
      try XCTUnwrap(directSearchResult.packages.first?.packageDirectory)
        .hasSuffix("/riela-fixture/packages/fixture-clean-workflow")
    )
    XCTAssertEqual(directSearchResult.packages.first?.valid, true)

    let invalidSearch = await app.run([
      "package", "search", "fixture-invalid",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", fixtureRegistry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(invalidSearch.exitCode, .success, invalidSearch.stderr)
    let invalidSearchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: invalidSearch.stdout)
    XCTAssertEqual(invalidSearchResult.packages.map(\.name), ["fixture-invalid-metadata-workflow"])
    XCTAssertEqual(invalidSearchResult.packages.first?.valid, false)
    XCTAssertEqual(invalidSearchResult.packages.first?.issues.first?.path, "riela-package.json")

    let registryAdd = await app.run([
      "package", "registry", "add", "fixture",
      "--registry-url", "https://github.com/tacogips/riela-fixture",
      "--registry-local-path", fixtureRegistry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registryAdd.exitCode, .success, registryAdd.stderr)

    let registeredSearch = await app.run([
      "package", "search", "fixture-clean",
      "--registry", "fixture",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registeredSearch.exitCode, .success, registeredSearch.stderr)
    let registeredSearchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: registeredSearch.stdout)
    XCTAssertEqual(registeredSearchResult.packages.map(\.name), ["fixture-clean-workflow"])

    let install = await app.run([
      "package", "install", "fixture-clean-workflow",
      "--registry", "fixture",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedPackage = tempDir.appendingPathComponent(".riela/packages/fixture-clean-workflow", isDirectory: true)
    XCTAssertEqual(installed.destinationDirectory, installedPackage.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedPackage.appendingPathComponent("riela-package.json").path))

    let packageRun = await app.run([
      "package", "temp-run", "fixture-clean-workflow",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(packageRun.exitCode, .success, packageRun.stderr)
    let packageRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: packageRun.stdout)
    XCTAssertEqual(packageRunResult.target, "fixture-clean-workflow")
    XCTAssertNotNil(packageRunResult.runSessionId)
  }

  func testUserPackageInstallProjectsCodexSkillDirectory() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-user-codex-skill-\(UUID().uuidString)", isDirectory: true)
    let homeDir = tempDir.appendingPathComponent("home", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    let workflowDirectory = packageSource.appendingPathComponent("workflows/riela-package-manager-skill", isDirectory: true)
    let codexSkillDirectory = packageSource.appendingPathComponent("skills/codex/riela-package", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: workflowDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: codexSkillDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: workflowDirectory
    )
    try """
    # Riela Package

    Install and manage Riela packages.
    """.write(to: codexSkillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try """
    {
      "name": "riela-package-manager-skill",
      "version": "1.0.0",
      "description": "Package manager skill fixture.",
      "tags": ["skill", "package"],
      "registry": "fixture",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "workflows/riela-package-manager-skill",
      "skillDirectory": "skills"
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "riela-package-manager-skill",
      "--source", packageSource.path,
      "--scope", "user",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["HOME": homeDir.path])

    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedPackage = homeDir.appendingPathComponent(".riela/packages/riela-package-manager-skill", isDirectory: true)
    let projectedSkill = homeDir.appendingPathComponent(".codex/skills/riela-package/SKILL.md")
    XCTAssertEqual(installed.destinationDirectory, installedPackage.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedPackage.appendingPathComponent("riela-package.json").path))
    XCTAssertEqual(try String(contentsOf: projectedSkill), "# Riela Package\n\nInstall and manage Riela packages.")
  }

  func testWorkflowRunFromRegistryRejectsEscapingWorkflowDirectory() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-registry-run-escape-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let packageDirectory = tempDir
      .appendingPathComponent(".riela/packages/escape-package", isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    let app = RielaCLIApplication()

    for workflowDirectory in ["/tmp/outside-workflow", "../outside-workflow"] {
      try """
      {
        "name": "escape-package",
        "version": "1.0.0",
        "description": "Escape package",
        "tags": ["demo"],
        "registry": "local",
        "checksum": "cccccccccccccccccccccccccccccccc",
        "checksumAlgorithm": "md5",
        "workflowDirectory": "\(workflowDirectory)"
      }
      """.write(to: packageDirectory.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

      let result = await app.run([
        "workflow", "run", "escape-package",
        "--from-registry",
        "--working-dir", tempDir.path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .usage, workflowDirectory)
      XCTAssertTrue(result.stderr.isEmpty)
      let failure = try decodeJSON(WorkflowRunFailureResult.self, from: result.stdout)
      XCTAssertTrue(failure.error.contains("workflowDirectory: path must be package-relative"), failure.error)
    }
  }

  // This parity test intentionally exercises a command sequence with shared state; splitting it would weaken the scenario.
  // swiftlint:disable:next function_body_length
  func testWorkflowCreateCheckoutPackageSessionContinueAndScopedParityCommands() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-parity-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)

    let app = RielaCLIApplication()
    let create = await app.run([
      "workflow", "create", "created-flow",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(create.exitCode, .success, create.stderr)
    let created = try decodeJSON(WorkflowCreateCommandResult.self, from: create.stdout)
    XCTAssertEqual(created.workflowName, "created-flow")
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(created.workflowDirectory)/workflow.json"))
    let checkoutCache = tempDir
      .appendingPathComponent(".riela/workflow-checkout-sources/github-example-workflows-main-copied-flow", isDirectory: true)
      .appendingPathComponent("copied-flow", isDirectory: true)
    try FileManager.default.createDirectory(at: checkoutCache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: created.workflowDirectory), to: checkoutCache)

    let checkout = await app.run([
      "workflow", "checkout", "https://github.com/example/workflows/tree/main/copied-flow",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(checkout.exitCode, .success, checkout.stderr)
    let checkedOut = try decodeJSON(WorkflowCheckoutCommandResult.self, from: checkout.stdout)
    XCTAssertEqual(checkedOut.workflowName, "copied-flow")
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(checkedOut.destinationDirectory)/workflow.json"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/workflow-checkouts/copied-flow.json").path))

    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )
    try """
    {
      "name": "demo-package",
      "version": "1.0.0",
      "description": "Demo package",
      "tags": ["demo"],
      "registry": "local",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let install = await app.run([
      "package", "install", "demo-package",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    XCTAssertEqual(installed.destinationDirectory, tempDir.appendingPathComponent(".riela/packages/demo-package").path)

    let list = await app.run([
      "workflow", "package", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    let listed = try decodeJSON(WorkflowPackageCommandResult.self, from: list.stdout)
    XCTAssertEqual(listed.packages.map(\.name), ["demo-package"])
    XCTAssertEqual(listed.packages.first?.valid, true)

    let workflowList = await app.run([
      "workflow", "list",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(workflowList.exitCode, .success, workflowList.stderr)
    let listedWorkflows = try decodeJSON(WorkflowCatalogResult.self, from: workflowList.stdout)
    let packageCatalogEntry = try XCTUnwrap(listedWorkflows.workflows.first { $0.workflowName == "demo-package" })
    XCTAssertEqual(packageCatalogEntry.sourceKind, .package)
    XCTAssertEqual(packageCatalogEntry.packageName, "demo-package")
    XCTAssertEqual(packageCatalogEntry.mutable, false)
    XCTAssertEqual(packageCatalogEntry.valid, true)

    let packageValidate = await app.run([
      "workflow", "validate", "demo-package",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(packageValidate.exitCode, .success, packageValidate.stderr)
    let packageValidation = try decodeJSON(WorkflowValidationCommandResult.self, from: packageValidate.stdout)
    XCTAssertEqual(packageValidation.workflowId, "worker-only-single-step")
    XCTAssertEqual(packageValidation.sourceKind, .package)
    XCTAssertEqual(packageValidation.packageName, "demo-package")
    XCTAssertEqual(packageValidation.mutable, false)

    let packageInspect = await app.run([
      "workflow", "inspect", "demo-package",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(packageInspect.exitCode, .success, packageInspect.stderr)
    let workflowPackageInspection = try decodeJSON(WorkflowInspectionSummary.self, from: packageInspect.stdout)
    XCTAssertEqual(workflowPackageInspection.workflowId, "worker-only-single-step")
    XCTAssertEqual(workflowPackageInspection.sourceKind, .package)
    XCTAssertEqual(workflowPackageInspection.packageName, "demo-package")
    XCTAssertEqual(workflowPackageInspection.mutable, false)

    let packageWorkflowRun = await app.run([
      "workflow", "run", "demo-package",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(packageWorkflowRun.exitCode, .success, packageWorkflowRun.stderr)
    let packageWorkflowRunResult = try decodeJSON(WorkflowRunResult.self, from: packageWorkflowRun.stdout)
    XCTAssertEqual(packageWorkflowRunResult.workflowId, "worker-only-single-step")
    XCTAssertEqual(packageWorkflowRunResult.status, .completed)

    let registryAdd = await app.run([
      "package", "registry", "add", "local",
      "--registry-url", "https://github.com/example/registry",
      "--registry-local-path", tempDir.appendingPathComponent("local-registry").path,
      "--branch", "main",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registryAdd.exitCode, .success, registryAdd.stderr)
    let addedRegistry = try decodeJSON(WorkflowPackageRegistryConfig.self, from: registryAdd.stdout)
    XCTAssertEqual(addedRegistry.defaultRegistryId, "default")
    XCTAssertEqual(addedRegistry.registries.map(\.id), ["local", "default"])

    let registryList = await app.run([
      "workflow", "package", "registry", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(registryList.exitCode, .success, registryList.stderr)
    let listedRegistry = try decodeJSON(WorkflowPackageRegistryConfig.self, from: registryList.stdout)
    XCTAssertEqual(listedRegistry.registries.map(\.url), [
      "https://github.com/example/registry",
      "https://github.com/tacogips/riela-packages"
    ])

    let publish = await app.run([
      "workflow", "package", "publish", packageSource.path,
      "--package-name", "demo-package",
      "--dry-run",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(publish.exitCode, .success, publish.stderr)
    let published = try decodeJSON(WorkflowPackageCommandResult.self, from: publish.stdout)
    XCTAssertEqual(published.dryRun, true)

    let publishWrite = await app.run([
      "workflow", "package", "publish", packageSource.path,
      "--package-id", "demo-package",
      "--registry", "local",
      "--registry-local-path", tempDir.appendingPathComponent("local-registry").path,
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(publishWrite.exitCode, .success, publishWrite.stderr)
    let publishWriteResult = try decodeJSON(WorkflowPackageCommandResult.self, from: publishWrite.stdout)
    XCTAssertEqual(publishWriteResult.dryRun, false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(publishWriteResult.destinationDirectory)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-cache/demo-package.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-locks/demo-package.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/skills/demo-package/SKILL.md").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-native-addons/demo-package.json").path))

    let explicitRegistryRoot = tempDir.appendingPathComponent("explicit-url-registry", isDirectory: true)
    let explicitRegistryPublish = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "demo-package-url",
      "--registry", "https://github.com/acme/packages",
      "--registry-local-path", explicitRegistryRoot.path,
      "--branch", "release",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(explicitRegistryPublish.exitCode, .success, explicitRegistryPublish.stderr)
    let explicitRegistryResult = try decodeJSON(WorkflowPackageCommandResult.self, from: explicitRegistryPublish.stdout)
    let explicitRegistryRecordPath = try XCTUnwrap(explicitRegistryResult.destinationDirectory)
    let explicitRegistryRecord = try decodeJSON(JSONObject.self, from: String(contentsOfFile: explicitRegistryRecordPath))
    XCTAssertEqual(explicitRegistryRecord["registry"]?.stringValue, "github-acme-packages")
    XCTAssertEqual(explicitRegistryRecord["registryUrl"]?.stringValue, "https://github.com/acme/packages")
    XCTAssertEqual(explicitRegistryRecord["registryRef"]?.stringValue, "release")
    XCTAssertTrue(FileManager.default.fileExists(atPath: explicitRegistryRoot.appendingPathComponent("registry/demo-package-url.json").path))

    let registryURLPrecedencePublish = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "demo-package-url-precedence",
      "--registry", "local",
      "--registry-url", "https://github.com/override/packages",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(registryURLPrecedencePublish.exitCode, .success, registryURLPrecedencePublish.stderr)
    let registryURLPrecedenceResult = try decodeJSON(WorkflowPackageCommandResult.self, from: registryURLPrecedencePublish.stdout)
    let registryURLPrecedenceRecord = try decodeJSON(JSONObject.self, from: String(contentsOfFile: try XCTUnwrap(registryURLPrecedenceResult.destinationDirectory)))
    XCTAssertEqual(registryURLPrecedenceRecord["registry"]?.stringValue, "local")
    XCTAssertEqual(registryURLPrecedenceRecord["registryUrl"]?.stringValue, "https://github.com/override/packages")

    let runtimeRecordsRoot = tempDir.appendingPathComponent(".riela/sessions/runtime-records", isDirectory: true)
    let runtimeRecordCountBeforeDryRun = (try? FileManager.default.contentsOfDirectory(
      at: runtimeRecordsRoot,
      includingPropertiesForKeys: [.isDirectoryKey]
    ).count) ?? 0
    for command in ["run", "temp-run"] {
      let dryRun = await app.run([
        "package", command, "demo-package",
        "--dry-run",
        "--working-dir", tempDir.path,
        "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
        "--output", "json"
      ])
      XCTAssertEqual(dryRun.exitCode, .success, "\(command): \(dryRun.stderr) \(dryRun.stdout)")
      let dryRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: dryRun.stdout)
      XCTAssertEqual(dryRunResult.dryRun, true)
      XCTAssertNil(dryRunResult.runSessionId)
      let runtimeRecordCountAfterDryRun = (try? FileManager.default.contentsOfDirectory(
        at: runtimeRecordsRoot,
        includingPropertiesForKeys: [.isDirectoryKey]
      ).count) ?? 0
      XCTAssertEqual(runtimeRecordCountAfterDryRun, runtimeRecordCountBeforeDryRun)
    }

    let scopedPackageSource = tempDir.appendingPathComponent("scoped-package-source", isDirectory: true)
    try FileManager.default.copyItem(at: packageSource, to: scopedPackageSource)
    try """
    {
      "name": "@scope/scoped-flow",
      "version": "1.0.0",
      "description": "Scoped demo package",
      "tags": ["demo"],
      "registry": "local",
      "checksum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: scopedPackageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    let scopedInstall = await app.run([
      "package", "install", "@scope/scoped-flow",
      "--source", scopedPackageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(scopedInstall.exitCode, .success, scopedInstall.stderr)

    let scopedPackageValidate = await app.run([
      "workflow", "validate", "@scope/scoped-flow",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(scopedPackageValidate.exitCode, .success, scopedPackageValidate.stderr)
    let scopedPackageValidation = try decodeJSON(WorkflowValidationCommandResult.self, from: scopedPackageValidate.stdout)
    XCTAssertEqual(scopedPackageValidation.sourceKind, .package)
    XCTAssertEqual(scopedPackageValidation.packageName, "@scope/scoped-flow")

    let scopedRegistryRun = await app.run([
      "workflow", "run", "@scope/scoped-flow",
      "--from-registry",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(scopedRegistryRun.exitCode, .success, scopedRegistryRun.stderr)
    let scopedRegistryRunResult = try decodeJSON(WorkflowRunResult.self, from: scopedRegistryRun.stdout)
    XCTAssertEqual(scopedRegistryRunResult.workflowId, "worker-only-single-step")
    XCTAssertEqual(scopedRegistryRunResult.status, .completed)

    let registryRun = await app.run([
      "workflow", "run", "demo-package",
      "--from-registry",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(registryRun.exitCode, .success, registryRun.stderr)
    let registryRunResult = try decodeJSON(WorkflowRunResult.self, from: registryRun.stdout)
    XCTAssertEqual(registryRunResult.workflowId, "worker-only-single-step")
    XCTAssertEqual(registryRunResult.status, .completed)
    let registryRunSessionId = registryRunResult.session.sessionId

    let registryResume = await app.run([
      "session", "resume", registryRunSessionId,
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(registryResume.exitCode, .success, registryResume.stderr)
    let registryResumeResult = try decodeJSON(SessionResumeCommandResult.self, from: registryResume.stdout)
    XCTAssertEqual(registryResumeResult.sessionId, registryRunSessionId)

    let registryContinue = await app.run([
      "session", "continue", registryRunSessionId,
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(registryContinue.exitCode, .success, registryContinue.stderr)
    let registryContinueResult = try decodeJSON(SessionResumeCommandResult.self, from: registryContinue.stdout)
    XCTAssertEqual(registryContinueResult.sessionId, registryRunSessionId)

    let registryRerun = await app.run([
      "session", "rerun", registryRunSessionId, "main-worker",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(registryRerun.exitCode, .success, registryRerun.stderr)
    let registryRerunResult = try decodeJSON(SessionRerunCommandResult.self, from: registryRerun.stdout)
    XCTAssertEqual(registryRerunResult.sourceSessionId, registryRunSessionId)
    XCTAssertEqual(registryRerunResult.rerunFromStepId, "main-worker")

    let packageRun = await app.run([
      "package", "temp-run", "demo-package",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(packageRun.exitCode, .success, packageRun.stderr)
    let packageRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: packageRun.stdout)
    let packageRunSessionId = try XCTUnwrap(packageRunResult.runSessionId)
    let packageRuntimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: tempDir
      .appendingPathComponent(".riela/sessions/runtime-records", isDirectory: true)
      .path)
    XCTAssertEqual(try packageRuntimeStore.load(sessionId: packageRunSessionId).session.sessionId, packageRunSessionId)
    let secondPackageRun = await app.run([
      "package", "temp-run", "demo-package",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(secondPackageRun.exitCode, .success, secondPackageRun.stderr)
    let secondPackageRunResult = try decodeJSON(WorkflowPackageCommandResult.self, from: secondPackageRun.stdout)
    let secondPackageRunSessionId = try XCTUnwrap(secondPackageRunResult.runSessionId)
    XCTAssertNotEqual(secondPackageRunSessionId, packageRunSessionId)
    for sessionId in [packageRunSessionId, secondPackageRunSessionId] {
      XCTAssertEqual(try packageRuntimeStore.load(sessionId: sessionId).session.sessionId, sessionId)
    }
    let packageRunStatus = await app.run([
      "session", "status", packageRunSessionId,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(packageRunStatus.exitCode, .success, packageRunStatus.stderr)
    let packageInspection = try decodeJSON(SessionInspectionCommandResult.self, from: packageRunStatus.stdout)
    XCTAssertEqual(packageInspection.status, .completed)

    let selfImprove = await app.run([
      "workflow", "self-improve", "created-flow",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(selfImprove.exitCode, .success, selfImprove.stderr)
    let selfImproveResult = try decodeJSON(WorkflowSelfImproveCommandResult.self, from: selfImprove.stdout)
    XCTAssertEqual(selfImproveResult.workflowName, "created-flow")
    XCTAssertEqual(selfImproveResult.dryRun, false)
    XCTAssertEqual(selfImproveResult.mutated, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(created.workflowDirectory)/.riela-self-improve-patch.json"))
    XCTAssertTrue(try String(contentsOfFile: "\(created.workflowDirectory)/workflow.json").contains("self-improve-reviewed"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(selfImproveResult.backupDirectory)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(selfImproveResult.reportPath)))

    let autoImprove = await app.run([
      "workflow", "run", "supervised-mock-retry",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/supervised-mock-retry/mock-scenario.json",
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--auto-improve",
      "--max-supervised-attempts", "3",
      "--monitor-interval-ms", "1000",
      "--stall-timeout-ms", "2000",
      "--workflow-mutation-mode", "execution-copy",
      "--output", "json"
    ])
    XCTAssertEqual(autoImprove.exitCode, .success, autoImprove.stderr)
    let autoImproveResult = try decodeJSON(WorkflowRunResult.self, from: autoImprove.stdout)
    XCTAssertEqual(autoImproveResult.status, .completed)
    XCTAssertEqual(autoImproveResult.rootOutput?["status"], .string("ready"))
    let supervision = try XCTUnwrap(autoImproveResult.supervision)
    XCTAssertEqual(supervision["status"], .string("succeeded"))
    XCTAssertEqual(supervision["attempts"], .number(2))
    guard case let .object(policy)? = supervision["policy"] else {
      return XCTFail("expected supervision policy")
    }
    XCTAssertEqual(policy["maxSupervisedAttempts"], .number(3))
    XCTAssertEqual(policy["monitorIntervalMs"], .number(1000))
    XCTAssertEqual(policy["stallTimeoutMs"], .number(2000))
    XCTAssertEqual(policy["workflowMutationMode"], .string("execution-copy"))
    guard case let .array(incidents)? = supervision["incidents"] else {
      return XCTFail("expected supervision incidents")
    }
    XCTAssertEqual(incidents.count, 1)
    guard case let .object(incident)? = incidents.first else {
      return XCTFail("expected failure incident object")
    }
    XCTAssertEqual(incident["category"], .string("failure"))
    XCTAssertEqual(incident["stepId"], .string("main-worker"))
    guard case let .array(remediations)? = supervision["remediations"] else {
      return XCTFail("expected supervision remediations")
    }
    XCTAssertEqual(remediations.count, 1)
    guard case let .object(remediation)? = remediations.first else {
      return XCTFail("expected rerun remediation object")
    }
    XCTAssertEqual(remediation["action"], .string("rerun-workflow"))
    XCTAssertEqual(remediation["managerControl"], .string("session rerun"))
    XCTAssertEqual(remediation["targetSessionId"], .string(autoImproveResult.session.sessionId))
    XCTAssertNotEqual(remediation["sourceSessionId"], remediation["targetSessionId"])
    let supervisionRecord = tempDir
      .appendingPathComponent("sessions/runtime-records", isDirectory: true)
      .appendingPathComponent(autoImproveResult.session.sessionId, isDirectory: true)
      .appendingPathComponent("supervision-record.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: supervisionRecord.path))
    let persistedSupervision = try decodeJSON(
      JSONObject.self,
      from: String(contentsOf: supervisionRecord, encoding: .utf8)
    )
    XCTAssertEqual(persistedSupervision["status"], .string("succeeded"))
    XCTAssertEqual(persistedSupervision["targetSessionId"], .string(autoImproveResult.session.sessionId))
    XCTAssertEqual(persistedSupervision["attempts"], .number(2))

    let run = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success, run.stderr)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: run.stdout)
    let runtimeRecordRoot = tempDir
      .appendingPathComponent("sessions/runtime-records", isDirectory: true)
      .appendingPathComponent(runResult.session.sessionId, isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRecordRoot.appendingPathComponent("supervision-record.json").path))
    let secondRun = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(secondRun.exitCode, .success, secondRun.stderr)
    let secondRunResult = try decodeJSON(WorkflowRunResult.self, from: secondRun.stdout)
    XCTAssertNotEqual(secondRunResult.session.sessionId, runResult.session.sessionId)
    let normalRuntimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: tempDir
      .appendingPathComponent("sessions/runtime-records", isDirectory: true)
      .path)
    for sessionId in [runResult.session.sessionId, secondRunResult.session.sessionId] {
      XCTAssertEqual(try normalRuntimeStore.load(sessionId: sessionId).session.sessionId, sessionId)
    }
    let transitionWorkflowRoot = tempDir.appendingPathComponent("transition-workflows", isDirectory: true)
    let transitionWorkflow = try writeTwoStepWorkflow(at: transitionWorkflowRoot, workflowName: "two-step")
    let transitionSessionStore = tempDir.appendingPathComponent("transition-sessions", isDirectory: true)
    let transitionRun = await app.run([
      "workflow", "run", "two-step",
      "--workflow-definition-dir", transitionWorkflowRoot.path,
      "--mock-scenario", transitionWorkflow.scenarioPath,
      "--session-store", transitionSessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(transitionRun.exitCode, .success, transitionRun.stderr)
    let transitionRunResult = try decodeJSON(WorkflowRunResult.self, from: transitionRun.stdout)
    let secondTransitionRun = await app.run([
      "workflow", "run", "two-step",
      "--workflow-definition-dir", transitionWorkflowRoot.path,
      "--mock-scenario", transitionWorkflow.scenarioPath,
      "--session-store", transitionSessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(secondTransitionRun.exitCode, .success, secondTransitionRun.stderr)
    let secondTransitionRunResult = try decodeJSON(WorkflowRunResult.self, from: secondTransitionRun.stdout)
    let transitionPersistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: transitionSessionStore.path))
    let transitionCommunicationIds = try transitionPersistence
      .load(sessionId: transitionRunResult.session.sessionId)
      .workflowMessages
      .map(\.communicationId)
    let secondTransitionCommunicationIds = try transitionPersistence
      .load(sessionId: secondTransitionRunResult.session.sessionId)
      .workflowMessages
      .map(\.communicationId)
    XCTAssertEqual(transitionCommunicationIds, ["comm-000001"])
    XCTAssertEqual(secondTransitionCommunicationIds, ["comm-000002"])
    for communicationId in transitionCommunicationIds + secondTransitionCommunicationIds {
      for command in ["retry-communication", "replay-communication"] {
        let graphResult = await app.run([
          "graphql", command, communicationId,
          "--session-store", transitionSessionStore.path,
          "--output", "json"
        ])
        XCTAssertEqual(graphResult.exitCode, .success, "\(command) \(communicationId): \(graphResult.stderr) \(graphResult.stdout)")
      }
    }
    let preexistingResumeMessage = WorkflowMessageRecord(
      communicationId: "comm-000001",
      workflowExecutionId: runResult.session.sessionId,
      fromStepId: nil,
      toStepId: "main-worker",
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: "resume-source-exec",
      payload: ["mode": .string("preserve-on-resume")],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: Date(timeIntervalSince1970: 0)
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: tempDir.appendingPathComponent("sessions", isDirectory: true).path)).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: runResult.session, workflowMessages: [preexistingResumeMessage])
    )
    let continued = await app.run([
      "session", "continue", runResult.session.sessionId,
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(continued.exitCode, .success, continued.stderr)
    let continueResult = try decodeJSON(SessionResumeCommandResult.self, from: continued.stdout)
    XCTAssertEqual(continueResult.sessionId, runResult.session.sessionId)
    let continuedSnapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: tempDir.appendingPathComponent("sessions", isDirectory: true).path))
      .load(sessionId: runResult.session.sessionId)
    XCTAssertTrue(continuedSnapshot.workflowMessages.contains { $0.communicationId == "comm-000001" && $0.payload["mode"] == .string("preserve-on-resume") })
    let eventConfig = tempDir.appendingPathComponent("events.json")
    try """
    {
      "sources": [{"id":"web-a","kind":"webhook","path":"/events/web","signingSecretEnv":"WEBHOOK_SECRET"}],
      "bindings": [{"id":"bind-a","sourceId":"web-a","workflowName":"worker-only-single-step","inputMapping":{"mode":"event-input"}}]
    }
    """.write(to: eventConfig, atomically: true, encoding: .utf8)

    let eventEnvelope = tempDir.appendingPathComponent("event-envelope.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "event-1",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "event-input"}
    }
    """.write(to: eventEnvelope, atomically: true, encoding: .utf8)

    for command in [
      ["events", "validate", eventConfig.path],
      ["events", "list", eventConfig.path],
      ["events", "emit", eventConfig.path, "--variables", eventEnvelope.path],
      ["hook", "codex"],
      ["graphql", "schema"],
      ["graphql", "session", runResult.session.sessionId, "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path],
      ["serve", "status"],
      ["serve", "graphql"]
    ] {
      let result = await app.run(command + ["--output", "json"])
      XCTAssertEqual(result.exitCode, .success, command.joined(separator: " "))
      let scoped = try decodeJSON(ScopedParityCommandResult.self, from: result.stdout)
      XCTAssertEqual(scoped.status, "ok")
    }

    let eventRoot = tempDir.appendingPathComponent("event-root", isDirectory: true)
    let eventEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", eventEnvelope.path,
      "--output", "json"
    ])
    XCTAssertEqual(eventEmit.exitCode, .success, eventEmit.stderr)
    let eventEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: eventEmit.stdout)
    XCTAssertEqual(eventEmitResult.status, "ok")
    let eventReceiptId = try XCTUnwrap(eventEmitResult.records.first { $0.hasPrefix("receipt=") }?.dropFirst("receipt=".count).description)
    let eventReceiptURL = eventRoot.appendingPathComponent("receipts/\(eventReceiptId).json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventReceiptURL.path))

    let readOnlyEventEnvelope = tempDir.appendingPathComponent("event-envelope-read-only.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "event-read-only",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "read-only-input"}
    }
    """.write(to: readOnlyEventEnvelope, atomically: true, encoding: .utf8)
    let readOnlyEventEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", readOnlyEventEnvelope.path,
      "--read-only",
      "--output", "json"
    ])
    XCTAssertEqual(readOnlyEventEmit.exitCode, .success, readOnlyEventEmit.stderr)
    let readOnlyEventEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: readOnlyEventEmit.stdout)
    XCTAssertEqual(readOnlyEventEmitResult.status, "ok")

    let duplicateEventEnvelope = tempDir.appendingPathComponent("event-envelope-duplicate.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "event-1",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "duplicate-input"}
    }
    """.write(to: duplicateEventEnvelope, atomically: true, encoding: .utf8)
    let duplicateEventEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", duplicateEventEnvelope.path,
      "--output", "json"
    ])
    XCTAssertEqual(duplicateEventEmit.exitCode, .success, duplicateEventEmit.stderr)
    let duplicateEventEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: duplicateEventEmit.stdout)
    XCTAssertEqual(duplicateEventEmitResult.status, "duplicate")
    XCTAssertTrue(duplicateEventEmitResult.records.contains { $0.contains("duplicate=true") })
    let originalReceiptText = try String(contentsOf: eventReceiptURL, encoding: .utf8)
    XCTAssertTrue(originalReceiptText.contains("event-input"))
    XCTAssertFalse(originalReceiptText.contains("duplicate-input"))

    let eventList = await app.run([
      "events", "list", "web-a",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(eventList.exitCode, .success, eventList.stderr)
    let eventListResult = try decodeJSON(ScopedParityCommandResult.self, from: eventList.stdout)
    XCTAssertTrue(eventListResult.records.contains { $0.contains(eventReceiptId) })

    let eventReplay = await app.run([
      "events", "replay", eventReceiptId,
      "--event-root", eventRoot.path,
      "--reason", "test",
      "--output", "json"
    ])
    XCTAssertEqual(eventReplay.exitCode, .success, eventReplay.stderr)
    let eventReplayResult = try decodeJSON(ScopedParityCommandResult.self, from: eventReplay.stdout)
    XCTAssertEqual(eventReplayResult.status, "ok")
    let eventReplayReceiptId = try XCTUnwrap(eventReplayResult.records.first { $0.hasPrefix("receipt=") }?.dropFirst("receipt=".count).description)
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("receipts/\(eventReplayReceiptId).json").path))

    let slashEventEnvelope = tempDir.appendingPathComponent("event-envelope-slash.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "a/b",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "slash"}
    }
    """.write(to: slashEventEnvelope, atomically: true, encoding: .utf8)
    let colonEventEnvelope = tempDir.appendingPathComponent("event-envelope-colon.json")
    try """
    {
      "sourceId": "web-a",
      "eventId": "a:b",
      "provider": "webhook",
      "eventType": "event-input",
      "input": {"mode": "colon"}
    }
    """.write(to: colonEventEnvelope, atomically: true, encoding: .utf8)
    let slashEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", slashEventEnvelope.path,
      "--output", "json"
    ])
    let colonEmit = await app.run([
      "events", "emit", "web-a",
      "--event-root", eventRoot.path,
      "--event-file", colonEventEnvelope.path,
      "--output", "json"
    ])
    XCTAssertEqual(slashEmit.exitCode, .success, slashEmit.stderr)
    XCTAssertEqual(colonEmit.exitCode, .success, colonEmit.stderr)
    let slashEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: slashEmit.stdout)
    let colonEmitResult = try decodeJSON(ScopedParityCommandResult.self, from: colonEmit.stdout)
    XCTAssertEqual(slashEmitResult.status, "ok")
    XCTAssertEqual(colonEmitResult.status, "ok")
    let slashReceiptId = try XCTUnwrap(slashEmitResult.records.first { $0.hasPrefix("receipt=") }?.dropFirst("receipt=".count).description)
    let colonReceiptId = try XCTUnwrap(colonEmitResult.records.first { $0.hasPrefix("receipt=") }?.dropFirst("receipt=".count).description)
    XCTAssertNotEqual(slashReceiptId, colonReceiptId)
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("receipts/\(slashReceiptId).json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("receipts/\(colonReceiptId).json").path))

    let eventServe = await app.run([
      "events", "serve",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(eventServe.exitCode, .success, eventServe.stderr)
    let eventServeResult = try decodeJSON(ScopedParityCommandResult.self, from: eventServe.stdout)
    XCTAssertEqual(eventServeResult.status, "ok")
    XCTAssertTrue(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("serve-record.json").path))

    let liveEventRoot = tempDir.appendingPathComponent("live-event-root", isDirectory: true)
    try FileManager.default.createDirectory(at: liveEventRoot.appendingPathComponent("sources", isDirectory: true), withIntermediateDirectories: true)
    try """
    {
      "id": "telegram-live",
      "kind": "telegram-gateway",
      "provider": "telegram",
      "tokenEnv": "RIELA_TELEGRAM_BOT_TOKEN"
    }
    """.write(
      to: liveEventRoot.appendingPathComponent("sources/telegram-live.json"),
      atomically: true,
      encoding: .utf8
    )
    let liveEventServe = await app.run([
      "events", "serve",
      "--event-root", liveEventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(liveEventServe.exitCode, .success, liveEventServe.stderr)
    let liveEventServeResult = try decodeJSON(ScopedParityCommandResult.self, from: liveEventServe.stdout)
    XCTAssertEqual(liveEventServeResult.status, "failed")
    XCTAssertTrue(liveEventServeResult.records.contains("status=unavailable"))
    XCTAssertTrue(liveEventServeResult.records.contains("unsupportedLiveSources=telegram-live:telegram-gateway"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: liveEventRoot.appendingPathComponent("serve-record.json").path))

    let dryRunLiveEventServe = await app.run([
      "events", "serve",
      "--event-root", liveEventRoot.path,
      "--dry-run",
      "--output", "json"
    ])
    XCTAssertEqual(dryRunLiveEventServe.exitCode, .success, dryRunLiveEventServe.stderr)
    let dryRunLiveEventServeResult = try decodeJSON(ScopedParityCommandResult.self, from: dryRunLiveEventServe.stdout)
    XCTAssertEqual(dryRunLiveEventServeResult.status, "ok")
    XCTAssertTrue(dryRunLiveEventServeResult.records.contains("status=dry-run"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: liveEventRoot.appendingPathComponent("serve-record.json").path))

    try FileManager.default.createDirectory(at: eventRoot.appendingPathComponent("replies", isDirectory: true), withIntermediateDirectories: true)
    try #"{"idempotencyKey":"reply-1","sourceId":"web-a","status":"queued","workflowExecutionId":"run-1"}"#
      .write(to: eventRoot.appendingPathComponent("replies/reply-1.json"), atomically: true, encoding: .utf8)
    let eventReplies = await app.run([
      "events", "replies", "run-1",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(eventReplies.exitCode, .success, eventReplies.stderr)
    let eventRepliesResult = try decodeJSON(ScopedParityCommandResult.self, from: eventReplies.stdout)
    XCTAssertTrue(eventRepliesResult.records.contains { $0.contains("reply-1") })

    try FileManager.default.createDirectory(at: eventRoot.appendingPathComponent("schedules", isDirectory: true), withIntermediateDirectories: true)
    try #"{"scheduleId":"schedule-1","sourceId":"web-a","status":"active","workflowName":"worker-only-single-step","kind":"cron","timezone":"UTC","nextDueAt":"2026-06-16T00:00:00Z"}"#
      .write(to: eventRoot.appendingPathComponent("schedules/schedule-1.json"), atomically: true, encoding: .utf8)
    for command in [
      ["events", "schedules", "list"],
      ["events", "schedules", "inspect", "schedule-1"],
      ["events", "schedules", "cancel", "schedule-1", "--reason", "test"]
    ] {
      let result = await app.run(command + [
        "--event-root", eventRoot.path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, command.joined(separator: " "))
      let scoped = try decodeJSON(ScopedParityCommandResult.self, from: result.stdout)
      XCTAssertEqual(scoped.status, "ok")
      XCTAssertTrue(scoped.records.contains { $0.contains("schedule-1") })
    }

    let managerSession = await app.run([
      "graphql", "manager-session", runResult.session.sessionId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(managerSession.exitCode, .success, managerSession.stderr)
    let managerSessionResult = try decodeJSON(ScopedParityCommandResult.self, from: managerSession.stdout)
    XCTAssertEqual(managerSessionResult.status, "ok")
    XCTAssertTrue(managerSessionResult.records.first?.contains(runResult.session.sessionId) == true)

    let missingManagerMessage = await app.run([
      "graphql", "send-manager-message", runResult.session.sessionId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertNotEqual(missingManagerMessage.exitCode, .success)
    XCTAssertTrue(missingManagerMessage.stdout.contains("requires --message-json or --message-file"))

    let managerMessage = await app.run([
      "graphql", "send-manager-message", runResult.session.sessionId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--message-json", #"{"kind":"retry","target":"main-worker","reason":"test-manager-control"}"#,
      "--output", "json"
    ])
    XCTAssertEqual(managerMessage.exitCode, .success, managerMessage.stderr)
    let managerMessageResult = try decodeJSON(ScopedParityCommandResult.self, from: managerMessage.stdout)
    XCTAssertEqual(managerMessageResult.status, "ok")
    let managerSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: tempDir.appendingPathComponent("sessions", isDirectory: true).path)
    ).load(sessionId: runResult.session.sessionId)
    let managerMessageRecord = try XCTUnwrap(managerSnapshot.workflowMessages.first {
      $0.payload["reason"] == .string("test-manager-control")
    })
    let managerCommunicationId = managerMessageRecord.communicationId
    XCTAssertTrue(managerMessageResult.records.first?.contains(managerCommunicationId) == true)
    XCTAssertEqual(managerMessageRecord.payload["kind"], .string("retry"))
    XCTAssertEqual(managerMessageRecord.payload["target"], .string("main-worker"))
    XCTAssertEqual(managerMessageRecord.payload["reason"], .string("test-manager-control"))
    XCTAssertNil(managerMessageRecord.payload["managerMessage"])

    var secondSession = runResult.session
    secondSession.sessionId = "worker-only-single-step-session-200"
    try CLIWorkflowSessionStore(rootDirectory: tempDir.appendingPathComponent("sessions", isDirectory: true).path).save(PersistedCLIWorkflowSession(
      workflowName: "worker-only-single-step",
      session: secondSession,
      resolution: WorkflowResolutionOptions(workflowName: "worker-only-single-step", scope: .direct, workflowDefinitionDir: "\(root)/examples", workingDirectory: tempDir.path),
      mockScenarioPath: "\(root)/examples/worker-only-single-step/mock-scenario.json"
    ))
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: tempDir.appendingPathComponent("sessions", isDirectory: true).path)).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: secondSession)
    )
    let secondManagerMessage = await app.run([
      "graphql", "send-manager-message", secondSession.sessionId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--message-json", #"{"kind":"retry","target":"main-worker","reason":"second-manager-control"}"#,
      "--output", "json"
    ])
    XCTAssertEqual(secondManagerMessage.exitCode, .success, secondManagerMessage.stderr)
    let secondManagerMessageResult = try decodeJSON(ScopedParityCommandResult.self, from: secondManagerMessage.stdout)
    let secondManagerCommunicationId = "graphql-manager-\(secondSession.sessionId)-1"
    XCTAssertTrue(secondManagerMessageResult.records.first?.contains(secondManagerCommunicationId) == true)
    XCTAssertNotEqual(managerCommunicationId, secondManagerCommunicationId)

    for command in [
      ["graphql", "replay-communication", managerCommunicationId],
      ["graphql", "retry-communication", managerCommunicationId],
      ["graphql", "retry-communication-delivery", managerCommunicationId]
    ] {
      let result = await app.run(command + [
        "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, command.joined(separator: " "))
      let scoped = try decodeJSON(ScopedParityCommandResult.self, from: result.stdout)
      XCTAssertEqual(scoped.status, "ok")
      XCTAssertTrue(scoped.records.first?.contains(managerCommunicationId) == true)
    }
    let secondRetry = await app.run([
      "graphql", "retry-communication", secondManagerCommunicationId,
      "--session-store", tempDir.appendingPathComponent("sessions", isDirectory: true).path,
      "--output", "json"
    ])
    XCTAssertEqual(secondRetry.exitCode, .success, secondRetry.stderr)
    let secondRetryResult = try decodeJSON(ScopedParityCommandResult.self, from: secondRetry.stdout)
    XCTAssertTrue(secondRetryResult.records.first?.contains(secondManagerCommunicationId) == true)

    let callRoot = tempDir.appendingPathComponent("call-step-root", isDirectory: true)
    let callWorkflow = callRoot.appendingPathComponent("call-flow", isDirectory: true)
    try FileManager.default.createDirectory(at: callWorkflow.appendingPathComponent("nodes", isDirectory: true), withIntermediateDirectories: true)
    try """
    {
      "workflowId": "call-flow",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "step-a",
      "nodes": [
        { "id": "node-a", "nodeFile": "nodes/node-a.json" },
        { "id": "node-b", "nodeFile": "nodes/node-b.json" }
      ],
      "steps": [
        { "id": "step-a", "nodeId": "node-a", "role": "worker", "transitions": [{ "toStepId": "step-b" }] },
        { "id": "step-b", "nodeId": "node-b", "role": "worker" }
      ]
    }
    """.write(to: callWorkflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"node-a","executionBackend":"codex-agent","model":"gpt-5.5","variables":{}}"#
      .write(to: callWorkflow.appendingPathComponent("nodes/node-a.json"), atomically: true, encoding: .utf8)
    try #"{"id":"node-b","executionBackend":"codex-agent","model":"gpt-5.5","variables":{},"promptVariants":{"direct":{"promptTemplate":"direct variant"}}}"#
      .write(to: callWorkflow.appendingPathComponent("nodes/node-b.json"), atomically: true, encoding: .utf8)
    let callScenario = tempDir.appendingPathComponent("call-step-scenario.json")
    try #"{"step-b":{"provider":"scenario-mock","model":"gpt-5.5","payload":{"status":"called-step-b"}}}"#
      .write(to: callScenario, atomically: true, encoding: .utf8)
    let callSessionStore = tempDir.appendingPathComponent("call-step-sessions", isDirectory: true)
    let callSession = WorkflowSession(
      workflowId: "call-flow",
      sessionId: "call-flow-run-1",
      status: .running,
      entryStepId: "step-a",
      currentStepId: "step-b",
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    try CLIWorkflowSessionStore(rootDirectory: callSessionStore.path).save(PersistedCLIWorkflowSession(
      workflowName: "call-flow",
      session: callSession,
      resolution: WorkflowResolutionOptions(workflowName: "call-flow", scope: .direct, workflowDefinitionDir: callRoot.path, workingDirectory: tempDir.path),
      mockScenarioPath: callScenario.path
    ))
    let preexistingCallMessage = WorkflowMessageRecord(
      communicationId: "comm-000001",
      workflowExecutionId: callSession.sessionId,
      fromStepId: nil,
      toStepId: "step-b",
      routingScope: .workflow,
      deliveryKind: .direct,
      sourceStepExecutionId: "preexisting-call-exec",
      payload: ["mode": .string("preexisting-call-message")],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: Date(timeIntervalSince1970: 0)
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: callSessionStore.path)).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: callSession, workflowMessages: [preexistingCallMessage])
    )
    let called = await app.run([
      "call-step", "call-flow", "call-flow-run-1", "step-b",
      "--workflow-definition-dir", callRoot.path,
      "--session-store", callSessionStore.path,
      "--message-json", #"{"mode":"direct"}"#,
      "--prompt-variant", "direct",
      "--resume-step-exec", "previous-exec-1",
      "--output", "json"
    ])
    XCTAssertEqual(called.exitCode, .success, called.stderr)
    let calledResult = try decodeJSON(WorkflowRunResult.self, from: called.stdout)
    XCTAssertEqual(calledResult.session.sessionId, "call-flow-run-1")
    XCTAssertEqual(calledResult.session.executions.map(\.stepId), ["step-b"])
    XCTAssertEqual(calledResult.rootOutput?["resumedFromNodeExecId"], .string("previous-exec-1"))
    XCTAssertEqual(calledResult.rootOutput?["promptText"], .string("direct variant"))
    let calledSnapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: callSessionStore.path))
      .load(sessionId: calledResult.session.sessionId)
    let directCallMessage = try XCTUnwrap(calledSnapshot.workflowMessages.first { $0.payload["directCallPromptVariant"] == .string("direct") })
    XCTAssertEqual(directCallMessage.payload["directCallPromptVariant"], .string("direct"))
    XCTAssertEqual(calledSnapshot.rootOutput?["resumedFromNodeExecId"], .string("previous-exec-1"))
    let calledCommunicationIds = calledSnapshot.workflowMessages.map(\.communicationId)
    XCTAssertEqual(Set(calledCommunicationIds).count, calledCommunicationIds.count)
    XCTAssertTrue(calledCommunicationIds.contains("comm-000001"))
    XCTAssertTrue(calledCommunicationIds.contains("comm-000002"))

    let workflowCallSessionStore = tempDir.appendingPathComponent("workflow-call-sessions", isDirectory: true)
    let workflowCallSession = WorkflowSession(
      workflowId: "call-flow",
      sessionId: "call-flow-run-2",
      status: .running,
      entryStepId: "step-a",
      currentStepId: "step-b",
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    try CLIWorkflowSessionStore(rootDirectory: workflowCallSessionStore.path).save(PersistedCLIWorkflowSession(
      workflowName: "call-flow",
      session: workflowCallSession,
      resolution: WorkflowResolutionOptions(workflowName: "call-flow", scope: .direct, workflowDefinitionDir: callRoot.path, workingDirectory: tempDir.path),
      mockScenarioPath: callScenario.path
    ))
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: workflowCallSessionStore.path)).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: workflowCallSession)
    )
    let workflowCalled = await app.run([
      "workflow-call", "call-flow", "call-flow-run-2", "step-b",
      "--workflow-definition-dir", callRoot.path,
      "--mock-scenario", callScenario.path,
      "--session-store", workflowCallSessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(workflowCalled.exitCode, .success, workflowCalled.stderr)
    let workflowCalledResult = try decodeJSON(WorkflowRunResult.self, from: workflowCalled.stdout)
    XCTAssertEqual(workflowCalledResult.session.sessionId, "call-flow-run-2")
    XCTAssertEqual(workflowCalledResult.session.executions.map(\.stepId), ["step-b"])
    XCTAssertEqual(
      try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: workflowCallSessionStore.path))
        .load(sessionId: workflowCalledResult.session.sessionId)
        .session
        .sessionId,
      workflowCalledResult.session.sessionId
    )
  }

  func testScopedPackageIdsInstallListRunPublishUpdateAndRemove() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-scoped-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )
    try """
    {
      "name": "@scope/scoped-flow",
      "version": "1.0.0",
      "description": "Scoped package",
      "tags": ["scoped"],
      "registry": "local",
      "checksum": "cccccccccccccccccccccccccccccccc",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "@scope/scoped-flow",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedDirectory = tempDir.appendingPathComponent(".riela/packages/@scope/scoped-flow", isDirectory: true)
    XCTAssertEqual(installed.destinationDirectory, installedDirectory.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedDirectory.appendingPathComponent("riela-package.json").path))

    let list = await app.run([
      "package", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    let listed = try decodeJSON(WorkflowPackageCommandResult.self, from: list.stdout)
    XCTAssertEqual(listed.packages.map(\.name), ["@scope/scoped-flow"])
    XCTAssertEqual(listed.packages.first?.valid, true)

    for command in ["run", "temp-run"] {
      let result = await app.run([
        "package", command, "@scope/scoped-flow",
        "--working-dir", tempDir.path,
        "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, "\(command): \(result.stderr) \(result.stdout)")
      let run = try decodeJSON(WorkflowPackageCommandResult.self, from: result.stdout)
      XCTAssertEqual(run.target, "@scope/scoped-flow")
      XCTAssertNotNil(run.runSessionId)
    }

    let update = await app.run([
      "package", "update", "@scope/scoped-flow",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(update.exitCode, .success, update.stderr)
    let updated = try decodeJSON(WorkflowPackageCommandResult.self, from: update.stdout)
    XCTAssertEqual(updated.packages.map(\.name), ["@scope/scoped-flow"])

    let publish = await app.run([
      "package", "publish", packageSource.path,
      "--package-name", "@scope/scoped-flow",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(publish.exitCode, .success, publish.stderr)
    let published = try decodeJSON(WorkflowPackageCommandResult.self, from: publish.stdout)
    XCTAssertEqual(published.packages.first?.name, "@scope/scoped-flow")
    let encodedKey = "%40scope%2Fscoped-flow"
    XCTAssertEqual(published.destinationDirectory, tempDir.appendingPathComponent(".riela/package-registry/\(encodedKey).json").path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-cache/\(encodedKey).json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-locks/\(encodedKey).json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-native-addons/\(encodedKey).json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/skills/\(encodedKey)/SKILL.md").path))

    let remove = await app.run([
      "package", "remove", "@scope/scoped-flow",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(remove.exitCode, .success, remove.stderr)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installedDirectory.path))
  }

  func testPackageRemoveAndEventRecordCommandsRejectTraversalIdentifiers() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-traversal-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let app = RielaCLIApplication()
    let escapedPackageTarget = tempDir.appendingPathComponent(".riela/some-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: escapedPackageTarget, withIntermediateDirectories: true)
    let packageRemove = await app.run([
      "package", "remove", "../some-directory",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(packageRemove.exitCode, .failure)
    XCTAssertTrue(packageRemove.stdout.contains("invalid package name"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: escapedPackageTarget.path))

    let escapedPackage = tempDir.appendingPathComponent(".riela/escape", isDirectory: true)
    try FileManager.default.createDirectory(at: escapedPackage, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: escapedPackage.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: escapedPackage.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: escapedPackage.appendingPathComponent("prompts")
    )
    try """
    {
      "name": "escape",
      "version": "1.0.0",
      "description": "Escaped package",
      "tags": ["test"],
      "registry": "local",
      "checksum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: escapedPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let packageTempRun = await app.run([
      "package", "temp-run", "../escape",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(packageTempRun.exitCode, .failure)
    XCTAssertTrue(packageTempRun.stdout.contains("invalid package name"))

    let packagePublish = await app.run([
      "package", "publish", escapedPackage.path,
      "--package-name", "../escape",
      "--working-dir", tempDir.path,
      "--yes",
      "--output", "json"
    ])
    XCTAssertEqual(packagePublish.exitCode, .failure)
    XCTAssertTrue(packagePublish.stdout.contains("invalid package name"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".riela/package-registry/escape.json").path))

    let eventRoot = tempDir.appendingPathComponent("event-root", isDirectory: true)
    try FileManager.default.createDirectory(at: eventRoot.appendingPathComponent("receipts", isDirectory: true), withIntermediateDirectories: true)
    let replayTraversal = await app.run([
      "events", "replay", "../outside",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(replayTraversal.exitCode, .failure)
    XCTAssertTrue(replayTraversal.stdout.contains("invalid event receipt id"))

    try FileManager.default.createDirectory(at: eventRoot.appendingPathComponent("schedules", isDirectory: true), withIntermediateDirectories: true)
    try """
    {
      "scheduleId": "../escape",
      "sourceId": "web-a",
      "status": "active",
      "workflowName": "worker-only-single-step",
      "kind": "cron",
      "timezone": "UTC",
      "nextDueAt": "2026-06-16T00:00:00Z"
    }
    """.write(to: eventRoot.appendingPathComponent("schedules/schedule-1.json"), atomically: true, encoding: .utf8)
    let scheduleTraversal = await app.run([
      "events", "schedules", "inspect", "../escape",
      "--event-root", eventRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(scheduleTraversal.exitCode, .failure)
    XCTAssertTrue(scheduleTraversal.stdout.contains("invalid event schedule id"))

    let scheduleCancel = await app.run([
      "events", "schedules", "cancel", "schedule-1",
      "--event-root", eventRoot.path,
      "--reason", "test",
      "--output", "json"
    ])
    XCTAssertEqual(scheduleCancel.exitCode, .failure)
    XCTAssertTrue(scheduleCancel.stdout.contains("invalid event schedule id"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: eventRoot.appendingPathComponent("escape.json").path))
  }

  func testInspectJSONFailureReturnsParseableEnvelopeForMissingWorkflow() async throws {
    let result = await RielaCLIApplication().run([
      "workflow", "inspect", "definitely-missing-workflow",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowInspectionFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.workflowId, "definitely-missing-workflow")
    XCTAssertEqual(failure.exitCode, CLIExitCode.failure.rawValue)
    XCTAssertTrue(failure.error.contains("notFound"))
  }

  func testInspectJSONFailureReturnsDiagnosticsForInvalidWorkflow() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-invalid-inspect-\(UUID().uuidString)", isDirectory: true)
    let workflowDir = tempDir.appendingPathComponent("broken", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try """
    {
      "workflowId": "broken",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "missing-entry",
      "nodes": [{ "id": "node", "nodeFile": "nodes/node.json" }],
      "steps": [{ "id": "step", "nodeId": "node", "role": "worker" }]
    }
    """.write(to: workflowDir.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let result = await RielaCLIApplication().run([
      "workflow", "inspect", "broken",
      "--workflow-definition-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowInspectionFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.workflowId, "broken")
    XCTAssertTrue(failure.error.contains("invalidWorkflow"))
    XCTAssertTrue(failure.diagnostics.contains {
      $0.path == "workflow.entryStepId" && $0.message.contains("missing-entry")
    })
  }

  func testScenarioSequenceRetriesInvalidOutputContractBeforePublishingTransition() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let scenario = WorkflowMockScenario(responses: [
      "step": [
        MockNodeResponse(payload: ["other": .string("invalid")]),
        MockNodeResponse(payload: ["status": .string("valid")])
      ]
    ])
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: ScenarioNodeAdapter(scenario: scenario)
    )
    let workflow = WorkflowDefinition(
      workflowId: "retry-scenario",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "next-node", nodeFile: "nodes/next-node.json")
      ],
      steps: [
        WorkflowStepRef(id: "step", nodeId: "node", transitions: [WorkflowStepTransition(toStepId: "next")]),
        WorkflowStepRef(id: "next", nodeId: "next-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "next", nodeFile: "nodes/next-node.json")
      ]
    )
    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": AgentNodePayload(
          id: "node",
          executionBackend: .codexAgent,
          model: "gpt-5.5",
          output: NodeOutputContract(
            jsonSchema: [
              "type": .string("object"),
              "required": .array([.string("status")])
            ],
            maxValidationAttempts: 2
          )
        ),
        "next-node": AgentNodePayload(id: "next-node", executionBackend: .codexAgent, model: "gpt-5.5")
      ]
    ))

    XCTAssertEqual(result.status, .completed)
    let retriedExecutions = result.session.executions.filter { $0.stepId == "step" }
    XCTAssertEqual(retriedExecutions.map(\.attempt), [1, 2])
    XCTAssertEqual(retriedExecutions.map(\.status), [.failed, .completed])
    XCTAssertEqual(retriedExecutions.first?.acceptedOutput, nil)
    XCTAssertEqual(retriedExecutions.last?.acceptedOutput?.payload["status"], .string("valid"))
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.sourceStepExecutionId, retriedExecutions.last?.executionId)
  }

  func testScenarioSequenceSkipsUnusedRetrySlotsForRepeatedStepExecutions() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let scenario = WorkflowMockScenario(responses: [
      "step": [
        MockNodeResponse(when: ["loop": true], payload: ["status": .string("first")]),
        MockNodeResponse(fail: true),
        MockNodeResponse(when: ["loop": false, "done": true], payload: ["status": .string("second")])
      ]
    ])
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: ScenarioNodeAdapter(scenario: scenario)
    )
    let workflow = WorkflowDefinition(
      workflowId: "repeat-scenario",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "final-node", nodeFile: "nodes/final-node.json")
      ],
      steps: [
        WorkflowStepRef(id: "step", nodeId: "node", transitions: [
          WorkflowStepTransition(toStepId: "step", label: "loop"),
          WorkflowStepTransition(toStepId: "final", label: "done")
        ]),
        WorkflowStepRef(id: "final", nodeId: "final-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "final", nodeFile: "nodes/final-node.json")
      ]
    )
    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": AgentNodePayload(
          id: "node",
          executionBackend: .codexAgent,
          model: "gpt-5.5",
          output: NodeOutputContract(
            jsonSchema: [
              "type": .string("object"),
              "required": .array([.string("status")])
            ],
            maxValidationAttempts: 2
          )
        ),
        "final-node": AgentNodePayload(id: "final-node", executionBackend: .codexAgent, model: "gpt-5.5")
      ],
      maxSteps: 3
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.nodeExecutions, 3)
    XCTAssertEqual(result.transitions, 2)
    let executions = result.session.executions.filter { $0.stepId == "step" }
    XCTAssertEqual(executions.map(\.attempt), [1, 1])
    XCTAssertEqual(executions.map(\.acceptedOutput?.payload["status"]), [.string("first"), .string("second")])
    let messages = try await store.listMessages(for: result.session.sessionId, toStepId: nil)
    XCTAssertEqual(messages.map(\.toStepId), ["step", "final"])
  }

  func testScenarioLookupUsesExecutingStepIdWhenNodeIsReusable() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let scenarioURL = tempDir.appendingPathComponent("scenario.json")
    try """
    {
      "step-a": {
        "provider": "scenario-mock",
        "model": "gpt-5.5",
        "payload": {
          "status": "step-key-used"
        }
      }
    }
    """.write(to: scenarioURL, atomically: true, encoding: .utf8)
    let workflowJSON = """
    {
      "workflow": {
        "workflowId": "reusable-node-scenario",
        "defaults": {
          "maxLoopIterations": 3,
          "nodeTimeoutMs": 120000
        },
        "entryStepId": "step-a",
        "nodes": [
          {
            "id": "shared-worker",
            "nodeFile": "nodes/shared-worker.json"
          }
        ],
        "steps": [
          {
            "id": "step-a",
            "nodeId": "shared-worker",
            "role": "worker"
          }
        ]
      },
      "nodePayloads": {
        "nodes/shared-worker.json": {
          "id": "shared-worker",
          "executionBackend": "codex-agent",
          "model": "gpt-5.5",
          "variables": {}
        }
      }
    }
    """

    let result = await RielaCLIApplication().run([
      "workflow", "run", workflowJSON,
      "--mock-scenario", scenarioURL.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success)
    let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(run.rootOutput?["status"], .string("step-key-used"))
    XCTAssertEqual(run.session.executions.first?.stepId, "step-a")
    XCTAssertEqual(run.session.executions.first?.nodeId, "shared-worker")
  }

  private func assertScopedProjectWorkflowEscapeRejected(workingDirectory: URL, workflowName: String = "escape") async throws {
    let validate = await RielaCLIApplication().run([
      "workflow", "validate", workflowName,
      "--scope", "project",
      "--working-dir", workingDirectory.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .failure)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validateFailure = try decodeJSON(WorkflowValidationFailureResult.self, from: validate.stdout)
    XCTAssertFalse(validateFailure.valid)
    XCTAssertEqual(validateFailure.workflowId, workflowName)
    XCTAssertTrue(validateFailure.error.contains("escapes"))

    let inspect = await RielaCLIApplication().run([
      "workflow", "inspect", workflowName,
      "--scope", "project",
      "--working-dir", workingDirectory.path,
      "--output", "json"
    ])
    XCTAssertEqual(inspect.exitCode, .failure)
    XCTAssertTrue(inspect.stderr.isEmpty)
    let inspectFailure = try decodeJSON(WorkflowInspectionFailureResult.self, from: inspect.stdout)
    XCTAssertEqual(inspectFailure.workflowId, workflowName)
    XCTAssertTrue(inspectFailure.error.contains("escapes"))

    let run = await RielaCLIApplication().run([
      "workflow", "run", workflowName,
      "--scope", "project",
      "--working-dir", workingDirectory.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stderr.isEmpty)
    let runFailure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(runFailure.target, workflowName)
    XCTAssertTrue(runFailure.error.contains("escapes"))
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(stdout.utf8))
  }

  private func rawDailySummaryVariables(
    provider: String = "telegram",
    text: String,
    eventId: String,
    receivedAt: String,
    attachments: [JSONValue] = []
  ) -> JSONObject {
    [
      "workflowInput": .object([
        "provider": .string(provider),
        "text": .string(text),
        "eventId": .string(eventId),
        "conversationId": .string("chat-1"),
        "receivedAt": .string(receivedAt)
      ]),
      "event": .object([
        "provider": .string(provider),
        "eventId": .string(eventId),
        "receivedAt": .string(receivedAt),
        "input": .object([
          "provider": .string(provider),
          "text": .string(text),
          "attachments": .array(attachments)
        ]),
        "conversation": .object([
          "id": .string("chat-1"),
          "threadId": .string("topic-a")
        ]),
        "actor": .object([
          "id": .string("user-1"),
          "displayName": .string("Memory User")
        ])
      ])
    ]
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

  private func memoryInt64Array(_ value: MemoryJSONValue?) -> [Int64] {
    guard case let .array(values)? = value else {
      return []
    }
    return values.compactMap { value in
      guard case let .number(number) = value else {
        return nil
      }
      return Int64(exactly: number)
    }
  }

  private func repositoryRoot() -> String {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url.path
      }
      url.deleteLastPathComponent()
    }
    return FileManager.default.currentDirectoryPath
  }

  private func writeTwoStepWorkflow(at root: URL, workflowName: String) throws -> (workflowDirectory: URL, scenarioPath: String) {
    let workflowDirectory = root.appendingPathComponent(workflowName, isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory.appendingPathComponent("nodes", isDirectory: true), withIntermediateDirectories: true)
    try """
    {
      "workflowId": "\(workflowName)",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "step-a",
      "nodes": [
        { "id": "node-a", "nodeFile": "nodes/node-a.json" },
        { "id": "node-b", "nodeFile": "nodes/node-b.json" }
      ],
      "steps": [
        { "id": "step-a", "nodeId": "node-a", "role": "worker", "transitions": [{ "toStepId": "step-b" }] },
        { "id": "step-b", "nodeId": "node-b", "role": "worker" }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"node-a","executionBackend":"codex-agent","model":"gpt-5.5","variables":{}}"#
      .write(to: workflowDirectory.appendingPathComponent("nodes/node-a.json"), atomically: true, encoding: .utf8)
    try #"{"id":"node-b","executionBackend":"codex-agent","model":"gpt-5.5","variables":{}}"#
      .write(to: workflowDirectory.appendingPathComponent("nodes/node-b.json"), atomically: true, encoding: .utf8)
    let scenarioURL = root.appendingPathComponent("\(workflowName)-scenario.json")
    try """
    {
      "step-a": {"provider":"scenario-mock","model":"gpt-5.5","when":{"always":true},"payload":{"status":"first"}},
      "step-b": {"provider":"scenario-mock","model":"gpt-5.5","when":{"always":true},"payload":{"status":"second"}}
    }
    """.write(to: scenarioURL, atomically: true, encoding: .utf8)
    return (workflowDirectory, scenarioURL.path)
  }

  private struct IsolatedUserScopeWorkflowLayout {
    let base: URL
    let homeRoot: URL
    let projectRoot: URL
  }

  private func makeIsolatedUserScopeWorkflowLayout(
    repositoryRoot: String,
    workflowName: String
  ) throws -> IsolatedUserScopeWorkflowLayout {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-user-scope-\(UUID().uuidString)", isDirectory: true)
    let homeRoot = base.appendingPathComponent("home", isDirectory: true)
    let projectRoot = base.appendingPathComponent("project", isDirectory: true)
    let userWorkflows = homeRoot
      .appendingPathComponent(".riela/workflows", isDirectory: true)
      .appendingPathComponent(workflowName, isDirectory: true)
    try FileManager.default.createDirectory(at: userWorkflows.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

    let sourceWorkflow = URL(fileURLWithPath: repositoryRoot)
      .appendingPathComponent("examples/\(workflowName)", isDirectory: true)
    if FileManager.default.fileExists(atPath: userWorkflows.path) {
      try FileManager.default.removeItem(at: userWorkflows)
    }
    try FileManager.default.copyItem(at: sourceWorkflow, to: userWorkflows)
    return IsolatedUserScopeWorkflowLayout(base: base, homeRoot: homeRoot, projectRoot: projectRoot)
  }

  private func createExecutable(directory: URL, name: String, body: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try """
    #!/bin/sh
    \(body)
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }
}
