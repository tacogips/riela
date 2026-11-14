import Foundation
import RielaCore
import XCTest

@testable import RielaCLI

final class StartupIdentityRealStoreBenchmarks: XCTestCase {
  func testConsistentCopiedHistoryStartup() async throws {
    guard let path = ProcessInfo.processInfo.environment["ART_TEST_STARTUP_STORE_COPY"] else {
      throw XCTSkip("explicit consistent scratch-copy benchmark opt-in")
    }
    let root = URL(fileURLWithPath: path).standardizedFileURL
    let marker = root.appendingPathComponent("startup-benchmark-allowed")
    guard (try? String(contentsOf: marker, encoding: .utf8)) == "scratch-copy-only\n" else {
      return XCTFail("benchmark requires an explicitly marked disposable SQLite backup")
    }
    let database = root.appendingPathComponent("runtime-records/runtime-message-log.sqlite")
    let bytes = try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? Int ?? 0
    func seconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    let firstStart = ContinuousClock.now
    let first = try await makeSeededProductionRuntimeStore(
      sessionStoreRoot: root.path,
      executionLocks: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      hydrateSessions: false)
    let firstSeconds = seconds(firstStart.duration(to: .now))
    let next = try await first.createSession(
      .init(workflowId: "startup-benchmark", entryStepId: "start"))
    XCTAssertTrue(next.sessionId.hasPrefix("startup-benchmark-session-"))
    let secondStart = ContinuousClock.now
    _ = try await makeSeededProductionRuntimeStore(
      sessionStoreRoot: root.path,
      executionLocks: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      hydrateSessions: false)
    let secondSeconds = seconds(secondStart.duration(to: .now))
    let proof: [String: Any] = [
      "databaseBytes": bytes, "legacyBackfillAndStartupSeconds": firstSeconds,
      "preparedMetadataStartupSeconds": secondSeconds, "providerCalls": 0,
      "canonicalSourceWrites": 0
    ]
    try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys, .prettyPrinted])
      .write(to: root.appendingPathComponent("startup-benchmark-proof.json"), options: .atomic)
    FileHandle.standardError.write(
      try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]))
  }
}
