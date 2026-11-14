import Foundation
import XCTest
@testable import RielaCLI

final class BuiltinAddonContainerStateDirectoryTests: XCTestCase {
  func testRepeatedPreparationPreservesWorkerFiles() throws {
    let root = try makeRielaCLITestTemporaryDirectory("container-state-path")
    defer { try? FileManager.default.removeItem(at: root) }
    let state = root.appendingPathComponent("state")
    try prepareBuiltinAddonContainerState(at: state)
    let file = state.appendingPathComponent("home/keep.txt")
    try Data("keep".utf8).write(to: file)
    try prepareBuiltinAddonContainerState(at: state)
    XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
  }

  func testGuestSymlinkCannotRedirectHostDirectoryPreparation() throws {
    let root = try makeRielaCLITestTemporaryDirectory("container-state-symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside")
    let state = root.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("home"), withDestinationURL: outside)
    XCTAssertThrowsError(try prepareBuiltinAddonContainerState(at: state))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: outside)
    XCTAssertThrowsError(try prepareBuiltinAddonContainerState(at: root.appendingPathComponent("alias/state")))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }
}
