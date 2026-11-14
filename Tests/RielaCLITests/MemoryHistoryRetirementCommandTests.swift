import Foundation
import RielaMemory
import XCTest
@testable import RielaCLI

final class MemoryHistoryRetirementCommandTests: XCTestCase {
  func testParsedExactScopeDryRunApplyAndRetiredVersionFailure() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/history-retirement/cli-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.save(memoryId: "m", workflowId: "w", nodeId: "collect", tags: ["checkpoint"], payload: .string("old body"))
    let head = try store.update(memoryId: "m", recordId: first.recordId, workflowId: "w", nodeId: "collect",
      tags: ["checkpoint"], payload: .string("checkpoint only"))
    let args = ["memory", "retire-history", "m", "--record-id", "\(head.recordId)", "--memory-root", root.path,
      "--workflow-id", "w", "--node-id", "collect", "--tag", "checkpoint", "--expected-head-version", "2",
      "--through-version", "1", "--output", "json"]
    func run(_ tokens: [String]) throws -> CLICommandResult {
      guard case let .memory(command) = try RielaArgumentParser().parse(tokens) else {
        throw CLIUsageError("expected memory command")
      }
      return MemoryCommandRunner().run(command)
    }
    let dry = try run(args + ["--dry-run"])
    XCTAssertEqual(dry.exitCode, .success)
    XCTAssertEqual(try JSONDecoder().decode(MemoryHistoryRetirementReport.self, from: Data(dry.stdout.utf8)).status, "planned")
    XCTAssertNoThrow(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 1))
    let apply = try run(args)
    XCTAssertEqual(apply.exitCode, .success)
    XCTAssertEqual(try JSONDecoder().decode(MemoryHistoryRetirementReport.self, from: Data(apply.stdout.utf8)).status, "retired")
    let old = try run(["memory", "show-version", "m", "--record-id", "\(head.recordId)",
      "--memory-root", root.path, "--version", "1", "--output", "json"])
    XCTAssertNotEqual(old.exitCode, .success)
    XCTAssertTrue(old.stdout.contains("retiredVersion"))
    XCTAssertFalse(apply.stdout.contains("old body"))
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: head.recordId, version: 2), head)
  }

  func testMissingOwnershipOrRelativeRootRejectsBeforeMutation() throws {
    for extra in [[], ["--memory-root", "relative"]] {
      let tokens = ["memory", "retire-history", "m", "--record-id", "1", "--expected-head-version", "2", "--through-version", "1"] + extra
      guard case let .memory(command) = try RielaArgumentParser().parse(tokens) else {
        return XCTFail("expected memory command")
      }
      let result = MemoryCommandRunner().run(command)
      XCTAssertNotEqual(result.exitCode, .success)
      XCTAssertTrue(result.stdout.contains("requires explicit absolute"))
    }
  }
}
