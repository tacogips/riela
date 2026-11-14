import Foundation
import XCTest
@testable import RielaServer

@MainActor
final class RielaAPIKeyStoreTests: XCTestCase {
  func testDurabilityHashOnlyAndOwnerPermissions() throws {
    let store = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let issued = try store.issue(name: "Integration")
    XCTAssertEqual(issued.token.count, 49)
    let restarted = RielaAPIKeyStore(root: store.root)
    XCTAssertEqual(try restarted.list(), [issued.record])
    XCTAssertEqual(try restarted.authenticate(issued.token, purpose: .client), issued.record)
    let file = store.root.appendingPathComponent("api-keys.json")
    let persisted = try String(contentsOf: file, encoding: .utf8)
    XCTAssertFalse(persisted.contains(issued.token))
    XCTAssertFalse(persisted.contains(String(issued.token.dropFirst(6))))
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
  }

  func testPurposeWorkerBindingRevocationAndExpiry() throws {
    let store = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let client = try store.issue(name: "Client", expiresAt: now.addingTimeInterval(60), now: now)
    let worker = try store.issue(name: "Worker", purpose: .worker, workerID: "worker-1",
                                 expiresAt: now.addingTimeInterval(60), now: now)
    XCTAssertNil(try store.authenticate(client.token, purpose: .worker, workerID: "worker-1", now: now))
    XCTAssertNil(try store.authenticate(worker.token, purpose: .client, now: now))
    XCTAssertNil(try store.authenticate(worker.token, purpose: .worker, workerID: "worker-2", now: now))
    XCTAssertEqual(try store.authenticate(worker.token, purpose: .worker, now: now)?.workerID, "worker-1")
    XCTAssertEqual(try store.authenticate(worker.token, purpose: .worker, workerID: "worker-1", now: now), worker.record)
    XCTAssertNil(try store.authenticate(client.token, purpose: .client, now: now.addingTimeInterval(60)))
    XCTAssertNil(try store.authenticate(worker.token, purpose: .worker, workerID: "worker-1",
                                        now: now.addingTimeInterval(60)))
    let otherProcess = RielaAPIKeyStore(root: store.root)
    try otherProcess.revoke(id: worker.record.id, now: now)
    XCTAssertNil(try store.authenticate(worker.token, purpose: .worker, workerID: "worker-1", now: now))
    XCTAssertNotNil(try store.list().first { $0.id == worker.record.id }?.revokedAt)
  }

  func testClientPolicyReloadAndCorruptionFailClosed() throws {
    let store = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    XCTAssertTrue(try store.requireClientKey())
    XCTAssertFalse(try store.authorizeClient(token: nil))
    let otherProcess = RielaAPIKeyStore(root: store.root)
    try otherProcess.setRequireClientKey(false)
    XCTAssertTrue(try store.authorizeClient(token: nil))
    XCTAssertFalse(try store.authorizeClient(token: "invalid"))
    XCTAssertNil(try store.authenticate("invalid", purpose: .worker, workerID: "worker"))
    try otherProcess.setRequireClientKey(true)
    XCTAssertFalse(try store.authorizeClient(token: nil))
    try Data("{}".utf8).write(to: store.root.appendingPathComponent("api-keys.json"))
    XCTAssertThrowsError(try store.authorizeClient(token: nil))
    XCTAssertThrowsError(try store.issue(name: "Must not overwrite corrupt store"))
  }

  func testConcurrentMutationsRetainAllIssuedKeys() async throws {
    let store = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let count = 20
    let records = try await withThrowingTaskGroup(of: RielaAPIKeyStore.IssuedKey.self) { group in
      for index in 0..<count {
        group.addTask { try RielaAPIKeyStore(root: store.root).issue(name: "Client \(index)") }
      }
      var records: [RielaAPIKeyStore.IssuedKey] = []
      for try await key in group { records.append(key) }
      return records
    }
    XCTAssertEqual(try store.list().count, count)
    for issued in records {
      XCTAssertEqual(try store.authenticate(issued.token, purpose: .client), issued.record)
    }
    XCTAssertEqual(Set(records.map(\.token)).count, count)
  }

  func testSymlinkedStoreFailsClosed() throws {
    let store = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let issued = try store.issue(name: "Client")
    let file = store.root.appendingPathComponent("api-keys.json")
    let destination = store.root.appendingPathComponent("saved.json")
    try FileManager.default.moveItem(at: file, to: destination)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: destination)
    XCTAssertThrowsError(try store.authenticate(issued.token, purpose: .client))
    XCTAssertThrowsError(try store.setRequireClientKey(false))
  }

  func testInvalidPurposeBindingsRejected() throws {
    let store = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    XCTAssertThrowsError(try store.issue(name: "Worker", purpose: .worker))
    XCTAssertThrowsError(try store.issue(name: "Worker", purpose: .worker, workerID: ""))
    XCTAssertThrowsError(try store.issue(name: "Client", purpose: .client, workerID: "worker"))
    XCTAssertThrowsError(try store.issue(name: " "))
    XCTAssertThrowsError(try store.issue(name: "Expired", expiresAt: .distantPast))
  }

  private func fixture() throws -> RielaAPIKeyStore {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/api-key-store-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return RielaAPIKeyStore(root: root)
  }
}
