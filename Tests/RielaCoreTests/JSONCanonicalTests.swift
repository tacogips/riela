import Foundation
import XCTest
@testable import RielaCore

final class JSONCanonicalTests: XCTestCase {
  func testObjectOrderingAndNumbersAreStable() throws {
    let first: JSONObject = ["z": .integer(1), "a": .string("x\n"), "nested": .object(["b": .bool(true), "a": .null])]
    let second: JSONObject = ["nested": .object(["a": .null, "b": .bool(true)]), "a": .string("x\n"), "z": .integer(1)]
    XCTAssertEqual(try JSONCanonical.encode(first), try JSONCanonical.encode(second))
    for value in [0.1, 1e21, -0.5] {
      let bytes = try JSONCanonical.encode(JSONValue.number(value))
      XCTAssertEqual(try JSONCanonical.encode(JSONDecoder().decode(JSONValue.self, from: bytes)), bytes)
    }
  }

  func testDatePrecisionRoundsAndRoundTripsAndNaNFails() throws {
    let value = Date(timeIntervalSince1970: 1.2346)
    let encoded = try JSONCanonical.encode(value)
    let decoded = try JSONCanonical.decoder().decode(Date.self, from: encoded)
    XCTAssertEqual(try JSONCanonical.encode(decoded), encoded)
    XCTAssertEqual(decoded.timeIntervalSince1970, 1.235, accuracy: 0.000_001)
    XCTAssertThrowsError(try JSONCanonical.decoder().decode(Date.self, from: Data(#""2024-01-01T00:00:00Z""#.utf8)))
    XCTAssertThrowsError(try JSONCanonical.encode(JSONValue.number(.nan)))
    XCTAssertEqual(JSONCanonical.sha256Hex(Data("abc".utf8)),
                   "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }
}
