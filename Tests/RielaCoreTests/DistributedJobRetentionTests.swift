import Foundation
@testable import RielaCore
import XCTest

final class DistributedJobRetentionTests: XCTestCase {
  func testCompactionPreservesLookupAndCompletionReplay() async throws {
    let url = try storeURL()
    var limits = DistributedStoreLimits()
    limits.retainedTerminalJobs = 1
    let controller = try DistributedJobController(fileURL: url, limits: limits)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    let result = DistributedJobResult(outcome: .succeeded, payload: ["text": .string(String(repeating: "r", count: 10_000))])
    var firstLease: String?
    for index in 0..<8 {
      _ = try await controller.enqueue(id: "job-\(index)", target: .init(), payload: ["input": .string("original")])
      let claimed = try await controller.claim(worker: worker, now: Date(), leaseDuration: 10)
      let job = try XCTUnwrap(claimed)
      if index == 0 { firstLease = job.lease?.token }
      _ = try await controller.complete(jobId: job.id, worker: worker, token: XCTUnwrap(job.lease?.token), result: result, now: Date())
    }
    let compact = try await controller.jobs(now: Date())
    XCTAssertEqual(compact.filter { $0.archived == true }.count, 7)
    XCTAssertLessThan(try Data(contentsOf: url).count, 30_000)
    let reopened = try DistributedJobController(fileURL: url, limits: limits)
    let restored = try await reopened.job(id: "job-0", now: Date())
    XCTAssertEqual(restored?.result, result)
    XCTAssertEqual(restored?.payload, ["input": .string("original")])
    let replay = try await reopened.complete(jobId: "job-0", worker: worker, token: XCTUnwrap(firstLease), result: result, now: Date())
    XCTAssertEqual(replay.result, result)
    do {
      _ = try await reopened.complete(jobId: "job-0", worker: worker, token: XCTUnwrap(firstLease),
        result: .init(outcome: .succeeded, payload: [:]), now: Date())
      XCTFail("Conflicting archived completion accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .conflictingResult) }
    let same = try await reopened.enqueue(id: "job-0", target: .init(), payload: ["input": .string("original")])
    XCTAssertEqual(same.status, .succeeded, "Compacted job IDs must never replay work")
  }

  func testAdmissionLimitsReserveSpaceAndAllowExistingWorkToFinish() async throws {
    let url = try storeURL()
    var limits = DistributedStoreLimits()
    limits.maximumJobs = 2
    limits.maximumActiveJobs = 1
    limits.retainedTerminalJobs = 0
    let controller = try DistributedJobController(fileURL: url, limits: limits)
    _ = try await controller.enqueue(id: "first", target: .init(), payload: [:])
    await assertCapacityExceeded(controller, id: "second")
    try await controller.cancel(jobId: "first")
    _ = try await controller.enqueue(id: "second", target: .init(), payload: [:])
    try await controller.cancel(jobId: "second")
    await assertCapacityExceeded(controller, id: "third")
    let jobs = try await controller.jobs(now: Date())
    XCTAssertEqual(jobs.map(\.status), [.cancelled, .cancelled])

    let budgetURL = try storeURL()
    limits.maximumArchiveBytes = limits.maximumJobBytes
    let budgeted = try DistributedJobController(fileURL: budgetURL, limits: limits)
    _ = try await budgeted.enqueue(id: "reserved", target: .init(), payload: [:])
    try await budgeted.cancel(jobId: "reserved")
    await assertCapacityExceeded(budgeted, id: "over-budget")
  }

  func testArchivedArtifactsCanBeRestoredAfterRestart() async throws {
    let url = try storeURL()
    var limits = DistributedStoreLimits()
    limits.retainedTerminalJobs = 0
    let controller = try DistributedJobController(fileURL: url, limits: limits)
    let request = DistributedNodeRequest(invocation: .adapter(.init(node: .init(id: "node", model: "local"), promptText: "report")),
      workspace: "project", timeoutSeconds: 10, exports: ["report.txt"])
    _ = try await controller.enqueueNode(id: "report", target: .init(), request: request)
    let worker = try await controller.register(workerId: "worker", groups: [], capacity: 1)
    let claimed = try await controller.claim(worker: worker, now: Date(), leaseDuration: 10)
    let job = try XCTUnwrap(claimed)
    let bytes = Data("archived report".utf8)
    _ = try await controller.complete(jobId: job.id, worker: worker, token: XCTUnwrap(job.lease?.token),
      result: .init(outcome: .succeeded, payload: [:], artifacts: [.init(path: "report.txt", data: bytes)]), now: Date())
    let locations = try await controller.artifacts(jobId: job.id)
    let location = try XCTUnwrap(locations.first)
    try FileManager.default.removeItem(at: location.url)
    let reopened = try DistributedJobController(fileURL: url, limits: limits)
    let restored = try await reopened.artifacts(jobId: job.id)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.first?.url)), bytes)
  }

  func testOversizedSnapshotIsRejectedBeforeJSONDecoding() throws {
    let url = try storeURL()
    var limits = DistributedStoreLimits()
    limits.maximumSnapshotBytes = 64
    try Data(repeating: 0, count: 65).write(to: url)
    XCTAssertThrowsError(try DistributedJobController(fileURL: url, limits: limits)) {
      XCTAssertEqual($0 as? DistributedWorkerError, .storeCapacityExceeded)
    }
  }

  private func assertCapacityExceeded(_ controller: DistributedJobController, id: String) async {
    do {
      _ = try await controller.enqueue(id: id, target: .init(), payload: [:])
      XCTFail("Admission exceeded the store quota")
    } catch { XCTAssertEqual(error as? DistributedWorkerError, .storeCapacityExceeded) }
  }

  private func storeURL() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/distributed-workers/retention-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root.appendingPathComponent("jobs.json")
  }
}
