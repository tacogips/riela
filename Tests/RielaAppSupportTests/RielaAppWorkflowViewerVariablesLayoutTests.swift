#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import RielaCore
import XCTest

@MainActor
final class WorkflowViewerVariablesLayoutTests: XCTestCase {
  func testWorkflowViewerInstanceSettingRowsFillVariablesTabWidth() throws {
    let temp = try scratchRoot(name: "riela-app-viewer-variables-\(UUID().uuidString)")
    let workflowDirectory = temp.appendingPathComponent("workflows/demo", isDirectory: true)
    let runtimeRoot = temp.appendingPathComponent(".riela/sessions/runtime-records", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    try writeWorkflow(id: "viewer-variables-layout", to: workflowDirectory)
    try saveSession(runtimeRoot: runtimeRoot)

    let controller = WorkflowViewerWindowController()
    controller.show(
      workflowDirectory: workflowDirectory.path,
      sessionStoreRoot: temp.appendingPathComponent(".riela/sessions", isDirectory: true).path,
      onSetWorkingDirectory: { "/tmp/work" },
      onSetEnvironmentVariables: { "1 variable" },
      onSetWorkflowVariables: { "2 variables" }
    )
    let root = try XCTUnwrap(controller.window?.contentView)
    let tabView = try XCTUnwrap(firstSubview(of: NSTabView.self, in: root))
    try selectTab(named: "Variables", in: tabView)
    controller.window?.layoutIfNeeded()

    let row = try XCTUnwrap(selectableRow(accessibilityLabel: "Current Directory", in: root))
    let stack = try XCTUnwrap(row.superview as? NSStackView)
    XCTAssertEqual(stack.orientation, .vertical)
    XCTAssertEqual(row.frame.width, stack.frame.width, accuracy: 1)
  }

  private func writeWorkflow(id: String, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try """
    {
      "id": "\(id)",
      "entryStepId": "first",
      "nodes": [{"id": "first", "type": "agent", "payloadFile": "nodes/first.json"}],
      "edges": []
    }
    """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "first",
      "executionBackend": "codex-agent",
      "model": "gpt-5.5",
      "modelFreeze": false,
      "variables": {}
    }
    """.write(to: directory.appendingPathComponent("nodes/first.json"), atomically: true, encoding: .utf8)
  }

  private func saveSession(runtimeRoot: URL) throws {
    let updatedAt = Date(timeIntervalSince1970: 11)
    let session = WorkflowSession(
      workflowId: "viewer-variables-layout",
      sessionId: "viewer-variables",
      status: .completed,
      entryStepId: "first",
      currentStepId: nil,
      createdAt: Date(timeIntervalSince1970: 10),
      updatedAt: updatedAt,
      executions: [WorkflowStepExecution(
        executionId: "viewer-variables-step",
        stepId: "first",
        nodeId: "first",
        attempt: 1,
        status: .completed,
        createdAt: updatedAt,
        updatedAt: updatedAt
      )]
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot.path)
      .save(WorkflowRuntimePersistenceSnapshot(session: session))
  }

  private func scratchRoot(name: String) throws -> URL {
    let root = try repositoryRoot().appendingPathComponent("tmp", isDirectory: true)
    let scratch = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
  }

  private func repositoryRoot() throws -> URL {
    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    while url.path != "/" {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    throw NSError(
      domain: "RielaAppWorkflowViewerVariablesLayoutTests",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"]
    )
  }

  private func selectTab(named label: String, in tabView: NSTabView) throws {
    guard let item = tabView.tabViewItems.first(where: { $0.label == label }) else {
      throw NSError(
        domain: "RielaAppWorkflowViewerVariablesLayoutTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Tab not found: \(label)"]
      )
    }
    tabView.selectTabViewItem(item)
  }

  private func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
    if let typed = root as? T {
      return typed
    }
    for subview in root.subviews {
      if let found = firstSubview(of: type, in: subview) {
        return found
      }
    }
    return nil
  }

  private func selectableRow(accessibilityLabel: String, in root: NSView) -> RielaAppSelectableSettingsRow? {
    allSubviews(of: RielaAppSelectableSettingsRow.self, in: root).first { row in
      !row.hasHiddenAncestor &&
        row.accessibilityLabel() == accessibilityLabel &&
        row.accessibilityRole() == .button
    }
  }

  private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    var matches: [T] = []
    if let typed = root as? T {
      matches.append(typed)
    }
    for subview in root.subviews {
      matches.append(contentsOf: allSubviews(of: type, in: subview))
    }
    return matches
  }
}

private extension NSView {
  var hasHiddenAncestor: Bool {
    if isHidden {
      return true
    }
    return superview?.hasHiddenAncestor ?? false
  }
}
#endif
