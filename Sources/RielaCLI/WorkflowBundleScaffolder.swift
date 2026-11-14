import Foundation
import RielaCore

struct WorkflowBundleScaffoldSpecification: Equatable, Sendable {
  var workflowId: String
  var description: String
  var nodeId: String
  var executionBackend: NodeExecutionBackend
  var model: String
  var modelFreeze: Bool
  var prompt: String
  var maxLoopIterations: Int
  var nodeTimeoutMs: Int

  init(
    workflowId: String,
    description: String,
    nodeId: String = "main-worker",
    executionBackend: NodeExecutionBackend,
    model: String,
    modelFreeze: Bool,
    prompt: String,
    maxLoopIterations: Int = 3,
    nodeTimeoutMs: Int = 120_000
  ) {
    self.workflowId = workflowId
    self.description = description
    self.nodeId = nodeId
    self.executionBackend = executionBackend
    self.model = model
    self.modelFreeze = modelFreeze
    self.prompt = prompt
    self.maxLoopIterations = maxLoopIterations
    self.nodeTimeoutMs = nodeTimeoutMs
  }
}

struct WorkflowBundleScaffoldResult: Equatable, Sendable {
  var workflowDirectory: URL
  var files: [URL]
}

struct WorkflowBundleScaffolder: Sendable {
  func create(
    at workflowDirectory: URL,
    specification: WorkflowBundleScaffoldSpecification
  ) throws -> WorkflowBundleScaffoldResult {
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let promptsDirectory = workflowDirectory.appendingPathComponent("prompts", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: promptsDirectory, withIntermediateDirectories: true)

    let workflowPath = workflowDirectory.appendingPathComponent("workflow.json")
    let nodePath = nodesDirectory.appendingPathComponent("node-\(specification.nodeId).json")
    let promptPath = promptsDirectory.appendingPathComponent("\(specification.nodeId).md")
    let workflow = ScaffoldedWorkflowDefinition(
      workflowId: specification.workflowId,
      description: specification.description,
      defaults: .init(
        maxLoopIterations: specification.maxLoopIterations,
        nodeTimeoutMs: specification.nodeTimeoutMs
      ),
      entryStepId: specification.nodeId,
      nodes: [.init(id: specification.nodeId, nodeFile: "nodes/node-\(specification.nodeId).json")],
      steps: [.init(id: specification.nodeId, nodeId: specification.nodeId, role: "worker")]
    )
    let node = ScaffoldedWorkflowNode(
      id: specification.nodeId,
      description: specification.description,
      executionBackend: specification.executionBackend,
      model: specification.model,
      modelFreeze: specification.modelFreeze,
      promptTemplateFile: "prompts/\(specification.nodeId).md",
      variables: [:]
    )
    try writeJSON(workflow, to: workflowPath)
    try writeJSON(node, to: nodePath)
    try Data((specification.prompt + "\n").utf8).write(to: promptPath, options: .atomic)
    return WorkflowBundleScaffoldResult(
      workflowDirectory: workflowDirectory,
      files: [workflowPath, nodePath, promptPath]
    )
  }

  private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
  }
}

private struct ScaffoldedWorkflowDefinition: Encodable {
  struct Defaults: Encodable {
    var maxLoopIterations: Int
    var nodeTimeoutMs: Int
  }

  struct Node: Encodable {
    var id: String
    var nodeFile: String
  }

  struct Step: Encodable {
    var id: String
    var nodeId: String
    var role: String
  }

  var workflowId: String
  var description: String
  var defaults: Defaults
  var entryStepId: String
  var nodes: [Node]
  var steps: [Step]
}

private struct ScaffoldedWorkflowNode: Encodable {
  var id: String
  var description: String
  var executionBackend: NodeExecutionBackend
  var model: String
  var modelFreeze: Bool
  var promptTemplateFile: String
  var variables: JSONObject
}
