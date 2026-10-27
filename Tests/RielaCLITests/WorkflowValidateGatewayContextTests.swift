import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowValidateGatewayContextTests: XCTestCase {
  func testValidatePrintsSharedCwdLocalWarningOnlyOnce() async {
    let addon = WorkflowNodeAddonRef(name: "riela/kv-get")
    let workflow = WorkflowDefinition(workflowId: "kv-warning-deduplicated",
      defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 1), entryStepId: "step",
      nodeRegistry: [.init(id: "node", addon: addon)], steps: [.init(id: "step", nodeId: "node")],
      nodes: [.init(id: "node", addon: addon)])
    let warning = WorkflowValidationDiagnostic(severity: .warning, path: "workflow.nodes",
      message: "riela memory/KV state is cwd-local and becomes a localOnly deliverable on handover; add a kaiba mirror step")
    let bundle = ResolvedWorkflowBundle(workflow: workflow, nodePayloads: [:], sourceScope: .project,
      workflowDirectory: "/tmp", diagnostics: [warning])
    let command = WorkflowValidateCommand(resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: .init(hostId: "local", backends: [], refreshedAt: Date())))
    let result = await command.run(WorkflowValidateOptions(workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId), output: .json))
    XCTAssertEqual(result.stdout.components(separatedBy: "cwd-local").count - 1, 1, result.stdout)
  }

  func testValidateInjectsProductionPostprocessCompiler() async {
    let addon = WorkflowNodeAddonRef(
      name: "riela/gmail-gateway-reader",
      config: ["postprocess": .array([.object(["bogus": .integer(1)])])]
    )
    let workflow = WorkflowDefinition(
      workflowId: "gateway-production-validation",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", addon: addon)],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "node", addon: addon)]
    )
    let bundle = ResolvedWorkflowBundle(workflow: workflow, nodePayloads: [:], sourceScope: .project, workflowDirectory: "/tmp")
    let command = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: Date()))
    )
    let result = await command.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json
    ))
    XCTAssertEqual(result.exitCode, .failure, result.stdout)
    XCTAssertTrue(result.stdout.contains("addon.config.postprocess"), result.stdout)
  }

  func testValidateRejectsMixedGatewayModeAndUnknownCatalogOperation() async throws {
    let mixed = await validate(addon: WorkflowNodeAddonRef(
      name: "riela/wrike-gateway-read",
      config: ["operation": .string("tasks"), "arguments": .object([:]), "queryTemplate": .string("{ tasks { id } }")]
    ))
    XCTAssertEqual(mixed.exitCode, .failure, mixed.stdout)
    XCTAssertTrue(mixed.stdout.contains("queryTemplate"), mixed.stdout)

    guard WorkflowValidationContext.production().gatewayCatalog?(.gmail, "reader") != nil else {
      throw XCTSkip("Gmail operation catalog is not available in this build")
    }
    let unknown = await validate(addon: WorkflowNodeAddonRef(
      name: "riela/gmail-gateway-reader",
      config: ["operation": .string("noSuchOperation"), "arguments": .object([:])]
    ))
    XCTAssertEqual(unknown.exitCode, .failure, unknown.stdout)
    XCTAssertTrue(unknown.stdout.contains("unknown operation"), unknown.stdout)
  }

  func testGatewayWorkflowExamplesValidate() async throws {
    let examples = [
      "builtin-gateway-json", "gmail-latest-mail-digest-telegram", "wrike-project-kanban-agent",
      "apple-gateway-admin", "apple-gateway-packaging-plan", "x-gateway-json-search",
      "notion-gateway-json-sync", "x-window-checkpoint", "x-incremental-posts-kv"
    ]
    for example in examples {
      let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("examples/\(example)").path
      let result = await WorkflowValidateCommand().run(WorkflowValidateOptions(
        workflowName: example,
        resolution: WorkflowResolutionOptions(workflowName: example, workflowDefinitionDir: directory),
        output: .json
      ))
      XCTAssertEqual(result.exitCode, .success, "\(example): \(result.stdout)\n\(result.stderr)")
    }
  }

  private func validate(addon: WorkflowNodeAddonRef) async -> CLICommandResult {
    let workflow = WorkflowDefinition(
      workflowId: "gateway-production-validation",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", addon: addon)],
      steps: [WorkflowStepRef(id: "step", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "node", addon: addon)]
    )
    let bundle = ResolvedWorkflowBundle(workflow: workflow, nodePayloads: [:], sourceScope: .project, workflowDirectory: "/tmp")
    let command = WorkflowValidateCommand(
      resolver: HostValidationBundleResolver(bundle: bundle),
      hostResolver: HostValidationCapabilityResolver(snapshot: HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: Date()))
    )
    return await command.run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json
    ))
  }
}
