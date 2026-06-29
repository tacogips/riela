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

  func testInstanceListUsesStateAndAddInstanceFlowInsteadOfEnabledDisabledSplit() throws {
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
    XCTAssertFalse(appSource.contains("menuItem(\"Open Profile Folder\""))
    XCTAssertFalse(controllerSource.contains("Add Workflow/Package..."))
    XCTAssertFalse(controllerSource.contains("Add Project..."))
    XCTAssertFalse(controllerSource.contains("profileField"))
    XCTAssertFalse(controllerSource.contains("Switch/Create"))
    XCTAssertFalse(controllerSource.contains("Open Profile Folder"))
    XCTAssertFalse(controllerSource.contains("Enabled Instances"))
    XCTAssertFalse(controllerSource.contains("Disabled Instances"))
    XCTAssertFalse(controllerSource.contains("title: \"Active\""))
    XCTAssertFalse(controllerSource.contains("Active:"))
    XCTAssertFalse(appSource.contains("active /"))
    XCTAssertFalse(appSource.contains("enabled\""))
    XCTAssertTrue(appSource.contains("menuItem(\"Instances...\""))
    XCTAssertTrue(appSource.contains("setActivationPolicy(.regular)"))
    XCTAssertTrue(appSource.contains("\"Instances: \\(daemonSummary())\""))
    XCTAssertTrue(controllerSource.contains("window.title = \"Riela Workflow Instances\""))
    XCTAssertTrue(controllerSource.contains("window.title = \"Profile Select\""))
    XCTAssertTrue(controllerSource.contains("title: \"Instance\""))
    XCTAssertTrue(controllerSource.contains("title: \"Workflow\""))
    XCTAssertTrue(controllerSource.contains("title: \"State\""))
    XCTAssertTrue(controllerSource.contains("messageText = \"Add Instance\""))
    XCTAssertTrue(controllerSource.contains("Select a workflow and enter instance parameters."))
    XCTAssertTrue(controllerSource.contains("Missing source"))
    XCTAssertTrue(controllerSource.contains("Needs Source"))
    XCTAssertTrue(controllerSource.contains("addAction(\"Start\""))
    XCTAssertTrue(controllerSource.contains("addAction(\"Stop\""))
    XCTAssertTrue(controllerSource.contains("addAction(\"Restart\""))
    XCTAssertTrue(controllerSource.contains("addAction(\"Remove Instance\""))
    XCTAssertTrue(controllerSource.contains("Instance ID:"))
    XCTAssertTrue(controllerSource.contains("NSButton(title: \"+\""))
    XCTAssertTrue(controllerSource.contains("NSButton(title: \"-\""))
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
    XCTAssertTrue(controllerSource.contains("Instance Dir:"))
    XCTAssertTrue(controllerSource.contains("Instance Env:"))
    XCTAssertTrue(controllerSource.contains("Instance Variables:"))
    XCTAssertTrue(controllerSource.contains("currentDirectoryButtonPressed"))
    XCTAssertTrue(controllerSource.contains("environmentVariablesButtonPressed"))
    XCTAssertTrue(controllerSource.contains("workflowVariablesButtonPressed"))
  }

  func testProcessTerminologyIsPreservedForEventSourceProcesses() throws {
    let root = try repositoryRoot()
    let controllerSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/DaemonWorkflowWindowController.swift"),
      encoding: .utf8
    )
    let storeSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaAppSupport/RielaAppEnvironmentFileStore.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(controllerSource.contains("Event runner:"))
    XCTAssertTrue(storeSource.contains("processEnvironment"))
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
