import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

private struct BuiltinCatalogBundleResolver: WorkflowBundleResolving {
  let bundle: ResolvedWorkflowBundle

  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    bundle
  }
}

private struct BuiltinCatalogCapabilityResolver: HostCapabilityResolving {
  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    [HostCapabilitySnapshot(
      hostId: "local", backends: [], addonExecutables: [:], refreshedAt: Date()
    )]
  }
}

extension WorkflowHostCapabilityTests {
  func testIssue116BuiltinsResolveWithoutExternalExecutable() async {
    let names = [
      "riela/chat-persona-router",
      "riela/chat-persona-memory-read",
      "riela/chat-persona-memory-write",
      "riela/memory-save",
      "riela/memory-load",
      "riela/gmail-digest",
      "riela/x-digest",
      "riela/gemini-sdk-worker",
      "riela/codex-sdk-worker",
      "riela/time-signal",
      "riela/gmail-gateway-read",
      "riela/x-gateway-read"
    ]
    for name in names {
      for version in [nil, "1"] as [String?] {
        let result = await validateBuiltinCatalogReference(name: name, version: version)
        XCTAssertEqual(result.exitCode, .success, "\(name) \(version ?? "omitted"): \(result.stdout)")
        XCTAssertFalse(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
      }
    }
  }

  func testIssue116UnsupportedVersionsAndUnknownNamesFailClosed() async {
    let versionTwoNames = [
      "riela/chat-persona-router",
      "riela/chat-persona-memory-read",
      "riela/chat-persona-memory-write",
      "riela/memory-save",
      "riela/memory-load",
      "riela/gmail-digest",
      "riela/x-digest",
      "riela/gemini-sdk-worker",
      "riela/codex-sdk-worker",
      "riela/time-signal",
      "riela/gmail-gateway-read",
      "riela/x-gateway-read"
    ]
    for name in versionTwoNames {
      let result = await validateBuiltinCatalogReference(name: name, version: "2")
      XCTAssertEqual(result.exitCode, .failure, result.stdout)
      XCTAssertTrue(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
    }
    for name in ["riela/issue-116-unknown", "example/issue-116-unknown"] {
      let result = await validateBuiltinCatalogReference(name: name, version: "1")
      XCTAssertEqual(result.exitCode, .failure, result.stdout)
      XCTAssertTrue(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
    }
  }

  private func validateBuiltinCatalogReference(name: String, version: String?) async -> CLICommandResult {
    let memoryId: String?
    if name.hasPrefix("riela/chat-persona-memory-") {
      memoryId = "persona-chat-memory"
    } else if name == "riela/memory-save" || name == "riela/memory-load" {
      memoryId = "chat-memory"
    } else {
      memoryId = nil
    }
    let memories = memoryId.map { [WorkflowMemoryDeclaration(id: $0)] }
    let workflow = WorkflowDefinition(
      workflowId: "issue-116-addon-check",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      memories: memories,
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(
        id: "tool", addon: WorkflowNodeAddonRef(name: name, version: version), memories: memories
      )],
      steps: [WorkflowStepRef(id: "run", nodeId: "tool")],
      nodes: []
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow, nodePayloads: [:], sourceScope: .project,
      workflowDirectory: "/tmp/issue-116-addon-check"
    )
    return await WorkflowValidateCommand(
      resolver: BuiltinCatalogBundleResolver(bundle: bundle),
      hostResolver: BuiltinCatalogCapabilityResolver()
    ).run(WorkflowValidateOptions(
      workflowName: workflow.workflowId,
      resolution: WorkflowResolutionOptions(workflowName: workflow.workflowId),
      output: .json, host: "local", strictHost: true
    ))
  }
}
