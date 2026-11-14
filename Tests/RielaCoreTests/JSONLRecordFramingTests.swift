import Foundation
import XCTest
@testable import RielaCore

final class JSONLRecordFramingTests: XCTestCase {
  func testUnicodeSeparatorsInsideStringsAreNotProtocolDelimiters() throws {
    for separator in ["\u{0085}", "\u{2028}", "\u{2029}"] {
      let record = "{\"text\":\"before\(separator)after\"}"
      XCTAssertEqual(JSONLRecordFraming.records(in: record + "\n"), [record])
      let decoded = try JSONDecoder().decode([String: String].self, from: Data(record.utf8))
      XCTAssertEqual(decoded["text"], "before" + separator + "after")
    }
  }

  func testCRLFAndBlankLinesPreserveActualRecordCount() {
    XCTAssertEqual(JSONLRecordFraming.records(in: " \r\n{\"one\":1}\r\n\n{\"two\":2}\r\n"),
      ["{\"one\":1}", "{\"two\":2}"])
  }
}
