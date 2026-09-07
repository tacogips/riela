import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

final class SpecialistWrikeRecoveryTests: XCTestCase {
  func testLostOwnershipResponseRecoversTrackerMappingWithoutSecondWrite() async throws {
    let store = try makeStore()
    let gateway = RecoveryGateway(result: .delivered("remote-task"))
    let worker = SpecialistOutboxDeliveryWorker(store: store, matrix: nil, matrixRoomID: nil,
                                               wrike: SpecialistWrikeDeliveryAdapter(gateway: gateway))
    let receipts = await worker.deliverPending()
    XCTAssertEqual(receipts.first { $0.destination == "tracker" }?.state, .delivered)
    XCTAssertEqual(try store.trackerTaskId(taskId: "task"), "remote-task",
                   "Recovered creates must bind later lifecycle updates to the recovered task")
    _ = await worker.deliverPending()
    let writes = await gateway.writes
    XCTAssertEqual(writes, 1, "Receipt recovery must never issue a replacement create")
  }

  func testNegativeAndConflictingLookupsDoNotAuthorizeAnotherWrite() async throws {
    for result: SpecialistWrikeReconciliation in [.notFound, .conflicting] {
      let store = try makeStore()
      let gateway = RecoveryGateway(result: result)
      let worker = SpecialistOutboxDeliveryWorker(store: store, matrix: nil, matrixRoomID: nil,
                                                 wrike: SpecialistWrikeDeliveryAdapter(gateway: gateway))
      let receipts = await worker.deliverPending()
      XCTAssertEqual(receipts.first { $0.destination == "tracker" }?.state, .uncertain)
      _ = await worker.deliverPending()
      let writes = await gateway.writes
      XCTAssertEqual(writes, 1)
      XCTAssertNil(try store.trackerTaskId(taskId: "task"))
    }
  }

  private func makeStore() throws -> SpecialistSupervisorStore {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/wrike-recovery-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let request = SpecialistRequest(requestId: "request", sourceEventId: "source",
                                    principal: .init(accountId: "account", actorId: "actor", roomId: "room"),
                                    route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task"))
    _ = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    return store
  }
}

private actor RecoveryGateway: SpecialistWrikeGateway {
  let result: SpecialistWrikeReconciliation
  var writes = 0

  init(result: SpecialistWrikeReconciliation) { self.result = result }

  func deliver(_: SpecialistOutboxEvent, trackerTaskId _: String?) async throws -> String {
    writes += 1
    throw SpecialistRemoteDeliveryError.uncertain
  }

  func reconcile(_: SpecialistOutboxEvent, trackerTaskId _: String?) async throws -> SpecialistWrikeReconciliation {
    result
  }
}
