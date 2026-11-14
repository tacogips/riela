import Foundation
import RielaCore
@testable import RielaServer
import XCTest

final class DistributedConfigurationTransactionTests: XCTestCase {
  func testConfigurationReplacementFencesPreviouslyLoadedClients() async throws {
    let url = try configurationURL()
    let original = try DistributedControllerConfiguration.load(from: url)
    let client = try original.controller(relativeTo: url)
    var updated = original
    updated.storePath = "replacement.json"
    try await updated.saveIfIdle(replacing: original, at: url)
    let lateClient = try original.controller(relativeTo: url)
    for stale in [client, lateClient] {
      do {
        _ = try await stale.enqueue(id: "stale", target: .init(), payload: [:])
        XCTFail("Previously loaded configuration must not enqueue after replacement")
      } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleControllerConfiguration) }
    }
    let current = try updated.controller(relativeTo: url)
    _ = try await current.enqueue(id: "current", target: .init(), payload: [:])
    let jobs = try await current.jobs(now: Date())
    XCTAssertEqual(jobs.map(\.id), ["current"])
  }

  func testConcurrentEnqueueAndSaveCannotStrandWork() async throws {
    for _ in 0..<8 {
      let url = try configurationURL()
      let original = try DistributedControllerConfiguration.load(from: url)
      let client = try original.controller(relativeTo: url)
      var changed = original
      changed.storePath = "replacement.json"
      let updated = changed
      let enqueue = Task {
        do {
          _ = try await client.enqueue(id: "race", target: .init(), payload: [:])
          return true
        } catch { XCTAssertEqual(error as? DistributedWorkerError, .staleControllerConfiguration); return false }
      }
      let save = Task {
        do {
          try await updated.saveIfIdle(replacing: original, at: url)
          return true
        } catch { XCTAssertEqual(error as? DistributedWorkerError, .controllerBusy); return false }
      }
      let enqueued = await enqueue.value
      let saved = await save.value
      XCTAssertNotEqual(enqueued, saved, "Exactly one side of the transaction must win")
      let persisted = try DistributedControllerConfiguration.load(from: url)
      XCTAssertEqual(persisted, saved ? updated : original)
      let oldStore = try DistributedJobController(fileURL: url.deletingLastPathComponent().appendingPathComponent("jobs.json"))
      let jobs = try await oldStore.jobs(now: Date())
      XCTAssertEqual(jobs.count, enqueued ? 1 : 0)
    }
  }

  private func configurationURL() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/distributed-workers/config-transactions/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("controller.json")
    let configuration = DistributedControllerConfiguration(host: "127.0.0.1", port: 8788, storePath: "jobs.json", workers: [
      .init(id: "one", groups: [], tokenEnvironment: "WORKER_TOKEN", maxCapacity: 1)
    ])
    try JSONEncoder().encode(configuration).write(to: url)
    return url
  }
}
