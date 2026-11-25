import Foundation
import XCTest
@testable import RielaCore

enum BotMemoryFixture {
  static let botId = "release"
  static let now = Date(timeIntervalSince1970: 1_750_000_000)
  static let timestamp = RoutineStore.timestamp(now)

  static func withWriter(limits: BotMemoryLimits = .init(), _ body: (BotMemoryWriter, BotStore) throws -> Void) throws {
    let repo = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repo.appendingPathComponent("tmp/bots-overview/bots-06-memory-core/fixtures/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotStore(sessionStoreRoot: root.appendingPathComponent("sessions").path)
    try createBot(botId, in: store)
    let writer = BotMemoryWriter(
      botStore: store, memoryRoot: root.appendingPathComponent("memory").path,
      redact: { $0.replacingOccurrences(of: "sk-[A-Za-z0-9]+", with: "[REDACTED]", options: .regularExpression) },
      limits: limits, now: { now }
    )
    try body(writer, store)
  }

  static func createBot(_ id: String, in store: BotStore) throws {
    try store.create(.init(botId: id, name: id, createdAt: timestamp, updatedAt: timestamp))
  }

  static func entry(
    _ text: String, kind: BotMemoryKind = .note, topic: String = "general",
    source: BotMemorySource = .user, id: Int64? = nil, capturedAt: String = timestamp
  ) -> BotMemoryEntry {
    .init(
      recordId: id, kind: kind, topic: topic, text: text,
      provenance: .init(source: source, ref: "session:fixture", capturedAt: capturedAt, actor: "fixture")
    )
  }

  static func expectError(
    _ code: String, _ expression: @autoclosure () throws -> some Any,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
      XCTAssertEqual((error as? BotStoreError)?.code, code, String(describing: error), file: file, line: line)
    }
  }
}
