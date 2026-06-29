#if os(macOS)
import Foundation
import XCTest

final class RielaAppInterfaceIdentifierTests: XCTestCase {
  func testInstanceListDoesNotExposeLegacySourceColumnIdentifier() throws {
    let root = try repositoryRoot()
    let controllerURL = root.appendingPathComponent(
      "Sources/RielaApp/DaemonWorkflowWindowController.swift"
    )
    let source = try String(contentsOf: controllerURL, encoding: .utf8)

    XCTAssertFalse(
      source.contains("NSUserInterfaceItemIdentifier(\"source\")") ||
      source.contains("NSUserInterfaceItemIdentifier(\"sources\")"),
      "The main instance list should not keep workflow-source table column identifiers."
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
    let profileSelectSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/ProfileSelectWindowController.swift"),
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
    XCTAssertFalse(controllerSource.contains("Last Action:"))
    XCTAssertFalse(controllerSource.contains("Selected: None"))
    XCTAssertFalse(controllerSource.contains("Profile: \\(profileName.rawValue)"))
    XCTAssertFalse(controllerSource.contains("State: \\(row.state.rawValue)"))
    XCTAssertFalse(controllerSource.contains("Runtime: \\(runtimeDetail)"))
    XCTAssertFalse(appSource.contains("active /"))
    XCTAssertFalse(appSource.contains("enabled\""))
    XCTAssertTrue(appSource.contains("menuItem(\"Instances...\""))
    XCTAssertTrue(appSource.contains("setActivationPolicy(.regular)"))
    XCTAssertTrue(appSource.contains("\"Instances: \\(daemonSummary())\""))
    XCTAssertTrue(controllerSource.contains("window.title = \"Riela Workflow Instances\""))
    XCTAssertTrue(profileSelectSource.contains("window.title = \"Profile Select\""))
    XCTAssertTrue(profileSelectSource.contains("profileActionRow("))
    XCTAssertTrue(profileSelectSource.contains("title: \"Use Selected Profile\""))
    XCTAssertTrue(profileSelectSource.contains("title: \"Add Profile\""))
    XCTAssertTrue(profileSelectSource.contains("Remove Selected Profile"))
    XCTAssertFalse(profileSelectSource.contains("NSButton(title: \"+\""))
    XCTAssertFalse(profileSelectSource.contains("NSButton(title: \"-\""))
    XCTAssertFalse(profileSelectSource.contains("NSButton(title: \"Open\""))
    XCTAssertFalse(profileSelectSource.contains("NSButton(title: \"Cancel\""))
    XCTAssertFalse(controllerSource.contains("addColumn(Column.workflow, title: \"Workflow\""))
    XCTAssertFalse(controllerSource.contains("addColumn(Column.state, title: \"State\""))
    XCTAssertTrue(controllerSource.contains("table.headerView = nil"))
    XCTAssertTrue(controllerSource.contains("makeInstanceRowView"))
    XCTAssertTrue(controllerSource.contains("instanceSubtitle(for:"))
    XCTAssertTrue(controllerSource.contains("messageText = \"Add Instance\""))
    XCTAssertTrue(controllerSource.contains("Select a workflow and enter instance parameters."))
    XCTAssertTrue(controllerSource.contains("\"< Instances\""))
    XCTAssertTrue(controllerSource.contains("Current Settings"))
    XCTAssertTrue(controllerSource.contains("Instance Actions"))
    XCTAssertTrue(controllerSource.contains("NSClickGestureRecognizer"))
    XCTAssertTrue(controllerSource.contains("settingRow(title: \"Name\""))
    XCTAssertTrue(controllerSource.contains("actionRow(title: \"Start\""))
    XCTAssertTrue(controllerSource.contains("title: \"Remove Instance\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Duplicate\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Rename\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Start\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Stop\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Restart\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Remove Instance\""))
    XCTAssertFalse(controllerSource.contains("buttonTitle: \"Edit\""))
    XCTAssertTrue(controllerSource.contains("showInstanceDetail()"))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Actions\""))
    XCTAssertFalse(controllerSource.contains("addAction(\"Open\""))
    XCTAssertFalse(controllerSource.contains("onViewSelectedWorkflow"))
    XCTAssertTrue(controllerSource.contains("Missing source"))
    XCTAssertTrue(controllerSource.contains("Needs Source"))
    XCTAssertTrue(controllerSource.contains("labelWithString: \"Instance ID\""))
    XCTAssertTrue(controllerSource.contains("NSButton(title: \"+ Add Instance\""))
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
    let processSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift"),
      encoding: .utf8
    )
    let storeSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaAppSupport/RielaAppEnvironmentFileStore.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(processSource.contains("RielaAppDaemonProcessEventSourceFactory"))
    XCTAssertTrue(processSource.contains("[RielaApp daemon event-serve]"))
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
