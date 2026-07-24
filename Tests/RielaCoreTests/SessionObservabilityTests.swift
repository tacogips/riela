import XCTest
@testable import RielaCore

final class SessionObservabilityTests: XCTestCase {
  func testDigestUsesPersistedBudgetAndBuildsDeterministicChildTree() throws {
    let observedAt = Date(timeIntervalSince1970: 2_000)
    let parent = snapshot(
      sessionId: "parent",
      status: .running,
      createdAt: Date(timeIntervalSince1970: 1_000),
      effectiveStepBudget: 12
    )
    let laterChild = snapshot(
      sessionId: "child-b",
      parentSessionId: "parent",
      rootSessionId: "parent",
      status: .running,
      createdAt: Date(timeIntervalSince1970: 1_200)
    )
    let earlierChild = snapshot(
      sessionId: "child-a",
      parentSessionId: "parent",
      rootSessionId: "parent",
      status: .completed,
      createdAt: Date(timeIntervalSince1970: 1_100)
    )
    let snapshots = [laterChild, parent, earlierChild]
    let service = SessionObservabilityService(
      loadSnapshot: { id in try XCTUnwrap(snapshots.first { $0.session.sessionId == id }) },
      loadRollupSnapshots: { _ in snapshots },
      clock: FixedWorkflowRuntimeClock(observedAt)
    )

    let view = try service.progress(
      sessionId: "parent",
      includeChildren: true,
      previousStatuses: ["parent": .created]
    )

    XCTAssertEqual(view.root.digest.effectiveStepBudget, 12)
    XCTAssertEqual(view.root.digest.previousStatus, .created)
    XCTAssertEqual(view.root.children.map(\.digest.sessionId), ["child-a", "child-b"])
    XCTAssertFalse(SessionObservabilityService.isTerminal(view.root))
  }

  func testDigestProjectsEveryAcceptedProgressSignalFromOneObservationTime() throws {
    let observedAt = Date(timeIntervalSince1970: 2_000)
    let eventAt = observedAt.addingTimeInterval(-5)
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let executions = [
      WorkflowStepExecution(
        executionId: "exec-1",
        stepId: "prepare",
        nodeId: "prepare-node",
        attempt: 1,
        backend: .codexAgent,
        status: .completed,
        createdAt: createdAt,
        updatedAt: createdAt
      ),
      WorkflowStepExecution(
        executionId: "exec-2",
        stepId: "translate-step",
        nodeId: "translate-node",
        attempt: 1,
        backend: .claudeCodeAgent,
        status: .running,
        lastBackendEventAt: eventAt,
        lastBackendEventType: "assistant",
        createdAt: createdAt,
        updatedAt: eventAt
      )
    ]
    let session = WorkflowSession(
      workflowId: "workflow",
      sessionId: "session",
      status: .running,
      entryStepId: "prepare",
      currentStepId: "translate-step",
      createdAt: createdAt,
      updatedAt: eventAt,
      executions: executions,
      stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic(
        stepBudget: 7,
        executionCount: 2,
        maxLoopIterations: 3,
        budgetSource: .computedDefault
      ),
      effectiveStepBudget: 12
    )
    let snapshot = WorkflowRuntimePersistenceSnapshot(
      session: session,
      loopEvidence: loopEvidence(
        sessionId: session.sessionId,
        date: createdAt,
        gateVisitCounts: ["implementation-review": 3]
      )
    )
    let service = SessionObservabilityService(
      loadSnapshot: { _ in snapshot },
      loadRollupSnapshots: { _ in [snapshot] },
      clock: FixedWorkflowRuntimeClock(observedAt)
    )

    let digest = try service.progress(sessionId: session.sessionId).root.digest

    XCTAssertEqual(digest.observedAt, observedAt)
    XCTAssertEqual(digest.currentStepId, "translate-step")
    XCTAssertEqual(digest.currentStage, "Translation in progress")
    XCTAssertEqual(digest.executionCount, 2)
    XCTAssertEqual(digest.effectiveStepBudget, 7, "stepBudgetDiagnostic must take precedence")
    XCTAssertEqual(digest.gateVisitCounts, ["implementation-review": 3])
    XCTAssertEqual(digest.lastBackendEventType, "assistant")
    XCTAssertEqual(digest.lastBackendEventAt, eventAt)
    XCTAssertEqual(digest.lastBackendEventAgeMs, 5_000)
    XCTAssertEqual(digest.activeBackend, .claudeCodeAgent)
  }

  func testRollupStopsAtPersistedParentCycle() throws {
    let parent = snapshot(
      sessionId: "parent",
      parentSessionId: "child",
      rootSessionId: "parent",
      status: .running
    )
    let child = snapshot(
      sessionId: "child",
      parentSessionId: "parent",
      rootSessionId: "parent",
      status: .running
    )
    let service = SessionObservabilityService(
      loadSnapshot: { _ in parent },
      loadRollupSnapshots: { _ in [parent, child] },
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 2_000))
    )

    let root = try service.progress(sessionId: "parent", includeChildren: true).root

    XCTAssertEqual(root.digest.sessionId, "parent")
    XCTAssertEqual(root.children.map(\.digest.sessionId), ["child"])
    XCTAssertTrue(root.children[0].children.isEmpty)
  }

  func testSessionAndExecutionProvenanceRoundTripAndLegacyDefaults() throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let execution = WorkflowStepExecution(
      executionId: "exec-1",
      stepId: "step-1",
      nodeId: "node-1",
      attempt: 1,
      backend: .codexAgent,
      backendSessionId: "codex-session",
      backendWorkingDirectory: "/tmp/project",
      createdAt: date,
      updatedAt: date
    )
    let session = WorkflowSession(
      workflowId: "workflow",
      sessionId: "child",
      entryStepId: "step-1",
      createdAt: date,
      updatedAt: date,
      executions: [execution],
      parentSessionId: "parent",
      rootSessionId: "root",
      effectiveStepBudget: 20
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(WorkflowSession.self, from: encoder.encode(session))
    XCTAssertEqual(decoded.parentSessionId, "parent")
    XCTAssertEqual(decoded.rootSessionId, "root")
    XCTAssertEqual(decoded.effectiveStepBudget, 20)
    XCTAssertEqual(decoded.executions.first?.backendSessionId, "codex-session")
    XCTAssertEqual(decoded.executions.first?.backendWorkingDirectory, "/tmp/project")

    let legacyJSON = """
    {"workflowId":"workflow","sessionId":"legacy","status":"created","entryStepId":"step","createdAt":"1970-01-01T00:16:40Z","updatedAt":"1970-01-01T00:16:40Z"}
    """
    let legacy = try decoder.decode(WorkflowSession.self, from: Data(legacyJSON.utf8))
    XCTAssertNil(legacy.parentSessionId)
    XCTAssertNil(legacy.rootSessionId)
    XCTAssertNil(legacy.effectiveStepBudget)
  }

  func testTransitionalCancelledFailureKindIsTerminal() throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let session = WorkflowSession(
      workflowId: "workflow",
      sessionId: "cancelled",
      status: .running,
      entryStepId: "step",
      currentStepId: "step",
      createdAt: date,
      updatedAt: date,
      failureKind: .cancelled
    )
    let snapshot = WorkflowRuntimePersistenceSnapshot(session: session)
    let service = SessionObservabilityService(
      loadSnapshot: { _ in snapshot },
      loadRollupSnapshots: { _ in [snapshot] },
      clock: FixedWorkflowRuntimeClock(date)
    )

    XCTAssertTrue(SessionObservabilityService.isTerminal(session))
    XCTAssertTrue(SessionObservabilityService.isTerminal(try service.progress(sessionId: "cancelled").root))
  }

  func testHealthDoesNotFallBackToCompletedBackendWhileNonBackendStepIsRunning() throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let session = WorkflowSession(
      workflowId: "workflow",
      sessionId: "session",
      status: .running,
      entryStepId: "backend-step",
      currentStepId: "local-step",
      createdAt: date,
      updatedAt: date,
      executions: [
        WorkflowStepExecution(
          executionId: "backend-exec",
          stepId: "backend-step",
          nodeId: "backend-node",
          attempt: 1,
          backend: .codexAgent,
          status: .completed,
          lastBackendEventAt: date,
          lastBackendEventType: "turn.completed",
          createdAt: date,
          updatedAt: date
        ),
        WorkflowStepExecution(
          executionId: "local-exec",
          stepId: "local-step",
          nodeId: "local-node",
          attempt: 1,
          status: .running,
          createdAt: date,
          updatedAt: date
        )
      ]
    )
    let snapshot = WorkflowRuntimePersistenceSnapshot(session: session)
    let service = SessionObservabilityService(
      loadSnapshot: { _ in snapshot },
      loadRollupSnapshots: { _ in [snapshot] },
      clock: FixedWorkflowRuntimeClock(date)
    )

    let activity = try XCTUnwrap(service.health(sessionId: session.sessionId).backendActivity)

    XCTAssertNil(activity.backend)
    XCTAssertEqual(activity.verdict, .unknown)
    XCTAssertEqual(activity.evidence.first?.detail, "the session has no active backend execution to assess")
  }

  func testProbeFailureUsesStableNonSecretDiagnostic() throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let execution = WorkflowStepExecution(
      executionId: "exec",
      stepId: "step",
      nodeId: "node",
      attempt: 1,
      backend: .codexAgent,
      createdAt: date,
      updatedAt: date
    )
    let session = WorkflowSession(
      workflowId: "workflow",
      sessionId: "session",
      status: .running,
      entryStepId: "step",
      currentStepId: "step",
      createdAt: date,
      updatedAt: date,
      executions: [execution]
    )
    let activity = SessionBackendActivityProbeRegistry([ThrowingBackendActivityProbe()]).assess(
      SessionBackendActivityProbeInput(
        session: session,
        execution: execution,
        backend: .codexAgent,
        observedAt: date,
        activeThresholdMs: 30_000,
        stalledThresholdMs: 180_000
      )
    )

    XCTAssertEqual(activity.verdict, .unknown)
    XCTAssertEqual(activity.evidence.map(\.detail), ["backend activity probe failed"])
    XCTAssertFalse(activity.evidence[0].detail.contains("super-secret"))
  }

  func testSQLiteRollupDiscoversInFlightChildWithoutMutatingReadTimestamp() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try store.save(snapshot(sessionId: "parent", status: .running))
    try store.save(snapshot(
      sessionId: "child",
      parentSessionId: "parent",
      rootSessionId: "parent",
      status: .running
    ))
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let before = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date
    )

    let snapshots = try store.loadRollupSnapshots(sessionId: "parent")
    let after = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date
    )

    XCTAssertEqual(Set(snapshots.map(\.session.sessionId)), Set(["parent", "child"]))
    XCTAssertEqual(before, after)
  }

  func testSQLiteRollupPageBoundsDecodedSnapshotsAndReportsTruncation() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try store.save(snapshot(sessionId: "parent", status: .running))
    for childId in ["child-a", "child-b", "child-c"] {
      try store.save(snapshot(
        sessionId: childId,
        parentSessionId: "parent",
        rootSessionId: "parent",
        status: .running
      ))
    }

    let page = try store.loadRollupSnapshotPage(sessionId: "parent", limit: 2)
    let service = SessionObservabilityService(
      loadSnapshot: { try store.loadStrictReadOnly(sessionId: $0) },
      loadRollupSnapshotPage: { _ in page },
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 2_000))
    )
    let view = try service.progress(sessionId: "parent", includeChildren: true)

    XCTAssertEqual(page.snapshots.map(\.session.sessionId), ["parent", "child-a"])
    XCTAssertTrue(page.truncated)
    XCTAssertEqual(page.limit, 2)
    XCTAssertEqual(view.rollupTruncated, true)
    XCTAssertEqual(view.rollupSnapshotLimit, 2)
    XCTAssertEqual(view.root.children.map(\.digest.sessionId), ["child-a"])
  }

  func testSQLiteRollupReadsPreMigrationSchemaWithoutDDL() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let setup = runSQLite(
      databasePath,
      """
      CREATE TABLE workflow_runtime_snapshots (
        workflow_execution_id TEXT PRIMARY KEY,
        session_json BLOB NOT NULL CHECK (json_valid(session_json, 8)),
        root_output_json BLOB CHECK (root_output_json IS NULL OR json_valid(root_output_json, 8)),
        diagnostics_json BLOB NOT NULL CHECK (json_valid(diagnostics_json, 8)),
        updated_at TEXT NOT NULL
      );
      CREATE TABLE workflow_messages (
        workflow_execution_id TEXT NOT NULL,
        communication_id TEXT NOT NULL,
        from_step_id TEXT,
        to_step_id TEXT,
        routing_scope TEXT NOT NULL,
        delivery_kind TEXT NOT NULL,
        source_step_execution_id TEXT NOT NULL,
        transition_condition TEXT,
        payload_json BLOB NOT NULL CHECK (json_valid(payload_json, 8)),
        artifact_refs_json BLOB NOT NULL CHECK (json_valid(artifact_refs_json, 8)),
        lifecycle_status TEXT NOT NULL,
        created_order INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (workflow_execution_id, communication_id)
      );
      INSERT INTO workflow_runtime_snapshots VALUES (
        'legacy',
        jsonb('{"workflowId":"workflow","sessionId":"legacy","status":"running","entryStepId":"step","currentStepId":"step","createdAt":"1970-01-01T00:16:40Z","updatedAt":"1970-01-01T00:16:40Z","executions":[]}'),
        NULL,
        jsonb('[]'),
        '1970-01-01T00:16:40Z'
      );
      """
    )
    XCTAssertEqual(setup.exitCode, 0, setup.stderr)
    let before = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date
    )

    let snapshots = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
      .loadRollupSnapshots(sessionId: "legacy")
    let columns = runSQLite(
      databasePath,
      "SELECT name FROM pragma_table_info('workflow_runtime_snapshots') ORDER BY cid;",
      readOnly: true
    )
    let after = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date
    )

    XCTAssertEqual(snapshots.map(\.session.sessionId), ["legacy"])
    XCTAssertEqual(before, after)
    XCTAssertFalse(columns.stdout.contains("parent_session_id"))
    XCTAssertFalse(columns.stdout.contains("root_session_id"))
  }

  func testSQLiteRollupUsesImmutableFallbackWithoutMutatingStore() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try store.save(snapshot(sessionId: "parent", status: .running))
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let checkpoint = runSQLite(databasePath, "PRAGMA wal_checkpoint(TRUNCATE);")
    XCTAssertEqual(checkpoint.exitCode, 0, checkpoint.stderr)
    removeSQLiteSidecars(for: databasePath)
    let before = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date
    )
    let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: databasePath))

    let snapshots = try store.loadRollupSnapshots(sessionId: "parent")

    let after = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date
    )
    XCTAssertEqual(snapshots.map(\.session.sessionId), ["parent"])
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: databasePath)), bytesBefore)
    XCTAssertEqual(after, before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath + "-shm"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath + "-wal"))
  }

  func testLegacySnapshotLoadRetainsIdleWALCompatibilityFallback() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try store.save(snapshot(sessionId: "legacy-reader", status: .running))
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let checkpoint = runSQLite(databasePath, "PRAGMA wal_checkpoint(TRUNCATE);")
    XCTAssertEqual(checkpoint.exitCode, 0, checkpoint.stderr)
    removeSQLiteSidecars(for: databasePath)

    let loaded = try store.load(sessionId: "legacy-reader")

    XCTAssertEqual(loaded.session.sessionId, "legacy-reader")
  }

  func testSQLiteRollupCanReadDuringHeldWriterTransaction() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try store.save(snapshot(sessionId: "parent", status: .running))
    try store.save(snapshot(
      sessionId: "child",
      parentSessionId: "parent",
      rootSessionId: "parent",
      status: .running
    ))
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databasePath]
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    try process.run()
    defer {
      if process.isRunning {
        input.fileHandleForWriting.write(Data("ROLLBACK;\n.quit\n".utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
      }
    }
    input.fileHandleForWriting.write(Data(
      """
      BEGIN IMMEDIATE;
      UPDATE workflow_runtime_snapshots
      SET updated_at = '2033-05-18T03:33:20Z'
      WHERE workflow_execution_id = 'child';
      .print writer-transaction-held

      """.utf8
    ))
    let marker = String(
      data: output.fileHandleForReading.availableData,
      encoding: .utf8
    ) ?? ""
    XCTAssertTrue(marker.contains("writer-transaction-held"), marker)

    let snapshots = try store.loadRollupSnapshots(sessionId: "parent")
    XCTAssertEqual(Set(snapshots.map(\.session.sessionId)), Set(["parent", "child"]))
    XCTAssertTrue(process.isRunning, "reader must complete while the writer transaction remains open")

    input.fileHandleForWriting.write(Data("COMMIT;\n.quit\n".utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, String(
      data: error.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? "")
  }

  private func snapshot(
    sessionId: String,
    parentSessionId: String? = nil,
    rootSessionId: String? = nil,
    status: WorkflowSessionStatus,
    createdAt: Date = Date(timeIntervalSince1970: 1_000),
    effectiveStepBudget: Int? = nil
  ) -> WorkflowRuntimePersistenceSnapshot {
    WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "workflow",
      sessionId: sessionId,
      status: status,
      entryStepId: "step",
      currentStepId: status == .running ? "step" : nil,
      createdAt: createdAt,
      updatedAt: createdAt,
      parentSessionId: parentSessionId,
      rootSessionId: rootSessionId,
      effectiveStepBudget: effectiveStepBudget
    ))
  }

  private func loopEvidence(
    sessionId: String,
    date: Date,
    gateVisitCounts: [String: Int]
  ) -> LoopEvidenceManifest {
    LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-\(sessionId)",
      workflowId: "workflow",
      sessionId: sessionId,
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      convergence: LoopConvergenceEvidence(gateVisitCounts: gateVisitCounts),
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
  }

  private func runSQLite(_ databasePath: String, _ sql: String, readOnly: Bool = false) -> SQLiteRunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = readOnly ? ["-readonly", databasePath, sql] : [databasePath, sql]
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
    return SQLiteRunResult(
      exitCode: process.terminationStatus,
      stdout: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  private func removeSQLiteSidecars(for databasePath: String) {
    for suffix in ["-shm", "-wal"] {
      try? FileManager.default.removeItem(atPath: databasePath + suffix)
    }
  }
}

private struct SQLiteRunResult {
  var exitCode: Int32
  var stdout: String
  var stderr: String
}

private struct ThrowingBackendActivityProbe: SessionBackendActivityProbing {
  let backend = NodeExecutionBackend.codexAgent

  func assess(_: SessionBackendActivityProbeInput) throws -> SessionBackendActivity {
    throw SensitiveProbeError()
  }
}

private struct SensitiveProbeError: Error, CustomStringConvertible {
  var description: String {
    "token=super-secret path=/Users/example/private"
  }
}
