import Foundation
import XCTest
@testable import RielaAdapters

final class ServerSentEventsParserTests: XCTestCase {
  func testDispatchesMultilineDataOnBlankLine() {
    let parser = ServerSentEventsParser()

    let events = parser.feed(data("data: first\ndata: second\n\n"))

    XCTAssertEqual(events, [ServerSentEvent(data: "first\nsecond")])
    XCTAssertEqual(parser.finish(), [])
  }

  func testAcceptsMixedLineEndings() {
    let parser = ServerSentEventsParser()

    let events = parser.feed(data("data: one\r\ndata: two\r\rdata: three\n\n"))

    XCTAssertEqual(events, [
      ServerSentEvent(data: "one\ntwo"),
      ServerSentEvent(data: "three")
    ])
  }

  func testBuffersIncompleteLineAcrossChunks() {
    let parser = ServerSentEventsParser()

    XCTAssertEqual(parser.feed(data("data: hel")), [])
    XCTAssertEqual(parser.feed(data("lo\n\n")), [ServerSentEvent(data: "hello")])
  }

  func testBuffersSplitUTF8ScalarAcrossChunks() {
    let parser = ServerSentEventsParser()
    let payload = Data("data: あ\n\n".utf8)

    XCTAssertEqual(parser.feed(payload.prefix(7)), [])
    XCTAssertEqual(parser.feed(payload.dropFirst(7)), [ServerSentEvent(data: "あ")])
  }

  func testStripsBomOnlyAtStreamStart() {
    let parser = ServerSentEventsParser()

    let events = parser.feed(data("\u{FEFF}data: first\n\n")) + parser.feed(data("data: \u{FEFF}second\n\n"))

    XCTAssertEqual(events, [
      ServerSentEvent(data: "first"),
      ServerSentEvent(data: "\u{FEFF}second")
    ])
  }

  func testIgnoresCommentLines() {
    let parser = ServerSentEventsParser()

    let events = parser.feed(data(": keepalive\ndata: payload\n\n"))

    XCTAssertEqual(events, [ServerSentEvent(data: "payload")])
  }

  func testFieldWithoutColonHasEmptyValue() {
    let parser = ServerSentEventsParser()

    let events = parser.feed(data("event\ndata: value\n\n"))

    XCTAssertEqual(events, [ServerSentEvent(event: "", data: "value")])
  }

  func testStripsOneLeadingSpaceAfterColon() {
    let parser = ServerSentEventsParser()

    let events = parser.feed(data("data:  spaced\n\n"))

    XCTAssertEqual(events, [ServerSentEvent(data: " spaced")])
  }

  func testParsesEventNameAndPersistentIdentifier() {
    let parser = ServerSentEventsParser()

    let events = parser.feed(data("id: 42\nevent: delta\ndata: first\n\ndata: second\n\n"))

    XCTAssertEqual(events, [
      ServerSentEvent(id: "42", event: "delta", data: "first"),
      ServerSentEvent(id: "42", data: "second")
    ])
  }

  func testIgnoresIdentifierContainingNull() {
    let parser = ServerSentEventsParser()

    let events = parser.feed(data("id: ok\ndata: first\n\nid: bad\u{0}id\ndata: second\n\n"))

    XCTAssertEqual(events, [
      ServerSentEvent(id: "ok", data: "first"),
      ServerSentEvent(id: "ok", data: "second")
    ])
  }

  func testFinishFlushesTrailingEvent() {
    let parser = ServerSentEventsParser()

    XCTAssertEqual(parser.feed(data("data: trailing")), [])
    XCTAssertEqual(parser.finish(), [ServerSentEvent(data: "trailing")])
  }

  func testEmptyDataEventIsNotDispatched() {
    let parser = ServerSentEventsParser()

    let events = parser.feed(data("event: notice\n\n"))

    XCTAssertEqual(events, [])
    XCTAssertEqual(parser.finish(), [])
  }

  private func data(_ text: String) -> Data {
    Data(text.utf8)
  }
}
