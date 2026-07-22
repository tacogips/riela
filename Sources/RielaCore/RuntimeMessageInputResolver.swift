import Foundation

public struct WorkflowResolvedMessageInput: Codable, Equatable, Sendable {
  public var workflowExecutionId: String
  public var stepId: String
  public var messages: [WorkflowMessageRecord]
  public var payload: JSONObject
  public var communicationIds: [String]
  public var sourceStepIds: [String]

  public init(
    workflowExecutionId: String,
    stepId: String,
    messages: [WorkflowMessageRecord],
    payload: JSONObject,
    communicationIds: [String],
    sourceStepIds: [String]
  ) {
    self.workflowExecutionId = workflowExecutionId
    self.stepId = stepId
    self.messages = messages
    self.payload = payload
    self.communicationIds = communicationIds
    self.sourceStepIds = sourceStepIds
  }

  public func applying(to input: AdapterExecutionInput) -> AdapterExecutionInput {
    var adapterInput = input
    for (key, value) in payload {
      adapterInput.mergedVariables[key] = value
    }
    return adapterInput
  }
}

public protocol WorkflowMessageInputResolving: Sendable {
  func resolveInput(
    for sessionId: String,
    stepId: String,
    store: any WorkflowRuntimeStore
  ) async throws -> WorkflowResolvedMessageInput
}

public struct DefaultWorkflowMessageInputResolver: WorkflowMessageInputResolving {
  public init() {}

  public func resolveInput(
    for sessionId: String,
    stepId: String,
    store: any WorkflowRuntimeStore
  ) async throws -> WorkflowResolvedMessageInput {
    let messages = try await store.listMessages(for: sessionId, toStepId: stepId)
      .filter(\.isResolvableInput)
      .sorted {
        if $0.createdOrder == $1.createdOrder {
          return $0.communicationId < $1.communicationId
        }
        return $0.createdOrder < $1.createdOrder
      }
    var payload: JSONObject = [:]
    var sourceStepIds: [String] = []
    for message in messages {
      if let fromStepId = message.fromStepId, !sourceStepIds.contains(fromStepId) {
        sourceStepIds.append(fromStepId)
      }
      for (key, value) in message.payload {
        payload[key] = value
      }
    }
    payload["_rielaInput"] = resolvedInputMetadata(
      sessionId: sessionId,
      stepId: stepId,
      messages: messages,
      sourceStepIds: sourceStepIds
    )
    return WorkflowResolvedMessageInput(
      workflowExecutionId: sessionId,
      stepId: stepId,
      messages: messages,
      payload: payload,
      communicationIds: messages.map(\.communicationId),
      sourceStepIds: sourceStepIds
    )
  }
}

private func resolvedInputMetadata(
  sessionId: String,
  stepId: String,
  messages: [WorkflowMessageRecord],
  sourceStepIds: [String]
) -> JSONValue {
  let messageValues = messages.map(resolvedInputMessageMetadata)
  var metadata: JSONObject = [
    "workflowExecutionId": .string(sessionId),
    "stepId": .string(stepId),
    "communicationIds": .array(messages.map(\.communicationId).map(JSONValue.string)),
    "sourceStepIds": .array(sourceStepIds.map(JSONValue.string)),
    "messages": .array(messageValues)
  ]
  if let latest = messages.last {
    metadata["latest"] = resolvedInputMessageMetadata(latest)
  }
  return .object(metadata)
}

private func resolvedInputMessageMetadata(_ message: WorkflowMessageRecord) -> JSONValue {
  var metadata: JSONObject = [
    "communicationId": .string(message.communicationId),
    "workflowExecutionId": .string(message.workflowExecutionId),
    "sourceStepExecutionId": .string(message.sourceStepExecutionId),
    "deliveryKind": .string(message.deliveryKind.rawValue),
    "routingScope": .string(message.routingScope.rawValue),
    "lifecycleStatus": .string(message.lifecycleStatus.rawValue),
    "createdOrder": .number(Double(message.createdOrder)),
    "payload": .object(message.payload)
  ]
  if let fromStepId = message.fromStepId {
    metadata["fromStepId"] = .string(fromStepId)
  }
  if let toStepId = message.toStepId {
    metadata["toStepId"] = .string(toStepId)
  }
  if let transitionCondition = message.transitionCondition {
    metadata["transitionCondition"] = .string(transitionCondition)
  }
  return .object(metadata)
}

private extension WorkflowMessageRecord {
  var isResolvableInput: Bool {
    switch lifecycleStatus {
    case .delivered, .consumed:
      return true
    case .created, .failed, .superseded:
      return false
    }
  }
}
