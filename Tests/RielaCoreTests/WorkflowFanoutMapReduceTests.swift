import Foundation
import XCTest
@testable import RielaCore

final class WorkflowFanoutMapReduceTests: XCTestCase {
  func testDependencyWavesPreserveInputIndicesAndRequireAcceptedDependencies() throws {
    let items: [JSONValue] = [item("c", ["a", "b"]), item("a"), item("b")]
    let policy = WorkflowFanoutDependencies(branchIdFrom: "/id", dependsOnFrom: "/dependsOn", completedBranchIdsFrom: "/accepted")
    let first = try WorkflowFanoutWave.select(items: items, policy: policy, source: ["accepted": .array([])])
    XCTAssertEqual(first.selectedIndices, [1, 2])
    let next = try WorkflowFanoutWave.select(items: items, policy: policy, source: ["accepted": .array([.string("a"), .string("b")])])
    XCTAssertEqual(next.selectedIndices, [0])
    XCTAssertEqual(next.pendingBranchIds, ["c"])
    XCTAssertThrowsError(try WorkflowFanoutWave.select(items: items, policy: policy, source: ["accepted": .array([.string("c")])]))
    XCTAssertThrowsError(try WorkflowFanoutWave.select(items: [item("a", ["b"]), item("b", ["a"])], policy: policy, source: ["accepted": .array([])]))
    XCTAssertThrowsError(try WorkflowFanoutWave.select(items: [item("a"), item("a")], policy: policy, source: ["accepted": .array([])]))
    XCTAssertThrowsError(try WorkflowFanoutWave.select(items: [item("a", ["missing"])], policy: policy, source: ["accepted": .array([])]))
  }

  func testChangeEvidencePreservesOverwrittenBytesAndReportsDrift() async throws {
    let root = try scratch()
    let path = root.appendingPathComponent("shared.txt")
    try Data("feature A".utf8).write(to: path)
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    let saved = try await evidence.capture(branchId: "a", paths: ["shared.txt", "new.txt"], stepId: "after:implement")
    try Data("feature B".utf8).write(to: path)
    try Data("new file".utf8).write(to: root.appendingPathComponent("new.txt"))
    let reduced = try await evidence.reduce()
    XCTAssertEqual(reduced["hasDrift"], .bool(true))
    XCTAssertEqual(reduced["requiresSemanticReview"], .bool(true))
    let stored = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: URL(fileURLWithPath: saved)))
    XCTAssertEqual(fanoutJSONPointer(.object(stored), "/files/shared.txt/contentBase64"), .string(Data("feature A".utf8).base64EncodedString()))
    let another = try await evidence.capture(branchId: "a", paths: ["shared.txt"], stepId: "after:repair")
    XCTAssertNotEqual(saved, another)
    XCTAssertEqual(try Data(contentsOf: path), Data("feature B".utf8))
  }

  func testTrackingRejectsTraversalAndSymlinksWithoutWritingSource() async throws {
    let root = try scratch()
    let evidence = try WorkflowFanoutChangeEvidence(root: root)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
    for path in ["../outside", ".git/config", "escape/file"] {
      do {
        _ = try await evidence.capture(branchId: "a", paths: [path], stepId: "before")
        XCTFail("accepted unsafe path: \(path)")
      } catch { XCTAssertTrue(error is AdapterExecutionError) }
    }
  }

  private func item(_ id: String, _ dependencies: [String] = []) -> JSONValue {
    .object(["id": .string(id), "dependsOn": .array(dependencies.map(JSONValue.string))])
  }

  private func scratch() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/fanout-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
}
