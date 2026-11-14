import Foundation
import RielaAddons
import RielaCore
import XCTest
@testable import RielaCLI

final class LoopStartPromoteCommandTests: XCTestCase {
  // MARK: - loop start parsing

  func testLoopStartParsesIntoStartKind() throws {
    let command = try RielaArgumentParser().parse(["loop", "start", "demo-workflow", "--var", "k=v"])
    guard case let .loop(loopCommand) = command else {
      return XCTFail("expected loop command")
    }
    XCTAssertEqual(loopCommand.kind, .start)
    XCTAssertEqual(loopCommand.options.target, "demo-workflow")
    XCTAssertEqual(loopCommand.options.arguments, ["--var", "k=v"])
  }

  func testLoopPromoteParsesIntoPromoteKind() throws {
    let command = try RielaArgumentParser().parse(["loop", "promote", "demo-workflow"])
    guard case let .loop(loopCommand) = command else {
      return XCTFail("expected loop command")
    }
    XCTAssertEqual(loopCommand.kind, .promote)
    XCTAssertEqual(loopCommand.options.target, "demo-workflow")
  }

  func testLoopStartWithoutWorkflowIdIsUsageError() {
    XCTAssertThrowsError(try RielaArgumentParser().parse(["loop", "start"])) { error in
      XCTAssertEqual((error as? CLIUsageError)?.message, "loop start requires a workflow id")
    }
  }

  func testWorkflowRunOptionsCollectsVarPairsIntoInlineVariables() throws {
    let options = try LoopStartCommand.workflowRunOptions(
      workflowName: "demo",
      tokens: ["--var", "alpha=1", "--var", "beta=two words", "--max-steps", "4"]
    )
    XCTAssertEqual(options.target, "demo")
    XCTAssertEqual(options.maxSteps, 4)
    let variables = try JSONReferenceLoader().object(from: try XCTUnwrap(options.variables))
    XCTAssertEqual(variables["alpha"], .string("1"))
    XCTAssertEqual(variables["beta"], .string("two words"))
  }

  func testWorkflowRunOptionsRejectsIsolate() {
    XCTAssertThrowsError(try LoopStartCommand.workflowRunOptions(workflowName: "demo", tokens: ["--isolate"])) { error in
      XCTAssertTrue(((error as? CLIUsageError)?.message ?? "").contains("not yet supported"))
    }
  }

  func testWorkflowRunOptionsRejectsVarCombinedWithVariables() {
    XCTAssertThrowsError(try LoopStartCommand.workflowRunOptions(
      workflowName: "demo",
      tokens: ["--var", "k=v", "--variables", "{}"]
    )) { error in
      XCTAssertTrue(((error as? CLIUsageError)?.message ?? "").contains("cannot combine"))
    }
  }

  func testWorkflowRunOptionsRejectsMalformedVar() {
    XCTAssertThrowsError(try LoopStartCommand.workflowRunOptions(workflowName: "demo", tokens: ["--var", "novalue"]))
  }

  // MARK: - Policy panel

  func testPolicyPanelProjectsAuthoredMetadata() {
    let workflow = Self.loopWorkflow()
    let panel = LoopStartCommand.policyPanel(
      workflow: workflow,
      loop: workflow.loop!,
      nodePayloads: [:]
    )
    XCTAssertEqual(panel.workflowId, "loop-panel-demo")
    XCTAssertEqual(panel.loopKind, "design-implement-review")
    XCTAssertTrue(panel.required)
    XCTAssertEqual(panel.mutationRoots, ["Sources/"])
    XCTAssertEqual(panel.scratchRoot, "tmp/loop")
    XCTAssertEqual(panel.commit, "allow")
    XCTAssertEqual(panel.push, "deny")
    XCTAssertEqual(panel.nestedProcessPolicy["riela"], "deny")
    XCTAssertEqual(panel.nestedProcessPolicy["codex"], "deny")
    XCTAssertEqual(panel.allowedBackends, ["codex-agent"])
    XCTAssertEqual(panel.gates.map(\.gateId), ["implementation-review"])
    XCTAssertEqual(panel.budget?.maxTotalTokens, 50_000)
    XCTAssertEqual(panel.evidenceRequiredSections, ["verification"])
  }

  func testPanelTextRendersDeclaredValues() {
    let workflow = Self.loopWorkflow()
    let panel = LoopStartCommand.policyPanel(workflow: workflow, loop: workflow.loop!, nodePayloads: [:])
    let text = LoopStartCommand.panelText(panel)
    XCTAssertTrue(text.contains("loop policy: loop-panel-demo"))
    XCTAssertTrue(text.contains("implementation-review (step review, required)"))
    XCTAssertTrue(text.contains("maxTotalTokens=50000"))
  }

  // MARK: - loop promote readiness

  func testPromotionReadinessLabelsOptionalLoopIssuesAdvisory() {
    var workflow = Self.loopWorkflow()
    workflow.loop?.required = false
    workflow.loop?.implementationPlan = nil
    let result = LoopPromoteCommand.promotionReadiness(bundle: Self.bundle(workflow: workflow))
    XCTAssertTrue(result.ready, "advisory issues must not flip readiness")
    XCTAssertFalse(result.issues.isEmpty)
    XCTAssertTrue(result.issues.allSatisfy { $0.level == "advisory" })
  }

  func testPromotionReadinessLabelsRequiredLoopIssuesEnforced() {
    var workflow = Self.loopWorkflow()
    workflow.loop?.implementationPlan = nil
    let result = LoopPromoteCommand.promotionReadiness(bundle: Self.bundle(workflow: workflow))
    XCTAssertFalse(result.ready)
    XCTAssertTrue(result.issues.contains {
      $0.path == "workflow.loop.implementationPlan.required" && $0.level == "enforced"
    })
  }

  func testPromotionReadinessReportsMissingLoopMetadataAsAdvisory() {
    var workflow = Self.loopWorkflow()
    workflow.loop = nil
    let result = LoopPromoteCommand.promotionReadiness(bundle: Self.bundle(workflow: workflow))
    XCTAssertTrue(result.ready)
    XCTAssertTrue(result.issues.contains { $0.path == "workflow.loop" && $0.level == "advisory" })
  }

  func testPromotionReadinessEvaluatesPackageManifestChecks() throws {
    let manifestData = Data(#"{"name":"sample-package","loop":{"promotionReady":false}}"#.utf8)
    let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: manifestData)
    let workflow = Self.loopWorkflow()
    let bundle = Self.bundle(workflow: workflow, packageManifest: manifest, packageDirectory: "/tmp/nonexistent-package")
    let result = LoopPromoteCommand.promotionReadiness(bundle: bundle)
    // promotionReady is false → manifest issues are advisory, and the
    // promotion-ready requirements are still evaluated (usageContract etc.).
    XCTAssertTrue(result.issues.contains { $0.path == "loop.usageContract" && $0.level == "advisory" })
  }

  func testPromotionReadinessEnforcesPromotionReadyManifestChecks() throws {
    let manifestData = Data(#"{"name":"sample-package","loop":{"promotionReady":true}}"#.utf8)
    let manifest = try JSONDecoder().decode(WorkflowPackageManifest.self, from: manifestData)
    let workflow = Self.loopWorkflow()
    let bundle = Self.bundle(workflow: workflow, packageManifest: manifest, packageDirectory: "/tmp/nonexistent-package")
    let result = LoopPromoteCommand.promotionReadiness(bundle: bundle)
    XCTAssertFalse(result.ready)
    XCTAssertTrue(result.issues.contains { $0.path == "loop.usageContract" && $0.level == "enforced" })
  }

  // MARK: - Fixtures

  private static func bundle(
    workflow: WorkflowDefinition,
    packageManifest: WorkflowPackageManifest? = nil,
    packageDirectory: String? = nil
  ) -> ResolvedWorkflowBundle {
    ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: [:],
      sourceScope: .project,
      workflowDirectory: "/tmp/loop-panel-demo",
      packageManifest: packageManifest,
      packageDirectory: packageDirectory
    )
  }

  private static func loopWorkflow() -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "loop-panel-demo",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "review",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "review-node", nodeFile: "nodes/review.json")],
      steps: [
        WorkflowStepRef(
          id: "review",
          nodeId: "review-node",
          role: .worker,
          loop: WorkflowStepLoopMetadata(role: "gate", gateId: "implementation-review")
        )
      ],
      nodes: [WorkflowNodeRef(id: "review-node", nodeFile: "nodes/review.json")],
      loop: WorkflowLoopMetadata(
        kind: "design-implement-review",
        required: true,
        evidence: LoopEvidenceRequirements(
          required: true,
          artifactRootPolicy: "runtime-owned",
          requiredSections: ["verification"]
        ),
        policies: LoopPolicyDeclaration(
          mutation: LoopMutationPolicyDeclaration(
            allowedWriteRoots: ["Sources/"],
            scratchRoot: "tmp/loop",
            commit: "allow",
            push: "deny"
          ),
          process: LoopProcessPolicyDeclaration(
            nestedRiela: "deny",
            nestedCodex: "deny",
            allowedBackends: ["codex-agent"]
          )
        ),
        budget: LoopBudgetDeclaration(maxTotalTokens: 50_000),
        gates: [LoopGateDeclaration(
          id: "implementation-review",
          stepId: "review",
          required: true,
          acceptWhen: LoopGateAcceptancePolicy(decision: .accepted)
        )],
        implementationPlan: LoopImplementationPlanRequirement(required: true, pathPattern: "impl-plans/*.md")
      )
    )
  }
}
