#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class RielaAppMarketplaceLayoutTests: XCTestCase {
  func testMarketplacePaneFiltersWorkflowListByPartialTextAtRuntime() throws {
    let controller = makeController()
    let root = try XCTUnwrap(controller.window?.contentView)
    let repository = try RielaAppWorkflowRepositoryReference.parse("acme/workflows")
    var state = RielaAppDaemonWorkflowState()
    state.addWorkflowRepository(repository)
    let listings = [
      listing(repositoryId: repository.id, workflowId: "daily-summary", summary: "Summarize mail"),
      listing(repositoryId: repository.id, workflowId: "chat-reply", summary: "Reply to chat")
    ]
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [],
      workflowSources: [],
      state: state,
      snapshots: [:],
      marketplaceCatalogs: [
        repository.id: RielaAppWorkflowRepositoryCatalog(repository: repository, workflows: listings)
      ],
      assistantAssistance: "",
      statusMessage: ""
    )

    controller.showMarketplacePane()
    controller.window?.layoutIfNeeded()

    let searchField = try XCTUnwrap(
      visibleSubviews(of: NSSearchField.self, in: root)
        .first { $0.accessibilityLabel() == "Filter Marketplace Workflows" }
    )
    XCTAssertTrue(hasButton(label: "Install daily-summary", in: root))

    searchField.stringValue = "chat"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    controller.window?.layoutIfNeeded()

    XCTAssertEqual(controller.marketplaceFilterText, "chat")
    XCTAssertFalse(hasButton(label: "Install daily-summary", in: root))
    XCTAssertTrue(hasButton(label: "Install chat-reply", in: root))
  }

  func testMarketplaceHeaderUsesAccessibleIconButtonsAtRuntime() throws {
    let controller = makeController()
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showMarketplacePane()
    controller.window?.layoutIfNeeded()

    let addButton = try XCTUnwrap(
      visibleSubviews(of: NSButton.self, in: root)
        .first { $0.accessibilityLabel() == "Add GitHub repository" }
    )
    let refreshButton = try XCTUnwrap(
      visibleSubviews(of: NSButton.self, in: root)
        .first { $0.accessibilityLabel() == "Refresh repository workflows" }
    )
    XCTAssertEqual(addButton.title, "")
    XCTAssertEqual(addButton.imagePosition, .imageOnly)
    XCTAssertEqual(refreshButton.title, "")
    XCTAssertEqual(refreshButton.imagePosition, .imageOnly)
  }

  private func makeController() -> DaemonWorkflowWindowController {
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
      environmentColumnStatus: { _ in "Ready" },
      onWindowWillClose: {}
    )
  }

  private func listing(
    repositoryId: String,
    workflowId: String,
    summary: String
  ) -> RielaAppRemoteWorkflowListing {
    RielaAppRemoteWorkflowListing(
      repositoryId: repositoryId,
      workflowId: workflowId,
      title: workflowId,
      summary: summary,
      relativePath: "packages/\(workflowId)",
      installSourceURL: URL(fileURLWithPath: "/tmp/\(workflowId)"),
      kind: .packageWorkflow,
      packageName: workflowId
    )
  }

  private func hasButton(label: String, in root: NSView) -> Bool {
    visibleSubviews(of: NSButton.self, in: root).contains { $0.accessibilityLabel() == label }
  }

  private func visibleSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    allSubviews(of: type, in: root).filter { !hasHiddenAncestor($0) }
  }

  private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    let current = (root as? T).map { [$0] } ?? []
    return current + root.subviews.flatMap { allSubviews(of: type, in: $0) }
  }

  private func hasHiddenAncestor(_ view: NSView) -> Bool {
    view.isHidden || view.superview.map(hasHiddenAncestor) == true
  }
}
#endif
