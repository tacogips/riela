import Foundation
import XCTest
@testable import RielaMemory

final class EvolutionReverseDeltaTests: XCTestCase {
  func testExactRoundTripsIncludingBinaryAndUnicode() throws {
    let values = [Data(), Data("記憶🧠\n".utf8), Data([0, 255, 128, 10]), Data("same".utf8)]
    for previous in values {
      for next in values {
        let delta = try EvolutionReverseDelta(previous: previous, next: next, nextVersion: 2)
        let decoded = try JSONDecoder().decode(EvolutionReverseDelta.self, from: JSONEncoder().encode(delta))
        XCTAssertEqual(try decoded.reconstructPrevious(from: next, version: 2), previous)
        XCTAssertEqual(decoded.direction.rawValue, "next-to-previous")
        XCTAssertEqual(decoded.toVersion, 1)
      }
    }
  }

  func testReconstructsChainWithSmallStoredChanges() throws {
    let base = String(repeating: "unchanged", count: 10_000)
    let versions = (1...10).map { Data("\(base) version=\($0) \(base)".utf8) }
    let deltas = try (1..<versions.count).map { index in
      try EvolutionReverseDelta(previous: versions[index - 1], next: versions[index], nextVersion: Int64(index + 1))
    }
    XCTAssertLessThan(try deltas.reduce(0) { try $0 + JSONEncoder().encode($1).count }, 10_000)
    var reconstructed = versions[versions.count - 1]
    for delta in deltas.reversed() {
      reconstructed = try delta.reconstructPrevious(from: reconstructed, version: delta.fromVersion)
      XCTAssertEqual(reconstructed, versions[Int(delta.toVersion) - 1])
    }
  }

  func testRejectsWrongBaseVersionAndTamperedPatch() throws {
    let delta = try EvolutionReverseDelta(previous: Data("old".utf8), next: Data("new".utf8), nextVersion: 2)
    XCTAssertThrowsError(try delta.reconstructPrevious(from: Data("old".utf8), version: 2))
    XCTAssertThrowsError(try delta.reconstructPrevious(from: Data("new".utf8), version: 1))
    let mutations: [String: Any] = [
      "schemaVersion": 2, "fromVersion": 0, "toVersion": 8,
      "prefixByteCount": Int.max, "suffixByteCount": -1,
      "toByteCount": Int.max, "fromSHA256": "bad", "toSHA256": "bad",
      "previousMiddle": Data("xxx".utf8).base64EncodedString()
    ]
    for (key, value) in mutations {
      var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(delta)) as? [String: Any])
      object[key] = value
      let decoded = try JSONDecoder().decode(
        EvolutionReverseDelta.self, from: JSONSerialization.data(withJSONObject: object)
      )
      XCTAssertThrowsError(try decoded.reconstructPrevious(from: Data("new".utf8), version: 2), key)
    }
  }

  func testUnknownDirectionFailsDecoding() throws {
    let delta = try EvolutionReverseDelta(previous: Data(), next: Data(), nextVersion: 2)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(delta)) as? [String: Any])
    object["direction"] = "previous-to-next"
    XCTAssertThrowsError(try JSONDecoder().decode(
      EvolutionReverseDelta.self, from: JSONSerialization.data(withJSONObject: object)
    ))
  }
}
