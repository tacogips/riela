import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class RuntimePersistenceBoundedWriteTests: XCTestCase {
  func testExecutionWriteBytesAndFileGrowthStayBoundedAcrossFiveHundredSaves() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let samples = PersistenceWriteSampleCollector()
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path) { samples.append($0) }
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    var executions: [WorkflowStepExecution] = []
    var fileSizes: [Int] = []

    for index in 1...500 {
      let date = createdAt.addingTimeInterval(TimeInterval(index))
      executions.append(WorkflowStepExecution(
        executionId: "execution-\(index)",
        stepId: "step-\(index)",
        nodeId: "node",
        attempt: 1,
        inputSnapshot: ["fixed": .string(String(repeating: "x", count: 768))],
        status: .completed,
        streamedResponseText: String(repeating: "y", count: 256),
        createdAt: date,
        updatedAt: date
      ))
      let session = WorkflowSession(
        workflowId: "bounded", sessionId: "bounded-session", status: .running,
        entryStepId: "step-1", currentStepId: "step-\(index)",
        createdAt: createdAt, updatedAt: date, executions: executions
      )
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
      if [50, 100, 450, 500].contains(index) { fileSizes.append(databaseBytes(root: root)) }
    }

    let writes = samples.values
    XCTAssertEqual(writes.count, 500)
    XCTAssertLessThanOrEqual(Double(writes[499].boundBytes), Double(writes[49].boundBytes) * 1.5)
    XCTAssertLessThanOrEqual(Double(writes[499].headerEncodeInputBytes), Double(writes[49].headerEncodeInputBytes) * 1.5)
    XCTAssertEqual(writes[49].sqliteFullScanSteps, 0)
    XCTAssertEqual(writes[499].sqliteFullScanSteps, 0)
    let earlyGrowth = fileSizes[1] - fileSizes[0]
    let lateGrowth = fileSizes[3] - fileSizes[2]
    XCTAssertGreaterThan(earlyGrowth, 0)
    XCTAssertLessThanOrEqual(Double(lateGrowth), Double(earlyGrowth) * 1.5)
  }

  func testPointGCWorkDoesNotGrowWithUnrelatedFamilyPayloads() throws {
    let controlRoot = temporaryDirectory()
    let seededRoot = temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: controlRoot)
      try? FileManager.default.removeItem(at: seededRoot)
    }
    let controlSamples = PersistenceWriteSampleCollector()
    let seededSamples = PersistenceWriteSampleCollector()
    let controlStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: controlRoot.path) { controlSamples.append($0) }
    let seededStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: seededRoot.path) { seededSamples.append($0) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let seededDB = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: seededRoot.path),
      mode: .readWriteCreate,
      options: .writableRuntimeStoreDefault
    )
    try seededStore.prepareSchema(in: seededDB)
    try seededDB.execute("""
      WITH RECURSIVE payloads(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM payloads WHERE i<20000)
      INSERT INTO workflow_runtime_payloads(root_session_id,digest,bytes,byte_count)
      SELECT 'large-family', 'unrelated-' || i, jsonb('{"value":' || i || '}'), 12 FROM payloads
      """)
    var executions: [WorkflowStepExecution] = []
    for index in 1...50 {
      let execution = WorkflowStepExecution(
        executionId: "step-attempt-1-exec-\(index)", stepId: "step", nodeId: "node", attempt: 1,
        inputSnapshot: [:], status: .completed, createdAt: date, updatedAt: date.addingTimeInterval(Double(index))
      )
      executions.append(execution)
      let session = WorkflowSession(
        workflowId: "large-family", sessionId: "large-family", status: .running,
        entryStepId: "step", createdAt: date, updatedAt: date.addingTimeInterval(Double(index)), executions: executions
      )
      let snapshot = WorkflowRuntimePersistenceSnapshot(session: session)
      try controlStore.save(snapshot)
      try seededStore.save(snapshot)
    }

    XCTAssertEqual(controlSamples.values.count, 50)
    XCTAssertEqual(seededSamples.values.count, 50)
    let controlVMSteps = controlSamples.values[49].sqliteVMSteps
    let seededVMSteps = seededSamples.values[49].sqliteVMSteps
    XCTAssertLessThanOrEqual(abs(seededVMSteps - controlVMSteps), max(controlVMSteps / 50, 10))
    XCTAssertEqual(controlSamples.values[49].sqliteFullScanSteps, 0)
    XCTAssertEqual(seededSamples.values[49].sqliteFullScanSteps, 0)
    XCTAssertEqual(
      try seededDB.query("SELECT COUNT(*) AS value FROM workflow_runtime_payloads WHERE root_session_id='large-family'").first?[
        "value"].flatMap(Int.init),
      20_050
    )
  }

  func testChildTerminalSavesDeferFamilyReleaseUntilRootTerminates() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let samples = PersistenceWriteSampleCollector()
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path) { samples.append($0) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let rootSession = WorkflowSession(
      workflowId: "family", sessionId: "root-session", status: .running,
      entryStepId: "root", createdAt: date, updatedAt: date
    )
    try store.save(WorkflowRuntimePersistenceSnapshot(session: rootSession))

    for index in 1...8 {
      var child = WorkflowSession(
        workflowId: "family", sessionId: "child-\(index)", status: .completed,
        entryStepId: "child", createdAt: date, updatedAt: date.addingTimeInterval(Double(index))
      )
      child.parentSessionId = "root-session"
      child.rootSessionId = "root-session"
      try store.save(WorkflowRuntimePersistenceSnapshot(session: child))
    }
    XCTAssertEqual(Array(samples.values.dropFirst()).map(\.familyReleaseScans), Array(repeating: 0, count: 8))

    var terminalRoot = rootSession
    terminalRoot.status = .completed
    terminalRoot.updatedAt = date.addingTimeInterval(9)
    try store.save(WorkflowRuntimePersistenceSnapshot(session: terminalRoot))
    XCTAssertEqual(samples.values.last?.familyReleaseScans, 1)
  }

  private func databaseBytes(root: URL) -> Int {
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    return [path, path + "-wal"].reduce(0) { total, value in
      let size = (try? FileManager.default.attributesOfItem(atPath: value)[.size] as? NSNumber)?.intValue ?? 0
      return total + size
    }
  }

  private func temporaryDirectory() -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/efficient-history/eh-05-session-rows/tests/\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private final class PersistenceWriteSampleCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [SQLiteWorkflowRuntimePersistenceStore.PersistenceWriteSample] = []

  var values: [SQLiteWorkflowRuntimePersistenceStore.PersistenceWriteSample] {
    lock.lock()
    defer { lock.unlock() }
    return samples
  }

  func append(_ sample: SQLiteWorkflowRuntimePersistenceStore.PersistenceWriteSample) {
    lock.lock()
    defer { lock.unlock() }
    samples.append(sample)
  }
}
