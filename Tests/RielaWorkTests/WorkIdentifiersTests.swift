import Foundation
import XCTest
@testable import RielaWork

final class WorkIdentifiersTests: XCTestCase {
  func testGeneratedIdentifiersCarryTheirPrefixAndALowercaseUUID() {
    let cases: [(String, String)] = [
      (IntentID.generate().rawValue, "intent-"),
      (TaskID.generate().rawValue, "task-"),
      (AttemptID.generate().rawValue, "attempt-"),
      (DecisionID.generate().rawValue, "decision-"),
      (EvidenceID.generate().rawValue, "evidence-")
    ]
    for (value, prefix) in cases {
      XCTAssertTrue(value.hasPrefix(prefix), "'\(value)' must start with '\(prefix)'")
      let suffix = String(value.dropFirst(prefix.count))
      XCTAssertEqual(suffix, suffix.lowercased(), "the UUID part of '\(value)' must be lowercase")
      XCTAssertNotNil(UUID(uuidString: suffix), "'\(suffix)' must be a UUID")
    }
  }

  func testGeneratedIdentifiersAreDistinct() {
    XCTAssertNotEqual(TaskID.generate(), TaskID.generate())
  }

  func testIdentifiersRoundTripAsPlainJSONStrings() throws {
    let id = TaskID("task-0f0d0d48-2b3e-4c1d-9f0a-5a9a3b1e7c22")
    let data = try JSONEncoder().encode(id)
    XCTAssertEqual(String(bytes: data, encoding: .utf8), "\"task-0f0d0d48-2b3e-4c1d-9f0a-5a9a3b1e7c22\"")
    XCTAssertEqual(try JSONDecoder().decode(TaskID.self, from: data), id)
  }

  func testIdentifierKindsAreDistinctTypesWithTheSameRawValue() {
    XCTAssertEqual(TaskID("x").rawValue, EvidenceID("x").rawValue)
    XCTAssertEqual(TaskID("x").description, "x")
  }

  /// Design section 16: `RielaWork` depends on `RielaCore`, never the reverse.
  /// A reverse import would make the core test target rebuild on every task
  /// store schema bump, so the rule is proven by reading the sources.
  func testRielaCoreNeverImportsRielaWork() throws {
    let coreSources = repositoryRoot()
      .appendingPathComponent("Sources/RielaCore", isDirectory: true)
    var offenders: [String] = []
    let enumerator = FileManager.default.enumerator(atPath: coreSources.path)
    while let relative = enumerator?.nextObject() as? String {
      guard relative.hasSuffix(".swift") else { continue }
      let contents = try String(contentsOf: coreSources.appendingPathComponent(relative), encoding: .utf8)
      if contents.contains("import RielaWork") {
        offenders.append(relative)
      }
    }
    XCTAssertEqual(offenders.sorted(), [], "RielaCore must not import RielaWork")
  }

  private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}
