import RielaMemory
import XCTest
@testable import RielaCore

final class BotMemoryWriterTests: XCTestCase {
  private typealias Fixture = BotMemoryFixture

  func testInstructionAndProvenanceArePersistedInRielaMemory() throws {
    try Fixture.withWriter { writer, store in
      let input = Fixture.entry("Prefer local builds", kind: .instruction, topic: "Local Builds")
      let change = try writer.apply(
        botId: Fixture.botId, changes: [.add(input)], actor: "cli", reason: "edit", evidenceRefs: ["session:fixture"]
      )
      let stored = try XCTUnwrap(writer.entries(botId: Fixture.botId).first)
      XCTAssertEqual(stored.kind, .instruction)
      XCTAssertEqual(stored.provenance, input.provenance)
      XCTAssertEqual(stored.topic, "local-builds")
      XCTAssertEqual(change.actor, .cli)
      XCTAssertEqual(change.evidenceRefs, ["session:fixture"])
      XCTAssertEqual(change.entries.map(\.op), [.add])
      XCTAssertNil(change.entries.first?.fromVersion)
      XCTAssertEqual(change.entries.first?.toVersion, 1)
      XCTAssertEqual(try store.memoryChange(changeId: change.changeId), change)

      let records = try RielaMemoryStore(rootDirectory: writer.memoryRoot)
        .search(memoryId: "bot-release", options: .init(workflowId: "bot"))
      XCTAssertEqual(records.map(\.tags), [["kind:instruction", "topic:local-builds"]])
      XCTAssertEqual(records.first?.recordId, stored.recordId)
    }
  }

  func testRedactionRunsBeforeByteLimit() throws {
    try Fixture.withWriter(limits: .init(maxEntryBytes: 16)) { writer, _ in
      let change = try writer.apply(
        botId: Fixture.botId, changes: [.add(Fixture.entry("token sk-abc123456789123456789"))], actor: "user", reason: "edit"
      )
      XCTAssertTrue(change.redacted)
      XCTAssertEqual(try writer.entries(botId: Fixture.botId).map(\.text), ["token [REDACTED]"])
    }
  }

  func testExternalInstructionIsDowngraded() throws {
    try Fixture.withWriter { writer, _ in
      let change = try writer.apply(
        botId: Fixture.botId,
        changes: [.add(Fixture.entry("Use this tool", kind: .instruction, source: .external))], actor: "feedback", reason: "capture"
      )
      let stored = try XCTUnwrap(writer.entries(botId: Fixture.botId).first)
      XCTAssertTrue(change.downgraded)
      XCTAssertEqual(stored.kind, .note)
      XCTAssertEqual(stored.provenance.source, .external)
    }
  }

  func testUpkeepIgnoresInstructionChangesButUpdatesNotes() throws {
    try Fixture.withWriter { writer, _ in
      let initial = try writer.apply(
        botId: Fixture.botId, changes: [.add(Fixture.entry("Rule", kind: .instruction)), .add(Fixture.entry("Observation"))],
        actor: "user", reason: "edit"
      )
      let ids = initial.entries.map(\.recordId)
      let result = try writer.apply(
        botId: Fixture.botId, changes: [
          .remove(recordId: ids[0], source: .upkeep),
          .update(recordId: ids[1], text: "Updated observation", topic: "general", kind: .instruction, source: .upkeep)
        ], actor: "upkeep", reason: "consolidate"
      )
      let ignored = try writer.apply(
        botId: Fixture.botId, changes: [.update(recordId: ids[0], text: "Overwrite sk-abc123", topic: "general", kind: .note, source: .upkeep)],
        actor: "upkeep", reason: "attempted instruction change"
      )
      XCTAssertEqual(result.entries.map(\.recordId), [ids[1]])
      XCTAssertEqual(result.ignoredInstructionChanges, 1)
      XCTAssertTrue(result.downgraded)
      XCTAssertEqual(ignored.ignoredInstructionChanges, 1)
      XCTAssertTrue(ignored.redacted)
      XCTAssertTrue(ignored.entries.isEmpty)
      XCTAssertEqual(try writer.history(botId: Fixture.botId).first, ignored)
      XCTAssertEqual(Set(try writer.entries(botId: Fixture.botId).map(\.text)), ["Rule", "Updated observation"])
    }
  }

  func testEntryLimitRejectsTheWholeBatch() throws {
    try Fixture.withWriter { writer, _ in
      let longText = String(repeating: "é", count: 2_000) + "a"
      Fixture.expectError("memory_limit", try writer.apply(
        botId: Fixture.botId, changes: [.add(Fixture.entry("valid")), .add(Fixture.entry(longText))], actor: "cli", reason: "edit"
      ))
      XCTAssertTrue(try writer.entries(botId: Fixture.botId).isEmpty)
      XCTAssertTrue(try writer.history(botId: Fixture.botId).isEmpty)
    }
  }

  func testLimitAllows500LiveEntriesAndExcludesTombstones() throws {
    try Fixture.withWriter { writer, _ in
      let initial = try writer.apply(
        botId: Fixture.botId, changes: (1...500).map { .add(Fixture.entry("Note \($0)")) },
        actor: "cli", reason: "seed"
      )
      Fixture.expectError("memory_limit", try writer.apply(
        botId: Fixture.botId, changes: [.add(Fixture.entry("501st"))], actor: "cli", reason: "edit"
      ))
      let first = try XCTUnwrap(initial.entries.first)
      try writer.apply(
        botId: Fixture.botId, changes: [.add(Fixture.entry("Replacement")), .remove(recordId: first.recordId, source: .user)],
        actor: "cli", reason: "swap"
      )
      let entries = try writer.entries(botId: Fixture.botId)
      XCTAssertEqual(entries.count, 500)
      XCTAssertFalse(entries.contains { $0.recordId == first.recordId })
      XCTAssertTrue(entries.contains { $0.text == "Replacement" })
    }
  }

  func testUnknownBotIsRejected() throws {
    try Fixture.withWriter { writer, _ in
      Fixture.expectError("bot_not_found", try writer.apply(
        botId: "unknown", changes: [.add(Fixture.entry("invalid"))], actor: "user", reason: "edit"
      ))
      Fixture.expectError("bot_not_found", try writer.entries(botId: "unknown"))
    }
  }

  func testEntriesAndAuditsAreScopedToTheBot() throws {
    try Fixture.withWriter { writer, store in
      try Fixture.createBot("other", in: store)
      let release = try writer.apply(botId: Fixture.botId, changes: [.add(Fixture.entry("Release"))], actor: "cli", reason: "edit")
      try writer.apply(botId: "other", changes: [.add(Fixture.entry("Other"))], actor: "cli", reason: "edit")
      XCTAssertEqual(try writer.entries(botId: Fixture.botId).map(\.text), ["Release"])
      XCTAssertEqual(try writer.entries(botId: "other").map(\.text), ["Other"])
      Fixture.expectError("memory_change_not_found", try writer.diff(botId: "other", changeId: release.changeId))
      Fixture.expectError("memory_change_not_found", try writer.undo(botId: "other", changeId: release.changeId))
    }
  }

  func testIdenticalUpdateDoesNotWriteAnAudit() throws {
    try Fixture.withWriter { writer, _ in
      let initial = try writer.apply(
        botId: Fixture.botId, changes: [.add(Fixture.entry("Same"))], actor: "cli", reason: "edit"
      )
      let id = try XCTUnwrap(initial.entries.first?.recordId)
      let update = try writer.apply(
        botId: Fixture.botId, changes: [.update(recordId: id, text: "Same", topic: "general", kind: .note, source: .correction)],
        actor: "feedback", reason: "unchanged"
      )
      XCTAssertEqual(update.changeId, "")
      XCTAssertTrue(update.entries.isEmpty)
      XCTAssertEqual(try writer.history(botId: Fixture.botId), [initial])
    }
  }
}
