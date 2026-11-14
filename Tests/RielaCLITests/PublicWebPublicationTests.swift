import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class PublicWebPublicationTests: XCTestCase {
  private let url = "https://example.com/news/1"
  private func node(_ changes: JSONObject = [:]) -> JSONObject {
    var result: JSONObject = ["@type": .string("BlogPosting"), "mainEntityOfPage": .object(["@type": .string("WebPage"), "@id": .string(url)]),
      "datePublished": .string("2026-10-25T10:00:00.004Z")]
    for (key, value) in changes { result[key] = value }; return result
  }
  private func script(_ value: JSONValue) throws -> String {
    "<script type='application/ld+json'>" + (try value.compactJSONString()) + "</script>"
  }
  private func date(_ html: String) throws -> WebCollectionTimestamp? {
    try PublicWebPublication.date(Data(html.utf8), url: url, type: "BlogPosting")
  }

  func testExactBoundTypeURLAndAwarePublishedDateIncludingGraphsAndOffsets() throws {
    let html = try script(.object(["@graph": .array([.object(node())])]))
    XCTAssertEqual(try date(html)?.wire, "2026-10-25T10:00:00.004000+00:00")
    let equivalent = try script(.array([.object(node()), .object(node(["datePublished": .string("2026-10-25T19:00:00.004+09:00")]))]))
    XCTAssertNotNil(try date(equivalent))
    XCTAssertEqual(try date(script(.object(node(["datePublished": .string("2026-10-25T19:30+09:00")]))))?.wire, "2026-10-25T19:30:00+09:00")
    let original = try script(.object(node()))
    XCTAssertNotNil(try date(original + original))
  }

  func testOtherTypesURLsNaiveDatesAndModificationDatesNeverSupplyPublicationDate() throws {
    for changes: JSONObject in [["@type": .string("Article")], ["mainEntityOfPage": .object(["@type": .string("WebPage"), "@id": .string(url + "-other")])],
      ["datePublished": .null, "dateModified": .string("2026-10-25T10:00:00Z")], ["datePublished": .string("2026-10-25")],
      ["datePublished": .string("2026-10-25T10:00:00")], ["datePublished": .string("Sun, 25 Oct 2026 10:00:00 +0000")]] {
      XCTAssertNil(try date(script(.object(node(changes)))))
    }
    XCTAssertNil(try date("<meta name='date' content='2026-10-25T10:00:00Z'><script type='application/ld+json'>{bad}</script>"))
  }

  func testConflictingOrInvalidBoundDatesFailClosedEvenWithValidSibling() throws {
    let first = try script(.object(node()))
    XCTAssertNil(try date(first + script(.object(node(["datePublished": .string("2026-10-24T10:00:00Z")])))))
    XCTAssertNil(try date(first + script(.object(node(["datePublished": .null])))))
    XCTAssertNotNil(try date(first + script(.object(node(["mainEntityOfPage": .object(["@id": .string(url + "-other")])])))))
  }

  func testBoundedScriptCountAndSizeDoNotParseUnboundedDocuments() throws {
    let invalid = "<script type='application/ld+json'>" + String(repeating: " ", count: 200_001) + "</script>"
    XCTAssertNil(try date(invalid))
    let unrelated = try script(.object(["x": .integer(1)]))
    XCTAssertNil(try date(String(repeating: unrelated, count: 10) + script(.object(node()))))
  }
}
