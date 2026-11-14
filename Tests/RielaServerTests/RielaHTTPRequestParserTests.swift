import Foundation
@testable import RielaServer
import XCTest

final class RielaHTTPRequestParserTests: XCTestCase {
  func testParsesFragmentedJSONRequestOnlyWhenComplete() throws {
    let header = Data("POST /graphql?operation=test HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\n\r\n".utf8)
    XCTAssertEqual(try RielaHTTPRequestParser().parse(header), .incomplete)
    let result = try RielaHTTPRequestParser().parse(header + Data("{}".utf8))
    guard case let .complete(request) = result else {
      return XCTFail("expected a complete request")
    }
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/graphql")
    XCTAssertEqual(request.query, "operation=test")
    XCTAssertEqual(request.headers["host"], "127.0.0.1")
    XCTAssertEqual(request.body, Data("{}".utf8))
  }

  func testRejectsTraversalMalformedPercentEncodingAndTransferEncoding() {
    let requests = [
      "GET /%2e%2e/secret HTTP/1.1\r\n\r\n",
      "GET /bad%2 HTTP/1.1\r\n\r\n",
      "POST /graphql HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
    ]
    for request in requests {
      XCTAssertThrowsError(try RielaHTTPRequestParser().parse(Data(request.utf8)))
    }
  }

  func testRejectsBodyOverLimitBeforeReadingBody() {
    let request = "POST /graphql HTTP/1.1\r\nContent-Length: \(RielaHTTPRequestParser.maximumBodyBytes + 1)\r\n\r\n"
    XCTAssertThrowsError(try RielaHTTPRequestParser().parse(Data(request.utf8))) { error in
      XCTAssertEqual(error as? RielaHTTPRequestParserError, .bodyTooLarge)
    }
  }
}
