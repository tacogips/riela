import Foundation
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
    let earlyGrowth = fileSizes[1] - fileSizes[0]
    let lateGrowth = fileSizes[3] - fileSizes[2]
    XCTAssertGreaterThan(earlyGrowth, 0)
    XCTAssertLessThanOrEqual(Double(lateGrowth), Double(earlyGrowth) * 1.5)
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
