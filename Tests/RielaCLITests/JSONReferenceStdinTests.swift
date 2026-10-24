import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class JSONReferenceStdinTests: XCTestCase {
  func testExplicitStdinReferenceReadsTypedJSONWithoutInterpolation() throws {
    let loader = JSONReferenceLoader(standardInput: { Data(#"{"cursor":"{{literal}}","count":2,"ids":["one"]}"#.utf8) })
    XCTAssertEqual(try loader.object(from: "@-"), ["cursor": .string("{{literal}}"), "count": .integer(2), "ids": .array([.string("one")])])
  }

  func testOversizedAndNonUTF8InputAreRejected() {
    for data in [Data(repeating: 32, count: 64 * 1024 * 1024 + 1), Data([0xff])] {
      XCTAssertThrowsError(try JSONReferenceLoader(standardInput: { data }).object(from: "@-"))
    }
  }

  func testInlineReferenceNeverReadsStdin() throws {
    let loader = JSONReferenceLoader(standardInput: { throw WorkflowResolutionError.invalidJSONReference("must not read stdin") })
    XCTAssertEqual(try loader.object(from: #"{"ok":true}"#), ["ok": .bool(true)])
  }
}
