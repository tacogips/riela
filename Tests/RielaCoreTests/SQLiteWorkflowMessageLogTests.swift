import XCTest
@testable import RielaCore

final class SQLiteWorkflowMessageLogTests: XCTestCase {
  func testRuntimePersistenceSaveWritesSearchableJSONBWorkflowMessageLog() throws {
    let root = temporaryDirectory()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "wf",
      sessionId: "session-jsonb",
      status: .running,
      entryStepId: "start",
      currentStepId: "worker",
      createdAt: date,
      updatedAt: date,
      executions: [
        WorkflowStepExecution(
          executionId: "exec-start",
          stepId: "start",
          nodeId: "node-start",
          attempt: 1,
          status: .completed,
          createdAt: date,
          updatedAt: date
        )
      ]
    )
    let message = WorkflowMessageRecord(
      communicationId: "comm-000001",
      workflowExecutionId: session.sessionId,
      fromStepId: "start",
      toStepId: "worker",
      sourceStepExecutionId: "exec-start",
      transitionCondition: "always",
      payload: [
        "status": .string("ok"),
        "decision": .string("route"),
        "nested": .object(["value": .string("needle")]),
        "count": .number(2)
      ],
      artifactRefs: ["artifact-a"],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: date
    )

    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(
      WorkflowRuntimePersistenceProjector.snapshot(session: session, workflowMessages: [message])
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: root
      .appendingPathComponent(session.sessionId, isDirectory: true)
      .appendingPathComponent("runtime-snapshot.json").path))

    let dbPath = SQLiteWorkflowMessageLog.defaultDatabasePath(rootDirectory: root.path)
    let storage = try sqliteColumns(
      dbPath,
      """
      SELECT typeof(payload_json), json_valid(payload_json, 8), json_valid(payload_json),
        json_extract(payload_json, '$.nested.value'), typeof(artifact_refs_json),
        json_extract(artifact_refs_json, '$[0]')
      FROM workflow_messages
      """
    )
    XCTAssertEqual(storage, ["blob", "1", "0", "needle", "blob", "artifact-a"])
    let snapshotStorage = try sqliteColumns(
      dbPath,
      """
      SELECT typeof(session_json), json_valid(session_json, 8), json_valid(session_json),
        json_extract(session_json, '$.sessionId')
      FROM workflow_runtime_snapshots
      """
    )
    XCTAssertEqual(snapshotStorage, ["blob", "1", "0", "session-jsonb"])

    let log = SQLiteWorkflowMessageLog(databasePath: dbPath)
    XCTAssertEqual(try log.jsonPathStringValues(workflowExecutionId: session.sessionId, path: "$.nested.value"), ["needle"])
    XCTAssertEqual(
      try log.listMessages(
        workflowExecutionId: session.sessionId,
        toStepId: "worker",
        payloadScalarFilter: .init(key: "status", value: .string("ok"))
      ),
      [message]
    )
  }

  func testSQLiteRuntimePersistenceRoundTripsLoopEvidenceAndMigratesExistingDatabase() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbPath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let migrationSetup = runSQLite(
      dbPath,
      """
      CREATE TABLE workflow_runtime_snapshots (
        workflow_execution_id TEXT PRIMARY KEY,
        session_json BLOB NOT NULL CHECK (json_valid(session_json, 8)),
        root_output_json BLOB CHECK (root_output_json IS NULL OR json_valid(root_output_json, 8)),
        diagnostics_json BLOB NOT NULL CHECK (json_valid(diagnostics_json, 8)),
        updated_at TEXT NOT NULL
      )
      """
    )
    XCTAssertEqual(migrationSetup.exitCode, 0, migrationSetup.stderr)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "wf",
      sessionId: "session-loop",
      status: .completed,
      entryStepId: "review",
      createdAt: date,
      updatedAt: date
    )
    let manifest = LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-session-loop",
      workflowId: "wf",
      sessionId: "session-loop",
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      gates: [
        LoopGateResult(gateId: "implementation-review", stepId: "review", stepExecutionId: "review-exec", decision: .accepted)
      ],
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )

    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try store.save(WorkflowRuntimePersistenceSnapshot(session: session, loopEvidence: manifest))
    let loaded = try store.load(sessionId: "session-loop")

    XCTAssertEqual(loaded.loopEvidence, manifest)

    let storage = try sqliteColumns(
      dbPath,
      """
      SELECT typeof(loop_evidence_json), json_valid(loop_evidence_json, 8),
        json_extract(loop_evidence_json, '$.gates[0].decision')
      FROM workflow_runtime_snapshots
      WHERE workflow_execution_id = 'session-loop'
      """
    )
    XCTAssertEqual(storage, ["blob", "1", "accepted"])
  }

  func testWorkflowMessageLogRejectsPlainTextJSONColumns() throws {
    let dbPath = temporaryDirectory().appendingPathComponent("runtime-message-log.sqlite").path
    try SQLiteWorkflowMessageLog(databasePath: dbPath).replaceMessages(for: "session-jsonb", with: [])

    let result = runSQLite(
      dbPath,
      """
      INSERT INTO workflow_messages (
        workflow_execution_id, communication_id, routing_scope, delivery_kind,
        source_step_execution_id, payload_json, artifact_refs_json,
        lifecycle_status, created_order, created_at
      ) VALUES (
        'session-jsonb', 'comm-text', 'workflow', 'direct',
        'exec-start', '{"status":"text-json"}', '[]',
        'delivered', 1, '2023-11-14T22:13:20.000Z'
      )
      """
    )

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertTrue(result.stderr.contains("CHECK constraint failed"))
  }

  func testRuntimePersistenceOpenFailureIncludesDatabasePath() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: root)
    let runtimeRoot = root.appendingPathComponent("runtime-records", isDirectory: true)
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtimeRoot.path)

    do {
      _ = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot.path).load(sessionId: "session-1")
      XCTFail("expected SQLite open failure")
    } catch WorkflowRuntimePersistenceStoreError.sqliteFailed(let message) {
      XCTAssertTrue(message.contains(databasePath), message)
      XCTAssertTrue(message.contains("failed to open sqlite database"), message)
    }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  }

  private func sqliteColumns(_ dbPath: String, _ sql: String) throws -> [String] {
    let result = runSQLite(dbPath, sql, readOnly: true)
    XCTAssertEqual(result.exitCode, 0, result.stderr)
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
  }

  private func runSQLite(_ dbPath: String, _ sql: String, readOnly: Bool = false) -> SQLiteRunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = readOnly ? ["-readonly", dbPath, sql] : [dbPath, sql]
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return SQLiteRunResult(exitCode: 1, stdout: "", stderr: "\(error)")
    }
    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return SQLiteRunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
  }
}

private struct SQLiteRunResult {
  var exitCode: Int32
  var stdout: String
  var stderr: String
}
