import RielaObservability
import XCTest
@testable import RielaCore

/// Finalization stays best-effort, but a skipped acknowledgment or terminal
/// record (for example a busy admission pool) must be reported, not swallowed.
final class AddonFinalizationSkipReportTests: XCTestCase {
  func testSkippedAcknowledgmentAndTerminalRecordAreLoggedAsWarnings() async throws {
    let telemetry = InMemoryRielaTelemetry()
    let resolver = BusyFinalizationResolver()
    let runner = DeterministicWorkflowRunner(addonResolver: resolver, telemetry: telemetry)
    let result = try await runner.run(DeterministicWorkflowRunRequest(workflow: finalizingWorkflow()))
    XCTAssertEqual(result.status, .completed, "finalization failures must not fail an accepted run")
    let skipped = await telemetry.logs().filter { $0.name == "riela.workflow.addon.finalization.skipped" }
    XCTAssertEqual(skipped.map { $0.attributes["finalization.kind"] }.sorted { ($0 ?? "") < ($1 ?? "") }, ["acknowledge", "terminal"])
    for log in skipped {
      XCTAssertEqual(log.severity, "WARNING")
      XCTAssertEqual(log.attributes["error_code"], AdapterExecutionErrorCode.timeout.rawValue)
      XCTAssertEqual(log.attributes["error_class"], "sandbox admission deadline reached")
      if log.attributes["finalization.kind"] == "terminal" {
        XCTAssertEqual(log.attributes["workflow.id"], "finalization-skip")
        XCTAssertNil(log.attributes["node.step.id"])
      } else {
        XCTAssertEqual(log.attributes["node.step.id"], "finalize")
      }
    }
    let attempts = await resolver.attempts
    XCTAssertEqual(attempts, ["acknowledge", "terminal"])
  }

  func testSkippedFinalizationStreamsBackendEventWhenHandlerIsKnown() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let resolver = BusyFinalizationResolver()
    let runner = DeterministicWorkflowRunner(store: store, addonResolver: resolver)
    let result = try await runner.run(DeterministicWorkflowRunRequest(workflow: finalizingWorkflow()))
    let execution = try XCTUnwrap(result.session.executions.first)
    let events = SkipEventRecorder()
    let handler: WorkflowRunEventHandler = { event in await events.append(event) }
    await runner.acknowledgeAcceptedFinalization(in: execution, session: result.session, handler: handler)
    await runner.recordTerminalFinalization(in: result.session, handler: handler)
    let recorded = await events.events
    XCTAssertEqual(recorded.count, 2)
    XCTAssertEqual(recorded.map(\.backendEventType), Array(repeating: DeterministicWorkflowRunner.addonFinalizationSkippedEventType, count: 2))
    XCTAssertEqual(recorded.first?.stepId, "finalize")
    XCTAssertEqual(recorded.first?.executionId, execution.executionId)
    XCTAssertNil(recorded.last?.stepId)
    XCTAssertEqual(recorded.map { $0.backendEventMetadata?["operation"] }, [.string("acknowledge"), .string("terminal")])
    XCTAssertEqual(recorded.first?.backendEventMetadata?["errorCode"], .string("timeout"))
  }

  private func finalizingWorkflow() -> WorkflowDefinition {
    let addon = WorkflowNodeAddonRef(name: "test/finalizing-addon", version: "1")
    return WorkflowDefinition(
      workflowId: "finalization-skip", defaults: WorkflowDefaults(nodeTimeoutMs: 30_000, maxLoopIterations: 1),
      entryStepId: "finalize", nodeRegistry: [WorkflowNodeRegistryRef(id: "finalize", addon: addon)],
      steps: [WorkflowStepRef(id: "finalize", nodeId: "finalize")], nodes: [WorkflowNodeRef(id: "finalize", addon: addon)])
  }
}

private actor BusyFinalizationResolver: WorkflowAddonResolving, WorkflowAddonFinalizationAcknowledging,
  WorkflowAddonTerminalRecording {
  var attempts: [String] = []

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    .init(provider: "fixture", model: "fixture", promptText: "", completionPassed: true, payload: [:],
      runtimeFinalizationToken: WorkflowAddonFinalizationToken(value: "busy-token"))
  }

  func acknowledgeAcceptedFinalization(_ token: WorkflowAddonFinalizationToken) async throws {
    attempts.append("acknowledge")
    throw AdapterExecutionError(.timeout, "sandbox admission deadline reached")
  }

  func recordTerminalFinalization(workflowExecutionId: String, stepExecutionIds: [String]) async throws {
    attempts.append("terminal")
    throw AdapterExecutionError(.timeout, "sandbox admission deadline reached")
  }
}

private actor SkipEventRecorder {
  var events: [WorkflowRunEvent] = []
  func append(_ event: WorkflowRunEvent) { events.append(event) }
}
