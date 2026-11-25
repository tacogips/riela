import Foundation
import XCTest
@testable import RielaServer

@MainActor
final class ServerIdentityTests: XCTestCase {
  func testIdentityIsStableAndCanBeRenamed() throws {
    let fixture = try PairingTestFixture()
    defer { fixture.remove() }
    let root = fixture.store.root
    let initial = try RielaServerIdentity.loadOrCreate(root: root, name: nil)
    XCTAssertNotNil(UUID(uuidString: initial.serverId))
    XCTAssertEqual(initial.serverId, initial.serverId.lowercased())
    XCTAssertEqual(initial.name, ProcessInfo.processInfo.hostName)
    XCTAssertEqual(try RielaServerIdentity.loadOrCreate(root: root, name: nil), initial)
    let renamed = try RielaServerIdentity.loadOrCreate(root: root, name: "Office")
    XCTAssertEqual(renamed.serverId, initial.serverId)
    XCTAssertEqual(renamed.name, "Office")
    XCTAssertEqual(try RielaServerIdentity.loadOrCreate(root: root, name: nil), renamed)
    let path = root.appendingPathComponent("server-identity.json").path
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
  }
}
