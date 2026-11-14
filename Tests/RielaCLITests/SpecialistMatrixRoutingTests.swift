import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

final class SpecialistMatrixRoutingTests: XCTestCase {
  func testIntakeIgnoresUnconfiguredJoinedRoom() async throws {
    let response = #"""
    {"next_batch":"next","rooms":{"join":{
      "!allowed":{"timeline":{"events":[{"type":"m.room.message","event_id":"$a","sender":"@user","content":{"body":"allowed"}}]}},
      "!private":{"timeline":{"events":[{"type":"m.room.message","event_id":"$b","sender":"@user","content":{"body":"private"}}]}}
    }}}
    """#
    let transport = MatrixRoutingTransport(response: response)
    let intake = SpecialistMatrixIntakeAdapter(homeserver: try endpoint(), accessToken: "fixture", accountId: "account",
                                               localUserId: "@bot", transport: transport, allowedRoomIDs: ["!allowed"])
    let page = try await intake.poll()
    XCTAssertEqual(page.events.map(\.sourceEventId), ["$a"])
  }

  func testReplyPreservesPersistedThread() async throws {
    let transport = MatrixRoutingTransport(response: #"{"event_id":"$receipt"}"#)
    let adapter = SpecialistMatrixDeliveryAdapter(homeserver: try endpoint(), accessToken: "fixture", transport: transport)
    let event = SpecialistOutboxEvent(eventId: "outbox", destination: "chat", operation: "status", payload: "running", sequence: 1,
                                      recipient: .init(accountId: "account", actorId: "@user", roomId: "!allowed", threadId: "$thread"))
    _ = try await adapter.deliver(event, roomId: "!allowed")
    let captured = await transport.lastBody()
    let body = try XCTUnwrap(captured)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let relation = try XCTUnwrap(json["m.relates_to"] as? [String: String])
    XCTAssertEqual(relation, ["rel_type": "m.thread", "event_id": "$thread"])
  }

  func testWorkerNeverSendsTaskToDifferentConfiguredRoomOrAccount() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/matrix-routing-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    for (index, principal) in [
      SpecialistPrincipal(accountId: "account", actorId: "actor", roomId: "!private"),
      SpecialistPrincipal(accountId: "other-account", actorId: "actor", roomId: "!allowed")
    ].enumerated() {
      let request = SpecialistRequest(requestId: "request-\(index)", sourceEventId: "event-\(index)",
                                      principal: principal, route: .work, body: "private task")
      let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task-\(index)"))
      _ = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 2, expectedVersion: task.version, destinations: ["chat"])
    }
    let transport = MatrixRoutingTransport(response: #"{"event_id":"$receipt"}"#)
    let matrix = SpecialistMatrixDeliveryAdapter(homeserver: try endpoint(), accessToken: "fixture", transport: transport)
    let worker = SpecialistOutboxDeliveryWorker(store: store, matrix: matrix, matrixRoomID: "!allowed", wrike: nil, matrixAccountID: "account")
    let receipts = await worker.deliverPending()
    XCTAssertEqual(receipts.count, 2)
    XCTAssertTrue(receipts.allSatisfy { $0.state == .permanentFailure })
    let lastBody = await transport.lastBody()
    XCTAssertNil(lastBody, "A recipient mismatch must fail before sending private task text")
  }

  private func endpoint() throws -> URL { try XCTUnwrap(URL(string: "https://matrix.invalid")) }
}

private actor MatrixRoutingTransport: SpecialistHTTPTransport {
  let response: String
  var bodies: [Data] = []
  init(response: String) { self.response = response }
  func lastBody() -> Data? { bodies.last }
  func send(url _: URL, method _: String, headers _: [String: String], body: Data) async throws -> (status: Int, body: Data) {
    bodies.append(body)
    return (200, Data(response.utf8))
  }
}
