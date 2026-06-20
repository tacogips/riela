import Foundation

extension DeterministicWorkflowRunner {
  func memoryJSON(_ memory: WorkflowMemoryDeclaration) -> JSONValue {
    var object: JSONObject = ["id": .string(memory.id)]
    if let description = memory.description {
      object["description"] = .string(description)
    }
    if let purpose = memory.purpose {
      object["purpose"] = .string(purpose)
    }
    if let scope = memory.scope {
      object["scope"] = .string(scope.rawValue)
    }
    if let defaultLimit = memory.defaultLimit {
      object["defaultLimit"] = .number(Double(defaultLimit))
    }
    return .object(object)
  }

  func memoryCommandHelp(
    workflowId: String,
    nodeId: String,
    workflowMemories: [WorkflowMemoryDeclaration],
    nodeMemories: [WorkflowMemoryDeclaration]
  ) -> String {
    let memoryIds = Array(Set((workflowMemories + nodeMemories).map(\.id))).sorted()
    guard !memoryIds.isEmpty else {
      return ""
    }
    let memoryList = memoryIds.joined(separator: ", ")
    return """
      Available Riela memory ids for this node: \(memoryList).
      Save JSON memory: riela memory save <memory-id> --workflow-id \(workflowId) --node-id \(nodeId) --payload-json '<json>'.
      Load recent memory: riela memory load <memory-id> --workflow-id \(workflowId) --node-id \(nodeId) --limit 30.
      Search memory with grep-style regular expressions: riela memory search <memory-id> --workflow-id \(workflowId) --match '<regex>' --limit 30.
      """
  }

  func memoryGuidance(variables: JSONObject) -> String? {
    guard case let .string(help)? = variables["memoryCommandHelp"], !help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return help
  }
}
