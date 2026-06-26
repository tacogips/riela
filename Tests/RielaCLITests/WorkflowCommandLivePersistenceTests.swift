import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WorkflowCommandLivePersistenceTests: XCTestCase {
  func testWorkflowRunJSONPersistsLiveSessionBeforeCommandNodeCompletes() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-json-live-session-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("slow-command", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    let script = try createExecutable(
      directory: tempDir,
      name: "slow-command.sh",
      body: """
      sleep 1
      printf '%s\\n' '{"status":"done"}'
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "command": { "executable": "\(script.path)" }
      }
      """
    )

    let app = RielaCLIApplication()
    let task = Task {
      await app.run([
        "workflow", "run", "slow-command",
        "--workflow-definition-dir", workflowRoot.path,
        "--session-store", sessionStore.path,
        "--output", "json"
      ])
    }

    var liveRecord: PersistedCLIWorkflowSession?
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      liveRecord = try? CLIWorkflowSessionStore(rootDirectory: sessionStore.path).loadAll().first
      if liveRecord != nil {
        break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTAssertEqual(liveRecord?.workflowName, "slow-command")
    let snapshot = try liveRecord.map {
      try SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
      ).load(sessionId: $0.session.sessionId)
    }
    XCTAssertNotNil(snapshot)

    let result = await task.value
    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    let legacyLoopStatus = await RielaCLIApplication().run([
      "loop", "status", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(legacyLoopStatus.exitCode, .success)
    let legacyLoop = try decodeJSON(LoopStatusCommandResult.self, from: legacyLoopStatus.stdout)
    XCTAssertFalse(legacyLoop.loopEvidenceRecorded)
    XCTAssertNil(legacyLoop.loopEvidence)
    let legacySessionStatus = await RielaCLIApplication().run([
      "session", "status", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(legacySessionStatus.exitCode, .success, legacySessionStatus.stderr + legacySessionStatus.stdout)
    let legacySession = try decodeJSON(SessionInspectionCommandResult.self, from: legacySessionStatus.stdout)
    XCTAssertFalse(legacySession.loopEvidenceRecorded)
    XCTAssertNil(legacySession.loopEvidence)
    let explicitLoopEvidence = await RielaCLIApplication().run([
      "loop", "evidence", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(explicitLoopEvidence.exitCode, .success, explicitLoopEvidence.stderr + explicitLoopEvidence.stdout)
    let explicitEvidence = try decodeJSON(LoopEvidenceCommandResult.self, from: explicitLoopEvidence.stdout)
    XCTAssertFalse(explicitEvidence.loopEvidenceRecorded)
    XCTAssertEqual(explicitEvidence.loopEvidence?.workflowId, "slow-command")
    XCTAssertEqual(explicitEvidence.loopEvidence?.sessionId, runResult.session.sessionId)
    XCTAssertEqual(explicitEvidence.loopEvidence?.steps.count, 1)
    XCTAssertEqual(explicitEvidence.loopEvidence?.gates, [])
    XCTAssertTrue(explicitEvidence.loopEvidence?.redaction.warnings.contains(
      "workflow.loop metadata is absent; explicit projection includes runtime step evidence only"
    ) ?? false)
    let explicitLoopGates = await RielaCLIApplication().run([
      "loop", "gates", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(explicitLoopGates.exitCode, .success, explicitLoopGates.stderr + explicitLoopGates.stdout)
    let explicitGates = try decodeJSON(LoopGatesCommandResult.self, from: explicitLoopGates.stdout)
    XCTAssertFalse(explicitGates.loopEvidenceRecorded)
    XCTAssertEqual(explicitGates.gates, [])
    let snapshotAfterExplicitEvidence = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).load(sessionId: runResult.session.sessionId)
    XCTAssertNil(snapshotAfterExplicitEvidence.loopEvidence)
    XCTAssertEqual(runResult.status, .completed)
    XCTAssertEqual(runResult.rootOutput?["status"], .string("done"))
  }

  func testSessionProgressReportsActiveStepDuringLiveSecondStep() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-live-active-step-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("two-step-command", isDirectory: true)
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    let firstScript = try createExecutable(
      directory: tempDir,
      name: "first-step.sh",
      body: #"printf '%s\n' '{"status":"first"}'"#
    )
    let secondScript = try createExecutable(
      directory: tempDir,
      name: "second-step.sh",
      body: """
      sleep 1
      printf '%s\\n' '{"status":"second"}'
      """
    )
    try writeTwoCommandWorkflow(
      workflowDirectory: workflowDirectory,
      firstNodeJSON: """
      {
        "id": "first-command",
        "nodeType": "command",
        "command": { "executable": "\(firstScript.path)" }
      }
      """,
      secondNodeJSON: """
      {
        "id": "second-command",
        "nodeType": "command",
        "command": { "executable": "\(secondScript.path)" }
      }
      """
    )

    let app = RielaCLIApplication()
    let task = Task {
      await app.run([
        "workflow", "run", "two-step-command",
        "--workflow-definition-dir", workflowRoot.path,
        "--session-store", sessionStore.path,
        "--output", "json"
      ])
    }

    var progress: SessionInspectionCommandResult?
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let persisted = try? CLIWorkflowSessionStore(rootDirectory: sessionStore.path).loadAll().first {
        let result = await RielaCLIApplication().run([
          "session", "progress", persisted.session.sessionId,
          "--session-store", sessionStore.path,
          "--output", "json"
        ])
        if result.exitCode == .success,
           let decoded = try? decodeJSON(SessionInspectionCommandResult.self, from: result.stdout),
           decoded.activeStepId == "second-step" {
          progress = decoded
          break
        }
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    let liveProgress = try XCTUnwrap(progress)
    XCTAssertEqual(liveProgress.activeStepId, "second-step")
    XCTAssertNil(liveProgress.activeBackend)
    XCTAssertNotNil(liveProgress.activeExecutionUpdatedAt)
    XCTAssertEqual(liveProgress.executions.map(\.stepId), ["second-step"])
    XCTAssertEqual(liveProgress.executions.first?.status, .running)

    let result = await task.value
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
  }

  func testWorkflowRunPersistsLoopEvidenceDuringLiveProgress() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-live-loop-evidence-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("live-loop", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    let artifactRoot = tempDir.appendingPathComponent("artifacts", isDirectory: true)
    let releaseFile = tempDir.appendingPathComponent("release-command")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let script = try createExecutable(
      directory: tempDir,
      name: "live-loop-command.sh",
      body: """
      while [ ! -f '\(releaseFile.path)' ]; do
        sleep 0.05
      done
      tr -d '\\n' <<'JSON'
      {
        "loopGate": {
          "gateId": "implementation-review",
          "stepId": "run-command",
          "decision": "accepted",
          "severityCounts": { "high": 0, "medium": 0 },
          "evidenceRefs": ["live-review.json"],
          "diagnostics": ["ok"]
        }
      }
      JSON
      printf '\\n'
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      workflowId: "live-loop",
      workflowLoopJSON: """
      {
        "kind": "design-implement-review",
        "required": true,
        "gates": [
          {
            "id": "implementation-review",
            "stepId": "run-command",
            "required": true,
            "acceptWhen": { "decision": "accepted", "maxHighFindings": 0, "maxMediumFindings": 0 }
          }
        ]
      }
      """,
      stepLoopJSON: """
      {
        "role": "gate",
        "gateId": "implementation-review",
        "evidenceTags": ["live-review"],
        "recordsVerification": true
      }
      """,
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "command": {
          "executable": "\(script.path)"
        }
      }
      """
    )

    let app = RielaCLIApplication()
    let task = Task {
      await app.run([
        "workflow", "run", "live-loop",
        "--workflow-definition-dir", workflowRoot.path,
        "--session-store", sessionStore.path,
        "--artifact-root", artifactRoot.path,
        "--output", "json"
      ])
    }

    var liveSnapshot: WorkflowRuntimePersistenceSnapshot?
    var liveArtifactSnapshot: WorkflowRuntimePersistenceSnapshot?
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let record = try? CLIWorkflowSessionStore(rootDirectory: sessionStore.path).loadAll().first {
        liveSnapshot = try? SQLiteWorkflowRuntimePersistenceStore(
          rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
        ).load(sessionId: record.session.sessionId)
        liveArtifactSnapshot = try? FileWorkflowRuntimePersistenceStore(rootDirectory: artifactRoot.path)
          .load(sessionId: record.session.sessionId)
        if liveSnapshot?.loopEvidence?.steps.contains(where: { $0.status == "running" }) == true {
          break
        }
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    let evidence = try XCTUnwrap(liveSnapshot?.loopEvidence)
    XCTAssertEqual(evidence.workflowId, "live-loop")
    XCTAssertEqual(evidence.steps.first?.status, "running")
    XCTAssertEqual(evidence.steps.first?.evidenceTags, ["live-review"])
    XCTAssertEqual(evidence.gates.first?.gateId, "implementation-review")
    XCTAssertEqual(evidence.gates.first?.decision, .rejected)
    XCTAssertEqual(evidence.gates.first?.stepExecutionId, "missing")
    XCTAssertNotNil(liveArtifactSnapshot?.loopEvidence)

    try Data().write(to: releaseFile)
    let result = await task.value
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(runResult.loopEvidence?.acceptedGateCount, 1)
    let finalSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).load(sessionId: runResult.session.sessionId)
    XCTAssertEqual(finalSnapshot.loopEvidence?.gates.first?.decision, .accepted)
    XCTAssertEqual(finalSnapshot.loopEvidence?.gates.first?.evidenceRefs, ["live-review.json"])
  }

  func testWorkflowRunPersistsLoopEvidenceToSessionStoreAndArtifactRoot() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-loop-evidence-persistence-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("loop-command", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    let artifactRoot = tempDir.appendingPathComponent("artifacts", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let script = try createExecutable(
      directory: tempDir,
      name: "loop-gate-command.sh",
      body: """
      tr -d '\\n' <<'JSON'
      {
        "loopGate": {
          "gateId": "implementation-review",
          "stepId": "run-command",
          "decision": "accepted",
          "severityCounts": { "high": 0, "medium": 0 },
          "evidenceRefs": ["review.json"],
          "diagnostics": ["ok"]
        }
      }
      JSON
      printf '\\n'
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      workflowId: "loop-command",
      workflowLoopJSON: """
      {
        "kind": "design-implement-review",
        "required": true,
        "gates": [
          {
            "id": "implementation-review",
            "stepId": "run-command",
            "required": true,
            "acceptWhen": { "decision": "accepted", "maxHighFindings": 0, "maxMediumFindings": 0 }
          }
        ]
      }
      """,
      stepLoopJSON: """
      {
        "role": "gate",
        "gateId": "implementation-review",
        "evidenceTags": ["review"],
        "recordsVerification": true
      }
      """,
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "command": {
          "executable": "\(script.path)"
        }
      }
      """
    )

    let result = await RielaCLIApplication().run([
      "workflow", "run", "loop-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--artifact-root", artifactRoot.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    let runLoopEvidence = try XCTUnwrap(runResult.loopEvidence)
    XCTAssertEqual(runLoopEvidence.workflowId, "loop-command")
    XCTAssertEqual(runLoopEvidence.sessionId, runResult.session.sessionId)
    XCTAssertEqual(runLoopEvidence.gateCount, 1)
    XCTAssertEqual(runLoopEvidence.acceptedGateCount, 1)
    XCTAssertEqual(runLoopEvidence.rejectedGateCount, 0)
    XCTAssertEqual(runLoopEvidence.blockingFindingCount, 0)
    XCTAssertEqual(runLoopEvidence.stepCount, 1)
    let sessionSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).load(sessionId: runResult.session.sessionId)
    let artifactSnapshot = try FileWorkflowRuntimePersistenceStore(rootDirectory: artifactRoot.path)
      .load(sessionId: runResult.session.sessionId)

    for snapshot in [sessionSnapshot, artifactSnapshot] {
      let evidence = try XCTUnwrap(snapshot.loopEvidence)
      XCTAssertEqual(evidence.workflowId, "loop-command")
      XCTAssertEqual(evidence.sessionId, runResult.session.sessionId)
      XCTAssertEqual(evidence.workflowSource.kind, "workflow-directory")
      XCTAssertEqual(evidence.workflowSource.mutable, true)
      XCTAssertEqual(evidence.gates.first?.gateId, "implementation-review")
      XCTAssertEqual(evidence.gates.first?.decision, .accepted)
      XCTAssertEqual(evidence.gates.first?.severityCounts.high, 0)
      XCTAssertEqual(evidence.gates.first?.evidenceRefs, ["review.json"])
      XCTAssertEqual(evidence.steps.first?.evidenceTags, ["review"])
    }

    let jsonl = await RielaCLIApplication().run([
      "workflow", "run", "loop-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path
    ])
    XCTAssertEqual(jsonl.exitCode, .success, jsonl.stderr + jsonl.stdout)
    let jsonlLines = jsonl.stdout.split(separator: "\n").map(String.init)
    let finalRecord = try decodeJSON(WorkflowRunResultRecord.self, from: try XCTUnwrap(jsonlLines.last))
    XCTAssertEqual(finalRecord.type, "run_result")
    XCTAssertEqual(finalRecord.result.loopEvidence?.workflowId, "loop-command")
    XCTAssertEqual(finalRecord.result.loopEvidence?.gateCount, 1)
    XCTAssertEqual(finalRecord.result.loopEvidence?.acceptedGateCount, 1)

    let text = await RielaCLIApplication().run([
      "workflow", "run", "loop-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--output", "text"
    ])
    XCTAssertEqual(text.exitCode, .success, text.stderr + text.stdout)
    XCTAssertTrue(text.stdout.contains("loopEvidence: gates=1 accepted=1 rejected=0 blockingFindings=0"))

    let loopStatus = await RielaCLIApplication().run([
      "loop", "status", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(loopStatus.exitCode, .success, loopStatus.stderr + loopStatus.stdout)
    let loopStatusResult = try decodeJSON(LoopStatusCommandResult.self, from: loopStatus.stdout)
    XCTAssertTrue(loopStatusResult.loopEvidenceRecorded)
    XCTAssertEqual(loopStatusResult.loopEvidence?.workflowId, "loop-command")
    XCTAssertEqual(loopStatusResult.loopEvidence?.gateCount, 1)
    XCTAssertEqual(loopStatusResult.loopEvidence?.acceptedGateCount, 1)

    for command in ["status", "health", "export"] {
      let sessionInspection = await RielaCLIApplication().run([
        "session", command, runResult.session.sessionId,
        "--session-store", sessionStore.path,
        "--output", "json"
      ])
      XCTAssertEqual(sessionInspection.exitCode, .success, sessionInspection.stderr + sessionInspection.stdout)
      let inspection = try decodeJSON(SessionInspectionCommandResult.self, from: sessionInspection.stdout)
      XCTAssertTrue(inspection.loopEvidenceRecorded, command)
      XCTAssertEqual(inspection.loopEvidence?.workflowId, "loop-command", command)
      XCTAssertEqual(inspection.loopEvidence?.gateCount, 1, command)
      XCTAssertEqual(inspection.loopEvidence?.acceptedGateCount, 1, command)
      XCTAssertEqual(inspection.loopEvidence?.rejectedGateCount, 0, command)
      XCTAssertEqual(inspection.loopEvidence?.blockingFindingCount, 0, command)
    }

    let sessionText = await RielaCLIApplication().run([
      "session", "status", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "text"
    ])
    XCTAssertEqual(sessionText.exitCode, .success, sessionText.stderr + sessionText.stdout)
    XCTAssertTrue(sessionText.stdout.contains("loopEvidenceRecorded: true"))
    XCTAssertTrue(sessionText.stdout.contains("loopEvidence: gates=1 accepted=1 rejected=0 blockingFindings=0"))

    let loopEvidence = await RielaCLIApplication().run([
      "loop", "evidence", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(loopEvidence.exitCode, .success, loopEvidence.stderr + loopEvidence.stdout)
    let loopEvidenceResult = try decodeJSON(LoopEvidenceCommandResult.self, from: loopEvidence.stdout)
    XCTAssertTrue(loopEvidenceResult.loopEvidenceRecorded)
    XCTAssertEqual(loopEvidenceResult.loopEvidence?.manifestId, "loop-evidence-\(runResult.session.sessionId)")
    XCTAssertEqual(loopEvidenceResult.loopEvidence?.gates.first?.gateId, "implementation-review")

    let loopGates = await RielaCLIApplication().run([
      "loop", "gates", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(loopGates.exitCode, .success, loopGates.stderr + loopGates.stdout)
    let loopGatesResult = try decodeJSON(LoopGatesCommandResult.self, from: loopGates.stdout)
    XCTAssertTrue(loopGatesResult.loopEvidenceRecorded)
    XCTAssertEqual(loopGatesResult.gates.map(\.gateId), ["implementation-review"])
    XCTAssertEqual(loopGatesResult.gates.first?.decision, .accepted)

    let rerun = await RielaCLIApplication().run([
      "session", "rerun", runResult.session.sessionId, "run-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr + rerun.stdout)
    let rerunResult = try decodeJSON(SessionRerunCommandResult.self, from: rerun.stdout)
    XCTAssertEqual(rerunResult.recovery?.entryMode, .rerun)
    XCTAssertEqual(rerunResult.recovery?.sourceSessionId, runResult.session.sessionId)
    XCTAssertEqual(rerunResult.recovery?.sourceStepId, "run-command")
    let rerunSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).load(sessionId: rerunResult.sessionId)
    XCTAssertEqual(rerunSnapshot.loopEvidence?.recovery?.entryMode, .rerun)
    XCTAssertEqual(rerunSnapshot.loopEvidence?.recovery?.sourceSessionId, runResult.session.sessionId)
    XCTAssertEqual(rerunSnapshot.loopEvidence?.recovery?.childSessionIds, [rerunResult.sessionId])
  }

  func testWorkflowRunPersistsRejectedRequiredLoopGateForFailedRunInspection() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-rejected-loop-gate-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("rejected-loop-command", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    let artifactRoot = tempDir.appendingPathComponent("artifacts", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let script = try createExecutable(
      directory: tempDir,
      name: "rejected-loop-gate-command.sh",
      body: """
      tr -d '\\n' <<'JSON'
      {
        "loopGate": {
          "gateId": "implementation-review",
          "stepId": "run-command",
          "decision": "accepted",
          "severityCounts": { "high": 1, "medium": 0 },
          "blockingFindings": [
            {
              "id": "missing-test",
              "severity": "high",
              "message": "Regression coverage is missing.",
              "evidenceRefs": ["review.json"]
            }
          ],
          "evidenceRefs": ["review.json"],
          "diagnostics": ["high finding remained"]
        }
      }
      JSON
      printf '\\n'
      """
    )
    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      workflowId: "rejected-loop-command",
      workflowLoopJSON: """
      {
        "kind": "design-implement-review",
        "required": true,
        "gates": [
          {
            "id": "implementation-review",
            "stepId": "run-command",
            "required": true,
            "acceptWhen": { "decision": "accepted", "maxHighFindings": 0, "maxMediumFindings": 0 }
          }
        ]
      }
      """,
      stepLoopJSON: """
      {
        "role": "gate",
        "gateId": "implementation-review",
        "evidenceTags": ["review"],
        "recordsVerification": true
      }
      """,
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "command": {
          "executable": "\(script.path)"
        }
      }
      """
    )

    let result = await RielaCLIApplication().run([
      "workflow", "run", "rejected-loop-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--artifact-root", artifactRoot.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure, result.stderr + result.stdout)
    let runResult = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
    XCTAssertEqual(runResult.workflowId, "rejected-loop-command")
    XCTAssertEqual(runResult.exitCode, 1)
    XCTAssertEqual(runResult.status, .failed)
    XCTAssertEqual(runResult.session.status, .failed)
    XCTAssertEqual(runResult.loopEvidence?.gateCount, 1)
    XCTAssertEqual(runResult.loopEvidence?.acceptedGateCount, 0)
    XCTAssertEqual(runResult.loopEvidence?.rejectedGateCount, 1)
    XCTAssertEqual(runResult.loopEvidence?.blockingFindingCount, 2)

    let sessionSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    ).load(sessionId: runResult.session.sessionId)
    let artifactSnapshot = try FileWorkflowRuntimePersistenceStore(rootDirectory: artifactRoot.path)
      .load(sessionId: runResult.session.sessionId)
    for snapshot in [sessionSnapshot, artifactSnapshot] {
      XCTAssertEqual(snapshot.session.status, .failed)
      let evidence = try XCTUnwrap(snapshot.loopEvidence)
      XCTAssertEqual(evidence.gates.count, 1)
      XCTAssertEqual(evidence.gates.first?.decision, .rejected)
      XCTAssertEqual(evidence.gates.first?.severityCounts.high, 1)
      XCTAssertEqual(evidence.gates.first?.evidenceRefs, ["review.json"])
      XCTAssertEqual(evidence.gates.first?.blockingFindings.count, 2)
      XCTAssertTrue(evidence.gates.first?.blockingFindings.contains(where: { finding in
        finding.id.contains("max-high-findings")
      }) ?? false)
      XCTAssertTrue(evidence.gates.first?.blockingFindings.contains(where: { finding in
        finding.message.contains("Regression coverage is missing")
      }) ?? false)
    }

    let loopGates = await RielaCLIApplication().run([
      "loop", "gates", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(loopGates.exitCode, .success, loopGates.stderr + loopGates.stdout)
    let gates = try decodeJSON(LoopGatesCommandResult.self, from: loopGates.stdout)
    XCTAssertTrue(gates.loopEvidenceRecorded)
    XCTAssertEqual(gates.gates.first?.decision, .rejected)
    XCTAssertEqual(gates.gates.first?.blockingFindings.count, 2)

    let loopStatus = await RielaCLIApplication().run([
      "loop", "status", runResult.session.sessionId,
      "--session-store", sessionStore.path,
      "--output", "text"
    ])
    XCTAssertEqual(loopStatus.exitCode, .success, loopStatus.stderr + loopStatus.stdout)
    XCTAssertTrue(loopStatus.stdout.contains("gates: 1"))
    XCTAssertTrue(loopStatus.stdout.contains("acceptedGates: 0"))
    XCTAssertTrue(loopStatus.stdout.contains("blockingFindings: 2"))
  }

  func testWorkflowRunJSONSignalFailureIncludesPersistedSessionDiagnostic() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-json-signal-failure-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("signal-command", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      workflowId: "signal-command",
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "command": { "executable": "/bin/sh", "arguments": ["-c", "kill -13 $$"] }
      }
      """
    )

    let result = await RielaCLIApplication().run([
      "workflow", "run", "signal-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.isEmpty)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: result.stdout)
    XCTAssertEqual(failure.target, "signal-command")
    XCTAssertEqual(failure.sessionStore, sessionStore.path)
    XCTAssertEqual(failure.persistedSession, true)
    XCTAssertNotNil(failure.sessionId)
    XCTAssertTrue(failure.error.contains("exit code -13"), failure.error)
    XCTAssertEqual(failure.childExitCode, -13)
    XCTAssertEqual(failure.terminationSignal, 13)
    let sessionId = try XCTUnwrap(failure.sessionId)
    XCTAssertNotNil(try CLIWorkflowSessionStore(rootDirectory: sessionStore.path).load(sessionId: sessionId))
  }

  func testWorkflowRunJSONFailureErrorIsBounded() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-json-bounded-failure-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = tempDir.appendingPathComponent("workflows", isDirectory: true)
    let workflowDirectory = workflowRoot.appendingPathComponent("noisy-command", isDirectory: true)
    let sessionStore = tempDir.appendingPathComponent("sessions", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try writeSingleCommandWorkflow(
      workflowDirectory: workflowDirectory,
      workflowId: "noisy-command",
      nodeJSON: """
      {
        "id": "run-command",
        "nodeType": "command",
        "command": {
          "executable": "/bin/sh",
          "arguments": ["-c", "i=0; while [ $i -lt 9000 ]; do printf x >&2; i=$((i + 1)); done; exit 1"]
        }
      }
      """
    )

    let result = await RielaCLIApplication().run([
      "workflow", "run", "noisy-command",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: result.stdout)
    XCTAssertLessThanOrEqual(failure.error.count, 8_100)
    XCTAssertTrue(failure.error.contains("...(truncated)"), failure.error)
    XCTAssertEqual(failure.persistedSession, true)
  }

  private func writeSingleCommandWorkflow(
    workflowDirectory: URL,
    workflowId: String = "slow-command",
    workflowLoopJSON: String? = nil,
    stepLoopJSON: String? = nil,
    nodeJSON: String
  ) throws {
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    let workflowLoopEntry = workflowLoopJSON.map { ",\n  \"loop\": \($0)" } ?? ""
    let stepLoopEntry = stepLoopJSON.map { ",\n      \"loop\": \($0)" } ?? ""
    try """
    {
      "workflowId": "\(workflowId)",
      "defaults": { "maxLoopIterations": 1, "nodeTimeoutMs": 10000 },
      "entryStepId": "run-command",
      "nodes": [{ "id": "run-command", "nodeFile": "nodes/node-run-command.json" }],
      "steps": [
        {
          "id": "run-command",
          "nodeId": "run-command",
          "role": "worker"\(stepLoopEntry)
        }
      ]\(workflowLoopEntry)
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try nodeJSON.write(to: nodesDirectory.appendingPathComponent("node-run-command.json"), atomically: true, encoding: .utf8)
  }

  private func writeTwoCommandWorkflow(
    workflowDirectory: URL,
    firstNodeJSON: String,
    secondNodeJSON: String
  ) throws {
    let nodesDirectory = workflowDirectory.appendingPathComponent("nodes", isDirectory: true)
    try FileManager.default.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)
    try """
    {
      "workflowId": "two-step-command",
      "defaults": { "maxLoopIterations": 1, "nodeTimeoutMs": 10000 },
      "entryStepId": "first-step",
      "nodes": [
        { "id": "first-command", "nodeFile": "nodes/node-first-command.json" },
        { "id": "second-command", "nodeFile": "nodes/node-second-command.json" }
      ],
      "steps": [
        {
          "id": "first-step",
          "nodeId": "first-command",
          "role": "worker",
          "transitions": [{ "toStepId": "second-step" }]
        },
        {
          "id": "second-step",
          "nodeId": "second-command",
          "role": "worker"
        }
      ]
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try firstNodeJSON.write(to: nodesDirectory.appendingPathComponent("node-first-command.json"), atomically: true, encoding: .utf8)
    try secondNodeJSON.write(to: nodesDirectory.appendingPathComponent("node-second-command.json"), atomically: true, encoding: .utf8)
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

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(stdout.utf8))
  }
}
