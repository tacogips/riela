#if os(macOS)
import AppKit
import Foundation
@testable import RielaApp
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
    let controllerPromptSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/DaemonWorkflowWindowController+Prompts.swift"),
      encoding: .utf8
    )
    let controllerRowSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/DaemonWorkflowWindowController+Rows.swift"),
      encoding: .utf8
    )
    let controllerSettingsShellSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/DaemonWorkflowWindowController+SettingsShell.swift"),
      encoding: .utf8
    )
    let controllerDetailSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/DaemonWorkflowWindowController+DetailView.swift"),
      encoding: .utf8
    )
    let controllerUXSource = controllerSource
      + controllerPromptSource
      + controllerRowSource
      + controllerSettingsShellSource
      + controllerDetailSource
    let profileSelectSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/ProfileSelectWindowController.swift"),
      encoding: .utf8
    )
    let environmentSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/EntryPoint+Environment.swift"),
      encoding: .utf8
    )
    let settingsEditorSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/RielaAppSettingsEditorWindowController.swift"),
      encoding: .utf8
    )
    let disclosureSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/RielaAppDisclosureIndicator.swift"),
      encoding: .utf8
    )
    let daemonInstancesSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/EntryPoint+DaemonInstances.swift"),
      encoding: .utf8
    )
    let settingsRowStyleSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/RielaAppSettingsRowStyle.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(appSource.contains("Auto-Start Enabled Workflows"))
    XCTAssertFalse(appSource.contains("Stop and Disable Auto-Start"))
    XCTAssertFalse(appSource.contains("menuItem(\"Open Profile Folder\""))
    XCTAssertFalse(appSource.contains("Select Workflow to Serve") || appSource.contains("status = \"Selected\""))
    XCTAssertFalse(appSource.contains("panel.title = \"Choose Workflow to Serve\""))
    XCTAssertFalse(appSource.contains("status = \"Workflow selected\""))
    XCTAssertTrue(appSource.contains("panel.title = \"Choose Workflow to View\"") && appSource.contains("status = \"Workflow ready to view\""))
    assertSourcePickerOpenPanelsUseUserFacingCopy(appSource: appSource)
    XCTAssertFalse(controllerUXSource.contains("Add Workflow/Package..."))
    XCTAssertFalse(controllerUXSource.contains("Add Project..."))
    XCTAssertFalse(controllerUXSource.contains("profileField"))
    XCTAssertFalse(controllerUXSource.contains("Switch/Create"))
    XCTAssertFalse(controllerUXSource.contains("Open Profile Folder"))
    XCTAssertFalse(controllerUXSource.contains("Enabled Instances"))
    XCTAssertFalse(controllerUXSource.contains("Disabled Instances"))
    XCTAssertFalse(controllerUXSource.contains("title: \"Active\""))
    XCTAssertFalse(controllerUXSource.contains("Active:"))
    XCTAssertFalse(controllerUXSource.contains("Last Action:"))
    XCTAssertFalse(controllerUXSource.contains("Selected: None"))
    XCTAssertFalse(controllerUXSource.contains("Profile: \\(profileName.rawValue)"))
    XCTAssertFalse(controllerUXSource.contains("State: \\(row.state.rawValue)"))
    XCTAssertFalse(controllerUXSource.contains("Runtime: \\(runtimeDetail)"))
    assertMissingSelectionCopyUsesUserFacingLanguage(
      appSource: appSource,
      controllerSource: controllerSource,
      environmentSource: environmentSource,
      daemonInstancesSource: daemonInstancesSource
    )
    XCTAssertFalse(appSource.contains("active /"))
    XCTAssertFalse(appSource.contains("enabled\""))
    assertStatusMenuUsesCompactSummaries(appSource: appSource)
    XCTAssertTrue(appSource.contains("addDaemonWorkflowSourceOnlyDirectory()"))
    XCTAssertTrue(appSource.contains("importDaemonWorkflowOrPackageSourcesOnly("))
    XCTAssertFalse(appSource.contains("addDaemonWorkflowDirectory()"))
    assertCompactInstanceWindowAndToolbar(controllerSource: controllerSource + controllerSettingsShellSource)
    assertProfilePopupUsesAccessibleCompressibleControl(controllerSource: controllerSource + controllerSettingsShellSource)
    assertProfileSelectUsesSettingsRows(
      profileSelectSource: profileSelectSource,
      settingsRowStyleSource: settingsRowStyleSource,
      controllerRowSource: controllerRowSource,
      environmentSource: environmentSource,
      settingsEditorSource: settingsEditorSource,
      daemonInstancesSource: daemonInstancesSource
    )
    XCTAssertFalse(controllerUXSource.contains("addColumn(Column.workflow, title: \"Workflow\""))
    XCTAssertFalse(controllerUXSource.contains("addColumn(Column.state, title: \"State\""))
    XCTAssertTrue(controllerRowSource.contains("table.headerView = nil"))
    XCTAssertTrue(controllerRowSource.contains("makeInstanceRowView"))
    XCTAssertTrue(controllerRowSource.contains("rielaAppSettingsRow(rowStack)"))
    XCTAssertTrue(controllerRowSource.contains("instanceSubtitle(for:"))
    XCTAssertTrue(controllerRowSource.contains("column.minWidth = 180"))
    XCTAssertTrue(controllerRowSource.contains("column.resizingMask = .autoresizingMask"))
    XCTAssertTrue(controllerRowSource.contains("scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)"))
    XCTAssertTrue(controllerRowSource.contains("DaemonWorkflowInstanceListView"))
    XCTAssertTrue(controllerRowSource.contains("scrollView.frame = NSRect("))
    XCTAssertFalse(controllerRowSource.contains("scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)"))
    XCTAssertFalse(controllerRowSource.contains("scroll.heightAnchor.constraint(equalToConstant: 260)"))
    XCTAssertTrue(controllerRowSource.contains("stateSymbolName(for: row.state)"))
    XCTAssertTrue(controllerRowSource.contains("stateIcon.contentTintColor = stateColor(for: row.state)"))
    XCTAssertTrue(controllerRowSource.contains("stateStack.setAccessibilityLabel(row.state.rawValue)"))
    XCTAssertFalse(controllerRowSource.contains("state.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)"))
    assertMetadataTextUsesReadableSeparators(
      settingsRowStyleSource: settingsRowStyleSource,
      controllerSource: controllerSource,
      controllerRowSource: controllerRowSource,
      controllerPromptSource: controllerPromptSource,
      controllerUXSource: controllerUXSource
    )
    assertAddInstancePromptUsesSettingsFlow(
      controllerSource: controllerSource,
      controllerPromptSource: controllerPromptSource,
      controllerUXSource: controllerUXSource
    )
    assertWorkflowSourceSelectionRows(
      controllerSource: controllerSource,
      controllerPromptSource: controllerPromptSource
    )
    XCTAssertTrue(controllerUXSource.contains("NSButton(title: \"Instances\""))
    XCTAssertTrue(controllerUXSource.contains("NSImage(systemSymbolName: \"chevron.left\""))
    XCTAssertTrue(controllerUXSource.contains("backToInstancesButton.setAccessibilityLabel(\"Back to Instances\")"))
    XCTAssertFalse(controllerSource.contains("\"< Instances\""))
    XCTAssertTrue(controllerUXSource.contains("Current Settings"))
    XCTAssertTrue(controllerUXSource.contains("Manage Instance"))
    assertNeedsSourceRelinkContract(
      appSource: appSource,
      controllerSource: controllerSource + controllerDetailSource,
      controllerUXSource: controllerUXSource,
      daemonInstancesSource: daemonInstancesSource
    )
    XCTAssertFalse(controllerUXSource.contains("NSClickGestureRecognizer"))
    XCTAssertTrue(disclosureSource.contains("NSImage(systemSymbolName: \"chevron.right\""))
    XCTAssertTrue(disclosureSource.contains("imageView.setAccessibilityElement(false)"))
    XCTAssertTrue(controllerUXSource.contains("rielaAppDisclosureIndicator()"))
    XCTAssertTrue(profileSelectSource.contains("rielaAppDisclosureIndicator()"))
    XCTAssertFalse(environmentSource.contains("rielaAppDisclosureIndicator()"))
    XCTAssertFalse(controllerUXSource.contains("labelWithString: \">\""))
    XCTAssertFalse(profileSelectSource.contains("labelWithString: \">\""))
    XCTAssertFalse(environmentSource.contains("labelWithString: \">\""))
    assertSettingsRowLabelsCompressInNarrowPrompts(
      settingsRowStyleSource, controllerUXSource, profileSelectSource, environmentSource, daemonInstancesSource
    )
    XCTAssertTrue(controllerUXSource.contains("settingRow(title: \"Name\""))
    XCTAssertTrue(controllerUXSource.contains("startRow = actionRow("))
    XCTAssertTrue(controllerUXSource.contains("title: \"Remove Instance\""))
    XCTAssertFalse(controllerUXSource.contains("NSButton(title: \"Duplicate\""))
    XCTAssertFalse(controllerUXSource.contains("NSButton(title: \"Rename\""))
    XCTAssertFalse(controllerUXSource.contains("NSButton(title: \"Start\""))
    XCTAssertFalse(controllerUXSource.contains("NSButton(title: \"Stop\""))
    XCTAssertFalse(controllerUXSource.contains("NSButton(title: \"Restart\""))
    XCTAssertFalse(controllerUXSource.contains("NSButton(title: \"Remove Instance\""))
    XCTAssertFalse(controllerUXSource.contains("buttonTitle: \"Edit\""))
    assertEnvironmentPromptsUseSettingsRows(environmentSource: environmentSource)
    XCTAssertTrue(controllerSource.contains("showInstanceDetail()"))
    XCTAssertFalse(controllerUXSource.contains("NSButton(title: \"Actions\""))
    XCTAssertFalse(controllerUXSource.contains("addAction(\"Open\""))
    XCTAssertFalse(controllerUXSource.contains("onViewSelectedWorkflow"))
    XCTAssertTrue(daemonInstancesSource.contains("DaemonInstancePromptViewFactory"))
    XCTAssertTrue(daemonInstancesSource.contains("title: \"Instance Name\""))
    XCTAssertTrue(daemonInstancesSource.contains("message: \"Update the saved instance identifier and display name"))
    XCTAssertTrue(daemonInstancesSource.contains("title: \"New Instance\""))
    XCTAssertTrue(daemonInstancesSource.contains("message: \"Create another saved instance"))
    XCTAssertFalse(daemonInstancesSource.contains("Rename Workflow Instance"))
    XCTAssertFalse(daemonInstancesSource.contains("Duplicate Workflow Instance"))
    XCTAssertFalse(daemonInstancesSource.contains("Change the management id"))
    XCTAssertTrue(daemonInstancesSource.contains("nameEditorStack(idField: idField, nameField: nameField)"))
    XCTAssertTrue(daemonInstancesSource.contains("fieldRow(title: \"Instance ID\""))
    XCTAssertTrue(daemonInstancesSource.contains("fieldRow(title: \"Display Name\""))
    XCTAssertTrue(daemonInstancesSource.contains("RielaAppSettingsEditorWindowController.editMultiline("))
    XCTAssertFalse(daemonInstancesSource.contains("variableEditorStack(currentValue: value, editorView: scrollView)"))
    assertInstancePromptsUseCompactFrames(daemonInstancesSource: daemonInstancesSource)
    XCTAssertFalse(daemonInstancesSource.contains("labelWithString: \"Instance ID\""))
    XCTAssertFalse(daemonInstancesSource.contains("labelWithString: \"Display Name\""))
    XCTAssertTrue(controllerSource.contains("Missing source"))
    XCTAssertTrue(controllerSource.contains("Needs Source"))
    XCTAssertFalse(controllerSource.contains("labelWithString: \"Instance ID\""))
    XCTAssertTrue(controllerSource.contains("let addListButton = NSButton(title: \"\""))
    XCTAssertFalse(controllerUXSource.contains("NSButton(title: \"+ Add Instance\""))
    XCTAssertLessThan(controllerSource.split(separator: "\n", omittingEmptySubsequences: false).count, 1_000)
    XCTAssertTrue(controllerPromptSource.contains("extension DaemonWorkflowWindowController"))
    XCTAssertTrue(controllerRowSource.contains("extension DaemonWorkflowWindowController"))
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
    let settingsRowStyleSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/RielaAppSettingsRowStyle.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(controllerSource.contains("tabItem(label: \"Edit\""))
    XCTAssertTrue(settingsRowStyleSource.contains("func rielaAppSettingsRow(_ row: NSStackView)"))
    XCTAssertTrue(controllerSource.contains("tabItem(label: \"Variables\""))
    XCTAssertTrue(controllerSource.contains("tabItem(label: \"Run Log\""))
    XCTAssertTrue(controllerSource.contains("tabItem(label: \"Structure\""))
    XCTAssertTrue(controllerSource.contains("initialWindowSize = NSSize(width: 640"))
    XCTAssertTrue(controllerSource.contains("minimumWindowSize = NSSize(width: 420"))
    XCTAssertTrue(controllerSource.contains("sidebarWidth: CGFloat = 180"))
    XCTAssertFalse(controllerSource.contains("initialWindowSize = NSSize(width: 700"))
    XCTAssertFalse(controllerSource.contains("minimumWindowSize = NSSize(width: 500"))
    XCTAssertFalse(controllerSource.contains("width: 980"))
    XCTAssertTrue(controllerSource.contains("configureCompactPopup(sessionPopup"))
    XCTAssertTrue(controllerSource.contains("configureIconButton(saveNodePatchButton"))
    XCTAssertTrue(controllerSource.contains("configureIconButton(clearNodePatchButton"))
    XCTAssertTrue(controllerSource.contains("configureIconButton(saveTemplateButton"))
    XCTAssertTrue(controllerSource.contains("configureIconButton(reloadTemplateButton"))
    XCTAssertTrue(controllerSource.contains("iconButton(\n      symbolName: \"arrow.clockwise\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Save Patch\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Clear Patch\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Reload\""))
    XCTAssertFalse(controllerSource.contains("greaterThanOrEqualToConstant: 520"))
    XCTAssertFalse(controllerSource.contains("greaterThanOrEqualToConstant: 540"))
    XCTAssertTrue(controllerSource.contains("applyPreferredHeight(140, to: detailScroll)"))
    XCTAssertTrue(controllerSource.contains("applyPreferredHeight(180, to: templateScroll)"))
    XCTAssertTrue(controllerSource.contains("applyPreferredHeight(300, to: tabView)"))
    XCTAssertFalse(controllerSource.contains("Workflow: \\(state.workflow.workflowId)"))
    XCTAssertFalse(controllerSource.contains("Sessions: \\(state.sessions.count)"))
    XCTAssertFalse(controllerSource.contains("Selected: \\($0.sessionId)"))
    XCTAssertTrue(controllerSource.contains("workflowTitleLabel"))
    XCTAssertTrue(controllerSource.contains("workflowSubtitleLabel"))
    XCTAssertTrue(controllerSource.contains("sessionSummary(state:"))
    XCTAssertTrue(controllerSource.contains("updateSessionPopup(for: self.state)"))
    XCTAssertTrue(controllerSource.contains("updateSessionPopup(for: loaded)"))
    XCTAssertTrue(controllerSource.contains("sessionPopup.selectItem(at: state.selectedSessionIndex)"))
    XCTAssertFalse(controllerSource.contains("sessionPopup.selectItem(at: 0)"))
    XCTAssertTrue(controllerSource.contains("stateSymbolName("))
    XCTAssertTrue(controllerSource.contains("stateAccessibilityLabel("))
    XCTAssertTrue(controllerSource.contains("NSImage(\n      systemSymbolName: stateSymbolName(node.state)"))
    XCTAssertFalse(controllerSource.contains("[Running]"))
    XCTAssertFalse(controllerSource.contains("[Completed]"))
    XCTAssertFalse(controllerSource.contains("[Failed]"))
    XCTAssertFalse(controllerSource.contains("[Idle]"))
    XCTAssertTrue(renderingSource.contains("Original Workflow Templates"))
    XCTAssertTrue(renderingSource.contains("Step Timeline"))
    XCTAssertTrue(renderingSource.contains("Step Messages"))
    XCTAssertFalse(renderingSource.contains("Selected Step Messages"))
    XCTAssertTrue(renderingSource.contains("State \\(workflowViewerStateText(session.status.rawValue))"))
    XCTAssertTrue(renderingSource.contains("workflowViewerStateText(_ rawValue: String)"))
    XCTAssertTrue(renderingSource.contains("State \\(workflowViewerStateText(entry.status.rawValue))"))
    XCTAssertTrue(renderingSource.contains("State \\(workflowViewerStateText(message.status.rawValue))"))
    XCTAssertTrue(renderingSource.contains("\"Workflow \\(state.workflow.workflowId)\""))
    XCTAssertTrue(renderingSource.contains("\"Session Store \\(state.sessionStoreRoot)\""))
    XCTAssertTrue(renderingSource.contains("\"Used by Step \\(templateFile.isActiveForStep ? \"Yes\" : \"No\")\""))
    XCTAssertFalse(renderingSource.contains("\"Active \\(templateFile.isActiveForStep ? \"Yes\" : \"No\")\""))
    XCTAssertFalse(renderingSource.contains("\"id: \\(state.workflow.workflowId)\""))
    XCTAssertFalse(renderingSource.contains("\"sessionStore: \\(state.sessionStoreRoot)\""))
    XCTAssertFalse(renderingSource.contains("\"  step: \\(templateFile.stepId)\""))
    XCTAssertFalse(renderingSource.contains("\"  active: \\(templateFile.isActiveForStep ? \"yes\" : \"no\")\""))
    XCTAssertFalse(renderingSource.contains("timelineMarker("))
    XCTAssertFalse(renderingSource.contains("\"[Running]\""))
    XCTAssertFalse(renderingSource.contains("\"[Done]\""))
    XCTAssertFalse(renderingSource.contains("\"[Skipped]\""))
    XCTAssertFalse(renderingSource.contains("\"[Failed]\""))
    XCTAssertFalse(renderingSource.contains("Status: \\(session.status.rawValue)"))
    XCTAssertFalse(renderingSource.contains(" active: \\(summary.activeStepIds.joined(separator: \",\"))"))
    XCTAssertTrue(controllerSource.contains("State \\(workflowViewerStateText(node.state.rawValue))"))
    XCTAssertFalse(controllerSource.contains("Node: \\(selectedNodeId)"))
    XCTAssertFalse(controllerSource.contains("Runtime: \\(node.state.rawValue)"))
    XCTAssertFalse(controllerSource.contains("Detail: \\(detail)"))
    XCTAssertTrue(controllerSource.contains("Instance Settings"))
    XCTAssertTrue(controllerSource.contains("instanceSettingRow("))
    XCTAssertTrue(controllerSource.contains("return rielaAppSelectableSettingsRow("))
    XCTAssertTrue(controllerSource.contains("rielaAppSettingsTitleLabel(title, maxWidth: 150)"))
    XCTAssertFalse(controllerSource.contains("widthAnchor.constraint(equalToConstant: 150)"))
    XCTAssertTrue(controllerSource.contains("title: \"Current Directory\""))
    XCTAssertTrue(controllerSource.contains("title: \"Environment Variables\""))
    XCTAssertTrue(controllerSource.contains("title: \"Workflow Variables\""))
    XCTAssertTrue(controllerSource.contains("Node Overrides"))
    XCTAssertTrue(controllerSource.contains("workflowViewerControlRow(title: \"Session\""))
    XCTAssertTrue(controllerSource.contains("let templateRow = workflowViewerControlRow("))
    XCTAssertTrue(controllerSource.contains("title: \"Template\","))
    XCTAssertTrue(controllerSource.contains("workflowViewerControlRow(title: \"Model\""))
    XCTAssertFalse(controllerSource.contains("workflowViewerControlRow(title: \"Actions\""))
    XCTAssertTrue(controllerSource.contains("updateNodeOverrideRows("))
    XCTAssertTrue(controllerSource.contains("Node overrides cannot be edited here"))
    XCTAssertTrue(controllerSource.contains("rielaAppSettingsTitleLabel(title, maxWidth: 86)"))
    XCTAssertTrue(controllerSource.contains("popup.setAccessibilityLabel(title)"))
    XCTAssertFalse(controllerSource.contains("widthAnchor.constraint(equalToConstant: 86)"))
    XCTAssertTrue(controllerSource.contains("currentDirectoryRowSelected"))
    XCTAssertTrue(controllerSource.contains("environmentVariablesRowSelected"))
    XCTAssertTrue(controllerSource.contains("workflowVariablesRowSelected"))
    XCTAssertTrue(controllerSource.contains("accessibilityHelp: \"Change \\(title)\""))
    XCTAssertFalse(controllerSource.contains("accessibilityHelp: \"Open \\(title)\""))
    XCTAssertTrue(controllerSource.contains("rielaAppDisclosureIndicator()"))
    XCTAssertFalse(controllerSource.contains("labelWithString: \">\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Instance Dir...\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Instance Env...\""))
    XCTAssertFalse(controllerSource.contains("NSButton(title: \"Instance Variables...\""))
    XCTAssertFalse(controllerSource.contains("editing is unavailable for this viewer"))
    XCTAssertTrue(controllerSource.contains("Current directory cannot be edited here"))
    XCTAssertTrue(controllerSource.contains("Environment variables cannot be edited here"))
    XCTAssertTrue(controllerSource.contains("Workflow variables cannot be edited here"))
    XCTAssertTrue(controllerSource.contains("Node patches cannot be edited here"))
  }

  func testSelectableSettingsRowsExposeButtonAccessibilitySemantics() throws {
    let root = try repositoryRoot()
    let settingsRowStyleSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/RielaAppSettingsRowStyle.swift"),
      encoding: .utf8
    )
    let controllerRowSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/DaemonWorkflowWindowController+Rows.swift"),
      encoding: .utf8
    )
    let controllerPromptSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/DaemonWorkflowWindowController+Prompts.swift"),
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
    let workflowViewerSource = try String(
      contentsOf: root.appendingPathComponent("Sources/RielaApp/WorkflowViewerWindowController.swift"),
      encoding: .utf8
    )

    assertSelectableSettingsRowsExposeButtonSemantics(
      settingsRowStyleSource: settingsRowStyleSource,
      controllerRowSource: controllerRowSource,
      controllerPromptSource: controllerPromptSource,
      profileSelectSource: profileSelectSource,
      environmentSource: environmentSource,
      workflowViewerSource: workflowViewerSource
    )
  }

  @MainActor
  func testSelectableSettingsRowRunsConfiguredPressAction() throws {
    let target = SelectableSettingsRowTarget()
    let row = RielaAppSelectableSettingsRow(views: [NSTextField(labelWithString: "Relink Source")])
    rielaAppSelectableSettingsRow(
      row,
      target: target,
      action: #selector(SelectableSettingsRowTarget.press),
      accessibilityLabel: "Relink Source",
      accessibilityHelp: "Choose a workflow source"
    )

    XCTAssertEqual(row.accessibilityRole(), .button)
    XCTAssertEqual(row.accessibilityLabel(), "Relink Source")
    XCTAssertTrue(row.accessibilityPerformPress())
    XCTAssertEqual(target.pressCount, 1)
    let spaceEvent = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: " ",
      charactersIgnoringModifiers: " ",
      isARepeat: false,
      keyCode: 49
    ))
    row.keyDown(with: spaceEvent)
    XCTAssertEqual(target.pressCount, 2)
  }

  @MainActor
  func testSettingsRowAppliesAppearanceAwareGroupedStyle() {
    let row = RielaAppSettingsRow(views: [NSTextField(labelWithString: "Current Lines")])
    rielaAppSettingsRow(row)

    XCTAssertTrue(row.wantsLayer)
    XCTAssertEqual(row.layer?.cornerRadius, 8)
    XCTAssertNotNil(row.layer?.backgroundColor)
    row.viewDidChangeEffectiveAppearance()
    XCTAssertNotNil(row.layer?.backgroundColor)
  }

  func testMetadataTextUsesSettingsStyleReadableSeparators() {
    XCTAssertEqual(
      rielaAppMetadataText(["Chat Bot", "Ready", "Package source"]),
      "Chat Bot, Ready, Package source"
    )
    XCTAssertEqual(
      rielaAppMetadataText(["  Chat Bot  ", "", "Missing source"]),
      "Chat Bot, Missing source"
    )
  }

  @MainActor
  func testSelectableSettingsRowShowsKeyboardFocusFeedback() {
    let target = SelectableSettingsRowTarget()
    let row = RielaAppSelectableSettingsRow(views: [NSTextField(labelWithString: "Relink Source")])
    rielaAppSelectableSettingsRow(
      row,
      target: target,
      action: #selector(SelectableSettingsRowTarget.press),
      accessibilityLabel: "Relink Source"
    )
    let idleAlpha = row.layer?.backgroundColor?.alpha

    XCTAssertTrue(row.becomeFirstResponder())
    XCTAssertGreaterThan(row.layer?.backgroundColor?.alpha ?? 0, idleAlpha ?? 0)
    XCTAssertTrue(row.resignFirstResponder())
    XCTAssertEqual(row.layer?.backgroundColor?.alpha, idleAlpha)
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
}

private extension RielaAppInterfaceIdentifierTests {
  private func assertProfileSelectUsesSettingsRows(
    profileSelectSource: String,
    settingsRowStyleSource: String,
    controllerRowSource: String,
    environmentSource: String,
    settingsEditorSource: String,
    daemonInstancesSource: String
  ) {
    XCTAssertTrue(profileSelectSource.contains("window.title = \"Profiles\""))
    XCTAssertTrue(profileSelectSource.contains("static let menuTitle = \"Profiles...\""))
    XCTAssertFalse(profileSelectSource.contains("Profile Select"))
    XCTAssertFalse(profileSelectSource.contains("\"Available\""))
    XCTAssertTrue(profileSelectSource.contains("NSImage(systemSymbolName: \"checkmark\""))
    XCTAssertTrue(profileSelectSource.contains("rielaAppSettingsRow(rowStack)"))
    XCTAssertTrue(profileSelectSource.contains("actionRows.alignment = .width"))
    XCTAssertTrue(profileSelectSource.contains("let title = NSTextField(labelWithString: \"Profile Name\")"))
    XCTAssertTrue(profileSelectSource.contains("alert.messageText = \"Profile Name\""))
    XCTAssertTrue(profileSelectSource.contains("Create a saved profile for another instance set."))
    XCTAssertTrue(profileSelectSource.contains("alert.addButton(withTitle: \"Done\")"))
    XCTAssertTrue(profileSelectSource.contains("profileFieldRow(title: \"Name\", control: field)"))
    XCTAssertTrue(profileSelectSource.contains("rielaAppSettingsTitleLabel(title, maxWidth: 90)"))
    XCTAssertFalse(profileSelectSource.contains("field.frame = NSRect(x: 0, y: 0, width: 260"))
    XCTAssertFalse(profileSelectSource.contains("let title = NSTextField(labelWithString: \"Profile Settings\")"))
    XCTAssertFalse(profileSelectSource.contains("alert.messageText = \"Add Profile\""))
    XCTAssertFalse(profileSelectSource.contains("alert.addButton(withTitle: \"Add\")"))
    XCTAssertTrue(settingsRowStyleSource.contains("func rielaAppSettingsRow(_ row: NSStackView)"))
    XCTAssertTrue(settingsRowStyleSource.contains("func rielaAppSelectableSettingsRow("))
    XCTAssertTrue(settingsRowStyleSource.contains("class RielaAppSettingsRow: NSStackView"))
    XCTAssertTrue(settingsRowStyleSource.contains("override func viewDidChangeEffectiveAppearance()"))
    XCTAssertTrue(settingsRowStyleSource.contains("effectiveAppearance.performAsCurrentDrawingAppearance"))
    XCTAssertTrue(settingsRowStyleSource.contains("row.edgeInsets = NSEdgeInsets("))
    XCTAssertTrue(settingsRowStyleSource.contains("row.layer?.cornerRadius = 8"))
    XCTAssertTrue(settingsRowStyleSource.contains("NSColor.controlBackgroundColor"))
    XCTAssertTrue(controllerRowSource.contains("rielaAppSettingsRow(row)"))
    XCTAssertTrue(profileSelectSource.contains("rielaAppSettingsRow(row)"))
    XCTAssertTrue(settingsEditorSource.contains("rielaAppSettingsRow(currentRow)"))
    XCTAssertTrue(daemonInstancesSource.contains("rielaAppSettingsRow(row)"))
    XCTAssertTrue(profileSelectSource.contains("useProfileTitleLabel = NSTextField(labelWithString: \"Use Profile\")"))
    XCTAssertTrue(profileSelectSource.contains("title: \"Add Profile\""))
    XCTAssertTrue(profileSelectSource.contains("alert.addButton(withTitle: \"Remove Profile\")"))
    XCTAssertTrue(profileSelectSource.contains("Other profiles are unchanged."))
    XCTAssertFalse(profileSelectSource.contains("Remove profile \\(profileName.rawValue) and its workflow sources"))
    XCTAssertFalse(profileSelectSource.contains("Switch to Selected Profile"))
    XCTAssertFalse(profileSelectSource.contains("Remove Selected Profile"))
    XCTAssertFalse(profileSelectSource.contains("NSButton(title: \"+\""))
    XCTAssertFalse(profileSelectSource.contains("NSButton(title: \"-\""))
    XCTAssertFalse(profileSelectSource.contains("NSButton(title: \"Open\""))
    XCTAssertFalse(profileSelectSource.contains("NSButton(title: \"Cancel\""))
  }

  private func assertSelectableSettingsRowsExposeButtonSemantics(
    settingsRowStyleSource: String,
    controllerRowSource: String,
    controllerPromptSource: String,
    profileSelectSource: String,
    environmentSource: String,
    workflowViewerSource: String
  ) {
    XCTAssertTrue(settingsRowStyleSource.contains("func rielaAppSelectableSettingsRow("))
    XCTAssertTrue(settingsRowStyleSource.contains("final class RielaAppSelectableSettingsRow: RielaAppSettingsRow"))
    XCTAssertTrue(settingsRowStyleSource.contains("override func accessibilityPerformPress() -> Bool"))
    XCTAssertTrue(settingsRowStyleSource.contains("override func keyDown(with event: NSEvent)"))
    XCTAssertTrue(settingsRowStyleSource.contains("override func updateTrackingAreas()"))
    XCTAssertTrue(settingsRowStyleSource.contains("override func mouseEntered(with event: NSEvent)"))
    XCTAssertTrue(settingsRowStyleSource.contains("override func becomeFirstResponder() -> Bool"))
    XCTAssertTrue(settingsRowStyleSource.contains("override func resignFirstResponder() -> Bool"))
    XCTAssertTrue(settingsRowStyleSource.contains("isKeyboardFocused || isHovered"))
    XCTAssertTrue(settingsRowStyleSource.contains("NSApp.sendAction(action, to: actionTarget, from: self)"))
    XCTAssertTrue(settingsRowStyleSource.contains("row.setAccessibilityElement(true)"))
    XCTAssertTrue(settingsRowStyleSource.contains("row.setAccessibilityRole(.button)"))
    XCTAssertTrue(settingsRowStyleSource.contains("row.setAccessibilityLabel(accessibilityLabel)"))
    XCTAssertTrue(settingsRowStyleSource.contains("row.setAccessibilityHelp(accessibilityHelp)"))
    XCTAssertTrue(settingsRowStyleSource.contains("final class RielaAppTableSelectionCellView: NSTableCellView"))
    XCTAssertTrue(settingsRowStyleSource.contains("func configureSelection("))
    XCTAssertTrue(settingsRowStyleSource.contains("tableViewReference.selectRowIndexes"))
    XCTAssertTrue(controllerRowSource.contains("rielaAppSelectableSettingsRow("))
    XCTAssertTrue(controllerRowSource.contains("RielaAppSettingsRow(views: views)"))
    XCTAssertTrue(controllerRowSource.contains("RielaAppTableSelectionCellView()"))
    XCTAssertTrue(controllerRowSource.contains("accessibilityHelp: \"Show instance details\""))
    XCTAssertFalse(controllerRowSource.contains("accessibilityHelp: \"Open instance settings\""))
    XCTAssertTrue(controllerPromptSource.contains("rielaAppSelectableSettingsRow("))
    XCTAssertTrue(controllerPromptSource.contains("RielaAppSettingsRow(views: [titleLabel, control])"))
    XCTAssertTrue(controllerPromptSource.contains("target: rowTarget"))
    XCTAssertTrue(profileSelectSource.contains("rielaAppSelectableSettingsRow("))
    XCTAssertTrue(profileSelectSource.contains("RielaAppTableSelectionCellView()"))
    XCTAssertTrue(profileSelectSource.contains("accessibilityHelp: \"Use \\(profileName.rawValue) profile\""))
    XCTAssertTrue(settingsRowStyleSource.contains("func setRielaAccessibilityEnabled(_ enabled: Bool)"))
    XCTAssertTrue(settingsRowStyleSource.contains("guard rielaAccessibilityEnabled else"))
    XCTAssertTrue(profileSelectSource.contains("removeProfileActionRow?.setRielaAccessibilityEnabled(canRemove)"))
    XCTAssertFalse(profileSelectSource.contains("removeProfileActionRow?.alphaValue"))
    XCTAssertTrue(environmentSource.contains("RielaAppSettingsEditorWindowController.chooseAction("))
    XCTAssertTrue(workflowViewerSource.contains("return rielaAppSelectableSettingsRow("))
    XCTAssertTrue(workflowViewerSource.contains("RielaAppTableSelectionCellView()"))
    XCTAssertTrue(workflowViewerSource.contains("accessibilityHelp: \"Show workflow node details\""))
  }

  private func assertProfilePopupUsesAccessibleCompressibleControl(controllerSource: String) {
    XCTAssertFalse(controllerSource.contains("labelWithString: \"Profile\""))
    XCTAssertTrue(controllerSource.contains("profilePopup.setAccessibilityLabel(\"Profile\")"))
    XCTAssertTrue(controllerSource.contains("profilePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 220)"))
    XCTAssertTrue(controllerSource.contains("profilePopup.setContentCompressionResistancePriority(.defaultLow"))
    XCTAssertFalse(controllerSource.contains("profilePopup.widthAnchor.constraint(equalToConstant: 160)"))
  }

  private func assertStatusMenuUsesCompactSummaries(appSource: String) {
    XCTAssertFalse(appSource.contains("\"Status: \\(status)\""))
    XCTAssertFalse(appSource.contains("\"Profile: \\(daemonProfileName.rawValue)\""))
    XCTAssertFalse(appSource.contains("\"Instances: \\(daemonSummary())\""))
    XCTAssertFalse(appSource.contains("\"Launch on Login: \\(launchAtLogin.statusDescription)\""))
    XCTAssertTrue(appSource.contains("menuItem(\"Instances...\""))
    XCTAssertTrue(appSource.contains("supplementaryMenuItem(launchAtLoginDetail)"))
    XCTAssertTrue(appSource.contains("setActivationPolicy(.regular)"))
    XCTAssertTrue(appSource.contains("menu.addItem(supplementaryMenuItem(\n      rielaAppMetadataText([\"Instances \\(daemonSummary())\""))
    XCTAssertTrue(appSource.contains("\"Profile \\(daemonProfileName.rawValue)\"]"))
  }

  private func assertAddInstancePromptUsesSettingsFlow(
    controllerSource: String,
    controllerPromptSource: String,
    controllerUXSource: String
  ) {
    XCTAssertTrue(controllerPromptSource.contains("messageText = \"Choose Workflow\""))
    XCTAssertTrue(controllerPromptSource.contains("messageText = \"Configure Instance\""))
    XCTAssertFalse(controllerPromptSource.contains("messageText = \"Add Instance\""))
    XCTAssertTrue(controllerPromptSource.contains("promptForWorkflowSourceOption("))
    XCTAssertTrue(controllerPromptSource.contains("promptForInstanceParameters(sourceOption:"))
    XCTAssertTrue(controllerSource.contains("WorkflowSourceSelection"))
    XCTAssertTrue(controllerPromptSource.contains("case .retry:"))
    XCTAssertTrue(controllerPromptSource.contains("Choose a workflow source."))
    XCTAssertTrue(controllerPromptSource.contains("Enter instance parameters."))
    XCTAssertFalse(controllerPromptSource.contains("alert.addButton(withTitle: \"Next\")"))
    XCTAssertTrue(controllerPromptSource.contains("addInstanceValueRow(title: \"Workflow\""))
    XCTAssertTrue(controllerPromptSource.contains("addInstanceFieldRow(title: \"Instance ID\""))
    XCTAssertTrue(controllerPromptSource.contains("addInstanceFieldRow(title: \"Display Name\""))
    XCTAssertTrue(controllerPromptSource.contains("addInstanceFieldRow(title: \".env File\""))
    XCTAssertTrue(controllerPromptSource.contains("addInstanceFieldRow(title: \"Working Directory\""))
    XCTAssertTrue(controllerPromptSource.contains("addInstanceToggleRow(title: \"Start\""))
    XCTAssertTrue(controllerPromptSource.contains("NSButton(checkboxWithTitle: \"\""))
    XCTAssertTrue(controllerPromptSource.contains("startCheckbox.setAccessibilityLabel(\"Start\")"))
    XCTAssertTrue(controllerPromptSource.contains("Start this instance immediately after creating it."))
    XCTAssertFalse(controllerPromptSource.contains("checkboxWithTitle: \"Start now\""))
    XCTAssertTrue(controllerPromptSource.contains("Manage Sources"))
    XCTAssertTrue(controllerPromptSource.contains("sourceActionStack(context: .addInstance)"))
    XCTAssertFalse(controllerPromptSource.contains("alert.addButton(withTitle: \"Relink\")"))
    XCTAssertTrue(controllerPromptSource.contains("stack.alignment = .width"))
    XCTAssertTrue(controllerPromptSource.contains("title: \"Import Workflow or Package\""))
    XCTAssertTrue(controllerPromptSource.contains("title: \"Add Project Source\""))
    XCTAssertFalse(controllerUXSource.contains("alert.addButton(withTitle: \"Import Workflow or Package...\""))
    XCTAssertFalse(controllerUXSource.contains("alert.addButton(withTitle: \"Add Project Source...\""))
  }

  private func assertMissingSelectionCopyUsesUserFacingLanguage(
    appSource: String,
    controllerSource: String,
    environmentSource: String,
    daemonInstancesSource: String
  ) {
    let source = [appSource, controllerSource, environmentSource, daemonInstancesSource].joined(separator: "\n")
    XCTAssertFalse(source.contains("is no longer available"))
    XCTAssertFalse(source.contains("Selected instance could not be found"))
    XCTAssertFalse(source.contains("Selected workflow source could not be found"))
    XCTAssertFalse(source.contains("Selected instance needs a workflow source"))
    XCTAssertFalse((daemonInstancesSource + environmentSource).contains("inline env") || daemonInstancesSource.contains("Invalid env vars") || daemonInstancesSource.contains("Instance Environment Variables"))
    XCTAssertFalse(daemonInstancesSource.contains("title: \"Instance Variables\"") || daemonInstancesSource.contains("Updated instance variables") || daemonInstancesSource.contains("Invalid instance variables"))
    XCTAssertTrue(controllerSource.contains("Needs source"))
    XCTAssertFalse(controllerSource.contains("stringValue = \"Unavailable\""))
  }

  private func assertCompactInstanceWindowAndToolbar(controllerSource: String) {
    XCTAssertTrue(controllerSource.contains("window.title = \"Riela Workflow Instances\""))
    XCTAssertTrue(controllerSource.contains("initialWindowSize = NSSize(width: 760"))
    XCTAssertTrue(controllerSource.contains("minimumWindowSize = NSSize(width: 640"))
    XCTAssertFalse(controllerSource.contains("width: 700, height: 560"))
    XCTAssertFalse(controllerSource.contains("width: 980"))
    XCTAssertTrue(controllerSource.contains("NSImage(systemSymbolName: \"plus\""))
    XCTAssertTrue(controllerSource.contains("addListButton.setAccessibilityLabel(\"Add Instance\")"))
    XCTAssertTrue(controllerSource.contains("NSImage(systemSymbolName: \"arrow.clockwise\""))
    XCTAssertTrue(controllerSource.contains("refreshButton.setAccessibilityLabel(\"Refresh Instances\")"))
    XCTAssertFalse(controllerSource.contains("instancesList.topAnchor.constraint(equalTo: root.topAnchor, constant: 10)"))
    XCTAssertFalse(controllerSource.contains("toolbar.heightAnchor.constraint(equalToConstant:"))
    XCTAssertFalse(controllerSource.contains("toolbar.heightAnchor.constraint(equalToConstant: 42)"))
  }

  private func assertNeedsSourceRelinkContract(
    appSource: String,
    controllerSource: String,
    controllerUXSource: String,
    daemonInstancesSource: String
  ) {
    XCTAssertTrue(controllerUXSource.contains("title: \"Relink Source\""))
    XCTAssertTrue(controllerSource.contains("promptForRelinkSourceOption("))
    XCTAssertFalse(controllerSource.contains("guard !options.isEmpty else {\n      return\n    }"))
    XCTAssertTrue(controllerSource.contains("case .retry:\n        continue"))
    XCTAssertTrue(controllerUXSource.contains("return to relink this instance"))
    XCTAssertTrue(controllerSource.contains("updateDetailActions(for: row.state)"))
    XCTAssertTrue(controllerSource.contains("missingSourceSettingRow?.isHidden = !needsSource"))
    XCTAssertTrue(controllerSource.contains("workflowSettingRow?.isHidden = needsSource"))
    XCTAssertTrue(controllerSource.contains("detailMissingSourceValueLabel.stringValue"))
    XCTAssertTrue(controllerSource.contains("rielaAppMetadataText([\"Missing source\", row.sourceIdentity])"))
    XCTAssertTrue(controllerSource.contains("nameSettingRow?.isHidden = needsSource"))
    XCTAssertTrue(controllerSource.contains("environmentSettingRow?.isHidden = needsSource"))
    XCTAssertTrue(controllerSource.contains("inlineEnvironmentSettingRow?.isHidden = needsSource"))
    XCTAssertTrue(controllerSource.contains("workingDirectorySettingRow?.isHidden = needsSource"))
    XCTAssertTrue(controllerSource.contains("variablesSettingRow?.isHidden = needsSource"))
    XCTAssertTrue(controllerSource.contains("eventSourcesSettingRow?.isHidden = needsSource"))
    XCTAssertTrue(controllerSource.contains("relinkSourceActionRow?.isHidden = !needsSource"))
    XCTAssertTrue(controllerSource.contains("startInstanceActionRow?.isHidden = !showsStartAction(for: state)"))
    XCTAssertTrue(controllerSource.contains("stopInstanceActionRow?.isHidden = !showsStopAction(for: state)"))
    XCTAssertTrue(controllerSource.contains("restartInstanceActionRow?.isHidden = !showsRestartAction(for: state)"))
    XCTAssertTrue(controllerSource.contains("case .stopped, .failed:"))
    XCTAssertTrue(controllerSource.contains("case .running, .reloading:"))
    XCTAssertTrue(appSource.contains("onRelinkInstance:"))
    XCTAssertTrue(daemonInstancesSource.contains("relinkDaemonWorkflowInstance("))
    XCTAssertTrue(daemonInstancesSource.contains("preference.active = false"))
    XCTAssertTrue(daemonInstancesSource.contains("await daemonRuntime.stop(identity: identity)\n      status = \"Relinked"))
  }

  private func assertEnvironmentPromptsUseSettingsRows(environmentSource: String) {
    XCTAssertTrue(environmentSource.contains("RielaAppSettingsEditorWindowController.chooseAction("))
    XCTAssertTrue(environmentSource.contains("Choose File"))
    XCTAssertTrue(environmentSource.contains("Clear .env File"))
    XCTAssertTrue(environmentSource.contains("Choose Directory"))
    XCTAssertTrue(environmentSource.contains("Clear Directory Override"))
    XCTAssertTrue(environmentSource.contains("panel.title = \"Choose Working Directory\""))
    XCTAssertTrue(environmentSource.contains("panel.title = \"Choose .env File\""))
    XCTAssertTrue(environmentSource.contains("status = \"Cleared working directory"))
    XCTAssertTrue(environmentSource.contains("status = \"Choose a .env file"))
    XCTAssertTrue(environmentSource.contains("status = \"Cleared .env file"))
    XCTAssertTrue(environmentSource.contains("alert.messageText = \"Use .env File?\""))
    XCTAssertTrue(environmentSource.contains("alert.addButton(withTitle: \"Use .env File\")"))
    XCTAssertFalse(environmentSource.contains("environmentChoiceStack("))
    XCTAssertFalse(environmentSource.contains("EnvironmentPromptLayout"))
    XCTAssertFalse(environmentSource.contains("EnvironmentPromptViewFactory"))
    XCTAssertFalse(environmentSource.contains("environmentActionRow("))
    XCTAssertFalse(environmentSource.contains("alert.messageText = \".env File\""))
    XCTAssertFalse(environmentSource.contains("alert.messageText = \"Working Directory\""))
    XCTAssertFalse(environmentSource.contains("Review the current env file") || environmentSource.contains("no file") || environmentSource.contains("all required env set"))
    XCTAssertFalse(environmentSource.contains("Review the current directory override"))
    XCTAssertFalse(environmentSource.contains("Select Instance Directory"))
    XCTAssertFalse(environmentSource.contains("Select the current directory"))
    XCTAssertFalse(environmentSource.contains("Select the directory used"))
    XCTAssertFalse(environmentSource.contains("Select .env File"))
    XCTAssertFalse(environmentSource.contains("Select a .env file"))
    XCTAssertFalse(environmentSource.contains("Select a different .env file"))
    XCTAssertFalse(environmentSource.contains("Selected env file"))
    XCTAssertFalse(environmentSource.contains("Set instance directory"))
    XCTAssertFalse(environmentSource.contains("Cleared instance directory override"))
    XCTAssertFalse(environmentSource.contains("Cleared env file for instance"))
    XCTAssertFalse(environmentSource.contains("Use Credential Env File"))
    XCTAssertFalse(environmentSource.contains("credential material"))
    XCTAssertFalse(environmentSource.contains("labelWithString: \"Actions\""))
    XCTAssertFalse(environmentSource.contains("alert.addButton(withTitle: \"Choose File\""))
    XCTAssertFalse(environmentSource.contains("alert.addButton(withTitle: \"Choose Directory\""))
    XCTAssertFalse(environmentSource.contains("alert.addButton(withTitle: \"Clear\""))
  }

  private func assertSettingsRowLabelsCompressInNarrowPrompts(
    _ settingsRowStyleSource: String,
    _ controllerUXSource: String,
    _ profileSelectSource: String,
    _ environmentSource: String,
    _ daemonInstancesSource: String
  ) {
    XCTAssertTrue(settingsRowStyleSource.contains("rielaAppSettingsTitleLabel("))
    XCTAssertTrue(settingsRowStyleSource.contains("RielaAppSettingsRow"))
    XCTAssertTrue(settingsRowStyleSource.contains("lessThanOrEqualToConstant: maxWidth"))
    XCTAssertFalse(profileSelectSource.contains("greaterThanOrEqualToConstant: 360"))
    XCTAssertFalse(environmentSource.contains("greaterThanOrEqualToConstant: 500"))
    XCTAssertFalse(environmentSource.contains("greaterThanOrEqualToConstant: 320"))
    XCTAssertFalse(environmentSource.contains("width: 520"))
    XCTAssertFalse(daemonInstancesSource.contains("greaterThanOrEqualToConstant: 500"))
    XCTAssertFalse(daemonInstancesSource.contains("greaterThanOrEqualToConstant: 400"))
    XCTAssertFalse(daemonInstancesSource.contains("greaterThanOrEqualToConstant: 360"))
    XCTAssertFalse(daemonInstancesSource.contains("greaterThanOrEqualToConstant: 250"))
    XCTAssertFalse(controllerUXSource.contains("greaterThanOrEqualToConstant: 500"))
    XCTAssertFalse(controllerUXSource.contains("greaterThanOrEqualToConstant: 320"))
    XCTAssertFalse(controllerUXSource.contains("width: 520"))
    XCTAssertFalse(controllerUXSource.contains("widthAnchor.constraint(equalToConstant: 130)"))
    XCTAssertFalse(controllerUXSource.contains("widthAnchor.constraint(equalToConstant: 145)"))
    XCTAssertFalse(environmentSource.contains("widthAnchor.constraint(equalToConstant: 145)"))
    XCTAssertFalse(daemonInstancesSource.contains("widthAnchor.constraint(equalToConstant: 130)"))
  }

  private func assertWorkflowSourceSelectionRows(
    controllerSource: String,
    controllerPromptSource: String
  ) {
    XCTAssertTrue(controllerSource.contains("environmentStatus: env"))
    XCTAssertTrue(controllerSource.contains("location: candidate.workflowDirectory"))
    XCTAssertTrue(controllerPromptSource.contains("WorkflowSourceSelectionTarget"))
    XCTAssertTrue(controllerPromptSource.contains("AddInstancePromptLayout"))
    XCTAssertTrue(controllerPromptSource.contains("static let accessoryWidth: CGFloat = 480"))
    XCTAssertTrue(controllerPromptSource.contains("AddInstancePromptViewFactory"))
    XCTAssertTrue(controllerPromptSource.contains("AddInstancePromptViewFactory().accessoryStack("))
    XCTAssertTrue(controllerPromptSource.contains("stack.widthAnchor.constraint(lessThanOrEqualToConstant: size.width)"))
    XCTAssertTrue(controllerPromptSource.contains("WorkflowSourceSelectionRowTarget"))
    XCTAssertTrue(controllerPromptSource.contains("workflowSourceSelectionStack(options: options)"))
    XCTAssertTrue(controllerPromptSource.contains("workflowSourceOptionRow(option: option, index: index"))
    XCTAssertTrue(controllerPromptSource.contains("let scroll = NSScrollView()"))
    XCTAssertTrue(controllerPromptSource.contains("let document = FlippedDocumentView()"))
    XCTAssertTrue(controllerPromptSource.contains("preferredHeight.priority = .defaultLow"))
    XCTAssertFalse(controllerPromptSource.contains("scroll.heightAnchor.constraint(equalToConstant: min(CGFloat(options.count) * 70, 220)).isActive = true"))
    XCTAssertTrue(controllerPromptSource.contains("sourceList.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)"))
    XCTAssertTrue(controllerPromptSource.contains("withExtendedLifetime(sourceSelection.target)"))
    XCTAssertTrue(controllerPromptSource.contains("NSImage(systemSymbolName: \"checkmark\""))
    XCTAssertTrue(controllerPromptSource.contains("checkmark.isHidden = checkmarkIndex != selectedIndex"))
    XCTAssertTrue(controllerPromptSource.contains("return .selected(options[sourceSelection.target.selectedIndex])"))
    XCTAssertTrue(controllerPromptSource.contains("labelWithString: \"Workflow Sources\""))
    XCTAssertFalse(controllerPromptSource.contains("labelWithString: \"Selected Source\""))
    XCTAssertTrue(controllerPromptSource.contains("emptyWorkflowSelectionStack("))
    XCTAssertTrue(controllerPromptSource.contains("accessibilityHelp: \"Choose \\(option.candidate.displayName)\""))
    XCTAssertFalse(controllerPromptSource.contains("No Selectable Workflows"))
    XCTAssertFalse(controllerPromptSource.contains("Select workflow source"))
    XCTAssertTrue(controllerPromptSource.contains("option.candidate.displayName"))
    XCTAssertTrue(controllerPromptSource.contains("option.candidate.sourceDescription"))
    XCTAssertTrue(controllerPromptSource.contains("option.environmentStatus"))
    XCTAssertTrue(controllerPromptSource.contains("option.location"))
    XCTAssertFalse(controllerPromptSource.contains("NSPopUpButton()"))
  }

  private func assertSourcePickerOpenPanelsUseUserFacingCopy(appSource: String) {
    XCTAssertFalse(appSource.contains("Add Workflow or Package Source to RielaApp"))
    XCTAssertFalse(appSource.contains("Add Riela Project to Profile"))
    XCTAssertFalse(appSource.contains("Select one or more workflow folders"))
    XCTAssertFalse(appSource.contains("Select one or more project folders"))
    XCTAssertTrue(appSource.contains("panel.title = \"Add Workflow Source\""))
    XCTAssertTrue(
      appSource.contains(
        "panel.message = \"Choose workflow folders, package folders, .rielapkg files, or .zip packages.\""
      )
    )
    XCTAssertTrue(appSource.contains("panel.title = \"Add Project Source\""))
    XCTAssertTrue(
      appSource.contains(
        "panel.message = \"Choose project folders containing .riela/workflows or .riela/packages.\""
      )
    )
  }

  private func assertMetadataTextUsesReadableSeparators(
    settingsRowStyleSource: String,
    controllerSource: String,
    controllerRowSource: String,
    controllerPromptSource: String,
    controllerUXSource: String
  ) {
    XCTAssertTrue(settingsRowStyleSource.contains("func rielaAppMetadataText(_ parts: [String]) -> String"))
    XCTAssertTrue(controllerRowSource.contains("rielaAppMetadataText([row.workflowName, \"Missing source\", row.sourceIdentity])"))
    XCTAssertTrue(controllerRowSource.contains("rielaAppMetadataText([row.workflowName, environmentColumnStatus(candidate)"))
    XCTAssertTrue(controllerPromptSource.contains("rielaAppMetadataText([option.candidate.sourceDescription"))
    XCTAssertTrue(controllerSource.contains("rielaAppMetadataText([row.workflowName, row.sourceDescription])"))
    XCTAssertTrue(controllerSource.contains("rielaAppMetadataText([candidate.displayName, candidate.sourceDescription, env])"))
    XCTAssertFalse(controllerUXSource.contains(" | Missing source"))
    XCTAssertFalse(controllerUXSource.contains(" | \\(environmentColumnStatus(candidate))"))
    XCTAssertFalse(controllerUXSource.contains(" | \\(row.sourceDescription)"))
    XCTAssertFalse(controllerUXSource.contains(" | \\(env)"))
  }

  private func assertInstancePromptsUseCompactFrames(daemonInstancesSource: String) {
    XCTAssertTrue(daemonInstancesSource.contains("alert.addButton(withTitle: \"Done\")"))
    XCTAssertFalse(daemonInstancesSource.contains("alert.addButton(withTitle: \"Save\")"))
    XCTAssertTrue(daemonInstancesSource.contains("static let nameEditorSize = NSSize(width: 360, height: 104)"))
    XCTAssertTrue(daemonInstancesSource.contains("static let variableEditorSize = NSSize(width: 440, height: 225)"))
    XCTAssertTrue(daemonInstancesSource.contains("static let editorTextSize = NSSize(width: 380, height: 160)"))
    XCTAssertTrue(daemonInstancesSource.contains("stack.widthAnchor.constraint(lessThanOrEqualToConstant: size.width)"))
    XCTAssertFalse(daemonInstancesSource.contains("width: 420, height: 110"))
    XCTAssertFalse(daemonInstancesSource.contains("width: 460, height: 220"))
    XCTAssertFalse(daemonInstancesSource.contains("width: 520, height: 285"))
    XCTAssertFalse(daemonInstancesSource.contains("width: 400, height: 160"))
    XCTAssertFalse(daemonInstancesSource.contains("width: 460, height: 225"))
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

@MainActor
private final class SelectableSettingsRowTarget: NSObject {
  private(set) var pressCount = 0

  @objc func press() {
    pressCount += 1
  }
}
#endif
