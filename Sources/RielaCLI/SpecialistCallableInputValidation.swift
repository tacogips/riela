import Foundation
import RielaCore

enum SpecialistCallableInputValidation {
  static func validateSnapshot(directory: URL, variablesJSON: String?, workingDirectory: String) throws {
    let node = try callableNode(directory: directory, workingDirectory: workingDirectory)
    let supplied = try variablesJSON.map { try JSONDecoder().decode(JSONObject.self, from: Data($0.utf8)) } ?? [:]
    var payload = node.variables
    payload.merge(supplied) { _, supplied in supplied }
    try validate(payload: payload, contract: node.input)
  }

  static func callableNode(directory: URL, workingDirectory: String) throws -> AgentNodePayload {
    let bundle = try FileSystemWorkflowBundleResolver(enforcesTransactionBlock: true, capturesCatalogOriginSnapshot: false).resolve(WorkflowResolutionOptions(
      workflowName: directory.lastPathComponent, scope: .direct,
      workflowDefinitionDir: directory.path, workingDirectory: workingDirectory
    ))
    let stepId = bundle.workflow.managerStepId ?? bundle.workflow.entryStepId
    guard let step = bundle.workflow.steps.first(where: { $0.id == stepId }),
          let node = bundle.nodePayloads[stepId] ?? bundle.nodePayloads[step.nodeId] else {
      throw CLIUsageError("selected workflow has no callable input contract source")
    }
    return node
  }

  static func validate(payload: JSONObject, contract: NodeInputContract?) throws {
    guard let schema = contract?.jsonSchema else { return }
    // Input and output use the same supported schema vocabulary and fail-closed
    // handling of unsupported keywords. Do not maintain a second validator.
    let result = try DefaultWorkflowOutputValidator().validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: payload),
      contract: WorkflowOutputContract(schema: schema, requiredObject: true)
    )
    guard result.status == .accepted else {
      let reason = String((result.reason ?? "schema mismatch").prefix(512))
      throw CLIUsageError("selected workflow input rejected: \(reason)")
    }
  }
}
