import Foundation
import RielaCore
import XCTest

final class ImplementationWorkflowSandboxTests: XCTestCase {
  func testCanonicalAuthoringNodesOwnWritesAndReviewsRemainReadOnly() throws {
    let nodes = repositoryRoot.appendingPathComponent(
      ".riela/workflows/codex-design-and-implement-review-loop/nodes",
      isDirectory: true
    )
    let expected: [String: AgentSandboxMode] = [
      "node-step1-issue-intake.json": .readOnly,
      "node-step2-design-doc-update.json": .readOnly,
      "node-step3-design-review.json": .readOnly,
      "node-step4-impl-plan-create.json": .readOnly,
      "node-step5-impl-plan-review.json": .readOnly,
      "node-step6-implement.json": .workspaceWrite,
      "node-step6-test-integrity-check.json": .readOnly,
      "node-step7-adversarial-review.json": .readOnly,
      "node-step8-docs-refresh.json": .workspaceWrite,
      "node-step8-impl-plan-completion-check.json": .readOnly,
      "node-step9-commit-message.json": .readOnly
    ]

    for (fileName, sandbox) in expected {
      let data = try Data(contentsOf: nodes.appendingPathComponent(fileName))
      let payload = try JSONDecoder().decode(AgentNodePayload.self, from: data)
      XCTAssertEqual(payload.agentSandbox, sandbox, fileName)
    }
  }

  func testCanonicalAuthoringPromptsRetainAcceptedReviewBoundaries() throws {
    let prompts = repositoryRoot.appendingPathComponent(
      ".riela/workflows/codex-design-and-implement-review-loop/prompts",
      isDirectory: true
    )
    let implementationPrompt = try String(
      contentsOf: prompts.appendingPathComponent("step6-implement.md"),
      encoding: .utf8
    )
    XCTAssertTrue(implementationPrompt.contains("Use the accepted implementation plan"))
    XCTAssertTrue(implementationPrompt.contains("only for full `issue-resolution` mode"))

    let documentationPrompt = try String(
      contentsOf: prompts.appendingPathComponent("step8-docs-refresh.md"),
      encoding: .utf8
    )
    XCTAssertTrue(documentationPrompt.contains("after Step 7 acceptance"))
    XCTAssertTrue(documentationPrompt.contains("Do not reopen design or implementation scope"))
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
