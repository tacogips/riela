import Foundation
import XCTest
import RielaSQLite
@testable import RielaCLI

final class TerminalRetentionRealStoreBenchmarks: XCTestCase {
  func testExplicitDisposableCopyIndexMigration() throws {
    guard let path = ProcessInfo.processInfo.environment["RIELA_TEST_RETENTION_STORE_COPY"] else {
      throw XCTSkip("Opt in only with an explicitly marked disposable production-store copy")
    }
    let root = URL(fileURLWithPath: path).standardizedFileURL
    guard root == root.resolvingSymlinksInPath(), root.pathComponents.contains("tmp"),
      root.deletingLastPathComponent().lastPathComponent == "retention-performance-evidence",
      try String(contentsOf: root.appendingPathComponent("retention-benchmark-allowed"), encoding: .utf8)
        == "disposable-retention-copy-only\n" else {
      return XCTFail("Refusing an unmarked or aliased runtime-store path")
    }
    let database = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.appendingPathComponent("sessions").path)
    let db = try SQLiteDatabase.open(path: database)
    let before = try TerminalRetentionMetadata.sessions(db)
    let started = Date()
    try TerminalRetentionIndexes.prepare(db)
    let migrationSeconds = Date().timeIntervalSince(started)
    let readStarted = Date()
    let after = try TerminalRetentionMetadata.sessions(db)
    let metadataSeconds = Date().timeIntervalSince(readStarted)
    XCTAssertEqual(after, before)
    let result: [String: Any] = ["index_migration_seconds": migrationSeconds,
      "indexed_metadata_seconds": metadataSeconds, "session_count": after.count,
      "metadata_exact_parity": after == before, "canonical_writes": 0]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appendingPathComponent("index-migration-proof.json"), options: .atomic)
  }
}
