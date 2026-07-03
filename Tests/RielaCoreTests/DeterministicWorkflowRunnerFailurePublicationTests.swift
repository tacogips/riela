import RielaObservability
import XCTest
@testable import RielaCore

private enum FailurePublishingError: Error {
  case writeFailed
}

private struct FailureThrowingPublisher: WorkflowOutputPublishing {
  func publishAcceptedOutput(_: WorkflowPublicationRequest) async throws -> WorkflowPublicationResult {
    throw FailurePublishingError.writeFailed
  }
}

final class RunnerFailurePublicationTests: XCTestCase {
  func testFailurePublicationErrorIsLoggedAndOriginalAdapterFailureIsThrown() async throws {
    let telemetry = InMemoryRielaTelemetry()
    let runner = DeterministicWorkflowRunner(
      adapter: FailingAdapter(),
      publisher: FailureThrowingPublisher(),
      telemetry: telemetry
    )

    do {
      _ = try await runner.run(request())
      XCTFail("expected adapter failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error, AdapterExecutionError(.providerError, "forced failure"))
    } catch {
      XCTFail("expected adapter failure, got \(error)")
    }

    let logs = await telemetry.logs()
    let log = try XCTUnwrap(logs.first { $0.name == "riela.workflow.publish.failure" })
    XCTAssertEqual(log.severity, "ERROR")
    XCTAssertEqual(log.attributes["node.step.id"], "step")
    XCTAssertEqual(log.attributes["node.id"], "node")
    XCTAssertEqual(log.attributes["attempt"], "1")
    XCTAssertEqual(log.attributes["backend"], "codex-agent")
    XCTAssertEqual(log.attributes["error_code"], "provider_error")
    XCTAssertEqual(log.attributes["error_class"], "FailurePublishingError")
  }

  private func request() -> DeterministicWorkflowRunRequest {
    DeterministicWorkflowRunRequest(
      workflow: WorkflowDefinition(
        workflowId: "runner",
        defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
        entryStepId: "step",
        nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
        steps: [WorkflowStepRef(id: "step", nodeId: "node")],
        nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")]
      ),
      nodePayloads: [
        "node": AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5")
      ]
    )
  }
}
