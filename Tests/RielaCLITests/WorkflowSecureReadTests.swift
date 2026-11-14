import Foundation
import XCTest
@testable import RielaCLI

final class WorkflowSecureReadTests: XCTestCase {
  func testInventoryDescriptorReadRejectsDeterministicLeafSwapRace() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let target = try resolveVersioningTarget(root: root).identity
    let workflowURL = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json")
    let replacement = root.appendingPathComponent("outside-workflow.json")
    try Data("{}".utf8).write(to: replacement)
    XCTAssertThrowsError(try WorkflowHistoryIdentityResolver.inventory(for: target) { relativePath in
      guard relativePath == "workflow.json" else { return }
      try FileManager.default.removeItem(at: workflowURL)
      try FileManager.default.createSymbolicLink(at: workflowURL, withDestinationURL: replacement)
    }) { error in
      XCTAssertTrue(String(describing: error).contains("linked"))
    }
  }

  func testDescriptorRelativeHistoryReadRejectsDeterministicLeafSwapRace() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-history-read-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let record = root.appendingPathComponent("record.json")
    let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).json")
    try Data("original".utf8).write(to: record)
    try Data("replacement".utf8).write(to: outside)
    addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

    XCTAssertThrowsError(try WorkflowDescriptorRelativeReader.read(record, within: root) {
      try FileManager.default.removeItem(at: record)
      try FileManager.default.createSymbolicLink(at: record, withDestinationURL: outside)
    }) { error in
      XCTAssertTrue(String(describing: error).contains("linked"))
    }
  }

  func testProposalGenerationRejectsWorkflowLeafSwapAfterInventory() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let workflow = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json")
    let replacement = root.appendingPathComponent("replacement-workflow.json")
    try Data("{}".utf8).write(to: replacement)
    let versioning = WorkflowSelfImproveVersioning(beforeProposalWorkflowOpen: {
      try FileManager.default.removeItem(at: workflow)
      try FileManager.default.createSymbolicLink(at: workflow, withDestinationURL: replacement)
    })

    XCTAssertThrowsError(try versioning.execute(
      workflowName: "versioned-flow",
      bundle: resolved.bundle,
      workingDirectory: root,
      dryRun: true,
      approved: false,
      changeSetId: nil,
      expectedDigest: nil,
      sourceSessionId: "leaf-swap-session"
    )) { error in
      XCTAssertTrue(String(describing: error).contains("linked"))
    }
  }
}
