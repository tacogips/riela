import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

@MainActor
final class RemoteRegistryTests: XCTestCase {
  func testPrivateModesAndSeparateTokenStorage() throws {
    let fixture = try RemoteTestFixture(test: self)
    let registry = fixture.registry
    let credentialRoot = fixture.root.appendingPathComponent("credentials")
    let registryFile = credentialRoot.appendingPathComponent("remotes.json")
    let tokenDirectory = credentialRoot.appendingPathComponent("remotes")
    let tokenFile = tokenDirectory.appendingPathComponent("srv.token")
    let secret = UUID().uuidString

    XCTAssertEqual(try registry.list().active, "local")
    try registry.add(record: record(), token: secret)
    XCTAssertEqual(try permissions(credentialRoot), 0o700)
    XCTAssertEqual(try permissions(tokenDirectory), 0o700)
    XCTAssertEqual(try permissions(registryFile), 0o600)
    XCTAssertEqual(try permissions(tokenFile), 0o600)
    XCTAssertTrue(try registry.token(name: "srv") == secret)
    XCTAssertFalse(try String(contentsOf: registryFile, encoding: .utf8).contains(secret))
  }

  func testDuplicateReservedAndActiveRemoval() throws {
    let fixture = try RemoteTestFixture(test: self)
    let registry = fixture.registry
    try registry.add(record: record(), token: "fixture-token")
    XCTAssertThrowsError(try registry.add(record: record(), token: "replacement")) { error in
      XCTAssertEqual((error as? BotStoreError)?.code, "remote_exists")
    }
    for name in ["local", "*", "unverified", "../srv", "UPPER"] {
      XCTAssertThrowsError(try registry.add(record: record(name: name), token: "invalid")) { error in
        XCTAssertEqual((error as? BotStoreError)?.code, "remote_name_invalid")
      }
    }
    XCTAssertTrue(try registry.token(name: "srv") == "fixture-token")
    try registry.use(name: "srv")
    XCTAssertEqual(try registry.list().active, "srv")
    try registry.remove(name: "srv")
    let afterRemoval = try registry.list()
    XCTAssertEqual(afterRemoval.active, "local")
    XCTAssertTrue(afterRemoval.remotes.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: fixture.root.appendingPathComponent("credentials/remotes/srv.token").path
    ))
  }

  func testCredentialDirectoryFollowsXDGStateHome() throws {
    let fixture = try RemoteTestFixture(test: self)
    var environment = fixture.environment
    environment["RIELA_CREDENTIAL_DIR"] = nil
    let registry = RemoteRegistry(environment: environment)
    try registry.add(record: record(), token: "fixture-token")
    let expected = fixture.root.appendingPathComponent("state/riela/credentials/remotes.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".config").path))
  }

  func testTokenReadRefusesSymlink() throws {
    let fixture = try RemoteTestFixture(test: self)
    let registry = fixture.registry
    try registry.add(record: record(), token: "fixture-token")
    let tokenFile = fixture.root.appendingPathComponent("credentials/remotes/srv.token")
    let otherFile = fixture.root.appendingPathComponent("other")
    let manager = FileManager.default
    try Data("separate file".utf8).write(to: otherFile)
    try manager.removeItem(at: tokenFile)
    try manager.createSymbolicLink(at: tokenFile, withDestinationURL: otherFile)
    XCTAssertThrowsError(try registry.token(name: "srv"))
  }

  private func permissions(_ url: URL) throws -> Int {
    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  private func record(name: String = "srv") -> RemoteRecord {
    RemoteRecord(
      name: name, address: "https://riela.example", serverId: "server-id", serverName: "Riela",
      grantId: "grant-id", scope: .read, addedAt: Date(timeIntervalSince1970: 0)
    )
  }
}
