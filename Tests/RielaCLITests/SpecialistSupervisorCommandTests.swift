import Foundation
import XCTest
import RielaCore
@testable import RielaCLI
@testable import RielaWorkflowRegistry

final class SpecialistSupervisorCommandTests: XCTestCase {
  func testCompactCatalogDoesNotExposePromptAndPinsClosureRevision() throws {
    let root = try taskDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = root.appendingPathComponent(".riela/workflows/catalog-test", isDirectory: true)
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try Data("{\"workflowId\":\"catalog-test\",\"description\":\"  Short   description  \",\"defaults\":{},\"entryStepId\":\"entry\",\"nodes\":[],\"steps\":[]}".utf8)
      .write(to: workflow.appendingPathComponent("workflow.json"))
    try Data("secret prompt must not be in card".utf8).write(to: workflow.appendingPathComponent("nodes/secret.md"))
    let first = try XCTUnwrap(WorkflowCompactCatalog().list(workingDirectory: root.path).first { $0.workflowId == "catalog-test" })
    XCTAssertEqual(first.shortSummary, "Short description")
    XCTAssertFalse(try json(first).contains("secret prompt"))
    try Data("changed executable asset".utf8).write(to: workflow.appendingPathComponent("nodes/secret.md"))
    let second = try XCTUnwrap(WorkflowCompactCatalog().refresh(workingDirectory: root.path).first { $0.workflowId == "catalog-test" })
    XCTAssertNotEqual(first.revision, second.revision)
  }

  func testHermeticSmokeUsesActualSpecialistCommandComposition() async throws {
    let root = try taskDirectory()
    defer { try? removeSnapshotFixture(root) }
    let source = root.appendingPathComponent("smoke-work/.riela/workflows/specialist-smoke")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let executable = source.appendingPathComponent("fixture-tool.sh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let result = await SpecialistCommandRunner().run(SpecialistCommand(kind: .smoke, options: CLICommandOptions(
      scope: "specialist", command: "smoke", target: nil, arguments: ["--state-root", root.path], output: .json
    )))
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("stub-boundary-real-runner"))
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let task = try XCTUnwrap(try store.task(
      taskId: "task-smoke-request",
      principal: SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")
    ))
    XCTAssertEqual(task.state, .succeeded, "A successful command exit must correspond to a successful child task")
    let dispatch = try XCTUnwrap(try store.dispatch(dispatchId: "dispatch-smoke-request"))
    XCTAssertEqual(task.childSessionId, dispatch.childSessionId)
    XCTAssertNotNil(dispatch.resultJSON)
    let runtimeRoot = URL(fileURLWithPath: store.databasePath).deletingLastPathComponent().path
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
      .load(sessionId: dispatch.childSessionId)
    XCTAssertEqual(snapshot.session.status, .completed)
    XCTAssertFalse(snapshot.session.executions.isEmpty, "The smoke must execute a child node, not just update task state")
    XCTAssertTrue(snapshot.session.executions.allSatisfy { $0.status == .completed })
    let capturedExecutable = root.appendingPathComponent("workflow-snapshots/dispatch-smoke-request/fixture-tool.sh")
    let attributes = try FileManager.default.attributesOfItem(atPath: capturedExecutable.path)
    let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    XCTAssertNotEqual(mode & 0o100, 0, "Snapshot must retain executable scripts")
    XCTAssertEqual(mode & 0o222, 0, "Snapshot assets must not remain writable")
  }

  func testSDKPlanningDispatchesSelectedWorkflowWithoutExplicitWorkflowOrVariables() async throws {
    let root = try taskDirectory()
    defer { try? removeSnapshotFixture(root) }
    let seeded = await SpecialistCommandRunner().run(SpecialistCommand(kind: .smoke, options: CLICommandOptions(
      scope: "specialist", command: "smoke", target: nil, arguments: ["--state-root", root.path], output: .json
    )))
    XCTAssertEqual(seeded.exitCode, .success, seeded.stderr)
    let work = root.appendingPathComponent("smoke-work")
    let card = try WorkflowCompactCatalog().select(workflowId: "specialist-smoke", workingDirectory: work.path)
    let adapter = PlanningCompositionAdapter(card: card)
    let runner = SpecialistCommandRunner(classifierAdapter: adapter)
    let config = work.appendingPathComponent("sdk-specialists.json")
    let node = AgentNodePayload(id: "planner", executionBackend: .officialOpenAISDK, model: "fixture")
    let nodeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node))
    let configuration: [String: Any] = [
      "specialists": [["id": "engineering", "capacity": 1, "domain": "software", "allowedOriginIds": [card.originId]]],
      "classifier": ["node": nodeJSON]
    ]
    try JSONSerialization.data(withJSONObject: configuration).write(to: config)
    let arguments = ["--state-root", root.path, "--working-dir", work.path,
                     "--specialist-config", config.path, "--mock-scenario", work.appendingPathComponent("smoke-scenario.json").path]
    let submitted = await runner.run(SpecialistCommand(kind: .submit, options: CLICommandOptions(
      scope: "specialist", command: "submit", target: "sdk-request", arguments: arguments, output: .json
    )))
    XCTAssertEqual(submitted.exitCode, .success, submitted.stderr)
    let replayed = await runner.run(SpecialistCommand(kind: .submit, options: CLICommandOptions(
      scope: "specialist", command: "submit", target: "sdk-request", arguments: arguments, output: .json
    )))
    XCTAssertEqual(replayed.exitCode, .success, replayed.stderr)
    XCTAssertTrue(replayed.stdout.contains("already_accepted"))
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let dispatch = try XCTUnwrap(try store.dispatch(dispatchId: "dispatch-sdk-request"))
    XCTAssertEqual(dispatch.workflowId, card.workflowId)
    XCTAssertEqual(dispatch.workflowOriginId, card.originId)
    XCTAssertEqual(dispatch.workflowRevision, card.revision)
    let variables = try JSONDecoder().decode(JSONObject.self, from: Data(try XCTUnwrap(dispatch.inputJSON).utf8))
    XCTAssertEqual(variables["request"], .string("prepared by SDK"))
    let plannedInputs = await adapter.inputs
    XCTAssertEqual(plannedInputs.count, 3, "Ownership, selection and input preparation must all use the adapter")
    let executed = await runner.run(SpecialistCommand(kind: .execute, options: CLICommandOptions(
      scope: "specialist", command: "execute", target: dispatch.dispatchId, arguments: arguments, output: .json
    )))
    XCTAssertEqual(executed.exitCode, .success, executed.stderr)
    let task = try store.task(taskId: "task-sdk-request", principal: .init(accountId: "local", actorId: "operator", roomId: "local"))
    XCTAssertEqual(task?.state, .succeeded)
    let runtimeRoot = URL(fileURLWithPath: store.databasePath).deletingLastPathComponent().path
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot).load(sessionId: dispatch.childSessionId)
    XCTAssertEqual(snapshot.session.status, .completed)
    XCTAssertFalse(snapshot.session.executions.isEmpty)
  }

  func testRestartSafeServiceSweepRoutesClarificationContinuationOnce() async throws {
    let root = try taskDirectory()
    defer { try? removeSnapshotFixture(root) }
    let runner = SpecialistCommandRunner()
    let seeded = await runner.run(SpecialistCommand(kind: .smoke, options: .init(
      scope: "specialist", command: "smoke", target: nil,
      arguments: ["--state-root", root.path], output: .json
    )))
    XCTAssertEqual(seeded.exitCode, .success, seeded.stderr)

    let work = root.appendingPathComponent("smoke-work")
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")
    let original = SpecialistRequest(
      requestId: "continuation-root", sourceEventId: "continuation-root-event",
      principal: principal, route: .work, body: "need clarification"
    )
    let queued = try XCTUnwrap(try store.createTaskIfWorkRequest(original, taskId: "continuation-task"))
    _ = try store.transition(taskId: queued.taskId, to: .needsClarification, expectedVersion: queued.version)
    let continuation = try XCTUnwrap(try store.beginClarificationContinuation(.init(
      requestId: "continuation-reply", sourceEventId: "continuation-reply-event",
      principal: principal, route: .clarification, body: "the needed detail"
    )))

    let arguments = [
      "--state-root", root.path, "--working-dir", work.path,
      "--workflow", "specialist-smoke", "--variables", "{\"workflowInput\":{\"request\":\"continued\"}}",
      "--specialist-config", work.appendingPathComponent("specialists.json").path,
      "--mock-scenario", work.appendingPathComponent("smoke-scenario.json").path, "--once"
    ]
    let first = await runner.run(SpecialistCommand(kind: .serve, options: .init(
      scope: "specialist", command: "serve", target: nil, arguments: arguments, output: .json
    )))
    XCTAssertEqual(first.exitCode, .success, first.stderr)
    let dispatchID = "dispatch-\(continuation.request.requestId)"
    XCTAssertEqual(try store.dispatch(dispatchId: dispatchID)?.state, .terminal)
    XCTAssertEqual(try store.task(taskId: queued.taskId, principal: principal)?.state, .succeeded)

    let reopened = SpecialistSupervisorStore(databasePath: store.databasePath)
    XCTAssertTrue(try reopened.pendingClarificationContinuations().isEmpty)
    let second = await runner.run(SpecialistCommand(kind: .serve, options: .init(
      scope: "specialist", command: "serve", target: nil, arguments: arguments, output: .json
    )))
    XCTAssertEqual(second.exitCode, .success, second.stderr)
    XCTAssertEqual(try reopened.recoverableDispatches().filter { $0.taskId == queued.taskId }.map(\.dispatchId), [dispatchID])
  }

  private func json<T: Encodable>(_ value: T) throws -> String {
    String(bytes: try JSONEncoder().encode(value), encoding: .utf8) ?? ""
  }

  private func removeSnapshotFixture(_ root: URL) throws {
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
      for case let file as URL in files {
        let isDirectory = try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        try FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: file.path)
      }
    }
    try FileManager.default.removeItem(at: root)
  }

  private func taskDirectory() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/command-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private actor PlanningCompositionAdapter: NodeAdapter {
  let card: WorkflowCompactCatalogCard
  var inputs: [AdapterExecutionInput] = []

  init(card: WorkflowCompactCatalogCard) { self.card = card }

  func execute(_ input: AdapterExecutionInput, context _: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let responses: [JSONObject] = [
      ["specialistId": .string("engineering"), "kind": .string("claim"), "reason": .string("in domain")],
      ["workflowId": .string(card.workflowId), "originId": .string(card.originId), "revision": .string(card.revision)],
      ["variables": .object(["request": .string("prepared by SDK")]), "needsClarification": .bool(false), "question": .string("")]
    ]
    guard inputs.count < responses.count else { throw SpecialistClassifierError.invalidResponse }
    let response = responses[inputs.count]
    inputs.append(input)
    return AdapterExecutionOutput(provider: "fixture", model: "fixture", promptText: input.promptText, completionPassed: true, payload: response)
  }
}
