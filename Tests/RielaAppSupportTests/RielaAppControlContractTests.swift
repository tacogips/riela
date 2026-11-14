import Foundation
import XCTest
import RielaCore
import RielaServer
@testable import RielaAppSupport

final class RielaAppControlContractTests: XCTestCase {
  private let id = "12345678-1234-1234-1234-123456789abc"
  private let body = Data("{\"a\":1,\"b\":2}".utf8)

  func testOperationRoundTrips() throws {
    let operations: [RielaAppControlOperation] = [
      .bootstrap, .reload(identity: "i", body: body), .run(identity: "i", body: body),
      .cancel(identity: "i", sessionId: nil, body: body), .environmentStatus(identity: "i"),
      .environmentReload(identity: "i", body: body), .launchStatus(launchId: "l")
    ]
    for operation in operations {
      let envelope = RielaAppControlRequestEnvelope(requestId: id, operation: operation, profile: "p")
      let decoded = try RielaAppControlRequestEnvelope.decodeStrict(envelope.encoded())
      XCTAssertEqual(decoded, envelope)
      XCTAssertEqual(decoded.operation.wireName, operation.wireName)
    }
  }

  func testStrictRequestValidation() throws {
    let base = try RielaAppControlRequestEnvelope(requestId: id, operation: .bootstrap, profile: "p").encoded()
    guard case let .object(original) = try JSONDecoder().decode(JSONValue.self, from: base) else { return XCTFail("Expected an object") }
    var cases: [JSONObject] = []
    var value = original; value["extra"] = .null; cases.append(value)
    value = original; value.removeValue(forKey: "body"); cases.append(value)
    for (key, invalid) in [("version", JSONValue.integer(2)), ("requestId", .string(id.uppercased())),
                           ("requestId", .string("invalid")), ("profile", .string("")),
                           ("profile", .string(String(repeating: "x", count: 129))),
                           ("identity", .string("i"))] {
      value = original; value[key] = invalid; cases.append(value)
    }
    value = original; value["operation"] = .string("instance.run"); value["identity"] = .string("i")
    value["sessionId"] = .string("s"); value["body"] = .object([:]); cases.append(value)
    for invalid in cases {
      XCTAssertThrowsError(try RielaAppControlRequestEnvelope.decodeStrict(JSONEncoder().encode(invalid))) { error in
        XCTAssertEqual(error as? RielaAppControlEnvelopeError, .invalidRequest)
      }
    }
  }

  func testDigestIgnoresRequestIdAndObjectOrder() throws {
    let first = RielaAppControlRequestEnvelope(requestId: id, operation: .run(identity: "i", body: body), profile: "p")
    let reordered = RielaAppControlRequestEnvelope(requestId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      operation: .run(identity: "i", body: Data("{\"b\":2,\"a\":1}".utf8)), profile: "p")
    let changed = RielaAppControlRequestEnvelope(requestId: id,
      operation: .run(identity: "i", body: Data("{\"a\":2}".utf8)), profile: "p")
    XCTAssertEqual(try first.digest(), try reordered.digest())
    XCTAssertNotEqual(try first.digest(), try changed.digest())
  }

  func testResultAndResponse() throws {
    let result = RielaAppControlResult.error(status: 400, code: "invalid_configured_run")
    XCTAssertEqual(result.body, .object(["error": .object(["code": .string("invalid_configured_run")])]))
    XCTAssertEqual(RielaAppControlResult(httpResponse: result.httpResponse), result)
    let response = RielaAppControlResponseEnvelope(requestId: id, status: 400, body: result.body)
    let data = try JSONEncoder().encode(response)
    XCTAssertEqual(try RielaAppControlResponseEnvelope.decodeStrict(data), response)
    guard case var .object(values) = try JSONDecoder().decode(JSONValue.self, from: data) else { return XCTFail("Expected an object") }
    values["extra"] = .null
    XCTAssertThrowsError(try RielaAppControlResponseEnvelope.decodeStrict(JSONEncoder().encode(values)))
  }
}
