import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class CacheCommandTests: XCTestCase {
  private func root() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/cache-cli-tests/\(UUID().uuidString)")
  }
  func testHelpAndInvalidOperationsReturnExpectedExitCodes() throws {
    for arguments in [["--help"], ["configure", "--help"], ["put", "--help"], ["get", "--help"]] {
      let result = CacheCommandRunner().run(arguments)
      XCTAssertEqual(result.exitCode, .success)
      XCTAssertTrue(result.stdout.contains("riela cache"))
      XCTAssertTrue(result.stdout.contains("--entries-file"))
    }
    XCTAssertEqual(CacheCommandRunner().run(["unknown", "cache"]).exitCode, .usage)
    XCTAssertEqual(try RielaArgumentParser().parse(["cache", "get", "cache", "--scope", "s", "--key", "k"]),
      .cache(["get", "cache", "--scope", "s", "--key", "k"]))
  }
  func testFileBatchRoundTripPreservesPolicyAndReportsMiss() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func run(_ operation: String, _ arguments: [String] = []) throws -> CacheResult {
      let result = CacheCommandRunner().run([operation, "cache", "--cache-root", directory.path] + arguments)
      XCTAssertEqual(result.exitCode, .success, result.stdout)
      return try JSONDecoder().decode(CacheResult.self, from: Data(result.stdout.utf8))
    }
    _ = try run("configure", ["--ttl-seconds", "3600", "--max-bytes", "4096"])
    let file = directory.appendingPathComponent("input.json")
    let entry = CachePut(key: "post", fetchedAt: ISO8601DateFormatter().string(from: Date()), payload: .object(["text": .string("inspected")]), protectFromEviction: true)
    try JSONEncoder().encode([entry]).write(to: file)
    let saved = try run("put", ["--scope", "s", "--entries-file", file.path])
    XCTAssertEqual(saved.stats.policy.ttlSeconds, 3600)
    XCTAssertNil(saved.results[0].entry?.payload)
    XCTAssertEqual(saved.results[0].entry?.protectFromEviction, true)
    XCTAssertGreaterThan(saved.stats.protectedByteCount, 0)
    try JSONEncoder().encode([CacheProtection(key: "post", revision: saved.results[0].entry!.revision,
      protectFromEviction: false)]).write(to: file)
    let released = try run("protect", ["--scope", "s", "--entries-file", file.path])
    XCTAssertEqual(released.results[0].status, "released")
    XCTAssertEqual(released.stats.protectedByteCount, 0)
    XCTAssertEqual(released.stats.entryCount, 1)
    XCTAssertEqual(released.results[0].entry?.expiresAt, saved.results[0].entry?.expiresAt)
    try JSONEncoder().encode(["post", "missing"]).write(to: file)
    let loaded = try run("get", ["--scope", "s", "--keys-file", file.path])
    XCTAssertEqual(loaded.results.map(\.status), ["hit", "miss"])
    XCTAssertEqual(loaded.results[0].entry?.payload, entry.payload)
    let oversized = CacheCommandRunner().run(["get", "cache", "--cache-root", directory.path, "--scope", "s", "--key", "post", "--max-output-bytes", "1"])
    XCTAssertNotEqual(oversized.exitCode, .success)
    let removed = try run("delete", ["--scope", "s", "--key", "post", "--expected-revision", saved.results[0].entry!.revision])
    XCTAssertEqual(removed.deletedCount, 1)
  }
  func testBuiltinCacheAddonRoundTripAndPolicyValidation() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    func input(_ operation: BuiltinCacheAddon, _ extra: JSONObject = [:]) -> WorkflowAddonExecutionInput {
      let config: JSONObject = ["cacheId": .string("cache"), "cacheRoot": .string(directory.path)]
      return .init(workflowId: "workflow", stepId: "step", nodeId: "node",
        addon: .init(name: operation.rawValue, config: config.merging(extra) { _, new in new }), resolvedInputPayload: [:])
    }
    XCTAssertThrowsError(try resolver.executeCacheAddon(input(.configure, ["ttlSeconds": .number(1.5)]), operation: .configure))
    _ = try resolver.executeCacheAddon(input(.put, ["key": .string("post"),
      "fetchedAt": .string(ISO8601DateFormatter().string(from: Date())), "payload": .string("inspected")]), operation: .put)
    let result = try resolver.executeCacheAddon(input(.get, ["keys": .array([.string("post")])]), operation: .get)
    let decoded = try JSONDecoder().decode(CacheResult.self, from: JSONEncoder().encode(result.payload))
    XCTAssertEqual(decoded.results[0].entry?.payload, .string("inspected"))
    XCTAssertEqual(decoded.results[0].entry?.scope, "workflow")
  }
}
