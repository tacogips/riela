import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import XCTest
@testable import RielaCore

final class WorkflowFanoutObservationBoundTests: XCTestCase {
  func testThreeBranchJoinAggregatesAndBoundsInlineObservations() async throws {
    let root = try scratch()
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    for branch in ["a", "b", "c"] {
      let directory = "dir-\(branch)"
      try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
      try Data("seed".utf8).write(to: root.appendingPathComponent("\(directory)/seed"))
      _ = try await evidence.capture(branchId: branch, paths: [directory], stepId: "fanout-dispatch")
      _ = try await evidence.capture(branchId: branch, paths: [directory], stepId: "after:n1")
      _ = try await evidence.capture(branchId: branch, paths: [directory], stepId: "after:n2")
      for index in 0..<400 {
        try Data("value-\(index)".utf8).write(to: root.appendingPathComponent("\(directory)/file-\(index)"))
      }
    }

    let reduced = try await evidence.reduce()
    XCTAssertEqual(reduced["observationCount"], .integer(1_203))
    XCTAssertEqual(reduced["observationOccurrenceCount"], .integer(3_609))
    XCTAssertEqual(reduced["inlineObservationCount"], .integer(200))
    XCTAssertEqual(reduced["observationsTruncated"], .bool(true))
    XCTAssertEqual(reduced["hasDrift"], .bool(true))
    XCTAssertEqual(reduced["complete"], .bool(true))
    XCTAssertEqual(fanoutJSONPointer(.object(reduced), "/limits/observationInline"), .integer(200))
    XCTAssertEqual(fanoutJSONPointer(.object(reduced), "/observationCountsByBranch/a/total"), .integer(401))
    XCTAssertEqual(fanoutJSONPointer(.object(reduced), "/observationCountsByBranch/a/inline"), .integer(200))
    XCTAssertEqual(fanoutJSONPointer(.object(reduced), "/observationCountsByBranch/b/total"), .integer(401))
    XCTAssertEqual(fanoutJSONPointer(.object(reduced), "/observationCountsByBranch/c/total"), .integer(401))
    guard case let .array(inline)? = reduced["observations"] else { return XCTFail("missing inline observations") }
    let joinBytes = try JSONValue.object(reduced).compactJSONString().utf8.count
    XCTAssertLessThan(joinBytes, 262_144)
    guard case let .string(target)? = reduced["observationsPath"] else { return XCTFail("missing observationsPath") }
    let full = try readJSON(URL(fileURLWithPath: target))
    guard case let .array(all)? = full["observations"] else { return XCTFail("missing full observations") }
    XCTAssertEqual(all.count, 1_203)
    XCTAssertTrue(all.allSatisfy { value in
      guard case let .object(item) = value else { return false }
      return item["occurrenceDetails"] != nil
    })
    guard let sample: JSONValue = all.first(where: { fanoutJSONPointer($0, "/path") == .string("dir-a/file-0") }) else {
      return XCTFail("missing aggregated sample")
    }
    XCTAssertEqual(fanoutJSONPointer(sample, "/occurrences"), .integer(3))
    XCTAssertEqual(fanoutJSONPointer(sample, "/firstStepId"), .string("fanout-dispatch"))
    XCTAssertEqual(fanoutJSONPointer(sample, "/lastStepId"), .string("after:n2"))
    XCTAssertEqual(fanoutJSONPointer(sample, "/occurrenceDetails/2/stepId"), .string("after:n2"))
    XCTAssertEqual(inline.count, 200)
  }

  func testZeroLimitKeepsDriftAndNoDriftStillPersistsEmptyList() async throws {
    let root = try scratch()
    try Data("before".utf8).write(to: root.appendingPathComponent("file"))
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await evidence.capture(branchId: "a", paths: ["file"], stepId: "before")
    try Data("after".utf8).write(to: root.appendingPathComponent("file"))
    let drift = try await evidence.reduce(observationInlineLimit: 0)
    XCTAssertEqual(drift["observations"], .array([]))
    XCTAssertEqual(drift["inlineObservationCount"], .integer(0))
    XCTAssertEqual(drift["hasDrift"], .bool(true))

    let stableRoot = try scratch()
    try Data("stable".utf8).write(to: stableRoot.appendingPathComponent("file"))
    let stable = try WorkflowFanoutChangeEvidence(root: stableRoot)
    _ = try await stable.capture(branchId: "a", paths: ["file"], stepId: "before")
    let noDrift = try await stable.reduce()
    XCTAssertEqual(noDrift["observationCount"], .integer(0))
    XCTAssertEqual(noDrift["hasDrift"], .bool(false))
    guard case let .string(path)? = noDrift["observationsPath"] else { return XCTFail("missing observationsPath") }
    XCTAssertEqual(try readJSON(URL(fileURLWithPath: path))["observations"], .array([]))
  }

  func testPersistenceFailureKeepsInlineObservationsAndMarksIncomplete() async throws {
    let root = try scratch()
    try Data("before".utf8).write(to: root.appendingPathComponent("file"))
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await evidence.capture(branchId: "a", paths: ["file"], stepId: "before")
    try Data("after".utf8).write(to: root.appendingPathComponent("file"))
    let directory = await evidence.directory
    XCTAssertEqual(chmod(directory.path, mode_t(0o500)), 0)
    defer { _ = chmod(directory.path, mode_t(0o700)) }

    let reduced = try await evidence.reduce()
    XCTAssertEqual(reduced["complete"], .bool(false))
    XCTAssertEqual(reduced["observationsPath"], .null)
    XCTAssertEqual(reduced["inlineObservationCount"], .integer(1))
    guard case let .array(failures)? = reduced["reduceFailures"], case let .object(failure)? = failures.last else {
      return XCTFail("missing persistence failure")
    }
    XCTAssertEqual(failure["path"], .string("observations.json"))
    XCTAssertEqual(failure["phase"], .string("reduce"))
  }

  func testRepeatedReduceIsDeterministicAndReplacesArtifact() async throws {
    let root = try scratch()
    try Data("before".utf8).write(to: root.appendingPathComponent("file"))
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    _ = try await evidence.capture(branchId: "a", paths: ["file"], stepId: "before")
    try Data("after".utf8).write(to: root.appendingPathComponent("file"))
    let first = try await evidence.reduce()
    guard case let .string(path)? = first["observationsPath"] else { return XCTFail("missing observationsPath") }
    let firstBytes = try Data(contentsOf: URL(fileURLWithPath: path))
    let second = try await evidence.reduce()
    XCTAssertEqual(first["observations"], second["observations"])
    XCTAssertEqual(second["observationsPath"], .string(path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), firstBytes)
  }

  private func readJSON(_ url: URL) throws -> JSONObject {
    try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url))
  }

  private func scratch() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/fanout-observation-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
}
