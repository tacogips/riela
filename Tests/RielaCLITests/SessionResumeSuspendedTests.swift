import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

final class SessionResumeSuspendedTests: XCTestCase {
  func testWorkflowRunSuspendQuestionGateAndAnswerResume() async throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/session-suspend-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("suspend-cli", isDirectory: true)
    let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    {"workflowId":"suspend-cli","defaults":{"nodeTimeoutMs":30000,"maxLoopIterations":2},"entryStepId":"start",
     "nodes":[{"id":"start","nodeFile":"start.json"}],"steps":[{"id":"start","nodeId":"start"}]}
    """.write(to: bundle.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"start","executionBackend":"codex-agent","agentSandbox":"read-only","model":"fixture","variables":{},
     "output":{"jsonSchema":{"type":"object","required":["answer"]}}}
    """.write(to: bundle.appendingPathComponent("start.json"), atomically: true, encoding: .utf8)
    let scenario = bundle.appendingPathComponent("scenario.json")
    try """
    {"start":[
      {"payload":{"answer":"before","handover":{"reason":"userInputRequired","question":{"id":"q1","text":"Choose an option","options":[{"id":"a","label":"Option A"}]}}}},
      {"payload":{"answer":"after"}}
    ]}
    """.write(to: scenario, atomically: true, encoding: .utf8)

    let common = ["--workflow-definition-dir", root.path, "--working-directory", root.path,
                  "--session-store", sessionRoot.path, "--mock-scenario", scenario.path,
                  "--output", "text"]
    let run = await RielaCLIApplication().run(["workflow", "run", "suspend-cli"] + common)
    XCTAssertEqual(run.exitCode, .suspended, run.stderr + run.stdout)
    XCTAssertTrue(run.stderr.contains("Choose an option"), run.stderr + run.stdout)
    let store = CLIWorkflowSessionStore(rootDirectory: sessionRoot.path)
    let suspended = try store.load(sessionId: "suspend-cli-session-1")
    XCTAssertEqual(suspended.session.status, .suspended)
    XCTAssertEqual(suspended.session.executions.count, 1)

    let status = await RielaCLIApplication().run([
      "session", "status", suspended.session.sessionId,
      "--working-directory", root.path,
      "--session-store", sessionRoot.path,
      "--output", "text"
    ])
    XCTAssertEqual(status.exitCode, .success, status.stderr + status.stdout)
    XCTAssertTrue(status.stdout.contains("resumeStep: start"), status.stdout)
    XCTAssertTrue(status.stdout.contains("reason: userInputRequired"), status.stdout)

    let noAnswer = await RielaCLIApplication().run(["session", "resume", suspended.session.sessionId] + common)
    XCTAssertEqual(noAnswer.exitCode, .suspended)
    XCTAssertTrue(noAnswer.stderr.contains("Choose an option"), noAnswer.stderr)
    XCTAssertEqual(try store.load(sessionId: suspended.session.sessionId).session.executions.count, 1)
    let persistence = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot.path)
    )
    let unansweredSnapshot = try persistence.load(sessionId: suspended.session.sessionId)
    XCTAssertFalse(unansweredSnapshot.workflowMessages.contains { $0.payload["handover"] != nil })

    let answer = await RielaCLIApplication().run([
      "session", "resume", suspended.session.sessionId,
      "--variables", "{\"handover\":{\"answer\":{\"option\":\"a\"}}}"
    ] + common)
    XCTAssertEqual(answer.exitCode, .success, answer.stderr + answer.stdout)
    let completed = try store.load(sessionId: suspended.session.sessionId)
    XCTAssertEqual(completed.session.status, .completed)
    XCTAssertNil(completed.session.suspend)
    let inputSnapshot = try XCTUnwrap(completed.session.executions.last?.inputSnapshot)
    guard case let .object(mergedVariables)? = inputSnapshot["mergedVariables"] else {
      return XCTFail("expected merged adapter variables in execution snapshot")
    }
    XCTAssertEqual(
      mergedVariables["handover"],
      .object(["answer": .object(["option": .string("a")])])
    )
    let suspendedExecutionId = try XCTUnwrap(suspended.session.executions.first?.executionId)
    let answerMessages = try persistence.load(sessionId: suspended.session.sessionId).workflowMessages
      .filter { $0.payload["handover"] != nil }
    XCTAssertEqual(answerMessages.count, 1)
    let answerMessage = try XCTUnwrap(answerMessages.first)
    XCTAssertEqual(answerMessage.toStepId, "start")
    XCTAssertNil(answerMessage.fromStepId)
    XCTAssertEqual(
      answerMessage.payload,
      ["handover": .object(["answer": .object(["option": .string("a")])])]
    )
    XCTAssertEqual(answerMessage.sourceStepExecutionId, suspendedExecutionId)
  }
}
