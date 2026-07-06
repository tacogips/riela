import Foundation
import XCTest
@testable import RielaAdapters

final class ServerSentEventsParserTests: XCTestCase {
  func testDispatchesMultilineDataOnBlankLine() throws {
    let parser = ServerSentEventsParser()

    let events = try parser.feed(data("data: first\ndata: second\n\n"))

    XCTAssertEqual(events, [ServerSentEvent(data: "first\nsecond")])
    XCTAssertEqual(try parser.finish(), [])
  }

  func testAcceptsMixedLineEndings() throws {
    let parser = ServerSentEventsParser()

    let events = try parser.feed(data("data: one\r\ndata: two\r\rdata: three\n\n"))

    XCTAssertEqual(events, [
      ServerSentEvent(data: "one\ntwo"),
      ServerSentEvent(data: "three")
    ])
  }

  func testBuffersIncompleteLineAcrossChunks() throws {
    let parser = ServerSentEventsParser()

    XCTAssertEqual(try parser.feed(data("data: hel")), [])
    XCTAssertEqual(try parser.feed(data("lo\n\n")), [ServerSentEvent(data: "hello")])
  }

  func testBuffersSplitUTF8ScalarAcrossChunks() throws {
    let parser = ServerSentEventsParser()
    let payload = Data("data: あ\n\n".utf8)

    XCTAssertEqual(try parser.feed(payload.prefix(7)), [])
    XCTAssertEqual(try parser.feed(payload.dropFirst(7)), [ServerSentEvent(data: "あ")])
  }

  func testStripsBomOnlyAtStreamStart() throws {
    let parser = ServerSentEventsParser()

    let events = try parser.feed(data("\u{FEFF}data: first\n\n")) + (try parser.feed(data("data: \u{FEFF}second\n\n")))

    XCTAssertEqual(events, [
      ServerSentEvent(data: "first"),
      ServerSentEvent(data: "\u{FEFF}second")
    ])
  }

  func testIgnoresCommentLines() throws {
    let parser = ServerSentEventsParser()

    let events = try parser.feed(data(": keepalive\ndata: payload\n\n"))

    XCTAssertEqual(events, [ServerSentEvent(data: "payload")])
  }

  func testFieldWithoutColonHasEmptyValue() throws {
    let parser = ServerSentEventsParser()

    let events = try parser.feed(data("event\ndata: value\n\n"))

    XCTAssertEqual(events, [ServerSentEvent(event: "", data: "value")])
  }

  func testStripsOneLeadingSpaceAfterColon() throws {
    let parser = ServerSentEventsParser()

    let events = try parser.feed(data("data:  spaced\n\n"))

    XCTAssertEqual(events, [ServerSentEvent(data: " spaced")])
  }

  func testParsesEventNameAndPersistentIdentifier() throws {
    let parser = ServerSentEventsParser()

    let events = try parser.feed(data("id: 42\nevent: delta\ndata: first\n\ndata: second\n\n"))

    XCTAssertEqual(events, [
      ServerSentEvent(id: "42", event: "delta", data: "first"),
      ServerSentEvent(id: "42", data: "second")
    ])
  }

  func testIgnoresIdentifierContainingNull() throws {
    let parser = ServerSentEventsParser()

    let events = try parser.feed(data("id: ok\ndata: first\n\nid: bad\u{0}id\ndata: second\n\n"))

    XCTAssertEqual(events, [
      ServerSentEvent(id: "ok", data: "first"),
      ServerSentEvent(id: "ok", data: "second")
    ])
  }

  func testFinishFlushesTrailingEvent() throws {
    let parser = ServerSentEventsParser()

    XCTAssertEqual(try parser.feed(data("data: trailing")), [])
    XCTAssertEqual(try parser.finish(), [ServerSentEvent(data: "trailing")])
  }

  func testEmptyDataEventIsNotDispatched() throws {
    let parser = ServerSentEventsParser()

    let events = try parser.feed(data("event: notice\n\n"))

    XCTAssertEqual(events, [])
    XCTAssertEqual(try parser.finish(), [])
  }

  func testAcceptsCRLFPairSplitAcrossChunks() throws {
    let parser = ServerSentEventsParser()

    XCTAssertEqual(try parser.feed(data("data: one\r")), [])
    XCTAssertEqual(try parser.feed(data("\n\n")), [ServerSentEvent(data: "one")])
  }

  func testInvalidUTF8DoesNotPoisonLaterValidEvents() throws {
    let parser = ServerSentEventsParser()

    XCTAssertEqual(try parser.feed(Data([0xff, 0xfe, 0x0a])), [])
    let events = try parser.feed(data("data: recovered\n\n"))

    XCTAssertEqual(events, [ServerSentEvent(data: "recovered")])
  }

  func testPendingUTF8BufferLimitThrows() {
    let parser = ServerSentEventsParser()

    XCTAssertThrowsError(try parser.feed(Data(repeating: 0xE3, count: 1_048_577))) { error in
      XCTAssertEqual(error as? ServerSentEventsParserError, .pendingBufferLimitExceeded(maxBytes: 1_048_576))
    }
  }

  private func data(_ text: String) -> Data {
    Data(text.utf8)
  }
}
