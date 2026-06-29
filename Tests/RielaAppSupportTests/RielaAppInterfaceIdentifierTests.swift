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
    let environmentSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/EntryPoint+Environment.swift"),
      encoding: .utf8
    )
    let daemonInstancesSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/EntryPoint+DaemonInstances.swift"),
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
    XCTAssertTrue(controllerSource.contains("Instance Parameters"))
    XCTAssertTrue(controllerSource.contains("addInstanceFieldRow("))
    XCTAssertTrue(controllerSource.contains("addInstanceToggleRow("))
    XCTAssertTrue(controllerSource.contains("addInstanceFieldRow(title: \"Workflow\""))
    XCTAssertTrue(controllerSource.contains("addInstanceFieldRow(title: \"Instance ID\""))
    XCTAssertTrue(controllerSource.contains("addInstanceFieldRow(title: \"Display Name\""))
    XCTAssertTrue(controllerSource.contains("addInstanceFieldRow(title: \"Env File\""))
    XCTAssertTrue(controllerSource.contains("addInstanceFieldRow(title: \"Working Directory\""))
    XCTAssertTrue(controllerSource.contains("addInstanceToggleRow(title: \"Start\""))
    XCTAssertTrue(controllerSource.contains("Source Actions"))
    XCTAssertTrue(controllerSource.contains("sourceActionStack()"))
    XCTAssertTrue(controllerSource.contains("title: \"Import Workflow or Package\""))
    XCTAssertTrue(controllerSource.contains("title: \"Add Project Source\""))
    XCTAssertFalse(controllerSource.contains("alert.addButton(withTitle: \"Import Workflow or Package...\""))
    XCTAssertFalse(controllerSource.contains("alert.addButton(withTitle: \"Add Project Source...\""))
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
    XCTAssertTrue(environmentSource.contains("environmentChoiceStack("))
    XCTAssertTrue(environmentSource.contains("environmentActionRow("))
    XCTAssertTrue(environmentSource.contains("Choose File"))
    XCTAssertTrue(environmentSource.contains("Clear Env File"))
    XCTAssertTrue(environmentSource.contains("Choose Directory"))
    XCTAssertTrue(environmentSource.contains("Clear Directory Override"))
    XCTAssertFalse(environmentSource.contains("alert.addButton(withTitle: \"Choose File\""))
    XCTAssertFalse(environmentSource.contains("alert.addButton(withTitle: \"Choose Directory\""))
    XCTAssertFalse(environmentSource.contains("alert.addButton(withTitle: \"Clear\""))
    XCTAssertTrue(controllerSource.contains("showInstanceDetail()"))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Actions\""))
    XCTAssertFalse(controllerSource.contains("addAction(\"Open\""))
    XCTAssertFalse(controllerSource.contains("onViewSelectedWorkflow"))
    XCTAssertTrue(daemonInstancesSource.contains("daemonInstancePromptFieldRow("))
    XCTAssertTrue(daemonInstancesSource.contains("daemonInstancePromptFieldRow(title: \"Instance ID\""))
    XCTAssertTrue(daemonInstancesSource.contains("daemonInstancePromptFieldRow(title: \"Display Name\""))
    XCTAssertTrue(daemonInstancesSource.contains("multilineValueEditorStack("))
    XCTAssertTrue(daemonInstancesSource.contains("multilineValueFieldRow(title: \"Current Lines\""))
    XCTAssertTrue(daemonInstancesSource.contains("multilineValueFieldRow(title: \"Editor\""))
    XCTAssertTrue(daemonInstancesSource.contains("Variable Settings"))
    XCTAssertFalse(daemonInstancesSource.contains("labelWithString: \"Instance ID\""))
    XCTAssertFalse(daemonInstancesSource.contains("labelWithString: \"Display Name\""))
    XCTAssertTrue(controllerSource.contains("Missing source"))
    XCTAssertTrue(controllerSource.contains("Needs Source"))
    XCTAssertFalse(controllerSource.contains("labelWithString: \"Instance ID\""))
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
    XCTAssertTrue(controllerSource.contains("Instance Settings"))
    XCTAssertTrue(controllerSource.contains("instanceSettingRow("))
    XCTAssertTrue(controllerSource.contains("title: \"Current Directory\""))
    XCTAssertTrue(controllerSource.contains("title: \"Environment Variables\""))
    XCTAssertTrue(controllerSource.contains("title: \"Workflow Variables\""))
    XCTAssertTrue(controllerSource.contains("Node Overrides"))
    XCTAssertTrue(controllerSource.contains("currentDirectoryRowSelected"))
    XCTAssertTrue(controllerSource.contains("environmentVariablesRowSelected"))
    XCTAssertTrue(controllerSource.contains("workflowVariablesRowSelected"))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Instance Dir...\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Instance Env...\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Instance Variables...\""))
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
