import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class MemoryAddonFileTests: XCTestCase {
  func testPersonaMemoryWriteAndReadPreserveFileReferences() async throws {
    let root = repositoryRoot()
    let memoryRoot = "\(root)/tmp/test-persona-memory-files-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    try FileManager.default.createDirectory(atPath: memoryRoot, withIntermediateDirectories: true)
    let sourceFile = URL(fileURLWithPath: memoryRoot).appendingPathComponent("source-yui.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceFile)
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])

    let write = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "write-mika-memory",
        nodeId: "write-mika-memory",
        addon: WorkflowNodeAddonRef(
          name: "riela/chat-persona-memory-write",
          version: "1",
          config: [
            "personaId": .string("mika"),
            "personaName": .string("Mika Trend"),
            "memoryId": .string("persona-chat-memory"),
            "memoryRoot": .string(memoryRoot)
          ]
        ),
        variables: [
          "workflowInput": .object([
            "imagePaths": .array([.string(sourceFile.path)])
          ])
        ],
        resolvedInputPayload: [
          "replyText": .string("アニメ風の女性の肖像だよ。"),
          "memoryEntries": .array([
            .object([
              "kind": .string("observation"),
              "importance": .string("high"),
              "content": .string("The user showed Mika an anime-style female portrait.")
            ])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(write.payload["replyText"], .string("アニメ風の女性の肖像だよ。"))
    guard case let .object(writeMemory)? = write.payload["memory"] else {
      return XCTFail("persona memory write metadata was not returned")
    }
    XCTAssertEqual(writeMemory["filesWritten"], .number(1))

    let read = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "read-mika-memory",
        nodeId: "read-mika-memory",
        addon: WorkflowNodeAddonRef(
          name: "riela/chat-persona-memory-read",
          version: "1",
          config: [
            "personaId": .string("mika"),
            "personaName": .string("Mika Trend"),
            "memoryId": .string("persona-chat-memory"),
            "memoryRoot": .string(memoryRoot)
          ]
        )
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(read.payload["memoryRecordCount"], .number(1))
    XCTAssertEqual(read.payload["memoryAttachmentCountRead"], .number(1))
    guard case let .array(filePaths)? = read.payload["filePaths"],
      case let .string(storedFilePath)? = filePaths.first else {
      return XCTFail("persona memory read filePaths were not returned")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedFilePath))
    guard case let .array(imagePaths)? = read.payload["imagePaths"],
      case let .string(storedImagePath)? = imagePaths.first else {
      return XCTFail("persona memory read imagePaths were not returned")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedImagePath))
    guard case let .string(markdown)? = read.payload["memoryMarkdown"] else {
      return XCTFail("persona memory markdown was not returned")
    }
    XCTAssertTrue(markdown.contains("image image/png"))
    XCTAssertTrue(markdown.contains("anime-style female portrait"))
  }

  func testBuiltinChatMemoryRawDailySummaryStoresAttachmentFilesOnRawRecords() async throws {
    let root = repositoryRoot()
    let memoryRoot = "\(root)/tmp/test-chat-memory-raw-daily-files-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    try FileManager.default.createDirectory(atPath: memoryRoot, withIntermediateDirectories: true)
    let sourceFile = URL(fileURLWithPath: memoryRoot).appendingPathComponent("source-yui.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceFile)
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

    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "chat-memory-raw-and-daily-summary",
        stepId: "update-chat-memory",
        nodeId: "update-chat-memory",
        addon: addon,
        variables: rawDailySummaryVariables(
          text: "image message",
          eventId: "event-image",
          receivedAt: "2026-06-22T09:00:00Z",
          attachments: [
            .object([
              "path": .string(sourceFile.path),
              "mediaType": .string("image/png"),
              "kind": .string("image"),
              "name": .string("yui.png")
            ])
          ]
        )
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["rawFileCount"], .number(1))
    let store = RielaMemoryStore(rootDirectory: memoryRoot)
    let rawRecords = try store.search(
      memoryId: "raw-chat-log",
      options: MemorySearchOptions(workflowId: "chat-memory-raw-and-daily-summary", tags: ["has-files"], limit: 10)
    )
    XCTAssertEqual(rawRecords.count, 1)
    XCTAssertEqual(rawRecords[0].files.count, 1)
    XCTAssertEqual(rawRecords[0].files[0].kind, "image")
    XCTAssertEqual(rawRecords[0].files[0].mediaType, "image/png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: rawRecords[0].files[0].path))
    let summaryRecords = try store.search(
      memoryId: "daily-chat-summary",
      options: MemorySearchOptions(
        workflowId: "chat-memory-raw-and-daily-summary",
        tags: ["summary:telegram:chat-1:2026-06-22"],
        limit: 10
      )
    )
    XCTAssertEqual(memoryNumber(objectPayload(summaryRecords[0].payload)?["rawFileCount"]), 1)
    XCTAssertTrue(memoryString(objectPayload(summaryRecords[0].payload)?["summary"])?.contains("yui.png") == true)
  }

  func testBuiltinMemoryUpdatePreservesFilesWhenNoFilesAreConfigured() async throws {
    let root = repositoryRoot()
    let memoryRoot = "\(root)/tmp/test-memory-update-preserves-files-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    try FileManager.default.createDirectory(atPath: memoryRoot, withIntermediateDirectories: true)
    let sourceFile = URL(fileURLWithPath: memoryRoot).appendingPathComponent("source-yui.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceFile)
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])

    let save = try await resolver.execute(
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
            "filePaths": .array([.string(sourceFile.path)]),
            "payload": .object(["text": .string("original file memory")])
          ]
        )
      ),
      context: AdapterExecutionContext()
    )
    guard case let .object(savedRecord)? = save.payload["record"],
      case let .number(recordIdNumber)? = savedRecord["recordId"],
      let recordId = Int64(exactly: recordIdNumber) else {
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
            "memoryRoot": .string(memoryRoot),
            "recordId": .number(Double(recordId)),
            "payload": .object(["text": .string("updated file memory")])
          ]
        )
      ),
      context: AdapterExecutionContext()
    )

    guard case let .object(updatedRecord)? = update.payload["record"],
      case let .array(files)? = updatedRecord["files"],
      case let .object(file)? = files.first,
      case let .string(path)? = file["path"] else {
      return XCTFail("memory-update did not preserve file references")
    }
    XCTAssertEqual(files.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
  }

  func testBuiltinChatPersonaRouterPrefersEarliestAliasMention() async throws {
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

    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "discord-trio",
        stepId: "route-message",
        nodeId: "route-message",
        addon: addon,
        variables: ["workflowInput": .object(["request": .string("Rina, what image did I just show Mika?")])]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["target"], .string("rina"))
    XCTAssertEqual(output.when["target_rina"], true)
    XCTAssertEqual(output.when["target_mika"], false)
  }

  func testBuiltinPersonaMemoryWriteBlocksHandoffBackToVisitedPersona() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "rina",
      personaName: "Rina Cursor",
      resolvedInputPayload: [
        "replyText": .string("結論。ここで止める。@Yui はどう見る？"),
        "handoff_yui": .bool(true),
        "latestOutputs": .array([
          .object(["payload": .object(["replyAs": .string("yui"), "replyText": .string("Yui reply")])]),
          .object(["payload": .object(["replyAs": .string("mika"), "replyText": .string("Mika reply")])])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.when["handoff_mika"], false)
    XCTAssertEqual(output.when["handoff_rina"], false)
    XCTAssertEqual(output.payload["handoff_yui"], .bool(false))
    XCTAssertEqual(output.payload["replyText"], .string("結論。ここで止める。"))
    XCTAssertEqual(output.payload["autonomousTurns"], .number(3))
    guard case let .object(guardPayload)? = output.payload["handoffGuard"] else {
      return XCTFail("handoff guard metadata was not returned")
    }
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("target-persona-already-replied"))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("yui"))
  }

  func testBuiltinPersonaMemoryWriteUsesRuntimeReplyStepsForHandoffTrail() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "rina",
      personaName: "Rina Cursor",
      resolvedInputPayload: [
        "replyText": .string("結論。@Yui に戻す必要はない。"),
        "handoff_yui": .bool(true),
        "runtime": .object([
          "executedStepIds": .array([
            .string("route-message"),
            .string("send-yui-reply"),
            .string("send-mika-reply")
          ])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["handoff_yui"], .bool(false))
    XCTAssertEqual(output.payload["replyText"], .string("結論。"))
    XCTAssertEqual(output.payload["handoffTrail"], .array([.string("yui"), .string("mika"), .string("rina")]))
    XCTAssertEqual(output.payload["autonomousTurns"], .number(3))
    guard case let .object(guardPayload)? = output.payload["handoffGuard"] else {
      return XCTFail("handoff guard metadata was not returned")
    }
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("target-persona-already-replied"))
    XCTAssertEqual(guardPayload["visitedPersonas"], .array([.string("yui"), .string("mika")]))
  }

  func testBuiltinPersonaMemoryWriteAllowsNextUnvisitedPersona() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "mika",
      personaName: "Mika Trend",
      resolvedInputPayload: [
        "replyText": .string("いいじゃん。@Rina はどう？"),
        "handoff_rina": .bool(true),
        "latestOutputs": .array([
          .object(["payload": .object(["replyAs": .string("yui"), "replyText": .string("Yui reply")])])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_rina"], true)
    XCTAssertEqual(output.payload["handoff_rina"], .bool(true))
    guard case let .object(guardPayload)? = output.payload["handoffGuard"] else {
      return XCTFail("handoff guard metadata was not returned")
    }
    XCTAssertEqual(guardPayload["blocked"], .bool(false))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("rina"))
  }

  func testBuiltinPersonaMemoryWriteRemovesBlockedJapaneseHandoffSentence() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "rina",
      personaName: "Rina Cursor",
      resolvedInputPayload: [
        "replyText": .string("結論: ループガード retest妥当。ミカ、上記3点について短評をくれ。"),
        "handoff_mika": .bool(true),
        "runtime": .object([
          "executedStepIds": .array([
            .string("send-yui-reply"),
            .string("send-mika-reply")
          ])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_mika"], false)
    XCTAssertEqual(output.payload["replyText"], .string("結論: ループガード retest妥当。"))
    guard case let .object(guardPayload)? = output.payload["handoffGuard"] else {
      return XCTFail("handoff guard metadata was not returned")
    }
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("target-persona-already-replied"))
  }

  func testBuiltinPersonaMemoryWriteRemovesFinalTurnContinuationToVisitedPersona() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "rina",
      personaName: "Rina Cursor",
      resolvedInputPayload: [
        "replyText": .string("結論: 妥当。要点は3点。次はミカの要点を受け取り、私の短評を返す。"),
        "handoff_mika": .bool(false),
        "handoff_yui": .bool(false),
        "runtime": .object([
          "executedStepIds": .array([
            .string("send-yui-reply"),
            .string("send-mika-reply")
          ])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_mika"], false)
    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("結論: 妥当。要点は3点。"))
    guard case let .object(guardPayload)? = output.payload["handoffGuard"] else {
      return XCTFail("handoff guard metadata was not returned")
    }
    XCTAssertEqual(guardPayload["blocked"], .bool(false))
  }

  func testBuiltinPersonaMemoryWriteKeepsBlockedTargetMentionWhenItIsNotAContinuation() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "rina",
      personaName: "Rina Cursor",
      resolvedInputPayload: [
        "replyText": .string("Yuiの前提は正しい。ここで止める。"),
        "handoff_yui": .bool(true),
        "latestOutputs": .array([
          .object(["payload": .object(["replyAs": .string("yui"), "replyText": .string("Yui reply")])])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("Yuiの前提は正しい。ここで止める。"))
    guard case let .object(guardPayload)? = output.payload["handoffGuard"] else {
      return XCTFail("handoff guard metadata was not returned")
    }
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("target-persona-already-replied"))
  }

  func testBuiltinPersonaMemoryWriteBlocksSelfHandoffOnFirstReply() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "yui",
      personaName: "Yui Codex",
      resolvedInputPayload: [
        "replyText": .string("続きは@Yuiが見るね。"),
        "handoff_yui": .bool(true)
      ]
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["handoff_yui"], .bool(false))
    XCTAssertEqual(output.payload["replyText"], .string("では、肩の力を抜いて続けましょう。"))
    guard case let .object(guardPayload)? = output.payload["handoffGuard"] else {
      return XCTFail("handoff guard metadata was not returned")
    }
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("current-persona-already-replied"))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("yui"))
  }

  private func repositoryRoot() -> String {
    FileManager.default.currentDirectoryPath
  }

  private func executePersonaMemoryWrite(
    personaId: String,
    personaName: String,
    resolvedInputPayload: JSONObject,
    config extraConfig: JSONObject = [:]
  ) async throws -> AdapterExecutionOutput {
    let memoryRoot = "\(repositoryRoot())/tmp/test-persona-memory-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(atPath: memoryRoot)
    }
    var config: JSONObject = [
      "personaId": .string(personaId),
      "personaName": .string(personaName),
      "memoryId": .string("persona-chat-memory"),
      "memoryRoot": .string(memoryRoot)
    ]
    for (key, value) in extraConfig {
      config[key] = value
    }
    let stepId = "write-\(personaId)-memory"
    return try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-agent-trio-chat",
        stepId: stepId,
        nodeId: stepId,
        addon: WorkflowNodeAddonRef(
          name: "riela/chat-persona-memory-write",
          version: "1",
          config: config
        ),
        resolvedInputPayload: resolvedInputPayload
      ),
      context: AdapterExecutionContext()
    )
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
}
