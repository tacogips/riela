#if os(macOS)
import Foundation
import XCTest

final class RielaAppInterfaceIdentifierTests: XCTestCase {
  func testWorkflowSourceColumnUsesOnlySourceIdentifier() throws {
    let root = try repositoryRoot()
    let controllerURL = root.appendingPathComponent(
      "Sources/RielaApp/DaemonWorkflowWindowController.swift"
    )
    let source = try String(contentsOf: controllerURL, encoding: .utf8)

    XCTAssertTrue(
      source.contains("NSUserInterfaceItemIdentifier(\"source\")"),
      "Workflow source column should use the canonical 'source' identifier."
    )
    XCTAssertFalse(
      source.contains("NSUserInterfaceItemIdentifier(\"sources\")"),
      "Do not keep a legacy 'sources' user-interface identifier."
    )
  }

  func testWorkflowListUsesActiveAndListControlsInsteadOfStartStopMenuActions() throws {
    let root = try repositoryRoot()
    let appSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/EntryPoint.swift"),
      encoding: .utf8
    )
    let controllerSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/DaemonWorkflowWindowController.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(appSource.contains("Auto-Start Enabled Workflows"))
    XCTAssertFalse(appSource.contains("Stop and Disable Auto-Start"))
    XCTAssertFalse(controllerSource.contains("Add Workflow/Package..."))
    XCTAssertFalse(controllerSource.contains("Add Project..."))
    XCTAssertTrue(controllerSource.contains("NSButton(title: \"+\""))
    XCTAssertTrue(controllerSource.contains("NSButton(title: \"-\""))
    XCTAssertTrue(controllerSource.contains("title: \"Active\""))
  }

  func testWorkflowEditViewerSeparatesEditRunLogAndStructureTabs() throws {
    let root = try repositoryRoot()
    let controllerSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/WorkflowViewerWindowController.swift"),
      encoding: .utf8
    )
    let renderingSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/WorkflowViewerWindowController+Rendering.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(controllerSource.contains("tabItem(label: \"Edit\""))
    XCTAssertTrue(controllerSource.contains("tabItem(label: \"Variables\""))
    XCTAssertTrue(controllerSource.contains("tabItem(label: \"Run Log\""))
    XCTAssertTrue(controllerSource.contains("tabItem(label: \"Structure\""))
    XCTAssertTrue(renderingSource.contains("Original Workflow Templates"))
    XCTAssertTrue(renderingSource.contains("Step Timeline"))
    XCTAssertTrue(controllerSource.contains("Current Dir:"))
    XCTAssertTrue(controllerSource.contains("currentDirectoryButtonPressed"))
    XCTAssertTrue(controllerSource.contains("environmentVariablesButtonPressed"))
    XCTAssertTrue(controllerSource.contains("workflowVariablesButtonPressed"))
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
      domain: "RielaAppInterfaceIdentifierTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"]
    )
  }
}
#endif
