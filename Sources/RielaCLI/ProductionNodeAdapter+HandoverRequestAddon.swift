import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeTaskWorkflowAddonIfSupported(
    _ input: WorkflowAddonExecutionInput
  ) async throws -> AdapterExecutionOutput? {
    switch input.addon.name {
    case "riela/workflow-create-register-run":
      return try await executeWorkflowCreateRegisterRun(input)
    case "riela/handover-request":
      return try executeHandoverRequest(input)
    default:
      return nil
    }
  }

  func executeHandoverRequest(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    guard input.variables["rielaTask"] != nil else {
      throw AdapterExecutionError(.policyBlocked, "riela/handover-request runs only inside a task attempt")
    }
    let envelopeKeys: Set<String> = ["reason", "question", "presence", "progressNote", "resumeStepId"]
    let authoredInput = input.resolvedInputPayload.filter { key, _ in envelopeKeys.contains(key) }
    let source = authoredInput.merging(input.addon.config ?? [:]) { current, _ in current }
    guard handoverRequestNonEmptyString(source["resumeStepId"]) != nil else {
      throw policyError("riela/handover-request resumeStepId is required")
    }
    let envelopeValue = JSONValue.object(source)
    let envelope = try HandoverEnvelope.parse(envelopeValue, source: input.addon.name)
    let bytes = try JSONEncoder().encode(envelope)
    let json = try JSONDecoder().decode(JSONValue.self, from: bytes)
    guard case let .object(envelopeObject) = json else {
      throw AdapterExecutionError(.invalidOutput, "riela/handover-request envelope must be an object")
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon", model: input.addon.name, promptText: "",
      completionPassed: true, payload: [
        "status": .string("handover-requested"),
        "addon": .string(input.addon.name),
        "stepId": .string(input.stepId),
        "handover": .object(envelopeObject)
      ]
    )
  }
}

private func handoverRequestNonEmptyString(_ value: JSONValue?) -> String? {
  guard case let .string(text)? = value else { return nil }
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}
