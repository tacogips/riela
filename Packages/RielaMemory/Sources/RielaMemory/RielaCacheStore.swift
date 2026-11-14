import Crypto
import Foundation
import SQLite3

/// Disposable inspected retrieval data only. Never shares durable memory tables.
public struct RielaCacheStore: Sendable {
  public static let maximumFrameBytes = 67_108_864
  public let rootDirectory: String
  private let clock: @Sendable () -> Date

  public init(rootDirectory: String, clock: @escaping @Sendable () -> Date = { Date() }) {
    self.rootDirectory = rootDirectory
    self.clock = clock
  }

  public static func defaultRootDirectory(workingDirectory: String = FileManager.default.currentDirectoryPath) -> String {
    URL(fileURLWithPath: workingDirectory).appendingPathComponent(".riela/cache").path
  }

  public func databasePath(cacheId: String) throws -> String {
    guard cacheId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
      throw RielaCacheError.invalid("invalid cache id")
    }
    return URL(fileURLWithPath: rootDirectory).appendingPathComponent("\(cacheId).cache.sqlite").path
  }

  public func configure(cacheId: String, policy: CachePolicy) throws -> CacheResult {
    try policy.validate()
    return try transaction(cacheId) { db, now in
      let old = try readPolicy(db)
      let expired = try expire(db, now: now, policy: old)
      try execute(db, "UPDATE cache_policy SET ttl_seconds = ?, max_bytes = ? WHERE id = 1",
        bindings: [.int(policy.ttlSeconds), .int(policy.maxBytes)])
      let additionallyExpired = try expire(db, now: now, policy: policy)
      let evicted = try evict(db, policy: policy)
      return try result(db, policy: policy, expired: expired + additionallyExpired, evicted: evicted)
    }
  }

  public func prune(cacheId: String) throws -> CacheResult {
    try transaction(cacheId) { db, now in
      let policy = try readPolicy(db)
      let expired = try expire(db, now: now, policy: policy)
      return try result(db, policy: policy, expired: expired, evicted: evict(db, policy: policy))
    }
  }

  public func put(cacheId: String, scope: String, entries: [CachePut]) throws -> CacheResult {
    try validate(scope: scope, keys: entries.map(\.key))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try transaction(cacheId) { db, now in
      let policy = try readPolicy(db)
      var prepared: [(CachePut, Int64, String, String, Int)] = []
      var total = 0
      for entry in entries {
        guard let date = cacheDate(entry.fetchedAt) else { throw RielaCacheError.invalid("invalid fetchedAt") }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= 0, seconds <= Double(now) / 1000 else {
          throw RielaCacheError.invalid("fetchedAt must not be in the future or before 1970")
        }
        let fetched = Int64((seconds * 1000).rounded(.down))
        guard fetched + Int64(policy.ttlSeconds) * 1000 > now else { throw RielaCacheError.expiredInput(entry.key) }
        let existing = try queryRows(db, sql: "SELECT fetched_ms FROM cache_entries WHERE scope = ? AND key = ?",
          bindings: [.text(scope), .text(entry.key)]).first
        if let timestamp = existing?.columns["fetched_ms"].flatMap(Int64.init), timestamp > fetched {
          throw RielaCacheError.invalid("put cannot replace a newer fetchedAt: \(entry.key)")
        }
        let data = try encoder.encode(entry.payload)
        // Charge key/namespace and fixed record overhead as well as payload bytes.
        let bytes = data.count + entry.key.utf8.count + scope.utf8.count + 512
        total += bytes
        guard total <= min(policy.maxBytes, Self.maximumFrameBytes) else {
          throw RielaCacheError.oversized(bytes: total, limit: min(policy.maxBytes, Self.maximumFrameBytes))
        }
        let canonical = CachePut(key: entry.key, fetchedAt: cacheTimestamp(fetched), payload: entry.payload)
        var digestInput = Data(scope.utf8)
        digestInput.append(0)
        digestInput.append(try encoder.encode(canonical))
        let revision = SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
        var stored = canonical
        stored.protectFromEviction = entry.protectFromEviction
        prepared.append((stored, fetched, String(decoding: data, as: UTF8.self), revision, bytes))
      }
      // Validation above precedes any eviction, even when a later batch item is invalid.
      let expired = try expire(db, now: now, policy: policy)
      var lookups: [CacheLookup] = []
      for (entry, fetched, payload, revision, bytes) in prepared {
        let sequence = try nextSequence(db)
        try execute(db, """
          INSERT INTO cache_entries(scope, key, payload_json, fetched_ms, revision, byte_count, access_seq, protected)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(scope, key) DO UPDATE SET payload_json = excluded.payload_json,
            fetched_ms = excluded.fetched_ms, revision = excluded.revision,
            byte_count = excluded.byte_count, access_seq = excluded.access_seq,
            protected = max(cache_entries.protected, excluded.protected)
          """, bindings: [.text(scope), .text(entry.key), .text(payload), .int64(fetched),
            .text(revision), .int(bytes), .int64(sequence), .int(entry.protectFromEviction == true ? 1 : 0)])
        lookups.append(.init(key: entry.key, status: "stored", entry: .init(key: entry.key, scope: scope,
          revision: revision, fetchedAt: entry.fetchedAt,
          expiresAt: cacheTimestamp(fetched + Int64(policy.ttlSeconds) * 1000), payload: nil, byteCount: bytes,
          protectFromEviction: try isProtected(db, scope: scope, key: entry.key))))
      }
      // Protect the entire new batch during admission, including ordinary unprotected puts.
      // If existing protected data leaves insufficient room, roll back every change.
      let batchKeys = Set(entries.map(\.key))
      let protectedRows = try queryRows(db, sql: "SELECT scope, key, byte_count FROM cache_entries WHERE protected = 1", bindings: [])
      let retained = protectedRows.filter { $0.columns["scope"] != scope || !batchKeys.contains($0.columns["key"]!) }
        .reduce(0) { $0 + Int($1.columns["byte_count"]!)! }
      guard retained + total <= policy.maxBytes else { throw RielaCacheError.protectedCapacityExceeded(limit: policy.maxBytes) }
      // New entries are newest in LRU order and the batch plus protected data fits.
      let evicted = try evict(db, policy: policy)
      return try result(db, policy: policy, expired: expired, evicted: evicted, results: lookups)
    }
  }

  public func get(cacheId: String, scope: String, keys: [String], maxOutputBytes: Int = maximumFrameBytes) throws -> CacheResult {
    try validate(scope: scope, keys: keys)
    guard (1...Self.maximumFrameBytes).contains(maxOutputBytes) else { throw RielaCacheError.invalid("invalid output budget") }
    return try transaction(cacheId) { db, now in
      let policy = try readPolicy(db)
      var results: [CacheLookup] = []
      var bytes = 0
      for key in keys {
        let metadata = try queryRows(db, sql: "SELECT fetched_ms, byte_count FROM cache_entries WHERE scope = ? AND key = ?",
          bindings: [.text(scope), .text(key)]).first
        guard let metadata else { results.append(.init(key: key, status: "miss", reason: "notFound")); continue }
        let fetched = Int64(metadata.columns["fetched_ms"] ?? "") ?? 0
        guard fetched + Int64(policy.ttlSeconds) * 1000 > now else {
          results.append(.init(key: key, status: "miss", reason: "expired")); continue
        }
        bytes += Int(metadata.columns["byte_count"] ?? "") ?? 0
        guard bytes <= maxOutputBytes else { throw RielaCacheError.oversized(bytes: bytes, limit: maxOutputBytes) }
        let row = try queryRows(db, sql: "SELECT payload_json, revision FROM cache_entries WHERE scope = ? AND key = ?",
          bindings: [.text(scope), .text(key)]).first!
        let payload = try JSONDecoder().decode(MemoryJSONValue.self, from: Data(row.payloadJSON.utf8))
        results.append(.init(key: key, status: "hit", entry: .init(key: key, scope: scope,
          revision: row.columns["revision"]!, fetchedAt: cacheTimestamp(fetched),
          expiresAt: cacheTimestamp(fetched + Int64(policy.ttlSeconds) * 1000), payload: payload,
          byteCount: Int(metadata.columns["byte_count"] ?? "") ?? 0,
          protectFromEviction: try isProtected(db, scope: scope, key: key))))
        try execute(db, "UPDATE cache_entries SET access_seq = ? WHERE scope = ? AND key = ?",
          bindings: [.int64(nextSequence(db)), .text(scope), .text(key)])
      }
      let expired = try expire(db, now: now, policy: policy)
      let response = try result(db, policy: policy, expired: expired, results: results)
      let outputBytes = try JSONEncoder().encode(response).count
      guard outputBytes <= maxOutputBytes else { throw RielaCacheError.oversized(bytes: outputBytes, limit: maxOutputBytes) }
      return response
    }
  }

  /// Atomic compare-and-delete. Absent keys succeed; a changed live revision rolls back the whole batch.
  public func delete(cacheId: String, scope: String, entries: [CacheDelete]) throws -> CacheResult {
    try validate(scope: scope, keys: entries.map(\.key))
    guard entries.allSatisfy({ $0.revision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }) else {
      throw RielaCacheError.invalid("delete requires a SHA256 revision for every key")
    }
    return try transaction(cacheId) { db, now in
      let policy = try readPolicy(db)
      let expired = try expire(db, now: now, policy: policy)
      var deleted = 0
      for entry in entries {
        let row = try queryRows(db, sql: "SELECT revision FROM cache_entries WHERE scope = ? AND key = ?",
          bindings: [.text(scope), .text(entry.key)]).first
        guard let row else { continue }
        guard row.columns["revision"] == entry.revision else { throw RielaCacheError.revisionConflict(entry.key) }
        try execute(db, "DELETE FROM cache_entries WHERE scope = ? AND key = ?", bindings: [.text(scope), .text(entry.key)])
        deleted += Int(sqlite3_changes(db))
      }
      return try result(db, policy: policy, expired: expired, deleted: deleted)
    }
  }

  /// Revision-checked capacity protection. Does not touch LRU order or retrieval TTL.
  public func protect(cacheId: String, scope: String, entries: [CacheProtection]) throws -> CacheResult {
    try validate(scope: scope, keys: entries.map(\.key))
    guard entries.allSatisfy({ $0.revision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }) else {
      throw RielaCacheError.invalid("protection requires a SHA256 revision for every key")
    }
    return try transaction(cacheId) { db, now in
      let policy = try readPolicy(db)
      let expired = try expire(db, now: now, policy: policy)
      var results: [CacheLookup] = []
      for entry in entries {
        guard let row = try queryRows(db, sql: "SELECT revision, fetched_ms, byte_count FROM cache_entries WHERE scope = ? AND key = ?",
          bindings: [.text(scope), .text(entry.key)]).first, row.columns["revision"] == entry.revision else {
          throw RielaCacheError.revisionConflict(entry.key)
        }
        try execute(db, "UPDATE cache_entries SET protected = ? WHERE scope = ? AND key = ?",
          bindings: [.int(entry.protectFromEviction ? 1 : 0), .text(scope), .text(entry.key)])
        let fetched = Int64(row.columns["fetched_ms"]!)!
        results.append(.init(key: entry.key, status: entry.protectFromEviction ? "protected" : "released",
          entry: .init(key: entry.key, scope: scope, revision: entry.revision, fetchedAt: cacheTimestamp(fetched),
            expiresAt: cacheTimestamp(fetched + Int64(policy.ttlSeconds) * 1000), payload: nil,
            byteCount: Int(row.columns["byte_count"]!)!, protectFromEviction: entry.protectFromEviction)))
      }
      return try result(db, policy: policy, expired: expired, results: results)
    }
  }

  private func isProtected(_ db: OpaquePointer, scope: String, key: String) throws -> Bool {
    try queryRows(db, sql: "SELECT protected FROM cache_entries WHERE scope = ? AND key = ?",
      bindings: [.text(scope), .text(key)]).first?.columns["protected"] == "1"
  }

  private func validate(scope: String, keys: [String]) throws {
    guard !scope.isEmpty, scope.utf8.count <= 512, !scope.contains("\0"), scope == scope.trimmingCharacters(in: .whitespacesAndNewlines),
      !keys.isEmpty, keys.count <= 1024, Set(keys).count == keys.count,
      keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0") && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
      throw RielaCacheError.invalid("scope/key invalid, duplicate key, or batch outside 1...1024")
    }
  }

  private func transaction<T>(_ cacheId: String, body: (OpaquePointer, Int64) throws -> T) throws -> T {
    let path = try databasePath(cacheId: cacheId)
    try FileManager.default.createDirectory(atPath: rootDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db = handle else {
      if let handle { sqlite3_close(handle) }
      throw RielaMemoryError.openFailed("cache database could not be opened")
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5_000)
    let application = try queryRows(db, sql: "PRAGMA application_id", bindings: []).first?.columns["application_id"]
    let tables = try queryRows(db, sql: "SELECT count(*) AS count FROM sqlite_master WHERE type = 'table'", bindings: []).first?.columns["count"]
    guard application == "1380533064" || (application == "0" && tables == "0") else { throw RielaCacheError.foreignDatabase }
    let schemaVersion = try queryRows(db, sql: "PRAGMA user_version", bindings: []).first?.columns["user_version"]
    guard schemaVersion == "0" || schemaVersion == "1" || schemaVersion == "2" else { throw RielaCacheError.foreignDatabase }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    try execute(db, "PRAGMA auto_vacuum = FULL")
    _ = try queryRows(db, sql: "PRAGMA journal_mode = DELETE", bindings: [])
    _ = try queryRows(db, sql: "PRAGMA secure_delete = ON", bindings: [])
    try execute(db, "BEGIN IMMEDIATE")
    do {
      try execute(db, "PRAGMA application_id = 1380533064")
      try execute(db, "PRAGMA user_version = 2")
      try execute(db, "CREATE TABLE IF NOT EXISTS cache_policy(id INTEGER PRIMARY KEY CHECK(id = 1), ttl_seconds INTEGER NOT NULL, max_bytes INTEGER NOT NULL, sequence INTEGER NOT NULL)")
      try execute(db, "INSERT OR IGNORE INTO cache_policy VALUES(1, 86400, 268435456, 0)")
      try execute(db, """
        CREATE TABLE IF NOT EXISTS cache_entries(scope TEXT NOT NULL, key TEXT NOT NULL, payload_json TEXT NOT NULL,
          fetched_ms INTEGER NOT NULL, revision TEXT NOT NULL, byte_count INTEGER NOT NULL, access_seq INTEGER NOT NULL,
          protected INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(scope, key))
        """)
      let columns = try queryRows(db, sql: "PRAGMA table_info(cache_entries)", bindings: [])
      if !columns.contains(where: { $0.columns["name"] == "protected" }) {
        try execute(db, "ALTER TABLE cache_entries ADD COLUMN protected INTEGER NOT NULL DEFAULT 0")
      }
      try execute(db, "CREATE INDEX IF NOT EXISTS cache_lru ON cache_entries(access_seq, scope, key)")
      try execute(db, "CREATE INDEX IF NOT EXISTS cache_expiry ON cache_entries(fetched_ms)")
      let seconds = clock().timeIntervalSince1970
      guard seconds.isFinite, seconds >= 0, seconds < 9e12 else { throw RielaCacheError.invalid("invalid clock") }
      let value = try body(db, Int64((seconds * 1000).rounded(.down)))
      try execute(db, "COMMIT")
      return value
    } catch { try? execute(db, "ROLLBACK"); throw error }
  }

  private func readPolicy(_ db: OpaquePointer) throws -> CachePolicy {
    let row = try queryRows(db, sql: "SELECT ttl_seconds, max_bytes FROM cache_policy WHERE id = 1", bindings: []).first!
    return CachePolicy(ttlSeconds: Int(row.columns["ttl_seconds"]!)!, maxBytes: Int(row.columns["max_bytes"]!)!)
  }
  private func nextSequence(_ db: OpaquePointer) throws -> Int64 {
    let value = try queryRows(db, sql: "SELECT sequence FROM cache_policy WHERE id = 1", bindings: []).first!.columns["sequence"]!
    guard let sequence = Int64(value), sequence < Int64.max else { throw RielaCacheError.invalid("cache sequence exhausted") }
    try execute(db, "UPDATE cache_policy SET sequence = ? WHERE id = 1", bindings: [.int64(sequence + 1)])
    return sequence + 1
  }
  private func expire(_ db: OpaquePointer, now: Int64, policy: CachePolicy) throws -> Int {
    try execute(db, "DELETE FROM cache_entries WHERE fetched_ms <= ?", bindings: [.int64(now - Int64(policy.ttlSeconds) * 1000)])
    return Int(sqlite3_changes(db))
  }
  private func evict(_ db: OpaquePointer, policy: CachePolicy) throws -> Int {
    var total = try queryRows(db, sql: "SELECT coalesce(sum(byte_count), 0) AS bytes FROM cache_entries", bindings: []).first!.columns["bytes"].flatMap(Int.init)!
    var count = 0
    while total > policy.maxBytes {
      guard let row = try queryRows(db, sql: "SELECT scope, key, byte_count FROM cache_entries WHERE protected = 0 ORDER BY access_seq, scope, key LIMIT 1", bindings: []).first else {
        throw RielaCacheError.protectedCapacityExceeded(limit: policy.maxBytes)
      }
      try execute(db, "DELETE FROM cache_entries WHERE scope = ? AND key = ?", bindings: [.text(row.columns["scope"]!), .text(row.columns["key"]!)])
      total -= Int(row.columns["byte_count"]!)!
      count += 1
    }
    return count
  }
  private func result(_ db: OpaquePointer, policy: CachePolicy, expired: Int = 0, evicted: Int = 0,
    deleted: Int = 0, results: [CacheLookup] = []) throws -> CacheResult {
    let row = try queryRows(db, sql: """
      SELECT count(*) AS count, coalesce(sum(byte_count), 0) AS bytes,
        coalesce(sum(CASE WHEN protected = 1 THEN byte_count ELSE 0 END), 0) AS protected_bytes
      FROM cache_entries
      """, bindings: []).first!
    return CacheResult(results: results, deletedCount: deleted,
      stats: .init(entryCount: Int(row.columns["count"]!)!, byteCount: Int(row.columns["bytes"]!)!,
        expiredCount: expired, evictedCount: evicted, policy: policy, protectedByteCount: Int(row.columns["protected_bytes"]!)!))
  }
}
