import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testResolverMaterializesNodeRefsFromSiblingWorkflow() throws {
    let root = sharedNodeRepositoryRoot()
      .appendingPathComponent("tmp/riela-cli-shared-node-sibling-\(UUID().uuidString)", isDirectory: true)
    let sharedWorkflow = root.appendingPathComponent("shared-personas", isDirectory: true)
    let telegramWorkflow = root.appendingPathComponent("telegram-entry", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: sharedWorkflow.appendingPathComponent("nodes"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: sharedWorkflow.appendingPathComponent("prompts"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: telegramWorkflow, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "shared-personas",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "mika",
      "nodes": [{
        "id": "mika",
        "nodeFile": "nodes/mika.json",
        "memories": [{
          "id": "persona-chat-memory",
          "purpose": "shared Mika memory across chat vendors",
          "scope": "cross-workflow"
        }]
      }],
      "steps": [{ "id": "mika", "nodeId": "mika", "role": "worker" }]
    }
    """.write(to: sharedWorkflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "mika",
      "executionBackend": "codex-agent",
      "model": "gpt-5-nano",
      "systemPromptTemplateFile": "prompts/mika-system.md",
      "promptTemplate": "Reply as shared Mika.",
      "variables": {}
    }
    """.write(to: sharedWorkflow.appendingPathComponent("nodes/mika.json"), atomically: true, encoding: .utf8)
    try "shared Mika persona".write(
      to: sharedWorkflow.appendingPathComponent("prompts/mika-system.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    {
      "workflowId": "telegram-entry",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "reply",
      "nodes": [{
        "id": "telegram-mika",
        "nodeRef": { "workflowId": "shared-personas", "nodeId": "mika" },
        "inputFilters": [{
          "kind": "telegram",
          "builtin": "mention-responder",
          "config": { "aliases": ["@mikatrend0529bot"] }
        }]
      }],
      "steps": [{ "id": "reply", "nodeId": "telegram-mika", "role": "worker" }]
    }
    """.write(to: telegramWorkflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let bundle = try FileSystemWorkflowBundleResolver().resolve(
      WorkflowResolutionOptions(workflowName: "telegram-entry", scope: .direct, workflowDefinitionDir: root.path)
    )

    let registryNode = try XCTUnwrap(bundle.workflow.nodeRegistry.first)
    XCTAssertEqual(registryNode.id, "telegram-mika")
    XCTAssertEqual(registryNode.nodeRef, WorkflowSharedNodeRef(workflowId: "shared-personas", nodeId: "mika"))
    XCTAssertNil(registryNode.nodeFile)
    XCTAssertEqual(registryNode.memories?.first?.id, "persona-chat-memory")
    XCTAssertEqual(registryNode.memories?.first?.scope, .crossWorkflow)
    XCTAssertEqual(registryNode.inputFilters?.first?.builtin, .mentionResponder)
    XCTAssertNil(registryNode.addon)
    let runtimeNode = try XCTUnwrap(bundle.workflow.nodes.first)
    XCTAssertNil(runtimeNode.nodeFile)
    XCTAssertEqual(runtimeNode.nodeRef, WorkflowSharedNodeRef(workflowId: "shared-personas", nodeId: "mika"))
    XCTAssertEqual(runtimeNode.memories?.first?.id, "persona-chat-memory")
    let payload = try XCTUnwrap(bundle.nodePayloads["telegram-mika"])
    XCTAssertEqual(payload.id, "telegram-mika")
    XCTAssertEqual(payload.systemPromptTemplate, "shared Mika persona")
    XCTAssertEqual(payload.promptTemplate, "Reply as shared Mika.")
    XCTAssertNil(bundle.nodePayloads["mika"])
  }

  func testResolverMaterializesNestedSharedNodeRefPayloads() throws {
    let root = sharedNodeRepositoryRoot()
      .appendingPathComponent("tmp/riela-cli-nested-shared-node-\(UUID().uuidString)", isDirectory: true)
    let leafWorkflow = root.appendingPathComponent("leaf-personas", isDirectory: true)
    let sharedWorkflow = root.appendingPathComponent("shared-personas", isDirectory: true)
    let entryWorkflow = root.appendingPathComponent("telegram-entry", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: leafWorkflow.appendingPathComponent("nodes"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: leafWorkflow.appendingPathComponent("prompts"),
      withIntermediateDirectories: true
    )
    try writeNodeFileWorkflow(
      to: leafWorkflow,
      workflowId: "leaf-personas",
      nodeId: "mika",
      nodeFile: "nodes/mika.json"
    )
    try """
    {
      "id": "mika",
      "executionBackend": "codex-agent",
      "model": "gpt-5-nano",
      "systemPromptTemplateFile": "prompts/mika-system.md",
      "promptTemplate": "Reply as nested Mika.",
      "variables": {}
    }
    """.write(to: leafWorkflow.appendingPathComponent("nodes/mika.json"), atomically: true, encoding: .utf8)
    try "nested Mika persona".write(
      to: leafWorkflow.appendingPathComponent("prompts/mika-system.md"),
      atomically: true,
      encoding: .utf8
    )
    try writeSharedNodeRefWorkflow(
      to: sharedWorkflow,
      workflowId: "shared-personas",
      nodeId: "mika",
      targetWorkflowId: "leaf-personas",
      targetNodeId: "mika"
    )
    try writeSharedNodeRefWorkflow(
      to: entryWorkflow,
      workflowId: "telegram-entry",
      nodeId: "telegram-mika",
      targetWorkflowId: "shared-personas",
      targetNodeId: "mika",
      entryStepId: "reply"
    )

    let bundle = try FileSystemWorkflowBundleResolver().resolve(
      WorkflowResolutionOptions(workflowName: "telegram-entry", scope: .direct, workflowDefinitionDir: root.path)
    )

    let payload = try XCTUnwrap(bundle.nodePayloads["telegram-mika"])
    XCTAssertEqual(payload.id, "telegram-mika")
    XCTAssertEqual(payload.systemPromptTemplate, "nested Mika persona")
    XCTAssertEqual(payload.promptTemplate, "Reply as nested Mika.")
    XCTAssertNil(bundle.nodePayloads["mika"])
  }

  func testResolverMaterializesAddonNodeRefsInsidePackagedWorkflowRoot() throws {
    let root = sharedNodeRepositoryRoot()
      .appendingPathComponent("tmp/riela-cli-packaged-shared-node-\(UUID().uuidString)", isDirectory: true)
    let packageDirectory = root
      .appendingPathComponent(".riela/packages/persona-package", isDirectory: true)
    let sharedWorkflow = packageDirectory
      .appendingPathComponent("workflows/shared-personas", isDirectory: true)
    let entryWorkflow = packageDirectory
      .appendingPathComponent("workflows/telegram-entry", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: sharedWorkflow, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: entryWorkflow, withIntermediateDirectories: true)
    try """
    {
      "name": "persona-package",
      "version": "1.0.0",
      "description": "Persona package",
      "tags": ["workflow"],
      "registry": "local",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "workflows/telegram-entry"
    }
    """.write(to: packageDirectory.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    try """
    {
      "workflowId": "shared-personas",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "yui",
      "nodes": [{
        "id": "yui",
        "memories": [{ "id": "persona-chat-memory", "scope": "cross-workflow" }],
        "addon": {
          "name": "riela/chat-reply-worker",
          "version": "1",
          "config": { "textTemplate": "shared yui" }
        }
      }],
      "steps": [{ "id": "yui", "nodeId": "yui", "role": "worker" }]
    }
    """.write(to: sharedWorkflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "workflowId": "telegram-entry",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "reply",
      "nodes": [{
        "id": "telegram-yui",
        "nodeRef": { "workflowId": "shared-personas", "nodeId": "yui" }
      }],
      "steps": [{ "id": "reply", "nodeId": "telegram-yui", "role": "worker" }]
    }
    """.write(to: entryWorkflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let bundle = try FileSystemWorkflowBundleResolver().resolve(
      WorkflowResolutionOptions(workflowName: "persona-package", scope: .project, workingDirectory: root.path)
    )

    XCTAssertEqual(bundle.workflow.workflowId, "telegram-entry")
    XCTAssertEqual(bundle.packageDirectory, packageDirectory.path)
    let registryNode = try XCTUnwrap(bundle.workflow.nodeRegistry.first)
    XCTAssertNil(registryNode.nodeRef)
    XCTAssertEqual(registryNode.addon?.name, "riela/chat-reply-worker")
    XCTAssertEqual(registryNode.memories?.first?.id, "persona-chat-memory")
    let runtimeNode = try XCTUnwrap(bundle.workflow.nodes.first)
    XCTAssertNil(runtimeNode.nodeRef)
    XCTAssertEqual(runtimeNode.addon?.name, "riela/chat-reply-worker")
    XCTAssertTrue(bundle.nodePayloads.isEmpty)
  }

  func testResolverRejectsCyclicSharedNodeRefs() throws {
    let root = sharedNodeRepositoryRoot()
      .appendingPathComponent("tmp/riela-cli-shared-node-cycle-\(UUID().uuidString)", isDirectory: true)
    let sharedA = root.appendingPathComponent("shared-a", isDirectory: true)
    let sharedB = root.appendingPathComponent("shared-b", isDirectory: true)
    let entryWorkflow = root.appendingPathComponent("entry", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSharedNodeRefWorkflow(
      to: sharedA,
      workflowId: "shared-a",
      nodeId: "aa",
      targetWorkflowId: "shared-b",
      targetNodeId: "bb"
    )
    try writeSharedNodeRefWorkflow(
      to: sharedB,
      workflowId: "shared-b",
      nodeId: "bb",
      targetWorkflowId: "shared-a",
      targetNodeId: "aa"
    )
    try writeSharedNodeRefWorkflow(
      to: entryWorkflow,
      workflowId: "entry",
      nodeId: "reply",
      targetWorkflowId: "shared-a",
      targetNodeId: "aa",
      entryStepId: "reply"
    )

    XCTAssertThrowsError(
      try FileSystemWorkflowBundleResolver().resolve(
        WorkflowResolutionOptions(workflowName: "entry", scope: .direct, workflowDefinitionDir: root.path)
      )
    ) { error in
      guard case let WorkflowResolutionError.invalidWorkflow(diagnostics) = error else {
        return XCTFail("expected invalidWorkflow, got \(error)")
      }
      XCTAssertTrue(diagnostics.contains { $0.message.contains("cyclic shared node reference") })
    }
  }

  private func sharedNodeRepositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url
      }
      url.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  }

  private func writeSharedNodeRefWorkflow(
    to directory: URL,
    workflowId: String,
    nodeId: String,
    targetWorkflowId: String,
    targetNodeId: String,
    entryStepId: String? = nil
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stepId = entryStepId ?? nodeId
    try """
    {
      "workflowId": "\(workflowId)",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "\(stepId)",
      "nodes": [{ "id": "\(nodeId)", "nodeRef": { "workflowId": "\(targetWorkflowId)", "nodeId": "\(targetNodeId)" } }],
      "steps": [{ "id": "\(stepId)", "nodeId": "\(nodeId)", "role": "worker" }]
    }
    """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
  }

  private func writeNodeFileWorkflow(
    to directory: URL,
    workflowId: String,
    nodeId: String,
    nodeFile: String
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "\(workflowId)",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 120000 },
      "entryStepId": "\(nodeId)",
      "nodes": [{ "id": "\(nodeId)", "nodeFile": "\(nodeFile)" }],
      "steps": [{ "id": "\(nodeId)", "nodeId": "\(nodeId)", "role": "worker" }]
    }
    """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
  }
}
