import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class LookAroundReadOnlyTests: XCTestCase {
  func testCommandNodeIsRejectedBeforeStartingLookAround() async throws {
    let fixture = try fixture()
    let runner = BotJobRunner(service: fixture.service, mockScenarioPath: fixture.scenarioPath, workflowOverride: { workflow in
      var workflow = workflow
      workflow.nodePayloads["look-around"] = AgentNodePayload(
        id: "look-around", nodeType: .command, model: "", command: .init(executable: "/usr/bin/false")
      )
      return workflow
    })

    do {
      _ = try await runner.run(botId: fixture.botId, job: .lookAround, force: true)
      XCTFail("Expected the job policy to reject the command node")
    } catch let error as BotStoreError {
      XCTAssertEqual(error.code, "look_around_not_read_only")
      XCTAssertTrue(error.message.contains("command payload"), error.message)
    }
    XCTAssertTrue(try fixture.service.store.links(botId: fixture.botId).isEmpty)
    XCTAssertTrue(try fixture.service.store.jobRuns(botId: fixture.botId, job: .lookAround, limit: 10).isEmpty)
    XCTAssertTrue(try CLIWorkflowSessionStore(rootDirectory: fixture.service.sessionStoreRoot).list().isEmpty)
  }

  func testLookAroundOverridesWorkspaceWriteAtAdapterBoundary() async throws {
    let fixture = try fixture()
    let adapter = try fixture.adapter(requestsPermission: false)
    let runner = BotJobRunner(
      service: fixture.service, mockScenarioPath: fixture.scenarioPath,
      nodeAdapter: adapter, workflowOverride: Self.withWorkspaceWrite
    )
    let result = try await runner.run(botId: fixture.botId, job: .lookAround, force: true)
    XCTAssertEqual(result.status, .succeeded, result.detail ?? "")
    let sandboxes = await adapter.sandboxes
    XCTAssertEqual(sandboxes, [.readOnly])
    let id = try XCTUnwrap(result.sessionId)
    XCTAssertEqual(try fixture.service.store.link(forSession: id)?.source, "job")
    let recovered = try XCTUnwrap(BotActivityRuntime.botContext(
      forExistingSession: id, sessionStoreRoot: fixture.service.sessionStoreRoot,
      workingDirectory: fixture.service.workingDirectory, environment: fixture.service.environment
    ))
    XCTAssertTrue(recovered.forceReadOnlySandbox)
    XCTAssertEqual(recovered.permissionWaitMs, 0)
  }

  func testJobPermissionIsCancelledByPolicyAndOrdinaryRunKeepsBotWait() async throws {
    let fixture = try fixture()
    let adapter = try fixture.adapter(requestsPermission: true)
    let runner = BotJobRunner(service: fixture.service, mockScenarioPath: fixture.scenarioPath, nodeAdapter: adapter)
    let job = try await runner.run(botId: fixture.botId, job: .lookAround, force: true)
    XCTAssertEqual(job.status, .succeeded, job.detail ?? "")
    let jobResolution = try fixture.permissionResolution(sessionId: XCTUnwrap(job.sessionId))
    XCTAssertEqual(jobResolution.payload["outcome"], .string("cancelled"))
    XCTAssertEqual(jobResolution.payload["resolvedBy"], .string("policy"))

    let bot = try XCTUnwrap(fixture.service.store.load(botId: fixture.botId))
    let workflow = try BotJobWorkflows.make(job: .lookAround, bot: bot, prompt: "Return an empty suggestions array.")
    let target = try jsonString(Self.withWorkspaceWrite(workflow))
    var command = WorkflowRunCommand()
    command.taskNodeAdapterOverride = adapter
    let options = WorkflowRunOptions(
      target: target, mockScenarioPath: fixture.scenarioPath, output: .json,
      sessionStore: fixture.service.sessionStoreRoot, workingDirectory: fixture.service.workingDirectory,
      explicitWorkingDirectory: true, botId: fixture.botId
    )
    let run = await CLIRuntimeEnvironment.$captured.withValue(fixture.service.environment) {
      await CLIRuntimeEnvironment.$overrides.withValue(nil) { await command.run(options) }
    }
    XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
    let plainSession = try XCTUnwrap(try fixture.service.store.links(botId: fixture.botId).first { $0.source == "run" })
    let plainResolution = try fixture.permissionResolution(sessionId: plainSession.sessionId)
    XCTAssertEqual(plainResolution.payload["outcome"], .string("cancelled"))
    XCTAssertEqual(plainResolution.payload["resolvedBy"], .string("timeout"))
    let sandboxes = await adapter.sandboxes
    let outcomes = await adapter.permissionOutcomes
    XCTAssertEqual(sandboxes, [.readOnly, .workspaceWrite])
    XCTAssertEqual(outcomes, [.cancelled, .cancelled])
  }

  private static func withWorkspaceWrite(_ payload: TemporaryWorkflowPayload) -> TemporaryWorkflowPayload {
    var payload = payload
    payload.nodePayloads["look-around"]?.agentSandbox = .workspaceWrite
    return payload
  }

  private func fixture() throws -> LookAroundFixture {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-16-jobs-surfaces/read-only-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return try LookAroundFixture(root: root)
  }
}

private struct LookAroundFixture {
  let botId = "read-only-bot"
  let service: BotsService
  let scenarioPath: String

  init(root: URL) throws {
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    let stamp = RoutineStore.timestamp(date)
    service = BotsService(
      workingDirectory: root.path, sessionStoreRoot: root.appendingPathComponent("sessions").path,
      environment: [
        "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
        "RIELA_WORKFLOW_HOME": root.appendingPathComponent("user").path, "RIELA_API_KEY": ""
      ], now: { date }
    )
    scenarioPath = root.appendingPathComponent("scenario.json").path
    try #"{"look-around":{"payload":{"suggestions":[]}}}"#.write(toFile: scenarioPath, atomically: true, encoding: .utf8)
    _ = try service.store.create(BotRecord(
      botId: botId, name: "Read only bot", defaultBackend: NodeExecutionBackend.codexAgent.rawValue,
      permissionWaitMs: 20, createdAt: stamp, updatedAt: stamp
    ))
  }

  func adapter(requestsPermission: Bool) throws -> LookAroundScenarioAdapter {
    let scenario = try WorkflowMockScenarioLoader().loadScenario(at: scenarioPath)
    return LookAroundScenarioAdapter(
      underlying: ScenarioNodeAdapter(scenario: scenario, requiresScenarioResponse: true),
      requestsPermission: requestsPermission
    )
  }

  func permissionResolution(sessionId: String) throws -> ActivityEvent {
    try XCTUnwrap(service.store.activityPage(sessionId: sessionId).events.first { $0.kind == .permissionResolved })
  }
}

private actor LookAroundScenarioAdapter: NodeAdapter {
  let underlying: ScenarioNodeAdapter
  let requestsPermission: Bool
  private(set) var sandboxes: [AgentSandboxMode?] = []
  private(set) var permissionOutcomes: [AdapterPermissionOutcome] = []

  init(underlying: ScenarioNodeAdapter, requestsPermission: Bool) {
    self.underlying = underlying
    self.requestsPermission = requestsPermission
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    sandboxes.append(input.node.agentSandbox)
    if requestsPermission {
      let handler = try XCTUnwrap(context.permissionRequestHandler)
      let outcome = await handler(AdapterPermissionRequest(toolCallId: "write", title: "Write a file", options: [
        AdapterPermissionOption(optionId: "allow", name: "Allow once", kind: "allow_once")
      ]))
      permissionOutcomes.append(outcome)
    }
    return try await underlying.execute(input, context: context)
  }
}
