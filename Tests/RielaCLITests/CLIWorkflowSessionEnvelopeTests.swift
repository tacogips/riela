import Foundation
import RielaSQLite
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class CLIWorkflowSessionEnvelopeTests: XCTestCase {
  func testSaveStoresSmallEnvelopeAndLoadsCanonicalSession() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-envelope")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let record = makeRecord(sessionId: "envelope-session", status: .completed, executionCount: 3)
    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: record.session))

    let database = try openDatabase(root: root.path)
    let row = try XCTUnwrap(database.query(
      "SELECT length(record_json) AS bytes, json_type(record_json, '$.session.executions') AS executions, status "
        + "FROM cli_workflow_sessions WHERE session_id = ?",
      bindings: [.text(record.session.sessionId)]
    ).first)
    XCTAssertLessThan(try XCTUnwrap(Int(try XCTUnwrap(row["bytes"]))), 1_000)
    XCTAssertNil(row["executions"])
    XCTAssertEqual(row["status"], record.session.status.rawValue)
    XCTAssertEqual(try store.load(sessionId: record.session.sessionId), record)
    let listed = try XCTUnwrap(store.list(limit: 10).first)
    XCTAssertEqual(listed.session.executions, [])
    XCTAssertEqual(listed.executionCount, 3)
  }

  func testLegacyRecordLoadsAndConvertsToCanonicalEnvelope() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-legacy-convert")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let record = makeRecord(sessionId: "legacy-session", status: .running, executionCount: 2)
    try insertLegacy(record, using: store, root: root.path)
    try openDatabase(root: root.path).execute(
      "DELETE FROM workflow_runtime_snapshots WHERE workflow_execution_id = ?",
      bindings: [.text(record.session.sessionId)]
    )

    XCTAssertEqual(try store.load(sessionId: record.session.sessionId), record)
    XCTAssertTrue(try store.convertLegacyRecord(sessionId: record.session.sessionId))
    XCTAssertEqual(try store.legacyFullRecordIds(limit: 10), [])
    XCTAssertEqual(try store.load(sessionId: record.session.sessionId), record)
  }

  func testLegacyConversionUsesCanonicalSnapshotStatus() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-canonical-status")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var legacy = makeRecord(sessionId: "conflicting-session", status: .running, executionCount: 1)
    var canonical = legacy.session
    canonical.status = .completed
    canonical.updatedAt = canonical.updatedAt.addingTimeInterval(10)
    try insertLegacy(legacy, using: store, root: root.path)
    try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).save(WorkflowRuntimePersistenceProjector.snapshot(session: canonical))

    XCTAssertTrue(try store.convertLegacyRecord(sessionId: legacy.session.sessionId))
    let converted = try store.load(sessionId: legacy.session.sessionId)
    XCTAssertEqual(converted.session.status, .completed)
    XCTAssertEqual(converted.session.updatedAt, canonical.updatedAt)
    legacy.session.status = .completed
    legacy.session.updatedAt = canonical.updatedAt
    XCTAssertEqual(converted, legacy)
  }

  func testMissingCanonicalSnapshotIsUnreadableAndListKeepsOtherRows() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-missing-canonical")
    defer { try? FileManager.default.removeItem(at: root) }
    let warnings = EnvelopeWarningRecorder()
    let store = CLIWorkflowSessionStore(rootDirectory: root.path, warningSink: warnings.record)
    let valid = makeRecord(sessionId: "valid-envelope", status: .completed, executionCount: 1)
    let missing = makeRecord(sessionId: "missing-envelope", status: .failed, executionCount: 1)
    try store.save(valid, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: valid.session))
    try store.save(missing, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: missing.session))
    let database = try openDatabase(root: root.path)
    try database.execute(
      "DELETE FROM workflow_runtime_snapshots WHERE workflow_execution_id = ?",
      bindings: [.text(missing.session.sessionId)]
    )

    XCTAssertEqual(try store.list(limit: 10).map(\.session.sessionId), [valid.session.sessionId])
    XCTAssertEqual(warnings.take(), ["warning: skipped 1 unreadable CLI session record(s)"])
    XCTAssertThrowsError(try store.loadStrictReadOnly(sessionId: missing.session.sessionId)) { error in
      XCTAssertEqual(
        error as? CLIWorkflowSessionStoreError,
        .canonicalSnapshotMissing(sessionId: missing.session.sessionId)
      )
    }
    XCTAssertEqual(warnings.take(), [])
  }

  func testExecutionIdentityObservationReadsEnvelopeAndLegacyRows() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-execution-identities")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var envelope = makeRecord(sessionId: "identity-envelope", status: .running, executionCount: 2)
    envelope.session.executions[1].executionId = "envelope-exec-90"
    try store.save(envelope, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: envelope.session))
    var legacy = makeRecord(sessionId: "identity-legacy", status: .running, executionCount: 1)
    legacy.session.executions[0].executionId = "legacy-exec-2"
    try insertLegacy(legacy, using: store, root: root.path)
    let generator = MonotonicWorkflowRuntimeIDGenerator()

    try store.observePersistedExecutionIdentities(generator)

    XCTAssertEqual(try generator.nextStepExecutionId(stepId: "probe", attempt: 1), "probe-attempt-1-exec-91")
  }

  func testListUsesHeaderForInlineCanonicalSnapshotAndCountsExecutions() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-inline-header")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let record = makeRecord(sessionId: "inline-header", status: .running, executionCount: 3)
    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: record.session))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let sessionJSON = try XCTUnwrap(String(data: encoder.encode(record.session), encoding: .utf8))
    try openDatabase(root: root.path).execute(
      "UPDATE workflow_runtime_snapshots SET session_json = jsonb(?) WHERE workflow_execution_id = ?",
      bindings: [.text(sessionJSON), .text(record.session.sessionId)]
    )

    let listed = try XCTUnwrap(store.list(limit: 10).first)
    XCTAssertEqual(listed.session.executions, [])
    XCTAssertEqual(listed.executionCount, 3)
  }

  func testListCountExcludesImportedExecutions() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-imported-count")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var record = makeRecord(sessionId: "imported-count", status: .running, executionCount: 3)
    record.session.executions[1].importedFrom = WorkflowImportedExecutionSource(
      sessionId: "source-session", executionId: "source-execution"
    )

    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: record.session))

    XCTAssertEqual(try store.list(limit: 10).first?.executionCount, 2)
  }

  func testReadOnlyListSupportsGenerationTenRuntimeTables() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-generation-ten-list")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let record = makeRecord(sessionId: "generation-ten", status: .running, executionCount: 3)
    try insertLegacy(record, using: store, root: root.path)
    let database = try openDatabase(root: root.path)
    try database.execute("DROP TABLE workflow_runtime_executions")
    try database.execute("DROP TABLE workflow_runtime_payloads")

    let listed = try XCTUnwrap(store.list(status: .running, limit: 10).first)
    XCTAssertEqual(listed.session.sessionId, record.session.sessionId)
    XCTAssertEqual(listed.executionCount, 3)
  }

  func testListCountWorkDoesNotReadLargeExecutionPayloads() throws {
    let smallRoot = try makeRielaCLITestTemporaryDirectory("cli-session-small-payload-count")
    let largeRoot = try makeRielaCLITestTemporaryDirectory("cli-session-large-payload-count")
    defer {
      try? FileManager.default.removeItem(at: smallRoot)
      try? FileManager.default.removeItem(at: largeRoot)
    }

    func countQueryWork(root: URL, sessionId: String, payloadBytes: Int) throws -> Int {
      let store = CLIWorkflowSessionStore(rootDirectory: root.path)
      var record = makeRecord(sessionId: sessionId, status: .running, executionCount: 4)
      for index in record.session.executions.indices {
        record.session.executions[index].streamedResponseText = String(repeating: "x", count: payloadBytes)
      }
      try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: record.session))
      XCTAssertEqual(try store.list(limit: 10).first?.executionCount, 4)

      let database = try openDatabase(root: root.path)
      let query = try store.listSQL(workflowName: nil, status: nil, limit: 10, in: database)
      let workBefore = database.statementWorkSnapshot
      _ = try database.query(query.sql, bindings: query.bindings)
      return database.statementWorkSnapshot.vmSteps - workBefore.vmSteps
    }

    let smallWork = try countQueryWork(root: smallRoot, sessionId: "small-payload-count", payloadBytes: 20)
    let largeWork = try countQueryWork(root: largeRoot, sessionId: "large-payload-count", payloadBytes: 250_000)
    XCTAssertLessThanOrEqual(largeWork, smallWork + 5)
  }

  func testSavingListSummaryThrowsAndPreservesCanonicalExecutions() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-summary-save")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let record = makeRecord(sessionId: "summary-save", status: .running, executionCount: 3)
    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: record.session))
    let listed = try XCTUnwrap(store.list(limit: 10).first)

    XCTAssertThrowsError(try store.save(listed)) { error in
      XCTAssertEqual(
        error as? CLIWorkflowSessionStoreError,
        .sqliteFailed("cannot save header-only session summary: \(record.session.sessionId)")
      )
    }
    let executionCount = try openDatabase(root: root.path).query(
      "SELECT COUNT(*) AS count FROM workflow_runtime_executions WHERE workflow_execution_id = ?",
      bindings: [.text(record.session.sessionId)]
    ).first?["count"]
    XCTAssertEqual(executionCount, "3")
  }

  func testHydrationSkipsMissingCanonicalSnapshotWithWarning() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-hydration-missing-canonical")
    defer { try? FileManager.default.removeItem(at: root) }
    let warnings = EnvelopeWarningRecorder()
    let store = CLIWorkflowSessionStore(rootDirectory: root.path, warningSink: warnings.record)
    let record = makeRecord(sessionId: "hydration-missing", status: .running, executionCount: 1)
    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: record.session))
    try openDatabase(root: root.path).execute(
      "DELETE FROM workflow_runtime_snapshots WHERE workflow_execution_id = ?",
      bindings: [.text(record.session.sessionId)]
    )
    XCTAssertThrowsError(try store.load(sessionId: record.session.sessionId)) { error in
      guard let storeError = error as? CLIWorkflowSessionStoreError,
        case .notFound = storeError else {
        return XCTFail("expected a non-strict missing-session result")
      }
    }
    XCTAssertEqual(warnings.take(), ["warning: skipped 1 unreadable CLI session record(s)"])
    let runtime = InMemoryWorkflowRuntimeStore()

    try await seedRuntimeStoreFromPersistedCLIState(runtime, sessionStoreRoot: root.path, familyOf: record.session.sessionId)

    let hydrated = try await runtime.loadSession(id: record.session.sessionId)
    XCTAssertNil(hydrated)
    XCTAssertEqual(warnings.take(), [])
  }

  func testListStatusFilterUsesCanonicalStatusAfterRuntimeOnlyUpdate() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-canonical-filter")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let record = makeRecord(sessionId: "canonical-filter", status: .running, executionCount: 1)
    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: record.session))
    var canonical = record.session
    canonical.status = .cancelled
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
      .save(WorkflowRuntimePersistenceProjector.snapshot(session: canonical))

    XCTAssertTrue(try store.list(status: .running, limit: 10).isEmpty)
    XCTAssertEqual(try store.list(status: .cancelled, limit: 10).first?.session.status, .cancelled)
  }

  func testLegacyRowBecomesEnvelopeOnOrdinarySave() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-ordinary-save")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    var record = makeRecord(sessionId: "ordinary-save", status: .running, executionCount: 1)
    try insertLegacy(record, using: store, root: root.path)
    record.session.status = .completed

    try store.save(record)

    XCTAssertTrue(try store.legacyFullRecordIds(limit: 10).isEmpty)
    let canonical = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).load(sessionId: record.session.sessionId)
    XCTAssertEqual(canonical.session.status, .completed)
  }

  func testCLISavePreservesWorkflowMessagesInExistingCanonicalSnapshot() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-save-preserves-messages")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let record = makeRecord(sessionId: "preserve-messages", status: .running, executionCount: 1)
    let message = WorkflowMessageRecord(
      communicationId: "communication-1", workflowExecutionId: record.session.sessionId,
      fromStepId: "step-1", toStepId: "worker", sourceStepExecutionId: record.session.executions[0].executionId,
      payload: ["body": .string("kept")], lifecycleStatus: .delivered, createdOrder: 1,
      createdAt: record.session.updatedAt
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
      .save(WorkflowRuntimePersistenceSnapshot(session: record.session, workflowMessages: [message]))

    try store.save(record)

    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).load(sessionId: record.session.sessionId)
    XCTAssertEqual(snapshot.workflowMessages, [message])
  }

  func testForeignPinLockDoesNotStartLocalTransaction() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-foreign-pin")
    let definitionRoot = try makeRielaCLITestTemporaryDirectory("cli-session-definition-store")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: definitionRoot)
    }
    let data = Data(#"{"version":1}"#.utf8)
    let outcome = try WorkflowDefinitionStore(rootDirectory: definitionRoot.path).commit(
      WorkflowDefinitionWrite(
        workflowName: "pinned-workflow",
        operation: .seed,
        documentData: data,
        documentDigest: JSONCanonical.sha256Hex(data),
        sourceDirectory: definitionRoot.path,
        sourceScope: "user",
        provenance: "test",
        actor: WorkflowDefinitionActor(kind: .user),
        reason: "seed"
      )
    )
    guard case let .created(definitionVersion, _) = outcome else {
      return XCTFail("expected definition version to be created")
    }
    let version = definitionVersion.versionId
    let definitionDB = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: definitionRoot.path)
    )
    try definitionDB.execute("BEGIN IMMEDIATE")
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let source = WorkflowDefinitionSource(
      kind: .store,
      workflowName: "pinned-workflow",
      versionId: version,
      storeRoot: definitionRoot.path,
      digest: JSONCanonical.sha256Hex(data)
    )
    let session = WorkflowSession(
      workflowId: "pinned-workflow",
      sessionId: "foreign-pin-session",
      entryStepId: "entry",
      createdAt: date,
      updatedAt: date,
      definitionSource: source
    )
    let record = PersistedCLIWorkflowSession(
      workflowName: "pinned-workflow",
      session: session,
      resolution: WorkflowResolutionOptions(workflowName: "pinned-workflow", scope: .user)
    )
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    let save = Task.detached {
      try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: session))
    }
    try await Task.sleep(for: .milliseconds(150))
    save.cancel()
    do {
      try await save.value
      XCTFail("a cancelled wait on the held foreign writer lock should fail before the local transaction")
    } catch {
      // The cancellable SQLite lock wait is interrupted before local writes begin.
    }
    let localDatabase = try openDatabase(root: root.path)
    XCTAssertEqual(try localDatabase.query("SELECT COUNT(*) AS count FROM cli_workflow_sessions").first?["count"], "0")
    XCTAssertEqual(try localDatabase.query("SELECT COUNT(*) AS count FROM workflow_runtime_snapshots").first?["count"], "0")
    try definitionDB.execute("COMMIT")
    try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: session))
    XCTAssertEqual(try definitionDB.query(
      "SELECT COUNT(*) AS count FROM definition_version_pins WHERE session_id = ?",
      bindings: [.text(session.sessionId)]
    ).first?["count"], "1")
    XCTAssertEqual(try store.load(sessionId: session.sessionId).session, session)
  }

  func testForeignPinFailureLeavesLocalRowsAbsentAndRetrySucceeds() throws {
    let root = try makeRielaCLITestTemporaryDirectory("cli-session-foreign-pin-failure")
    let definitionRoot = try makeRielaCLITestTemporaryDirectory("cli-session-definition-failure")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: definitionRoot)
    }
    let data = Data(#"{"version":1}"#.utf8)
    let outcome = try WorkflowDefinitionStore(rootDirectory: definitionRoot.path).commit(
      WorkflowDefinitionWrite(
        workflowName: "pinned-workflow",
        operation: .seed,
        documentData: data,
        documentDigest: JSONCanonical.sha256Hex(data),
        sourceDirectory: definitionRoot.path,
        sourceScope: "user",
        provenance: "test",
        actor: WorkflowDefinitionActor(kind: .user),
        reason: "seed"
      )
    )
    guard case let .created(version, _) = outcome else {
      return XCTFail("expected definition version to be created")
    }
    let definitionDB = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: definitionRoot.path)
    )
    try definitionDB.execute("""
      CREATE TRIGGER reject_cli_foreign_pin BEFORE INSERT ON definition_version_pins
      BEGIN SELECT RAISE(ABORT, 'injected CLI foreign pin failure'); END
      """)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let session = WorkflowSession(
      workflowId: "pinned-workflow",
      sessionId: "foreign-pin-retry",
      entryStepId: "entry",
      createdAt: date,
      updatedAt: date,
      definitionSource: WorkflowDefinitionSource(
        kind: .store,
        workflowName: "pinned-workflow",
        versionId: version.versionId,
        storeRoot: definitionRoot.path,
        digest: JSONCanonical.sha256Hex(data)
      )
    )
    let record = PersistedCLIWorkflowSession(
      workflowName: "pinned-workflow",
      session: session,
      resolution: WorkflowResolutionOptions(workflowName: "pinned-workflow", scope: .user)
    )
    let store = CLIWorkflowSessionStore(rootDirectory: root.path)
    XCTAssertThrowsError(try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: session)))
    let localDatabase = try openDatabase(root: root.path)
    XCTAssertEqual(try localDatabase.query("SELECT COUNT(*) AS count FROM cli_workflow_sessions").first?["count"], "0")
    XCTAssertEqual(try localDatabase.query("SELECT COUNT(*) AS count FROM workflow_runtime_snapshots").first?["count"], "0")

    try definitionDB.execute("DROP TRIGGER reject_cli_foreign_pin")
    XCTAssertNoThrow(try store.save(record, runtimeSnapshot: WorkflowRuntimePersistenceProjector.snapshot(session: session)))
    XCTAssertEqual(try definitionDB.query(
      "SELECT COUNT(*) AS count FROM definition_version_pins WHERE session_id = ?",
      bindings: [.text(session.sessionId)]
    ).first?["count"], "1")
  }

  private func makeRecord(
    sessionId: String,
    status: WorkflowSessionStatus,
    executionCount: Int
  ) -> PersistedCLIWorkflowSession {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let executions = (1...executionCount).map { index in
      WorkflowStepExecution(
        executionId: "step-\(index)-attempt-1-exec-\(index)",
        stepId: "step-\(index)",
        nodeId: "worker",
        attempt: 1,
        inputSnapshot: ["payload": .string(String(repeating: "x", count: 20))],
        status: .completed,
        createdAt: date,
        updatedAt: date
      )
    }
    return PersistedCLIWorkflowSession(
      workflowName: "envelope-workflow",
      session: WorkflowSession(
        workflowId: "envelope-workflow",
        sessionId: sessionId,
        status: status,
        entryStepId: "step-1",
        currentStepId: "step-\(executionCount)",
        createdAt: date,
        updatedAt: date,
        executions: executions
      ),
      resolution: WorkflowResolutionOptions(workflowName: "envelope-workflow", scope: .project)
    )
  }

  private func openDatabase(root: String) throws -> SQLiteDatabase {
    try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root))
  }

  private func insertLegacy(
    _ record: PersistedCLIWorkflowSession,
    using store: CLIWorkflowSessionStore,
    root: String
  ) throws {
    try store.save(record)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try XCTUnwrap(String(data: encoder.encode(record), encoding: .utf8))
    try openDatabase(root: root).execute(
      "UPDATE cli_workflow_sessions SET record_json = jsonb(?) WHERE session_id = ?",
      bindings: [.text(json), .text(record.session.sessionId)]
    )
  }
}

private final class EnvelopeWarningRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []

  func record(_ message: String) {
    lock.lock()
    messages.append(message)
    lock.unlock()
  }

  func take() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let result = messages
    messages = []
    return result
  }
}
