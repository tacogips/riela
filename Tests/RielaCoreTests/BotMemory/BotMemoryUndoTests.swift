import Foundation
import XCTest
@testable import RielaCore

final class BotMemoryUndoTests: XCTestCase {
  private typealias Fixture = BotMemoryFixture

  func testUndoLatestRestoresAddedUpdatedAndRemovedRecords() throws {
    try Fixture.withWriter { writer, _ in
      let seed = try writer.apply(
        botId: Fixture.botId, changes: [.add(Fixture.entry("Original")), .add(Fixture.entry("Restore"))], actor: "cli", reason: "seed"
      )
      let before = try writer.entries(botId: Fixture.botId)
      let ids = seed.entries.map(\.recordId)
      let change = try writer.apply(
        botId: Fixture.botId, changes: [
          .add(Fixture.entry("Added")),
          .update(recordId: ids[0], text: "Updated", topic: "updated", kind: .instruction, source: .correction),
          .remove(recordId: ids[1], source: .user)
        ], actor: "cli", reason: "edit"
      )
      let after = try writer.entries(botId: Fixture.botId)

      let undo = try writer.undo(botId: Fixture.botId, actor: "api")
      XCTAssertEqual(try writer.entries(botId: Fixture.botId), before)
      XCTAssertEqual(undo.reason, "undo:\(change.changeId)")
      XCTAssertEqual(undo.actor, .api)
      XCTAssertEqual(undo.entries.map(\.op), [.remove, .update, .update])
      XCTAssertEqual(try writer.history(botId: Fixture.botId), [undo, change, seed])

      let redo = try writer.undo(botId: Fixture.botId, changeId: undo.changeId, actor: "api")
      XCTAssertEqual(try writer.entries(botId: Fixture.botId), after)
      XCTAssertEqual(redo.reason, "undo:\(undo.changeId)")
    }
  }

  func testUndoConflictDoesNotChangeAnyEntry() throws {
    try Fixture.withWriter { writer, _ in
      let change = try writer.apply(
        botId: Fixture.botId, changes: [.add(Fixture.entry("Untouched")), .add(Fixture.entry("Before"))], actor: "cli", reason: "seed"
      )
      let id = try XCTUnwrap(change.entries.last?.recordId)
      let later = try writer.apply(
        botId: Fixture.botId, changes: [.update(recordId: id, text: "After", topic: "general", kind: .note, source: .user)],
        actor: "cli", reason: "edit"
      )
      let beforeUndo = try writer.entries(botId: Fixture.botId)
      Fixture.expectError("memory_change_conflict", try writer.undo(botId: Fixture.botId, changeId: change.changeId))
      XCTAssertEqual(try writer.entries(botId: Fixture.botId), beforeUndo)
      XCTAssertEqual(try writer.history(botId: Fixture.botId), [later, change])
    }
  }

  func testDiffReportsAddedRecordAndUpdatedTextFromStoredVersions() throws {
    try Fixture.withWriter { writer, _ in
      let initial = try writer.apply(botId: Fixture.botId, changes: [.add(Fixture.entry("Old"))], actor: "cli", reason: "seed")
      let id = try XCTUnwrap(initial.entries.first?.recordId)
      let change = try writer.apply(
        botId: Fixture.botId, changes: [.update(recordId: id, text: "New", topic: "general", kind: .note, source: .user)],
        actor: "cli", reason: "edit"
      )
      let added = try XCTUnwrap(writer.diff(botId: Fixture.botId, changeId: initial.changeId).first)
      let payload = try XCTUnwrap(added.changes.first { $0.path == "/payload" })
      XCTAssertNil(payload.beforeJSON)
      let value = try XCTUnwrap(String(data: try XCTUnwrap(payload.afterJSON), encoding: .utf8))
      XCTAssertTrue(value.contains("Old"))

      let updated = try XCTUnwrap(writer.diff(botId: Fixture.botId, changeId: change.changeId).first)
      let text = try XCTUnwrap(updated.changes.first { $0.path == "/payload/text" })
      XCTAssertEqual(text.beforeJSON, Data("\"Old\"".utf8))
      XCTAssertEqual(text.afterJSON, Data("\"New\"".utf8))
    }
  }

  func testUpkeepRejectionUsesRetainedNoteIdsAndHalfThreshold() {
    let notes = (1...6).map { Fixture.entry("Note \($0)", id: Int64($0)) }
    let instruction = Fixture.entry("Rule", kind: .instruction, id: 7)
    let items = (1...3).map { BotMemoryMarkdownItem(kind: .note, topic: "general", text: "Note \($0)", recordId: Int64($0)) }
    XCTAssertEqual(BotMemoryWriter.upkeepRejection(current: notes + [instruction], proposed: Array(items.prefix(2))), "upkeep_removes_too_much")
    XCTAssertNil(BotMemoryWriter.upkeepRejection(current: notes + [instruction], proposed: items))
    XCTAssertNil(BotMemoryWriter.upkeepRejection(current: Array(notes.prefix(3)), proposed: Array(items.prefix(1))))
  }

  func testUpkeepMarkdownCannotRemoveTooManyNotes() throws {
    try Fixture.withWriter { writer, _ in
      let seed = try writer.apply(
        botId: Fixture.botId, changes: (1...4).map { .add(Fixture.entry("Note \($0)")) }, actor: "cli", reason: "seed"
      )
      let before = try writer.entries(botId: Fixture.botId)
      Fixture.expectError("upkeep_removes_too_much", try writer.applyMarkdown(
        botId: Fixture.botId, markdown: "## Notes\n- New note", source: .upkeep, actor: "upkeep", reason: "consolidate"
      ))
      XCTAssertEqual(try writer.entries(botId: Fixture.botId), before)
      XCTAssertEqual(try writer.history(botId: Fixture.botId), [seed])
    }
  }
}
