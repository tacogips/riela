import Foundation

public let promptOverflowMessagePhrases = [
  "prompt is too long",
  "context_length_exceeded",
  "maximum context length",
  "request_too_large"
]

public func adapterFailureKind(_ error: AdapterExecutionError) -> WorkflowSessionFailureKind {
  if let failureKind = error.failureKind {
    return failureKind
  }
  switch error.code {
  case .providerError, .invalidInput:
    let message = error.message.lowercased()
    if promptOverflowMessagePhrases.contains(where: message.contains) {
      return .promptTooLarge
    }
  case .policyBlocked, .timeout, .invalidOutput, .templateResolutionFailed:
    break
  }
  return .adapterFailure
}
