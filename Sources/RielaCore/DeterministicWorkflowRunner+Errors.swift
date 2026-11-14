import Foundation

public enum DeterministicWorkflowRunnerError: Error, Equatable, Sendable {
  case invalidWorkflow(String)
  case missingNode(String)
  case missingStep(String)
  case missingNodePayload(String)
  case missingPromptVariant(String, String)
  case maxStepsExceeded(Int)
  case loopBudgetExceeded(String)
  case rerunValidation(String)
  case resumeValidation(String)
  case crossWorkflowDispatchFailed(workflowId: String, reason: String)
  case fanoutDispatchFailed(groupId: String, reason: String)
}

func errorMessage(_ error: WorkflowSessionEntryValidationError) -> String {
  switch error {
  case let .usage(message), let .validation(message):
    message
  }
}
