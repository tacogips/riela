import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class SessionAddonRecoveryTests: XCTestCase {
  func testSessionResumeAndRerunProvideBuiltinAddonResolver() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-addon-recovery")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflowRoot = root.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("two-time-signals", isDirectory: true)
    let sessionStore = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try writeWorkflow(to: workflowDirectory.appendingPathComponent("workflow.json"))

    let app = RielaCLIApplication()
    let initialRun = await app.run([
      "workflow", "run", "two-time-signals",
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--max-steps", "1",
      "--output", "json"
    ])
    XCTAssertEqual(initialRun.exitCode, .failure, initialRun.stderr + initialRun.stdout)
    let initialFailure = try decode(WorkflowRunFailureResult.self, from: initialRun.stdout)
    XCTAssertEqual(initialFailure.failureKind, .maxStepsExceeded)
    let sessionId = try XCTUnwrap(initialFailure.sessionId)

    let resume = await app.run([
      "session", "resume", sessionId,
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(resume.exitCode, .success, resume.stderr + resume.stdout)
    let resumed = try decode(SessionResumeCommandResult.self, from: resume.stdout)
    XCTAssertEqual(resumed.status, .completed)

    let rerun = await app.run([
      "session", "rerun", sessionId, "first-signal",
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr + rerun.stdout)
    let rerunResult = try decode(SessionRerunCommandResult.self, from: rerun.stdout)
    XCTAssertEqual(rerunResult.status, .completed)
    XCTAssertEqual(rerunResult.rerunFromStepId, "first-signal")
  }

  func testPlainRerunCarriesAcceptedInboxForMockScenarioConsumer() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-rerun-inbox-carryover")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflowRoot = root.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("inbox-carryover", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try writeInboxCarryoverWorkflow(workflowDirectory: workflowDirectory, nodesDirectory: nodesDirectory)
    let scenario = root.appendingPathComponent("mock-scenario.json")
    try """
    {
      "checkpoint": { "provider": "scenario-mock", "model": "gpt-5.5", "payload": { "status": "ready" } },
      "consumer": { "provider": "scenario-mock", "model": "gpt-5.5", "payload": { "status": "consumed" } }
    }
    """.write(to: scenario, atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let initialRun = await app.run([
      "workflow", "run", "inbox-carryover",
      "--workflow-definition-dir", workflowRoot.path,
      "--mock-scenario", scenario.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(initialRun.exitCode, .success, initialRun.stderr + initialRun.stdout)
    let source = try decode(WorkflowSessionIDEnvelope.self, from: initialRun.stdout)
    let store = CLIWorkflowSessionStore(rootDirectory: sessionStore.path)
    let persistedSource = try store.load(sessionId: source.session.sessionId)
    let sourceCheckpoint = try XCTUnwrap(persistedSource.session.executions.first { $0.stepId == "checkpoint" })
    let sourceConsumer = try XCTUnwrap(persistedSource.session.executions.first { $0.stepId == "consumer" })
    let sourceCommunicationIds = try XCTUnwrap(communicationIds(in: sourceConsumer))
    XCTAssertEqual(sourceCommunicationIds.count, 1)

    let rerun = await app.run([
      "session", "rerun", source.session.sessionId, "consumer",
      "--workflow-definition-dir", workflowRoot.path,
      "--mock-scenario", scenario.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr + rerun.stdout)
    let result = try decode(SessionRerunCommandResult.self, from: rerun.stdout)
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.rerunFromStepId, "consumer")

    let persistedRerun = try store.load(sessionId: result.sessionId)
    let executions = persistedRerun.session.executions
    XCTAssertEqual(executions.map(\.stepId), ["checkpoint", "consumer"])
    XCTAssertEqual(executions[0].importedFrom?.sessionId, persistedSource.session.sessionId)
    XCTAssertEqual(executions[0].importedFrom?.executionId, sourceCheckpoint.executionId)
    XCTAssertNil(executions[1].importedFrom)
    XCTAssertEqual(persistedRerun.session.newExecutionCount, 1)
    let rerunCommunicationIds = try XCTUnwrap(communicationIds(in: executions[1]))
    XCTAssertEqual(rerunCommunicationIds.count, 1)
    let rerunCommunicationId = try XCTUnwrap(rerunCommunicationIds.first)
    let sourceCommunicationId = try XCTUnwrap(sourceCommunicationIds.first)
    XCTAssertNotEqual(rerunCommunicationId, sourceCommunicationId)
    XCTAssertEqual(executions[0].importedFrom?.communicationIds[rerunCommunicationId], sourceCommunicationId)
  }

  func testSessionResumeRetriesPolicyBlockedAddonAfterRepair() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-policy-retry")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflowRoot = root.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("two-time-signals", isDirectory: true)
    let sessionStore = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    let workflowFile = workflowDirectory.appendingPathComponent("workflow.json")
    try writeWorkflow(to: workflowFile, intervalMinutes: 0)

    let app = RielaCLIApplication()
    let initialRun = await app.run([
      "workflow", "run", "two-time-signals",
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(initialRun.exitCode, .failure, initialRun.stderr + initialRun.stdout)
    let failure = try decode(WorkflowRunFailureResult.self, from: initialRun.stdout)
    XCTAssertEqual(failure.failureKind, .policyBlocked)
    let sessionId = try XCTUnwrap(failure.sessionId)

    try writeWorkflow(to: workflowFile, intervalMinutes: 5)
    let resume = await app.run([
      "session", "resume", sessionId, "--retry-failed-step",
      "--workflow-definition-dir", workflowRoot.path,
      "--working-dir", root.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(resume.exitCode, .success, resume.stderr + resume.stdout)
    XCTAssertEqual(try decode(SessionResumeCommandResult.self, from: resume.stdout).status, .completed)
  }

  private func writeWorkflow(to url: URL, intervalMinutes: Int = 5) throws {
    try """
    {
      "workflowId": "two-time-signals",
      "defaults": { "maxLoopIterations": 3, "nodeTimeoutMs": 30000 },
      "entryStepId": "first-signal",
      "nodes": [
        {
          "id": "first-signal",
          "addon": {
            "name": "riela/time-signal",
            "version": "1",
            "config": { "intervalMinutes": \(intervalMinutes) },
            "inputs": {
              "scheduledAt": "2026-08-06T01:00:00.000Z",
              "timezone": "Asia/Tokyo"
            }
          }
        },
        {
          "id": "second-signal",
          "addon": {
            "name": "riela/time-signal",
            "version": "1",
            "config": { "intervalMinutes": 5 },
            "inputs": {
              "scheduledAt": "{{inbox.latest.output.payload.scheduledAt}}",
              "timezone": "{{inbox.latest.output.payload.timezone}}"
            }
          }
        }
      ],
      "steps": [
        {
          "id": "first-signal",
          "nodeId": "first-signal",
          "role": "worker",
          "transitions": [
            { "toStepId": "second-signal", "label": "should_announce" }
          ]
        },
        { "id": "second-signal", "nodeId": "second-signal", "role": "worker" }
      ]
    }
    """.write(to: url, atomically: true, encoding: .utf8)
  }

  private func writeInboxCarryoverWorkflow(workflowDirectory: URL, nodesDirectory: URL) throws {
    try """
    {
      "workflowId": "inbox-carryover",
      "defaults": { "maxLoopIterations": 2, "nodeTimeoutMs": 30000 },
      "entryStepId": "checkpoint",
      "nodes": [
        { "id": "checkpoint", "nodeFile": "nodes/checkpoint.json" },
        { "id": "consumer", "nodeFile": "nodes/consumer.json" }
      ],
      "steps": [
        { "id": "checkpoint", "nodeId": "checkpoint", "transitions": [{ "toStepId": "consumer" }] },
        { "id": "consumer", "nodeId": "consumer" }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    { "id": "checkpoint", "executionBackend": "codex-agent", "agentSandbox": "read-only", "model": "gpt-5.5", "variables": {} }
    """.write(to: nodesDirectory.appendingPathComponent("checkpoint.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "consumer", "executionBackend": "codex-agent", "agentSandbox": "read-only", "model": "gpt-5.5",
      "promptTemplate": "Consume the upstream status {{_rielaInput.latest.payload.status}}.", "variables": {}
    }
    """.write(to: nodesDirectory.appendingPathComponent("consumer.json"), atomically: true, encoding: .utf8)
  }

  private func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(value.utf8))
  }

  private func communicationIds(in execution: WorkflowStepExecution) -> [String]? {
    guard case let .object(mergedVariables)? = execution.inputSnapshot?["mergedVariables"],
          case let .object(rielaInput)? = mergedVariables["_rielaInput"],
          case let .array(rawIds)? = rielaInput["communicationIds"] else {
      return nil
    }
    let ids = rawIds.compactMap { value -> String? in
      guard case let .string(id) = value else { return nil }
      return id
    }
    return ids.count == rawIds.count ? ids : nil
  }
}

private struct WorkflowSessionIDEnvelope: Decodable {
  struct Session: Decodable {
    var sessionId: String
  }

  var session: Session
}
