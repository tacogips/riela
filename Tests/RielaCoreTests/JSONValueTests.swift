import XCTest
@testable import RielaCore

final class JSONValueTests: XCTestCase {
  func testDecodesAndReencodesLargeIntegersLosslessly() throws {
    let data = Data(#"{"id":9223372036854775807,"fraction":1.25}"#.utf8)

    let value = try JSONDecoder().decode(JSONValue.self, from: data)

    guard case let .object(object) = value else {
      return XCTFail("Expected object")
    }
    XCTAssertEqual(object["id"], .integer(9_223_372_036_854_775_807))
    XCTAssertEqual(object["fraction"], .number(1.25))
    XCTAssertEqual(object["id"]?.asInt64, 9_223_372_036_854_775_807)
    XCTAssertEqual(object["id"]?.asDouble, Double(9_223_372_036_854_775_807))

    let encoded = try JSONEncoder().encode(value)
    let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
    XCTAssertTrue(encodedText.contains("9223372036854775807"), encodedText)
  }

  func testIntegerAndNumberEqualityOnlyInteroperatesWhenExactlyRepresentable() {
    XCTAssertEqual(JSONValue.integer(42), JSONValue.number(42))
    XCTAssertEqual(JSONValue.integer(-42), JSONValue.number(-42))
    XCTAssertNotEqual(JSONValue.integer(9_007_199_254_740_993), JSONValue.number(9_007_199_254_740_992))
    XCTAssertNotEqual(JSONValue.integer(42), JSONValue.number(42.25))
  }
}
