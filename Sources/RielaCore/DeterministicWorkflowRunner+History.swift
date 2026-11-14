import Foundation
import CryptoKit

private struct HistoryInvocationContract: Codable {
  var workflowDigest: String
  var payloadDigest: String
  var inputDigest: String
  var variablesDigest: String
}

private func historyDigest<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
}

extension DeterministicWorkflowRunner {
  func historyInvocationSnapshot(_ input: AdapterExecutionInput, request: DeterministicWorkflowRunRequest,
    step: WorkflowStepRef, payload: AgentNodePayload) throws -> JSONObject {
    var snapshot = input.invocationSnapshot
    let contract = try historyContract(request, step: step, payload: payload)
    snapshot["_rielaHistoryContract"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(contract))
    return snapshot
  }

  private func historyContract(_ request: DeterministicWorkflowRunRequest, step: WorkflowStepRef,
    payload: AgentNodePayload) throws -> HistoryInvocationContract {
    var workflow = request.workflow
    workflow.steps = [step]
    return try HistoryInvocationContract(workflowDigest: historyDigest(workflow),
      payloadDigest: historyDigest(payload),
      inputDigest: historyDigest(["input": JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload.input)),
        "variables": .object(payload.variables)]), variablesDigest: historyDigest(request.variables))
  }

  func preservedHistory(_ request: DeterministicWorkflowRunRequest, source: WorkflowSession,
    target: String) async throws -> WorkflowHistoryImportInput {
    func reject(_ message: String) -> DeterministicWorkflowRunnerError {
      .rerunValidation("cannot preserve history: \(message)")
    }
    guard source.status == .failed, source.fanoutGroups?.isEmpty != false,
          let boundary = source.executions.firstIndex(where: { $0.stepId == target }) else {
      throw reject("requires a failed sequential session with recorded target invocation")
    }
    let prefix = source.executions[..<boundary].filter { $0.status == .completed }
    guard Set(prefix.map(\.stepId)).count == prefix.count,
          source.executions[..<boundary].allSatisfy({ $0.status == .completed || $0.status == .failed }),
          prefix.allSatisfy({ $0.acceptedOutput != nil }),
          source.executions[boundary...].allSatisfy({ $0.stepId == target && $0.status == .failed }) else {
      throw reject("ambiguous repeated or non-accepted step boundary")
    }
    for execution in Array(prefix) + [source.executions[boundary]] {
      guard let raw = execution.inputSnapshot?["_rielaHistoryContract"],
            let currentStep = request.workflow.steps.first(where: { $0.id == execution.stepId }),
            let rawPayload = request.nodePayloads[currentStep.nodeId] else {
        throw reject("missing invocation compatibility evidence for \(execution.stepId)")
      }
      let previous = try JSONDecoder().decode(HistoryInvocationContract.self, from: JSONEncoder().encode(raw))
      let currentPayload = rawPayload
      let current = try historyContract(request, step: currentStep, payload: currentPayload)
      guard previous.variablesDigest == current.variablesDigest,
            previous.workflowDigest == current.workflowDigest,
            execution.nodeId == currentStep.nodeId else {
        throw reject("incompatible workflow/variables/step \(execution.stepId)")
      }
      if execution.stepId == target {
        guard previous.inputDigest == current.inputDigest else {
          throw reject("incompatible target input contract")
        }
      } else if previous.payloadDigest != current.payloadDigest {
        throw reject("incompatible accepted node \(execution.nodeId)")
      }
    }
    let acceptedIds = Set(prefix.map(\.executionId))
    let messages = try await store.listMessages(for: source.sessionId, toStepId: nil)
    guard messages.allSatisfy({ acceptedIds.contains($0.sourceStepExecutionId) && $0.deliveryKind == .direct }),
          !prefix.isEmpty || messages.isEmpty else {
      throw reject("history contains unsupported or unaccepted communications")
    }
    guard prefix.first?.stepId == request.workflow.entryStepId || (prefix.isEmpty && target == request.workflow.entryStepId),
          messages.count == prefix.count else {
      throw reject("incomplete accepted prefix or communication count")
    }
    let orderedPrefix = Array(prefix)
    let orderedMessages = messages.sorted { $0.createdOrder < $1.createdOrder }
    for (index, execution) in orderedPrefix.enumerated() {
      let next = index + 1 < orderedPrefix.count ? orderedPrefix[index + 1].stepId : target
      let message = orderedMessages[index]
      let transitions = request.workflow.steps.first(where: { $0.id == execution.stepId })?.transitions ?? []
      guard transitions.count == 1, transitions[0].toStepId == next,
            transitions[0].toWorkflowId == nil, transitions[0].fanout == nil,
            message.sourceStepExecutionId == execution.executionId,
            message.fromStepId == execution.stepId, message.toStepId == next,
            message.payload == execution.acceptedOutput?.payload,
            message.routingScope == .workflow,
            index == 0 || message.createdOrder > orderedMessages[index - 1].createdOrder else {
        throw reject("missing, changed, or non-sequential accepted communication for \(execution.stepId)")
      }
    }
    let resolved = try await inputResolver.resolveInput(for: source.sessionId, stepId: target, store: store)
    guard case let .object(variables)? = source.executions[boundary].inputSnapshot?["mergedVariables"],
          variables["_rielaInput"] == resolved.payload["_rielaInput"] else {
      throw reject("recorded target inbox does not match accepted communications")
    }
    return WorkflowHistoryImportInput(sessionId: "", sourceSessionId: source.sessionId,
      executions: Array(prefix), messages: messages)
  }
}
