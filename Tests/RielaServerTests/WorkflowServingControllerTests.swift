import Foundation
import XCTest
@testable import RielaServer

final class WorkflowServingControllerTests: XCTestCase {
  func testStartStopAndRestartUseSharedControllerLifecycle() async throws {
    let recorder = ServeRecorder()
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      resolver: FakeServeResolver(workflowId: "demo-flow"),
      listenerFactory: FakeListenerFactory(recorder: recorder),
      eventSourceFactory: FakeEventSourceFactory(recorder: recorder),
      generationIDGenerator: FakeGenerationIDGenerator()
    ))

    let request = WorkflowServeStartRequest(selection: .scopedName("demo-flow"), startsEventSources: true)
    let started = try await controller.start(request)

    XCTAssertEqual(started.status, .running)
    XCTAssertEqual(started.generation?.generationId, "generation-1")
    XCTAssertEqual(started.generation?.eventSources.map(\.generationId), ["generation-1"])

    let restarted = try await controller.restart()

    XCTAssertEqual(restarted.status, .running)
    XCTAssertEqual(restarted.generation?.generationId, "generation-2")
    let events = await recorder.snapshot()
    XCTAssertEqual(events, [
      "listener-start:generation-1",
      "events-start:generation-1",
      "events-stop:generation-1",
      "listener-stop:generation-1",
      "listener-start:generation-2",
      "events-start:generation-2"
    ])

    let stopped = try await controller.stop()
    XCTAssertEqual(stopped.status, .stopped)
  }

  func testReloadSwapsGenerationAfterReplacementStartsAndStopsOldEventSources() async throws {
    let recorder = ServeRecorder()
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      resolver: FakeServeResolver(workflowId: "demo-flow"),
      listenerFactory: FakeListenerFactory(recorder: recorder),
      eventSourceFactory: FakeEventSourceFactory(recorder: recorder),
      generationIDGenerator: FakeGenerationIDGenerator()
    ))

    _ = try await controller.start(WorkflowServeStartRequest(selection: .scopedName("demo-flow")))
    let reloaded = try await controller.reload()

    XCTAssertEqual(reloaded.status, .running)
    XCTAssertEqual(reloaded.generation?.generationId, "generation-2")
    let events = await recorder.snapshot()
    XCTAssertEqual(events, [
      "listener-start:generation-1",
      "events-start:generation-1",
      "listener-start:generation-2",
      "events-start:generation-2",
      "events-stop:generation-1",
      "listener-stop:generation-1"
    ])
  }

  func testReloadValidationFailureKeepsCurrentGenerationRunning() async throws {
    let recorder = ServeRecorder()
    let resolver = FakeServeResolver(workflowId: "demo-flow")
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      resolver: resolver,
      listenerFactory: FakeListenerFactory(recorder: recorder),
      eventSourceFactory: FakeEventSourceFactory(recorder: recorder),
      generationIDGenerator: FakeGenerationIDGenerator()
    ))

    _ = try await controller.start(WorkflowServeStartRequest(selection: .scopedName("demo-flow")))
    await resolver.setFailure(WorkflowServeError.validationFailed(WorkflowServeDiagnostics(
      code: "updated_workflow_invalid",
      message: "updated workflow is invalid"
    )))

    do {
      _ = try await controller.reload()
      XCTFail("expected reload failure")
    } catch {}

    let state = await controller.currentState()
    XCTAssertEqual(state.status, .running)
    XCTAssertEqual(state.generation?.generationId, "generation-1")
    XCTAssertEqual(state.diagnostics.first?.code, "updated_workflow_invalid")
    let events = await recorder.snapshot()
    XCTAssertEqual(events, [
      "listener-start:generation-1",
      "events-start:generation-1"
    ])
  }

  func testReloadFailIfReplacementFailsStopsCurrentGeneration() async throws {
    let recorder = ServeRecorder()
    let resolver = FakeServeResolver(workflowId: "demo-flow")
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      resolver: resolver,
      listenerFactory: FakeListenerFactory(recorder: recorder),
      eventSourceFactory: FakeEventSourceFactory(recorder: recorder),
      generationIDGenerator: FakeGenerationIDGenerator()
    ))

    _ = try await controller.start(WorkflowServeStartRequest(selection: .scopedName("demo-flow")))
    await resolver.setFailure(WorkflowServeError.validationFailed(WorkflowServeDiagnostics(
      code: "updated_workflow_invalid",
      message: "updated workflow is invalid"
    )))

    do {
      _ = try await controller.reload(WorkflowServeReloadRequest(restartPolicy: .failIfReplacementFails))
      XCTFail("expected reload failure")
    } catch {}

    let state = await controller.currentState()
    XCTAssertEqual(state.status, .failed)
    XCTAssertNil(state.generation)
    let events = await recorder.snapshot()
    XCTAssertEqual(events, [
      "listener-start:generation-1",
      "events-start:generation-1",
      "events-stop:generation-1",
      "listener-stop:generation-1"
    ])
  }

  func testCurrentStateReflectsEventSourceHandleStatusChanges() async throws {
    let eventSource = MutableEventSourceHandle(generationId: "generation-1")
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      resolver: FakeServeResolver(workflowId: "demo-flow"),
      listenerFactory: FakeListenerFactory(recorder: ServeRecorder()),
      eventSourceFactory: FixedEventSourceFactory(eventSource: eventSource),
      generationIDGenerator: FakeGenerationIDGenerator()
    ))

    _ = try await controller.start(WorkflowServeStartRequest(selection: .scopedName("demo-flow")))
    eventSource.updateStatus("exited")

    let state = await controller.currentState()

    XCTAssertEqual(state.generation?.eventSources.first?.status, "exited")
  }

  func testMacStyleClientCanUseControllerWithoutCLI() async throws {
    let controller = WorkflowServingController(dependencies: WorkflowServingDependencies(
      resolver: FakeServeResolver(workflowId: "menu-flow"),
      listenerFactory: FakeListenerFactory(recorder: ServeRecorder()),
      eventSourceFactory: FakeEventSourceFactory(recorder: ServeRecorder()),
      generationIDGenerator: FakeGenerationIDGenerator()
    ))
    let client = MacStyleServeClient(controller: controller)

    try await client.selectAndServe(.scopedName("menu-flow"))
    try await client.update()

    let state = await client.status()
    XCTAssertEqual(state.status, .running)
    XCTAssertEqual(state.generation?.workflowId, "menu-flow")
    XCTAssertEqual(state.generation?.generationId, "generation-2")
  }

  func testDefaultResolverAcceptsAuthoredWorkflowWithoutNodeRegistry() async throws {
    let root = try temporaryDirectory()
    let workflowDirectory = root.appendingPathComponent("authored-flow", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "authored-flow",
      "defaults": {
        "nodeTimeoutMs": 1000,
        "maxLoopIterations": 1
      },
      "entryStepId": "reply",
      "nodes": [
        {
          "id": "reply",
          "addon": {
            "name": "riela/test-reply",
            "version": "1"
          }
        }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)

    let resolved = try await DefaultWorkflowServeResolver().resolve(WorkflowServeStartRequest(
      selection: .directDirectory(workflowDirectory.path, identifier: "authored-flow"),
      workingDirectory: root.path
    ))

    XCTAssertEqual(resolved.workflowId, "authored-flow")
    XCTAssertEqual(resolved.selectedIdentity, "authored-flow")
    XCTAssertEqual(resolved.workflowDirectory, workflowDirectory.path)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("workflow-serving-controller-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return directory
  }
}

private actor MacStyleServeClient {
  private let controller: WorkflowServingController

  init(controller: WorkflowServingController) {
    self.controller = controller
  }

  func selectAndServe(_ selection: WorkflowServeSelection) async throws {
    _ = try await controller.start(WorkflowServeStartRequest(selection: selection))
  }

  func update() async throws {
    _ = try await controller.reload(WorkflowServeReloadRequest())
  }

  func status() async -> WorkflowServeState {
    await controller.currentState()
  }
}

private actor ServeRecorder {
  private var events: [String] = []

  func append(_ event: String) {
    events.append(event)
  }

  func snapshot() -> [String] {
    events
  }
}

private actor FakeServeResolver: WorkflowServeResolving {
  private let workflowId: String
  private var failure: Error?

  init(workflowId: String) {
    self.workflowId = workflowId
  }

  func setFailure(_ failure: Error?) {
    self.failure = failure
  }

  func resolve(_ request: WorkflowServeStartRequest) async throws -> WorkflowServeResolvedWorkflow {
    if let failure {
      throw failure
    }
    return WorkflowServeResolvedWorkflow(
      workflowId: workflowId,
      selectedIdentity: request.selection.identifier
    )
  }
}

private struct FakeListenerFactory: WorkflowServeListenerFactory {
  let recorder: ServeRecorder

  func startListener(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> any WorkflowServeListenerHandle {
    await recorder.append("listener-start:\(generationId)")
    return FakeListenerHandle(endpoint: "http://127.0.0.1:8787", generationId: generationId, recorder: recorder)
  }
}

private struct FakeEventSourceFactory: WorkflowServeEventSourceFactory {
  let recorder: ServeRecorder

  func startEventSources(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> [any WorkflowServeEventSourceHandle] {
    await recorder.append("events-start:\(generationId)")
    return [FakeEventSourceHandle(generationId: generationId, recorder: recorder)]
  }
}

private struct FixedEventSourceFactory: WorkflowServeEventSourceFactory {
  let eventSource: MutableEventSourceHandle

  func startEventSources(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> [any WorkflowServeEventSourceHandle] {
    [eventSource]
  }
}

private struct FakeListenerHandle: WorkflowServeListenerHandle {
  let endpoint: String
  let generationId: String
  let recorder: ServeRecorder

  func shutdown() async throws {
    await recorder.append("listener-stop:\(generationId)")
  }
}

private struct FakeEventSourceHandle: WorkflowServeEventSourceHandle {
  let generationId: String
  let recorder: ServeRecorder

  var status: WorkflowServeEventSourceStatus {
    WorkflowServeEventSourceStatus(sourceId: "fake", status: "running", generationId: generationId)
  }

  func shutdown() async throws {
    await recorder.append("events-stop:\(generationId)")
  }
}

private final class MutableEventSourceHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  private let lock = NSLock()
  private let sourceId: String
  private let generationId: String
  private var currentStatus: String

  init(sourceId: String = "mutable", generationId: String, status: String = "running") {
    self.sourceId = sourceId
    self.generationId = generationId
    self.currentStatus = status
  }

  var status: WorkflowServeEventSourceStatus {
    lock.withLock {
      WorkflowServeEventSourceStatus(sourceId: sourceId, status: currentStatus, generationId: generationId)
    }
  }

  func updateStatus(_ status: String) {
    lock.withLock {
      currentStatus = status
    }
  }

  func shutdown() async throws {
    updateStatus("stopped")
  }
}

private actor FakeGenerationIDGenerator: WorkflowServeGenerationIDGenerating {
  private var counter = 0

  func nextGenerationID() -> String {
    counter += 1
    return "generation-\(counter)"
  }
}
