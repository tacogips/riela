import Foundation
import XCTest
@testable import RielaCore

final class BotListStateStoreTests: XCTestCase {
  func testPinRoundTripsAndDefaultDeletesOnlySelectedRow() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bot-list-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BotStore(sessionStoreRoot: directory.path)
    XCTAssertTrue(try store.listState(botId: "build").isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.databasePath))
    try store.create(BoardFixture.input("build").bot)
    try store.create(BoardFixture.input("release").bot)

    let pinned = try store.setListState(botId: "build", key: .bot) { $0.pinned = true }
    XCTAssertEqual(pinned, BotListState(pinned: true))
    let taskKey = BotListStateKey(itemKind: "task", itemId: "review")
    try store.setListState(botId: "build", key: taskKey) { $0.manualOrder = 1 }
    try store.setListState(botId: "release", key: .bot) { $0.pinned = true }
    let updated = try store.setListState(botId: "build", key: .bot) { $0.snoozedUntil = BoardFixture.now }
    XCTAssertTrue(updated.pinned)
    XCTAssertEqual(try store.listState(botId: "build"), [.bot: updated, taskKey: BotListState(manualOrder: 1)])

    try store.setListState(botId: "build", key: .bot) { $0 = BotListState() }
    XCTAssertEqual(try store.listState(botId: "build"), [taskKey: BotListState(manualOrder: 1)])
    XCTAssertEqual(try store.listState(botId: "release"), [.bot: pinned])
    XCTAssertEqual(try store.read { try $0.query("SELECT item_kind FROM bot_list_state WHERE bot_id = 'build'").count }, 1)

    try store.remove(botId: "build")
    XCTAssertThrowsError(try store.setListState(botId: "build", key: .bot) { $0.pinned = true }) { error in
      XCTAssertEqual((error as? BotStoreError)?.code, "bot_not_found")
    }
    XCTAssertTrue(try store.listState(botId: "build").isEmpty)
  }
}
