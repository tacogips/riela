import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class LoopConcurrencyPreflightTests: XCTestCase {
  func testWorkflowWithoutConcurrencyProceedsWithoutLease() throws {
    let (root, cleanup) = try temporaryRoot()
    defer { cleanup() }
    let outcome = try loopConcurrencyPreflight(
      workflow: Self.workflow(concurrency: nil),
      sessionStoreRoot: root,
      output: .json
    )
    guard case let .proceed(leaseHolder, diagnostics) = outcome else {
      return XCTFail("expected proceed")
    }
    XCTAssertNil(leaseHolder)
    XCTAssertTrue(diagnostics.isEmpty)
  }

  func testBusyFailRefusesWithTypedRecordAndNonZeroExit() throws {
    let (root, cleanup) = try temporaryRoot()
    defer { cleanup() }
    let workflow = Self.workflow(concurrency: LoopConcurrencyDeclaration(onBusy: "fail"))

    guard case let .proceed(firstHolder, _) = try loopConcurrencyPreflight(
      workflow: workflow, sessionStoreRoot: root, output: .json
    ) else {
      return XCTFail("first acquire must proceed")
    }
    XCTAssertNotNil(firstHolder)

    guard case let .busyFail(result) = try loopConcurrencyPreflight(
      workflow: workflow, sessionStoreRoot: root, output: .json
    ) else {
      return XCTFail("second acquire must be busy")
    }
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stdout.contains("\"type\":\"loop_concurrency_busy\""))
    XCTAssertTrue(result.stdout.contains(firstHolder ?? ""), "busy record names the holder")
  }

  func testBusySkipExitsZeroWithSkipRecord() throws {
    let (root, cleanup) = try temporaryRoot()
    defer { cleanup() }
    let workflow = Self.workflow(concurrency: LoopConcurrencyDeclaration(onBusy: "skip"))

    _ = try loopConcurrencyPreflight(workflow: workflow, sessionStoreRoot: root, output: .json)
    guard case let .busySkip(result) = try loopConcurrencyPreflight(
      workflow: workflow, sessionStoreRoot: root, output: .json
    ) else {
      return XCTFail("expected busy skip")
    }
    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stdout.contains("\"type\":\"loop_concurrency_skipped\""))
  }

  func testReleasePendingLeaseAllowsNextAcquire() throws {
    let (root, cleanup) = try temporaryRoot()
    defer { cleanup() }
    let workflow = Self.workflow(concurrency: LoopConcurrencyDeclaration(onBusy: "fail"))

    guard case let .proceed(holder, _) = try loopConcurrencyPreflight(
      workflow: workflow, sessionStoreRoot: root, output: .json
    ) else {
      return XCTFail("first acquire must proceed")
    }
    releasePendingLoopConcurrencyLease(workflow: workflow, sessionStoreRoot: root, leaseHolder: holder)
    guard case .proceed = try loopConcurrencyPreflight(
      workflow: workflow, sessionStoreRoot: root, output: .json
    ) else {
      return XCTFail("release must free the lease")
    }
  }

  // MARK: - Fixtures

  private func temporaryRoot() throws -> (String, () -> Void) {
    let root = NSTemporaryDirectory() + "loop-preflight-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return (root, { try? FileManager.default.removeItem(atPath: root) })
  }

  private static func workflow(concurrency: LoopConcurrencyDeclaration?) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "concurrency-demo",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "review",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "review-node", nodeFile: "nodes/review.json")],
      steps: [WorkflowStepRef(id: "review", nodeId: "review-node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "review-node", nodeFile: "nodes/review.json")],
      loop: WorkflowLoopMetadata(concurrency: concurrency, gates: [])
    )
  }
}
