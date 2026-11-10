import Foundation
import XCTest
import RielaCore
@testable import RielaAppSupport

final class RielaAppInstanceReloadContractTests: XCTestCase {
  func testStrictRequest() throws {
    let valid = """
    {"expectedProfile":"default","expectedRevision":1,"reason":" ok ","workflowDirectory":null,"interruptRunning":false}
    """
    XCTAssertEqual(try RielaAppInstanceReloadRequest.decodeStrict(Data(valid.utf8)).reason, "ok")
    for invalid in [valid.replacingOccurrences(of: ",\"workflowDirectory\":null", with: ""),
                    valid.replacingOccurrences(of: "\"reason\":\" ok \"", with: "\"reason\":\"  \""),
                    valid.replacingOccurrences(of: "\"reason\":\" ok \"", with: "\"reason\":\"\(String(repeating: "x", count: 513))\""),
                    valid.replacingOccurrences(of: "null", with: "\"relative\""),
                    valid.replacingOccurrences(of: "{", with: "{\"extra\":1,")] {
      XCTAssertThrowsError(try RielaAppInstanceReloadRequest.decodeStrict(Data(invalid.utf8))) {
        XCTAssertEqual(($0 as? RielaAppInstanceReloadError)?.code, .invalidReloadRequest)
      }
    }
  }

  func testFingerprints() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/instance-control/instance-control-01-contracts/test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a")
    let b = root.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    for (dir, names) in [(a, ["x", "y"]), (b, ["y", "x"])] {
      for name in names { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }
    }
    let digest = try RielaAppInstanceReloadFingerprint.eventRootDigest(eventRoot: a.path)
    XCTAssertEqual(digest, try RielaAppInstanceReloadFingerprint.eventRootDigest(eventRoot: b.path))
    try FileManager.default.createSymbolicLink(atPath: b.appendingPathComponent("link").path, withDestinationPath: "x")
    XCTAssertEqual(digest, try RielaAppInstanceReloadFingerprint.eventRootDigest(eventRoot: b.path))
    try Data("z".utf8).write(to: b.appendingPathComponent("x"))
    XCTAssertNotEqual(digest, try RielaAppInstanceReloadFingerprint.eventRootDigest(eventRoot: b.path))
    XCTAssertEqual(try RielaAppInstanceReloadFingerprint.eventRootDigest(eventRoot: nil),
                   try RielaAppInstanceReloadFingerprint.eventRootDigest(eventRoot: root.appendingPathComponent("missing").path))
    let settings = EventOverlapSettings(overlapPolicy: "queue")
    XCTAssertNotEqual(RielaAppInstanceReloadFingerprint.triggerDefaultsFingerprint(nil), RielaAppInstanceReloadFingerprint.triggerDefaultsFingerprint(settings))
    XCTAssertEqual(RielaAppInstanceReloadFingerprint.triggerDefaultsFingerprint(settings), RielaAppInstanceReloadFingerprint.triggerDefaultsFingerprint(settings))
    let record = RielaAppInstanceStartRecord(workflowDirectory: "/a", eventRoot: nil, eventRootDigest: "a", triggerDefaultsFingerprint: "a")
    XCTAssertFalse(RielaAppInstanceReloadFingerprint.respawnRequired(childRunning: false, installed: nil, proposed: record))
    XCTAssertTrue(RielaAppInstanceReloadFingerprint.respawnRequired(childRunning: true, installed: nil, proposed: record))
    XCTAssertFalse(RielaAppInstanceReloadFingerprint.respawnRequired(childRunning: true, installed: record, proposed: record))
    var changed = record
    changed.eventRootDigest = "b"
    XCTAssertTrue(RielaAppInstanceReloadFingerprint.respawnRequired(childRunning: true, installed: record, proposed: changed))
    changed = record
    changed.triggerDefaultsFingerprint = "b"
    XCTAssertTrue(RielaAppInstanceReloadFingerprint.respawnRequired(childRunning: true, installed: record, proposed: changed))
  }

  func testStatuses() {
    let expected = [400, 404, 409, 422, 422, 422, 422, 409, 409, 409, 500, 500, 422, 422, 409]
    XCTAssertEqual(RielaAppInstanceReloadCode.allCases.map(\.httpStatus), expected)
  }
}
