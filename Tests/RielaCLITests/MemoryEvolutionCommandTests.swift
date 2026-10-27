import Foundation
import RielaMemory
import XCTest
@testable import RielaCLI

final class MemoryEvolutionCommandTests: XCTestCase {
  func testHistoryShowAndRestoreThroughParsedCommands() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/evolution-history/cli-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let original = try store.save(memoryId: "m", workflowId: "w", payload: .string("before"))
    _ = try store.update(memoryId: "m", recordId: original.recordId, payload: .string("after"))
    let common = ["m", "--record-id", "\(original.recordId)", "--memory-root", root.path, "--output", "json"]
    func run(_ action: String, _ options: [String] = []) throws -> CLICommandResult {
      let parsed = try RielaArgumentParser().parse(["memory", action] + common + options)
      guard case let .memory(command) = parsed else { throw CLIUsageError("expected memory command") }
      return MemoryCommandRunner().run(command)
    }
    let history = try run("history")
    XCTAssertEqual(history.exitCode, .success)
    let revisions = try JSONDecoder().decode([MemoryEvolutionRevision].self, from: Data(history.stdout.utf8))
    XCTAssertEqual(revisions.map(\.version), [2, 1])
    XCTAssertNil(revisions.first?.reverseDelta)
    XCTAssertEqual(revisions.first?.isHead, true)
    XCTAssertNotNil(revisions.first?.storage)
    let shown = try run("show-version", ["--version", "1"])
    XCTAssertEqual(shown.exitCode, .success)
    XCTAssertEqual(try JSONDecoder().decode(MemoryRecord.self, from: Data(shown.stdout.utf8)), original)
    XCTAssertNotEqual(try run("restore-version", ["--version", "1"]).exitCode, .success)
    let staleRestore = try run("restore-version", ["--version", "1", "--expected-head-version", "1"])
    XCTAssertNotEqual(staleRestore.exitCode, .success)
    XCTAssertTrue(staleRestore.stdout.contains("stale_revision"))
    XCTAssertEqual(try run("restore-version", ["--version", "1", "--expected-head-version", "2"]).exitCode, .success)
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: original.recordId, version: 3), original)
    XCTAssertThrowsError(try RielaArgumentParser().parse(["memory", "show-version"] + common + ["--version", "0"]))
  }
}
