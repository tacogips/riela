import Foundation
import XCTest
import RielaMemory

final class WriteIntentPersistenceTests: XCTestCase {
  func testAlternatingDurableSlotsPreserveSelectedTargetUntilPointerCommit() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaWriteIntentStore(rootDirectory: root.path, storeId: "intents", scope: "date-a")
    let one = try store.stage(key: "first", serializedJSON: #"{"n":1.0,"text":"{{literal}}"}"#, selected: nil)
    let two = try store.stage(key: "second", serializedJSON: #"{"n":2}"#, selected: one)
    XCTAssertNotEqual(one.slot, two.slot)
    XCTAssertEqual(try store.load(one), #"{"n":1.0,"text":"{{literal}}"}"#)
    let restarted = RielaWriteIntentStore(rootDirectory: root.path, storeId: "intents", scope: "date-a")
    XCTAssertEqual(try restarted.load(two), #"{"n":2}"#)
    let three = try restarted.stage(key: "third", serializedJSON: #"{"n":3}"#, selected: two)
    XCTAssertEqual(three.slot, one.slot)
    XCTAssertNil(try restarted.load(one))
    XCTAssertEqual(try restarted.load(two), #"{"n":2}"#)
    XCTAssertEqual(try restarted.stage(key: "third", serializedJSON: #"{"n":3}"#, selected: three), three)
    try restarted.clear()
    XCTAssertNil(try restarted.load(two)); XCTAssertNil(try restarted.load(three))
    let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("intents.sqlite").path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testOwnerAndStaleSelectedReferenceAreFenced() throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaWriteIntentStore(rootDirectory: root.path, storeId: "intents", scope: "a")
    let one = try store.stage(key: "one", serializedJSON: "{}", selected: nil)
    let foreign = RielaWriteIntentStore(rootDirectory: root.path, storeId: "intents", scope: "b")
    XCTAssertThrowsError(try foreign.load(one))
    try store.clear()
    XCTAssertThrowsError(try store.stage(key: "two", serializedJSON: "[]", selected: one))
    XCTAssertThrowsError(try store.stage(key: "bad", serializedJSON: "not json", selected: nil))
    XCTAssertThrowsError(try store.stage(key: "", serializedJSON: "{}", selected: nil))
  }
}
