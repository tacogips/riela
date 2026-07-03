import Foundation
import RielaObservability

extension DeterministicWorkflowRunner {
  func publishFailureAndThrow(
    _ adapterFailure: AdapterExecutionError,
    sessionId: String,
    step: WorkflowStepRef,
    attempt: Int,
    backend: NodeExecutionBackend? = nil,
    adapterOutput: AdapterExecutionOutput? = nil,
    transitions: [WorkflowStepTransition],
    publishesRootOutput: Bool? = nil,
    throwing originalError: Error? = nil
  ) async throws -> Never {
    do {
      _ = try await publisher.publishAcceptedOutput(
        WorkflowPublicationRequest(
          sessionId: sessionId,
          stepId: step.id,
          nodeId: step.nodeId,
          attempt: attempt,
          backend: backend,
          body: .failure(adapterFailure, adapterOutput: adapterOutput),
          transitions: transitions,
          publishesRootOutput: publishesRootOutput ?? transitions.isEmpty
        )
      )
    } catch let publishedFailure as AdapterExecutionError where publishedFailure == adapterFailure {
      // The in-memory publisher records the failed execution, then rethrows the adapter failure by design.
    } catch {
      await telemetry.recordLog(RielaTelemetryLog(
        name: "riela.workflow.publish.failure",
        severity: "ERROR",
        attributes: failurePublicationAttributes(
          sessionId: sessionId,
          step: step,
          attempt: attempt,
          backend: backend,
          adapterFailure: adapterFailure,
          publicationError: error
        )
      ))
    }
    if let originalError {
      throw originalError
    }
    throw adapterFailure
  }

  private func failurePublicationAttributes(
    sessionId: String,
    step: WorkflowStepRef,
    attempt: Int,
    backend: NodeExecutionBackend?,
    adapterFailure: AdapterExecutionError,
    publicationError: Error
  ) -> [String: String] {
    [
      "session.id": sessionId,
      "node.step.id": step.id,
      "node.id": step.nodeId,
      "attempt": String(attempt),
      "backend": backend?.rawValue ?? "none",
      "error_code": adapterFailure.code.rawValue,
      "error_class": String(describing: type(of: publicationError))
    ]
  }
}
