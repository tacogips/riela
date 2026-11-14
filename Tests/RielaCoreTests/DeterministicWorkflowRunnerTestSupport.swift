import XCTest
import RielaMemory
@testable import RielaCore

struct FailingAdapter: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    throw AdapterExecutionError(.providerError, "forced failure")
  }
}

struct CancellingAdapter: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    throw CancellationError()
  }
}

struct StaticAdapter: NodeAdapter {
  var output: AdapterExecutionOutput

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    output
  }
}

struct BackendEventEmittingAdapter: NodeAdapter {
  var event: AdapterBackendEvent

  init(event: AdapterBackendEvent) {
    self.event = event
  }

  init(eventType: String) {
    self.event = AdapterBackendEvent(provider: "test", eventType: eventType)
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    var emitted = event
    if emitted.provider.isEmpty {
      emitted.provider = input.node.executionBackend?.rawValue ?? "test"
    }
    await context.backendEventHandler?(emitted)
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }
}

actor WorkflowRunEventRecorder {
  private var recordedEvents: [WorkflowRunEvent] = []

  func append(_ event: WorkflowRunEvent) {
    recordedEvents.append(event)
  }

  func events() -> [WorkflowRunEvent] {
    recordedEvents
  }
}

struct StepCancellingInputResolver: WorkflowMessageInputResolving {
  var cancelledStepId: String
  var delegate = DefaultWorkflowMessageInputResolver()

  func resolveInput(
    for sessionId: String,
    stepId: String,
    store: any WorkflowRuntimeStore
  ) async throws -> WorkflowResolvedMessageInput {
    if stepId == cancelledStepId {
      throw CancellationError()
    }
    return try await delegate.resolveInput(for: sessionId, stepId: stepId, store: store)
  }
}

struct StepCapturingAdapter: NodeAdapter {
  var outputsByStep: [String: AdapterExecutionOutput]

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    outputsByStep[input.node.id] ?? AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }
}

actor DeadlineCapturingAdapter: NodeAdapter {
  private(set) var deadline: Date?

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    deadline = context.deadline
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }

  func capturedDeadline() -> Date? {
    deadline
  }
}

actor InputCapturingAdapter: NodeAdapter {
  private var input: AdapterExecutionInput?

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    self.input = input
    return AdapterExecutionOutput(
      provider: "test",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }

  func capturedInput() -> AdapterExecutionInput? {
    input
  }
}

actor CapturingAddonResolver: WorkflowAddonResolving {
  private var input: WorkflowAddonExecutionInput?
  var output: AdapterExecutionOutput

  init(output: AdapterExecutionOutput) {
    self.output = output
  }

  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    self.input = input
    return output
  }

  func capturedInput() -> WorkflowAddonExecutionInput? {
    input
  }
}

actor StaticStdioNodeExecutor: WorkflowStdioNodeExecuting {
  private let result: WorkflowStdioNodeExecutionResult?
  private let error: AdapterExecutionError?
  private var inputs: [WorkflowStdioNodeExecutionInput] = []

  init(result: WorkflowStdioNodeExecutionResult? = nil, error: AdapterExecutionError? = nil) {
    self.result = result
    self.error = error
  }

  func execute(
    _ input: WorkflowStdioNodeExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> WorkflowStdioNodeExecutionResult {
    inputs.append(input)
    if let error {
      throw error
    }
    return result ?? WorkflowStdioNodeExecutionResult(payload: nil)
  }

  func capturedInputs() -> [WorkflowStdioNodeExecutionInput] {
    inputs
  }
}

func XCTAssertThrowsErrorAsync(
  _ expression: @autoclosure () async throws -> some Sendable,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("expected error", file: file, line: line)
  } catch {}
}

extension InMemoryWorkflowRuntimeStore {
  func loadSessionForTest(id: String) async -> WorkflowSession? {
    try? await loadSession(id: id)
  }
}
