import Foundation
import RielaCore
import RielaMemory
import RielaAddons
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
  func testBuiltinLifecycleAndMaintenanceUseNativeStore() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    func run(_ operation: BuiltinCacheAddon, _ extra: JSONObject) throws -> JSONObject {
      let config: JSONObject = ["cacheId": .string("cache"), "cacheRoot": .string(directory.path), "scope": .string("s")]
      let input = WorkflowAddonExecutionInput(workflowId: "workflow", stepId: "step", nodeId: "node",
        addon: .init(name: operation.rawValue, config: config.merging(extra) { _, new in new }), resolvedInputPayload: [:])
      return try resolver.executeCacheAddon(input, operation: operation).payload
    }
    _ = try run(.configure, ["maxBytes": .integer(1500)])
    let entry: JSONObject = ["key": .string("old"), "fetchedAt": .string(ISO8601DateFormatter().string(from: Date())),
      "payload": .string("checked"), "protectFromEviction": .bool(true)]
    let saved = try run(.put, ["entries": .array([.object(entry)])])
    XCTAssertThrowsError(try run(.reconcile, [:]))
    let retained = try run(.reconcile, ["references": .object(saved)])
    let decoded = try JSONDecoder().decode(CacheResult.self, from: JSONEncoder().encode(retained))
    XCTAssertGreaterThan(decoded.stats.protectedByteCount, 0)
    let released = try run(.reconcile, ["references": .array([])])
    XCTAssertEqual(try JSONDecoder().decode(CacheResult.self, from: JSONEncoder().encode(released)).stats.protectedByteCount, 0)
    let result = try run(.maintain, ["cacheIds": .array([.string("cache"), .string("missing")])])
    XCTAssertEqual(result["cacheCount"], .integer(1))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/cache-reconcile", version: "1"))
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

  // MARK: - Catalog parity

  func testCatalogCacheRowsAgreeWithValidatedFlags() throws {
    let rows = SurfaceCatalog.all.filter { $0.family == "cache" }
    XCTAssertEqual(Set(rows.map(\.id)), Set(CacheCommandRunner.operations.map { "cache.\($0)" }))
    XCTAssertEqual(Set(CacheCommandRunner.operationOptions.keys), Set(CacheCommandRunner.operations))
    for operation in CacheCommandRunner.operations {
      let row = try XCTUnwrap(rows.first { $0.id == "cache.\(operation)" }, operation)
      XCTAssertEqual(row.cli?.path, ["cache", operation])
      XCTAssertEqual(Set(row.cli?.options ?? []),
        CacheCommandRunner.commonOptions.union(CacheCommandRunner.operationOptions[operation] ?? []),
        "catalog row and validateFlags disagree for cache \(operation)")
    }
  }

  // MARK: - CLI maintain, keys, reservation and reference inputs

  private func cli(_ operation: String, _ directory: URL, _ arguments: [String]) -> CLICommandResult {
    CacheCommandRunner().run([operation] + arguments + ["--cache-root", directory.path])
  }

  private func scratch() throws -> URL {
    let directory = root()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func sortedJSON(_ stdout: String) throws -> String {
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(stdout.utf8))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (String(bytes: try encoder.encode(value), encoding: .utf8) ?? "") + "\n"
  }

  func testMaintainFailsOnFailedStoreAndAcceptsPositionalOrIdsFile() throws {
    let directory = try scratch()
    XCTAssertEqual(cli("configure", directory, ["good"]).exitCode, .success)
    try Data("corrupt store".utf8).write(to: directory.appendingPathComponent("bad.cache.sqlite"))
    let ids = directory.appendingPathComponent("ids.json")
    try JSONEncoder().encode(["good", "bad", "missing"]).write(to: ids)
    let failed = cli("maintain", directory, ["--cache-ids-file", ids.path])
    XCTAssertEqual(failed.exitCode, .failure, failed.stdout)
    let summary = try JSONDecoder().decode(CacheMaintenanceResult.self, from: Data(failed.stdout.utf8))
    XCTAssertEqual(summary.status, "failed")
    XCTAssertEqual(summary.failedCacheIds, ["bad"])
    XCTAssertEqual(summary.cacheCount, 1)
    XCTAssertEqual(summary.skippedCacheCount, 1)

    let single = cli("maintain", directory, ["good", "--max-duration-seconds", "0.5"])
    XCTAssertEqual(single.exitCode, .success, single.stdout)
    XCTAssertEqual(try JSONDecoder().decode(CacheMaintenanceResult.self, from: Data(single.stdout.utf8)).cacheCount, 1)
    // Stable output: keys are sorted, so consecutive runs print identical bytes.
    XCTAssertEqual(single.stdout, try sortedJSON(single.stdout))
    XCTAssertEqual(cli("maintain", directory, ["good"]).stdout, cli("maintain", directory, ["good"]).stdout)

    XCTAssertEqual(cli("maintain", directory, ["good", "--cache-ids-file", ids.path]).exitCode, .usage)
    XCTAssertEqual(cli("maintain", directory, []).exitCode, .usage)
    XCTAssertEqual(cli("maintain", directory, ["--keys-file", ids.path]).exitCode, .usage)
    XCTAssertEqual(cli("get", directory, ["--scope", "s", "--key", "k"]).exitCode, .usage, "other operations need <cache-id>")
  }

  func testKeysHonorsOutputFormat() throws {
    let directory = try scratch()
    let entries = directory.appendingPathComponent("entries.json")
    let now = ISO8601DateFormatter().string(from: Date())
    try JSONEncoder().encode([CachePut(key: "a", fetchedAt: now, payload: .string("1")),
      CachePut(key: "b", fetchedAt: now, payload: .string("2"))]).write(to: entries)
    XCTAssertEqual(cli("put", directory, ["cache", "--scope", "s", "--entries-file", entries.path]).exitCode, .success)
    let json = cli("keys", directory, ["cache", "--scope", "s"])
    XCTAssertEqual(json.exitCode, .success)
    XCTAssertEqual(Set(try JSONDecoder().decode([String].self, from: Data(json.stdout.utf8))), ["a", "b"])
    let lines = cli("keys", directory, ["cache", "--scope", "s", "--output", "jsonl"]).stdout
      .split(separator: "\n").map(String.init)
    XCTAssertEqual(Set(lines), [#""a""#, #""b""#])
    XCTAssertEqual(cli("keys", directory, ["cache", "--scope", "empty", "--output", "jsonl"]).stdout, "")
  }

  func testReservedBuiltinCacheIdsAreRejectedOnEveryCLIWritePath() throws {
    let directory = try scratch()
    let file = directory.appendingPathComponent("input.json")
    try Data("[]".utf8).write(to: file)
    let writes: [(String, [String])] = [
      ("configure", []), ("prune", []),
      ("put", ["--scope", "s", "--entries-file", file.path]),
      ("protect", ["--scope", "s", "--entries-file", file.path]),
      ("reconcile", ["--scope", "s", "--references-file", file.path]),
      ("delete", ["--scope", "s", "--entries-file", file.path])
    ]
    for (operation, arguments) in writes {
      for cacheId in ["x-gateway-users", "x-gateway-api-usage"] {
        let result = cli(operation, directory, [cacheId] + arguments)
        XCTAssertEqual(result.exitCode, .usage, "\(operation) \(cacheId)")
        XCTAssertTrue(result.stdout.contains("reserved for a built-in runtime cache"), result.stdout)
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("x-gateway-users.cache.sqlite").path))
    // Operators may still inspect the built-in caches.
    XCTAssertEqual(cli("keys", directory, ["x-gateway-users", "--scope", "users"]).exitCode, .success)
    XCTAssertEqual(cli("get", directory, ["x-gateway-users", "--scope", "users", "--key", "u"]).exitCode, .success)
  }

  func testPutRequestFileReferencesFileAndReconcileThroughCLI() throws {
    let directory = try scratch()
    func decoded(_ result: CLICommandResult) throws -> CacheResult {
      XCTAssertEqual(result.exitCode, .success, result.stdout)
      return try JSONDecoder().decode(CacheResult.self, from: Data(result.stdout.utf8))
    }
    let now = ISO8601DateFormatter().string(from: Date())
    let request = directory.appendingPathComponent("request.json")
    let first = CachePut(key: "first", fetchedAt: now, payload: .string("one"), protectFromEviction: true)
    try JSONSerialization.data(withJSONObject: [
      "entries": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))],
      "retainedReferences": [Any]()
    ]).write(to: request)
    let firstReceipt = try decoded(cli("put", directory, ["cache", "--scope", "s", "--request-file", request.path]))
    XCTAssertEqual(firstReceipt.results.map(\.status), ["stored"])
    XCTAssertEqual(cli("put", directory, ["cache", "--scope", "s", "--request-file", request.path, "--key", "k"]).exitCode,
      .usage, "--request-file is exclusive with put input flags")
    XCTAssertEqual(cli("put", directory, ["cache", "--scope", "s", "--request-file", request.path,
      "--references-file", request.path]).exitCode, .usage)

    // Second put retains the first receipt verbatim through --references-file.
    let references = directory.appendingPathComponent("references.json")
    try JSONEncoder().encode(firstReceipt).write(to: references)
    let entries = directory.appendingPathComponent("entries.json")
    try JSONEncoder().encode([CachePut(key: "second", fetchedAt: now, payload: .string("two"))]).write(to: entries)
    let secondReceipt = try decoded(cli("put", directory, ["cache", "--scope", "s", "--entries-file", entries.path,
      "--references-file", references.path]))
    XCTAssertEqual(secondReceipt.results.first?.entry?.protectFromEviction, false)
    XCTAssertEqual(secondReceipt.stats.protectedByteCount, firstReceipt.results[0].entry?.byteCount)

    // Reconcile to the second receipt plus a dangling reference: first is released,
    // second protected, and the dangling key is reported missing.
    let snapshot: JSONValue = .array([
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(secondReceipt)),
      .object(["key": .string("gone"), "revision": .string(String(repeating: "0", count: 64))])
    ])
    try JSONEncoder().encode(snapshot).write(to: references)
    let reconciled = try decoded(cli("reconcile", directory, ["cache", "--scope", "s", "--references-file", references.path]))
    XCTAssertEqual(reconciled.results.map(\.key), ["first", "second", "gone"])
    XCTAssertEqual(reconciled.results.map(\.status), ["released", "protected", "missing"])
    XCTAssertEqual(reconciled.stats.protectedByteCount, secondReceipt.results[0].entry?.byteCount)
    XCTAssertEqual(cli("reconcile", directory, ["cache", "--scope", "s"]).exitCode, .usage)
  }

  // MARK: - Add-on paths

  func testCacheAddonsRejectReservedIdsAndReportFailedMaintenance() throws {
    let directory = try scratch()
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    func run(_ operation: BuiltinCacheAddon, _ config: JSONObject) throws -> AdapterExecutionOutput {
      let base: JSONObject = ["cacheRoot": .string(directory.path), "scope": .string("s")]
      return try resolver.executeCacheAddon(.init(workflowId: "workflow", stepId: "step", nodeId: "node",
        addon: .init(name: operation.rawValue, config: base.merging(config) { _, new in new }), resolvedInputPayload: [:]),
        operation: operation)
    }
    let now = ISO8601DateFormatter().string(from: Date())
    let reserved: [(BuiltinCacheAddon, JSONObject)] = [
      (.configure, [:]), (.prune, [:]), (.get, ["key": .string("u")]),
      (.put, ["key": .string("u"), "fetchedAt": .string(now), "payload": .string("p")]),
      (.protect, ["entries": .array([])]), (.reconcile, ["references": .array([])]),
      (.delete, ["key": .string("u"), "expectedRevision": .string(String(repeating: "0", count: 64))])
    ]
    for (operation, config) in reserved {
      XCTAssertThrowsError(try run(operation, config.merging(["cacheId": .string("x-gateway-users")]) { _, new in new })) {
        XCTAssertEqual(($0 as? AdapterExecutionError)?.code, .policyBlocked, operation.rawValue)
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("x-gateway-users.cache.sqlite").path))

    // cache-put with retainedReferences, then cache-protect releases it explicitly.
    let entry: JSONObject = ["key": .string("a"), "fetchedAt": .string(now), "payload": .string("v"), "protectFromEviction": .bool(true)]
    let first = try run(.put, ["cacheId": .string("c"), "entries": .array([.object(entry)]), "retainedReferences": .array([])])
    let receipt = try JSONDecoder().decode(CacheResult.self, from: JSONEncoder().encode(first.payload))
    let revision = try XCTUnwrap(receipt.results.first?.entry?.revision)
    let second = try run(.put, ["cacheId": .string("c"), "key": .string("b"), "fetchedAt": .string(now),
      "payload": .string("w"), "retainedReferences": .object(first.payload)])
    XCTAssertEqual(try JSONDecoder().decode(CacheResult.self, from: JSONEncoder().encode(second.payload)).stats.protectedByteCount,
      receipt.results[0].entry?.byteCount)
    let released = try run(.protect, ["cacheId": .string("c"), "entries": .array([.object([
      "key": .string("a"), "revision": .string(revision), "protectFromEviction": .bool(false)])])])
    let releasedResult = try JSONDecoder().decode(CacheResult.self, from: JSONEncoder().encode(released.payload))
    XCTAssertEqual(releasedResult.results.map(\.status), ["released"])
    XCTAssertEqual(releasedResult.stats.protectedByteCount, 0)

    // Maintenance: fractional duration is accepted; a failed store fails the node.
    try Data("corrupt".utf8).write(to: directory.appendingPathComponent("bad.cache.sqlite"))
    let healthy = try run(.maintain, ["cacheIds": .array([.string("c")]), "maxDurationSeconds": .number(0.5)])
    XCTAssertTrue(healthy.completionPassed)
    let failed = try run(.maintain, ["cacheIds": .array([.string("c"), .string("bad")])])
    XCTAssertFalse(failed.completionPassed)
    XCTAssertEqual(failed.payload["status"], .string("failed"))
    XCTAssertEqual(failed.payload["failedCacheIds"], .array([.string("bad")]))
  }

  // MARK: - managed-cache-checkpoint example, run for real twice

  func testManagedCacheCheckpointExampleRunsTwiceCarryingReferences() async throws {
    let directory = try scratch()
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let cacheRoot = directory.appendingPathComponent("cache")
    func run(key: String, references: JSONValue) async throws -> CLICommandResult {
      let variables: JSONValue = .object([
        "cacheRoot": .string(cacheRoot.path), "key": .string(key),
        "fetchedAt": .string(ISO8601DateFormatter().string(from: Date())),
        "payload": .object(["checked": .bool(true)]), "references": references
      ])
      return await RielaCLIApplication().run([
        "workflow", "run", "managed-cache-checkpoint",
        "--workflow-definition-dir", repository.appendingPathComponent("examples").path,
        "--session-store", directory.appendingPathComponent("sessions-\(key)").path,
        "--variables", String(bytes: try JSONEncoder().encode(variables), encoding: .utf8) ?? "{}",
        "--output", "json"
      ])
    }
    let first = try await run(key: "checkpoint:1", references: .array([]))
    XCTAssertEqual(first.exitCode, .success, first.stdout + first.stderr)
    let store = RielaCacheStore(rootDirectory: cacheRoot.path)
    let firstEntry = try XCTUnwrap(store.get(cacheId: "managed-example", scope: "example", keys: ["checkpoint:1"],
      touch: false).results.first?.entry)
    XCTAssertEqual(firstEntry.protectFromEviction, true)
    // The next transition passes the committed receipt reference from the first run.
    let reference: JSONValue = .array([.object(["key": .string(firstEntry.key), "revision": .string(firstEntry.revision)])])
    let second = try await run(key: "checkpoint:2", references: reference)
    XCTAssertEqual(second.exitCode, .success, second.stdout + second.stderr)
    let both = try store.get(cacheId: "managed-example", scope: "example", keys: ["checkpoint:1", "checkpoint:2"], touch: false)
    XCTAssertEqual(both.results.map(\.status), ["hit", "hit"])
    XCTAssertEqual(both.results.map { $0.entry?.protectFromEviction }, [true, true])
    XCTAssertEqual(both.results[0].entry?.revision, firstEntry.revision)
    XCTAssertEqual(both.stats.protectedByteCount, both.stats.byteCount)
  }

  func testManagedCacheMaintenanceExampleSucceedsAndFailsOnCorruptStore() async throws {
    let directory = try scratch()
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let cacheRoot = directory.appendingPathComponent("cache")
    _ = try RielaCacheStore(rootDirectory: cacheRoot.path).configure(cacheId: "managed-example", policy: .init())
    func run(_ cacheIds: [String], _ name: String) async throws -> CLICommandResult {
      let variables: JSONValue = .object(["cacheRoot": .string(cacheRoot.path), "cacheIds": .array(cacheIds.map(JSONValue.string))])
      return await RielaCLIApplication().run([
        "workflow", "run", "managed-cache-maintenance",
        "--workflow-definition-dir", repository.appendingPathComponent("examples").path,
        "--session-store", directory.appendingPathComponent("sessions-\(name)").path,
        "--variables", String(bytes: try JSONEncoder().encode(variables), encoding: .utf8) ?? "{}",
        "--output", "json"
      ])
    }
    let healthy = try await run(["managed-example", "typo"], "healthy")
    XCTAssertEqual(healthy.exitCode, .success, healthy.stdout + healthy.stderr)
    try Data("corrupt".utf8).write(to: cacheRoot.appendingPathComponent("broken.cache.sqlite"))
    let failed = try await run(["managed-example", "broken"], "failed")
    XCTAssertNotEqual(failed.exitCode, .success, "a failed store must fail the maintenance workflow: \(failed.stdout)")
  }
}
