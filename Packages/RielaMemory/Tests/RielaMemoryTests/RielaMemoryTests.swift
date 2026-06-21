import XCTest
@testable import RielaMemory

final class RielaMemoryTests: XCTestCase {
  func testSaveLoadAndSearchUseOneSQLiteFilePerMemoryId() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    try store.save(
      memoryId: "chat-memory",
      workflowId: "telegram-sdk-trio-chat",
      nodeId: "save-chat-event",
      registeredAt: "2026-06-20T10:00:00Z",
      payload: .object(["text": .string("hello yui"), "kind": .string("chat")])
    )
    try store.save(
      memoryId: "chat-memory",
      workflowId: "telegram-sdk-trio-chat",
      nodeId: "save-chat-event",
      registeredAt: "2026-06-20T10:01:00Z",
      payload: .object(["text": .string("hello rina"), "kind": .string("chat")])
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: try store.databasePath(memoryId: "chat-memory")))
    XCTAssertEqual(try store.load(memoryId: "chat-memory", workflowId: "telegram-sdk-trio-chat").map(\.registeredAt), [
      "2026-06-20T10:01:00Z",
      "2026-06-20T10:00:00Z"
    ])
    XCTAssertEqual(
      try store.search(
        memoryId: "chat-memory",
        options: MemorySearchOptions(workflowId: "telegram-sdk-trio-chat", matchPatterns: ["rina"])
      ).map(\.payload),
      [.object(["kind": .string("chat"), "text": .string("hello rina")])]
    )
  }

  func testMultipleMatchPatternsMatchAnyPattern() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    try store.save(
      memoryId: "persona-1",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:00:00Z",
      payload: .object(["text": .string("memory about yui and mika")])
    )
    try store.save(
      memoryId: "persona-1",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:01:00Z",
      payload: .object(["text": .string("memory about yui only")])
    )
    try store.save(
      memoryId: "persona-1",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:02:00Z",
      payload: .object(["text": .string("memory about rina only")])
    )

    let records = try store.search(
      memoryId: "persona-1",
      options: MemorySearchOptions(workflowId: "wf", matchPatterns: ["mika", "rina"])
    )

    XCTAssertEqual(records.map(\.registeredAt), [
      "2026-06-20T10:02:00Z",
      "2026-06-20T10:00:00Z"
    ])
  }

  func testLoadAndSearchMissingMemoryReturnEmptyResults() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    XCTAssertEqual(try store.load(memoryId: "new-memory", workflowId: "wf"), [])
    XCTAssertEqual(
      try store.search(
        memoryId: "new-memory",
        options: MemorySearchOptions(workflowId: "wf", matchPatterns: ["anything"])
      ),
      []
    )
  }

  func testSearchCanIncludeAllWorkflowsForSharedPersonaMemory() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    try store.save(
      memoryId: "rina-shared",
      workflowId: "discord-rina",
      nodeId: "rina",
      payload: .object(["text": .string("discord memory")])
    )
    try store.save(
      memoryId: "rina-shared",
      workflowId: "telegram-rina",
      nodeId: "rina",
      payload: .object(["text": .string("telegram memory")])
    )

    let scoped = try store.search(
      memoryId: "rina-shared",
      options: MemorySearchOptions(workflowId: "telegram-rina")
    )
    let shared = try store.search(
      memoryId: "rina-shared",
      options: MemorySearchOptions(workflowId: "telegram-rina", includeAllWorkflows: true)
    )

    XCTAssertEqual(scoped.map(\.workflowId), ["telegram-rina"])
    XCTAssertEqual(Set(shared.map(\.workflowId)), ["discord-rina", "telegram-rina"])
  }

  func testConcurrentSavesWaitForSharedMemoryDatabaseLock() async throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          try store.save(
            memoryId: "rina-shared",
            workflowId: "workflow-\(index)",
            nodeId: "rina",
            payload: .object(["index": .number(Double(index))])
          )
        }
      }
      try await group.waitForAll()
    }

    let records = try store.search(
      memoryId: "rina-shared",
      options: MemorySearchOptions(workflowId: "workflow-0", includeAllWorkflows: true, limit: 20)
    )
    XCTAssertEqual(records.count, 8)
  }

  func testLoadAndSearchRecordReturnedMemoryReferences() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    let saved = try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:00:00Z",
      payload: .object(["text": .string("remember this")])
    )

    XCTAssertEqual(try store.referenceHistory(memoryId: "chat-memory"), [])

    _ = try store.load(memoryId: "chat-memory", workflowId: "wf")
    _ = try store.search(
      memoryId: "chat-memory",
      options: MemorySearchOptions(workflowId: "wf", matchPatterns: ["remember"])
    )

    let references = try store.referenceHistory(memoryId: "chat-memory", recordId: saved.recordId)
    XCTAssertEqual(references.map(\.recordId), [saved.recordId, saved.recordId])
    XCTAssertTrue(references.allSatisfy { !$0.referencedAt.isEmpty })
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-memory-tests-\(UUID().uuidString)", isDirectory: true)
  }
}
