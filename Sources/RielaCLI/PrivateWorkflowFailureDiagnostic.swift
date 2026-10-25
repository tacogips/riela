import Foundation
import RielaCore

/// Public labels come only from host configuration. Private step ids, messages,
/// stderr and input data never cross this boundary.
struct PrivateWorkflowFailureDiagnostic: Equatable, Sendable {
  static let allowedKinds: Set<String> = [WorkflowSessionFailureKind.adapterFailure.rawValue,
    WorkflowSessionFailureKind.nodeTimeout.rawValue, WorkflowSessionFailureKind.cancelled.rawValue, "other"]
  let stage: String
  let kind: String
  var message: String { "private workflow execution failed [stage=\(stage);kind=\(kind)]" }

  static func parse(_ message: String, plan: PrivateWorkflowPlan) -> Self? {
    let prefix = "private workflow execution failed [stage="
    guard message.hasPrefix(prefix), message.hasSuffix("]"), message.utf8.count <= 256 else { return nil }
    let fields = message.dropFirst(prefix.count).dropLast().components(separatedBy: ";kind=")
    guard fields.count == 2, plan.failureStages?.values.contains(fields[0]) == true,
      allowedKinds.contains(fields[1]) else { return nil }
    let diagnostic = Self(stage: fields[0], kind: fields[1])
    return diagnostic.message == message ? diagnostic : nil
  }
}

struct PrivateWorkflowExecutionFailure: Error, Sendable {
  let code: AdapterExecutionErrorCode
  let diagnostic: PrivateWorkflowFailureDiagnostic
}
