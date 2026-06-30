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
    let source = try String(contentsOfFile: rielaAppSourceURL().path, encoding: .utf8)

    XCTAssertTrue(source.contains("sessionPopup.addItem(withTitle: \"No Runs\")"))
    XCTAssertFalse(source.contains("sessionPopup.addItem(withTitle: \"No sessions\")"))
  }

  private func visibleTextFields(in root: NSView) -> [NSTextField] {
    allSubviews(of: NSTextField.self, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    let current = (root as? T).map { [$0] } ?? []
    return current + root.subviews.flatMap { allSubviews(of: type, in: $0) }
  }

  private func rielaAppSourceURL() throws -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    while current.path != "/" {
      let candidate = current.appendingPathComponent("Sources/RielaApp/WorkflowViewerWindowController.swift")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      current.deleteLastPathComponent()
    }
    throw NSError(
      domain: "RielaAppWorkflowViewerEmptyStateTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "WorkflowViewerWindowController.swift was not found"]
    )
  }
}

private extension NSView {
  var hasHiddenAncestor: Bool {
    isHidden || superview?.hasHiddenAncestor == true
  }
}
#endif
