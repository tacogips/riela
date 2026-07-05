#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore
import RielaServer
import RielaViewer
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppBehaviorRegressionTests: XCTestCase {
  func testInstanceListDoesNotExposeLegacySourceColumnsAtRuntime() throws {
    let controller = makeDaemonController()
    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    let identifiers = Set(table.tableColumns.map(\.identifier.rawValue))

    XCTAssertTrue(identifiers.contains("instance"))
    XCTAssertFalse(identifiers.contains("source"))
    XCTAssertFalse(identifiers.contains("sources"))
    XCTAssertNil(table.headerView)
  }

  func testInstanceListShowsProfileAndCanClearProfileFilterAtRuntime() throws {
    let controller = makeDaemonController()
    let defaultInstance = profiledInstance(profileName: .default, identity: "daily", displayName: "Daily")
    let workInstance = profiledInstance(profileName: RielaAppProfileName("work"), identity: "daily", displayName: "Work Daily")

    controller.update(
      profileName: .default,
      profileNames: [.default, RielaAppProfileName("work")],
      candidates: [defaultInstance.instance.candidate],
      workflowSources: [defaultInstance.instance.source],
      profileWorkflowSources: [
        .default: [defaultInstance.instance.source],
        RielaAppProfileName("work"): [workInstance.instance.source]
      ],
      profileInstances: [defaultInstance, workInstance],
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )

    XCTAssertTrue(controller.profilePopup.itemTitles.contains("All Profiles"))
    XCTAssertTrue(controller.profilePopup.itemTitles.contains("default"))
    XCTAssertFalse(controller.profilePopup.itemTitles.contains(ProfileSelectWindowController.menuTitle))
    XCTAssertEqual(controller.instanceRows.map(\.profileName), [.default])

    controller.profilePopup.selectItem(withTitle: "All Profiles")
    controller.profilePopupChanged()

    XCTAssertEqual(controller.profileFilterName, nil)
    XCTAssertEqual(controller.instanceRows.map(\.profileName), [.default, RielaAppProfileName("work")])
    XCTAssertEqual(
      controller.workflowSourceOptions(profileName: RielaAppProfileName("work")).map(\.sourceIdentity),
      [workInstance.instance.source.sourceIdentity]
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    _ = table.view(atColumn: 0, row: 1, makeIfNecessary: true)
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue.contains("Profile work") })

    controller.showProfilesPane()
    XCTAssertTrue(controller.activeSidebarPane == .profiles)
  }

  func testInstanceListUsesWarningIconForMissingEnvironmentAndHidesSourceDescription() throws {
    let controller = makeDaemonController(environmentColumnStatus: { _ in "Missing 1" })
    let source = RielaAppDaemonWorkflowCandidate(
      id: "app-package:chat:bot",
      workflowId: "bot",
      displayName: "Chat Bot",
      sourceDescription: "profile package",
      workflowDirectory: "/workflows/chat",
      packageDirectory: "/packages/chat",
      workingDirectory: "/work",
      eventRoot: nil,
      eventSources: [],
      requiredEnvironment: [RielaAppEnvRequirement(name: "RIELA_TOKEN")]
    )
    var state = RielaAppDaemonWorkflowState()
    state.preferences["chat"] = RielaAppDaemonWorkflowPreference(
      identity: "chat",
      sourceIdentity: source.id,
      displayName: "Chat",
      available: true,
      active: false
    )

    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [source],
      workflowSources: [source],
      state: state,
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    _ = table.view(atColumn: 0, row: 0, makeIfNecessary: true)

    XCTAssertFalse(visibleTextFields(in: root).contains { $0.stringValue.contains("Missing 1") })
    XCTAssertFalse(visibleTextFields(in: root).contains { $0.stringValue.contains("profile package") })
    let warningIcon = allSubviews(of: NSImageView.self, in: root).first {
      $0.accessibilityLabel() == "Missing required environment variables"
    }
    XCTAssertEqual(warningIcon?.toolTip, "Missing 1")
    XCTAssertEqual(warningIcon?.accessibilityHelp(), "Missing 1")
  }

  func testInstanceRowsAreCachedBetweenTableQueriesAtRuntime() throws {
    var environmentStatusCalls = 0
    let controller = makeDaemonController(environmentColumnStatus: { _ in
      environmentStatusCalls += 1
      return "Ready"
    })
    let instances = (0..<12).map { index in
      profiledInstance(profileName: .default, identity: "daily-\(index)", displayName: "Daily \(index)")
    }

    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: instances.map(\.instance.candidate),
      workflowSources: instances.map(\.instance.source),
      profileWorkflowSources: [.default: instances.map(\.instance.source)],
      profileInstances: instances,
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )

    XCTAssertEqual(environmentStatusCalls, instances.count)
    XCTAssertEqual(controller.instanceRows.count, instances.count)
    XCTAssertEqual(controller.numberOfRows(in: controller.instanceTable), instances.count)
    _ = controller.instanceRows.map(\.instanceName)
    XCTAssertEqual(environmentStatusCalls, instances.count)
  }

  func testProfileQualifiedInstanceConfigurationUsesSelectedProfileStateAndWorkingDirectory() throws {
    let temp = try scratchRoot(name: "riela-app-profile-qualified-instance-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let appRoot = temp.appendingPathComponent("app-root", isDirectory: true)
    let workProfile = RielaAppProfileName("work")
    let app = RielaApp()
    app.profileStore = RielaAppProfileStore(appRootURL: appRoot)
    app.daemonProfileName = .default
    try app.profileStore.prepareInitialProfile(.default, persistsSelection: false)
    try app.profileStore.prepareInitialProfile(workProfile, persistsSelection: false)

    let defaultWorkflowDirectory = RielaAppProfileStore.workflowRootURL(
      appRootURL: appRoot,
      profileName: .default
    ).appendingPathComponent("daily-default", isDirectory: true)
    let workWorkflowRoot = RielaAppProfileStore.workflowRootURL(appRootURL: appRoot, profileName: workProfile)
    let workWorkflowDirectory = workWorkflowRoot.appendingPathComponent("daily-work", isDirectory: true)
    try FileManager.default.createDirectory(at: defaultWorkflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workWorkflowDirectory, withIntermediateDirectories: true)
    try writeWorkflow(id: "daily-default", to: defaultWorkflowDirectory)
    try writeWorkflow(id: "daily-work", to: workWorkflowDirectory)

    app.daemonState = RielaAppDaemonWorkflowState(preferences: [
      "daily": RielaAppDaemonWorkflowPreference(
        identity: "daily",
        sourceIdentity: "app-workflow:daily-default",
        displayName: "Default Daily",
        available: true,
        active: false,
        workingDirectory: temp.appendingPathComponent("default-work", isDirectory: true).path
      )
    ])
    try app.makeDaemonStore(profileName: .default).save(app.daemonState)
    try app.makeDaemonStore(profileName: workProfile).save(RielaAppDaemonWorkflowState(preferences: [
      "daily": RielaAppDaemonWorkflowPreference(
        identity: "daily",
        sourceIdentity: "app-workflow:daily-work",
        displayName: "Work Daily",
        available: true,
        active: false
      )
    ]))

    let workIdentity = RielaAppProfileInstanceIdentity(profileName: workProfile, identity: "daily").rawValue
    let resolved = try XCTUnwrap(app.resolveDaemonWorkflowInstance(identity: workIdentity))

    XCTAssertEqual(resolved.profileName, workProfile)
    XCTAssertEqual(resolved.localIdentity, "daily")
    XCTAssertEqual(resolved.candidate.workflowDirectory, workWorkflowDirectory.path)
    XCTAssertEqual(resolved.candidate.workingDirectory, workWorkflowRoot.path)
    XCTAssertEqual(
      app.daemonRuntimeConfiguration(for: resolved.candidate, preference: resolved.preference).workingDirectory,
      workWorkflowRoot.path
    )

    XCTAssertNil(app.saveDaemonWorkflowEnvironmentVariables(identity: workIdentity, text: "PERSONA=work"))
    XCTAssertNil(app.saveDaemonWorkflowDefaultVariables(identity: workIdentity, text: "persona=work"))
    XCTAssertTrue(app.saveDaemonNodePatch(
      identity: workIdentity,
      nodeId: "worker",
      patch: RielaAppDaemonWorkflowNodePatch(model: "gpt-5-mini")
    ))

    let savedWorkState = app.makeDaemonStore(profileName: workProfile).load()
    let savedDefaultState = app.makeDaemonStore(profileName: .default).load()
    XCTAssertEqual(savedWorkState.preference(for: "daily").environmentVariables["PERSONA"], "work")
    XCTAssertEqual(savedWorkState.preference(for: "daily").defaultVariables["persona"], .string("work"))
    XCTAssertEqual(savedWorkState.preference(for: "daily").nodePatches["worker"]?.model, "gpt-5-mini")
    XCTAssertEqual(savedDefaultState.preference(for: "daily").displayName, "Default Daily")
    XCTAssertNil(savedDefaultState.preference(for: "daily").environmentVariables["PERSONA"])
  }

  func testProfileQualifiedInstancesWithSameLocalIdentityCanRunConcurrently() async throws {
    let temp = try scratchRoot(name: "riela-app-profile-runtime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let defaultWorkflowDirectory = temp.appendingPathComponent("default/workflow", isDirectory: true)
    let workWorkflowDirectory = temp.appendingPathComponent("work/workflow", isDirectory: true)
    try FileManager.default.createDirectory(at: defaultWorkflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workWorkflowDirectory, withIntermediateDirectories: true)
    try writeWorkflow(id: "profile-runtime", to: defaultWorkflowDirectory)
    try writeWorkflow(id: "profile-runtime", to: workWorkflowDirectory)

    let defaultInstance = profiledRuntimeInstance(
      profileName: .default,
      workflowDirectory: defaultWorkflowDirectory
    )
    let workInstance = profiledRuntimeInstance(
      profileName: RielaAppProfileName("work"),
      workflowDirectory: workWorkflowDirectory
    )

    XCTAssertEqual(defaultInstance.localIdentity, "daily")
    XCTAssertEqual(workInstance.localIdentity, "daily")
    XCTAssertNotEqual(defaultInstance.id, workInstance.id)

    let runtime = RielaAppDaemonWorkflowRuntime(monitorIntervalNanoseconds: 0)
    await runtime.start(defaultInstance.runtimeCandidate, configuration: WorkflowServeRuntimeConfiguration())
    await runtime.start(workInstance.runtimeCandidate, configuration: WorkflowServeRuntimeConfiguration())

    XCTAssertEqual(runtime.snapshot(for: defaultInstance.id).status, .running)
    XCTAssertEqual(runtime.snapshot(for: workInstance.id).status, .running)

    await runtime.stopAll()
    XCTAssertEqual(runtime.snapshot(for: defaultInstance.id).status, .stopped)
    XCTAssertEqual(runtime.snapshot(for: workInstance.id).status, .stopped)
  }

  func testStatusMenuUsesCompactSummaryItemsAtRuntime() throws {
    let app = RielaApp()
    app.daemonProfileName = RielaAppProfileName("work")
    app.daemonState.preferences = [
      "running-one": RielaAppDaemonWorkflowPreference(
        identity: "running-one",
        sourceIdentity: "source-running",
        displayName: "Running One",
        available: true,
        active: true
      ),
      "missing-one": RielaAppDaemonWorkflowPreference(
        identity: "missing-one",
        sourceIdentity: "source-missing",
        displayName: "Missing One",
        available: true,
        active: false
      )
    ]
    app.daemonCandidates = [
      RielaAppDaemonWorkflowCandidate(
        id: "source-running",
        workflowId: "running",
        displayName: "Running",
        sourceDescription: "test source",
        workflowDirectory: "/tmp/running",
        workingDirectory: "/tmp",
        eventRoot: nil,
        eventSources: []
      )
    ]

    app.rebuildMenu()

    let menu = app.statusItem.menu
    XCTAssertEqual(menu?.items.first?.title, "Instances...")
    XCTAssertEqual(menu?.items.first?.target as? RielaApp, app)
    XCTAssertTrue(menu?.items.contains { $0.title == "Launch on Login" } == true)
    let aboutItem = try XCTUnwrap(menu?.items.first { $0.title == "About Riela" })
    XCTAssertEqual(aboutItem.target as? RielaApp, app)
    XCTAssertFalse(menu?.items.contains { $0.title.hasPrefix("Status:") } == true)
    XCTAssertFalse(menu?.items.contains { $0.title.hasPrefix("Profile:") } == true)
    XCTAssertFalse(menu?.items.contains { $0.title.hasPrefix("Instances:") } == true)

    let summaryItem = try XCTUnwrap(menu?.items.first { item in
      item.title.contains("Instances ") && item.title.contains("Profile work")
    })
    XCTAssertEqual(summaryItem.isEnabled, false)
    XCTAssertEqual(summaryItem.toolTip, summaryItem.title)
  }

  func testAddInstanceSelectionUsesInlinePaneAndNoWorkflowPopupAtRuntime() throws {
    let controller = makeDaemonController()
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:daily-summary",
      workflowId: "daily-summary",
      displayName: "Daily Summary",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/daily-summary",
      workingDirectory: "/workflows",
      eventRoot: nil,
      eventSources: []
    )
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [source],
      workflowSources: [source],
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    let addButton = try XCTUnwrap(button(accessibilityLabel: "Add Instance", in: root))
    addButton.performClick(nil)
    controller.window?.layoutIfNeeded()

    XCTAssertNil(controller.activeAddInstanceWindow)
    XCTAssertEqual(controller.navigationTitleLabel.stringValue, "Choose Workflow")
    XCTAssertEqual(controller.instancesListView?.isHidden, true)
    XCTAssertEqual(controller.addInstanceSelectionView?.isHidden, false)
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Choose Workflow" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Daily Summary" })

    controller.goBack()
    controller.window?.layoutIfNeeded()
    XCTAssertEqual(controller.navigationTitleLabel.stringValue, "Instances")
    XCTAssertEqual(controller.instancesListView?.isHidden, false)
    XCTAssertEqual(controller.addInstanceSelectionView?.isHidden, true)
  }

  func testInstanceDetailDoesNotRenderLegacyInlineBackButtonAtRuntime() throws {
    let controller = makeDaemonController()
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:daily-summary",
      workflowId: "daily-summary",
      displayName: "Daily Summary",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/daily-summary",
      workingDirectory: "/workflows",
      eventRoot: nil,
      eventSources: []
    )
    var state = RielaAppDaemonWorkflowState()
    state.preferences["morning-summary"] = RielaAppDaemonWorkflowPreference(
      identity: "morning-summary",
      sourceIdentity: source.id,
      displayName: "Morning Summary",
      available: true,
      active: false
    )
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [source],
      workflowSources: [source],
      state: state,
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    controller.selectCandidate(identity: "morning-summary")

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Current Settings" })
    XCTAssertNil(button(accessibilityLabel: "Back to Instances", in: root))
    XCTAssertFalse(visibleTextFields(in: root).contains { $0.stringValue == "< Instances" })
  }

  func testWorkflowViewerTabsAndEditableRowsAtRuntime() throws {
    let temp = try scratchRoot(name: "riela-app-behavior-viewer-\(UUID().uuidString)")
    let workflowDirectory = temp.appendingPathComponent("workflows/demo", isDirectory: true)
    let sessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    let runtimeRoot = sessionStoreRoot.appendingPathComponent("runtime-records", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    try writeWorkflow(id: "viewer-contract", to: workflowDirectory)
    try saveSessions([
      workflowSession(id: "contract-session", stepId: "first", updatedAt: Date(timeIntervalSince1970: 10))
    ], runtimeRoot: runtimeRoot)

    let controller = WorkflowViewerWindowController()
    controller.show(
      workflowDirectory: workflowDirectory.path,
      sessionStoreRoot: sessionStoreRoot.path,
      onSetWorkingDirectory: { "/tmp/work" },
      onSetEnvironmentVariables: { "1 variable" },
      onSetWorkflowVariables: { "2 variables" }
    )
    let root = try XCTUnwrap(controller.window?.contentView)
    let tabView = try XCTUnwrap(firstSubview(of: NSTabView.self, in: root))
    XCTAssertEqual(tabView.tabViewItems.map(\.label), ["Overview", "Variables", "Graph", "Run Log", "Structure"])
    XCTAssertTrue(controller.hasLiveRefreshTimerForTesting)
    XCTAssertEqual(controller.window?.minSize, NSSize(width: 560, height: 380))

    let popUpLabels = Set(visiblePopUpButtons(in: root).compactMap { $0.accessibilityLabel() })
    XCTAssertTrue(popUpLabels.contains("Session"))
    XCTAssertTrue(popUpLabels.contains("Template"))

    try selectTab(named: "Variables", in: tabView)
    controller.window?.layoutIfNeeded()
    let currentDirectoryRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Current Directory", in: root))
    XCTAssertEqual(currentDirectoryRow.accessibilityRole(), .button)
    XCTAssertEqual(currentDirectoryRow.accessibilityHelp(), "Change Current Directory")
    XCTAssertTrue(currentDirectoryRow.rielaAccessibilityEnabled)

    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
    XCTAssertFalse(controller.hasLiveRefreshTimerForTesting)
  }

  func testWorkflowViewerTreeRowsExposeStateAndPressActionAtRuntime() throws {
    let temp = try scratchRoot(name: "riela-app-behavior-tree-\(UUID().uuidString)")
    let workflowDirectory = temp.appendingPathComponent("workflows/demo", isDirectory: true)
    let sessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    let runtimeRoot = sessionStoreRoot.appendingPathComponent("runtime-records", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    try writeWorkflow(id: "viewer-tree", to: workflowDirectory)
    try saveSessions([
      workflowSession(
        workflowId: "viewer-tree",
        id: "tree-session",
        stepId: "first",
        updatedAt: Date(timeIntervalSince1970: 12)
      )
    ], runtimeRoot: runtimeRoot)

    let controller = WorkflowViewerWindowController()
    controller.show(workflowDirectory: workflowDirectory.path, sessionStoreRoot: sessionStoreRoot.path)
    let root = try XCTUnwrap(controller.window?.contentView)
    let outlineView = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: root))
    let secondRow = try XCTUnwrap((0..<outlineView.numberOfRows).first { row in
      (outlineView.item(atRow: row) as? WorkflowViewerNode)?.nodeId == "second"
    })
    let cell = try XCTUnwrap(
      outlineView.view(atColumn: 0, row: secondRow, makeIfNecessary: true) as? RielaAppTableSelectionCellView
    )

    XCTAssertEqual(cell.accessibilityRole(), .button)
    XCTAssertEqual(cell.accessibilityLabel(), "second")
    XCTAssertEqual(cell.accessibilityValue() as? String, "Idle")
    XCTAssertEqual(cell.accessibilityHelp(), "Show workflow node details")
    XCTAssertTrue(cell.accessibilityPerformPress())
    XCTAssertEqual(outlineView.selectedRow, secondRow)
  }

  func testSelectableSettingsRowBaseSemanticsAtRuntime() {
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
    XCTAssertEqual(row.accessibilityHelp(), "Choose a workflow source")
    XCTAssertTrue(row.acceptsFirstResponder)
    XCTAssertTrue(row.accessibilityPerformPress())
    XCTAssertEqual(target.pressCount, 1)
    row.setRielaAccessibilityEnabled(false)
    XCTAssertFalse(row.accessibilityPerformPress())
    XCTAssertEqual(target.pressCount, 1)
  }

  private func makeDaemonController(
    environmentColumnStatus: @escaping (RielaAppDaemonWorkflowCandidate) -> String = { _ in "Ready" }
  ) -> DaemonWorkflowWindowController {
    DaemonWorkflowWindowController(
      onRefresh: {},
      onSelectProfile: { _ in },
      onCreateProfile: { RielaAppProfileName($0) },
      onRemoveProfile: { _ in true },
      onAddDirectory: {},
      onAddURL: { _ in },
      onAddInstance: { _ in },
      onRevealSelectedSource: { _ in },
      onRelinkInstance: { _, _ in },
      onRenameWorkflow: { _ in },
      onRemoveInstance: { _ in },
      onStartInstance: { _ in },
      onStopInstance: { _ in },
      onRestartInstance: { _ in },
      onSetEnvironment: { _ in },
      onSetWorkingDirectory: { _ in },
      onSaveEnvironmentVariables: { _, _ in nil },
      onSaveWorkflowVariables: { _, _ in nil },
      onRegisterEventSource: { _, _, _ in nil },
      configuredEnvironmentValues: { _ in [] },
      onSaveAssistantAssistance: { _ in nil },
      environmentSummary: { _ in "Ready" },
      environmentColumnStatus: environmentColumnStatus,
      onWindowWillClose: {}
    )
  }

  private func writeWorkflow(id: String, to workflowDirectory: URL) throws {
    let workflow = WorkflowDefinition(
      workflowId: id,
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first"), WorkflowNodeRegistryRef(id: "second")],
      steps: [
        WorkflowStepRef(id: "first", nodeId: "first", transitions: [WorkflowStepTransition(toStepId: "second")]),
        WorkflowStepRef(id: "second", nodeId: "second")
      ],
      nodes: [
        WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json"),
        WorkflowNodeRef(id: "second", nodeFile: "nodes/second.json")
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))
  }

  private func workflowSession(
    workflowId: String = "viewer-contract",
    id: String,
    stepId: String,
    updatedAt: Date
  ) -> WorkflowSession {
    WorkflowSession(
      workflowId: workflowId,
      sessionId: id,
      status: .running,
      entryStepId: "first",
      currentStepId: stepId,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      executions: [WorkflowStepExecution(
        executionId: "exec-\(id)",
        stepId: stepId,
        nodeId: stepId,
        attempt: 1,
        status: .running,
        createdAt: updatedAt,
        updatedAt: updatedAt
      )]
    )
  }

  private func saveSessions(_ sessions: [WorkflowSession], runtimeRoot: URL) throws {
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot.path)
    for session in sessions {
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
    }
  }

  private func scratchRoot(name: String) throws -> URL {
    let root = try repositoryRoot().appendingPathComponent("tmp", isDirectory: true)
    let scratch = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
  }

  private func profiledInstance(
    profileName: RielaAppProfileName,
    identity: String,
    displayName: String
  ) -> RielaAppProfiledWorkflowInstance {
    let source = RielaAppDaemonWorkflowCandidate(
      id: "source-\(profileName.rawValue)-\(identity)",
      workflowId: "workflow-\(identity)",
      displayName: "\(displayName) Workflow",
      sourceDescription: "profile workflow",
      workflowDirectory: "/workflows/\(profileName.rawValue)/\(identity)",
      workingDirectory: "/work/\(profileName.rawValue)",
      eventRoot: nil,
      eventSources: []
    )
    var state = RielaAppDaemonWorkflowState()
    state.preferences[identity] = RielaAppDaemonWorkflowPreference(
      identity: identity,
      sourceIdentity: source.id,
      displayName: displayName,
      available: true,
      active: false
    )
    let instance = state.workflowInstances(from: [source]).first { $0.identity == identity }
    return RielaAppProfiledWorkflowInstance(profileName: profileName, instance: instance ?? .unconfigured(source: source))
  }

  private func profiledRuntimeInstance(
    profileName: RielaAppProfileName,
    workflowDirectory: URL
  ) -> RielaAppProfiledWorkflowInstance {
    let source = RielaAppDaemonWorkflowCandidate(
      id: "app-workflow:profile-runtime",
      workflowId: "profile-runtime",
      displayName: "Profile Runtime",
      sourceDescription: "profile workflow",
      sourceScope: .profile,
      workflowDirectory: workflowDirectory.path,
      workingDirectory: workflowDirectory.deletingLastPathComponent().path,
      eventRoot: nil,
      eventSources: []
    )
    let instance = WorkflowInstance.configured(
      identity: "daily",
      source: source,
      preference: RielaAppDaemonWorkflowPreference(
        identity: "daily",
        sourceIdentity: source.id,
        displayName: "\(profileName.rawValue) Daily",
        available: true,
        active: true
      )
    )
    return RielaAppProfiledWorkflowInstance(profileName: profileName, instance: instance)
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
      domain: "RielaAppBehaviorRegressionTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"]
    )
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

  private func button(accessibilityLabel: String, in root: NSView) -> NSButton? {
    allSubviews(of: NSButton.self, in: root).first { button in
      button.accessibilityLabel() == accessibilityLabel
    }
  }

  private func visibleTextFields(in root: NSView) -> [NSTextField] {
    allSubviews(of: NSTextField.self, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func visiblePopUpButtons(in root: NSView) -> [NSPopUpButton] {
    allSubviews(of: NSPopUpButton.self, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func selectableRow(accessibilityLabel: String, in root: NSView) -> RielaAppSelectableSettingsRow? {
    allSubviews(of: RielaAppSelectableSettingsRow.self, in: root).first { row in
      !row.hasHiddenAncestor &&
        row.accessibilityLabel() == accessibilityLabel &&
        row.accessibilityRole() == .button
    }
  }

  private func selectTab(named label: String, in tabView: NSTabView) throws {
    guard let item = tabView.tabViewItems.first(where: { $0.label == label }) else {
      throw NSError(
        domain: "RielaAppBehaviorRegressionTests",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Tab not found: \(label)"]
      )
    }
    tabView.selectTabViewItem(item)
  }

  private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    let current = (root as? T).map { [$0] } ?? []
    return current + root.subviews.flatMap { allSubviews(of: type, in: $0) }
  }
}

@MainActor
private final class SelectableSettingsRowTarget: NSObject {
  private(set) var pressCount = 0

  @objc func press() {
    pressCount += 1
  }
}

private extension NSView {
  var hasHiddenAncestor: Bool {
    isHidden || superview?.hasHiddenAncestor == true
  }
}
#endif
