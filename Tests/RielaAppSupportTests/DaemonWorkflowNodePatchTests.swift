#if os(macOS)
import Foundation
@testable import RielaAppSupport
import RielaCore
import RielaServer
import XCTest

final class DaemonWorkflowNodePatchTests: XCTestCase {
  func testWorkflowPreferenceStoresNodePatchWithoutMutatingWorkflow() throws {
    let preference = RielaAppDaemonWorkflowPreference(
      identity: "user-workflow:demo",
      available: true,
      active: true,
      nodePatches: [
        "worker": RielaAppDaemonWorkflowNodePatch(
          executionBackend: .codexAgent,
          model: "gpt-5-mini",
          effort: .low
        )
      ]
    )

    let data = try JSONEncoder().encode(preference)
    let decoded = try JSONDecoder().decode(RielaAppDaemonWorkflowPreference.self, from: data)

    XCTAssertEqual(decoded.nodePatches["worker"]?.model, "gpt-5-mini")
    XCTAssertEqual(decoded.nodePatchJSONObject, [
      "worker": .object([
        "executionBackend": .string("codex-agent"),
        "model": .string("gpt-5-mini"),
        "effort": .string("low")
      ])
    ])
  }

  func testWorkflowPreferenceStoresInstanceEnvironmentAndVariables() throws {
    let preference = RielaAppDaemonWorkflowPreference(
      identity: "telegram-persona-a",
      sourceIdentity: "user-workflow:telegram-bot",
      displayName: "Telegram Persona A",
      available: true,
      active: true,
      workingDirectory: "/projects/persona-a",
      environmentVariables: [
        "TELEGRAM_BOT_TOKEN": "token-a",
        "PERSONA": "assistant-a"
      ],
      defaultVariables: [
        "persona": .string("assistant-a"),
        "temperature": .number(0.2)
      ],
      nodePatches: [
        "worker": RielaAppDaemonWorkflowNodePatch(model: "gpt-5-mini")
      ]
    )

    let data = try JSONEncoder().encode(preference)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let configuration = try XCTUnwrap(object["configuration"] as? [String: Any])
    let decoded = try JSONDecoder().decode(RielaAppDaemonWorkflowPreference.self, from: data)

    XCTAssertNil(object["environmentVariables"])
    XCTAssertNil(object["defaultVariables"])
    XCTAssertNil(object["nodePatches"])
    XCTAssertEqual(configuration["workingDirectory"] as? String, "/projects/persona-a")
    XCTAssertEqual(decoded.identity, "telegram-persona-a")
    XCTAssertEqual(decoded.sourceIdentity, "user-workflow:telegram-bot")
    XCTAssertEqual(decoded.displayName, "Telegram Persona A")
    XCTAssertEqual(decoded.workingDirectory, "/projects/persona-a")
    XCTAssertEqual(decoded.environmentVariables["PERSONA"], "assistant-a")
    XCTAssertEqual(decoded.defaultVariables["persona"], .string("assistant-a"))
    XCTAssertEqual(decoded.nodePatchJSONObject?["worker"], .object(["model": .string("gpt-5-mini")]))
  }

  func testWorkflowPreferenceDecodesLegacyInstanceConfigurationFields() throws {
    let data = Data("""
    {
      "identity": "telegram-persona-a",
      "sourceIdentity": "user-workflow:telegram-bot",
      "available": true,
      "active": true,
      "environmentFilePath": "/secrets/persona-a.env",
      "environmentVariables": {"PERSONA": "assistant-a"},
      "defaultVariables": {"persona": "assistant-a"},
      "nodePatches": {"worker": {"model": "gpt-5-mini"}}
    }
    """.utf8)

    let decoded = try JSONDecoder().decode(RielaAppDaemonWorkflowPreference.self, from: data)

    XCTAssertEqual(decoded.environmentFilePath, "/secrets/persona-a.env")
    XCTAssertEqual(decoded.environmentVariables["PERSONA"], "assistant-a")
    XCTAssertEqual(decoded.defaultVariables["persona"], .string("assistant-a"))
    XCTAssertEqual(decoded.nodePatches["worker"]?.model, "gpt-5-mini")
  }

  func testStateProjectsMultipleManagedInstancesFromOneSourceWorkflow() {
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:telegram-bot",
      workflowId: "telegram-bot",
      displayName: "Telegram Bot",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/telegram-bot",
      workingDirectory: "/workflows",
      eventRoot: "/workflows/telegram-bot/.riela-events",
      eventSources: [RielaAppDaemonEventSourceSummary(id: "telegram", kind: "telegram-gateway")]
    )
    let state = RielaAppDaemonWorkflowState(preferences: [
      "persona-a": RielaAppDaemonWorkflowPreference(
        identity: "persona-a",
        sourceIdentity: source.id,
        displayName: "Persona A",
        available: true,
        environmentVariables: ["PERSONA": "a"]
      ),
      "persona-b": RielaAppDaemonWorkflowPreference(
        identity: "persona-b",
        sourceIdentity: source.id,
        displayName: "Persona B",
        available: true,
        defaultVariables: ["persona": .string("b")]
      )
    ])

    let candidates = state.managedCandidates(from: [source])

    XCTAssertEqual(candidates.map(\.id), ["persona-a", "persona-b"])
    XCTAssertEqual(candidates.map(\.sourceIdentity), [source.id, source.id])
    XCTAssertEqual(candidates.map(\.displayName), ["Persona A", "Persona B"])
    XCTAssertTrue(candidates.allSatisfy(\.isManagedInstance))
  }

  func testProcessEventSourceFactoryPassesNodePatchToEventsServeCommand() async throws {
    let process = NodePatchFakeEventServeProcessHandle(isRunning: true)
    let launcher = NodePatchEventLauncher(process: process)
    let factory = RielaAppDaemonProcessEventSourceFactory(
      executablePath: "/bin/echo",
      launcher: launcher,
      earlyExitGraceNanoseconds: 0
    )

    _ = try await factory.startEventSources(
      for: WorkflowServeResolvedWorkflow(workflowId: "chat-workflow", selectedIdentity: "chat-workflow"),
      request: WorkflowServeStartRequest(
        selection: .directDirectory("/users/workflows/chat-workflow", identifier: "chat-workflow"),
        workingDirectory: "/users/workflows",
        eventRoot: "/users/workflows/chat-workflow/.riela-events",
        nodePatch: [
          "worker": .object(["model": .string("gpt-5-mini")])
        ],
        startsEventSources: true
      ),
      generationId: "generation-1"
    )

    let command = try XCTUnwrap(launcher.commands.first)
    guard let patchIndex = command.arguments.firstIndex(of: "--node-patch") else {
      return XCTFail("expected --node-patch")
    }
    XCTAssertEqual(command.arguments[patchIndex + 1], #"{"worker":{"model":"gpt-5-mini"}}"#)
  }

  func testProcessEventSourceFactoryPassesVariablesToEventsServeCommand() async throws {
    let process = NodePatchFakeEventServeProcessHandle(isRunning: true)
    let launcher = NodePatchEventLauncher(process: process)
    let factory = RielaAppDaemonProcessEventSourceFactory(
      executablePath: "/bin/echo",
      launcher: launcher,
      earlyExitGraceNanoseconds: 0
    )

    _ = try await factory.startEventSources(
      for: WorkflowServeResolvedWorkflow(workflowId: "chat-workflow", selectedIdentity: "chat-workflow"),
      request: WorkflowServeStartRequest(
        selection: .directDirectory("/users/workflows/chat-workflow", identifier: "chat-workflow"),
        workingDirectory: "/users/workflows",
        eventRoot: "/users/workflows/chat-workflow/.riela-events",
        defaultVariables: [
          "persona": .string("assistant-a")
        ],
        startsEventSources: true
      ),
      generationId: "generation-1"
    )

    let command = try XCTUnwrap(launcher.commands.first)
    guard let variableIndex = command.arguments.firstIndex(of: "--variables") else {
      return XCTFail("expected --variables")
    }
    XCTAssertEqual(command.arguments[variableIndex + 1], #"{"persona":"assistant-a"}"#)
  }

  func testProcessEventSourceFactorySeparatesWorkflowDefinitionDirFromRuntimeWorkingDirectory() async throws {
    let process = NodePatchFakeEventServeProcessHandle(isRunning: true)
    let launcher = NodePatchEventLauncher(process: process)
    let factory = RielaAppDaemonProcessEventSourceFactory(
      executablePath: "/bin/echo",
      launcher: launcher,
      earlyExitGraceNanoseconds: 0
    )

    _ = try await factory.startEventSources(
      for: WorkflowServeResolvedWorkflow(
        workflowId: "chat-workflow",
        selectedIdentity: "chat-workflow",
        workflowDirectory: "/users/workflows/chat-workflow"
      ),
      request: WorkflowServeStartRequest(
        selection: .directDirectory("/users/workflows/chat-workflow", identifier: "chat-workflow"),
        configuration: WorkflowServeRuntimeConfiguration(
          workingDirectory: "/projects/persona-a",
          inheritedEnvironment: ["TOKEN": "value"],
          defaultVariables: ["persona": .string("assistant-a")]
        ),
        eventRoot: "/users/workflows/chat-workflow/.riela-events",
        startsEventSources: true
      ),
      generationId: "generation-1"
    )

    let command = try XCTUnwrap(launcher.commands.first)
    guard let definitionIndex = command.arguments.firstIndex(of: "--workflow-definition-dir") else {
      return XCTFail("expected --workflow-definition-dir")
    }
    guard let workingDirectoryIndex = command.arguments.firstIndex(of: "--working-directory") else {
      return XCTFail("expected --working-directory")
    }
    XCTAssertEqual(command.arguments[definitionIndex + 1], "/users/workflows/chat-workflow")
    XCTAssertEqual(command.arguments[workingDirectoryIndex + 1], "/projects/persona-a")
    XCTAssertEqual(command.workingDirectory, "/projects/persona-a")
  }

  @MainActor
  func testRuntimeRestartsWorkflowWhenEventSourceExits() async throws {
    let root = try temporaryHome()
    let workflowDirectory = root.appendingPathComponent(".riela/workflows/chat-workflow", isDirectory: true)
    try writeRunnableWorkflow(id: "chat-workflow", to: workflowDirectory)
    let factory = NodePatchRestartFactory()
    let runtime = RielaAppDaemonWorkflowRuntime(eventSourceFactory: factory, monitorIntervalNanoseconds: 10_000_000)
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:chat-workflow",
      workflowId: "chat-workflow",
      displayName: "chat-workflow",
      sourceDescription: "user workflow",
      workflowDirectory: workflowDirectory.path,
      workingDirectory: workflowDirectory.deletingLastPathComponent().path,
      eventRoot: workflowDirectory.appendingPathComponent(".riela-events", isDirectory: true).path,
      eventSources: [RielaAppDaemonEventSourceSummary(id: "chat-source", kind: "telegram-gateway")]
    )

    await runtime.start(
      candidate,
      configuration: WorkflowServeRuntimeConfiguration(
        workingDirectory: root.path,
        inheritedEnvironment: ["RIELA_APP_TEST_TOKEN": "runtime-token"],
        defaultVariables: ["persona": .string("assistant-a")],
        nodePatch: ["worker": .object(["model": .string("gpt-5-mini")])]
      )
    )
    factory.markLatestExited()

    for _ in 0..<50 where factory.startCount < 2 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertGreaterThanOrEqual(factory.startCount, 2)
    XCTAssertEqual(factory.requests.last?.workingDirectory, root.path)
    XCTAssertEqual(factory.requests.last?.inheritedEnvironment["RIELA_APP_TEST_TOKEN"], "runtime-token")
    XCTAssertEqual(factory.requests.last?.defaultVariables["persona"], .string("assistant-a"))
    XCTAssertEqual(factory.requests.last?.nodePatch?["worker"], .object(["model": .string("gpt-5-mini")]))
    await runtime.stop(identity: candidate.id)
  }

  private func temporaryHome() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("riela-app-node-patch-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }

  private func writeRunnableWorkflow(id: String, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "\(id)",
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
    """.write(to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
  }
}

private final class NodePatchEventLauncher: RielaAppDaemonEventServeProcessLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private let process: NodePatchFakeEventServeProcessHandle
  private var recordedCommands: [RielaAppDaemonEventServeCommand] = []

  var commands: [RielaAppDaemonEventServeCommand] {
    lock.withLock { recordedCommands }
  }

  init(process: NodePatchFakeEventServeProcessHandle) {
    self.process = process
  }

  func launch(_ command: RielaAppDaemonEventServeCommand) throws -> any RielaAppDaemonEventServeProcessHandle {
    lock.withLock {
      recordedCommands.append(command)
    }
    return process
  }
}

private final class NodePatchFakeEventServeProcessHandle: RielaAppDaemonEventServeProcessHandle, @unchecked Sendable {
  var processIdentifier: Int32
  var isRunning: Bool
  var terminationStatus: Int32?
  var capturedOutput: String
  private(set) var terminated = false

  init(
    processIdentifier: Int32 = 123,
    isRunning: Bool,
    terminationStatus: Int32? = nil,
    capturedOutput: String = ""
  ) {
    self.processIdentifier = processIdentifier
    self.isRunning = isRunning
    self.terminationStatus = terminationStatus
    self.capturedOutput = capturedOutput
  }

  func terminate() async {
    terminated = true
    isRunning = false
  }
}

private final class NodePatchRestartFactory: WorkflowServeEventSourceFactory, @unchecked Sendable {
  private let lock = NSLock()
  private var handles: [NodePatchRestartHandle] = []
  private var recordedRequests: [WorkflowServeStartRequest] = []

  var startCount: Int {
    lock.withLock { handles.count }
  }

  var requests: [WorkflowServeStartRequest] {
    lock.withLock { recordedRequests }
  }

  func startEventSources(
    for resolvedWorkflow: WorkflowServeResolvedWorkflow,
    request: WorkflowServeStartRequest,
    generationId: String
  ) async throws -> [any WorkflowServeEventSourceHandle] {
    let handle = NodePatchRestartHandle(generationId: generationId)
    lock.withLock {
      handles.append(handle)
      recordedRequests.append(request)
    }
    return [handle]
  }

  func markLatestExited() {
    lock.withLock { handles.last }?.markExited()
  }
}

private final class NodePatchRestartHandle: WorkflowServeEventSourceHandle, @unchecked Sendable {
  private let lock = NSLock()
  private let generationId: String
  private var running = true

  init(generationId: String) {
    self.generationId = generationId
  }

  var status: WorkflowServeEventSourceStatus {
    lock.withLock {
      WorkflowServeEventSourceStatus(
        sourceId: "restart-counting",
        status: running ? "running" : "exited",
        generationId: generationId
      )
    }
  }

  func markExited() {
    lock.withLock {
      running = false
    }
  }

  func shutdown() async throws {
    markExited()
  }
}
#endif
