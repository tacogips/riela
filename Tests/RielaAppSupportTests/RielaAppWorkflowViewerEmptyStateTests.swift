#if os(macOS)
import AppKit
@testable import RielaApp
import RielaCore
import RielaViewer
import XCTest

@MainActor
final class RielaAppWorkflowViewerEmptyStateTests: XCTestCase {
  func testViewerInitialHeaderUsesDirectActionCopy() throws {
    let controller = WorkflowViewerWindowController()
    let root = try XCTUnwrap(controller.window?.contentView)
    let visibleTexts = Set(visibleTextFields(in: root).map(\.stringValue))

    XCTAssertTrue(visibleTexts.contains("Choose Workflow"))
    XCTAssertFalse(visibleTexts.contains("No workflow loaded"))
  }

  func testRunLogEmptySessionCopyUsesRunsNotPersistence() {
    let controller = WorkflowViewerWindowController()
    let workflow = WorkflowDefinition(
      workflowId: "empty-copy",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first")],
      steps: [WorkflowStepRef(id: "first", nodeId: "first")],
      nodes: [WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json")]
    )
    let state = WorkflowViewerState(
      workflow: workflow,
      workflowDirectory: "/tmp/workflow",
      sessionStoreRoot: "/tmp/.riela/sessions",
      sessionStoreCandidates: ["/tmp/.riela/sessions"],
      selectedSessionId: nil,
      sessions: [],
      nodes: []
    )
    let lines = controller.renderRunLog(state: state, selectedStepId: nil, session: nil)

    XCTAssertTrue(lines.contains("No runs recorded for this workflow."))
    XCTAssertFalse(lines.contains("No persisted sessions found for this workflow."))
  }

  func testSessionPickerEmptyCopyUsesRunsNotSessions() throws {
    let temp = try scratchRoot(name: "riela-app-empty-session-picker-\(UUID().uuidString)")
    let workflowDirectory = temp.appendingPathComponent("workflows/demo", isDirectory: true)
    let nodeDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: nodeDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionStoreRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let controller = WorkflowViewerWindowController()
    let workflow = WorkflowDefinition(
      workflowId: "empty-session-picker",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first")],
      steps: [WorkflowStepRef(id: "first", nodeId: "first")],
      nodes: [WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json")]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))

    controller.show(workflowDirectory: workflowDirectory.path, sessionStoreRoot: sessionStoreRoot.path)
    let root = try XCTUnwrap(controller.window?.contentView)
    let popups = allSubviews(of: NSPopUpButton.self, in: root)
    XCTAssertTrue(popups.contains { popup in
      (0..<popup.numberOfItems).contains { popup.itemTitle(at: $0) == "No Runs" }
    })
    XCTAssertFalse(popups.contains { popup in
      (0..<popup.numberOfItems).contains { popup.itemTitle(at: $0) == "No sessions" }
    })
  }

  private func visibleTextFields(in root: NSView) -> [NSTextField] {
    allSubviews(of: NSTextField.self, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    let current = (root as? T).map { [$0] } ?? []
    return current + root.subviews.flatMap { allSubviews(of: type, in: $0) }
  }

  private func scratchRoot(name: String) throws -> URL {
    let root = try repositoryRoot().appendingPathComponent("tmp", isDirectory: true)
    let scratch = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
  }

  private func repositoryRoot() throws -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    while current.path != "/" {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
        return current
      }
      current.deleteLastPathComponent()
    }
    throw NSError(
      domain: "RielaAppWorkflowViewerEmptyStateTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"]
    )
  }

}

private extension NSView {
  var hasHiddenAncestor: Bool {
    isHidden || superview?.hasHiddenAncestor == true
  }
}
#endif
