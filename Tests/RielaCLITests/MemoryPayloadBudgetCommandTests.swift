import Foundation
import RielaMemory
import XCTest
@testable import RielaCLI

final class MemoryPayloadBudgetCommandTests: XCTestCase {
  func testExplicitBudgetLoadsAndSearchesLargeSavedPayloadWithStrictLoadDefault() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/memory-payload-budget/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let payload = MemoryJSONValue.string(String(repeating: "x", count: 1_300_000))
    let saved = try store.save(memoryId: "cache", workflowId: "workflow", nodeId: "collect", tags: ["source-cache"], payload: payload)
    func run(_ action: String, extra: [String] = []) throws -> MemorySearchCommandResult {
      let parsed = try RielaArgumentParser().parse(["memory", action, "cache", "--workflow-id", "workflow",
        "--node-id", "collect", "--tag", "source-cache", "--memory-root", root.path, "--output", "json"] + extra)
      guard case let .memory(command) = parsed else { throw CLIUsageError("expected memory command") }
      let result = MemoryCommandRunner().run(command)
      XCTAssertEqual(result.exitCode, .success, result.stderr)
      return try JSONDecoder().decode(MemorySearchCommandResult.self, from: Data(result.stdout.utf8))
    }
    let rejected = MemoryCommandRunner().run(.init(kind: .load, options: .init(
      memoryId: "cache", workflowId: "workflow", databaseRoot: root.path)))
    XCTAssertNotEqual(rejected.exitCode, .success)
    let normal = try run("search")
    XCTAssertEqual(normal.maxPayloadBytes, 1_000_000)
    XCTAssertTrue(normal.records.isEmpty)
    for action in ["load", "search"] {
      let expanded = try run(action, extra: ["--max-payload-bytes", "8388608"])
      XCTAssertEqual(expanded.maxPayloadBytes, 8_388_608)
      XCTAssertEqual(expanded.records, [saved])
    }
  }

  func testPayloadBudgetRejectsInvalidBoundsBeforeStoreAccess() throws {
    for value in ["0", "-1", "67108865", "1.5", "invalid", "999999999999999999999999"] {
      XCTAssertThrowsError(try RielaArgumentParser().parse(["memory", "load", "cache", "--workflow-id", "workflow", "--max-payload-bytes", value]))
    }
    for value in ["1", "67108864"] {
      XCTAssertNoThrow(try RielaArgumentParser().parse(["memory", "search", "cache", "--workflow-id", "workflow", "--max-payload-bytes", value]))
    }
    let invalid = MemoryCommandRunner().run(.init(kind: .load, options: .init(memoryId: "cache", workflowId: "workflow", maxPayloadBytes: 0)))
    XCTAssertNotEqual(invalid.exitCode, .success)
  }
}
