import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class MemoryPayloadOverflowTests: XCTestCase {
  private func root() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/memory-overflow/\(UUID().uuidString)")
  }

  func testStrictLoadNeverReturnsOlderRecordWhenNewestExceedsBudget() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RielaMemoryStore(rootDirectory: directory.path)
    let old = try store.save(memoryId: "cache", workflowId: "workflow", nodeId: "collect",
      registeredAt: "2026-10-17T00:00:00Z", payload: .string("old"))
    let latest = try store.save(memoryId: "cache", workflowId: "workflow", nodeId: "collect",
      registeredAt: "2026-10-18T00:00:00Z", payload: .string(String(repeating: "x", count: 1_300_000)))
    XCTAssertThrowsError(try store.load(memoryId: "cache", workflowId: "workflow", limit: 1)) {
      XCTAssertEqual($0 as? RielaMemoryError, .payloadTooLarge(recordId: latest.recordId, limit: 1_000_000))
    }
    XCTAssertEqual(try store.load(memoryId: "cache", workflowId: "workflow", limit: 1,
      maxPayloadBytes: 2_000_000), [latest])
    XCTAssertEqual(try store.search(memoryId: "cache", options: .init(workflowId: "workflow", limit: 1)), [old])
    XCTAssertTrue(try store.load(memoryId: "cache", workflowId: "other").isEmpty)
    XCTAssertThrowsError(try store.search(memoryId: "cache", options: .init(workflowId: "workflow",
      matchPatterns: ["old"], payloadOverflowPolicy: .fail)))
    XCTAssertThrowsError(try store.loadAllWorkflows(memoryId: "cache", workflowId: "other", limit: 1))
  }

  func testBuiltinLoadAndSearchAcceptExplicitBudgetAndRejectInvalidValues() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RielaMemoryStore(rootDirectory: directory.path)
    let saved = try store.save(memoryId: "cache", workflowId: "workflow", payload: .string(String(repeating: "x", count: 1_300_000)))
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    func input(_ name: String, budget: JSONValue? = nil) -> WorkflowAddonExecutionInput {
      var config: JSONObject = ["memoryId": .string("cache"), "memoryRoot": .string(directory.path)]
      config["maxPayloadBytes"] = budget
      return .init(workflowId: "workflow", stepId: "read", nodeId: "read",
        addon: .init(name: name, config: config), resolvedInputPayload: [:])
    }
    XCTAssertThrowsError(try resolver.executeMemoryAddon(input("riela/memory-load"), operation: .load))
    for operation in [BuiltinMemoryAddon.load, .search] {
      let output = try resolver.executeMemoryAddon(input(operation.rawValue, budget: .integer(2_000_000)), operation: operation)
      XCTAssertEqual(output.payload["maxPayloadBytes"], .number(2_000_000))
      guard case let .array(records)? = output.payload["records"] else { return XCTFail("missing records") }
      XCTAssertEqual(records.count, 1)
      XCTAssertEqual(saved.workflowId, "workflow")
      for invalid in [JSONValue.integer(0), .integer(67_108_865), .number(1.5), .bool(true), .string("2000000")] {
        XCTAssertThrowsError(try resolver.executeMemoryAddon(input(operation.rawValue, budget: invalid), operation: operation))
      }
    }
  }

  func testPersonaReplayFailsClosedInsteadOfDuplicatingOversizedEntry() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    func input(budget: JSONValue? = nil) -> WorkflowAddonExecutionInput {
      var config: JSONObject = ["personaId": .string("yui"), "memoryRoot": .string(directory.path)]
      config["maxPayloadBytes"] = budget
      return .init(workflowId: "workflow", stepId: "write", nodeId: "write",
        addon: .init(name: "riela/chat-persona-memory-write", config: config), resolvedInputPayload: [
          "_rielaInput": .object(["workflowExecutionId": .string("session"), "sourceStepExecutionId": .string("execution")]),
          "replyText": .string("saved"),
          "memoryEntries": .array([.object(["content": .string(String(repeating: "x", count: 1_300_000))])])
        ])
    }
    let first = try resolver.executeChatPersonaMemoryWrite(input())
    XCTAssertThrowsError(try resolver.executeChatPersonaMemoryWrite(input()))
    let replay = try resolver.executeChatPersonaMemoryWrite(input(budget: .integer(2_000_000)))
    guard case let .object(firstMemory)? = first.payload["memory"],
          case let .object(replayMemory)? = replay.payload["memory"] else { return XCTFail("missing memory") }
    XCTAssertEqual(replayMemory["idempotentReplay"], .bool(true))
    XCTAssertEqual(firstMemory["recordIds"], replayMemory["recordIds"])
    let store = RielaMemoryStore(rootDirectory: directory.path)
    XCTAssertEqual(try store.load(memoryId: "persona-chat-memory", workflowId: "workflow", maxPayloadBytes: 2_000_000).count, 1)
  }
}
