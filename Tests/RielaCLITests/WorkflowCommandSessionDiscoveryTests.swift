import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowCommandSessionDiscoveryTests: XCTestCase {
  func testSessionListTextAppendsProvenanceAfterLegacyColumns() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-list-columns-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try CLIWorkflowSessionStore(rootDirectory: tempDir.path).save(persistedSession(
      sessionId: "child-session",
      workflowName: "child-workflow",
      status: .running,
      updatedAt: Date(timeIntervalSince1970: 40),
      parentSessionId: "parent-session",
      rootSessionId: "root-session"
    ))

    let result = await RielaCLIApplication().run([
      "session", "list",
      "--session-store", tempDir.path,
      "--output", "text"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let columns = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: "\t")
    XCTAssertEqual(Array(columns.prefix(6)), [
      "child-session", "child-workflow", "running", "-", "step-a", "0"
    ])
    XCTAssertEqual(columns[7], tempDir.path)
    XCTAssertEqual(Array(columns.suffix(2)), ["parent-session", "root-session"])
  }

  func testSessionListFiltersOrdersAndLimitsPersistedRows() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-list-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = CLIWorkflowSessionStore(rootDirectory: tempDir.path)
    try store.save(persistedSession(
      sessionId: "session-old",
      workflowName: "workflow-a",
      status: .failed,
      updatedAt: Date(timeIntervalSince1970: 10),
      failureKind: .adapterFailure
    ))
    try store.save(persistedSession(
      sessionId: "session-other",
      workflowName: "workflow-b",
      status: .failed,
      updatedAt: Date(timeIntervalSince1970: 30),
      failureKind: .maxStepsExceeded
    ))
    try store.save(persistedSession(
      sessionId: "session-running",
      workflowName: "workflow-a",
      status: .running,
      updatedAt: Date(timeIntervalSince1970: 40)
    ))
    try store.save(persistedSession(
      sessionId: "session-new",
      workflowName: "workflow-a",
      status: .failed,
      updatedAt: Date(timeIntervalSince1970: 50),
      failureKind: .maxStepsExceeded
    ))

    let result = await RielaCLIApplication().run([
      "session", "list",
      "--workflow", "workflow-a",
      "--status", "failed",
      "--limit", "1",
      "--session-store", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let rows = try decodeJSON([SessionDiscoveryRow].self, from: result.stdout)
    XCTAssertEqual(rows.map(\.sessionId), ["session-new"])
    XCTAssertEqual(rows.first?.workflowName, "workflow-a")
    XCTAssertEqual(rows.first?.status, .failed)
    XCTAssertEqual(rows.first?.failureKind, .maxStepsExceeded)
  }

  func testMaxStepsFailurePersistsTerminalMetadataAndIsDiscoverable() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-max-steps-discovery-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("self-loop-command", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    let script = try createExecutable(
      directory: tempDir,
      name: "self-loop-command.sh",
      body: #"printf '%s\n' '{"status":"again"}'"#
    )
    try writeSelfLoopWorkflow(workflowDirectory: workflowDirectory, nodesDirectory: nodesDirectory, script: script)

    let run = await RielaCLIApplication().run([
      "workflow", "run", "self-loop-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--max-steps", "1",
      "--output", "json"
    ])

    XCTAssertEqual(run.exitCode, .failure)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(failure.failureKind, .maxStepsExceeded)
    XCTAssertEqual(failure.stepBudgetDiagnostic?.stepBudget, 1)
    let sessionId = try XCTUnwrap(failure.sessionId)

    let progress = await RielaCLIApplication().run([
      "session", "progress", sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(progress.exitCode, .success, progress.stderr)
    let progressPayload = try decodeJSON(SessionInspectionCommandResult.self, from: progress.stdout)
    XCTAssertEqual(progressPayload.status, .failed)
    XCTAssertEqual(progressPayload.failureKind, .maxStepsExceeded)
    XCTAssertEqual(progressPayload.stepBudgetDiagnostic?.unscheduledStepId, "run-command")

    let latest = await RielaCLIApplication().run([
      "session", "latest",
      "--workflow", "self-loop-command",
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(latest.exitCode, .success, latest.stderr)
    let latestRow = try decodeJSON(SessionDiscoveryRow.self, from: latest.stdout)
    XCTAssertEqual(latestRow.sessionId, sessionId)
    XCTAssertEqual(latestRow.status, .failed)
    XCTAssertEqual(latestRow.failureKind, .maxStepsExceeded)

    let resume = await RielaCLIApplication().run([
      "session", "resume", sessionId,
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--max-steps", "2",
      "--output", "json"
    ])
    XCTAssertEqual(resume.exitCode, .failure)
    let resumeFailure = try decodeJSON(SessionCommandFailureResult.self, from: resume.stdout)
    XCTAssertEqual(resumeFailure.sessionId, sessionId)
    XCTAssertTrue(resumeFailure.error.contains("maxStepsExceeded"), resumeFailure.error)

    let progressAfterFailedResume = await RielaCLIApplication().run([
      "session", "progress", sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(progressAfterFailedResume.exitCode, .success, progressAfterFailedResume.stderr)
    let failedResumeProgress = try decodeJSON(SessionInspectionCommandResult.self, from: progressAfterFailedResume.stdout)
    XCTAssertEqual(failedResumeProgress.status, .failed)
    XCTAssertEqual(failedResumeProgress.failureKind, .maxStepsExceeded)
    XCTAssertEqual(failedResumeProgress.stepBudgetDiagnostic?.stepBudget, 2)
    XCTAssertEqual(failedResumeProgress.executionCount, 3)

    let latestAfterFailedResume = await RielaCLIApplication().run([
      "session", "latest",
      "--workflow", "self-loop-command",
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(latestAfterFailedResume.exitCode, .success, latestAfterFailedResume.stderr)
    let latestAfterFailedResumeRow = try decodeJSON(SessionDiscoveryRow.self, from: latestAfterFailedResume.stdout)
    XCTAssertEqual(latestAfterFailedResumeRow.sessionId, sessionId)
    XCTAssertEqual(latestAfterFailedResumeRow.status, .failed)
    XCTAssertEqual(latestAfterFailedResumeRow.failureKind, .maxStepsExceeded)
    XCTAssertEqual(latestAfterFailedResumeRow.executionCount, failedResumeProgress.executionCount)
  }

  func testSessionResumeCompletesBudgetFailedSessionWithRaisedMaxSteps() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-resume-raised-max-steps-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("two-step-command", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    let script = try createExecutable(
      directory: tempDir,
      name: "two-step-command.sh",
      body: """
      if grep -q '"request":"preserve me"'; then
        printf '%s\\n' '{"status":"ok"}'
      else
        printf '%s\\n' 'missing workflowInput.request' >&2
        exit 7
      fi
      """
    )
    try writeTwoStepWorkflow(workflowDirectory: workflowDirectory, nodesDirectory: nodesDirectory, script: script)

    let run = await RielaCLIApplication().run([
      "workflow", "run", "two-step-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--variables", #"{"workflowInput":{"request":"preserve me"}}"#,
      "--max-steps", "1",
      "--output", "json"
    ])

    XCTAssertEqual(run.exitCode, .failure)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: run.stdout)
    XCTAssertEqual(failure.failureKind, .maxStepsExceeded)
    XCTAssertEqual(failure.stepBudgetDiagnostic?.stepBudget, 1)
    let sessionId = try XCTUnwrap(failure.sessionId)
    let persisted = try CLIWorkflowSessionStore(rootDirectory: sessionStore.path).load(sessionId: sessionId)
    XCTAssertEqual(persisted.runtimeVariables?["workflowInput"], .object(["request": .string("preserve me")]))

    let releaseFile = tempDir.appendingPathComponent("release-resume")
    _ = try createExecutable(
      directory: tempDir,
      name: "two-step-command.sh",
      body: """
      while [ ! -f '\(releaseFile.path)' ]; do
        sleep 0.05
      done
      if grep -q '"request":"preserve me"'; then
        printf '%s\\n' '{"status":"ok"}'
      else
        printf '%s\\n' 'missing workflowInput.request' >&2
        exit 7
      fi
      """
    )
    let resumeTask = Task {
      await RielaCLIApplication().run([
        "session", "resume", sessionId,
        "--workflow-definition-dir", workflowRoot.path,
        "--session-store", sessionStore.path,
        "--max-steps", "2",
        "--output", "json"
      ])
    }
    var runningProgress: SessionInspectionCommandResult?
    let runningDeadline = Date().addingTimeInterval(3)
    while Date() < runningDeadline {
      let progress = await RielaCLIApplication().run([
        "session", "progress", sessionId,
        "--session-store", sessionStore.path,
        "--output", "json"
      ])
      if progress.exitCode == .success,
         let decoded = try? decodeJSON(SessionInspectionCommandResult.self, from: progress.stdout),
         decoded.status == .running {
        runningProgress = decoded
        break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(runningProgress?.status, .running)
    XCTAssertEqual(runningProgress?.progress?.status, .running)
    let followTask = Task {
      await RielaCLIApplication().run([
        "session", "progress", sessionId,
        "--session-store", sessionStore.path,
        "--follow", "--poll-interval", "0.1",
        "--output", "jsonl"
      ])
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    try Data().write(to: releaseFile)

    let resume = await resumeTask.value
    let follow = await followTask.value

    XCTAssertEqual(resume.exitCode, .success, resume.stderr)
    let resumePayload = try decodeJSON(SessionResumeCommandResult.self, from: resume.stdout)
    XCTAssertEqual(resumePayload.sourceSessionId, sessionId)
    XCTAssertEqual(resumePayload.sessionId, sessionId)
    XCTAssertEqual(resumePayload.status, .completed)
    XCTAssertEqual(resumePayload.exitCode, CLIExitCode.success.rawValue)
    XCTAssertEqual(resumePayload.recovery?.entryMode, .resume)
    XCTAssertEqual(follow.exitCode, .success, follow.stderr + follow.stdout)
    let followViews = try follow.stdout.split(whereSeparator: \.isNewline).map {
      try decodeJSON(SessionObservabilityView.self, from: String($0))
    }
    XCTAssertEqual(followViews.first?.root.digest.status, .running)
    XCTAssertEqual(followViews.last?.root.digest.status, .completed)

    let progress = await RielaCLIApplication().run([
      "session", "progress", sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(progress.exitCode, .success, progress.stderr)
    let progressPayload = try decodeJSON(SessionInspectionCommandResult.self, from: progress.stdout)
    XCTAssertEqual(progressPayload.status, .completed)
    XCTAssertNil(progressPayload.failureKind)
    XCTAssertNil(progressPayload.stepBudgetDiagnostic)
  }

  func testSessionResumeRejectsNonBudgetFailedSessionWithRerunGuidance() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-resume-non-budget-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    try CLIWorkflowSessionStore(rootDirectory: sessionStore.path).save(persistedSession(
      sessionId: "adapter-failed-session",
      workflowName: "worker-only-single-step",
      status: .failed,
      updatedAt: Date(timeIntervalSince1970: 20),
      failureKind: .adapterFailure
    ))

    let result = await RielaCLIApplication().run([
      "session", "resume", "adapter-failed-session",
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, CLIExitCode.failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(SessionCommandFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.sessionId, "adapter-failed-session")
    XCTAssertEqual(failure.exitCode, CLIExitCode.failure.rawValue)
    XCTAssertTrue(failure.error.contains("failureKind adapterFailure"), failure.error)
    XCTAssertTrue(failure.error.contains("cannot be resumed"), failure.error)
    XCTAssertTrue(failure.error.contains("riela session rerun adapter-failed-session step-a"), failure.error)
  }

  private func writeSelfLoopWorkflow(workflowDirectory: URL, nodesDirectory: URL, script: URL) throws {
    try """
    {
      "workflowId": "self-loop-command",
      "defaults": { "maxLoopIterations": 1, "nodeTimeoutMs": 10000 },
      "entryStepId": "run-command",
      "nodes": [{ "id": "run-command", "nodeFile": "nodes/node-run-command.json" }],
      "steps": [
        {
          "id": "run-command",
          "nodeId": "run-command",
          "role": "worker",
          "transitions": [{ "toStepId": "run-command" }]
        }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "run-command",
      "nodeType": "command",
      "modelFreeze": false,
      "command": { "executable": "\(script.path)" }
    }
    """.write(to: nodesDirectory.appendingPathComponent("node-run-command.json"), atomically: true, encoding: .utf8)
  }

  private func writeTwoStepWorkflow(workflowDirectory: URL, nodesDirectory: URL, script: URL) throws {
    try """
    {
      "workflowId": "two-step-command",
      "defaults": { "maxLoopIterations": 1, "nodeTimeoutMs": 10000 },
      "entryStepId": "step-a",
      "nodes": [
        { "id": "node-a", "nodeFile": "nodes/node-a.json" },
        { "id": "node-b", "nodeFile": "nodes/node-b.json" }
      ],
      "steps": [
        {
          "id": "step-a",
          "nodeId": "node-a",
          "role": "worker",
          "transitions": [{ "toStepId": "step-b" }]
        },
        {
          "id": "step-b",
          "nodeId": "node-b",
          "role": "worker"
        }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "node-a",
      "nodeType": "command",
      "modelFreeze": false,
      "command": { "executable": "\(script.path)" }
    }
    """.write(to: nodesDirectory.appendingPathComponent("node-a.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "node-b",
      "nodeType": "command",
      "modelFreeze": false,
      "command": { "executable": "\(script.path)" }
    }
    """.write(to: nodesDirectory.appendingPathComponent("node-b.json"), atomically: true, encoding: .utf8)
  }

  private func createExecutable(directory: URL, name: String, body: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try """
    #!/bin/sh
    \(body)
    """.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func persistedSession(
    sessionId: String,
    workflowName: String,
    status: WorkflowSessionStatus,
    updatedAt: Date,
    failureKind: WorkflowSessionFailureKind? = nil,
    parentSessionId: String? = nil,
    rootSessionId: String? = nil
  ) -> PersistedCLIWorkflowSession {
    PersistedCLIWorkflowSession(
      workflowName: workflowName,
      session: WorkflowSession(
        workflowId: workflowName,
        sessionId: sessionId,
        status: status,
        entryStepId: "step-a",
        currentStepId: "step-a",
        createdAt: updatedAt,
        updatedAt: updatedAt,
        failureKind: failureKind,
        parentSessionId: parentSessionId,
        rootSessionId: rootSessionId
      ),
      resolution: WorkflowResolutionOptions(workflowName: workflowName)
    )
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(stdout.utf8))
  }
}
