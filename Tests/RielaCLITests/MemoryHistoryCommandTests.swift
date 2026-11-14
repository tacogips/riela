import Foundation
import RielaMemory
import XCTest
@testable import RielaCLI

final class MemoryHistoryCommandTests: XCTestCase {
  func testDefaultRetentionHistoryUndoRedoAndStaleRevision() throws {
    let root = temporaryRoot("history-default")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.save(memoryId: "m", workflowId: "w", payload: .string("one"))
    _ = try store.update(memoryId: "m", recordId: first.recordId, payload: .string("two"))
    _ = try store.update(memoryId: "m", recordId: first.recordId, payload: .string("three"))
    _ = try store.update(memoryId: "m", recordId: first.recordId, payload: .string("four"))

    let history = try run("history", memoryId: "m", recordId: first.recordId, root: root)
    XCTAssertEqual(history.exitCode, .success)
    let revisions = try JSONDecoder().decode([MemoryEvolutionRevision].self, from: Data(history.stdout.utf8))
    XCTAssertEqual(revisions.map(\.version), [4, 3])
    XCTAssertEqual(revisions.first?.isHead, true)
    XCTAssertNotNil(revisions.first?.revision)
    let dropped = try run("show-version", memoryId: "m", recordId: first.recordId, root: root, extra: ["--version", "1"])
    XCTAssertNotEqual(dropped.exitCode, .success)
    XCTAssertTrue(dropped.stdout.contains("version_not_retained"))
    XCTAssertTrue(dropped.stdout.contains("retained versions: [4, 3]"))
    XCTAssertTrue(dropped.stdout.contains("dropped by retention or never a stored version"))

    let undo = try run("undo", memoryId: "m", recordId: first.recordId, root: root, extra: ["--expected-head-version", "4"])
    XCTAssertEqual(undo.exitCode, .success)
    let moved = try JSONDecoder().decode(MemoryHeadMoveResult.self, from: Data(undo.stdout.utf8))
    XCTAssertEqual(moved.record.payload, .string("three"))
    let noMoreUndo = try run("undo", memoryId: "m", recordId: first.recordId, root: root, extra: ["--expected-head-version", "5"])
    XCTAssertNotEqual(noMoreUndo.exitCode, .success)
    XCTAssertTrue(noMoreUndo.stdout.contains("nothing_to_undo"))

    let redo = try run("redo", memoryId: "m", recordId: first.recordId, root: root, extra: ["--expected-head-version", "5"])
    XCTAssertEqual(redo.exitCode, .success)
    XCTAssertEqual(try JSONDecoder().decode(MemoryHeadMoveResult.self, from: Data(redo.stdout.utf8)).record.payload, .string("four"))
    let stale = try run("undo", memoryId: "m", recordId: first.recordId, root: root, extra: ["--expected-head-version", "5"])
    XCTAssertNotEqual(stale.exitCode, .success)
    XCTAssertTrue(stale.stdout.contains("stale_revision"))

    let branchUndo = try run("undo", memoryId: "m", recordId: first.recordId, root: root, extra: ["--expected-head-version", "6"])
    XCTAssertEqual(branchUndo.exitCode, .success)
    let branchHead = try JSONDecoder().decode(MemoryHeadMoveResult.self, from: Data(branchUndo.stdout.utf8))
    let branchUpdate = try run("update", memoryId: "m", recordId: first.recordId, root: root, extra: [
      "--workflow-id", "w", "--payload-json", "\"new branch\""
    ])
    XCTAssertEqual(branchUpdate.exitCode, .success)
    let redoAfterBranch = try run("redo", memoryId: "m", recordId: first.recordId, root: root,
      extra: ["--expected-head-version", "\(branchHead.revision + 1)"])
    XCTAssertNotEqual(redoAfterBranch.exitCode, .success)
    XCTAssertTrue(redoAfterBranch.stdout.contains("nothing_to_redo"))
  }

  func testHistoryRetentionOptionAndDiffSchema() throws {
    let root = temporaryRoot("history-explicit-retention")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let record = try store.save(memoryId: "m", workflowId: "w", payload: .string("one"))
    for value in 2...5 {
      let result = try run("update", memoryId: "m", recordId: record.recordId, root: root, extra: [
        "--workflow-id", "w", "--payload-json", "\"value-\(value)\"", "--history-retention", "5"
      ])
      XCTAssertEqual(result.exitCode, .success, result.stdout)
    }
    let history = try run("history", memoryId: "m", recordId: record.recordId, root: root)
    let revisions = try JSONDecoder().decode([MemoryEvolutionRevision].self, from: Data(history.stdout.utf8))
    XCTAssertEqual(revisions.map(\.version), [5, 4, 3, 2, 1])
    XCTAssertThrowsError(try RielaArgumentParser().parse([
      "memory", "update", "m", "--workflow-id", "w", "--record-id", "\(record.recordId)",
      "--payload-json", "{}", "--history-retention", "0"
    ]))

    let shapedRecord = try store.save(memoryId: "diff-schema", workflowId: "w",
      payload: .object(["keep": .string("old"), "removed": .bool(true)]))
    _ = try store.update(memoryId: "diff-schema", recordId: shapedRecord.recordId, payload: .object([
      "keep": .string("new"), "added": .object(["z": .number(1), "a": .string("https://example.test/a")])
    ]))
    let diff = try run("show-version", memoryId: "diff-schema", recordId: shapedRecord.recordId, root: root,
      extra: ["--version", "1", "--diff-against", "head"])
    XCTAssertEqual(diff.exitCode, .success)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(diff.stdout.utf8)) as? [String: Any])
    let entries = try XCTUnwrap(json["diff"] as? [[String: Any]])
    XCTAssertFalse(entries.isEmpty)
    let replace = try XCTUnwrap(entries.first { $0["op"] as? String == "replace" })
    XCTAssertEqual(Set(replace.keys), Set(["path", "op", "before", "after"]))
    XCTAssertNotNil(replace["path"])
    let addRemove = entries.filter { ["add", "remove"].contains($0["op"] as? String ?? "") }
    XCTAssertEqual(Set(addRemove.compactMap { $0["op"] as? String }), Set(["add", "remove"]))
    XCTAssertTrue(addRemove.filter { $0["op"] as? String == "add" }
      .allSatisfy { $0["before"] == nil && $0["after"] != nil })
    XCTAssertTrue(addRemove.filter { $0["op"] as? String == "remove" }
      .allSatisfy { $0["before"] != nil && $0["after"] == nil })
    let textDiff = try run("show-version", memoryId: "diff-schema", recordId: shapedRecord.recordId, root: root,
      extra: ["--version", "1", "--diff-against", "head"], output: "text")
    XCTAssertEqual(textDiff.exitCode, .success, textDiff.stdout)
    XCTAssertTrue(textDiff.stdout.contains("add /payload/added\nbefore: <absent>\nafter: {\"a\":\"https://example.test/a\",\"z\":1}"), textDiff.stdout)
    XCTAssertFalse(textDiff.stdout.contains("\\/"), textDiff.stdout)

    let numericDiff = try run("show-version", memoryId: "m", recordId: record.recordId, root: root,
      extra: ["--version", "3", "--diff-against", "4"])
    XCTAssertEqual(numericDiff.exitCode, .success, numericDiff.stdout)
    XCTAssertTrue(numericDiff.stdout.contains("\"diff\""))

    XCTAssertThrowsError(try RielaArgumentParser().parse(["memory", "history", "m", "--diff-against", "head"]))
    XCTAssertThrowsError(try RielaArgumentParser().parse(["memory", "history", "m", "--history-retention", "3"]))
  }

  func testHistoryTextShowsHeadRevisionStorageAndDroppedVersions() throws {
    let root = temporaryRoot("history-text")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let record = try store.save(memoryId: "m", workflowId: "w", payload: .string("one"))
    _ = try store.update(memoryId: "m", recordId: record.recordId, payload: .string("two"))
    _ = try store.update(memoryId: "m", recordId: record.recordId, payload: .string("three"))
    let result = try run("history", memoryId: "m", recordId: record.recordId, root: root, extra: ["--output", "text"])
    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stdout.contains("version 3 "))
    XCTAssertTrue(result.stdout.contains("head revision 3"))
    let head = try XCTUnwrap(store.evolutionHistory(memoryId: "m", recordId: record.recordId).first)
    let storage = try XCTUnwrap(head.storage)
    XCTAssertTrue(result.stdout.contains(" \(storage.encoding) \(storage.storedBytes)B"))
    XCTAssertTrue(result.stdout.contains("older versions dropped by retention (retained: 2...head)"))
  }

  private func run(
    _ action: String,
    memoryId: String,
    recordId: Int64,
    root: URL,
    extra: [String] = [],
    output: String = "json"
  ) throws -> CLICommandResult {
    let tokens = ["memory", action, memoryId, "--record-id", "\(recordId)", "--memory-root", root.path,
      "--output", output] + extra
    guard case let .memory(command) = try RielaArgumentParser().parse(tokens) else {
      throw CLIUsageError("expected memory command")
    }
    return MemoryCommandRunner().run(command)
  }

  private func temporaryRoot(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/\(name)-\(UUID().uuidString)")
  }
}
