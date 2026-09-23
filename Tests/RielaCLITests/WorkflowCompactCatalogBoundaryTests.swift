import Foundation
import XCTest
@testable import RielaWorkflowRegistry

final class WorkflowCompactCatalogBoundaryTests: XCTestCase {
  func testAllOriginsListButUnqualifiedSelectionUsesRegistryPrecedenceAndPaginationIsUnambiguous() throws {
    let root = try taskRoot("catalog-origins")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    try writeWorkflow(root.appendingPathComponent(".riela/workflows/project-choice"), id: "choice", description: "project")
    try writeWorkflow(home.appendingPathComponent(".riela/workflows/user-choice"), id: "choice", description: "user")
    try writeWorkflow(root.appendingPathComponent(".riela/workflows/second"), id: "second", description: "second")

    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let catalog = WorkflowCompactCatalog()
      let cards = try catalog.refresh(workingDirectory: root.path)
      XCTAssertEqual(cards.filter { $0.workflowId == "choice" }.count, 2, "Discovery retains all accessible origins")
      XCTAssertEqual(try catalog.select(workflowId: "choice", workingDirectory: root.path).shortSummary, "project")

      let firstPage = try catalog.list(workingDirectory: root.path, limit: 1)
      let first = try XCTUnwrap(firstPage.first)
      let secondPage = try catalog.list(
        workingDirectory: root.path, limit: 10, cursor: catalog.paginationCursor(for: first)
      )
      XCTAssertFalse(secondPage.contains { $0.originId == first.originId && $0.workflowId == first.workflowId })
      XCTAssertThrowsError(try catalog.list(workingDirectory: root.path, cursor: first.originId))
    }
  }

  func testLegacySummaryBoundsAndSelectedRevisionTamperingFailClosed() throws {
    let root = try taskRoot("catalog-tamper")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = root.appendingPathComponent(".riela/workflows/legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    let initial = "legacy-" + String(repeating: "a", count: 260)
    try definition(id: "legacy", description: initial, tags: Array(repeating: String(repeating: "t", count: 40), count: 10))
      .write(to: workflow.appendingPathComponent("workflow.json"))
    let catalog = WorkflowCompactCatalog()
    let cached = try XCTUnwrap(catalog.refresh(workingDirectory: root.path).first { $0.workflowId == "legacy" })
    XCTAssertEqual(cached.shortSummary.count, 240)
    XCTAssertEqual(cached.tags.count, 8)
    XCTAssertTrue(cached.tags.allSatisfy { $0.count == 32 })
    XCTAssertNil(cached.domain, "Legacy definitions have a deterministic absent-domain fallback")

    // Keep the file length stable, so revalidation proves the content digest
    // rather than size/mtime is the execution pin.
    try definition(id: "legacy", description: "legacy-" + String(repeating: "b", count: 260), tags: Array(repeating: String(repeating: "t", count: 40), count: 10))
      .write(to: workflow.appendingPathComponent("workflow.json"))
    XCTAssertThrowsError(try catalog.select(workflowId: "legacy", workingDirectory: root.path))
  }

  func testClosureDigestDetectsSameSizeAndRestoredMTimeDrift() throws {
    let root = try taskRoot("catalog-digest")
    defer { try? FileManager.default.removeItem(at: root) }
    let asset = root.appendingPathComponent("asset.bin")
    try Data("first".utf8).write(to: asset)
    let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: asset.path)
    let catalog = WorkflowCompactCatalog()
    let original = try catalog.closureRevision(workflowDirectory: root)
    try Data("other".utf8).write(to: asset)
    try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: asset.path)
    XCTAssertNotEqual(try catalog.closureRevision(workflowDirectory: root), original)
  }

  func testHiddenAssetsArePinnedAndHiddenSymlinksAreRejected() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/catalog-hidden/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let asset = root.appendingPathComponent(".runtime-config")
    try Data("first".utf8).write(to: asset)
    let catalog = WorkflowCompactCatalog()
    let first = try catalog.closureRevision(workflowDirectory: root)
    try Data("second".utf8).write(to: asset)
    XCTAssertNotEqual(try catalog.closureRevision(workflowDirectory: root), first)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".hidden-link"), withDestinationURL: asset)
    XCTAssertThrowsError(try catalog.closureRevision(workflowDirectory: root))
  }

  func testCachedDiscoveryDoesNotReadExecutableContents() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/catalog-boundary/\(UUID().uuidString)")
    let workflow = root.appendingPathComponent(".riela/workflows/catalog-boundary")
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let definition = #"{"workflowId":"catalog-boundary","description":"Compact discovery fixture","nodes":[],"steps":[]}"#
    try Data(definition.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    let prompt = workflow.appendingPathComponent("opaque-prompt.txt")
    try Data("Prompt contents must not be read by cached discovery".utf8).write(to: prompt)
    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": root.appendingPathComponent("isolated-home").path]) {
      let catalog = WorkflowCompactCatalog()
      let refreshed = try catalog.refresh(workingDirectory: root.path)
      XCTAssertTrue(refreshed.contains { $0.workflowId == "catalog-boundary" })
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: prompt.path)
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prompt.path) }
      XCTAssertThrowsError(try Data(contentsOf: prompt), "Fixture must deny direct content reads")
      let cards = try catalog.list(workingDirectory: root.path)
      XCTAssertEqual(cards.first { $0.workflowId == "catalog-boundary" }?.shortSummary, "Compact discovery fixture")
    }
  }

  func testSelectionFailsClosedAfterPermissionOrInventoryChangeAndPaginationBoundsAreStable() throws {
    let root = try taskRoot("catalog-access-change")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home")
    try writeWorkflow(root.appendingPathComponent(".riela/workflows/project-collision"), id: "collision", description: "project")
    try writeWorkflow(home.appendingPathComponent(".riela/workflows/user-collision"), id: "collision", description: "user")
    try writeWorkflow(root.appendingPathComponent(".riela/workflows/third"), id: "third", description: "third")

    try CLIRuntimeEnvironment.$overrides.withValue(["HOME": home.path]) {
      let catalog = WorkflowCompactCatalog()
      let cached = try catalog.refresh(workingDirectory: root.path)
      let project = try XCTUnwrap(cached.first { $0.workflowId == "collision" && $0.shortSummary == "project" })
      let user = try XCTUnwrap(cached.first { $0.workflowId == "collision" && $0.shortSummary == "user" })
      XCTAssertNotEqual(project.originId, user.originId, "Same IDs from distinct origins remain explicit cards")
      XCTAssertEqual(try catalog.list(workingDirectory: root.path, limit: 0).count, 1)
      XCTAssertLessThanOrEqual(try catalog.list(workingDirectory: root.path, limit: 9_999).count, 200)
      XCTAssertEqual(try catalog.select(workflowId: "collision", originId: user.originId, workingDirectory: root.path).shortSummary, "user")

      // A cached card never conveys execution authority after the authoritative
      // registry entry becomes unreadable/absent. Removal is deterministic even
      // under privileged test users for whom chmod would remain readable.
      try FileManager.default.removeItem(at: root.appendingPathComponent(".riela/workflows/project-collision/workflow.json"))
      XCTAssertThrowsError(try catalog.select(workflowId: "collision", originId: project.originId, workingDirectory: root.path))
    }
  }

  func testClosureDigestRejectsChangedExecutableModeAndCompleteSnapshotTampering() throws {
    let root = try taskRoot("catalog-complete-tamper")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = root.appendingPathComponent("workflow")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    let script = workflow.appendingPathComponent("scripts/run")
    try Data("echo safe\n".utf8).write(to: script)
    let catalog = WorkflowCompactCatalog()
    let original = try catalog.closureRevision(workflowDirectory: workflow)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    XCTAssertNotEqual(try catalog.closureRevision(workflowDirectory: workflow), original)
    try Data("echo altered\n".utf8).write(to: script)
    XCTAssertNotEqual(try catalog.closureRevision(workflowDirectory: workflow), original)
  }

  func testCachedSelectionRejectsAnActualUnreadableWorkflowOrigin() throws {
    let root = try taskRoot("catalog-permission-change")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent(".riela/workflows/private")
    try writeWorkflow(directory, id: "private", description: "private")
    let catalog = WorkflowCompactCatalog()
    _ = try catalog.refresh(workingDirectory: root.path)
    let definition = directory.appendingPathComponent("workflow.json")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: definition.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: definition.path) }
    XCTAssertThrowsError(try catalog.select(workflowId: "private", workingDirectory: root.path))
  }

  func testConcurrentRefreshAndSelectionNeverAcceptsAnUnpinnedMixedSnapshot() async throws {
    let root = try taskRoot("catalog-concurrent-capture")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent(".riela/workflows/race")
    try writeWorkflow(directory, id: "race", description: "first")
    let baselineCatalog = WorkflowCompactCatalog()
    let initial = try XCTUnwrap(baselineCatalog.refresh(workingDirectory: root.path).first)
    let definition = directory.appendingPathComponent("workflow.json")
    let barrier = CatalogCaptureBarrier()
    let catalog = WorkflowCompactCatalog { entry in
      guard entry.workflowId == "race" else { return }
      barrier.waitForMutation()
    }
    async let refresh: [WorkflowCompactCatalogCard] = Task.detached {
      try catalog.refresh(workingDirectory: root.path)
    }.value
    XCTAssertEqual(barrier.waitForCapture(), .success, "Refresh must stop before reading the selected card")
    try writeWorkflow(directory, id: "race", description: "second")
    barrier.releaseCapture()
    let refreshed = try await refresh
    let refreshedCard = try XCTUnwrap(refreshed.first { $0.workflowId == "race" })
    XCTAssertNotEqual(refreshedCard.revision, initial.revision)
    XCTAssertEqual(refreshedCard.shortSummary, "second")
    let selected = try catalog.select(workflowId: "race", workingDirectory: root.path)
    XCTAssertEqual(selected.revision, refreshedCard.revision,
                   "Capture must publish one complete post-mutation revision")
    XCTAssertFalse(try Data(contentsOf: definition).isEmpty)
  }

  private func taskRoot(_ name: String) throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/\(name)/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func definition(id: String, description: String, tags: [String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "workflowId": id,
      "description": description,
      "tags": tags,
      "nodes": [],
      "steps": []
    ], options: [.sortedKeys])
  }

  private func writeWorkflow(_ directory: URL, id: String, description: String) throws {
    let nodes = directory.appendingPathComponent("nodes")
    try FileManager.default.createDirectory(at: nodes, withIntermediateDirectories: true)
    let definition = #"""
    {"workflowId":"\#(id)","description":"\#(description)","defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":1},"entryStepId":"work",
    "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],
    "steps":[{"id":"work","nodeId":"work","role":"worker"}]}
    """#
    try Data(definition.utf8).write(to: directory.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"work","executionBackend":"codex-agent","model":"fixture","modelFreeze":false}"#.utf8)
      .write(to: nodes.appendingPathComponent("work.json"))
  }
}

private final class CatalogCaptureBarrier: @unchecked Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let released = DispatchSemaphore(value: 0)

  func waitForMutation() {
    entered.signal()
    _ = released.wait(timeout: .now() + 10)
  }

  func waitForCapture() -> DispatchTimeoutResult {
    entered.wait(timeout: .now() + 10)
  }

  func releaseCapture() {
    released.signal()
  }
}
