#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class RielaAppWorkflowViewerSurfaceTests: XCTestCase {
  func testWorkflowViewerTextSurfacesUseGroupedNoBorderTreatment() throws {
    let controller = WorkflowViewerWindowController()
    let root = try XCTUnwrap(controller.window?.contentView)
    let tabView = try XCTUnwrap(firstSubview(of: NSTabView.self, in: root))

    try assertVisibleTextScrollsAreGrouped(in: root, minimumCount: 2)
    try selectTab(named: "Run Log", in: tabView)
    try assertVisibleTextScrollsAreGrouped(in: root, minimumCount: 1)
    try selectTab(named: "Structure", in: tabView)
    try assertVisibleTextScrollsAreGrouped(in: root, minimumCount: 1)
  }

  func testWorkflowViewerAssistantPanelSubmitsCurrentDirectoryAndPersistsState() throws {
    var savedSettings: RielaAppAssistantSettings?
    var submittedMessage: String?
    var submittedWorkingDirectory: String?
    let controller = WorkflowViewerWindowController()

    controller.show(
      workflowDirectory: "/workflows/demo",
      sessionStoreRoot: nil,
      currentDirectory: "/projects/demo",
      assistantProfileName: RielaAppProfileName("work"),
      assistantSettings: RielaAppAssistantSettings(
        vendor: .openAIAPI,
        model: "gpt-5",
        messages: [RielaAppAssistantMessage(role: .assistant, content: "Ready.")]
      ),
      onSaveAssistantSettings: { settings in
        savedSettings = settings
        return nil
      },
      onSubmitAssistantMessage: { message, workingDirectory in
        submittedMessage = message
        submittedWorkingDirectory = workingDirectory
      }
    )
    controller.window?.layoutIfNeeded()

    let root = try XCTUnwrap(controller.window?.contentView)
    XCTAssertEqual(controller.assistantFoldButton.accessibilityLabel(), "Help with Riela setup")
    XCTAssertEqual(controller.assistantFoldButton.toolTip, "Help with Riela setup")
    XCTAssertTrue(controller.assistantPanelTitleLabel.isHidden)
    XCTAssertTrue(controller.assistantTranscriptScrollView?.isHidden == true)
    XCTAssertEqual(controller.assistantPanelHost.subviews.first?.frame.width, RielaAssistantMiniChatStyle.foldedPanelWidth)

    controller.toggleAssistantFolded()
    controller.window?.layoutIfNeeded()

    XCTAssertEqual(savedSettings?.isFolded, false)
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Riela Setup Assistant" })
    XCTAssertEqual(controller.assistantPromptField.placeholderString, "Ask for help with Riela setup")
    XCTAssertTrue(controller.assistantTranscriptTextView?.string.contains("Ready.") == true)

    controller.assistantPromptField.stringValue = "Explain this workflow"
    controller.sendAssistantMessage()
    XCTAssertEqual(submittedMessage, "Explain this workflow")
    XCTAssertEqual(submittedWorkingDirectory, "/projects/demo")

    controller.toggleAssistantFolded()
    XCTAssertEqual(savedSettings?.isFolded, true)
    XCTAssertEqual(controller.assistantTranscriptScrollView?.isHidden, true)
  }

  func testWorkflowViewerMinimumWidthKeepsAssistantUsableAtRuntime() throws {
    let controller = WorkflowViewerWindowController()
    controller.show(
      workflowDirectory: "/workflows/demo",
      sessionStoreRoot: nil,
      assistantSettings: RielaAppAssistantSettings(
        isFolded: false,
        messages: [RielaAppAssistantMessage(role: .assistant, content: "Ready.")]
      )
    )
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false)
    window.layoutIfNeeded()

    XCTAssertEqual(window.minSize, NSSize(width: 560, height: 380))
    XCTAssertGreaterThanOrEqual(controller.assistantPanelHost.frame.width, 536)
    XCTAssertGreaterThanOrEqual(controller.assistantPromptField.frame.width, 420)
    let titleFrame = controller.assistantPanelTitleLabel.convert(
      controller.assistantPanelTitleLabel.bounds,
      to: controller.assistantPanelHost
    )
    let foldFrame = controller.assistantFoldButton.convert(
      controller.assistantFoldButton.bounds,
      to: controller.assistantPanelHost
    )
    XCTAssertLessThan(titleFrame.minX, foldFrame.minX)
    XCTAssertGreaterThanOrEqual(foldFrame.maxX, controller.assistantPanelHost.bounds.width - 60)
  }

  func testWorkflowViewerAssistantClearButtonReflectsPersistedMessages() throws {
    let controller = WorkflowViewerWindowController()
    controller.show(
      workflowDirectory: "/workflows/demo",
      sessionStoreRoot: nil,
      assistantSettings: RielaAppAssistantSettings(
        messages: [RielaAppAssistantMessage(role: .assistant, content: "Old context.")]
      ),
      onSaveAssistantSettings: { _ in nil }
    )
    controller.window?.layoutIfNeeded()

    let root = try XCTUnwrap(controller.window?.contentView)
    let clearButton = try XCTUnwrap(
      allSubviews(of: NSButton.self, in: root).first { $0.accessibilityLabel() == "Clear Assistant History" }
    )

    XCTAssertTrue(clearButton.isEnabled)

    controller.updateAssistantPanel(
      settings: RielaAppAssistantSettings(messages: []),
      profileName: RielaAppProfileName("work")
    )

    XCTAssertFalse(clearButton.isEnabled)
  }

  private func assertVisibleTextScrollsAreGrouped(in root: NSView, minimumCount: Int) throws {
    let scrolls = allSubviews(of: NSScrollView.self, in: root).filter { scroll in
      !hasHiddenAncestor(scroll) && scroll.documentView is NSTextView
    }
    XCTAssertGreaterThanOrEqual(scrolls.count, minimumCount)
    for scroll in scrolls {
      XCTAssertTrue(scroll.borderType == NSBorderType.noBorder)
      XCTAssertEqual(scroll.layer?.cornerRadius, 12)
      XCTAssertEqual(scroll.layer?.masksToBounds, true)
    }
  }

  private func selectTab(named label: String, in tabView: NSTabView) throws {
    guard let item = tabView.tabViewItems.first(where: { $0.label == label }) else {
      throw NSError(
        domain: "RielaAppWorkflowViewerSurfaceTests",
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

  private func visibleTextFields(in root: NSView) -> [NSTextField] {
    allSubviews(of: NSTextField.self, in: root).filter { !hasHiddenAncestor($0) }
  }

  private func hasHiddenAncestor(_ view: NSView) -> Bool {
    if view.isHidden {
      return true
    }
    guard let superview = view.superview else {
      return false
    }
    return hasHiddenAncestor(superview)
  }
}
#endif
