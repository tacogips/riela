#if os(macOS)
@testable import RielaApp
import RielaCore
import RielaViewer
import XCTest

@MainActor
final class RielaAppWorkflowViewerVocabularyTests: XCTestCase {
  func testViewerUsesCurrentStepInsteadOfActiveInSessionTitles() {
    let controller = WorkflowViewerWindowController()
    let summary = WorkflowViewerSessionSummary(
      sessionId: "session-1",
      workflowId: "workflow-1",
      status: .running,
      currentStepId: "step-a",
      activeStepIds: ["step-a"],
      updatedAt: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(controller.sessionTitle(summary), "session-1, Running, Current Step step-a")
    XCTAssertFalse(controller.sessionTitle(summary).contains("Active"))
  }

  func testViewerMapsActiveRuntimeStateToRunningForDisplay() {
    let controller = WorkflowViewerWindowController()

    XCTAssertEqual(controller.workflowViewerStateText(WorkflowViewerNodeRuntimeState.active.rawValue), "Running")
  }

  func testTemplateDisplayNameUsesUserFacingUsageText() {
    let template = WorkflowViewerTemplateFile(
      id: "step-a:prompt",
      stepId: "step-a",
      nodeId: "node-a",
      nodeFile: "nodes/node-a.json",
      fieldPath: "promptTemplateFile",
      role: .prompt,
      relativePath: "prompts/step-a.md",
      resolvedPath: "/tmp/prompts/step-a.md",
      isActiveForStep: true
    )

    XCTAssertEqual(template.displayName, "Prompt / used by step: prompts/step-a.md")
    XCTAssertFalse(template.displayName.contains("active"))
  }
}
#endif
