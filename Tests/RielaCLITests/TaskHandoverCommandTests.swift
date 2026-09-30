import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

final class TaskHandoverCommandTests: XCTestCase {
  private var sessionStore: URL!
  private var store: WorkStore!

  override func setUpWithError() throws {
    sessionStore = testArtifactRoot.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionStore, withIntermediateDirectories: true)
    store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path))
    try store.saveTask(WorkTask(
      id: TaskID("task-cli"), intentId: IntentID("intent-cli"), title: "CLI handover",
      instruction: "Exercise the handover CLI.", plan: .workflow(WorkflowReference(name: "fixture")), state: .waiting
    ))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: sessionStore)
  }

  func testTaskCommandRoutingIncludesHandoverSurface() throws {
    let parser = RielaArgumentParser()
    for subcommand in ["handover", "takeover", "answer", "handovers"] {
      guard case let .task(command) = try parser.parse(["task", subcommand, "task-cli"]) else {
        return XCTFail("expected task command for \(subcommand)")
      }
      XCTAssertEqual(command.kind.rawValue, subcommand)
    }
    guard case let .task(reconcile) = try parser.parse(["task", "reconcile"]) else {
      return XCTFail("expected task reconcile command")
    }
    XCTAssertEqual(reconcile.kind, .reconcile)
    guard case let .session(.handover(options)) = try parser.parse([
      "session", "handover", "session-1", "--task", "task-cli"
    ]) else { return XCTFail("expected session handover command") }
    XCTAssertEqual(options.target, "session-1")
    XCTAssertTrue(options.arguments.contains("--task"))
  }

  func testTakeoverRejectsUnknownTraitByName() async {
    let result = await run(["task", "takeover", "task-cli", "--traits", "bogus"])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("bogus"), result.stderr)
  }

  func testForceOrphanFlagReachesOrphanFenceRuntime() async {
    let result = await run(["task", "takeover", "task-cli", "--force-orphan"])
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("has no lease"), result.stderr)
  }

  func testAnswerRequiresExactlyOnePayloadFlag() async {
    let result = await run([
      "task", "answer", "task-cli", "--question", "q1", "--text", "one", "--option", "staging"
    ])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("exactly one payload flag"), result.stderr)
  }

  func testReconcileRequiresExpiredLeasesFlag() async {
    let result = await run(["task", "reconcile"])
    XCTAssertEqual(result.exitCode, .usage)
    XCTAssertTrue(result.stderr.contains("supports --expired-leases"), result.stderr)
  }

  func testImmediateHandoverWithoutRunningAttemptFails() async {
    let result = await run(["task", "handover", "task-cli", "--reason", "move", "--now"])
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(commandError(result).contains("requires a running attempt"), commandError(result))
  }

  func testShowIncludesHandoverLeaseAndSuspendFields() async throws {
    let result = await run(["task", "show", "task-cli", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let payload = try JSONDecoder().decode(TaskShowCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.handovers, [])
    XCTAssertNil(payload.lease)
    XCTAssertNil(payload.suspend)
  }

  func testHandoversReturnsEmptyListForTaskWithoutHandover() async throws {
    let result = await run(["task", "handovers", "task-cli", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let payload = try JSONDecoder().decode(TaskHandoversCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.taskId, "task-cli")
    XCTAssertEqual(payload.handovers, [])
  }

  func testEnvelopeRunAppearsInTaskShowAndHandovers() async throws {
    let project = try makeProject()
    defer { try? FileManager.default.removeItem(at: project) }
    let workflowId = "handover-list-\(UUID().uuidString)"
    try writeHandoverWorkflow(project: project, workflowId: workflowId, reason: "userInputRequired")
    try saveTask(id: "task-list", workflowId: workflowId)

    let runResult = await run(["task", "run", "task-list", "--output", "json"], project: project)
    XCTAssertEqual(runResult.exitCode, .suspended, "stderr: \(runResult.stderr); stdout: \(runResult.stdout)")
    let showResult = await run(["task", "show", "task-list", "--output", "json"], project: project)
    let show = try decode(TaskShowCommandResult.self, from: showResult.stdout)
    XCTAssertEqual(show.handovers.count, 1)
    XCTAssertEqual(show.task.state, .waiting)
    XCTAssertEqual(show.handovers[0].digest.count, 64)

    let listResult = await run(["task", "handovers", "task-list", "--output", "json"], project: project)
    let list = try decode(TaskHandoversCommandResult.self, from: listResult.stdout)
    XCTAssertEqual(list.handovers, show.handovers)
  }

  func testAnswerOptionSchedulesTakeoverAndRejectsTamperedPacket() async throws {
    let project = try makeProject()
    defer { try? FileManager.default.removeItem(at: project) }
    let workflowId = "handover-answer-\(UUID().uuidString)"
    try writeHandoverWorkflow(project: project, workflowId: workflowId, reason: "userInputRequired", withOption: true)
    try saveTask(id: "task-answer", workflowId: workflowId)

    let runResult = await run(["task", "run", "task-answer", "--output", "json"], project: project)
    XCTAssertEqual(runResult.exitCode, .suspended, "stderr: \(runResult.stderr); stdout: \(runResult.stdout)")
    let packets = try store.listHandovers(taskId: TaskID("task-answer"))
    let packet = try XCTUnwrap(packets.first)
    let packetURL = project.appendingPathComponent("handover.json")
    try JSONCanonical.encode(packet).write(to: packetURL)

    let invalidOption = await run([
      "task", "answer", "task-answer", "--question", "q1", "--option", "bogus"
    ], project: project)
    XCTAssertEqual(invalidOption.exitCode, .failure)
    XCTAssertTrue(commandError(invalidOption).contains("not among the question's options"), commandError(invalidOption))
    let missingDefault = await run([
      "task", "answer", "task-answer", "--question", "q1", "--use-default"
    ], project: project)
    XCTAssertEqual(missingDefault.exitCode, .failure)
    XCTAssertTrue(commandError(missingDefault).contains("has no default answer"), commandError(missingDefault))

    let answerResult = await run([
      "task", "answer", "task-answer", "--question", "q1", "--option", "staging", "--output", "json"
    ], project: project)
    XCTAssertEqual(answerResult.exitCode, .success, answerResult.stderr)
    let answer = try decode(TaskAnswerCommandResult.self, from: answerResult.stdout)
    XCTAssertEqual(answer.taskState, .scheduled)

    var tampered = packet
    tampered.digest = String(repeating: "0", count: 64)
    try JSONCanonical.encode(tampered).write(to: packetURL)
    let beforeTamperAttemptCount = try store.listAttempts(taskId: TaskID("task-answer")).count
    let tamperedResult = await run([
      "task", "takeover", "task-answer", "--packet", packetURL.path, "--output", "json"
    ], project: project)
    XCTAssertEqual(tamperedResult.exitCode, .failure)
    XCTAssertTrue(commandError(tamperedResult).contains("digest"), commandError(tamperedResult))
    XCTAssertEqual(try store.listAttempts(taskId: TaskID("task-answer")).count, beforeTamperAttemptCount)

    try JSONCanonical.encode(packet).write(to: packetURL)
    let takeoverResult = await run([
      "task", "takeover", "task-answer", "--packet", packetURL.path, "--output", "json"
    ], project: project)
    XCTAssertEqual(takeoverResult.exitCode, .success, "stderr: \(takeoverResult.stderr); stdout: \(takeoverResult.stdout)")
    let attempts = try store.listAttempts(taskId: TaskID("task-answer"))
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts[1].takeoverLineage?.fromAttemptId, attempts[0].id)
    XCTAssertEqual(attempts[1].takeoverLineage?.handoverId, packet.id)
    XCTAssertEqual(try store.loadTask(id: TaskID("task-answer"))?.state, .succeeded)
  }

  func testPresenceTakeoverRequiresDeclaredUserReachableTrait() async throws {
    let project = try makeProject()
    defer { try? FileManager.default.removeItem(at: project) }
    let workflowId = "handover-presence-\(UUID().uuidString)"
    try writeHandoverWorkflow(project: project, workflowId: workflowId, reason: "userPresenceRequired")
    try saveTask(id: "task-presence", workflowId: workflowId)

    let runResult = await run(["task", "run", "task-presence", "--output", "json"], project: project)
    XCTAssertEqual(runResult.exitCode, .suspended, "stderr: \(runResult.stderr); stdout: \(runResult.stdout)")
    let unavailable = await run(["task", "takeover", "task-presence", "--output", "json"], project: project)
    XCTAssertEqual(unavailable.exitCode, .success, unavailable.stderr)
    let waiting = try decode(TaskRunCommandResult.self, from: unavailable.stdout)
    XCTAssertEqual(waiting.statusKind, .waiting)
    XCTAssertTrue(unavailable.stdout.contains("host-traits-unavailable"), unavailable.stdout)

    let available = await run([
      "task", "takeover", "task-presence", "--traits", "userReachable", "--output", "json"
    ], project: project)
    XCTAssertEqual(available.exitCode, .success, "stderr: \(available.stderr); stdout: \(available.stdout)")
    XCTAssertEqual(try store.loadTask(id: TaskID("task-presence"))?.state, .succeeded)
  }

  func testReconcileDryRunReturnsJSONWithoutWritingPackets() async throws {
    let beforeAttempts = try store.listAttempts(taskId: TaskID("task-cli"))
    let result = await run(["task", "reconcile", "--expired-leases", "--dry-run", "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let payload = try JSONDecoder().decode(TaskReconcileCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.entries, [])
    XCTAssertEqual(try store.listAttempts(taskId: TaskID("task-cli")), beforeAttempts)
    XCTAssertEqual(try store.listHandovers(taskId: TaskID("task-cli")), [])
  }

  func testSessionHandoverAdoptsSuspendedSessionInHermeticRepository() async throws {
    let project = try makeProject()
    defer { try? FileManager.default.removeItem(at: project) }
    let workflowId = "session-adoption-\(UUID().uuidString)"
    try writePlainWorkflow(project: project, workflowId: workflowId)
    let remote = try initializeFixtureRepository(at: project)
    defer { try? FileManager.default.removeItem(at: remote) }
    let sessionId = "session-adoption-\(UUID().uuidString)"
    try saveSuspendedSession(sessionId: sessionId, workflowId: workflowId)

    let result = await run(["session", "handover", sessionId, "--output", "json"], project: project)
    XCTAssertEqual(result.exitCode, .suspended, "stderr: \(result.stderr); stdout: \(result.stdout)")
    let payload = try JSONDecoder().decode(SessionHandoverCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.sessionId, sessionId)
    XCTAssertNotNil(try store.loadTask(id: TaskID(payload.taskId)))
    XCTAssertNotNil(try store.loadHandover(id: HandoverID(payload.handoverId)))
    try assertAdoptedIsolation(taskId: payload.taskId, project: project)
  }

  func testSessionHandoverCanAttachToExistingTask() async throws {
    let project = try makeProject()
    defer { try? FileManager.default.removeItem(at: project) }
    let workflowId = "session-attach-\(UUID().uuidString)"
    try writePlainWorkflow(project: project, workflowId: workflowId)
    let remote = try initializeFixtureRepository(at: project)
    defer { try? FileManager.default.removeItem(at: remote) }
    try saveTask(id: "task-existing", workflowId: workflowId)
    let sessionId = "session-attach-\(UUID().uuidString)"
    try saveSuspendedSession(sessionId: sessionId, workflowId: workflowId)

    let result = await run([
      "session", "handover", sessionId, "--task", "task-existing", "--output", "json"
    ], project: project)
    XCTAssertEqual(result.exitCode, .suspended, "stderr: \(result.stderr); stdout: \(result.stdout)")
    let payload = try JSONDecoder().decode(SessionHandoverCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(payload.taskId, "task-existing")
    XCTAssertEqual(try store.listHandovers(taskId: TaskID("task-existing")).count, 1)
    try assertAdoptedIsolation(taskId: payload.taskId, project: project)
  }

  private func run(_ arguments: [String], project: URL? = nil) async -> CLICommandResult {
    var command = arguments
    var environment = ["RIELA_SESSION_STORE": sessionStore.path]
    if let project {
      command += ["--scope", "project", "--working-dir", project.path]
      environment["GIT_CEILING_DIRECTORIES"] = project.deletingLastPathComponent().path
    }
    return await RielaCLIApplication().run(
      command + ["--session-store", sessionStore.path],
      environment: environment
    )
  }

  private func makeProject() throws -> URL {
    let project = testArtifactRoot.appendingPathComponent("project-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return project
  }

  /// Turns the fixture project into its own repository with a local bare remote so adoption never
  /// resolves the repository that contains this checkout. Returns the bare remote for cleanup.
  private func initializeFixtureRepository(at project: URL) throws -> URL {
    let remote = testArtifactRoot.appendingPathComponent("remote-\(UUID().uuidString).git", isDirectory: true)
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    let ceiling = project.deletingLastPathComponent().path
    try runFixtureGit(["-C", remote.path, "init", "--bare"], ceiling: ceiling)
    try runFixtureGit(["-C", project.path, "init"], ceiling: ceiling)
    try "fixture\n".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runFixtureGit(["-C", project.path, "add", "README.md"], ceiling: ceiling)
    try runFixtureGit([
      "-C", project.path, "-c", "user.name=riela-test", "-c", "user.email=riela-test@example.invalid",
      "-c", "commit.gpgsign=false", "commit", "-m", "fixture"
    ], ceiling: ceiling)
    try runFixtureGit(["-C", project.path, "remote", "add", "origin", remote.path], ceiling: ceiling)
    let toplevel = try runFixtureGit(["-C", project.path, "rev-parse", "--show-toplevel"], ceiling: ceiling)
    XCTAssertEqual(canonicalPath(URL(fileURLWithPath: toplevel)), canonicalPath(project))
    return remote
  }

  @discardableResult
  private func runFixtureGit(_ arguments: [String], ceiling: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CEILING_DIRECTORIES"] = ceiling
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      XCTFail("git \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(text)")
      throw CocoaError(.fileReadUnknown)
    }
    return text
  }

  private func canonicalPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  private func assertAdoptedIsolation(taskId: String, project: URL) throws {
    let attempts = try store.listAttempts(taskId: TaskID(taskId))
    let isolation = try XCTUnwrap(attempts.compactMap(\.isolation).first, "adopted attempt has no isolation")
    XCTAssertEqual(canonicalPath(URL(fileURLWithPath: isolation.path)), canonicalPath(project))
    XCTAssertTrue(isolation.branch?.hasPrefix("riela/task/") == true, isolation.branch ?? "nil branch")
  }

  private var testArtifactRoot: URL {
    var root = URL(fileURLWithPath: #filePath)
    while root.pathComponents.count > 1,
          !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
      root.deleteLastPathComponent()
    }
    let directory = root.appendingPathComponent("tmp/work-handover/wh-15-task-commands/tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func saveTask(id: String, workflowId: String) throws {
    try store.saveTask(WorkTask(
      id: TaskID(id), intentId: IntentID("intent-\(id)"), title: "CLI \(id)",
      instruction: "Exercise CLI handover.", plan: .workflow(WorkflowReference(
        name: workflowId, scope: WorkflowScope.project.rawValue
      )), state: .ready
    ))
  }

  private func writeHandoverWorkflow(
    project: URL, workflowId: String, reason: String, withOption: Bool = false
  ) throws {
    let question: JSONObject = [
      "id": .string("q1"), "text": .string("Choose"),
      "options": .array(withOption ? [.object(["id": .string("staging"), "label": .string("Staging")])] : [])
    ]
    var config: JSONObject = [
      "reason": .string(reason), "progressNote": .string("Waiting for CLI handover"),
      "resumeStepId": .string("resume")
    ]
    if reason == "userInputRequired" { config["question"] = .object(question) }
    if reason == "userPresenceRequired" {
      config["presence"] = .object([
        "traits": .array([.string("userReachable")]), "instructions": .string("Use a reachable host")
      ])
    }
    let addon = WorkflowNodeAddonRef(name: "riela/handover-request", version: "1", config: config)
    let workflow = WorkflowDefinition(
      workflowId: workflowId, defaults: .init(nodeTimeoutMs: 2_000, maxLoopIterations: 1),
      entryStepId: "prelude",
      nodeRegistry: [
        .init(id: "prelude", nodeFile: "prelude.json"), .init(id: "request", addon: addon),
        .init(id: "resume", nodeFile: "resume.json")
      ],
      steps: [
        .init(id: "prelude", nodeId: "prelude", transitions: [.init(toStepId: "request")]),
        .init(id: "request", nodeId: "request", transitions: [.init(toStepId: "resume")]),
        .init(id: "resume", nodeId: "resume")
      ],
      nodes: [
        .init(id: "prelude", nodeFile: "prelude.json"), .init(id: "request", addon: addon),
        .init(id: "resume", nodeFile: "resume.json")
      ]
    )
    try write(workflow, workflowId: workflowId, project: project)
  }

  private func writePlainWorkflow(project: URL, workflowId: String) throws {
    let workflow: [String: Any] = [
      "workflowId": workflowId,
      "defaults": ["nodeTimeoutMs": 2_000, "maxLoopIterations": 1],
      "entryStepId": "start",
      "nodes": [["id": "node", "nodeFile": "node.json"]],
      "steps": [
        ["id": "start", "nodeId": "node", "transitions": [["toStepId": "resume"]]],
        ["id": "resume", "nodeId": "node"]
      ]
    ]
    let node: [String: Any] = [
      "id": "node", "nodeType": "command", "model": "", "modelFreeze": false,
      "command": ["executable": "/usr/bin/true", "arguments": []]
    ]
    try writeJSON(workflow, project: project, workflowId: workflowId, filename: "workflow.json")
    try writeJSON(node, project: project, workflowId: workflowId, filename: "node.json")
  }

  private func write(_ workflow: WorkflowDefinition, workflowId: String, project: URL) throws {
    let folder = project.appendingPathComponent(".riela/workflows/\(workflowId)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONEncoder().encode(workflow).write(to: folder.appendingPathComponent("workflow.json"))
    let prelude: [String: Any] = [
      "id": "prelude", "nodeType": "command", "model": "", "modelFreeze": false,
      "command": ["executable": "/bin/echo", "arguments": ["{\"ready\":true}"]]
    ]
    let resume: [String: Any] = [
      "id": "resume", "nodeType": "command", "model": "", "modelFreeze": false,
      "command": ["executable": "/usr/bin/true", "arguments": []]
    ]
    try JSONSerialization.data(withJSONObject: prelude, options: [.sortedKeys])
      .write(to: folder.appendingPathComponent("prelude.json"))
    try JSONSerialization.data(withJSONObject: resume, options: [.sortedKeys])
      .write(to: folder.appendingPathComponent("resume.json"))
  }

  private func writeJSON(_ value: [String: Any], project: URL, workflowId: String, filename: String) throws {
    let folder = project.appendingPathComponent(".riela/workflows/\(workflowId)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
      .write(to: folder.appendingPathComponent(filename))
  }

  private func saveSuspendedSession(sessionId: String, workflowId: String) throws {
    let now = Date()
    let session = WorkflowSession(
      workflowId: workflowId, sessionId: sessionId, status: .suspended,
      entryStepId: "start", currentStepId: "resume", createdAt: now, updatedAt: now,
      suspend: SuspendRecord(
        reasonKind: .operatorMove, stepId: "resume", progressNote: "Resume adopted work",
        suspendedAt: now, producer: .runtime
      )
    )
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).save(WorkflowRuntimePersistenceSnapshot(session: session))
  }

  private func commandError(_ result: CLICommandResult) -> String {
    if let failure = try? decode(TaskCommandFailureResult.self, from: result.stdout) { return failure.error }
    return result.stderr + result.stdout
  }

  private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(json.utf8))
  }
}
