import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class SandboxCredentialProjectionTests: XCTestCase {
  func testBinaryCredentialSnapshotAndPinnedHomeAlias() throws {
    let root = try makeRielaCLITestTemporaryDirectory("credential-projection")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    let source = root.appendingPathComponent("auth.bin")
    let bytes = Data([0, 255, 1, 0, 128])
    try bytes.write(to: source)
    let projection = try SandboxCredentialProjection(credentials: [.init(source: source.path, homePath: ".vendor/auth")],
      parent: root, writableRoots: [home])
    try projection.install(in: home)
    XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent(".vendor/auth")), bytes)
    try Data("refreshed-host-value".utf8).write(to: source)
    XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent(".vendor/auth")), bytes, "snapshot must remain stable for its invocation")
    XCTAssertEqual(try Data(contentsOf: source), Data("refreshed-host-value".utf8))
  }

  func testPreviousGuestCannotRedirectCredentialInstallationIntoHostDirectory() throws {
    let root = try makeRielaCLITestTemporaryDirectory("credential-parent-symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let outside = root.appendingPathComponent("outside")
    for directory in [home, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
    let source = root.appendingPathComponent("auth")
    let sentinel = outside.appendingPathComponent("auth")
    try "credential".write(to: source, atomically: true, encoding: .utf8)
    try "host-sentinel".write(to: sentinel, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".vendor"), withDestinationURL: outside)
    let projection = try SandboxCredentialProjection(credentials: [.init(source: source.path, homePath: ".vendor/auth")],
      parent: root, writableRoots: [home])
    XCTAssertThrowsError(try projection.install(in: home))
    XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "host-sentinel")
  }

  func testCredentialDirectoryRefusesNestedSymlinksAndWritableSources() throws {
    let root = try makeRielaCLITestTemporaryDirectory("credential-source-policy")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    let source = root.appendingPathComponent("credentials")
    for directory in [home, source] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
    let secret = root.appendingPathComponent("unselected")
    try "must-not-copy".write(to: secret, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link"), withDestinationURL: secret)
    XCTAssertThrowsError(try SandboxCredentialProjection(credentials: [.init(source: source.path, homePath: ".vendor")],
      parent: root, writableRoots: [home]))
    XCTAssertThrowsError(try SandboxCredentialProjection(credentials: [.init(source: secret.path, homePath: ".vendor/auth")],
      parent: root, writableRoots: [root]))
  }
}
