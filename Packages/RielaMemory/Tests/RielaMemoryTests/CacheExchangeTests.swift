import Foundation
import SQLite3
import XCTest
@testable import RielaMemory

final class CacheExchangeTests: XCTestCase {
  func testLegacyDomainHashStillRequiresCryptographicallyMatchingStoredRevision() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaCacheStore(rootDirectory: root.path)
    let exchange = try RielaCacheExchange(store: store, cacheId: "bodies", scope: "account")
    var ref = try exchange.put([entry("one")])["one"]!
    ref.hashFormat = nil; ref.payloadSHA256 = String(repeating: "a", count: 64)
    // Domain serialization is intentionally not interpreted by the native cache.
    // Its original proof is checked by the domain adapter after this read.
    XCTAssertEqual(try exchange.get([ref]).hits["one"], .string("checked"))
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(try store.databasePath(cacheId: "bodies"), &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, "UPDATE cache_entries SET payload_json = '\"tampered\"'", nil, nil, nil), SQLITE_OK)
    XCTAssertEqual(try exchange.get([ref]).missing, ["one"])
  }

  func testExpiredReadDoesNotRefreshTTLAndNextReadIsMissing() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let clock = ExchangeTestClock()
    let store = RielaCacheStore(rootDirectory: root.path, clock: { clock.now() })
    let exchange = try RielaCacheExchange(store: store, cacheId: "bodies", scope: "account", policy: .init(ttlSeconds: 1))
    let item = CachePut(key: "one", fetchedAt: ISO8601DateFormatter().string(from: clock.now()), payload: .string("checked"))
    let ref = try exchange.put([item])["one"]!
    clock.advance()
    XCTAssertEqual(try exchange.get([ref]).expired, ["one"])
    XCTAssertEqual(try exchange.get([ref]).missing, ["one"])
  }

  func testUnprotectedBatchesLargerThanCapacityRemainRecoverable() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try RielaCacheExchange(store: .init(rootDirectory: root.path), cacheId: "bodies", scope: "account",
      policy: .init(maxBytes: 1500))
    let refs = try exchange.put([entry("old"), entry("recent"), entry("new")])
    XCTAssertEqual(refs.count, 3)
    let found = try exchange.get([refs["old"]!, refs["recent"]!, refs["new"]!])
    XCTAssertEqual(found.missing, ["old"])
    XCTAssertEqual(Set(found.hits.keys), ["recent", "new"])
    XCTAssertEqual(try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount, 0)
    // Losing the oldest body cannot make a release operation stop later work.
    try exchange.protect(Array(refs.values), enabled: true)
    XCTAssertEqual(try exchange.store.prune(cacheId: "bodies").stats.protectedByteCount, 0)
  }

  func testOverwriteAndPayloadProofMismatchAreMissesWithoutRenewingFetchTime() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try RielaCacheExchange(store: .init(rootDirectory: root.path), cacheId: "bodies", scope: "account")
    let saved = try exchange.put([entry("one")])["one"]!
    var changed = saved; changed.payloadSHA256 = String(repeating: "0", count: 64)
    XCTAssertEqual(try exchange.get([changed]).missing, ["one"])
    let original = try exchange.store.get(cacheId: "bodies", scope: "account", keys: ["one"]).results[0].entry!
    XCTAssertEqual(original.fetchedAt, saved.fetchedAt)
    _ = try exchange.store.put(cacheId: "bodies", scope: "account", entries: [entry("one", text: "changed")])
    XCTAssertEqual(try exchange.get([saved]).missing, ["one"])
  }

  func testLegacyUTF8ReferenceAndLiteralTemplateTextRoundTrip() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try RielaCacheExchange(store: .init(rootDirectory: root.path), cacheId: "bodies", scope: "account")
    let payload: MemoryJSONValue = .object(["text": .string("日本語 {{literal}} https://example.com/x"), "count": .number(3)])
    let put = CachePut(key: "one", fetchedAt: timestamp(), payload: payload)
    var ref = try exchange.put([put])["one"]!
    // hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True,
    // separators=(',', ':')).encode()).hexdigest(), recorded golden value.
    XCTAssertEqual(ref.payloadSHA256, "bf2cd6e7101f23870113b089ac6a7f9d1e76a096a6def51a6583a3933ea4ef71")
    ref.hashFormat = nil
    XCTAssertEqual(try exchange.get([ref]).hits["one"], payload)
    var domainRef = ref; domainRef.integritySHA256 = ref.payloadSHA256
    domainRef.payloadSHA256 = String(repeating: "a", count: 64)
    XCTAssertEqual(try exchange.get([domainRef]).hits["one"], payload)
  }

  func testInvalidLaterItemCannotPartiallyWriteEarlierBatch() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try RielaCacheExchange(store: .init(rootDirectory: root.path), cacheId: "bodies", scope: "account",
      policy: .init(maxBytes: 1000))
    var invalid = entry("later"); invalid.fetchedAt = "2099-01-01T00:00:00Z"
    XCTAssertThrowsError(try exchange.put([entry("first"), invalid]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: try exchange.store.databasePath(cacheId: "bodies")))
    XCTAssertThrowsError(try exchange.put([entry("repeat"), entry("repeat")]))
    XCTAssertThrowsError(try RielaCacheExchange(store: exchange.store, cacheId: "x-gateway-users", scope: "account"))
  }

  func testMoreThanNativeBatchLimitAndProtectedStaging() throws {
    let root = scratch(); defer { try? FileManager.default.removeItem(at: root) }
    let exchange = try RielaCacheExchange(store: .init(rootDirectory: root.path), cacheId: "staging", scope: "account",
      policy: .init(maxBytes: 2_000_000), capacityProtection: true)
    let refs = try exchange.put((0..<1025).map { entry(String($0)) }, retaining: .array([]))
    XCTAssertEqual(try exchange.get(Array(refs.values)).hits.count, 1025)
    XCTAssertGreaterThan(try exchange.store.prune(cacheId: "staging").stats.protectedByteCount, 1024 * 512)
    try exchange.protect(Array(refs.values), enabled: false)
    XCTAssertEqual(try exchange.store.prune(cacheId: "staging").stats.protectedByteCount, 0)
  }

  private func scratch() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
  private func timestamp() -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10)) }
  private func entry(_ key: String, text: String = "checked") -> CachePut {
    .init(key: key, fetchedAt: timestamp(), payload: .string(text), protectFromEviction: true)
  }
}

private final class ExchangeTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_760_000_000)
  func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
  func advance() { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(2) }
}
